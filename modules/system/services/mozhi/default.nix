let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../lib/mkDockerService.nix;

  defaults = {
    name = "mozhi";
    image = "codeberg.org/aryak/mozhi:latest";
    ports = [ 3000 ];
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "translate"
    "mozhi"
  ];
  description = "Mozhi translation frontend (OCI container)";

  options =
    { lib, ... }:
    mkDockerService.options { inherit lib defaults; };

  toConfig = args: cfg: mkDockerService.config { spec = cfg; inherit defaults; } args;
}
