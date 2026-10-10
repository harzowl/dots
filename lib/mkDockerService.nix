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
    { lib, defaults ? { } }:
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

      extraOptions = opt "extraOptions" {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra `docker`/`podman` run arguments.";
      };

      openFirewall = opt "openFirewall" {
        type = lib.types.bool;
        default = true;
        description = "Open the published ports (TCP).";
      };
    };

  config =
    { spec, defaults ? { } }:
    { lib, ... }:
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

      # "host" or "host:container" -> the host port (for the firewall).
      hostPort = p: lib.head (lib.splitString ":" (toString p));
    in
    {
      virtualisation = {
        docker.enable = lib.mkIf (spec.backend == "docker") true;

        oci-containers = {
          inherit (spec) backend;
          containers.${spec.name} = {
            inherit (spec) image volumes cmd extraOptions;
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
    };
}
