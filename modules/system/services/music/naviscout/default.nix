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
          Host directory for the playback cache and the cover-art byte cache,
          mounted read-write at the same path: the playback cache is the
          directory itself (`NAVISCOUT_CACHE_DIR`), the cover cache a `covers`
          subdirectory (`NAVISCOUT_COVER_CACHE_DIR`). When null both are left
          off and unmounted.
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

      catalogDb = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Host path of the durable SQLite database, mounted read-write at the
          same path and passed as `NAVISCOUT_CATALOG_DB`. It holds the catalogue
          store and, in its own tables, the resolved-video store. Its directory
          is created (0700, owned by the container uid) if it is not already
          covered by `stateDir`. When null nothing is persisted.
        '';
      };

      catalogExcludeReleaseTypes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "bootleg" ];
        description = ''
          Release types naviscout never serves or stores, matched
          case-insensitively against an album's types — its primary type, every
          secondary type and a non-official release status. An excluded album,
          its release groups and its tracks are filtered from every surface and
          dropped from the durable store. Bootlegs are excluded by default: a
          bootleg release group is a primary `Album` whose releases carry the
          `Bootleg` status, so it would otherwise read as an ordinary album and
          pad an artist's discography. Set to `[ ]` to keep every type.
        '';
      };

      genreDisplayMode = lib.mkOption {
        type = lib.types.enum [
          "title"
          "sentence"
          "none"
        ];
        default = "title";
        description = ''
          Default display mode for genre and mood names: `title` capitalises every
          word (`post-punk` → `Post-Punk`), `sentence` only the first word
          (`post-punk` → `Post-punk`), and `none` keeps the catalogue's
          spelling. Display never changes identity: dedup, counts, filters and
          merges use the folded canonical name.
        '';
      };

      genreDisplayGenreModes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "poezja śpiewana=sentence" ];
        description = ''
          `canonical=mode` assignments giving one genre the mode of its
          language. They are declared configuration, not inferred: MusicBrainz
          associates no locale with a tag, so a genre not listed here falls back
          to `genreDisplayMode`.
        '';
      };

      genreDisplayExceptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          `canonical=display` overrides, matched case-insensitively, for
          acronyms and written forms that are not the mode's output. An
          exception is the last word: it wins over the per-genre and default
          modes in every mode. Empty by default: which forms a deployment
          needs is its data, so the consuming host sets them.
        '';
      };

      genreDisplayMinorWords = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Words that `title` mode keeps lowercase unless they begin or end the
          label (`drum and bass` → `Drum and Bass`, while `The Fall` keeps its
          first `The`). A deployment that wants a different list sets it here;
          when null naviscout's own default list applies.
        '';
      };

      maxTagLength = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = ''
          Maximum length, in characters, of a MusicBrainz tag stored or served
          as a genre or mood. A longer tag is dropped when a classification is
          filed and when a durable entry is loaded, so an existing store serves
          the filtered set without a purge, and it appears on no surface or
          count. When null naviscout's own default applies; a deployment that
          needs a different bound sets it here.
        '';
      };

      lidarrMonitor = lib.mkOption {
        type = lib.types.enum [
          "album"
          "artist"
        ];
        default = "album";
        description = ''
          What a newly acquired artist's monitoring covers. `album` monitors
          only the album a client requested. `artist` adds the artist with
          whole-discography monitoring, leaving which release types are
          actually monitored to the artist's metadata profile — an
          albums-only profile yields albums only, with no singles or EPs.
          Neither mode passes a different profile or changes the configured
          one.
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

      # The directories naviscout persists into (the playback and cover caches,
      # and the catalogue database), each mounted at the same path and created
      # once.
      catalogDir = if cfg.catalogDb != null then builtins.dirOf cfg.catalogDb else null;
      dataDirs = lib.unique (
        lib.optional (cfg.stateDir != null) cfg.stateDir ++ lib.optional (catalogDir != null) catalogDir
      );

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
          coverCacheDir = "${cfg.stateDir}/covers";
        }
        // lib.optionalAttrs (cfg.navidromeDataDir != null) {
          lastfmDbPath = "${cfg.navidromeDataDir}/navidrome.db";
        }
        // lib.optionalAttrs (cfg.catalogDb != null) {
          inherit (cfg) catalogDb;
        }
        // {
          inherit (cfg)
            catalogExcludeReleaseTypes
            genreDisplayMode
            genreDisplayGenreModes
            genreDisplayExceptions
            lidarrMonitor
            ;
        }
        // lib.optionalAttrs (cfg.maxTagLength != null) {
          inherit (cfg) maxTagLength;
        }
        // lib.optionalAttrs (cfg.genreDisplayMinorWords != null) {
          inherit (cfg) genreDisplayMinorWords;
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
            ++ map (d: "${d}:${d}") dataDirs
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

      (lib.mkIf (dataDirs != [ ]) {
        systemd.tmpfiles.rules = map (d: "d '${d}' 0700 65532 65532 - -") dataDirs;
      })

      remap
    ];
}
