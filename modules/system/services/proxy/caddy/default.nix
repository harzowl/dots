let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "proxy"
    "caddy"
  ];
  description = "Caddy web server / reverse proxy";

  options =
    { lib, ... }:
    {
      email = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACME account email, forwarded to `services.caddy.email`.";
      };

      virtualHosts = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Sites to serve, forwarded to `services.caddy.virtualHosts`.";
      };

      globalConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Global Caddyfile directives, forwarded to `services.caddy.globalConfig`.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open ports 80 and 443.";
      };
    };

  toConfig =
    args: cfg:
    {
      services.caddy = {
        enable = true;
        inherit (cfg) email globalConfig virtualHosts;
      };

      networking.firewall = args.lib.mkIf cfg.openFirewall {
        allowedTCPPorts = [
          80
          443
        ];
      };
    };
}
