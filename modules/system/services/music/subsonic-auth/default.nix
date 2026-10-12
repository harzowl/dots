# subsonic-auth — a small reverse proxy that lets *native* Subsonic clients
# authenticate to Navidrome with their **Keycloak** credentials.
#
# Navidrome has no native OIDC, so the browser client (Feishin) is gated by
# oauth2-proxy. Native clients (Symfonium, play:Sub, …) can't do the browser
# flow, so this shim stands in front of the Navidrome API: it takes the client's
# credential (HTTP Basic, or Subsonic `u`/`p` — `p` may be `enc:<hex>`),
# validates it against a Keycloak **personal access token** (the PAT SPI's
# `/personal-access-token/auth` endpoint, HTTP Basic `user:PAT`), and on success
# proxies to Navidrome with a single trusted identity header.
#
# A raw `t`/`s` (md5) credential cannot be checked against a PAT and is
# rejected, but `t` may carry a PAT directly (that is what `/auth/login` hands
# back, below). Positive validations are cached briefly (keyed by the sha256 of
# `user\x00token`; the plaintext is never stored) so polling/streaming does not
# hit Keycloak per request.
#
# Native API clients that expect Navidrome's own login — desktop Feishin's
# "Navidrome" server type does `POST /auth/login` and then sends
# `X-Nd-Authorization: Bearer <token>` on `/api/*` (and `t=<token>` on `/rest`)
# — cannot use a PAT as a Navidrome password. The shim answers `/auth/login`
# itself, validating the JSON body's password as a Keycloak PAT, and returns
# both: `subsonicToken` is the PAT, so Feishin's `/rest` credential keeps
# working across a shim restart; `token` is an opaque session the client
# replays on `/api/*`. Sessions live in an in-memory TTL cache, so the `/api`
# client re-logs-in with its saved PAT when one expires, while `/rest` requests
# resolve `t` as a session first and otherwise re-validate it as a PAT against
# Keycloak using the request's `u`.
#
# The container runs the statically linked binary bind-mounted into a stock
# `alpine` image (no custom image build). It joins a user-defined network with a
# fixed IP so Navidrome can trust exactly that address, and relies on the front
# proxy to only route API paths here; it strips every client-supplied identity
# header itself regardless.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "subsonic-auth";
    image = "alpine:latest";
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "music"
    "subsonic-auth"
  ];
  description = "Native Subsonic auth via Keycloak personal access tokens (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      network = lib.mkOption {
        type = lib.types.str;
        default = "music";
        description = "Docker network the shim joins (must be the one Navidrome is on).";
      };
      ip = lib.mkOption {
        type = lib.types.str;
        default = "172.30.0.30";
        description = "Static container IP; this is what Navidrome must trust to set the header.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 4184;
        description = ''
          Port the shim listens on, published 1:1 on the host so the front proxy
          reaches it. The container's HTTP server binds the same port.
        '';
      };
      upstream = lib.mkOption {
        type = lib.types.str;
        default = "http://172.30.0.10:4533";
        description = "Navidrome base URL the shim proxies to.";
      };
      keycloakUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://172.30.0.1:8080";
        description = ''
          Keycloak base URL. Defaults to the docker bridge gateway (the host,
          where Keycloak runs on the host network) — no DNS or TLS round-trip.
        '';
      };
      realm = lib.mkOption {
        type = lib.types.str;
        description = "Keycloak realm holding the users and their PATs.";
      };
      identityHeader = lib.mkOption {
        type = lib.types.str;
        default = "X-Forwarded-Preferred-Username";
        description = "Header carrying the authenticated username to Navidrome.";
      };
      cacheTtl = lib.mkOption {
        type = lib.types.str;
        default = "60s";
        description = "Go duration a positive validation is cached (e.g. `60s`).";
      };
      cacheSize = lib.mkOption {
        type = lib.types.int;
        default = 4096;
        description = "Maximum number of cached validations (bounded).";
      };
      sessionTtl = lib.mkOption {
        type = lib.types.str;
        default = "12h";
        description = ''
          Go duration a /auth/login session token stays valid. Sessions live in
          memory only, so a restart drops them and the client re-logs-in with
          its saved PAT.
        '';
      };
      validateTimeout = lib.mkOption {
        type = lib.types.str;
        default = "5s";
        description = "Go duration timeout for a Keycloak validation request.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) pkgs;
      binary = pkgs.callPackage ./package.nix { };
    in
    mkDockerService.config {
      spec = cfg // {
        # Listen on the same port that is published 1:1 on the host.
        ports = [ cfg.port ];
        # Run the store binary directly; alpine has no entrypoint of its own.
        entrypoint = "/usr/local/bin/subsonic-auth";
        volumes = [ "${binary}/bin/subsonic-auth:/usr/local/bin/subsonic-auth:ro" ];
        extraOptions = [
          "--network=${cfg.network}"
          "--ip"
          cfg.ip
        ];
        settings = {
          listenAddr = "0.0.0.0:${toString cfg.port}";
          upstream = cfg.upstream;
          keycloakUrl = cfg.keycloakUrl;
          keycloakRealm = cfg.realm;
          identityHeader = cfg.identityHeader;
          cacheTtl = cfg.cacheTtl;
          cacheSize = cfg.cacheSize;
          sessionTtl = cfg.sessionTtl;
          validateTimeout = cfg.validateTimeout;
        };
      };
      inherit defaults;
    } args;
}
