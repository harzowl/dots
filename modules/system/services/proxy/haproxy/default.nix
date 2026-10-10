let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "proxy"
    "haproxy"
  ];
  description = "HAProxy TCP front for services behind the WireGuard mesh";

  options =
    { lib, ... }:
    {
      forwards = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              host = lib.mkOption {
                type = lib.types.str;
                description = "Target: a WireGuard mesh member name (resolved to its tunnel IP) or a literal address.";
              };
              port = lib.mkOption {
                type = lib.types.port;
                description = "Target port on `host`.";
              };
              listen = lib.mkOption {
                type = lib.types.nullOr lib.types.port;
                default = null;
                description = "Port to listen on here; defaults to `port`.";
              };
            };
          }
        );
        default = { };
        description = ''
          TCP forwards: `<name>` listens on `listen` (default `port`) and forwards
          to `<host>:<port>` with the PROXY protocol v2, so the backend sees the
          real client IP. For services that are not HTTP (e.g. mail ports).
        '';
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open the listen ports.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib;
      # A target may be a mesh member (→ its tunnel IP) or an address.
      resolve = host: args.config.dots.system.networking.wireguard.mesh.memberIps.${host} or host;
      listenPort = f: if f.listen != null then f.listen else f.port;
      mkForward =
        name: f:
        ''
          frontend ft_${name}
            bind :${toString (listenPort f)}
            default_backend bk_${name}

          backend bk_${name}
            server ${name} ${resolve f.host}:${toString f.port} send-proxy-v2
        '';
      forwards = lib.mapAttrsToList mkForward cfg.forwards;
    in
    {
      services.haproxy = {
        enable = true;
        config = ''
          global
            log stdout format raw local0
            maxconn 4096

          defaults
            mode tcp
            log global
            option tcplog
            timeout connect 10s
            timeout client 1m
            timeout server 1m

        '' + lib.concatStringsSep "\n" forwards;
      };

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall (
        lib.mapAttrsToList (_: f: listenPort f) cfg.forwards
      );
    };
}
