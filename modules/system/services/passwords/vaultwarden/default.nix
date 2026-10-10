# Vaultwarden — a lightweight, Bitwarden-compatible password manager server,
# run from the `vaultwarden/server` image. The container listens on :80; the
# published host port is what `edge`'s Caddy proxies to.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "vaultwarden";
    image = "vaultwarden/server:latest";
    ports = [ "8081:80" ];
    volumes = [ "/var/lib/vaultwarden:/data" ];
    settings = {
      # Set `domain = "https://vault.example.com"` on the host.
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

  toConfig = args: cfg: mkDockerService.config { spec = cfg; inherit defaults; } args;
}
