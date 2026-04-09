@echo off
setlocal EnableDelayedExpansion

:: MSYS2 bash requires /tmp to exist or it may hang at startup
if not exist C:\tmp mkdir C:\tmp
set "TMP=C:\tmp"
set "TEMP=C:\tmp"

:: m2-bash is installed into the build environment via meta.yaml requirements
:: It is available at %BUILD_PREFIX%\Library\usr\bin\bash.exe
set "BASH=%BUILD_PREFIX%\Library\usr\bin\bash.exe"

:: --norc --noprofile: skip bash init files that may block in MSYS2 env
"%BASH%" --norc --noprofile "%RECIPE_DIR%/build.sh"
if %ERRORLEVEL% neq 0 exit 1
