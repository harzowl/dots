let
  memoryLimitOption =
    { lib }:
    lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "3g";
      description = "Docker `--memory` limit for the container.";
    };
in
{
  inherit memoryLimitOption;

  options =
    {
      lib,
      defaults ? { },
    }:
    let
      opt =
        name: attrs:
        lib.mkOption (
          attrs
          // lib.optionalAttrs (lib.hasAttr name defaults) {
            default = defaults.${name};
          }
        );
    in
    {
      name = opt "name" {
        type = lib.types.str;
        description = "Container name (also the systemd unit suffix).";
      };

      image = opt "image" {
        type = lib.types.str;
        description = "OCI image reference, e.g. `ghcr.io/example/service:latest`.";
      };

      backend = opt "backend" {
        type = lib.types.enum [
          "docker"
          "podman"
        ];
        default = "docker";
        description = "Container backend; enabling a service turns it on for the host.";
      };

      startLimitBurst = opt "startLimitBurst" {
        type = lib.types.int;
        default = 5;
        description = ''
          Consecutive failed starts within `startLimitIntervalSec` before the unit
          is put into `failed`. Bounds a restart loop so a broken container fails
          the activation fast instead of restarting forever.
        '';
      };

      startLimitIntervalSec = opt "startLimitIntervalSec" {
        type = lib.types.int;
        default = 60;
        description = ''
          Window (seconds) over which `startLimitBurst` is counted. `0` disables
          the limit (restart forever) — the gates set this deliberately.
        '';
      };

      ports = opt "ports" {
        type = lib.types.listOf (lib.types.either lib.types.port lib.types.str);
        default = [ ];
        description = "Published TCP ports, `host` (1:1) or `host:container`.";
      };

      udpPorts = opt "udpPorts" {
        type = lib.types.listOf (lib.types.either lib.types.port lib.types.str);
        default = [ ];
        example = [ "6881" ];
        description = ''
          Published UDP ports, in the same `host` (1:1) or `host:container` form
          as `ports`. The container gets them published `/udp` and the firewall
          opens them with `allowedUDPPorts` — a separate option because the
          firewall keeps TCP and UDP apart.
        '';
      };

      volumes = opt "volumes" {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Volume mounts, `host:container[:ro]`.";
      };

      settings = opt "settings" {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = ''
          The container's environment variables, in camelCase — each key is
          mapped to its upper-snake form (`someKey` -> `SOME_KEY`). Values are
          stringified: `true`/`false`, numbers, and lists (comma-joined), so
          `{ timezone = "UTC"; maxConnections = 10; debug = false; allow = [ "a" "b" ]; }`
          works.
        '';
      };

      cmd = opt "cmd" {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Command (and args) overriding the image's default.";
      };

      entrypoint = opt "entrypoint" {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Override the image's entrypoint (`--entrypoint`). Useful for running a
          binary bind-mounted from the store in a stock base image without a
          custom image build.
        '';
      };

      extraOptions = opt "extraOptions" {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra `docker`/`podman` run arguments.";
      };

      gpuPassthrough = opt "gpuPassthrough" {
        type = lib.types.bool;
        default = false;
        description = "Pass the host's configured Docker GPU mode into this container.";
      };

      memoryLimit = memoryLimitOption { inherit lib; };

      environmentFiles = opt "environmentFiles" {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Host files passed to the container with `--env-file` (dotenv format),
          for secrets that must not live in the Nix store — e.g. the
          `/run/secretspec/env` file a secretspec scope writes.
        '';
      };

      dockerMods = opt "dockerMods" {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "ghcr.io/vuetorrent/vuetorrent-lsio-mod:latest" ];
        description = ''
          LinuxServer `DOCKER_MODS` images, one reference per element. They are
          joined with `|` (that env var's own separator, not the comma `settings`
          lists produce) and installed at container start.

          **LinuxServer-base images only** — only they carry the
          `S6_STAGE2_HOOK=/docker-mods` that installs the mods; on any other
          image the variable is silently ignored. Enable it per service, only
          where a mod is actually wanted, never as a blanket default.
        '';
      };

      dependsOn = opt "dependsOn" {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Services (or systemd units) this container is started after — a bare
          name is this backend's container unit (`navidrome` becomes
          `after`/`requires` `docker-navidrome.service`); an entry already ending
          in `.service` is used verbatim (e.g. a host unit such as
          `docker-network-music.service`). Keeps ordering out of host files.
        '';
      };

      network = opt "network" {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                description = "Name of the user-defined docker network.";
              };
              subnet = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Subnet to create the network with (`docker network create
                  --subnet`). Declare it identically on every service that names
                  the same network; it only needs to be set once per network.
                '';
              };
              ip = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Static container IP on that network.";
              };
            };
          }
        );
        default = null;
        description = ''
          Join a user-defined network, creating it if needed — one declaration
          replaces an `extraOptions` `--network`/`--ip`, a host network unit, and
          the `dependsOn` on it.
        '';
      };

      openFirewall = opt "openFirewall" {
        type = lib.types.bool;
        default = true;
        description = "Open the published ports (TCP).";
      };
    };

  ordering =
    {
      lib,
      pkgs,
      spec,
      backend ? spec.backend or "docker",
    }:
    let
      network = spec.network or null;
      managedNetwork =
        network != null
        && !(builtins.elem network.name [
          "host"
          "none"
          "bridge"
        ]);
      units =
        map (d: if lib.hasSuffix ".service" d then d else "${backend}-${d}.service") (spec.dependsOn or [ ])
        ++ lib.optional managedNetwork "docker-network-${network.name}.service";
    in
    {
      networkArgs = lib.optionals (network != null) (
        [ "--network=${network.name}" ]
        ++ lib.optionals (network.ip != null) [
          "--ip"
          network.ip
        ]
      );
      inherit units;
      networkUnit = lib.optionalAttrs managedNetwork {
        "docker-network-${network.name}" = {
          description = "Create the `${network.name}` docker network";
          after = [ "docker.service" ];
          requires = [ "docker.service" ];
          wantedBy = [ "multi-user.target" ];
          path = [ pkgs.docker ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            docker network inspect ${network.name} >/dev/null 2>&1 || docker network create ${
              lib.optionalString (network.subnet != null) "--subnet ${network.subnet} "
            }${network.name}
          '';
        };
      };
    };

  config =
    {
      spec,
      defaults ? { },
    }:
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      settings = (defaults.settings or { }) // spec.settings;

      envKey = import ./camelToUpperSnake.nix { inherit lib; };

      envValue =
        v:
        if lib.isBool v then
          (if v then "true" else "false")
        else if lib.isList v then
          lib.concatStringsSep "," (map toString v)
        else
          toString v;

      environment = lib.mapAttrs' (k: v: lib.nameValuePair (envKey k) (envValue v)) (
        settings
        // lib.optionalAttrs (spec.dockerMods or [ ] != [ ]) {
          dockerMods = lib.concatStringsSep "|" spec.dockerMods;
        }
      );

      gpuMode = config.dots.system.docker.gpu or null;
      gpuEnabled = spec.gpuPassthrough or false;

      gpuEnvironment =
        lib.optionalAttrs (gpuEnabled && gpuMode == "nvidia") {
          NVIDIA_VISIBLE_DEVICES = "all";
          NVIDIA_DRIVER_CAPABILITIES = "compute,video,utility";
        }
        // lib.optionalAttrs (gpuEnabled && gpuMode == "intel") {
          LIBVA_DRIVER_NAME = "iHD";
        }
        // lib.optionalAttrs (gpuEnabled && gpuMode == "amd") {
          LIBVA_DRIVER_NAME = "radeonsi";
        };

      gpuOptions =
        lib.optionals (gpuEnabled && gpuMode == "nvidia") [
          "--device"
          "nvidia.com/gpu=all"
        ]
        ++ lib.optionals (gpuEnabled && (gpuMode == "intel" || gpuMode == "amd")) [
          "--device"
          "/dev/dri:/dev/dri"
        ];

      hostPort =
        p:
        let
          parts = lib.splitString ":" (toString p);
        in
        lib.toInt (lib.removeSuffix "/udp" (lib.elemAt parts (lib.max 0 (lib.length parts - 2))));

      network = spec.network or null;

      managedNetwork =
        network != null
        && !(builtins.elem network.name [
          "host"
          "none"
          "bridge"
        ]);

      dependsOnUnits =
        map (d: if lib.hasSuffix ".service" d then d else "${spec.backend}-${d}.service") (
          spec.dependsOn or [ ]
        )
        ++ lib.optional managedNetwork "docker-network-${network.name}.service";
    in
    {
      assertions = lib.optional gpuEnabled {
        assertion = gpuMode != null;
        message = "dots.system.docker.gpu must be set when gpuPassthrough is enabled.";
      };

      virtualisation = {
        docker.enable = lib.mkIf (spec.backend == "docker") true;

        oci-containers = {
          inherit (spec) backend;
          containers.${spec.name} = {
            inherit (spec)
              image
              volumes
              cmd
              environmentFiles
              ;
            extraOptions =
              lib.optional ((spec.memoryLimit or null) != null) "--memory=${spec.memoryLimit}"
              ++ gpuOptions
              ++ spec.extraOptions
              ++ lib.optionals (network != null) (
                [ "--network=${network.name}" ]
                ++ lib.optionals (network.ip != null) [
                  "--ip"
                  network.ip
                ]
              );
            entrypoint = spec.entrypoint or null;
            environment = environment // gpuEnvironment;
            ports =
              map (
                p:
                let
                  s = toString p;
                in
                if lib.hasInfix ":" s then s else "${s}:${s}"
              ) spec.ports
              ++ map (
                p:
                let
                  s = toString p;
                in
                if lib.hasInfix ":" s then "${s}/udp" else "${s}:${s}/udp"
              ) (spec.udpPorts or [ ]);
          };
        };
      };

      networking.firewall = lib.mkIf spec.openFirewall {
        allowedTCPPorts = map hostPort spec.ports;
        allowedUDPPorts = map hostPort (spec.udpPorts or [ ]);
      };

      systemd = {
        paths = lib.listToAttrs (
          lib.imap0 (
            i: file:
            lib.nameValuePair "docker-${spec.name}-env-${toString i}" {
              wantedBy = [ "multi-user.target" ];
              pathConfig = {
                PathChanged = file;
                Unit = "docker-${spec.name}-env-${toString i}.service";
              };
            }
          ) spec.environmentFiles
        );

        services =
          lib.listToAttrs (
            lib.imap0 (
              i: _:
              lib.nameValuePair "docker-${spec.name}-env-${toString i}" {
                serviceConfig = {
                  Type = "oneshot";
                  ExecStart = "${pkgs.systemd}/bin/systemctl restart ${spec.backend}-${spec.name}.service";
                };
              }
            ) spec.environmentFiles
          )
          // lib.optionalAttrs (dependsOnUnits != [ ]) {
            "${spec.backend}-${spec.name}" = {
              after = dependsOnUnits;
              requires = dependsOnUnits;
            };
          }
          // {
            "${spec.backend}-${spec.name}" = {
              startLimitBurst = lib.mkDefault (spec.startLimitBurst or 5);
              startLimitIntervalSec = lib.mkDefault (spec.startLimitIntervalSec or 60);
            };
          }
          // lib.optionalAttrs managedNetwork {
            "docker-network-${network.name}" = {
              description = "Create the `${network.name}` docker network";
              after = [ "docker.service" ];
              requires = [ "docker.service" ];
              wantedBy = [ "multi-user.target" ];
              path = [ pkgs.docker ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                docker network inspect ${network.name} >/dev/null 2>&1 || docker network create ${
                  lib.optionalString (network.subnet != null) "--subnet ${network.subnet} "
                }${network.name}
              '';
            };
          };
      };
    };
}
