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

      trustedProxies = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          CIDRs allowed to send the PROXY protocol (e.g. the WireGuard mesh a
          front gateway forwards from). Enables the PROXY protocol on every
          non-HTTP listener, so the real client IP survives for SPF/DMARC and
          rate limiting. Leave empty when there is no front proxy.
        '';
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib;
      applyProxy =
        l:
        if (l.protocol or "smtp") == "http" then
          l
        else
          l // {
            proxy = {
              override = true;
              trusted-networks = cfg.trustedProxies;
            };
          };
      settings =
        if cfg.trustedProxies == [ ] then
          cfg.settings
        else
          cfg.settings
          // {
            server = (cfg.settings.server or { }) // {
              listener = lib.mapAttrs (_: applyProxy) (cfg.settings.server.listener or { });
            };
          };
    in
    {
      services.stalwart = {
        enable = true;
        inherit (cfg) stateVersion openFirewall credentials;
        settings = settings;
      };
    };
}
