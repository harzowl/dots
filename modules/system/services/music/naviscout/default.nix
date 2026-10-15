# naviscout — a discovery proxy that sits directly in front of Navidrome.
#
# It answers the Subsonic surface and adds catalogue discovery (MusicBrainz,
# Last.fm) plus Lidarr handoff, relaying everything else to `upstream` (the
# Navidrome base URL) unchanged. The music front ends — the oauth2-proxy gate
# and the subsonic-auth shim — point at naviscout instead of Navidrome:
#
#   Navidrome  <-  naviscout  <-  { the navidrome gate, the subsonic-auth shim }
#
# With `settings.nativeEnabled = true` it fronts the *whole* host instead of only
# `/rest`: every other path (the web UI, `/api`, `/share`, `/auth`) is relayed
# verbatim, and Navidrome's native `/api` list responses gain catalogue entries,
# so Navidrome's own web UI shows discovery. `settings.nativeEndpoints` picks the
# collections (`album`, `artist`, `song`) to extend.
#
# Streaming a catalogue (phantom) track shells out to `yt-dlp`, which needs
# `ffmpeg` and a CA trust store, so the binary is wrapped in a Nix-built OCI
# image the host loads (`package` has no default: the consumer passes its own
# build), rather than run from a stock base image. The container joins a
# user-defined network and is reached by the front ends on its container IP; it
# is published loopback-only so nothing off-host reaches it.
#
# A phantom play can be scrobbled to Last.fm as the user who played it, using
# the per-user session key Navidrome already stores rather than a second login:
# `navidromeDataDir` mounts Navidrome's data directory read-only, and the
# container reads `navidrome.db` with sqlite3 to resolve the key.
#
# Config is `NAVISCOUT_<UPPER_SNAKE>` env vars. Non-secret settings go through
# `settings` (camelCase, mapped like navidrome's `ND_*`); `upstream` and `port`
# become `NAVISCOUT_UPSTREAM_URL` / `NAVISCOUT_LISTEN`. Secrets (the Last.fm and
# Lidarr API keys) never enter `settings`: they arrive in a dotenv via
# `environmentFiles`, and `secretEnv` re-emits them under the `NAVISCOUT_*` name
# naviscout reads.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  defaults = {
    name = "naviscout";
    image = "naviscout:latest";
    # Loopback-only: the front ends reach it over the user-defined network, and
    # `openFirewall = false` keeps it off the LAN and the mesh.
    openFirewall = false;
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "music"
    "naviscout"
  ];
  description = "naviscout discovery proxy in front of Navidrome (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      port = lib.mkOption {
        type = lib.types.port;
        default = 4533;
        description = ''
          Port naviscout listens on (its container port). The front ends reach
          it on its container IP; pick a host port that does not collide with
          Navidrome's own loopback publish.
        '';
      };

      upstream = lib.mkOption {
        type = lib.types.str;
        description = "Base URL of the upstream music server (Navidrome).";
      };

      package = lib.mkOption {
        type = lib.types.package;
        description = ''
          The naviscout binary to run. There is no default: the consumer passes
          its own build, so this module does not depend on the naviscout flake.
        '';
      };

      stateDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Host directory for the playback cache, mounted read-write at the same
          path with the cache enabled (`NAVISCOUT_CACHE_DIR`). When null the
          cache is left off and unmounted.
        '';
      };

      navidromeDataDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Host directory holding Navidrome's SQLite database, mounted read-only
          at the same path so naviscout can resolve a user's linked Last.fm
          session key for scrobbling (`NAVISCOUT_LASTFM_DB_PATH` points at
          `<navidromeDataDir>/navidrome.db`). When null, scrobbling has no
          session-key source and is left off.
        '';
      };

      secretEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          NAVISCOUT_LIDARR_API_KEY = "LIDARR_API_KEY";
        };
        description = ''
          Map a `NAVISCOUT_*` env var to a secret name looked up in the dotenv
          files under `environmentFiles`. The values are re-emitted into a
          runtime dotenv (`/run/<name>.env`) passed to the container, so a
          secret never enters `settings` (the Nix store).
        '';
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      # camelCase -> `NAVISCOUT_UPPER_SNAKE` (ytdlpResolveCacheTtl ->
      # NAVISCOUT_YTDLP_RESOLVE_CACHE_TTL), the mapping naviscout's env expects.
      envKey =
        k:
        "NAVISCOUT_"
        + lib.toUpper (
          lib.concatMapStrings (c: if c != lib.toLower c then "_" + lib.toLower c else c) (
            lib.stringToCharacters k
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

      # The secret dotenv the container also gets, and its remap ahead of the
      # container (the RAW environmentFiles stay the lookup source).
      secretEnvFile = "/run/${cfg.name}.env";
      remapEnabled = cfg.secretEnv != { };
      containerEnvFiles = cfg.environmentFiles ++ lib.optional remapEnabled secretEnvFile;

      environment = lib.mapAttrs' (k: v: lib.nameValuePair (envKey k) (envValue v)) (
        {
          listen = ":${toString cfg.port}";
          upstreamUrl = cfg.upstream;
        }
        // lib.optionalAttrs (cfg.stateDir != null) {
          cacheDir = cfg.stateDir;
          cacheEnabled = true;
        }
        // lib.optionalAttrs (cfg.navidromeDataDir != null) {
          lastfmDbPath = "${cfg.navidromeDataDir}/navidrome.db";
        }
        // cfg.settings
      );

      imageTag = "latest";
      containerImage = pkgs.dockerTools.buildLayeredImage {
        inherit (cfg) name;
        tag = imageTag;
        # The runtime needs yt-dlp to resolve phantom tracks, sqlite3 to read
        # Navidrome's database for scrobbling, and a trust store for every
        # outbound TLS call.
        contents = [
          pkgs.cacert
          pkgs.sqlite
          pkgs.yt-dlp
        ];
        # yt-dlp wants a writable temp dir.
        extraCommands = ''
          mkdir -p tmp
          chmod 1777 tmp
        '';
        config = {
          Entrypoint = [ "${cfg.package}/bin/naviscout" ];
          WorkingDir = "/";
          # Match the project's image: a non-root uid, shared with the cache dir
          # (see the tmpfiles rule below).
          User = "65532:65532";
          Env = [
            "PATH=/bin"
            "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
            "TMPDIR=/tmp"
          ];
          ExposedPorts = {
            "${toString cfg.port}/tcp" = { };
          };
        };
      };

      remapScript = pkgs.writeShellScript "naviscout-secrets-env" (builtins.readFile ./secrets-env.sh);
      remapArgs = lib.concatMapStringsSep " " lib.escapeShellArg (
        [ secretEnvFile ]
        ++ cfg.environmentFiles
        ++ [ "--" ]
        ++ lib.mapAttrsToList (env: secret: "${env}=${secret}") cfg.secretEnv
      );

      # Map the neutral secrets to the `NAVISCOUT_*` names naviscout reads.
      remap = lib.mkIf remapEnabled {
        assertions = [
          {
            assertion = cfg.environmentFiles != [ ];
            message = "dots.system.services.music.naviscout.secretEnv needs environmentFiles to read the secrets from.";
          }
        ];

        systemd.services."${cfg.name}-env" = {
          description = "Map the naviscout secrets into their NAVISCOUT_ env names";
          after = [ "secretspec.service" ];
          wants = [ "secretspec.service" ];
          before = [ "docker-${cfg.name}.service" ];
          partOf = [ "secretspec.service" ];
          wantedBy = [ "multi-user.target" ];
          path = [
            pkgs.coreutils
            pkgs.gnused
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${remapScript} ${remapArgs}";
          };
        };
      };
    in
    lib.mkMerge [
      (mkDockerService.config {
        spec = cfg // {
          image = "${cfg.name}:${imageTag}";
          settings = { };
          environmentFiles = containerEnvFiles;
          ports = [ "127.0.0.1:${toString cfg.port}:${toString cfg.port}" ];
          volumes =
            cfg.volumes
            ++ lib.optional (cfg.stateDir != null) "${cfg.stateDir}:${cfg.stateDir}"
            ++ lib.optional (cfg.navidromeDataDir != null) "${cfg.navidromeDataDir}:${cfg.navidromeDataDir}:ro";
        };
        inherit defaults;
      } args)

      {
        virtualisation.oci-containers.containers.${cfg.name} = {
          imageFile = containerImage;
          inherit environment;
        };
      }

      (lib.mkIf (cfg.stateDir != null) {
        systemd.tmpfiles.rules = [
          "d '${cfg.stateDir}' 0700 65532 65532 - -"
        ];
      })

      remap
    ];
}
