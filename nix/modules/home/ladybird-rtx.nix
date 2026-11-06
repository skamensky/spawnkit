# Runs Ladybird on the NVIDIA GPU. Left alone it paints on the GPU that drives the display and ANGLE
# takes glvnd's default vendor, both Intel here. While the Windows VM owns the GPU, the NVIDIA driver
# has no device, so Ladybird stays on Intel.
{
  ladybird,
  makeWrapper,
  symlinkJoin,
}:
symlinkJoin {
  pname = "ladybird-rtx";
  inherit (ladybird) version;
  paths = [ ladybird ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    rm $out/bin/Ladybird
    makeWrapper ${ladybird}/bin/Ladybird $out/bin/Ladybird --run '
      for gpu in /proc/driver/nvidia/gpus/*; do
        if [ -e "$gpu" ]; then
          export VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json
          export __EGL_VENDOR_LIBRARY_FILENAMES=/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json
        fi
      done
    '
  '';
}
