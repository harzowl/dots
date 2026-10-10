# WireGuard. Two ways to use it:
#
# 1. `mesh` — declare the topology once; each host's interface is derived (tunnel
#    IPs by sorted member order, peer lists, the client's endpoint and route
#    exception). This host is `config.dots.system.core.hostname`.
#
#      dots.system.networking.wireguard = {
#        enable = true;
#        mesh = {
#          enable = true;
#          server = "edge";              # the egress gateway (NATs peers out)
#          subnet = "10.10.0";
#          port = 51820;
#          privateKeyFile = "/run/secretspec/WG_EDGE_PRIVATE_KEY";
#          members = {
#            edge = { publicKey = "…"; address = "203.0.113.10"; };
#            hub  = { publicKey = "…"; address = "192.168.1.121"; };
#          };
#        };
#      };
#
# 2. `interfaces` / `egress` — the low-level escape hatch for anything the mesh
#    does not cover (`interfaces` is forwarded to `networking.wireguard.interfaces`;
#    `egress` adds NAT + forwarding + firewall for a gateway).
#
#      dots.system.networking.wireguard = {
#        enable = true;
#        egress = { enable = true; interface = "eth0"; };
#        interfaces.wg0 = { ips = [ "10.10.0.1/24" ]; listenPort = 51820; … };
#      };
{
  config,
  lib,
  ...
}:
let
  cfg = config.dots.system.networking.wireguard;
  mesh = cfg.mesh;

  # This host's name in the mesh is its hostname; its tunnel IP is `<subnet>.N`
  # by sorted member order (unless the member sets `ip`).
  self = config.dots.system.core.hostname;
  names = lib.attrNames mesh.members;
  ips = lib.listToAttrs (
    lib.imap0 (
      i: n:
      lib.nameValuePair n (
        if mesh.members.${n}.ip != null then
          mesh.members.${n}.ip
        else
          "${mesh.subnet}.${toString (i + 1)}"
      )
    ) names
  );

  participating = mesh.enable && mesh.members ? ${self};
  isServer = participating && self == mesh.server;
  server = if mesh.server != null then mesh.members.${mesh.server} or { } else { };

  lanGateway =
    if mesh.gateway != null then
      mesh.gateway
    else
      "${lib.concatStringsSep "." (lib.take 3 (lib.splitString "." mesh.members.${self}.address))}.1";

  meshInterface = {
    ips = [ "${ips.${self}}/24" ];
    listenPort = mesh.port;
    privateKeyFile = mesh.privateKeyFile;
    peers =
      if isServer then
        map (n: {
          publicKey = mesh.members.${n}.publicKey;
          allowedIPs = [ "${ips.${n}}/32" ];
        }) (lib.remove self names)
      else
        [
          {
            publicKey = server.publicKey;
            endpoint = "${server.address}:${toString mesh.port}";
            allowedIPs =
              lib.optional mesh.routeAll "0.0.0.0/0"
              ++ lib.optional (mesh.routeAll && mesh.ipv6) "::/0";
            persistentKeepalive = 25;
          }
        ];
    postSetup = lib.optionalString (!isServer && mesh.routeAll) "ip route replace ${server.address}/32 via ${lanGateway}";
  };

  interfaces = cfg.interfaces // lib.optionalAttrs participating { ${mesh.interface} = meshInterface; };
  egressOn = cfg.egress.enable || isServer;
  listenPorts = lib.filter (p: p != null) (map (i: i.listenPort or null) (lib.attrValues interfaces));
in
{
  options.dots.system.networking.wireguard = {
    enable = lib.mkEnableOption "WireGuard";

    interfaces = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "WireGuard interfaces, forwarded to `networking.wireguard.interfaces`.";
    };

    egress = {
      enable = lib.mkEnableOption "NAT egress for WireGuard peers (turn this host into a VPN gateway)";

      interface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "External interface to masquerade peer traffic on.";
      };
    };

    mesh = {
      enable = lib.mkEnableOption "declarative WireGuard mesh (derive this host's interface from a member list)";

      server = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Member name that is the egress gateway (NATs peers' traffic out its public IP).";
      };

      subnet = lib.mkOption {
        type = lib.types.str;
        default = "10.10.0";
        description = "Tunnel /24 prefix; members are numbered `<subnet>.N` in sorted order unless they set `ip`.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 51820;
        description = "WireGuard listen port.";
      };

      interface = lib.mkOption {
        type = lib.types.str;
        default = "wg0";
        description = "Interface to generate.";
      };

      privateKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "This host's WireGuard private key file.";
      };

      routeAll = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Clients route 0.0.0.0/0 through the server (the LAN and the server endpoint stay off the tunnel).";
      };

      ipv6 = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Clients also route `::/0` (needs IPv6 forwarding + NAT on the server).";
      };

      gateway = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Client's LAN default gateway; defaults to `<address /24>.1`.";
      };

      members = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              publicKey = lib.mkOption { type = lib.types.str; };
              address = lib.mkOption {
                type = lib.types.str;
                description = "Reachable address (the endpoint clients dial).";
              };
              ip = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Tunnel IP; defaults to `<subnet>.N`.";
              };
            };
          }
        );
        default = { };
        description = "Mesh members keyed by name; this host is `config.dots.system.core.hostname`.";
      };

      memberIps = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        readOnly = true;
        default = ips;
        description = "Derived tunnel IPs, by member name (e.g. for Caddy routes).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !mesh.enable || mesh.server != null;
        message = "dots.system.networking.wireguard.mesh.server must be set.";
      }
      {
        assertion = !mesh.enable || mesh.members != { };
        message = "dots.system.networking.wireguard.mesh.members must not be empty.";
      }
    ];

    networking.wireguard.interfaces = interfaces;

    boot.kernel.sysctl = lib.mkIf egressOn {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    networking.nat = lib.mkIf egressOn {
      enable = true;
      externalInterface = cfg.egress.interface;
      internalInterfaces = lib.attrNames interfaces;
    };

    networking.firewall.allowedUDPPorts = lib.mkIf egressOn listenPorts;

    # The mesh interface's `postSetup` adds a route to the server endpoint via the
    # LAN gateway; wait for the LAN (`network-online`) so it can't race boot-time
    # DHCP and fail with "Nexthop has invalid gateway".
    systemd.services."wireguard-${mesh.interface}" = lib.mkIf participating {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };
  };
}
