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
    { lib, pkgs, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      # slskd's config is the nested `slskd.yml`, and its environment names do
      # not follow the YAML path (`soulseek.username` is `SLSKD_SLSK_USERNAME`),
      # so the file is generated from this structure instead of the env vars
      # `mkDockerService.settings` would produce.
      settings = lib.mkOption {
        inherit ((pkgs.formats.yaml { })) type;
        default = { };
        description = ''
          Contents of slskd's `slskd.yml`. **Not for secrets** (the Nix store is
          world-readable): pass those with `environmentFiles` — `SLSKD_PASSWORD`,
          `SLSKD_SLSK_USERNAME`, `SLSKD_SLSK_PASSWORD` — which slskd overlays on
          this file.
        '';
      };

      # The container's own, non-secret environment (e.g. `tz`), mapped
      # camelCase -> UPPER_SNAKE exactly like `mkDockerService.settings`.
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Extra container environment variables, e.g. `{ tz = \"Europe/Warsaw\"; }`.";
      };
    };

  toConfig =
    args: cfg:
    let
      config = (args.pkgs.formats.yaml { }).generate "slskd.yml" cfg.settings;
    in
    mkDockerService.config {
      spec = cfg // {
        volumes = cfg.volumes ++ [ "${config}:/app/slskd.yml:ro" ];
        settings = cfg.environment;
      };
      inherit defaults;
    } args;
}
