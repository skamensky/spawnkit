#!/bin/sh
# build.sh DIR VERSION PLUGIN_DIR: build Plasma's task manager from DIR/plasma-desktop-VERSION.tar.xz
# as tech.shmuel.taskmanager with DIR/taskmanager.patch, and install it into PLUGIN_DIR.
set -eu
dir=$1 version=$2 plugins=$3
rm -rf "$dir/src" "$dir/build"
mkdir "$dir/src"
tar -xJf "$dir/plasma-desktop-$version.tar.xz" -C "$dir/src" --strip-components=1 \
  "plasma-desktop-$version/applets/taskmanager" "plasma-desktop-$version/kcms/recentFiles"
cp "$dir/CMakeLists.txt" "$dir/src/"
patch -d "$dir/src/applets/taskmanager/qml" -p1 < "$dir/taskmanager.patch"
grep -rl org.kde.plasma.taskmanager "$dir/src/applets/taskmanager" |
  xargs sed -i 's/org\.kde\.plasma\.taskmanager/tech.shmuel.taskmanager/g'
sed -i 's/"Name": "Icons-and-Text Task Manager"/"Name": "Spawnkit Task Manager"/' "$dir/src/applets/taskmanager/metadata.json"
cmake -S "$dir/src" -B "$dir/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -Wno-dev
# One compile job per 1.5 GB available, at most one per CPU: unbounded, ninja runs a job per CPU,
# and with the Windows VM holding its memory, 32 compilers can push the OOM killer onto the desktop.
jobs=$(awk -v cpus="$(nproc)" '/^MemAvailable:/ { j = int($2 / 1572864); print (j < 1 ? 1 : j > cpus ? cpus : j) }' /proc/meminfo)
ninja -C "$dir/build" -j "$jobs"
install -D -m 0644 "$dir/build/bin/plasma/applets/tech.shmuel.taskmanager.so" "$plugins/tech.shmuel.taskmanager.so"
