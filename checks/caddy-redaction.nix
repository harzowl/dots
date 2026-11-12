# Asserts the Caddy access-log filter deletes the session-binding
# `X-Nd-Authorization` header in both directions. The assertion runs on the
# rendered `logFormat` (the text the NixOS caddy module writes into the
# Caddyfile), not on the option source, so a filter that never reaches a vhost
# fails. Includes a mutation of that rendered text as a negative fixture: each
# rule, once removed, must make the same predicate report it missing.
{ lib, pkgs }:
let
  module = import ../modules/system/services/proxy/caddy/default.nix;

  # Minimal option stubs for the options the caddy module reads or writes; the
  # real NixOS caddy module and firewall are irrelevant to the rendered format.
  harness =
    { lib, ... }:
    {
      options = {
        assertions = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
        dots.system = {
          core.domain = lib.mkOption {
            type = lib.types.str;
            default = "example.test";
          };
          networking.wireguard.mesh.memberIps = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
        };
        services.caddy = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          email = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          globalConfig = lib.mkOption {
            type = lib.types.lines;
            default = "";
          };
          virtualHosts = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
        };
        networking.firewall = {
          allowedTCPPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
          };
          allowedUDPPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
          };
        };
      };
    };

  evaluated = lib.evalModules {
    modules = [
      module
      harness
      {
        dots.system.services.proxy.caddy = {
          enable = true;
          virtualHosts."app.example.test" = {
            extraConfig = "";
          };
        };
      }
    ];
  };

  rendered = evaluated.config.services.caddy.virtualHosts."app.example.test".logFormat;

  required = [
    "request>headers>X-Nd-Authorization delete"
    "resp_headers>X-Nd-Authorization delete"
  ];
  present = rule: lib.hasInfix rule rendered;
  remove = rule: lib.replaceStrings [ rule ] [ "" ] rendered;

  missing = builtins.filter (rule: !present rule) required;
  # Removing the rule from the rendered text must make the predicate fail; a
  # predicate that cannot see the removal proves nothing about the real format.
  undetected = builtins.filter (rule: present (remove rule)) required;

  failures =
    lib.optional (missing != [ ]) "rendered log format is missing: ${lib.concatStringsSep ", " missing}"
    ++ map (rule: "negative fixture did not detect removal of: ${rule}") undetected;
in
if failures == [ ] then
  pkgs.runCommand "caddy-redaction" { } ''
    mkdir -p "$out"
    printf '%s\n' ${lib.escapeShellArg rendered} > "$out/rendered-log-format"
    printf '%s\n' "caddy access-log redaction: request and response rules present" > "$out/README"
  ''
else
  throw ''
    caddy-redaction check failed:
      ${lib.concatStringsSep "\n  " failures}

    rendered log format:
    ${rendered}
  ''
