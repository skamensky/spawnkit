# Previews of Word, PowerPoint and Excel files in Dolphin and file dialogs: a freedesktop
# thumbnailer, which KIO runs like its own plugins, that renders the first page through
# ONLYOFFICE's converter, x2t. KDE has no thumbnailer for these formats.
#
# x2t reads the font list ONLYOFFICE writes on its first run (data/fonts/AllFonts.js), whose
# paths point into its sandbox's /usr/share/fonts, so x2t runs under bwrap with the same fonts
# there. Until ONLYOFFICE has run once, there is no list and files keep their icons.
{
  lib,
  writeShellApplication,
  writeTextDir,
  symlinkJoin,
  bubblewrap,
  onlyoffice,
}:
let
  mimeTypes = [
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    "application/vnd.openxmlformats-officedocument.wordprocessingml.template"
    "application/vnd.ms-word.document.macroEnabled.12"
    "application/msword"
    "application/rtf"
    "text/rtf"
    "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
    "application/vnd.ms-powerpoint.presentation.macroEnabled.12"
    "application/vnd.ms-powerpoint"
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    "application/vnd.ms-excel.sheet.macroEnabled.12"
    "application/vnd.ms-excel"
  ];
  command = writeShellApplication {
    name = "spawnkit-office-thumbnail";
    runtimeInputs = [ bubblewrap ];
    text = ''
      # spawnkit-office-thumbnail SIZE INPUT OUTPUT: write INPUT's first page as a PNG that fits
      # in SIZE x SIZE pixels to OUTPUT.
      if [ $# -ne 3 ]; then
        echo "usage: spawnkit-office-thumbnail SIZE INPUT OUTPUT" >&2
        exit 2
      fi
      size=$1 input=$(realpath -- "$2") output=$3
      fonts=''${XDG_DATA_HOME:-$HOME/.local/share}/onlyoffice/desktopeditors/data/fonts/AllFonts.js
      if [ ! -f "$fonts" ]; then
        echo "spawnkit-office-thumbnail: no $fonts; open ONLYOFFICE once to create it" >&2
        exit 1
      fi
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      mkdir "$work/tmp"
      xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
      # Format 1029 is an image; thumbnail format 4 is PNG, keeping the page's aspect.
      cat >"$work/params.xml" <<EOF
      <?xml version="1.0" encoding="utf-8"?>
      <TaskQueueDataConvert>
      <m_sFileFrom>$(xml "$input")</m_sFileFrom>
      <m_sFileTo>$work/page.png</m_sFileTo>
      <m_nFormatTo>1029</m_nFormatTo>
      <m_sAllFontsPath>$(xml "$fonts")</m_sAllFontsPath>
      <m_sTempDir>$work/tmp</m_sTempDir>
      <m_bIsNoBase64>true</m_bIsNoBase64>
      <m_oThumbnail><format>4</format><aspect>1</aspect><first>true</first><width>$size</width><height>$size</height></m_oThumbnail>
      </TaskQueueDataConvert>
      EOF
      bwrap --dev-bind / / --ro-bind ${onlyoffice.fhsenv}/usr/share/fonts /usr/share/fonts -- \
        ${onlyoffice.derivation}/share/desktopeditors/converter/x2t "$work/params.xml" >&2
      mv "$work/page.png" "$output"
    '';
  };
in
symlinkJoin {
  name = "spawnkit-office-thumbnailer";
  paths = [
    command
    (writeTextDir "share/thumbnailers/spawnkit-office.thumbnailer" ''
      [Thumbnailer Entry]
      TryExec=${lib.getExe command}
      Exec=${lib.getExe command} %s %i %o
      MimeType=${lib.concatStringsSep ";" mimeTypes};
    '')
  ];
}
