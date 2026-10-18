# oauth2-proxy — OIDC reverse-proxy gates for apps without native SSO (Glance,
# Navidrome, …). Each entry under `gates` is its own container: it runs the OIDC
# login and proxies to one upstream app, so front a service by declaring one
# gate per app:
#
#   dots.system.services.auth.oauth2-proxy.gates.glance = {
#     enable = true;
#     port = 4180;
#     settings = { oauth2ProxyUpstreams = "http://127.0.0.1:8082"; … };
#   };
#
# The options are the shared container-service ones (`mkDockerService.options`),
# so a gate takes the same `network`, `dependsOn`, `settings`, … as any other
# service. A gate defaults to the host network — `network = { name = "host"; }`
# — so it reaches the app on `127.0.0.1` and is reachable by the front proxy;
# set `network = { name = …; subnet = …; ip = …; }` for a user-defined network
# with a static address, and the network's unit + the gate's ordering come from
# `mkDockerService.ordering`. `port` is published and opened in the firewall.
# The client/cookie secrets arrive as `OAUTH2_PROXY_CLIENT_SECRET` /
# `OAUTH2_PROXY_COOKIE_SECRET` from an env file (the secretspec env file).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  mkDockerService = import ../../../../../lib/mkDockerService.nix;
  camelToUpperSnake = import ../../../../../lib/camelToUpperSnake.nix { inherit lib; };

  defaults = {
    image = "quay.io/oauth2-proxy/oauth2-proxy:latest";
    network = {
      name = "host";
    };
    environmentFiles = [ "/run/secretspec/env" ];
  };

  optionType = lib.types.submodule {
    options = (mkDockerService.options { inherit lib defaults; }) // {
      enable = lib.mkEnableOption "this oauth2-proxy gate";
      port = lib.mkOption {
        type = lib.types.port;
        default = 4180;
        description = "Port oauth2-proxy listens on (published and opened in the firewall).";
      };
    };
  };

  # camelCase -> UPPER_SNAKE (oauth2ProxyClientId -> OAUTH2_PROXY_CLIENT_ID).
  envKey = camelToUpperSnake;

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
      type = lib.types.attrsOf optionType;
      default = { };
      description = "oauth2-proxy gates, one container per fronted app.";
    };
  };

  config =
    let
      gates = config.dots.system.services.auth.oauth2-proxy.gates;
      enabled = lib.filterAttrs (_: g: g.enable) gates;

      # The option-derived network args + ordering, shared with mkDockerService.
      wire =
        name: g:
        mkDockerService.ordering {
          inherit lib pkgs;
          spec = g // {
            name = "oauth2-proxy-${name}";
          };
        };

      container = name: g: {
        inherit (g)
          image
          volumes
          cmd
          environmentFiles
          ;
        extraOptions = g.extraOptions ++ (wire name g).networkArgs;
        # Every gate shares one Keycloak/OIDC config; a gate supplies only what
        # is its own (client id, upstream, redirect URL, extra roles).
        environment = lib.mapAttrs' (k: v: lib.nameValuePair (envKey k) (envValue v)) (
          {
            oauth2ProxyHttpAddress = "0.0.0.0:${toString g.port}";
            oauth2ProxyProvider = "keycloak-oidc";
            oauth2ProxyOidcIssuerUrl = "https://auth.${config.dots.system.core.domain}/realms/${config.dots.system.core.realm}";
            oauth2ProxyEmailDomains = "*";
            # Keycloak is the only identity source and an account may have no
            # email at all (or an unverified, foreign one). The gate authorizes
            # the authenticated Keycloak user, not the email claim, so don't
            # reject an id_token whose email is absent/unverified. The username
            # stands in for the email claim because oauth2-proxy insists on one
            # to build a session; the mirror uses the real email field separately.
            oauth2ProxyInsecureOidcAllowUnverifiedEmail = true;
            oauth2ProxyOidcEmailClaim = "preferred_username";
            oauth2ProxyReverseProxy = true;
            oauth2ProxySetXauthrequest = true;
            oauth2ProxyWhitelistDomains = ".${config.dots.system.core.domain}";
            oauth2ProxyCookieSecure = true;
            oauth2ProxySkipProviderButton = true;
            oauth2ProxyExcludeLoggingPaths = [ "/oauth2/callback" ];
          }
          // g.settings
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
