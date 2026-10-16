#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
test_home="$test_root/home"
mkdir -p "$test_home" "$test_root/runtime"
chmod 700 "$test_root/runtime"
activation=$(nix --extra-experimental-features 'nix-command flakes' build \
  --impure --no-link --print-out-paths --file "$repo/tests/activation.nix" \
  --argstr flake "path:$repo" --argstr testHome "$test_home")

# Refuse an unmanaged shell file without changing it.
printf '%s\n' 'untouched shell config' > "$test_home/.bashrc"
if env HOME="$test_home" USER=shmuel XDG_RUNTIME_DIR="$test_root/runtime" \
  XDG_CONFIG_HOME="$test_home/.config" XDG_DATA_HOME="$test_home/.local/share" \
  XDG_STATE_HOME="$test_home/.local/state" XDG_CACHE_HOME="$test_home/.cache" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$test_root/no-bus" \
  "$activation/activate" > "$test_root/collision.log" 2>&1; then
  printf '%s\n' 'ERROR: activation should have refused an unmanaged .bashrc' >&2
  exit 1
fi
grep -q 'untouched shell config' "$test_home/.bashrc"
mv "$test_home/.bashrc" "$test_root/preserved-bashrc"

for iteration in 1 2; do
  env HOME="$test_home" USER=shmuel XDG_RUNTIME_DIR="$test_root/runtime" \
    XDG_CONFIG_HOME="$test_home/.config" XDG_DATA_HOME="$test_home/.local/share" \
    XDG_STATE_HOME="$test_home/.local/state" XDG_CACHE_HOME="$test_home/.cache" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$test_root/no-bus" \
    "$activation/activate" > "$test_root/activation-$iteration.log" 2>&1 || {
      cat "$test_root/activation-$iteration.log" >&2
      exit 1
    }
done
test -L "$test_home/.bashrc"
test -L "$test_home/.codex/AGENTS.md"
test -L "$test_home/.claude/skills/setup-assistant"
test -L "$test_home/.config/mise/config.toml"
env -u __HM_SESS_VARS_SOURCED -u __HM_PROFILE_SOURCED \
  HOME="$test_home" USER=shmuel \
  XDG_CONFIG_HOME="$test_home/.config" XDG_DATA_HOME="$test_home/.local/share" \
  XDG_STATE_HOME="$test_home/.local/state" XDG_CACHE_HOME="$test_home/.cache" \
  PATH="$test_home/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin" \
  bash --noprofile --norc "$repo/tests/noninteractive.sh"
printf '%s\n' 'Isolated activation passed twice; unmanaged .bashrc preserved; noninteractive Node, Python and uv verified.'
