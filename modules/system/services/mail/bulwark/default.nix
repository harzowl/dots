# Bulwark — a webmail client for Stalwart Mail Server. It talks to Stalwart
# over JMAP and puts mail, calendar, contacts and files behind one login, run
# from the `ghcr.io/bulwarkmail/webmail` image. The container listens on :3000;
# the published host port is what the front proxy reaches.
#
# Configuration is passed as environment variables through `settings`
# (camelCase -> UPPER_SNAKE, `jmapServerUrl` -> `JMAP_SERVER_URL`). Set at least
# `jmapServerUrl`; doing so also disables the first-launch setup wizard, so pair
# it with the remaining values (`appName`, `sessionSecret`, …) for an
# env-driven, reproducible deployment.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "bulwark";
    image = "ghcr.io/bulwarkmail/webmail:latest";
    ports = [ "3000:3000" ];
    # The four state directories the image persists (see its docker-compose.yml):
    # settings, admin config, admin runtime state, and telemetry.
    volumes = [
      "/var/lib/bulwark/settings:/app/data/settings"
      "/var/lib/bulwark/admin:/app/data/admin"
      "/var/lib/bulwark/admin-state:/app/data/admin-state"
      "/var/lib/bulwark/telemetry:/app/data/telemetry"
    ];
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "mail"
    "bulwark"
  ];
  description = "Bulwark webmail (OCI container)";

  options =
    { lib, ... }:
    mkDockerService.options { inherit lib defaults; };

  toConfig = args: cfg: mkDockerService.config { spec = cfg; inherit defaults; } args;
}
