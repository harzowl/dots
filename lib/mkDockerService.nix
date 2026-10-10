# A reusable declarative container SERVICE. `options` is the submodule type for a
# service spec; `config` turns a spec into the NixOS config that runs it. It is
# shaped like a native NixOS service: the image's environment variables are set
# through `settings` with camelCase keys, mapped to the upper-snake env vars the
# container expects (`someKey` -> `SOME_KEY`, `maxPlayers` -> `MAX_PLAYERS`).
#
#   options.container = lib.mkOption {
#     type = lib.types.submodule mkDockerService.options;
#     default = { name = "app"; image = "example/app:latest";
#                 ports = [ 3000 ]; settings = { someKey = "test"; }; };
#   };
#   toConfig = args: cfg: mkDockerService.config cfg.container args;
#
# Enabling a service also turns the backend on for the host (docker by default).
# `ports` entries are `host` (published 1:1) or `host:container`; the host side is
# opened in the firewall.
{
  options =
    { lib, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          description = "Container name (also the systemd unit suffix).";
        };

        image = lib.mkOption {
          type = lib.types.str;
          description = "OCI image reference, e.g. `itzg/minecraft-server:latest`.";
        };

        backend = lib.mkOption {
          type = lib.types.enum [
            "docker"
            "podman"
          ];
          default = "docker";
          description = "Container backend; enabling a service turns it on for the host.";
        };

        ports = lib.mkOption {
          type = lib.types.listOf (lib.types.either lib.types.port lib.types.str);
          default = [ ];
          description = "Published TCP ports, `host` (1:1) or `host:container`.";
        };

        volumes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Volume mounts, `host:container[:ro]`.";
        };

        settings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = ''
            The container's environment variables, in camelCase — each key is
            mapped to its upper-snake form (`someKey` -> `SOME_KEY`). Values are
            stringified: `true`/`false`, numbers, and lists (comma-joined), so
            `{ maxPlayers = 10; onlineMode = false; }` works.
          '';
        };

        cmd = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Command (and args) overriding the image's default.";
        };

        extraOptions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra `docker`/`podman` run arguments.";
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open the published ports (TCP).";
        };
      };
    };

  config =
    spec: { lib, ... }:
    let
      # camelCase -> UPPER_SNAKE (someKey -> SOME_KEY, maxPlayers -> MAX_PLAYERS).
      envKey =
        k:
        let
          body = lib.concatMapStrings (
            c: if c != lib.toLower c then "_" + lib.toLower c else c
          ) (lib.stringToCharacters k);
          trimmed = lib.removePrefix "_" body;
        in
        lib.toUpper trimmed;

      # Values -> env strings (bool/number/string/list).
      envValue =
        v:
        if lib.isBool v then
          (if v then "true" else "false")
        else if lib.isList v then
          lib.concatStringsSep "," (map toString v)
        else
          toString v;

      environment = lib.mapAttrs' (k: v: lib.nameValuePair (envKey k) (envValue v)) spec.settings;

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
