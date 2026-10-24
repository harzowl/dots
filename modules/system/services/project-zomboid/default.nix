let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../lib/mkDockerService.nix;
  mkSecretEnv = import ../../../../lib/mkSecretEnv.nix;

  defaults = {
    name = "zomboid";
    image = "docker.io/indifferentbroccoli/projectzomboid-server-docker:latest";
    udpPorts = [
      16261
      16262
    ];
    extraOptions = [ "--stop-timeout=30" ];
    settings = {
      puid = 1000;
      pgid = 1000;
      serverName = "zomboid";
      maxPlayers = 10;
      memoryXmxGb = 6;
      memoryXmsGb = 6;
    };
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "games"
    "project-zomboid"
  ];
  description = "Project Zomboid dedicated server (OCI container)";

  when = cfg: cfg.enable || cfg.router.enable;

  options =
    { config, lib, ... }:
    (mkDockerService.options {
      inherit lib defaults;
    })
    // {
      memoryLimit = (mkDockerService.memoryLimitOption { inherit lib; }) // {
        default = "10g";
      };

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/zomboid";
        description = "Host directory holding the server install and save data.";
      };

      bindAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Host address the UDP ports are published on. Set it to the host's
          WireGuard address so the server is reachable only through the tunnel.
        '';
      };

      serverConfig = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.either lib.types.bool (lib.types.either lib.types.int lib.types.str)
        );
        default = { };
        description = ''
          Nix-cased overrides for the server.ini template. Keys are matched to
          the template keys case-insensitively, preserving their spelling
          (`autoCreateUserInWhiteList`, `UPnP`).
        '';
      };

      serverPasswordSecret = lib.mkOption {
        type = lib.types.str;
        default = "ZOMBOID_SERVER_PASSWORD";
        description = "Secret name holding the shared server join password.";
      };

      serverPasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "/run/secretspec/${config.dots.system.services.games.project-zomboid.serverPasswordSecret}";
        description = ''
          File holding the shared server join password; merged into the ini as
          `Password`. Null leaves the ini's existing `Password` untouched.
        '';
      };

      forceGenerateSeed = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Regenerate the world seed once. Toggle it off and on again to
          regenerate another; leaving it on does not regenerate every start.
        '';
      };

      forceGenerateResetId = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Regenerate `ResetID` once; toggle off and on to regenerate again.";
      };

      forceGenerateServerPlayerId = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Regenerate `ServerPlayerID` once; toggle off and on to regenerate again.";
      };

      secretEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          ADMIN_PASSWORD = "ZOMBOID_ADMIN_PASSWORD";
          RCON_PASSWORD = "ZOMBOID_RCON_PASSWORD";
        };
        description = ''
          Map a container credential variable to the neutral secret name looked
          up in `secretEnvSources`. The values are re-emitted into a runtime
          dotenv, so they never enter the Nix store.
        '';
      };

      secretEnvSources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "/run/secretspec/env" ];
        description = "Dotenv files the `secretEnv` values are read from, in order.";
      };

      router = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "UDP forwarding to the game server over the WireGuard mesh";

            upstream = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Mesh address of the host running the server.";
            };

            ports = lib.mkOption {
              type = lib.types.listOf lib.types.port;
              default = config.dots.system.services.games.project-zomboid.udpPorts;
              description = "UDP ports to forward to the server.";
            };

            externalInterface = lib.mkOption {
              type = lib.types.str;
              default = config.dots.system.networking.wireguard.egress.interface;
              description = "Public interface the forwarded ports arrive on.";
            };

            internalInterface = lib.mkOption {
              type = lib.types.str;
              default = config.dots.system.networking.wireguard.mesh.interface;
              description = "WireGuard interface facing the server.";
            };
          };
        };
        default = { };
        description = "Public UDP entry for a server reached over the WireGuard mesh.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) config lib pkgs;

      meshInterface = config.dots.system.networking.wireguard.mesh.interface;

      containerPort =
        p:
        let
          parts = lib.splitString ":" (toString p);
        in
        lib.last parts;

      publishPort =
        p:
        let
          port = containerPort p;
        in
        if cfg.bindAddress == null then p else "${cfg.bindAddress}:${port}:${port}";

      remap = mkSecretEnv {
        inherit lib pkgs;
        service = cfg.name;
        target = "/run/${cfg.name}.env";
        unit = "${cfg.name}-env";
        consumer = "${cfg.backend}-${cfg.name}.service";
        environmentFiles = cfg.secretEnvSources;
        mapping = cfg.secretEnv;
      };

      configDir = "${cfg.dataDir}/data/Server";
      serverName = cfg.settings.serverName or defaults.settings.serverName;
      configFile = "${configDir}/${serverName}.ini";
      forceFile = "${configFile}.nix-forced";

      configValue = v: if lib.isBool v then (if v then "true" else "false") else toString v;

      templateKeys =
        let
          lines = lib.splitString "\n" (builtins.readFile ./server.ini);
        in
        lib.filter (k: k != "") (
          map (
            line:
            let
              m = builtins.match "^([A-Za-z0-9_]+)=.*" line;
            in
            if m == null then "" else builtins.head m
          ) lines
        );

      normalizeKey = k: lib.toLower (lib.replaceStrings [ "_" ] [ "" ] k);

      resolveKey =
        key:
        let
          normalized = normalizeKey key;
          match = lib.findFirst (templateKey: normalizeKey templateKey == normalized) null templateKeys;
        in
        if match == null then key else match;

      configValueFor =
        iniKey: fallback:
        let
          matches = lib.filter (k: resolveKey k == iniKey) (lib.attrNames cfg.serverConfig);
        in
        if matches == [ ] then fallback else cfg.serverConfig.${lib.head matches};

      publicEnabled =
        let
          value = configValueFor "Public" false;
        in
        if lib.isBool value then value else value == "true";

      badKeys = lib.filter (
        k:
        builtins.elem (resolveKey k) [
          "Password"
          "RCONPassword"
          "DiscordToken"
          "Seed"
          "ResetID"
          "ServerPlayerID"
          "MaxPlayers"
          "DefaultPort"
          "UDPPort"
          "RCONPort"
        ]
      ) (lib.attrNames cfg.serverConfig);

      forceSeed = if cfg.forceGenerateSeed then "true" else "false";
      forceReset = if cfg.forceGenerateResetId then "true" else "false";
      forcePlayer = if cfg.forceGenerateServerPlayerId then "true" else "false";

      readValue = key: ''
        awk -F= -v key=${lib.escapeShellArg key} '$1 == key { sub(/^[^=]*=/, ""); print; exit }' ${lib.escapeShellArg configFile} 2>/dev/null || true
      '';

      setConfig = key: value: ''
        awk -v key=${lib.escapeShellArg (resolveKey key)} -v value=${lib.escapeShellArg value} '
          BEGIN { found = 0 }
          index($0, key "=") == 1 { print key "=" value; found = 1; next }
          { print }
          END { if (!found) print key "=" value }
        ' ${lib.escapeShellArg configFile} > ${lib.escapeShellArg (configFile + ".tmp")}
        mv ${lib.escapeShellArg (configFile + ".tmp")} ${lib.escapeShellArg configFile}
      '';

      setPassword = lib.optionalString (cfg.serverPasswordFile != null) ''
        if [ ! -s ${lib.escapeShellArg cfg.serverPasswordFile} ]; then
          echo "Project Zomboid server password secret ${cfg.serverPasswordSecret} is missing" >&2
          exit 1
        fi
        awk -v key=Password -v pwfile=${lib.escapeShellArg cfg.serverPasswordFile} '
          BEGIN { getline password < pwfile; close(pwfile); found = 0 }
          index($0, key "=") == 1 { print key "=" password; found = 1; next }
          { print }
          END { if (!found) print key "=" password }
        ' ${lib.escapeShellArg configFile} > ${lib.escapeShellArg (configFile + ".tmp")}
        mv ${lib.escapeShellArg (configFile + ".tmp")} ${lib.escapeShellArg configFile}
      '';

      spec = cfg // {
        settings = cfg.settings // {
          defaultPort = containerPort (lib.elemAt cfg.udpPorts 0);
          udpPort = containerPort (lib.elemAt cfg.udpPorts 1);
        };
        udpPorts = map publishPort cfg.udpPorts;
        volumes = [
          "${cfg.dataDir}/server:/project-zomboid"
          "${cfg.dataDir}/data:/project-zomboid-config"
        ]
        ++ cfg.volumes;
        environmentFiles = cfg.environmentFiles ++ [ remap.environmentFile ];
      };

      dependsOnUnits =
        map (d: if lib.hasSuffix ".service" d then d else "${cfg.backend}-${d}.service") cfg.dependsOn
        ++ [ "${cfg.name}-config.service" ]
        ++ lib.optional (cfg.bindAddress != null) "wireguard-${meshInterface}.service";
    in
    lib.mkMerge [
      (lib.mkIf cfg.enable (
        lib.mkMerge [
          (mkDockerService.config {
            inherit spec defaults;
          } args)

          {
            assertions = [
              {
                assertion = cfg.secretEnv == { } || cfg.secretEnvSources != [ ];
                message = "dots.system.services.games.project-zomboid.secretEnv needs secretEnvSources to read the secrets from.";
              }
              {
                assertion = badKeys == [ ];
                message = "dots.system.services.games.project-zomboid.serverConfig must not contain Password, RCONPassword, DiscordToken, Seed, ResetID, ServerPlayerID, MaxPlayers, DefaultPort, UDPPort or RCONPort; use serverPasswordSecret, the image env/settings, udpPorts, or the forceGenerate* flags.";
              }
              {
                assertion = !publicEnabled || config.dots.system.networking.wireguard.mesh.routeAll;
                message = "dots.system.services.games.project-zomboid.serverConfig Public requires the host to egress through the public entry (wireguard.mesh.routeAll = true); otherwise the advert names the host's direct address.";
              }
            ];

            dots.system.secretspec.secrets = lib.optional (
              cfg.serverPasswordFile != null
            ) cfg.serverPasswordSecret;

            systemd = {
              tmpfiles.rules = [
                "d '${cfg.dataDir}/server' 0755 root root -"
                "d '${cfg.dataDir}/data' 0755 root root -"
              ];

              services = {
                "${cfg.name}-config" = {
                  description = "Apply the Nix-managed Project Zomboid server settings";
                  wantedBy = [ "multi-user.target" ];
                  before = [ "${cfg.backend}-${cfg.name}.service" ];
                  path = [
                    pkgs.coreutils
                    pkgs.gawk
                  ];
                  serviceConfig.Type = "oneshot";
                  script = ''
                    umask 077
                    mkdir -p ${lib.escapeShellArg configDir}
                    oldSeed=$(${readValue "Seed"})
                    oldReset=$(${readValue "ResetID"})
                    oldPlayer=$(${readValue "ServerPlayerID"})
                    case "$oldSeed" in @*) oldSeed="" ;; esac
                    case "$oldReset" in @*) oldReset="" ;; esac
                    case "$oldPlayer" in @*) oldPlayer="" ;; esac
                    seed="$oldSeed"
                    reset="$oldReset"
                    player="$oldPlayer"
                    forced=""
                    if [ "${forceSeed}" = true ]; then
                      if [ -z "$seed" ] || ! awk -v f=seed '$0 == f { found = 1 } END { exit !found }' ${lib.escapeShellArg forceFile} 2>/dev/null; then
                        seed=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
                      fi
                      forced="$forced seed"
                    fi
                    if [ "${forceReset}" = true ]; then
                      if [ -z "$reset" ] || ! awk -v f=reset '$0 == f { found = 1 } END { exit !found }' ${lib.escapeShellArg forceFile} 2>/dev/null; then
                        reset=$(od -An -N4 -tu4 /dev/urandom | awk '{ print $1 % 2147483647 }')
                      fi
                      forced="$forced reset"
                    fi
                    if [ "${forcePlayer}" = true ]; then
                      if [ -z "$player" ] || ! awk -v f=player '$0 == f { found = 1 } END { exit !found }' ${lib.escapeShellArg forceFile} 2>/dev/null; then
                        player=$(od -An -N4 -tu4 /dev/urandom | awk '{ print $1 % 2147483647 }')
                      fi
                      forced="$forced player"
                    fi
                    install -m 0600 ${./server.ini} ${lib.escapeShellArg configFile}
                    awk -v seed="$seed" -v reset="$reset" -v player="$player" '
                      { gsub(/@SEED@/, seed); gsub(/@RESET_ID@/, reset); gsub(/@SERVER_PLAYER_ID@/, player); print }
                    ' ${lib.escapeShellArg configFile} > ${lib.escapeShellArg (configFile + ".tmp")}
                    mv ${lib.escapeShellArg (configFile + ".tmp")} ${lib.escapeShellArg configFile}
                    ${lib.concatStrings (lib.mapAttrsToList (k: v: setConfig k (configValue v)) cfg.serverConfig)}
                    ${setPassword}
                    printf '%s\n' $forced > ${lib.escapeShellArg forceFile}
                    chmod 600 ${lib.escapeShellArg configFile} ${lib.escapeShellArg forceFile}
                  '';
                }
                // lib.optionalAttrs (cfg.serverPasswordFile != null) {
                  after = [ "secretspec.service" ];
                  requires = [ "secretspec.service" ];
                };

                ${remap.unitName} = remap.unit;

                "${cfg.backend}-${cfg.name}" = {
                  after = dependsOnUnits;
                  requires = dependsOnUnits;
                };
              };
            };
          }
        ]
      ))

      (lib.mkIf cfg.router.enable {
        assertions = [
          {
            assertion = cfg.router.upstream != null;
            message = "dots.system.services.games.project-zomboid.router.upstream must be set.";
          }
          {
            assertion = !config.networking.nftables.enable;
            message = "dots.system.services.games.project-zomboid.router currently needs the iptables firewall backend.";
          }
        ];

        networking.nat = {
          enable = lib.mkDefault true;
          externalInterface = lib.mkDefault cfg.router.externalInterface;
          forwardPorts = map (p: {
            sourcePort = p;
            destination = "${cfg.router.upstream}:${toString p}";
            proto = "udp";
          }) cfg.router.ports;
          extraCommands = lib.concatMapStringsSep "\n" (p: ''
            iptables -w -t nat -A nixos-nat-post -o ${cfg.router.internalInterface} -d ${cfg.router.upstream} -p udp --dport ${toString p} -j MASQUERADE
          '') cfg.router.ports;
          extraStopCommands = lib.concatMapStringsSep "\n" (p: ''
            iptables -w -t nat -D nixos-nat-post -o ${cfg.router.internalInterface} -d ${cfg.router.upstream} -p udp --dport ${toString p} -j MASQUERADE || true
          '') cfg.router.ports;
        };
      })
    ];
}
