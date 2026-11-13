using module .\cfxBuildContext.psm1
using module .\cfxBuildTools.psm1

function Invoke-PackServer {
    param(
        [CfxBuildContext] $Context,
        [CfxBuildTools] $Tools
    )

    $binRoot = $Context.MSBuildOutput
    $packRoot = $Context.getPathInProject("out")
    $projectRoot = $Context.ProjectRoot

    Remove-Item -Recurse -Force -ErrorAction Ignore $packRoot | Out-Null

    # create folders layout
    New-Item -ItemType Directory -Force $packRoot\server\citizen\system_resources | Out-Null

    # copy system resources
    Copy-Item -Force -Recurse $projectRoot\ext\system-resources\data\* $packRoot\server\citizen\system_resources\

    # excludes the unit test runner CitiTest.exe, because it doesn't need to be distributed by the ci
    Copy-Item -Force -Exclude "CitiTest.exe" $binRoot\*.exe $packRoot\server\
    Copy-Item -Force $binRoot\*.dll $packRoot\server\

    Copy-Item -Force -Recurse $binRoot\citizen\* $packRoot\server\citizen\

    Copy-Item -Force -Recurse $projectRoot\data\shared\*         $packRoot\server\
    Copy-Item -Force -Recurse $projectRoot\data\redist\crt\*     $packRoot\server\
    Copy-Item -Force -Recurse $projectRoot\data\server\*         $packRoot\server\
    Copy-Item -Force -Recurse $projectRoot\data\server_windows\* $packRoot\server\
    Copy-Item -Force -Recurse $projectRoot\data\server_windows_release\* $packRoot\server\

    # GMP FIX (FXServer crashes right at startup: access violation inside msvcp140.dll):
    # data\redist\crt in the repo holds an OLD msvcp140/vcruntime140 (14.34). FXServer is compiled with the newer MSVC
    # toolset of the CI runner and loads the CRT from its own folder first, so an msvcp140.dll older than the compiler's
    # STL crashes (e.g. std::mutex). Bundle the CRT that ships with the toolset that built this server
    # (Visual Studio\VC\Redist\MSVC\<newest>\x64\Microsoft.VC14x.CRT). Never downgrade an already newer copy.
    $vswhere = [IO.Path]::Combine($projectRoot, "code\tools\ci\vswhere.exe")
    $vsPath = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($vsPath)) {
        throw "GMP: Visual Studio not found, cannot bundle the matching MSVC runtime"
    }

    $redistRoot = Join-Path $vsPath "VC\Redist\MSVC"
    $crtDir = Get-ChildItem -LiteralPath $redistRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.FullName "x64") -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue } |
        Select-Object -First 1

    if (-not $crtDir -or -not (Test-Path -LiteralPath (Join-Path $crtDir.FullName "msvcp140.dll"))) {
        throw "GMP: MSVC x64 CRT redistributable not found under $redistRoot"
    }

    $packedMsvcp = "$packRoot\server\msvcp140.dll"
    $toolMsvcp = Join-Path $crtDir.FullName "msvcp140.dll"
    $oldVer = $null
    if (Test-Path -LiteralPath $packedMsvcp) {
        $oldVer = (Get-Item -LiteralPath $packedMsvcp).VersionInfo.FileVersion
    }
    $toolVer = (Get-Item -LiteralPath $toolMsvcp).VersionInfo.FileVersion
    $oldV = if ($oldVer) { [version]($oldVer -replace '[^\d\.].*$','') } else { $null }
    $toolV = [version]($toolVer -replace '[^\d\.].*$','')

    if ($oldV -and $oldV -gt $toolV) {
        Write-Warning "GMP CRT: repo msvcp140.dll ($oldVer) is newer than the toolset CRT ($toolVer): keeping the repo copy"
    }
    else {
        Copy-Item -Force (Join-Path $crtDir.FullName "*.dll") "$packRoot\server\"
        Write-Host "GMP CRT: bundled msvcp140.dll $oldVer (repo data\redist\crt) -> $toolVer ($($crtDir.FullName))"
    }

    Remove-Item -Force $packRoot\server\citizen\.gitignore

    # breaks downlevel OS compat
    Remove-Item -Force $packRoot\server\dbghelp.dll

    # cleanup client-related scripting files
    Remove-Item -Force $packRoot\server\citizen\scripting\lua\natives_0*.zip
    Remove-Item -Force $packRoot\server\citizen\scripting\lua\natives_2*.zip
    Remove-Item -Force $packRoot\server\citizen\scripting\lua\*_universal.lua
    Remove-Item -Force $packRoot\server\citizen\scripting\lua\*_universal.zip
    Remove-Item -Force $packRoot\server\citizen\scripting\lua\natives_0*.lua
    Remove-Item -Force $packRoot\server\citizen\scripting\lua\natives_2*.lua

    Remove-Item -Force $packRoot\server\citizen\scripting\v8\*_universal.d.ts
    Remove-Item -Force $packRoot\server\citizen\scripting\v8\*_universal.js
    Remove-Item -Force $packRoot\server\citizen\scripting\v8\natives_0*.*
    Remove-Item -Force $packRoot\server\citizen\scripting\v8\natives_2*.*

    & $Tools.SevenZip a -mx=9 $packRoot\server.zip $packRoot\server\*
    & $Tools.SevenZip a -mx=7 $packRoot\server.7z $packRoot\server\*

    # cleanup
    Remove-Item -Force -Recurse $packRoot\server
}