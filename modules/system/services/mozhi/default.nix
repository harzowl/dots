let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../lib/mkDockerService.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "mozhi"
  ];
  description = "Mozhi translation frontend (OCI container)";

  options =
    { lib, ... }:
    {
      container = lib.mkOption {
        type = lib.types.submodule mkDockerService.options;
        default = {
          name = "mozhi";
          image = "codeberg.org/aryak/mozhi:latest";
          ports = [ 3000 ];
        };
        description = ''
          The container spec (see dots' `mkDockerService`); `name` and `image`
          default to Mozhi, and anything else can be overridden — e.g.
          `container.settings.mozhiDefaultEngine = "google";`.
        '';
      };
    };

  toConfig = args: cfg: mkDockerService.config cfg.container args;
}
