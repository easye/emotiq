#!/usr/bin/env bash
#
#  Assuming the proper development tools are in place, make the
#  libraries needed, and produce a shared object suitable for loading
#  the code for Pair Based Curves (PBC).
#
# Linux
#   apt-get install gcc make g++ flex bison
# MacOS
#   XCode needs to be installed


# debug
set -x

EXTERNAL_LIBS_VERSION=release-0.1.15

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE=${DIR}/..
var=${BASE}/var

MAKE=make

uname_s=$(uname -s)
case ${uname_s} in
    Linux*)
        echo Building for Linux
        lib_suffix=linux
        maketarget=makefile.linux.static
        if [ "x${PENTIUM4}" == "xtrue" ] ; then
          EXTERNAL_LIBS_VERSION=release-0.1.8-p4-linux
        fi
        ;;
    Darwin*)
        echo Building for macOS
        lib_suffix=osx
        maketarget=makefile.macos.static
        ;;
    FreeBSD*)
        echo Building for FreeBSD
        lib_suffix=freebsd
        maketarget=makefile.freebsd.static
        MAKE=gmake
        ;;
    *)
        maketarget=makefile.linux
        echo Unknown OS \"$(uname_s)\" 
        exit 127
        ;;
esac

mkdir -p ${var}/local

prefix=${var}/local
lib=${prefix}/lib
inc=${prefix}/include
pbcintf=${BASE}/src/Crypto/Crypto-Libraries/PBC-Intf

external_download_install () {
    libs_url=https://github.com/emotiq/emotiq-external-libs/releases/download/${EXTERNAL_LIBS_VERSION}/emotiq-external-libs-${lib_suffix}.tgz
    (cd ${var}/local && curl -L ${libs_url} | tar xvfz -)
}

if [[
       -f ${lib}/libgmp.a
    && -f ${lib}/libpbc.a
   ]]; then
    echo Not overwriting existing libaries in ${lib}
else
    external_download_install
fi

# Remove shared libs (we use only statics)
rm -f ${lib}/libgmp*.dylib ${lib}/libpbc*.dylib ${lib}/libgmp.so* ${lib}/libpbc.so*


export CFLAGS=-I${inc}
export CPPFLAGS=-I${inc}
export CXXFLAGS=-I${inc}
export LDFLAGS=-L${lib}

cd ${pbcintf} && \
    ${MAKE} --makefile=${maketarget} PREFIX=${prefix}
