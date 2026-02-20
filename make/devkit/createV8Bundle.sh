#!/bin/bash
#
# Copyright (c) 2026, Oracle and/or its affiliates. All rights reserved.
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
#
# This code is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License version 2 only, as
# published by the Free Software Foundation.
#
# This code is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# version 2 for more details (a copy is included in the LICENSE file that
# accompanied this code).
#
# You should have received a copy of the GNU General Public License version
# 2 along with this work; if not, write to the Free Software Foundation,
# Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
#
# Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
# or visit www.oracle.com if you need additional information or have any
# questions.
#

# This build script builds a v8 bundle to be used by the org.openjdk.engine.javascript module.

# Exit on error
set -e

V8_REVISION=14.4.221

BUNDLE_NAME=v8-static-$V8_REVISION.tar.gz

SCRIPT_DIR="$(cd "$(dirname $0)" > /dev/null && pwd)"
SCRIPT_FILE="$(basename $0)"
OUTPUT_DIR="${SCRIPT_DIR}/../../build/v8"
SRC_DIR="$OUTPUT_DIR/src"
BUILD_DIR="$OUTPUT_DIR/build"
DOWNLOAD_DIR="$OUTPUT_DIR/download"
INSTALL_DIR="$OUTPUT_DIR/install"
IMAGE_DIR="$OUTPUT_DIR/image"
V8_CONF_DIR="${SCRIPT_DIR}/v8-conf"

V8_REPO="$SRC_DIR/v8"

OS_NAME=$(uname -s)
OS_ARCH=$(arch)
NUM_CORES=$(nproc --all)

USAGE="$0 <depot tools dir>"

if [ "$1" = "" ]; then
    echo $USAGE
    exit 1
fi
DEPOT_TOOLS="$1"

FETCH="${DEPOT_TOOLS}/fetch"
GCLIENT="${DEPOT_TOOLS}/gclient"
GN="${DEPOT_TOOLS}/gn"

case $OS_ARCH in
  aarch64)
    V8_TARGET_CPU=arm64
    CLANG_TARGET=aarch64-unknown-linux-gnu
    ;;
  x86_64)
    V8_TARGET_CPU=x64
    case $OS_NAME in
      Linux)
        CLANG_TARGET=x86_64-unknown-linux-gnu
        ;;
      Darwin)
        CLANG_TARGET=x86_64-apple-darwin25.1.0
        ;;
      *)
        echo " Unsupported OS: $OS_NAME"
        exit 1
        ;;
    esac
    ;;
  *)
    echo " Unsupported arch: $OS_ARCH"
    exit 1
    ;;
esac

V8_CONF_FILE=${V8_CONF_DIR}/${V8_TARGET_CPU}.args.gn

if [ ! -e "$SRC_DIR" ]; then
  echo "Getting sources using depot tools"
  mkdir -p "$SRC_DIR"
  cd "$SRC_DIR" && $FETCH v8
  cd $V8_REPO && $GCLIENT sync -r $V8_REVISION
  if [ "$OS_NAME" = "Linux" ]; then
    # Always install the arm64 sysroot to ensure it's there for cross compilation
    cd $V8_REPO && build/linux/sysroot_scripts/install-sysroot.py --arch=arm64
  fi
fi

if [ ! -e "$BUILD_DIR" ]; then
  echo "Building V8"
  mkdir -p $BUILD_DIR
  cp $V8_CONF_FILE $BUILD_DIR/args.gn
  cd $V8_REPO && \
    $GN gen $BUILD_DIR && \
    ninja -C $BUILD_DIR
fi

V8_REPACK_V8_MONOLITH_DIR=$BUILD_DIR/v8_monolith_repack
V8_MONOLITH_RLIB=$V8_REPACK_V8_MONOLITH_DIR/libv8_monolith_rlib.a

if [ ! -e "$V8_MONOLITH_RLIB" ]; then
  echo "Repackaging rust libraries"
  V8_MONOLITH_LIB_NINJA=$BUILD_DIR/obj/v8_monolith.ninja
  V8_MONOLITH_LIB_RLIB_DEPS=$(cat $V8_MONOLITH_LIB_NINJA | awk 'BEGIN { FOUND=0 }; /build obj\/libv8_monolith.a:/ { FOUND=1 }; FOUND && /  rlibs =/ { print; FOUND=0 }' | sed 's/.*=[ ]*//')

  if [[ -z "$V8_MONOLITH_LIB_RLIB_DEPS" ]]; then
    V8_MONOLITH_RLIB=
  else
    mkdir -p $V8_REPACK_V8_MONOLITH_DIR/obj
    cd $V8_REPACK_V8_MONOLITH_DIR/obj && \
    for rlib in $V8_MONOLITH_LIB_RLIB_DEPS; do \
        mkdir -p $(basename $rlib); \
        (cd $(basename $rlib) && ar x "$BUILD_DIR"/$rlib); \
    done

    (cd $V8_REPACK_V8_MONOLITH_DIR/obj && ar -r -c -D $V8_MONOLITH_RLIB.tmp $(find . -name "*.o"))
    mv $V8_MONOLITH_RLIB.tmp $V8_MONOLITH_RLIB
  fi
