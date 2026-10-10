# A reusable OCI-container spec. `options` is the submodule type for a container
# spec; `config` turns a spec into the NixOS config that runs it — turning the
# backend on for the host (so enabling a container service brings up docker or
# podman), defining the container, publishing its ports and opening the firewall.
#
# A service module exposes `options` as a nested option and calls `config`:
#
#   options.container = lib.mkOption {
#     type = lib.types.submodule mkDockerContainer.options;
#     default = { name = "app"; image = "example/app:latest"; ports = [ 3000 ]; };
#   };
#   toConfig = args: cfg: mkDockerContainer.config cfg.container args;
#
# `ports` entries are `host` (published 1:1) or `host:container`; the host side is
# what the firewall opens. `backend` selects docker (default) or podman.
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
          description = "OCI image reference, e.g. `codeberg.org/aryak/mozhi:latest`.";
        };

        backend = lib.mkOption {
          type = lib.types.enum [
            "docker"
            "podman"
          ];
          default = "docker";
          description = "Container backend; enabling a container turns it on for the host.";
        };

        ports = lib.mkOption {
          type = lib.types.listOf (lib.types.either lib.types.port lib.types.str);
          default = [ ];
          description = "Published ports, `host` (1:1) or `host:container`; the host side is opened in the firewall.";
        };

        volumes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Volume mounts, `host:container[:ro]`.";
        };

        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Environment variables for the container.";
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
          description = "Open the published ports.";
        };
      };
    };

  config =
    spec: { lib, ... }:
    let
      # "host" or "host:container" → the host port (for the firewall).
      hostPort = p: lib.head (lib.splitString ":" (toString p));
    in
    {
      virtualisation = {
        docker.enable = lib.mkIf (spec.backend == "docker") true;

        oci-containers = {
          inherit (spec) backend;
          containers.${spec.name} = {
            inherit (spec) image volumes environment cmd extraOptions;
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
