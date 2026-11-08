# Gives a Nix Qt 6 app the desktop's look. Nix Qt loads only its own plugins, so without these the
# app draws with Qt's Fusion style and a default font, ignoring Plasma's widget style (Kvantum or
# Breeze), fonts, colours and file dialogs. The plugins come from the same nixpkgs as the app's Qt.
# Apps that bundle their own Qt (Zoom) must not get these plugins.
{
  kdePackages,
  lib,
  makeWrapper,
  symlinkJoin,
}:
pkg:
symlinkJoin {
  pname = lib.getName pkg;
  version = lib.getVersion pkg;
  paths = [ pkg ];
  nativeBuildInputs = [ makeWrapper ];
  passthru = (pkg.passthru or { }) // {
    unwrapped = pkg;
  };
  inherit (pkg) meta;
  postBuild = ''
    for f in $out/bin/*; do
      case "''${f##*/}" in .*) continue ;; esac
      [ -x "$f" ] && [ ! -d "$f" ] || continue
      wrapProgram "$f" --prefix QT_PLUGIN_PATH : ${
        lib.makeSearchPath "lib/qt-6/plugins" [
          kdePackages.plasma-integration
          kdePackages.qtstyleplugin-kvantum
          kdePackages.breeze
        ]
      }
    done
    # Launchers and D-Bus activation that name the unwrapped program start the wrapper instead.
    for f in $out/share/applications/*.desktop $out/share/dbus-1/services/*.service; do
      [ -e "$f" ] && grep -q '${pkg}/bin/' "$f" || continue
      target=$(readlink -f "$f")
      rm "$f"
      sed 's|${pkg}/bin/|'"$out"'/bin/|g' "$target" > "$f"
    done
  '';
}
