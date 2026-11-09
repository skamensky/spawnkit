#!/bin/sh
# build.sh DIR VERSION PLUGIN_DIR: build Plasma's notifications applet from
# DIR/plasma-workspace-VERSION.tar.xz as tech.shmuel.notifications with DIR/notifications.patch,
# and install it into PLUGIN_DIR.
set -eu
dir=$1 version=$2 plugins=$3
rm -rf "$dir/src" "$dir/build"
mkdir "$dir/src"
tar -xJf "$dir/plasma-workspace-$version.tar.xz" -C "$dir/src" --strip-components=1 \
  "plasma-workspace-$version/applets/notifications"
cp "$dir/CMakeLists.txt" "$dir/src/"
patch -d "$dir/src/applets/notifications" -p1 < "$dir/notifications.patch"
# metadata.json keeps X-Plasma-Provides org.kde.plasma.notifications: the fork is still Plasma's
# notification applet to everything that asks for one.
grep -rl org.kde.plasma.notifications "$dir/src/applets/notifications" --exclude=metadata.json |
  xargs sed -i 's/org\.kde\.plasma\.notifications/tech.shmuel.notifications/g'
sed -i '0,/"Name": "Notifications"/s//"Name": "Spawnkit Notifications"/' "$dir/src/applets/notifications/metadata.json"
cmake -S "$dir/src" -B "$dir/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -Wno-dev
# One compile job per 1.5 GB available, at most one per CPU (see plasma_taskmanager's build.sh).
jobs=$(awk -v cpus="$(nproc)" '/^MemAvailable:/ { j = int($2 / 1572864); print (j < 1 ? 1 : j > cpus ? cpus : j) }' /proc/meminfo)
ninja -C "$dir/build" -j "$jobs"
install -D -m 0644 "$dir/build/bin/plasma/applets/tech.shmuel.notifications.so" "$plugins/tech.shmuel.notifications.so"
