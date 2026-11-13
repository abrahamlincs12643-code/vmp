using module .\cfxBuildContext.psm1
using module .\cfxBuildTools.psm1
using module .\cfxCacheVersions.psm1
using module .\cfxVersions.psm1

function Invoke-PackClient {
    param(
        [CfxBuildContext] $Context,
        [CfxBuildTools] $Tools,
        [CfxVersions] $Versions
    )

    $cacheName = "fivereborn"

    $binRoot = $Context.MSBuildOutput
    $packRoot = [IO.Path]::Combine($Context.CachesRoot, $cacheName)
    $cachesRoot = $Context.CachesRoot
    $projectRoot = $Context.ProjectRoot

    # Ensure we always have clean packed client by removing old caches root
    Remove-Item -Force -Recurse -ErrorAction ignore $cachesRoot

    # Create needed caches root folder structure
    Invoke-EnsureDirExists $packRoot\bin\cef
    Invoke-EnsureDirExists $packRoot\citizen

    # Adding CEF
    Copy-Item -Force -Recurse $projectRoot\vendor\cef\Release\*.dll               $packRoot\bin\
    Copy-Item -Force -Recurse $projectRoot\vendor\cef\Release\*.bin               $packRoot\bin\
    Copy-Item -Force -Recurse $projectRoot\vendor\cef\Resources\icudtl.dat        $packRoot\bin\
    Copy-Item -Force -Recurse $projectRoot\vendor\cef\Resources\*.pak             $packRoot\bin\cef\
    Copy-Item -Force -Recurse $projectRoot\vendor\cef\Resources\locales\en-US.pak $packRoot\bin\cef\

    # remove CEF as redownloading is broken and this slows down gitlab ci cache
    Remove-Item -Recurse $projectRoot\vendor\cef\*

    if ($Context.IS_FIVEM) {
        Copy-Item -Force -Recurse $projectRoot\data\shared\*     $packRoot\
        Copy-Item -Force -Recurse $projectRoot\data\client\*     $packRoot\
        Copy-Item -Force -Recurse $projectRoot\data\redist\crt\* $packRoot\bin\
    }
    elseif ($Context.IS_REDM) {
        Copy-Item -Force -Recurse $projectRoot\data\shared\*                 $packRoot\
        Copy-Item -Force -Recurse $projectRoot\data\client\*.dll             $packRoot\
        Copy-Item -Force -Recurse $projectRoot\data\client\bin\*             $packRoot\bin\
        Copy-Item -Force -Recurse $projectRoot\data\redist\crt\*             $packRoot\bin\
        Copy-Item -Force -Recurse $projectRoot\data\client\citizen\clr2      $packRoot\citizen\
        Copy-Item -Force -Recurse $projectRoot\data\client\citizen\*.ttf     $packRoot\citizen\
        Copy-Item -Force -Recurse $projectRoot\data\client\citizen\ros       $packRoot\citizen\
        Copy-Item -Force -Recurse $projectRoot\data\client\citizen\resources $packRoot\citizen\
        Copy-Item -Force -Recurse $projectRoot\data\client_rdr\*             $packRoot\
    }

    # GMP FIX (FiveM crash "msvcp140.dll+12A47" right after update):
    # data\redist\crt in the repo holds an OLD copy of msvcp140/vcruntime140. The binaries are compiled with the
    # (newer) MSVC toolset of the CI runner, and the app loads the CRT from FiveM.app\bin first, so an older
    # msvcp140.dll than the compiler's STL crashes at startup. Always bundle the CRT that ships with the toolset
    # that built this client (Visual Studio\VC\Redist\MSVC\<newest>\x64\Microsoft.VC14x.CRT).
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

    $oldVer = $null
    if (Test-Path -LiteralPath "$packRoot\bin\msvcp140.dll") {
        $oldVer = (Get-Item "$packRoot\bin\msvcp140.dll").VersionInfo.FileVersion
    }

    Copy-Item -Force (Join-Path $crtDir.FullName "*.dll") "$packRoot\bin\"

    $newVer = (Get-Item "$packRoot\bin\msvcp140.dll").VersionInfo.FileVersion
    Write-Host "GMP CRT: bundled msvcp140.dll $oldVer (repo data\redist\crt) -> $newVer ($($crtDir.FullName))"
    if ($oldVer -and ([version]($oldVer -replace '[^\d\.].*$','')) -gt ([version]($newVer -replace '[^\d\.].*$',''))) {
        throw "GMP: bundled msvcp140.dll ($oldVer) is newer than the toolset CRT ($newVer) - refusing to downgrade"
    }

    # Adding build output
    Copy-Item -Force $binRoot\*.dll                      $packRoot\
    Copy-Item -Force $binRoot\*.com                      $packRoot\
    Copy-Item -Force $binRoot\CitizenFX_SubProcess_*.bin $packRoot\

    Copy-Item -Force -Recurse $binRoot\citizen\*         $packRoot\citizen\
	
    if ($Context.IS_FIVEM) {
        Copy-Item -Force $binRoot\FiveM_Diag.exe $packRoot\
    }

    # Adding UI
    Copy-Item -Force $Context.getPathInProject("ext\ui-build\data.zip")     $packRoot\citizen\ui.zip
    Copy-Item -Force $Context.getPathInProject("ext\ui-build\data_big.zip") $packRoot\citizen\ui-big.zip
	
    # Writing versions
    $Versions.Game    | Out-File -Encoding ascii $packRoot\citizen\version.txt
    $Versions.BuildID | Out-File -Encoding ascii $packRoot\citizen\release.txt

    Write-ClientCacheVersions -CachesRoot $cachesRoot -CacheName $cacheName -Versions $Versions

    # GCI
    if ($Context.PrivateRoot) {
        if (!$Tools.gci) {
            throw "No GCI tool"
        }

        $listFile = [IO.Path]::Combine($Context.PrivateRoot, "gci-list-{0}.txt" -f $Context.ProductName)

        if (!(Test-Path $listFile)) {
            throw "No GCI list found"
        }

        & $Tools.gci make -r $packRoot -l $listFile
        Test-LastExitCode "GCI tool failed"
    }

    # Bootstrapper
    $bootstrapperPath = [IO.Path]::Combine($binRoot, $Context.ProductExeName)
    $bootstrapperCompressedPath = "$cachesRoot\CitizenFX.exe.xz"

    Copy-Item -Force $bootstrapperPath $packRoot\CitizenFX.exe
    Copy-Item -Force $bootstrapperPath $cachesRoot\CitizenFX.exe

    # GMP: the closed Rockstar RGL elevation helper is no longer required/shipped
    if (Test-Path "$binRoot\RGL-ElevationHelper.exe") {
        Copy-Item -Force $binRoot\RGL-ElevationHelper.exe $packRoot\
    }

    # upload review jobs will use this compressed bootstrap file
    Remove-Item -Force -ErrorAction ignore $bootstrapperCompressedPath

    & $Tools.xz -9 $cachesRoot\CitizenFX.exe
    Test-LastExitCode "Failed to compress CitizenFX.exe with xz"

    $cachesVersion = @(
        $Versions.Launcher
        (Get-ItemProperty $bootstrapperCompressedPath).Length
    ) -join ' '
    $cachesVersion | Out-File -Encoding ascii $cachesRoot\version.txt
}
