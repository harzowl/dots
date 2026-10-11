# Stalwart mail server, v0.16+.
#
# 0.16 dropped TOML configuration entirely: the only file on disk is a small
# `config.json` that describes the datastore, and *everything else* (listeners,
# domains, accounts, routing, TLS, CORS, …) lives inside that datastore as JMAP
# objects managed through `stalwart-cli` / the WebUI. This module therefore:
#
#   * runs `stalwart_0_16` against a generated `config.json` (just the
#     `DataStore`), and
#   * optionally drops a declarative apply-plan (`provision`) at
#     `/etc/stalwart/provision.json`, which operators replay with
#     `stalwart-cli apply --file /etc/stalwart/provision.json`.
#
# Config is NOT auto-applied: `apply` reconciles (and deletes) everything the
# plan omits, so it is a deliberate, operator-run step — see the migration
# runbook in the consuming repo's README.
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
  description = "Stalwart mail server (v0.16+)";

  options =
    { config, lib, pkgs, pkgsUnstable, ... }:
    let
      cfg = config.dots.system.services.mail.stalwart;
    in
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgsUnstable.stalwart_0_16;
        defaultText = lib.literalExpression "pkgsUnstable.stalwart_0_16";
        description = "Stalwart 0.16+ package to run.";
      };

      cliPackage = lib.mkOption {
        type = lib.types.package;
        default = pkgsUnstable.stalwart-cli;
        defaultText = lib.literalExpression "pkgsUnstable.stalwart-cli";
        description = "`stalwart-cli`, used to apply the provision plan.";
      };

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/stalwart";
        description = "Persistent data directory (holds the embedded datastore).";
      };

      datastore = lib.mkOption {
        type = (pkgs.formats.json { }).type;
        default = {
          "@type" = "RocksDb";
          path = "${cfg.dataDir}/db";
        };
        defaultText = lib.literalExpression ''
          { "@type" = "RocksDb"; path = "''${dataDir}/db"; }
        '';
        description = ''
          The `DataStore` object written verbatim to `config.json` — the only
          configuration 0.16 reads from disk. Keep `path` pointing at the
          existing datastore when upgrading in place.
        '';
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open `firewallPorts` (TCP).";
      };

      firewallPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [
          25
          143
          465
          587
          993
          8080
        ];
        description = ''
          TCP ports to open. Listeners themselves live in the datastore, so
          this list must be kept in sync with the provision plan by hand.
        '';
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          STALWART_PUBLIC_URL = "https://mail.example.com";
        };
        description = "Extra environment for the unit (e.g. `STALWART_PUBLIC_URL`).";
      };

      credentials = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          STALWART_DNS_TOKEN = "/run/secretspec/STALWART_DNS_TOKEN";
        };
        description = ''
          Secret files exposed to the service as systemd credentials, readable
          in the datastore's secret objects as
          `{"@type":"File","filePath":"/run/credentials/stalwart.service/NAME"}`.
        '';
      };

      provision = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Optional declarative apply-plan (the JSON/NDJSON format produced by
          `stalwart-cli snapshot`), installed at `/etc/stalwart/provision.json`.
          Applied by hand with `stalwart-cli apply`.
        '';
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;
      configJson = (pkgs.formats.json { }).generate "config.json" cfg.datastore;
    in
    {
      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall cfg.firewallPorts;

      environment.systemPackages = [
        cfg.package
        cfg.cliPackage
      ];

      environment.etc =
        {
          "stalwart/config.json".source = configJson;
        }
        // lib.optionalAttrs (cfg.provision != null) {
          "stalwart/provision.json".source = cfg.provision;
        };

      users = {
        groups.stalwart = { };
        users.stalwart = {
          isSystemUser = true;
          group = "stalwart";
        };
      };

      systemd.tmpfiles.rules = [
        "d '${cfg.dataDir}' 0700 stalwart stalwart - -"
      ];

      systemd.services.stalwart = {
        description = "Stalwart Server";
        wantedBy = [ "multi-user.target" ];
        after = [
          "local-fs.target"
          "network.target"
        ];
        inherit (cfg) environment;
        serviceConfig = {
          Type = "simple";
          LimitNOFILE = 65536;
          KillMode = "process";
          KillSignal = "SIGINT";
          Restart = "on-failure";
          RestartSec = 5;
          SyslogIdentifier = "stalwart";

          ExecStart = "${lib.getExe cfg.package} --config=/etc/stalwart/config.json";

          LoadCredential = lib.mapAttrsToList (key: value: "${key}:${value}") cfg.credentials;

          CacheDirectory = "stalwart";
          ReadWritePaths = [ cfg.dataDir ];

          User = "stalwart";
          Group = "stalwart";

          # Bind standard privileged ports.
          AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
          CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];

          # Hardening.
          DeviceAllow = [ "" ];
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          PrivateDevices = true;
          PrivateUsers = false; # incompatible with CAP_NET_BIND_SERVICE
          ProcSubset = "pid";
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectProc = "invisible";
          ProtectSystem = "strict";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
          ];
          UMask = "0077";
        };
      };
    };
}
