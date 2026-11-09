# Rendered previews in Dolphin for documents that are text underneath: Markdown as a
# GitHub-style page with highlighted code, CSV and TSV as a spreadsheet grid, iCalendar files as
# an event card and Jupyter notebooks as nbviewer shows them (document-thumbnailer/). Each kind
# is a freedesktop thumbnailer, which KIO runs like its own plugins and prefers over
# textthumbnail as it names the exact type. A native Qt program needs no resident renderer:
# each preview takes a few tens of milliseconds.
{
  lib,
  stdenv,
  cmake,
  qt6,
  kdePackages,
}:
let
  # Thumbnailer id (as Dolphin's PreviewSettings names it) -> renderer kind and MIME types.
  kinds = {
    spawnkit-markdown = {
      kind = "markdown";
      mimeTypes = [
        "text/markdown"
        "text/x-markdown"
      ];
    };
    spawnkit-csv = {
      kind = "csv";
      mimeTypes = [ "text/csv" ];
    };
    spawnkit-tsv = {
      kind = "tsv";
      mimeTypes = [ "text/tab-separated-values" ];
    };
    spawnkit-calendar = {
      kind = "calendar";
      mimeTypes = [ "text/calendar" ];
    };
    spawnkit-notebook = {
      kind = "notebook";
      mimeTypes = [ "application/x-ipynb+json" ];
    };
  };
in
stdenv.mkDerivation {
  pname = "spawnkit-document-thumbnailer";
  version = "1";
  src = ./document-thumbnailer;
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
  ''
  + lib.concatStrings (
    lib.mapAttrsToList (id: k: ''
      cat >$out/share/thumbnailers/${id}.thumbnailer <<EOT
      [Thumbnailer Entry]
      TryExec=$out/bin/spawnkit-document-thumbnail
      Exec=$out/bin/spawnkit-document-thumbnail ${k.kind} %s %i %o
      MimeType=${lib.concatMapStrings (m: "${m};") k.mimeTypes}
      EOT
    '') kinds
  );
  passthru.thumbnailerIds = builtins.attrNames kinds;
  meta.mainProgram = "spawnkit-document-thumbnail";
}
