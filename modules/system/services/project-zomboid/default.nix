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

  antiCheatSettings = {
    safety = "AntiCheatSafety";
    speed = "AntiCheatSpeed";
    noClip = "AntiCheatNoClip";
    hit = "AntiCheatHit";
    packetException = "AntiCheatPacketException";
    permission = "AntiCheatPermission";
    xp = "AntiCheatXP";
    safeHouse = "AntiCheatSafeHouse";
    player = "AntiCheatPlayer";
    checksum = "AntiCheatChecksum";
  };

  antiCheatLevels = {
    ban = 1;
    kick = 2;
    log = 3;
    disabled = 4;
  };

  antiCheatOption =
    { lib }:
    lib.mkOption {
      type = lib.types.nullOr (lib.types.enum (lib.attrNames antiCheatLevels));
      default = null;
      description = "Anti-cheat response; null keeps the server.ini default.";
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
    let
      luaValue = lib.types.oneOf [
        lib.types.bool
        lib.types.int
        lib.types.float
        lib.types.str
        (lib.types.attrsOf luaValue)
        (lib.types.listOf luaValue)
      ];
      luaTable = lib.types.attrsOf luaValue;
    in
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

      publicViaEdge = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Use the WireGuard server as the public entry: route egress through it,
          set the Docker bridge MTU to 1420, disable UPnP, and advertise the
          server's public address.
        '';
      };

      servers = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              enable = lib.mkEnableOption "this server";

              settings = lib.mkOption {
                type = lib.types.submodule {
                  freeformType = lib.types.attrsOf (
                    lib.types.either lib.types.bool (lib.types.either lib.types.int lib.types.str)
                  );
                  options.antiCheat = lib.mkOption {
                    type = lib.types.nullOr (
                      lib.types.either (lib.types.enum (lib.attrNames antiCheatLevels)) (
                        lib.types.submodule {
                          options = lib.mapAttrs (_: _: antiCheatOption { inherit lib; }) antiCheatSettings // {
                            default = lib.mkOption {
                              type = lib.types.nullOr (lib.types.enum (lib.attrNames antiCheatLevels));
                              default = null;
                              description = "Response for checks without their own value.";
                            };
                          };
                        }
                      )
                    );
                    default = null;
                    description = ''
                      One level for every check, or a table with a `default` and
                      per-check overrides. Null keeps the server.ini defaults.
                    '';
                  };
                };
                default = { };
                description = ''
                  Nix-cased overrides for the server.ini template. Keys are matched
                  to the template keys case-insensitively, preserving their spelling
                  (`autoCreateUserInWhiteList`, `UPnP`).
                '';
              };

              mods = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      workshopId = lib.mkOption {
                        type = lib.types.nullOr lib.types.ints.positive;
                        default = null;
                        description = "Steam Workshop item id; mutually exclusive with path.";
                      };
                      path = lib.mkOption {
                        type = lib.types.nullOr lib.types.path;
                        default = null;
                        description = "Local mod directory; mutually exclusive with workshopId.";
                      };
                      items = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        default = [ ];
                        description = "Mod loading ids provided by this entry, in load order.";
                      };
                    };
                  }
                );
                default = [ ];
                description = "Project Zomboid mods; Workshop entries use workshopId, local entries use path.";
              };

              sandboxVars = lib.mkOption {
                type = lib.types.nullOr luaTable;
                default = null;
                description = ''
                  SandboxVars overrides merged into `<server>_SandboxVars.lua`;
                  null leaves the file untouched. Keys are the game's own names
                  in camelCase (`zombieLore.sprinterPercentage`,
                  `hoursForLootRespawn`). The merge runs once the game has
                  created the file, so mod-provided options keep their values.
                '';
              };

              spawnpoints = lib.mkOption {
                type = lib.types.nullOr (lib.types.attrsOf (lib.types.listOf luaTable));
                default = null;
                description = ''
                  SpawnPoints table written to `<server>_spawnpoints.lua`; null does not touch the file.
                '';
              };

              spawnregions = lib.mkOption {
                type = lib.types.nullOr (lib.types.listOf luaTable);
                default = null;
                description = ''
                  SpawnRegions list written to `<server>_spawnregions.lua`; null does not touch the file.
                '';
              };
            };
          }
        );
        default = { };
        description = ''
          Server definitions keyed by server name, which is also the save and
          config file name. Enable exactly one to run it.
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

      meshServerAddress =
        config.dots.system.networking.wireguard.mesh.members.${config.dots.system.networking.wireguard.mesh.server}.address;

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

      enabledServers = lib.attrNames (lib.filterAttrs (_: s: s.enable) cfg.servers);
      serverName = lib.head (enabledServers ++ [ defaults.settings.serverName ]);
      server =
        cfg.servers.${serverName} or {
          settings = { };
          mods = [ ];
          sandboxVars = null;
          spawnpoints = null;
          spawnregions = null;
        };
      configFile = "${configDir}/${serverName}.ini";

      configValue = v: if lib.isBool v then (if v then "true" else "false") else toString v;

      luaKey =
        k: if builtins.match "[A-Za-z_][A-Za-z0-9_]*" k != null then k else "[${builtins.toJSON k}]";

      capitalize =
        name:
        lib.toUpper (builtins.substring 0 1 name)
        + builtins.substring 1 (builtins.stringLength name - 1) name;

      pascalize =
        value:
        if lib.isAttrs value then
          lib.mapAttrs' (name: child: lib.nameValuePair (capitalize name) (pascalize child)) value
        else if lib.isList value then
          map pascalize value
        else
          value;

      renderLua =
        value:
        let
          table =
            entries: "{${lib.optionalString (entries != [ ]) " ${lib.concatStringsSep ", " entries} "}}";
        in
        if lib.isBool value then
          (if value then "true" else "false")
        else if lib.isInt value || lib.isFloat value then
          toString value
        else if lib.isString value then
          builtins.toJSON value
        else if lib.isList value then
          table (map renderLua value)
        else if lib.isAttrs value then
          table (lib.mapAttrsToList (k: v: "${luaKey k} = ${renderLua v}") value)
        else
          throw "unsupported Project Zomboid Lua value: ${builtins.typeOf value}";

      luaFiles =
        lib.optionalAttrs (server.spawnpoints != null) {
          "${serverName}_spawnpoints.lua" = pkgs.writeText "zomboid-spawnpoints.lua" ''
            function SpawnPoints()
              return ${renderLua server.spawnpoints};
            end
          '';
        }
        // lib.optionalAttrs (server.spawnregions != null) {
          "${serverName}_spawnregions.lua" = pkgs.writeText "zomboid-spawnregions.lua" ''
            function SpawnRegions()
              return ${renderLua server.spawnregions};
            end
          '';
        };

      sandboxOverridesTable = if server.sandboxVars == null then null else pascalize server.sandboxVars;

      sandboxOverrides =
        if sandboxOverridesTable == null || sandboxOverridesTable == { } then
          null
        else
          pkgs.writeText "zomboid-sandbox-vars.lua" ''
            return ${renderLua sandboxOverridesTable};
          '';

      modValues = {
        Mods = lib.concatStringsSep ";" (lib.concatMap (m: m.items) server.mods);
        WorkshopItems = lib.concatStringsSep ";" (
          map (m: toString m.workshopId) (lib.filter (m: m.workshopId != null) server.mods)
        );
      };

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

      antiCheatConfig = server.settings.antiCheat or null;
      antiCheatDefault = if lib.isAttrs antiCheatConfig then antiCheatConfig.default or null else null;

      antiCheatLevel =
        name:
        let
          level = antiCheatConfig.${name} or null;
        in
        if antiCheatConfig == null then
          null
        else if lib.isString antiCheatConfig then
          antiCheatConfig
        else if level != null then
          level
        else
          antiCheatDefault;

      antiCheatValues = lib.listToAttrs (
        lib.concatMap (
          name:
          let
            level = antiCheatLevel name;
          in
          lib.optional (level != null) {
            name = antiCheatSettings.${name};
            value = antiCheatLevels.${level};
          }
        ) (lib.attrNames antiCheatSettings)
      );

      effectiveSettings =
        lib.removeAttrs server.settings [ "antiCheat" ]
        // antiCheatValues
        // lib.optionalAttrs cfg.publicViaEdge {
          UPnP = false;
          serverBrowserAnnouncedIP = meshServerAddress;
        };

      configValueFor =
        iniKey: fallback:
        let
          matches = lib.filter (k: resolveKey k == iniKey) (lib.attrNames effectiveSettings);
        in
        if matches == [ ] then fallback else effectiveSettings.${lib.head matches};

      publicEnabled =
        let
          value = configValueFor "Public" false;
        in
        if lib.isBool value then value else value == "true";

      forbiddenKeys = [
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
        "Mods"
        "WorkshopItems"
      ];

      badKeys =
        settings: lib.filter (k: builtins.elem (resolveKey k) forbiddenKeys) (lib.attrNames settings);

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
          inherit serverName;
          defaultPort = containerPort (lib.elemAt cfg.udpPorts 0);
          udpPort = containerPort (lib.elemAt cfg.udpPorts 1);
        };
        udpPorts = map publishPort cfg.udpPorts;
        volumes = [
          "${cfg.dataDir}/server:/project-zomboid"
          "${cfg.dataDir}/data:/project-zomboid-config"
        ]
        ++ lib.concatMap (
          m:
          lib.optional (m.path != null)
            "${pkgs.copyPathToStore m.path}:/project-zomboid-config/mods/${builtins.baseNameOf (toString m.path)}:ro"
        ) server.mods
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

          (lib.mkIf cfg.publicViaEdge {
            dots.system = {
              networking.wireguard.mesh.routeAll = true;
              docker.mtu = 1420;
            };
          })

          (lib.mkIf (!cfg.publicViaEdge) {
            dots.system.networking.wireguard.mesh.routeAll = false;
          })

          {
            assertions = [
              {
                assertion = cfg.secretEnv == { } || cfg.secretEnvSources != [ ];
                message = "dots.system.services.games.project-zomboid.secretEnv needs secretEnvSources to read the secrets from.";
              }
              {
                assertion = lib.length enabledServers == 1;
                message = "dots.system.services.games.project-zomboid needs exactly one enabled servers.<name>; enabled: ${lib.concatStringsSep ", " enabledServers}.";
              }
              {
                assertion = lib.all (s: badKeys s.settings == [ ]) (lib.attrValues cfg.servers);
                message = "dots.system.services.games.project-zomboid servers.<name>.settings must not contain Password, RCONPassword, DiscordToken, Seed, ResetID, ServerPlayerID, MaxPlayers, DefaultPort, UDPPort, RCONPort, Mods or WorkshopItems; use serverPasswordSecret, the image env/settings, udpPorts, the mods list, or a new servers.<name> for a fresh world.";
              }
              {
                assertion = lib.all (s: lib.all (m: (m.workshopId == null) != (m.path == null)) s.mods) (
                  lib.attrValues cfg.servers
                );
                message = "dots.system.services.games.project-zomboid servers.<name>.mods entries need exactly one of workshopId or path.";
              }
              {
                assertion = !publicEnabled || config.dots.system.networking.wireguard.mesh.routeAll;
                message = "dots.system.services.games.project-zomboid servers.<name>.settings Public requires the host to egress through the public entry (wireguard.mesh.routeAll = true); otherwise the advert names the host's direct address.";
              }
            ];

            dots.system.secretspec.secrets = lib.optional (
              cfg.serverPasswordFile != null
            ) cfg.serverPasswordSecret;

            system.extraDependencies = lib.map (m: pkgs.copyPathToStore m.path) (
              lib.filter (m: m.path != null) server.mods
            );

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
                    pkgs.lua5_4
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
                    [ -n "$seed" ] || seed=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
                    [ -n "$reset" ] || reset=$(od -An -N4 -tu4 /dev/urandom | awk '{ print $1 % 2147483647 }')
                    [ -n "$player" ] || player=$(od -An -N4 -tu4 /dev/urandom | awk '{ print $1 % 2147483647 }')
                    install -m 0600 ${./server.ini} ${lib.escapeShellArg configFile}
                    awk -v seed="$seed" -v reset="$reset" -v player="$player" '
                      { gsub(/@SEED@/, seed); gsub(/@RESET_ID@/, reset); gsub(/@SERVER_PLAYER_ID@/, player); print }
                    ' ${lib.escapeShellArg configFile} > ${lib.escapeShellArg (configFile + ".tmp")}
                    mv ${lib.escapeShellArg (configFile + ".tmp")} ${lib.escapeShellArg configFile}
                    ${lib.concatStrings (lib.mapAttrsToList (k: v: setConfig k (configValue v)) effectiveSettings)}
                    ${setConfig "Mods" modValues.Mods}
                    ${setConfig "WorkshopItems" modValues.WorkshopItems}
                    ${setPassword}
                    ${lib.concatStrings (
                      lib.mapAttrsToList (name: file: ''
                        install -m 0644 ${file} ${lib.escapeShellArg "${configDir}/${name}"}
                      '') luaFiles
                    )}
                    ${lib.optionalString (sandboxOverrides != null) ''
                      lua ${./sandbox-vars.lua} ${sandboxOverrides} ${lib.escapeShellArg "${configDir}/${serverName}_SandboxVars.lua"}
                    ''}
                    chmod 600 ${lib.escapeShellArg configFile}
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
