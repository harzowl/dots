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
          Overrides applied to the game-generated ini. Managed keys are removed
          before each start, so deleting a key reverts to the game default.
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
      managedFile = "${configFile}.nix-managed";

      configValue = v: if lib.isBool v then (if v then "true" else "false") else toString v;

      publicEnabled =
        let
          value = cfg.serverConfig.Public or false;
        in
        if lib.isBool value then value else value == "true";

      setConfig = key: value: ''
        awk -v key=${lib.escapeShellArg key} -v value=${lib.escapeShellArg value} '
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
                assertion = !(cfg.serverConfig ? Password);
                message = "dots.system.services.games.project-zomboid.serverConfig.Password is set from serverPasswordSecret; do not put it in ini.";
              }
              {
                assertion = !publicEnabled || config.dots.system.networking.wireguard.mesh.routeAll;
                message = "dots.system.services.games.project-zomboid.serverConfig.Public requires the host to egress through the public entry (wireguard.mesh.routeAll = true); otherwise the advert names the host's direct address.";
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
                    touch ${lib.escapeShellArg configFile}
                    if [ -f ${lib.escapeShellArg managedFile} ]; then
                      awk -F= 'NR == FNR { keys[$0] = 1; next } { if ($1 in keys) next; print }' \
                        ${lib.escapeShellArg managedFile} ${lib.escapeShellArg configFile} > ${
                          lib.escapeShellArg (configFile + ".tmp")
                        }
                      mv ${lib.escapeShellArg (configFile + ".tmp")} ${lib.escapeShellArg configFile}
                    fi
                    ${lib.concatStrings (lib.mapAttrsToList (k: v: setConfig k (configValue v)) cfg.serverConfig)}
                    ${setPassword}
                    printf '%s\n' ${
                      lib.concatMapStringsSep " " (k: lib.escapeShellArg k) (
                        lib.attrNames cfg.serverConfig ++ [ "Password" ]
                      )
                    } > ${lib.escapeShellArg managedFile}
                    chmod 600 ${lib.escapeShellArg configFile} ${lib.escapeShellArg managedFile}
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
