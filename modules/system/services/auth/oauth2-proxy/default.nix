# oauth2-proxy — an OIDC reverse proxy / forward-auth gate for apps without
# native SSO (Glance). Runs on the host network so it can reach the app it
# fronts and be reached by the public proxy.
#
# Enabling this opens `port` (default 4180) and sets the listen address; the
# rest of the config (issuer, upstream, redirect URL, …) is host-supplied via
# `settings` (camelCase becomes `OAUTH2_PROXY_*`), and the client/cookie secrets
# arrive as `OAUTH2_PROXY_CLIENT_SECRET` / `OAUTH2_PROXY_COOKIE_SECRET` from an
# env file (the secretspec env file).
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "oauth2-proxy";
    image = "quay.io/oauth2-proxy/oauth2-proxy:latest";
    # Host networking, so `port` is bound on the host rather than published.
    ports = [ ];
    extraOptions = [ "--network=host" ];
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "auth"
    "oauth2-proxy"
  ];
  description = "oauth2-proxy OIDC gate (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      port = lib.mkOption {
        type = lib.types.port;
        default = 4180;
        description = "Port oauth2-proxy listens on (opened in the firewall).";
      };
    };

  toConfig =
    args: cfg:
    (mkDockerService.config {
      spec = cfg // {
        settings = {
          oauth2ProxyHttpAddress = "0.0.0.0:${toString cfg.port}";
        } // cfg.settings;
      };
      inherit defaults;
    } args)
    // {
      networking.firewall.allowedTCPPorts = [ cfg.port ];
    };
}
