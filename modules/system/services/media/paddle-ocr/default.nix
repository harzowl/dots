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
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Python interpreter from an environment containing PaddleOCR-VL, pgsrip, FastAPI and Uvicorn.";
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
      assertions = [
        {
          assertion = cfg.python != null;
          message = "dots.system.services.media.paddle-ocr.python must point to the OCR Python environment.";
        }
      ];

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
            ExecStart = "${cfg.python} ${script}";
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
