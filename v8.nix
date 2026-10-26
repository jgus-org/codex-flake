{
  fetchurl,
  lib,
  stdenv,
}:
{
  archive,
  srcBinding,
  version,
}:
let
  inherit (stdenv.hostPlatform) system;
  rustcTarget = stdenv.hostPlatform.rust.rustcTarget;
  release = file: "https://github.com/denoland/rusty_v8/releases/download/v${version}/${file}";
  meta = {
    inherit version;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
in
{
  librusty_v8 = fetchurl {
    inherit meta;
    name = "librusty_v8-${version}";
    sha256 = archive.${system};
    url = release "librusty_v8_release_${rustcTarget}.a.gz";
  };
  librusty_v8_src_binding = fetchurl {
    inherit meta;
    name = "src_binding-${version}";
    sha256 = srcBinding.${system};
    url = release "src_binding_release_${rustcTarget}.rs";
  };
}
