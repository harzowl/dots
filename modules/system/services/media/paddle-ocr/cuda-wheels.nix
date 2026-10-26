{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  cudaPackages,
}:
let
  # Keep these versions aligned with torch-bin's CUDA wheel (2.11.0+cu128).
  mkCudaWheel =
    {
      pname,
      version,
      url,
      hash,
      libDir,
      postInstall ? "",
    }:
    stdenv.mkDerivation {
      inherit pname version postInstall;

      src = fetchurl {
        inherit url hash;
        name = "${pname}-${version}.whl";
      };

      nativeBuildInputs = [
        unzip
        autoPatchelfHook
      ];

      buildInputs = [
        cudaPackages.cuda_cudart
        cudaPackages.cuda_nvrtc
        cudaPackages.libnvjitlink
        stdenv.cc.cc.lib
      ];

      autoPatchelfIgnoreMissingDeps = [
        "libcuda.so.1"
        "libnvidia-ml.so.1"
      ];

      dontConfigure = true;
      dontBuild = true;
      dontStrip = true;

      unpackPhase = ''
        runHook preUnpack
        unzip -q "$src" -d source
        runHook postUnpack
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out/lib"
        cp -a "source/${libDir}/." "$out/lib/"
        runHook postInstall
      '';

      meta = {
        description = "${pname} ${version} libraries from the prebuilt PyPI wheel";
        platforms = [ "x86_64-linux" ];
        license = lib.licenses.unfreeRedistributable;
      };
    };
in
{
  # nixpkgs builds these CUDA libraries from source; the PyPI wheels carry the
  # same versions and keep the prebuilt OCR environment compile-free.
  nccl = mkCudaWheel {
    pname = "nvidia-nccl-cu12";
    version = "2.28.7";
    url = "https://files.pythonhosted.org/packages/73/61/fa7a709b3f2d57038d99c220eba816b21466567835e4d46300ff674ed975/nvidia_nccl_cu12-2.28.7-py3-none-manylinux_2_18_x86_64.whl";
    hash = "sha256-KeojbQL9V+pfFFN+lZhdGQxsoGeh66Lisxne691szcM=";
    libDir = "nvidia/nccl/lib";
  };

  nvshmem = mkCudaWheel {
    pname = "nvidia-nvshmem-cu12";
    version = "3.6.5";
    url = "https://files.pythonhosted.org/packages/9e/da/36fa8307cc40889307fed415d70b67d35ec330ffce889a9c03cf8f616cfa/nvidia_nvshmem_cu12-3.6.5-py3-none-manylinux2014_x86_64.manylinux_2_17_x86_64.whl";
    hash = "sha256-+G2zXxztIaeQ+iVdyufbiZi/hlWpXnbAM6ZXQZCzmOQ=";
    libDir = "nvidia/nvshmem/lib";
    # The transport/bootstrap plugins pull MPI, UCX, libfabric and PMIx; the
    # single-GPU OCR path never loads them.
    postInstall = ''
      rm -f "$out/lib"/nvshmem_bootstrap_* "$out/lib"/nvshmem_transport_*
    '';
  };
}
