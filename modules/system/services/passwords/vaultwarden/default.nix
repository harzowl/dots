let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "vaultwarden";
    image = "vaultwarden/server:latest";
    ports = [ "8081:80" ];
    volumes = [ "/var/lib/vaultwarden:/data" ];
    settings = {
      signupsAllowed = false;
    };
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "passwords"
    "vaultwarden"
  ];
  description = "Vaultwarden password manager (OCI container)";

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
