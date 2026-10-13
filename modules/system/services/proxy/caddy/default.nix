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

      accessLogFormat = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = ''
          format filter {
            wrap json
            request>uri query {
              delete t
              delete s
              delete p
              delete token
              delete code
              delete state
            }
            request>headers>Referer delete
          }
        '';
        description = ''
          The access-log body injected into **every** vhost (the generated
          `routes` and the caller's `virtualHosts`), so a credential or OAuth
          `code`/`state` carried in a request URI never reaches a log file. The
          default redacts the Subsonic `t`/`s`/`p`, OIDC `code`/`state`, a
          generic `token` query parameter and the `Referer` header; the module
          prepends the usual `output file <logDir>/access-<host>.log` line. Set
          this to `null` to opt a host out and fall back to Caddy's default
          logging, or override it (e.g. `lib.mkForce`) to customise. A vhost
          that defines its own `logFormat` is never touched.
        '';
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

      # Every site logs through a credential-redacting filter (see
      # `accessLogFormat`) unless it brings its own `logFormat`. `logFormat` is a
      # per-vhost NixOS option, so it has to be injected site by site — both the
      # generated `routes` and the caller's own `virtualHosts` — and the module
      # reproduces the default `output file` line so the log paths are unchanged.
      # The NixOS caddy module's default log directory. Read as a literal, not
      # from `config.services.caddy` — this module also *defines*
      # `services.caddy`, so reading it back would recurse. Override
      # `accessLogFormat` wholesale if you change `services.caddy.logDir`.
      logDir = "/var/log/caddy";
      redactLog =
        host: vh:
        let
          base = if isAttrs vh then vh else { extraConfig = vh; };
        in
        if cfg.accessLogFormat == null || base ? logFormat then
          base
        else
          base
          // {
            logFormat = ''
              output file ${logDir}/access-${host}.log
              ${cfg.accessLogFormat}
            '';
          };

      sites = lib.mapAttrs redactLog (cfg.virtualHosts // routes);
    in
    {
      services.caddy = {
        enable = true;
        inherit (cfg) email globalConfig;
        virtualHosts = sites;
      };

      # Guard: with redaction enabled (the default) every site must carry a
      # `logFormat`, so a new vhost cannot silently ship with unredacted logging.
      # Opt out by setting `accessLogFormat = null`. Declared as an assertion
      # (evaluated after `config` is built) rather than a top-level `assert`,
      # which would force `config` during module collection and recurse.
      assertions = [
        {
          assertion =
            cfg.accessLogFormat == null || lib.all (vh: (vh.logFormat or null) != null) (lib.attrValues sites);
          message = "dots.system.services.proxy.caddy: a virtual host has no redacting `logFormat`; set `accessLogFormat = null` to opt out of access-log redaction";
        }
      ];

      networking.firewall = args.lib.mkIf cfg.openFirewall {
        allowedTCPPorts = [
          80
          443
        ];
      };
    };
}
