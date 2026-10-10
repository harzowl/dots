# WireGuard, plus an opt-in NAT egress so a public host can act as a VPN
# gateway for peers (point their tunnel at it and route traffic out its IP).
#
#   # server (egress gateway)
#   dots.system.networking.wireguard = {
#     enable = true;
#     egress = { enable = true; interface = "eth0"; };
#     interfaces.wg0 = {
#       ips = [ "10.10.0.1/24" ];
#       listenPort = 51820;
#       privateKeyFile = "/run/secretspec/WG_EDGE_PRIVATE_KEY";
#       peers = [ { publicKey = "…"; allowedIPs = [ "10.10.0.2/32" ]; } ];
#     };
#   };
#
#   # client (route everything through the gateway; keep the LAN + the gateway's
#   # endpoint off the tunnel, or you loop the tunnel through itself)
#   dots.system.networking.wireguard = {
#     enable = true;
#     interfaces.wg0 = {
#       ips = [ "10.10.0.2/24" ];
#       privateKeyFile = "/run/secretspec/WG_HUB_PRIVATE_KEY";
#       peers = [
#         {
#           publicKey = "…";
#           endpoint = "203.0.113.10:51820";
#           allowedIPs = [ "0.0.0.0/0" "::/0" ];
#           persistentKeepalive = 25;
#         }
#       ];
#       postSetup = ''ip route replace 203.0.113.10/32 via 192.168.1.1'';
#     };
#   };
{
  config,
  lib,
  ...
}:
let
  cfg = config.dots.system.networking.wireguard;
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
  };

  config = lib.mkIf cfg.enable {
    networking.wireguard.interfaces = cfg.interfaces;

    boot.kernel.sysctl = lib.mkIf cfg.egress.enable {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    networking.nat = lib.mkIf cfg.egress.enable {
      enable = true;
      externalInterface = cfg.egress.interface;
      internalInterfaces = builtins.attrNames cfg.interfaces;
    };

    networking.firewall.allowedUDPPorts = lib.mkIf cfg.egress.enable (
      lib.filter (p: p != null) (map (i: i.listenPort or null) (builtins.attrValues cfg.interfaces))
    );
  };
}
