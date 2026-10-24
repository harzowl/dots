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

      listed = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the server advertises itself in the in-game browser. The
          advert carries the address the server egresses from, so it must stay
          off while the public entry is a different host unless the server also
          egresses through it.
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

      iniDir = "${cfg.dataDir}/data/Server";
      serverName = cfg.settings.serverName or defaults.settings.serverName;
      iniFile = "${iniDir}/${serverName}.ini";
      listed = if cfg.listed then "true" else "false";

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
        ++ [ "${cfg.name}-ini.service" ]
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
                assertion = !cfg.listed || config.dots.system.networking.wireguard.mesh.routeAll;
                message = "dots.system.services.games.project-zomboid.listed requires the host to egress through the public entry (wireguard.mesh.routeAll = true); otherwise the advert names the host's direct address.";
              }
            ];

            systemd = {
              tmpfiles.rules = [
                "d '${cfg.dataDir}/server' 0755 root root -"
                "d '${cfg.dataDir}/data' 0755 root root -"
              ];

              services = {
                "${cfg.name}-ini" = {
                  description = "Set the Project Zomboid server browser visibility";
                  wantedBy = [ "multi-user.target" ];
                  before = [ "${cfg.backend}-${cfg.name}.service" ];
                  path = [
                    pkgs.coreutils
                    pkgs.gnugrep
                    pkgs.gnused
                  ];
                  serviceConfig.Type = "oneshot";
                  script = ''
                    mkdir -p ${lib.escapeShellArg iniDir}
                    touch ${lib.escapeShellArg iniFile}
                    if grep -q '^Public=' ${lib.escapeShellArg iniFile}; then
                      sed -i 's/^Public=.*/Public=${listed}/' ${lib.escapeShellArg iniFile}
                    else
                      printf 'Public=%s\n' ${lib.escapeShellArg listed} >> ${lib.escapeShellArg iniFile}
                    fi
                  '';
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
