# Asserts a `dependsOn` entry reaches the container unit's `after`/`requires`,
# so a service that must start after a sidecar only has to name it. The unit is
# one attrset built with `//`, so an ordering block added beside the base one is
# silently dropped — this evaluates the merged unit, not the option source.
{ lib, pkgs }:
let
  mkDockerService = import ../lib/mkDockerService.nix;

  system =
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      modules = [
        (mkDockerService.config {
          spec = {
            name = "probe";
            image = "alpine:latest";
            backend = "docker";
            ports = [ ];
            udpPorts = [ ];
            volumes = [ ];
            settings = { };
            cmd = [ ];
            entrypoint = null;
            extraOptions = [ ];
            gpuPassthrough = false;
            memoryLimit = null;
            environmentFiles = [ ];
            dockerMods = [ ];
            dependsOn = [
              "alpha"
              "beta.service"
            ];
            network = null;
            openFirewall = false;
            startLimitBurst = 5;
            startLimitIntervalSec = 60;
          };
        })
        (_: {
          system.stateVersion = "26.05";
          boot.loader.grub.devices = [ "nodev" ];
          fileSystems."/" = {
            device = "/dev/sda1";
            fsType = "ext4";
          };
        })
      ];
    }).config;

  unit = system.systemd.services.docker-probe;
  expected = [
    "docker-alpha.service"
    "beta.service"
  ];

  missingAfter = lib.filter (entry: !(builtins.elem entry unit.after)) expected;
  missingRequires = lib.filter (entry: !(builtins.elem entry unit.requires)) expected;

  failures =
    lib.optional (
      missingAfter != [ ]
    ) "dependsOn entries missing from after: ${lib.concatStringsSep ", " missingAfter}"
    ++ lib.optional (
      missingRequires != [ ]
    ) "dependsOn entries missing from requires: ${lib.concatStringsSep ", " missingRequires}";
in
if failures == [ ] then
  pkgs.runCommand "docker-depends-on" { } ''
    mkdir -p "$out"
    printf '%s\n' "dependsOn entries order the container unit" > "$out/README"
  ''
else
  throw ''
    docker-depends-on check failed:
      ${lib.concatStringsSep "\n  " failures}

    rendered unit:
      after = ${builtins.toJSON unit.after}
      requires = ${builtins.toJSON unit.requires}
  ''
