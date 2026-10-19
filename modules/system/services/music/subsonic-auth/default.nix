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
        description = "Navidrome base URL the shim proxies to (the fallback for any path no `routes` entry matches).";
      };
      routes = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                description = "Path prefix whose requests are proxied to `upstream`.";
              };
              upstream = lib.mkOption {
                type = lib.types.str;
                description = "Base URL requests under `path` are proxied to.";
              };
            };
          }
        );
        default = [ ];
        description = ''
          Path → upstream routes, matched by the longest whole-segment path prefix
          (`/rest` matches `/rest` and `/rest/…`, but not `/restless`), with
          `upstream` as the fallback. Lets a subpath go to a different upstream —
          e.g. `/rest` to a discovery proxy while the rest goes to Navidrome.
        '';
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
      requiredRole = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Realm role a PAT must carry to authenticate here. Sent to the PAT SPI as
          `X-Required-Role`, so a token minted for another service is refused
          (403). Empty accepts any valid PAT for the user.
        '';
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
      stateDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/subsonic-auth";
        description = ''
          Host directory holding the per-user PAT store (AES-256-GCM encrypted
          at rest), mounted read-write at the same path in the container. The
          key (`SUBSONIC_PAT_KEY`) comes from `environmentFiles`, never here.
        '';
      };
      revalidateInterval = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = ''
          Go duration between passes that re-check every stored PAT against the
          Keycloak PAT SPI and drop the revoked ones. This bounds how long a
          revoked PAT can keep authenticating an md5-only client.
        '';
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;
      binary = pkgs.callPackage ./package.nix { };
    in
    mkDockerService.config {
      spec = cfg // {
        ports = [ cfg.port ];
        entrypoint = "/usr/local/bin/subsonic-auth";
        volumes = [
          "${binary}/bin/subsonic-auth:/usr/local/bin/subsonic-auth:ro"
          "${cfg.stateDir}:${cfg.stateDir}"
        ];
        settings = {
          listenAddr = "0.0.0.0:${toString cfg.port}";
          inherit (cfg) upstream;
          routes = lib.concatMapStringsSep "," (r: "${r.path}=${r.upstream}") cfg.routes;
          inherit (cfg) keycloakUrl;
          keycloakRealm = cfg.realm;
          keycloakRequiredRole = cfg.requiredRole;
          inherit (cfg) identityHeader;
          inherit (cfg) cacheTtl;
          inherit (cfg) cacheSize;
          # The signing key (SUBSONIC_TOKEN_KEY) and the PAT store key
          # (SUBSONIC_PAT_KEY) are NOT here — they come from `environmentFiles`
          # so they never enter the Nix store.
          subsonicTokenKid = cfg.tokenKid;
          subsonicTokenTtl = cfg.tokenTtl;
          subsonicTokenAud = cfg.tokenAud;
          inherit (cfg) validateTimeout;
          patStoreDir = cfg.stateDir;
          patRevalidateInterval = cfg.revalidateInterval;
        };
      };
      inherit defaults;
    } args;
}
