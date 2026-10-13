# slskd — Soulseek client with a web UI (official image), :5030. Only the
# service's own identity lives here; the consumer supplies volumes, the
# environment and how it is fronted.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "slskd";
    image = "slskd/slskd:latest";
    ports = [ "127.0.0.1:5030:5030" ];
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "download"
    "slskd"
  ];
  description = "slskd Soulseek client (OCI container)";

  options =
    { lib, ... }:
    mkDockerService.options { inherit lib defaults; };

  toConfig =
    args: cfg:
    mkDockerService.config {
      spec = cfg;
      inherit defaults;
    } args;
}
