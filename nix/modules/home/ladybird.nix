# Ladybird's master branch, which the flake's ladybird input pins: `nix flake update ladybird`
# moves it. This reuses the nixpkgs recipe and replaces what master has outgrown. A bump can need
# new versions of the dependencies below; upstream's overlay ports and Flatpak manifest name them.
{
  lib,
  stdenv,
  stdenvNoCC,
  cmake,
  fetchurl,
  ladybird,
  rustPlatform,
  unzip,
  src,
}:
let
  ports = "Meta/CMake/vcpkg/overlay-ports";

  zmij = stdenv.mkDerivation {
    pname = "zmij";
    version = "1.2";
    src = fetchurl {
      url = "https://github.com/vitaut/zmij/archive/refs/tags/v1.2.tar.gz";
      sha512 = "f7c73c6cadb5588e717feac96ea6c4b0eb0bd1317b16008e3fe761af265808832ea03b2bc97b188200a5e14726d229fc589afaafee87f59fc290a6266a2b2a92";
    };
    patches = [ "${src}/${ports}/zmij/001-explicit-array-sizes.patch" ];
    nativeBuildInputs = [ cmake ];
    cmakeFlags = [
      "-DZMIJ_TEST=OFF"
      "-DZMIJ_EXAMPLE=OFF"
    ];
  };

  # Header-only, and from a commit of LLVM's main branch until LLVM 24 releases it.
  llvm-libc-headers = stdenvNoCC.mkDerivation {
    pname = "llvm-libc-headers";
    version = "0-unstable-e5416942";
    src = fetchurl {
      url = "https://github.com/llvm/llvm-project/archive/e54169423e7ee5d8b41c2f1b6f7a59000c901ee0.tar.gz";
      sha256 = "db3ee51752d716118e3ff1109c7920a32dfc29bd414112e8d18ff6280e608c1c";
    };
    unpackCmd = ''tar xzf "$curSrc" --wildcards '*/libc/*' '';
    installPhase = ''
      cd libc
      find hdr include shared src/__support src/string/memory_utils -name '*.h' \
        -exec install -D -m644 {} $out/include/llvm-libc/{} \;
    '';
  };

  pdfjs = stdenvNoCC.mkDerivation {
    pname = "pdfjs-ladybird";
    version = "6.4.299";
    src = fetchurl {
      url = "https://github.com/mozilla/pdf.js/releases/download/v6.4.299/pdfjs-6.4.299-dist.zip";
      sha512 = "ed520ebaa60242f68c27c47eece48887fb862bea977f873212f1bf7556ef562adcb33e4a1daac9fbb63e5fe882dc16ba9226e29d467fda25ee0101ba2ea930de";
    };
    nativeBuildInputs = [ unzip ];
    sourceRoot = ".";
    patches = [ "${src}/${ports}/pdfjs/0001-ladybird-embed.patch" ];
    installPhase = ''
      mkdir -p $out/share/pdfjs
      cp -r build web $out/share/pdfjs
    '';
  };
in
ladybird.overrideAttrs (old: {
  version = "0-unstable-${src.shortRev}";
  inherit src;
  cargoDeps = rustPlatform.importCargoLock { lockFile = "${src}/Cargo.lock"; };
  # nixpkgs' two patches are fixed upstream. Ours lets the GPU sandbox reach the drivers.
  patches = [ ./ladybird-nix-gpu-drivers.patch ];
  postPatch = ''
    sed -i '/iconutil/d' UI/CMakeLists.txt

    # Upstream suffixes its reduced FFmpeg build to coexist with system FFmpeg.
    substituteInPlace Meta/CMake/check_for_dependencies.cmake \
      --replace-fail libavcodec-ladybird libavcodec \
      --replace-fail libavutil-ladybird libavutil \
      --replace-fail libswresample-ladybird libswresample

    # Don't set absolute paths in RPATH
    substituteInPlace Meta/CMake/lagom_install_options.cmake \
      --replace-fail "\''${CMAKE_INSTALL_BINDIR}" "bin" \
      --replace-fail "\''${CMAKE_INSTALL_LIBDIR}" "lib"
  '';
  buildInputs = old.buildInputs ++ [
    zmij
    llvm-libc-headers
  ];
  cmakeFlags = old.cmakeFlags ++ [ (lib.cmakeFeature "PDFJS_DIR" "${pdfjs}/share/pdfjs") ];
})
