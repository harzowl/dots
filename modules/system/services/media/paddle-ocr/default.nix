let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "media"
    "paddle-ocr"
  ];
  description = "PaddleOCR-VL local OCR service";

  options =
    { lib, ... }:
    {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8765;
        description = "TCP port for the local OCR API.";
      };

      python = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Python environment containing PaddleOCR-VL dependencies. Defaults to a Nix-built environment.";
      };

      cacheDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/paddle-ocr";
        description = "Model and cache directory.";
      };

      model = lib.mkOption {
        type = lib.types.str;
        default = "PaddlePaddle/PaddleOCR-VL";
        description = "Hugging Face model id.";
      };

      prompt = lib.mkOption {
        type = lib.types.str;
        default = "OCR:";
        description = "PaddleOCR-VL prompt.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "User running the OCR service.";
      };

      cudaSupport = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Build the OCR Python environment with CUDA support.";
      };

      prebuilt = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Use prebuilt CUDA wheels (torch-bin, torchvision-bin) instead of compiling them.";
      };

      cudaCapabilities = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "CUDA compute capabilities to build source-built CUDA packages for.";
      };

      libraryPath = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra directories for `LD_LIBRARY_PATH` (CUDA, GCC runtime, ...).";
      };
    };

  toConfig =
    {
      lib,
      pkgs,
      ...
    }:
    cfg:
    let
      script = pkgs.writeText "paddle-ocr-server.py" (builtins.readFile ./server.py);
      pgsrip = pkgs.callPackage ./pgsrip.nix { };
      cudaWheels = pkgs.callPackage ./cuda-wheels.nix { };
      pythonBase =
        if cfg.prebuilt then
          pkgs.python3.override {
            packageOverrides = final: prev: {
              # torch 2.11 pulls cuda-bindings for the CuTe DSL backend; the OCR
              # server never imports it, and no binary cache carries the unfree
              # build.
              torch-bin = prev.torch-bin.overridePythonAttrs (old: {
                dependencies = builtins.filter (dep: (dep.pname or "") != "cuda-bindings") old.dependencies;
                # nixpkgs builds NCCL/NVSHMEM (and gdrcopy, which only
                # libnvshmem needs) from source; the wheels carry the same libs.
                buildInputs = map (
                  dep:
                  if (dep.pname or "") == "nccl" then
                    cudaWheels.nccl
                  else if (dep.pname or "") == "libnvshmem" then
                    cudaWheels.nvshmem
                  else
                    dep
                ) old.buildInputs;
                dontCheckRuntimeDeps = true;
              });
              torch = final.torch-bin;
              torchvision = final.torchvision-bin;
              # transformers 4.55 pulls both; the wheels avoid cargo/rustc.
              tokenizers = prev.buildPythonPackage {
                pname = "tokenizers";
                version = "0.22.2";
                format = "wheel";

                src = pkgs.fetchurl {
                  url = "https://files.pythonhosted.org/packages/2e/76/932be4b50ef6ccedf9d3c6639b056a967a86258c6d9200643f01269211ca/tokenizers-0.22.2-cp39-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
                  hash = "sha256-NpzJ/IzBDLJBQ4c6DZVDi7juJXu4DHGYnj7ikOjXLGc=";
                };

                nativeBuildInputs = [ pkgs.autoPatchelfHook ];
                buildInputs = [
                  pkgs.openssl
                  pkgs.stdenv.cc.cc.lib
                ];

                dependencies = [ final.huggingface-hub ];

                doCheck = false;
                dontCheckRuntimeDeps = true;
                pythonImportsCheck = [ "tokenizers" ];
              };
              safetensors = prev.buildPythonPackage {
                pname = "safetensors";
                version = "0.7.0";
                format = "wheel";

                src = pkgs.fetchurl {
                  url = "https://files.pythonhosted.org/packages/a0/60/429e9b1cb3fc651937727befe258ea24122d9663e4d5709a48c9cbfceecb/safetensors-0.7.0-cp38-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
                  hash = "sha256-2sclKTjwaW3epG9ehV3TE4RE6CI2475HX1SSnwxRDUg=";
                };

                nativeBuildInputs = [ pkgs.autoPatchelfHook ];
                buildInputs = [ pkgs.stdenv.cc.cc.lib ];

                dependencies = [ final.numpy ];

                doCheck = false;
                dontCheckRuntimeDeps = true;
                pythonImportsCheck = [ "safetensors" ];
              };
              # PaddleOCR-VL's remote code was saved with transformers 4.55 and
              # needs huggingface-hub < 1.0; nixpkgs ships newer, incompatible versions.
              huggingface-hub = prev.huggingface-hub.overridePythonAttrs (old: {
                version = "0.36.2";
                src = pkgs.fetchurl {
                  url = "https://files.pythonhosted.org/packages/7c/b7/8cb61d2eece5fb05a83271da168186721c450eb74e3c31f7ef3169fa475b/huggingface_hub-0.36.2.tar.gz";
                  sha256 = "0ypz2pldab87agnlwcsv46lzvb01hpahfw5qlfpzh95j5x6k0d0r";
                };
                # 0.36 requires requests at runtime; the 1.x derivation only lists it
                # for the optional CLI extra. The import check runs the hf wrapper.
                dependencies = old.dependencies ++ [ pkgs.python3Packages.requests ];
                pythonImportsCheck = [ ];
                dontCheckRuntimeDeps = true;
              });
              transformers = prev.transformers.overridePythonAttrs (_old: {
                version = "4.55.0";
                src = pkgs.fetchurl {
                  url = "https://files.pythonhosted.org/packages/27/5d/f7dc746eef83336a6b34197311fe0c1da0d1192f637c726c6a5cf0d83502/transformers-4.55.0.tar.gz";
                  sha256 = "1q9s9wiy4gz0309qm4nckyziw1i3bv2a47hr1nriaynh0n517ahm";
                };
                # nixpkgs' tokenizers is 0.22; 4.55's upper bound is cosmetic for
                # the tokenizer APIs this model uses.
                postPatch = ''
                  substituteInPlace src/transformers/dependency_versions_table.py \
                    --replace-fail '"tokenizers": "tokenizers>=0.21,<0.22"' '"tokenizers": "tokenizers>=0.21,<0.23"'
                '';
                dontCheckRuntimeDeps = true;
              });
            };
          }
        else
          pkgs.python3;
      pythonEnv = pythonBase.withPackages (
        ps: with ps; [
          torch
          torchvision
          transformers
          opencv4
          fastapi
          uvicorn
          pydantic
          pillow
          numpy
          einops
          protobuf
          sentencepiece
          accelerate
          pgsrip
        ]
      );
      python = if cfg.python != null then cfg.python else pythonEnv;
      environment = {
        PADDLE_OCR_MODEL = cfg.model;
        PADDLE_OCR_PROMPT = cfg.prompt;
        PADDLE_OCR_PORT = toString cfg.port;
        HF_HOME = cfg.cacheDir;
        XDG_CACHE_HOME = "${cfg.cacheDir}/cache";
        TMPDIR = "${cfg.cacheDir}/tmp";
      }
      // lib.optionalAttrs (cfg.libraryPath != [ ]) {
        LD_LIBRARY_PATH = lib.concatStringsSep ":" cfg.libraryPath;
      };
    in
    {
      # A global cudaSupport rebuilds every CUDA-capable package (opencv
      # included); the prebuilt wheels already carry CUDA.
      nixpkgs.config = lib.optionalAttrs (!cfg.prebuilt) {
        inherit (cfg) cudaSupport cudaCapabilities;
      };

      systemd = {
        tmpfiles.rules = [
          "d '${cfg.cacheDir}' 0755 ${cfg.user} ${cfg.user} -"
        ];

        services.paddle-ocr = {
          description = "PaddleOCR-VL local OCR service";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

          inherit environment;

          serviceConfig = {
            User = cfg.user;
            WorkingDirectory = cfg.cacheDir;
            ExecStart = "${python}/bin/python3 ${script}";
            Restart = "on-failure";
            RestartSec = 5;
            StandardOutput = "journal";
            StandardError = "journal";
          };
        };
      };

      networking.firewall.interfaces.docker0.allowedTCPPorts = [ cfg.port ];
    };
}
