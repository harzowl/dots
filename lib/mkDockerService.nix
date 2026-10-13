# A reusable declarative container SERVICE, shaped like a native NixOS service.
# It exports two pieces a service module reuses directly (so the service's own
# options ARE the container's — no `container` wrapper):
#
#   options = mkDockerService.options { inherit lib; defaults = { … }; };
#   toConfig = args: cfg: mkDockerService.config cfg args;
#
# `options` returns the option declarations (name, image, backend, ports,
# volumes, settings, cmd, extraOptions, openFirewall), with `defaults` folded in.
# The image's environment variables are set through `settings` with camelCase
# keys, mapped to the upper-snake env vars the container expects
# (`someKey` -> `SOME_KEY`, `maxPlayers` -> `MAX_PLAYERS`). Enabling a service
# also turns the backend on for the host (docker by default).
{
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
        description = "OCI image reference, e.g. `itzg/minecraft-server:latest`.";
      };

      backend = opt "backend" {
        type = lib.types.enum [
          "docker"
          "podman"
        ];
        default = "docker";
        description = "Container backend; enabling a service turns it on for the host.";
      };

      ports = opt "ports" {
        type = lib.types.listOf (lib.types.either lib.types.port lib.types.str);
        default = [ ];
        description = "Published TCP ports, `host` (1:1) or `host:container`.";
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
          `{ maxPlayers = 10; onlineMode = false; whitelist = [ "a" "b" ]; }`
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

      environmentFiles = opt "environmentFiles" {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Host files passed to the container with `--env-file` (dotenv format),
          for secrets that must not live in the Nix store — e.g. the
          `/run/secretspec/env` file a secretspec scope writes.
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

  # The option-derived wiring a container needs — the `--network`/`--ip` run
  # args, the `after`/`requires` unit list (`dependsOn` plus a user-defined
  # network's unit), and that network's creating unit. Exported so a module that
  # builds its own container (the oauth2-proxy gates) reuses the same ordering
  # instead of re-implementing it.
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
      # Both `after` and `requires` are this list.
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
    { lib, pkgs, ... }:
    let
      # Merge the service's default settings with the user's (an option default
      # does not merge with a partial definition).
      settings = (defaults.settings or { }) // spec.settings;

      # camelCase -> UPPER_SNAKE (someKey -> SOME_KEY, maxPlayers -> MAX_PLAYERS).
      envKey =
        k:
        lib.toUpper (
          lib.removePrefix "_" (
            lib.concatMapStrings (c: if c != lib.toLower c then "_" + lib.toLower c else c) (
              lib.stringToCharacters k
            )
          )
        );

      # Values -> env strings (bool/number/string/list).
      envValue =
        v:
        if lib.isBool v then
          (if v then "true" else "false")
        else if lib.isList v then
          lib.concatStringsSep "," (map toString v)
        else
          toString v;

      environment = lib.mapAttrs' (k: v: lib.nameValuePair (envKey k) (envValue v)) settings;

      # "container", "host:container" or "ip:host:container" -> the host port
      # (for the firewall); the last segment is always the container port.
      hostPort =
        p:
        let
          parts = lib.splitString ":" (toString p);
        in
        lib.toInt (lib.elemAt parts (lib.max 0 (lib.length parts - 2)));

      # The declared network, if any: the container joins it and starts after it.
      network = spec.network or null;

      # Only a *user-defined* network gets a unit to create and wait for; the
      # pre-defined `host`/`none`/`bridge` ones must not be `docker network
      # create`d.
      managedNetwork =
        network != null
        && !(builtins.elem network.name [
          "host"
          "none"
          "bridge"
        ]);

      # `dependsOn` -> systemd unit names. A bare service name is this backend's
      # container unit (`navidrome` -> `docker-navidrome.service`); an entry that
      # already ends in `.service` is taken verbatim. The declared network is
      # always appended so the container waits for it.
      dependsOnUnits =
        map (d: if lib.hasSuffix ".service" d then d else "${spec.backend}-${d}.service") (
          spec.dependsOn or [ ]
        )
        ++ lib.optional managedNetwork "docker-network-${network.name}.service";
    in
    {
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
            # Join the declared network (with its static IP) if set.
            extraOptions =
              spec.extraOptions
              ++ lib.optionals (network != null) (
                [ "--network=${network.name}" ]
                ++ lib.optionals (network.ip != null) [
                  "--ip"
                  network.ip
                ]
              );
            entrypoint = spec.entrypoint or null;
            inherit environment;
            ports = map (
              p:
              let
                s = toString p;
              in
              if lib.hasInfix ":" s then s else "${s}:${s}"
            ) spec.ports;
          };
        };
      };

      networking.firewall.allowedTCPPorts = lib.mkIf spec.openFirewall (
        map (p: builtins.fromJSON (hostPort p)) spec.ports
      );

      # Restart the container when a runtime env file's *contents* change.
      #
      # NixOS change-detection only reacts to unit *definitions*, never to files
      # a unit merely references — and `environmentFiles` live in /run (absent at
      # build time), so `restartTriggers` cannot watch them. Each such file gets
      # a path unit that, when the file is written (e.g. a rotated secret),
      # triggers a oneshot which restarts the container. A path activation only
      # *starts* an inactive unit, hence the explicit restart.
      systemd.paths = lib.listToAttrs (
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

      systemd.services =
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
          # Start after (and stay bound to) whatever the service depends on.
          "${spec.backend}-${spec.name}" = {
            after = dependsOnUnits;
            requires = dependsOnUnits;
          };
        }
        // lib.optionalAttrs managedNetwork {
          # Create the user-defined network once (idempotent); every service that
          # names it declares the same unit, which the module system merges.
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
}
