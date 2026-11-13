local version = ...
local majorVersion, minorVersion = version:match("^(%d+)%.(%d+)")
local baseVersion = ('%s.%s'):format(majorVersion, minorVersion)
local libName = 'v8_monolith.lib'
local libNameDebug = 'v8_monolithd.lib'

return {
    include = function()
        defines {
            'V8_COMPRESS_POINTERS',
            'V8_31BIT_SMIS_ON_64BIT_ARCH',
            'V8_COMPRESS_POINTERS_IN_SHARED_CAGE',
            'CPPGC_CAGED_HEAP',
            'V8_ENABLE_CHECKS',
        }

        if os.istarget('windows') then
            includedirs { "../vendor/v8/" .. baseVersion .. "/source/include/" }
            libdirs { "../vendor/v8/" .. baseVersion .. "/lib/" }

            filter "configurations:Debug"
            links { 
                libNameDebug,
                'Dbghelp.lib',
            }
            filter {}

            filter "configurations:Release"
            links { 
                libName,
                'Dbghelp.lib',
            }
            filter {}
        end
    end,
    run = function()
        kind 'Utility'
        
        files {
            ('../vendor/v8/%s/tag.txt'):format(baseVersion)
        }

        -- Mirrors are tried in order; the first one that serves the file wins.
        local mirrorURLs = {
            ('https://cdn.vmp.ir/mirrors/vendor/v8/%s'):format(baseVersion),
            ('https://content.cfx.re/mirrors/vendor/v8/%s'):format(baseVersion),
        }
        local v8LibDir = (path.getabsolute('../') .. '/vendor/v8/%s/lib'):format(baseVersion)

        -- Builds one "curl A || curl B" command line for cmd.exe.
        --  * --create-dirs: vendor/v8/<ver>/lib is not tracked by git (only *.lib is ignored there and
        --    empty folders are not committed), so curl must create it, otherwise it fails with
        --    "Failed to open the file" (exit 23) and MSBuild reports MSB8066 exit code 1.
        --  * --fail: never save an HTML error page as a .lib file.
        --  * -z: re-download only if the server copy is newer than the local file.
        local function downloadCommand(fileName)
            local target = ('%s/%s'):format(v8LibDir, fileName)
            local attempts = {}
            for _, url in ipairs(mirrorURLs) do
                table.insert(attempts, ('curl.exe --fail --retry 3 --retry-delay 5 --connect-timeout 30 --create-dirs "-z%s" -L "-o%s" "%s/%s?t=%s"'):format(target, target, url, fileName, os.time()))
            end
            return table.concat(attempts, ' || ')
        end

        if os.istarget('windows') then
            filter { "files:**/tag.txt", "configurations:Debug" }
                buildmessage 'Downloading v8_monolithd.lib'
                buildoutputs {
                    ('%s/%s'):format(v8LibDir, libNameDebug),
                }
                buildcommands {
                    -- download files, redownload only if outdated
                    'echo Pre-build step for downloading v8_monolith libraries',
                    downloadCommand(libNameDebug),
                    'if %errorlevel% neq 0 (echo ERROR: v8 monolith download failed on every mirror & exit /b 1)',
                    ('if not exist "%s/%s" (echo ERROR: %s is missing after download & exit /b 1)'):format(v8LibDir, libNameDebug, libNameDebug),
                }
            filter{}

            filter { "files:**/tag.txt", "configurations:Release" }
                buildmessage 'Downloading v8_monolith.lib'
                buildoutputs {
                    ('%s/%s'):format(v8LibDir, libName),
                }
                buildcommands {
                    -- download files, redownload only if outdated
                    'echo Pre-build step for downloading v8_monolith libraries',
                    downloadCommand(libName),
                    'if %errorlevel% neq 0 (echo ERROR: v8 monolith download failed on every mirror & exit /b 1)',
                    ('if not exist "%s/%s" (echo ERROR: %s is missing after download & exit /b 1)'):format(v8LibDir, libName, libName),
                }
            filter{}
        end
    end
}
