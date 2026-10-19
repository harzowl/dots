{
  config,
  lib,
  pkgs,
  services ? { },
  ...
}:
let
  mkDockerService = import ../../../../../lib/mkDockerService.nix;
  camelToUpperSnake = import ../../../../../lib/camelToUpperSnake.nix { inherit lib; };

  domain = config.dots.system.core.domain;

  defaults = {
    image = "quay.io/oauth2-proxy/oauth2-proxy:latest";
    network = {
      name = "host";
    };
    environmentFiles = [ "/run/secretspec/env" ];
  };

  optionType = lib.types.attrsOf (
    lib.types.submodule (
      { name, config, ... }:
      let
        inherit (config) service;
        sso = (services.${service} or { }).sso or { };
        redirectPath =
          if (sso.redirectPaths or [ ]) != [ ] then builtins.head sso.redirectPaths else "/oauth2/callback";
      in
      {
        options = (mkDockerService.options { inherit lib defaults; }) // {
          enable = lib.mkEnableOption "this oauth2-proxy gate" // {
            default = true;
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 4180;
            description = "Port oauth2-proxy listens on (published and opened in the firewall).";
          };
          service = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = ''
              Key into the consuming flake's `services` registry. The entry's
              `sso` block supplies the client id, redirect path and allowed
              roles.
            '';
          };
          clientId = lib.mkOption {
            type = lib.types.str;
            default = sso.clientId or "oauth2-proxy-${service}";
            description = "OIDC client id, taken from the service registry.";
          };
          redirectUrl = lib.mkOption {
            type = lib.types.str;
            default = "https://${service}.${domain}${redirectPath}";
            description = "OIDC redirect URL, derived from the service's host and redirect path.";
          };
          allowedRoles = lib.mkOption {
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
            default = sso.allowedRoles or null;
            description = "Roles a user must hold to pass the gate; `null` allows any authenticated user.";
          };
        };
      }
    )
  );

  envKey = camelToUpperSnake;
  gateEnvKey =
    k: envKey ("oauth2Proxy" + lib.toUpper (builtins.substring 0 1 k) + builtins.substring 1 (-1) k);

  envValue =
    v:
    if lib.isBool v then
      (if v then "true" else "false")
    else if lib.isList v then
      lib.concatStringsSep "," (map toString v)
    else
      toString v;
in
{
  options.dots.system.services.auth.oauth2-proxy = {
    gates = lib.mkOption {
      type = optionType;
      default = { };
      description = "oauth2-proxy gates, one container per fronted app.";
    };
  };

  config =
    let
      gates = config.dots.system.services.auth.oauth2-proxy.gates;
      enabled = lib.filterAttrs (_: g: g.enable) gates;

      wire =
        name: g:
        mkDockerService.ordering {
          inherit lib pkgs;
          spec = g // {
            name = "oauth2-proxy-${name}";
          };
        };

      settingsFor =
        g:
        {
          inherit (g) clientId redirectUrl;
        }
        // lib.optionalAttrs (g.allowedRoles != null) {
          inherit (g) allowedRoles;
        }
        // g.settings;

      container = name: g: {
        inherit (g)
          image
          volumes
          cmd
          environmentFiles
          ;
        extraOptions = g.extraOptions ++ (wire name g).networkArgs;
        environment = lib.mapAttrs' (k: v: lib.nameValuePair (gateEnvKey k) (envValue v)) (
          {
            httpAddress = "0.0.0.0:${toString g.port}";
            provider = "keycloak-oidc";
            oidcIssuerUrl = "https://auth.${config.dots.system.core.domain}/realms/${config.dots.system.core.realm}";
            emailDomains = "*";
            insecureOidcAllowUnverifiedEmail = true;
            oidcEmailClaim = "preferred_username";
            reverseProxy = true;
            setXauthrequest = true;
            whitelistDomains = ".${config.dots.system.core.domain}";
            cookieSecure = true;
            skipProviderButton = true;
            excludeLoggingPaths = [ "/oauth2/callback" ];
          }
          // settingsFor g
        );
        ports = map (
          p:
          let
            s = toString p;
          in
          if lib.hasInfix ":" s then s else "${s}:${s}"
        ) [ g.port ];
      };
    in
    {
      virtualisation.oci-containers.containers = lib.mapAttrs' (
        name: g: lib.nameValuePair "oauth2-proxy-${name}" (lib.mkIf g.enable (container name g))
      ) gates;

      networking.firewall.allowedTCPPorts = map (g: g.port) (lib.attrValues enabled);

      systemd.services =
        lib.mapAttrs' (
          name: g:
          lib.nameValuePair "docker-oauth2-proxy-${name}" {
            after = (wire name g).units;
            requires = (wire name g).units;
            # A gate can't start until the IdP answers OIDC discovery, so a
            # Keycloak (re)start would otherwise kill it for good: disable the
            # start-rate limit so the unit keeps retrying until the IdP is back.
            startLimitIntervalSec = 0;
            serviceConfig.RestartSec = 5;
          }
        ) enabled
        // lib.foldl' (acc: name: acc // (wire name enabled.${name}).networkUnit) { } (
          lib.attrNames enabled
        );
    };
}
