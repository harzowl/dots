# Asserts the exact-name `environment` option reaches the container unchanged and
# outranks the variable a `settings` key derives, so an image whose variables are
# not upper-snake keeps its own names (`Subsonic__Url`).
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
            settings = {
              someKey = "from-settings";
              otherKey = 1;
            };
            cmd = [ ];
            entrypoint = null;
            extraOptions = [ ];
            gpuPassthrough = false;
            memoryLimit = null;
            environmentFiles = [ ];
            dockerMods = [ ];
            dependsOn = [ ];
            network = null;
            openFirewall = false;
            startLimitBurst = 5;
            startLimitIntervalSec = 60;
            environment = {
              SOME_KEY = "exact-wins";
              Subsonic__Url = "http://probe.example.test:4533";
              numeric = 7;
              enabled = true;
            };
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

  environment = system.virtualisation.oci-containers.containers.probe.environment;

  expected = {
    SOME_KEY = "exact-wins";
    OTHER_KEY = "1";
    Subsonic__Url = "http://probe.example.test:4533";
    numeric = "7";
    enabled = "true";
  };

  wrong = lib.filter (name: (environment.${name} or null) != expected.${name}) (
    lib.attrNames expected
  );
  mapped = lib.filter (lib.flip lib.hasAttr environment) [
    "NUMERIC"
    "ENABLED"
  ];

  failures =
    lib.optional (wrong != [ ]) "wrong value for: ${lib.concatStringsSep ", " wrong}"
    ++ lib.optional (
      mapped != [ ]
    ) "exact names were rewritten to: ${lib.concatStringsSep ", " mapped}";
in
if failures == [ ] then
  pkgs.runCommand "docker-environment" { } ''
    mkdir -p "$out"
    printf '%s\n' "exact env names reach the container unchanged" > "$out/README"
  ''
else
  throw ''
    docker-environment check failed:
      ${lib.concatStringsSep "\n  " failures}

    rendered environment:
    ${builtins.toJSON environment}
  ''
