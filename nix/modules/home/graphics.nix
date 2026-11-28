# 3D modelling and path-traced rendering on the RTX. nixpkgs builds Blender without CUDA, and its
# CUDA build is only in cache.nixos-cuda.org, which the Nix daemon does not trust (compiling it
# locally takes hours). blender.org's own build ships precompiled CUDA and OptiX kernels and needs
# only the driver's libcuda/libnvoptix, which genericLinux exposes in /run/opengl-driver. It is
# built for any glibc 2.28+ distribution, so it runs in an FHS environment of Nix libraries.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  version = "5.3.0";
  unpacked = pkgs.stdenvNoCC.mkDerivation {
    pname = "blender-bin-unpacked";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://download.blender.org/release/Blender${lib.versions.majorMinor version}/blender-${version}-linux-x64.tar.xz";
      sha256 = "dacb8264197a3f7fda6001285a5a506fc97ee943881261c2c3bd63c882f22e05";
    };
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p $out
      cp -r . $out/blender
    '';
  };
  fhs = pkgs.buildFHSEnv {
    name = "blender";
    targetPkgs =
      p: with p; [
        libGL
        libglvnd
        libx11
        libxi
        libxxf86vm
        libxfixes
        libxrender
        libxext
        libxkbcommon
        libsm
        libice
        wayland
        libdecor
        dbus
        fontconfig
        freetype
        zlib
        libxcrypt-legacy
        vulkan-loader
        pulseaudio
        alsa-lib
      ];
    # The driver's CUDA, OptiX and GL libraries, matched to the running kernel module.
    profile = ''
      export LD_LIBRARY_PATH=/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    '';
    runScript = "${unpacked}/blender/blender";
  };
  blender = pkgs.symlinkJoin {
    name = "blender-${version}";
    # Also headless: blender -b scene.blend -P script.py renders and scripts without a display.
    paths = [ fhs ];
    postBuild = ''
      install -Dm644 ${unpacked}/blender/blender.svg $out/share/icons/hicolor/scalable/apps/blender.svg
      install -Dm644 ${unpacked}/blender/blender.desktop $out/share/applications/blender.desktop
      substituteInPlace $out/share/applications/blender.desktop --replace-fail "Exec=blender" "Exec=$out/bin/blender"
    '';
  };
in
{
  options.personal.graphics.enable = lib.mkEnableOption "Blender with CUDA/OptiX rendering";
  config = lib.mkIf (config.personal.graphics.enable && pkgs.stdenv.hostPlatform.isx86_64) {
    home.packages = [ blender ];
  };
}
