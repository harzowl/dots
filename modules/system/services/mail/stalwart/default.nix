let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "mail"
    "stalwart"
  ];
  description = "Stalwart mail server";

  options =
    { config, lib, pkgs, ... }:
    {
      stateVersion = lib.mkOption {
        type = lib.types.str;
        default = config.dots.system.stateVersion;
        defaultText = lib.literalExpression "config.dots.system.stateVersion";
        description = "Stalwart module state version, forwarded to `services.stalwart.stateVersion`.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open the TCP ports declared by `services.stalwart.settings.server.listener`.";
      };

      settings = lib.mkOption {
        type = (pkgs.formats.toml { }).type;
        default = { };
        description = "Stalwart configuration, forwarded to `services.stalwart.settings`.";
      };

      credentials = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Secret files exposed to the service as systemd credentials, forwarded to `services.stalwart.credentials`.";
      };
    };

  toConfig =
    _: cfg:
    {
      services.stalwart = {
        enable = true;
        inherit (cfg) stateVersion openFirewall settings credentials;
      };
    };
}
