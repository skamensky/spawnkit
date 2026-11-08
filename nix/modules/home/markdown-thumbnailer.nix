# Rendered Markdown previews in Dolphin: a freedesktop thumbnailer, which KIO runs like its
# own plugins and prefers over textthumbnail for text/markdown, that draws the file as a page
# in GitHub's dialect with highlighted code (markdown-thumbnailer/main.cpp). A native Qt
# program needs no resident renderer: each preview takes a few tens of milliseconds.
{
  stdenv,
  cmake,
  qt6,
  kdePackages,
}:
stdenv.mkDerivation {
  pname = "spawnkit-markdown-thumbnailer";
  version = "1";
  src = ./markdown-thumbnailer;
  nativeBuildInputs = [
    cmake
    qt6.wrapQtAppsHook
  ];
  buildInputs = [
    qt6.qtbase
    kdePackages.syntax-highlighting
  ];
  postInstall = ''
    mkdir -p $out/share/thumbnailers
    cat >$out/share/thumbnailers/spawnkit-markdown.thumbnailer <<EOT
    [Thumbnailer Entry]
    TryExec=$out/bin/spawnkit-markdown-thumbnail
    Exec=$out/bin/spawnkit-markdown-thumbnail %s %i %o
    MimeType=text/markdown;text/x-markdown;
    EOT
  '';
  meta.mainProgram = "spawnkit-markdown-thumbnail";
}
