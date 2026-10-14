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
# A raw `t`/`s` (md5) credential cannot be checked against a PAT: it is answered
# with Subsonic error 41 ("token auth unsupported") over HTTP 200, in the format
# the client asked for (`f`; XML is the default), which is the signal a client
# that computes the md5 keys on to retry with the credential in plaintext `p`
# instead. Positive validations are cached briefly (keyed by the sha256 of
# `user\x00token`; the plaintext is never stored) so polling/streaming does not
# hit Keycloak per request.
#
# Native API clients that expect Navidrome's own login — desktop Feishin's
# "Navidrome" server type does `POST /auth/login` and then sends
# `X-Nd-Authorization: Bearer <token>` on `/api/*` (and `t=<token>` on `/rest`)
# — cannot use a PAT as a Navidrome password. The shim answers `/auth/login`
# itself, validating the JSON body's password as a Keycloak PAT, and returns a
# short-lived **signed** token as both `subsonicToken` and `token`. The raw PAT
# is never handed back, so it cannot leak through a URL, a client store or a log
# line; the signed token is stateless (it survives a shim restart until it
# expires) and is bound to the identity and an audience. The signing key comes
# from `environmentFiles` (the secretspec env file), never from `settings`.
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
      tokenKid = lib.mkOption {
        type = lib.types.str;
        default = "1";
        description = ''
          Key id (`kid`) of the active token-signing key. To rotate, deploy a new
          key under a new `kid` and set `SUBSONIC_TOKEN_KEY_PREVIOUS` /
          `SUBSONIC_TOKEN_KID_PREVIOUS` to the old one until its tokens expire.
        '';
      };
      tokenTtl = lib.mkOption {
        type = lib.types.str;
        default = "7d";
        description = ''
          Lifetime of a signed subsonic token (a Go duration, or a `Nd` day
          count). Clients cache it and re-login when it expires, so keep it
          short — it is what bounds a leaked token, since the shim is stateless.
        '';
      };
      tokenAud = lib.mkOption {
        type = lib.types.str;
        default = "subsonic";
        description = "Audience bound into signed tokens and checked on verify.";
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
        settings = {
          listenAddr = "0.0.0.0:${toString cfg.port}";
          inherit (cfg) upstream;
          inherit (cfg) keycloakUrl;
          keycloakRealm = cfg.realm;
          inherit (cfg) identityHeader;
          inherit (cfg) cacheTtl;
          inherit (cfg) cacheSize;
          # The signing key (SUBSONIC_TOKEN_KEY) is NOT here — it comes from
          # `environmentFiles` so it never enters the Nix store.
          subsonicTokenKid = cfg.tokenKid;
          subsonicTokenTtl = cfg.tokenTtl;
          subsonicTokenAud = cfg.tokenAud;
          inherit (cfg) validateTimeout;
        };
      };
      inherit defaults;
    } args;
}
