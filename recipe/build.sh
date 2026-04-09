#!/bin/bash
set -euo pipefail

if [[ "${target_platform}" == win* ]]; then
    # MSYS2 bash may hang if /tmp doesn't exist
    mkdir -p /tmp

    # Use POSIX-style path (starts with /) — autoconf accepts it as absolute.
    INSTALL_PREFIX=$(python -c "
import os
p = os.environ['LIBRARY_PREFIX'].replace('\\\\', '/')
drive, rest = p.split(':', 1)
print('/' + drive.lower() + rest)
")

    # Prefer clang-cl over cl.exe: m4rie uses __builtin_ctzll / __builtin_popcountll
    # and __attribute__((optimize(...))), which cl.exe doesn't support.
    # clang-cl accepts GCC-compatible flags and builtins while producing MSVC-ABI
    # objects that link against the MSVC runtime.
    if command -v clang-cl >/dev/null 2>&1; then
        export CC=clang-cl
    fi
    # AR, RANLIB, DLLTOOL, etc. come from the conda-forge toolchain activation.

    export CFLAGS="-O2 -g"
    export CPPFLAGS="-I${INSTALL_PREFIX}/include"
    export LDFLAGS="-L${INSTALL_PREFIX}/lib"
    export PKG_CONFIG_PATH="${INSTALL_PREFIX}/lib/pkgconfig"
    export PKG_CONFIG="pkg-config"

    # Remove PATH entries containing spaces. Git for Windows tools appear at
    # paths like "/c/Program Files/Git/usr/bin/mkdir", which configure stores
    # unquoted and then bash word-splits on the space, causing every compiler
    # feature test to fail with "/c/Program: No such file or directory".
    # Use pure bash — passing $PATH as an argument to native Windows Python
    # triggers MSYS2's auto-conversion from POSIX (:) to Windows (;) format,
    # which breaks the split and wipes everything from PATH.
    IFS=: read -ra _path_arr <<< "$PATH"
    _clean_path=""
    for _p in "${_path_arr[@]}"; do
        case "$_p" in
            *\ *|'') ;;
            *) _clean_path="${_clean_path:+$_clean_path:}$_p" ;;
        esac
    done
    export PATH="$_clean_path"
    unset _path_arr _clean_path _p

    # Pre-set autoconf cache variables to bypass MSYS2 expr limitations.
    # MSYS2's /usr/bin/expr returns 0 for BRE \( \) capture groups, causing
    # EXEEXT and OBJEXT to be detected as "0" instead of ".exe" and "o",
    # which makes all subsequent compiler feature checks fail (they look for
    # "conftest.0" instead of "conftest.exe").
    export ac_cv_exeext='.exe'
    export ac_cv_objext='obj'

    # MSYS2's /usr/bin/expr also corrupts --opt=VALUE parsing in autoconf
    # (returns 0 instead of VALUE). Use an array with space separators so
    # configure does direct assignment (no expr call) for all options.
    configure_args=(
        --prefix "${INSTALL_PREFIX}"
        --libdir "${INSTALL_PREFIX}/lib"
    )

    # Set SHELL and CONFIG_SHELL to the current bash executable (no spaces in path).
    # configure's line ~261 re-execs itself via: exec $SHELL "$0" "$@"
    # If $SHELL is "/c/Program Files/Git/usr/bin/bash.exe" (has spaces), bash
    # word-splits it and tries to exec "/c/Program" — which doesn't exist.
    # $BASH is set by bash itself to the running executable's full path and is
    # always a no-space m2-bash path, so it's safe to use for re-exec.
    export SHELL="${BASH}"
    export CONFIG_SHELL="${BASH}"

    if ! "${BASH}" ./configure "${configure_args[@]}"; then
        echo "=== configure FAILED — config.log tail ==="
        tail -80 config.log 2>/dev/null || echo "(no config.log found)"
        exit 1
    fi

    # conda-forge's m4ri ships m4ri.lib + m4ri-2.dll but NOT libm4ri.dll.a.
    # Build a GNU-format import library so libtool can detect m4ri as a shared
    # dependency.  Without it libtool falls back to static-only and emits:
    #   "linker path does not have real file for library -lm4ri"
    #
    # Symbol extraction: nm on m4ri.lib reads __imp_XXX stubs for all exported
    # functions. dlltool --output-def fails on MSVC-built DLLs so we avoid it.
    #
    # DATA annotation: m4ri_codebook and m4ri_cantor_basis are global arrays.
    # They must be listed as "NAME DATA" in the def file so dlltool generates
    # the correct IAT pointer stub.  The MSVC .lib omits them from __imp_XXX
    # so we append them unconditionally.
    _m4ri_implib="${INSTALL_PREFIX}/lib/libm4ri.dll.a"
    _m4ri_dotlib="${INSTALL_PREFIX}/lib/m4ri.lib"
    if [[ ! -f "${_m4ri_implib}" && -f "${_m4ri_dotlib}" ]]; then
        _m4ri_dll=""
        for _f in "${INSTALL_PREFIX}/lib"/m4ri*.dll \
                   "${INSTALL_PREFIX}/bin"/m4ri*.dll; do
            [[ -f "${_f}" ]] && _m4ri_dll="${_f}" && break
        done
        _m4ri_dllname=$(basename "${_m4ri_dll:-m4ri-2.dll}")

        nm "${_m4ri_dotlib}" 2>/dev/null \
            | grep -o '__imp_[A-Za-z_][A-Za-z0-9_]*' \
            | sed 's/__imp_//' \
            | sort -u \
            > /tmp/m4ri_syms.txt || true

        # Detect additional data symbols via nm on the DLL (type D/B)
        _nm_data=""
        if [[ -n "${_m4ri_dll}" ]]; then
            _nm_data=$(nm "${_m4ri_dll}" 2>/dev/null \
                | awk '$2~/^[DB]$/{print $3}') || true
        fi

        {
            printf 'LIBRARY %s\n' "${_m4ri_dllname}"
            printf 'EXPORTS\n'
            while IFS= read -r _sym || [[ -n "${_sym}" ]]; do
                [[ -z "${_sym}" ]] && continue
                case "${_sym}" in
                    m4ri_codebook|m4ri_cantor_basis)
                        printf '  %s DATA\n' "${_sym}" ;;
                    *)
                        if [[ -n "${_nm_data}" ]] && \
                           printf '%s\n' "${_nm_data}" | grep -qx "${_sym}"; then
                            printf '  %s DATA\n' "${_sym}"
                        else
                            printf '  %s\n' "${_sym}"
                        fi ;;
                esac
            done < /tmp/m4ri_syms.txt
            # Append known data symbols unconditionally — MSVC .lib omits them
            # from the __imp_XXX section so nm doesn't find them above.
            printf '  m4ri_codebook DATA\n'
            printf '  m4ri_cantor_basis DATA\n'
        } > /tmp/m4ri.def
        # Remove any plain (non-DATA) duplicate entries for data symbols
        sed -i '/^  m4ri_codebook$\|^  m4ri_cantor_basis$/d' /tmp/m4ri.def || true

        dlltool -d /tmp/m4ri.def -l "${_m4ri_implib}" \
            || { cp "${_m4ri_dotlib}" "${_m4ri_implib}" || true; }

        [[ -f "${_m4ri_implib}" ]] \
            || { echo "ERROR: could not create ${_m4ri_implib}" >&2; exit 1; }

        unset _m4ri_implib _m4ri_dotlib _m4ri_dll _m4ri_dllname \
              _nm_data _sym _f
    fi
else
    export CFLAGS="-O2 -g -fPIC ${CFLAGS:-} -L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib"
    ./configure --prefix="${PREFIX}" --libdir="${PREFIX}/lib"
fi

# Serial make on Windows.  Explicit -j1 overrides any MAKEFLAGS=-jN that
# the environment or conda-build might have set, ensuring no parallel jobs
# race the libm4rie.la link rule against still-compiling .lo files.
if [[ "${target_platform}" == win* ]]; then
    unset MAKEFLAGS
    make -j1
else
    make -j${CPU_COUNT}
fi
if [[ "${CONDA_BUILD_CROSS_COMPILATION}" != "1" && "${target_platform}" != win* ]]; then
    make check
fi
make install
