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

      routes = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              host = lib.mkOption {
                type = lib.types.str;
                description = "Target: a WireGuard mesh member name (resolved to its tunnel IP) or a literal address.";
              };
              port = lib.mkOption { type = lib.types.port; };
              scheme = lib.mkOption {
                type = lib.types.str;
                default = "http";
              };
              domain = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Full hostname; defaults to `<name>.<dots.system.core.domain>`.";
              };
              extraConfig = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "Extra directives in the site block (security headers, CSP, caching, …).";
              };
              proxyConfig = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "Extra directives inside the generated `reverse_proxy` block.";
              };
            };
          }
        );
        default = { };
        description = ''
          Reverse-proxy services: `<name>.<dots.system.core.domain>` →
          `reverse_proxy <scheme>://<host>:<port>`. The domain is taken from the
          host (`dots.system.core.domain`), so it is not repeated per route, and
          a `host` naming a WireGuard mesh member resolves to that member's
          tunnel IP.
        '';
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
    let
      inherit (args) lib;
      domain = args.config.dots.system.core.domain;
      # A route's target may be a mesh member (→ its tunnel IP) or an address.
      resolve = host: args.config.dots.system.networking.wireguard.mesh.memberIps.${host} or host;
      routes = lib.mapAttrs' (
        name: r:
        lib.nameValuePair (if r.domain != null then r.domain else "${name}.${domain}") {
          extraConfig = lib.concatStringsSep "\n" (
            lib.optional (r.extraConfig != "") r.extraConfig
            ++ [
              "encode zstd gzip"
              "reverse_proxy ${r.scheme}://${resolve r.host}:${toString r.port} {"
              # SearXNG (and most apps) read the client IP from X-Real-IP; Caddy
              # sets X-Forwarded-For but not this one.
              "	header_up X-Real-IP {http.request.remote.host}"
            ]
            ++ lib.optional (r.proxyConfig != "") r.proxyConfig
            ++ [ "}" ]
          );
        }
      ) cfg.routes;
    in
    {
      services.caddy = {
        enable = true;
        inherit (cfg) email globalConfig;
        virtualHosts = cfg.virtualHosts // routes;
      };

      networking.firewall = args.lib.mkIf cfg.openFirewall {
        allowedTCPPorts = [
          80
          443
        ];
      };
    };
}
