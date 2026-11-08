#!/bin/sh
# build.sh DIR VERSION PREFIX: build Dolphin from DIR/dolphin-VERSION.tar.xz with DIR/dolphin.patch
# and install it into PREFIX, which /usr/local/bin/dolphin and the FileManager1 D-Bus service use.
set -eu
dir=$1 version=$2 prefix=$3
rm -rf "$dir/src" "$dir/build"
mkdir "$dir/src"
tar -xJf "$dir/dolphin-$version.tar.xz" -C "$dir/src" --strip-components=1
patch -d "$dir/src" -p1 < "$dir/dolphin.patch"
cmake -S "$dir/src" -B "$dir/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="$prefix" -Wno-dev
# One compile job per 1.5 GB available, at most one per CPU: unbounded, ninja runs a job per CPU,
# and with the Windows VM holding its memory, 32 compilers can push the OOM killer onto the desktop.
jobs=$(awk -v cpus="$(nproc)" '/^MemAvailable:/ { j = int($2 / 1572864); print (j < 1 ? 1 : j > cpus ? cpus : j) }' /proc/meminfo)
ninja -C "$dir/build" -j "$jobs"
rm -rf "$prefix"
cmake --install "$dir/build"
