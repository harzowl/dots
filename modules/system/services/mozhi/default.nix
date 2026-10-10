let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
  mkDockerContainer = import ../../../../lib/mkDockerContainer.nix;
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
        type = lib.types.submodule mkDockerContainer.options;
        default = {
          name = "mozhi";
          image = "codeberg.org/aryak/mozhi:latest";
          ports = [ 3000 ];
        };
        description = ''
          The container spec (see dots' `mkDockerContainer`); `name` and `image`
          default to Mozhi, and anything else can be overridden — e.g.
          `container.environment = { MOZHI_DEFAULT_ENGINE = "google"; };`.
        '';
      };
    };

  toConfig = args: cfg: mkDockerContainer.config cfg.container args;
}
