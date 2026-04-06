@echo off
setlocal

:: Build m4rie on Windows using the MSYS2/MinGW (m2w64) toolchain.
:: conda-build sets LIBRARY_PREFIX to %PREFIX%\Library for C libraries on Windows.
:: We convert backslashes to forward slashes for use in bash/configure.

bash -c "set -eo pipefail && export CFLAGS=\"-O2 -g ${CFLAGS}\" && ./configure --prefix=%LIBRARY_PREFIX:\=/% --libdir=%LIBRARY_PREFIX:\=/%/lib --bindir=%LIBRARY_PREFIX:\=/%/bin --includedir=%LIBRARY_PREFIX:\=/%/include && make && make install"
if errorlevel 1 exit 1
