# oauth2-proxy — OIDC reverse-proxy gates for apps without native SSO (Glance,
# Navidrome, …). Each entry under `gates` is its own container: it runs the OIDC
# login and proxies to one upstream app, so front a service by declaring one gate
# per app:
#
#   dots.system.services.auth.oauth2-proxy.gates.glance = {
#     enable = true;
#     port = 4180;
#     settings = { oauth2ProxyUpstreams = "http://127.0.0.1:8082"; … };
#   };
#
# Gates run on the host network (so they reach the app on the host and are
# reachable by the front proxy) and `port` is opened in the firewall. The config
# is host-supplied via `settings` (camelCase becomes `OAUTH2_PROXY_*`), and the
# client/cookie secrets arrive as `OAUTH2_PROXY_CLIENT_SECRET` /
# `OAUTH2_PROXY_COOKIE_SECRET` from an env file (the secretspec env file).
{ config, lib, ... }:
let
  optionType = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "this oauth2-proxy gate";
      image = lib.mkOption {
        type = lib.types.str;
        default = "quay.io/oauth2-proxy/oauth2-proxy:latest";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 4180;
        description = "Port oauth2-proxy listens on (opened in the firewall).";
      };
      ports = lib.mkOption {
        type = lib.types.listOf (lib.types.either lib.types.port lib.types.str);
        default = [ ];
      };
      volumes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      cmd = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
    };
  };

  # camelCase -> UPPER_SNAKE (oauth2ProxyClientId -> OAUTH2_PROXY_CLIENT_ID).
  envKey =
    k:
    lib.toUpper (
      lib.removePrefix "_" (
        lib.concatMapStrings (c: if c != lib.toLower c then "_" + lib.toLower c else c) (
          lib.stringToCharacters k
        )
      )
    );

  envValue =
    v:
    if lib.isBool v then
      (if v then "true" else "false")
    else if lib.isList v then
      lib.concatStringsSep "," (map toString v)
    else
      toString v;

  hostPort = p: lib.head (lib.splitString ":" (toString p));
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
      enabled = lib.filterAttrs (_: g: g.enable) config.dots.system.services.auth.oauth2-proxy.gates;

      mkContainer = g: {
        inherit (g) image volumes cmd environmentFiles;
        extraOptions = [ "--network=host" ];
        environment = lib.mapAttrs' (k: v: lib.nameValuePair (envKey k) (envValue v)) (
          { oauth2ProxyHttpAddress = "0.0.0.0:${toString g.port}"; } // g.settings
        );
        ports = map (
          p:
          let
            s = toString p;
          in
          if lib.hasInfix ":" s then s else "${s}:${s}"
        ) g.ports;
      };
    in
    lib.mkIf (enabled != { }) {
      virtualisation.docker.enable = true;

      virtualisation.oci-containers = {
        backend = "docker";
        containers = lib.mapAttrs' (name: g: lib.nameValuePair "oauth2-proxy-${name}" (mkContainer g)) enabled;
      };

      networking.firewall.allowedTCPPorts = map (g: g.port) (lib.attrValues enabled);
    };
}
