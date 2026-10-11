# oauth2-proxy — the forward-auth OIDC gate for apps without native SSO
# (Glance). Caddy calls its `/oauth2/auth` endpoint before proxying a request.
#
# Everything is set by the host through `settings` (camelCase becomes an
# `OAUTH2_PROXY_*` env var — `oauth2ProxyOidcIssuerUrl` ->
# `OAUTH2_PROXY_OIDC_ISSUER_URL`); the container has no config file. The client
# and cookie secrets arrive as `OAUTH2_PROXY_CLIENT_SECRET` /
# `OAUTH2_PROXY_COOKIE_SECRET` from an env file (the secretspec env file).
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "oauth2-proxy";
    image = "quay.io/oauth2-proxy/oauth2-proxy:latest";
    ports = [ "4180:4180" ];
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "auth"
    "oauth2-proxy"
  ];
  description = "oauth2-proxy forward-auth gate (OCI container)";

  options =
    { lib, ... }:
    mkDockerService.options { inherit lib defaults; };

  toConfig = args: cfg: mkDockerService.config { spec = cfg; inherit defaults; } args;
}
