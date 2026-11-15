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
      adminUser = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Keycloak identity whose `/auth/login` is reported as an admin
          (`isAdmin: true`). Octo captures a standing admin token only from such a
          login, which is what its native library and scan calls need; empty
          reports nobody as admin.
        '';
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
          count). Tokens minted for a PAT login carry the PAT hash (`ph`), and
          every request re-checks that hash against the local store, so the TTL
          is a client refresh hint rather than the hard session bound. Tokens
          without `ph` keep strict expiry and make the client re-login.
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
          revoked PAT can keep a `ph`-bound session or an md5-only client
          authenticated; the host chooses the cadence.
        '';
      };
      transientGrace = lib.mkOption {
        type = lib.types.str;
        default = "15m";
        description = ''
          Go duration a stored PAT may go without a successful validation
          before the per-request store check and md5 matching refuse it. A
          transient Keycloak failure keeps the PAT but does not advance its
          timestamp, so an outage longer than this fails closed.
        '';
      };
      front = {
        enable = lib.mkEnableOption ''
          the front bridge that turns the general gate's identity header into a
          short-lived Subsonic token for Feishin, fronting Octo
        '';
        port = lib.mkOption {
          type = lib.types.port;
          default = 4188;
          description = ''
            Port the bridge listens on inside the container. The general gate
            reaches it by container name on `network`, so it is not published.
          '';
        };
        upstream = lib.mkOption {
          type = lib.types.str;
          default = "http://octo:8080";
          description = "Octo base URL (no path); the bridge adds `/rest` itself.";
        };
        pathPrefix = lib.mkOption {
          type = lib.types.str;
          default = "/feishin";
          description = ''
            Public path prefix the gate proxies here. The bridge strips it and
            only serves the `/rest…` API beneath it.
          '';
        };
        identityHeader = lib.mkOption {
          type = lib.types.str;
          default = "X-Forwarded-Preferred-Username";
          description = "Header the gate sets with the authenticated username; the bridge trusts only this one.";
        };
        publicCoverPath = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Exact path the bridge also serves without the gate's identity header,
            for image fetchers that cannot hold a session. The bridge always asks
            Octo for `/rest/getCoverArt.view` as `adminUser`; empty disables it.
          '';
        };
        tokenTtl = lib.mkOption {
          type = lib.types.str;
          default = "1h";
          description = ''
            Lifetime of the token the bridge mints per gated request. Keep it
            short: the gate renews the browser session, not this credential.
          '';
        };
        environmentFiles = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Dotenv files for the bridge. It reads the same `SUBSONIC_TOKEN_KEY`
            and token kid as the native shim, so point it at the same file
            (e.g. `/run/secretspec/env`) rather than restating the key here.
          '';
        };
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;
      binary = pkgs.callPackage ./package.nix { };
      inherit (cfg) front;

      # Reuse the native container's network, but never its static IP: the
      # bridge answers to its container name, like the gate's other upstreams.
      frontNetwork =
        if cfg.network == null then
          null
        else
          {
            inherit (cfg.network) name subnet;
            ip = null;
          };

      frontEnvironmentFiles =
        if front.environmentFiles != [ ] then front.environmentFiles else cfg.environmentFiles;

      frontSpec = cfg // {
        name = "subsonic-bridge";
        network = frontNetwork;
        ports = [ ];
        udpPorts = [ ];
        openFirewall = false;
        volumes = [ "${binary}/bin/subsonic-auth:/usr/local/bin/subsonic-auth:ro" ];
        entrypoint = "/usr/local/bin/subsonic-auth";
        environmentFiles = frontEnvironmentFiles;
        settings = {
          mode = "front";
          listenAddr = "0.0.0.0:${toString front.port}";
          inherit (front)
            upstream
            pathPrefix
            identityHeader
            publicCoverPath
            ;
          inherit (cfg) adminUser;
          subsonicTokenKid = cfg.tokenKid;
          subsonicTokenAud = cfg.tokenAud;
          subsonicTokenTtl = front.tokenTtl;
        };
        environment = { };
        cmd = [ ];
        extraOptions = [ ];
        gpuPassthrough = false;
        memoryLimit = null;
        dockerMods = [ ];
        dependsOn = [ ];
      };
    in
    lib.mkMerge [
      (mkDockerService.config {
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
            inherit (cfg) adminUser;
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
            patTransientGrace = cfg.transientGrace;
          };
        };
        inherit defaults;
      } args)

      (lib.mkIf front.enable (
        mkDockerService.config {
          spec = frontSpec;
          inherit defaults;
        } args
      ))

      {
        assertions = [
          {
            assertion = !front.enable || cfg.network != null;
            message = "dots.system.services.music.subsonic-auth.front needs `network` so the general gate can reach the bridge by container name.";
          }
          {
            assertion = !front.enable || frontEnvironmentFiles != [ ];
            message = "dots.system.services.music.subsonic-auth.front needs `environmentFiles` with SUBSONIC_TOKEN_KEY (the key never belongs in `settings`).";
          }
          {
            assertion = !front.enable || front.publicCoverPath == "" || cfg.adminUser != "";
            message = "dots.system.services.music.subsonic-auth.front.publicCoverPath needs `adminUser`: the public cover token is minted for it.";
          }
        ];
      }
    ];
}
