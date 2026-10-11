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
#     `/etc/stalwart/provision.json` **and replays it automatically** via
#     `stalwart-provision.service` (a oneshot, run on boot and whenever the
#     plan changes), authenticated with the admin API key in
#     `provisionApiKeyFile`.
#
# The plan's `upsert`/`update` operations are idempotent and never delete;
# deletions must be expressed explicitly. `stalwart-cli apply` writes the
# datastore, but several settings (`MtaStageData`, `SpamSettings`, the SMTP
# DATA-stage gate) are only read at service start — so the unit restarts
# Stalwart whenever the plan changed anything.
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
    {
      config,
      lib,
      pkgs,
      pkgsUnstable,
      ...
    }:
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
          `stalwart-cli snapshot`), installed at `/etc/stalwart/provision.json`
          and applied automatically by `stalwart-provision.service`.
        '';
      };

      provisionApiKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          File holding a Stalwart **admin API key** (WebUI → Settings → API
          Keys), used by `stalwart-provision.service` to apply `provision`.
          The management API is OIDC-gated, so a key is required — the admin
          password is not accepted. When unset, the provision unit is not
          created and `provision` is only a passive file on disk.
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

      environment.etc = {
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

      # Declarative convergence: apply the plan, then restart Stalwart when it
      # changed anything — `MtaStageData`/`SpamSettings` and the SMTP DATA-stage
      # gate are only read at service start.
      systemd.services.stalwart-provision =
        lib.mkIf (cfg.provision != null && cfg.provisionApiKeyFile != null)
          {
            description = "Apply the Stalwart provision plan";
            after = [ "stalwart.service" ];
            wants = [ "stalwart.service" ];
            wantedBy = [ "multi-user.target" ];
            # A deploy can land before Stalwart answers; never give up retrying
            # (mirrors the oauth2-proxy gates).
            startLimitIntervalSec = 0;
            startLimitBurst = 0;
            # Re-run whenever the plan changes (i.e. on a new Nix generation).
            restartTriggers = [ cfg.provision ];
            path = [
              cfg.cliPackage
              pkgs.curl
              pkgs.systemd
              pkgs.coreutils
              pkgs.gnugrep
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "stalwart-provision" ''
                set -u
                URL="http://127.0.0.1:8080"
                PLAN=${lib.escapeShellArg (toString cfg.provision)}
                KEY_FILE=${lib.escapeShellArg (toString cfg.provisionApiKeyFile)}

                # The API may still be starting; give it up to a minute.
                n=0
                until curl -fsS "$URL/jmap/session" >/dev/null 2>&1; do
                  n=$((n + 1))
                  if [ "$n" -ge 60 ]; then
                    echo "Stalwart API not reachable; the next boot will retry."
                    exit 0
                  fi
                  sleep 1
                done

                if [ ! -r "$KEY_FILE" ]; then
                  echo "No API key at $KEY_FILE; skipping provision."
                  exit 0
                fi
                KEY="$(cat "$KEY_FILE")"

                out="$(stalwart-cli apply --file "$PLAN" --url "$URL" --api-key "$KEY" 2>&1)" || {
                  echo "$out"
                  exit 0
                }
                echo "$out"

                if printf '%s' "$out" | grep -qE '[1-9][0-9]* updated'; then
                  echo "Plan changed; restarting Stalwart to apply it."
                  systemctl restart stalwart.service || true
                fi
              '';
            };
          };
    };
}