fi

# repack these thin archives (index + links to local .o objects) into real archives
REPACK_CPP_LIBS_DIR=$BUILD_DIR/cpplib_repack
REPACK_CPP_LIB=$REPACK_CPP_LIBS_DIR/libc++.a
REPACK_CPP_ABI_LIB=$REPACK_CPP_LIBS_DIR/libc++abi.a

if [ ! -e "$REPACK_CPP_LIB" ]; then
  echo "Repackaging libc++.a"
  mkdir -p $REPACK_CPP_LIBS_DIR
  cd $REPACK_CPP_LIBS_DIR && ar -t $BUILD_DIR/obj/buildtools/third_party/libc++/libc++.a | xargs ar -r -c -D $REPACK_CPP_LIB.tmp
  mv $REPACK_CPP_LIB.tmp $REPACK_CPP_LIB
fi

if [ ! -e "$REPACK_CPP_ABI_LIB" ]; then
  echo "Repackaging libc++abi.a"
  mkdir -p $REPACK_CPP_LIBS_DIR
  cd $REPACK_CPP_LIBS_DIR && ar -t $BUILD_DIR/obj/buildtools/third_party/libc++abi/libc++abi.a | xargs ar -r -c -D $REPACK_CPP_ABI_LIB.tmp
  mv $REPACK_CPP_ABI_LIB.tmp $REPACK_CPP_ABI_LIB
fi

mkdir -p $IMAGE_DIR
# Extract what we need into an image
echo "Copying v8 libs to image"
mkdir -p "$IMAGE_DIR/lib"
cp -a $BUILD_DIR/obj/libv8_monolith.a $IMAGE_DIR/lib/
cp -a $REPACK_CPP_LIB $IMAGE_DIR/lib/
cp -a $REPACK_CPP_ABI_LIB $IMAGE_DIR/lib/
cp -a $V8_REPO/third_party/llvm-build/Release+Asserts/lib/clang/22/lib/${CLANG_TARGET}/libclang_rt.builtins.a $IMAGE_DIR/lib/
if [[ ! -z "$V8_MONOLITH_RLIB" ]]; then
  cp -a $V8_MONOLITH_RLIB $IMAGE_DIR/lib/
fi

echo "Copying includes to image"
# V8 headers
mkdir -p $IMAGE_DIR/include
cp -r -a $V8_REPO/include/v8*.h $IMAGE_DIR/include/
mkdir -p $IMAGE_DIR/include/inspector
cp -a $BUILD_DIR/gen/include/inspector/*.h $IMAGE_DIR/include/inspector
# libc++ headers
cp -a $V8_REPO/third_party/libc++/src/include/* $IMAGE_DIR/include/
cp -a $V8_REPO/buildtools/third_party/libc++/__config_site $IMAGE_DIR/include/
cp -a $V8_REPO/buildtools/third_party/libc++/__assertion_handler $IMAGE_DIR/include/

echo "Copying toolchain to image"
mkdir -p $IMAGE_DIR/bin
cp $V8_REPO/third_party/llvm-build/Release+Asserts/bin/clang++ $IMAGE_DIR/bin/
cp $V8_REPO/third_party/llvm-build/Release+Asserts/bin/lld $IMAGE_DIR/bin/
cp $V8_REPO/third_party/llvm-build/Release+Asserts/bin/ld.lld $IMAGE_DIR/bin/
cp $V8_REPO/third_party/llvm-build/Release+Asserts/bin/ld64.lld $IMAGE_DIR/bin/
cp $V8_REPO/third_party/llvm-build/Release+Asserts/bin/lld-link $IMAGE_DIR/bin/

echo "Copying lib/clang/*/include to image"
mkdir -p $IMAGE_DIR/lib/clang/22/include
cp -a $V8_REPO/third_party/llvm-build/Release+Asserts//lib/clang/22/include/. \
    $IMAGE_DIR/lib/clang/22/include/

echo "Copying sysroot"
mkdir -p $IMAGE_DIR/bin
cp -a $V8_REPO/build/linux/debian_bullseye_amd64-sysroot $IMAGE_DIR/sysroot/

# Copy this script to image
echo "Copying this script to image"
cp $SCRIPT_DIR/$SCRIPT_FILE $IMAGE_DIR
cp -a $V8_CONF_DIR $IMAGE_DIR

# Create bundle
echo "Creating $OUTPUT_DIR/$BUNDLE_NAME"
cd $IMAGE_DIR
tar zcf $OUTPUT_DIR/$BUNDLE_NAME *