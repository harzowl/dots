# Source-based policy routing: send traffic from a given source address out a
# chosen gateway, regardless of the main routing table. Useful to let one
# service egress directly (e.g. over the LAN) while everything else takes the
# default route (e.g. through a WireGuard gateway).
#
#   dots.system.networking.policyRouting.rules = [
#     { from = "192.168.1.121"; via = "192.168.1.1"; dev = "eth0"; }
#   ];
#
# Each rule installs an `ip rule` (match `from`) and a default route in its own
# table pointing at `via`/`dev`. Runs as a oneshot after `network-online.target`
# so the gateway is reachable (a boot-time race would otherwise fail the route).
let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "networking"
    "policyRouting"
  ];
  description = "Source-based policy routing";

  # Setting any rule turns it on; no separate `enable` needed.
  when = cfg: cfg.rules != [ ];

  options =
    { lib, ... }:
    {
      rules = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              from = lib.mkOption {
                type = lib.types.str;
                description = "Source address or CIDR to match.";
              };
              via = lib.mkOption {
                type = lib.types.str;
                description = "Gateway the matched traffic is routed through.";
              };
              dev = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Output interface (optional).";
              };
              table = lib.mkOption {
                type = lib.types.ints.positive;
                default = 100;
                description = "Routing table id for this rule.";
              };
              priority = lib.mkOption {
                type = lib.types.ints.positive;
                default = 100;
                description = "`ip rule` priority (lower runs first).";
              };
            };
          }
        );
        default = [ ];
        description = "Policy-routing rules.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;
      ruleCmds = lib.concatMapStrings (
        r:
        ''
          ip rule add from ${r.from} lookup ${toString r.table} priority ${toString r.priority}
          ip route replace default table ${toString r.table} ${lib.optionalString (r.dev != null) "dev ${r.dev} "}via ${r.via}
        ''
      ) cfg.rules;
    in
    {
      systemd.services.policy-routing = {
        description = "Source-based policy routing";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "policy-routing" ruleCmds;
        };
      };
    };
}
