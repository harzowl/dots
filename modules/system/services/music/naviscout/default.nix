# Secrets never enter the Nix store. `secretEnv` maps a `NAVISCOUT_*` name to a
# neutral key found in `environmentFiles`, and a oneshot unit writes the
# prefixed dotenv systemd reads. The source files stay the consumer's.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;

  serviceName = "naviscout";
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "music"
    "naviscout"
  ];
  description = "naviscout catalogue discovery proxy in front of Navidrome";

  imports =
    args:
    args.lib.optional (args ? naviscout && args.naviscout != null) args.naviscout.nixosModules.default;

  options =
    { lib, ... }:
    let
      inherited =
        type: description:
        lib.mkOption {
          inherit type description;
          default = null;
        };

      opt =
        type: description:
        lib.mkOption {
          type = lib.types.nullOr type;
          inherit description;
          default = null;
        };

      optList =
        type: description:
        lib.mkOption {
          type = lib.types.listOf type;
          inherit description;
          default = [ ];
        };

      optAttrs =
        type: description:
        lib.mkOption {
          type = lib.types.attrsOf type;
          inherit description;
          default = { };
        };
    in
    {
      upstreamUrl = lib.mkOption {
        type = lib.types.str;
        description = "Base URL of the Subsonic/OpenSubsonic server naviscout augments.";
      };

      listen = inherited (lib.types.nullOr lib.types.str) ''
        Address the server listens on (`host:port`). Null keeps naviscout's
        default.
      '';

      dataDir = inherited (lib.types.nullOr lib.types.str) ''
        Durable state directory (catalogue database and related stores). Null
        keeps naviscout's default.
      '';

      cacheDir = inherited (lib.types.nullOr lib.types.str) ''
        Regenerable state directory (cover and playback caches). Null keeps
        naviscout's default.
      '';

      user = inherited (lib.types.nullOr lib.types.str) ''
        Service user. Null keeps naviscout's default.
      '';

      group = inherited (lib.types.nullOr lib.types.str) ''
        Service group. Null keeps naviscout's default.
      '';

      uid = inherited (lib.types.nullOr lib.types.int) ''
        Fixed numeric UID for the static service user; null lets NixOS pick
        one. Set this to keep a store migrated from an existing deployment
        owned by its former uid.
      '';

      gid = inherited (lib.types.nullOr lib.types.int) ''
        Fixed numeric GID for the static service group; null lets NixOS pick
        one.
      '';

      dynamicUser = inherited (lib.types.nullOr lib.types.bool) ''
        Run under a systemd DynamicUser. Null keeps naviscout's default.
      '';

      restart = inherited (lib.types.nullOr lib.types.str) ''
        systemd `Restart=` policy. Null keeps naviscout's default.
      '';

      restartSec = inherited (lib.types.nullOr lib.types.str) ''
        Delay between restarts. Null keeps naviscout's default.
      '';

      openFirewall = inherited (lib.types.nullOr lib.types.bool) ''
        Open the listening port in the host firewall. Null keeps naviscout's
        default.
      '';

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Dotenv files read by systemd before it drops privileges. This is the
          home for credentials; they never enter the Nix store.
        '';
      };

      credentials = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Files loaded with `LoadCredential=NAME:SOURCE`, for a consumer that
          prefers systemd credentials over an environment file.
        '';
      };

      secretEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          NAVISCOUT_LIDARR_API_KEY = "LIDARR_API_KEY";
        };
        description = ''
          Map a `NAVISCOUT_*` env name to a neutral secret name looked up in
          `environmentFiles`. The values are re-emitted into a runtime dotenv,
          so a secret never enters the typed settings (the Nix store).
        '';
      };

      upstream = {
        insecureTls = opt lib.types.bool "Skip TLS verification when talking to the upstream server.";
        timeout = opt lib.types.str "Upstream request timeout (a Go duration such as `10s`).";
        maxBody = opt lib.types.ints.unsigned "Largest upstream response body accepted, in bytes.";
      };

      phantomPrefix = opt lib.types.str "Prefix for catalogue entity ids.";

      trigger = opt (lib.types.enum [
        "play"
        "star"
        "both"
        "off"
      ]) "Upstream events that provoke a scrobble attempt.";

      musicbrainz = {
        url = opt lib.types.str "MusicBrainz API base URL.";
        userAgent = opt lib.types.str "User agent sent to MusicBrainz; required when `musicbrainz.url` is set.";
      };

      lastfm = {
        url = opt lib.types.str "Last.fm API base URL.";
        dbPath = opt lib.types.str "Path to Navidrome's SQLite database, read for Last.fm metadata.";
      };

      coverArt = {
        url = opt lib.types.str "Cover Art Archive base URL.";
      };

      deezer = {
        url = opt lib.types.str "Deezer API base URL.";
      };

      cover = {
        sourceOrder = optList (lib.types.enum [
          "remembered"
          "cover_art_archive"
          "lastfm_cover"
          "artist_image"
        ]) "Order in which album cover sources are tried.";
        artistSourceOrder = optList (lib.types.enum [
          "lastfm_artist"
          "artist_image"
        ]) "Order in which artist picture sources are tried.";
        maxConcurrency = opt lib.types.ints.positive "Maximum concurrent cover resolutions.";
        queueSize = opt lib.types.ints.positive "Maximum queued cover resolutions.";
        waitTimeout = opt lib.types.str "Longest a request waits for a cover (a Go duration).";
      };

      coverCache = {
        maxBytes = opt lib.types.ints.unsigned "Rotation budget for cached cover art, in bytes.";
      };

      lidarr = {
        url = opt lib.types.str "Lidarr API base URL.";
        rootFolder = opt lib.types.str "Root folder for artists added through naviscout.";
        qualityProfileId = opt lib.types.int "Quality profile id; 0 lets Lidarr choose.";
        metadataProfileId = opt lib.types.int "Metadata profile id; 0 lets Lidarr choose.";
        monitor = opt (lib.types.enum [
          "album"
          "artist"
        ]) "How much of an added artist Lidarr monitors.";
      };

      playback = {
        enable = opt lib.types.bool "Enable playback of catalogue tracks through yt-dlp.";
      };

      ytdlp = {
        binary = opt lib.types.str "yt-dlp executable.";
        format = opt lib.types.str "yt-dlp format selector.";
        cookiesFile = opt lib.types.str "Netscape-format cookies file passed to yt-dlp.";
        resolveTimeout = opt lib.types.str "Timeout for one resolution (a Go duration).";
        extraArgs = optList lib.types.str "Extra yt-dlp arguments.";
        resolveCacheTtl = opt lib.types.str "Lifetime of a resolved video (a Go duration).";
        maxConcurrency = opt lib.types.ints.positive "Maximum concurrent yt-dlp resolutions.";
        searchTemplate = opt lib.types.str "Search query template.";
        searchResults = opt lib.types.ints.positive "Number of search results to inspect.";
        music = opt lib.types.bool "Use yt-dlp's music search mode.";
        musicTimeout = opt lib.types.str "Timeout for the music search (a Go duration).";
        sourceOrder = optList (lib.types.enum [
          "soundcloud"
          "bandcamp"
          "internet_archive"
        ]) "Fallback sources tried after YouTube, in order.";
        sourceTimeouts = {
          soundcloud = opt lib.types.str "Timeout for the SoundCloud fallback.";
          bandcamp = opt lib.types.str "Timeout for the Bandcamp fallback.";
          internet_archive = opt lib.types.str "Timeout for the Internet Archive fallback.";
        };
        linkLookup = opt lib.types.bool "Resolve a track's link directly before searching.";
        linkTimeout = opt lib.types.str "Timeout for a link lookup (a Go duration).";
        linkTtl = opt lib.types.str "Lifetime of a cached link lookup (a Go duration).";
        linkCacheMax = opt lib.types.ints.positive "Maximum cached link lookups.";
        resolvedPath = opt lib.types.str "Legacy JSON store of resolved videos, imported once.";
        resolvedMaxEntries = opt lib.types.ints.positive "Maximum entries in the resolved-video store.";
      };

      listenbrainz = {
        url = opt lib.types.str "ListenBrainz API base URL.";
        labsUrl = opt lib.types.str "ListenBrainz Labs API base URL.";
        cacheTtl = opt lib.types.str "Lifetime of cached ListenBrainz data (a Go duration).";
        cacheMax = opt lib.types.ints.positive "Maximum cached ListenBrainz entries.";
      };

      warmTracks = opt lib.types.ints.unsigned "Tracks to warm ahead of playback.";

      stream = {
        maxConcurrency = opt lib.types.ints.positive "Maximum concurrent playback streams.";
        overflow = opt (lib.types.enum [
          "wait"
          "error"
        ]) "What a request does when the stream pool is full.";
      };

      playWait = opt lib.types.str "Longest a play waits for a free slot (a Go duration).";

      cache = {
        enable = opt lib.types.bool "Cache resolved playback files.";
        ttl = opt lib.types.str "Lifetime of a cached playback file (a Go duration).";
        maxBytes = opt lib.types.ints.unsigned "Rotation budget for the playback cache, in bytes.";
      };

      native = {
        enable = opt lib.types.bool "Augment Navidrome's native API responses.";
        endpoints = optList (lib.types.enum [
          "album"
          "artist"
          "song"
          "genre"
        ]) "Native collections naviscout augments.";
      };

      search = {
        deadline = opt lib.types.str "Warm search deadline (a Go duration).";
        coldDeadline = opt lib.types.str "Cold search deadline (a Go duration).";
        artistDeadline = opt lib.types.str "Artist lookup deadline (a Go duration).";
        albumDeadline = opt lib.types.str "Album lookup deadline (a Go duration).";
      };

      catalog = {
        path = opt lib.types.str "Legacy JSON catalogue store, imported once.";
        maxEntries = opt lib.types.ints.positive "Maximum catalogue entries.";
        ttl = opt lib.types.str "Catalogue entry lifetime (a Go duration).";
        searchTtl = opt lib.types.str "Catalogue search cache lifetime (a Go duration).";
        enrich = opt lib.types.bool "Enrich catalogue entries in the background.";
        requireDate = opt lib.types.bool "Hide catalogue albums without a release date.";
        refresh = opt lib.types.bool "Refresh stored catalogue entries.";
        excludeArtists = optList lib.types.str "MusicBrainz artist ids never served or stored.";
        excludeReleaseTypes = optList lib.types.str "Release types never served or stored.";
      };

      genreDisplay = {
        mode = opt (lib.types.enum [
          "title"
          "sentence"
          "none"
        ]) "Default genre label casing.";
        genreModes = optAttrs (lib.types.enum [
          "title"
          "sentence"
          "none"
        ]) "Per-genre display mode overrides (`genre = mode`).";
        exceptions = optAttrs lib.types.str "Genre labels pinned to a written form (`genre = display`).";
        minorWords = optList lib.types.str "Words kept lowercase inside a title-cased label.";
        wordSubstitutions = optAttrs lib.types.str "Whole-word display substitutions (`word = display`).";
      };

      mood = {
        enable = opt lib.types.bool "Surface non-genre tags as moods.";
        exclude = optList lib.types.str "Tags never surfaced as moods.";
      };

      maxTagLength = opt lib.types.ints.positive "Longest accepted MusicBrainz tag.";

      stations = {
        enable = opt lib.types.bool "Serve per-listener stations.";
        size = opt (lib.types.ints.between 10 100) "Tracks in a generated station.";
        ttl = opt lib.types.str "Station snapshot lifetime (a Go duration).";
        historyWindow = opt lib.types.str "Play history window used for stations (a Go duration).";
        replayCap = opt lib.types.ints.positive "Maximum repeats of one track in a station.";
        pinned = optList lib.types.str "Pinned station seeds.";
        refreshInterval = opt lib.types.str "Station refresh interval (a Go duration).";
        streamTtl = opt lib.types.str "Lifetime of a station stream URL (a Go duration).";
        ffmpeg = opt lib.types.str "ffmpeg executable used for station streams.";
        lastfmConcurrency = opt lib.types.ints.positive "Maximum concurrent Last.fm station lookups.";
        deadline = opt lib.types.str "Station request deadline (a Go duration).";
        sources = optList (lib.types.enum [
          "lastfm"
          "listenbrainz"
          "listenbrainz_radio"
        ]) "Station sources, in preference order.";
        sourceTimeouts = {
          lastfm = opt lib.types.str "Timeout for the Last.fm station source.";
          listenbrainz = opt lib.types.str "Timeout for the ListenBrainz station source.";
          listenbrainz_radio = opt lib.types.str "Timeout for the ListenBrainz radio station source.";
        };
      };

      logLevel = opt (lib.types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ]) "Server log verbosity.";
      slowLogThreshold = opt lib.types.str "Requests slower than this are logged (a Go duration).";
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      secretEnvFile = "/run/${serviceName}.env";
      remapEnabled = cfg.secretEnv != { };

      fallbackSourceNames = [
        "soundcloud"
        "bandcamp"
        "internet_archive"
      ];
      stationSourceNames = [
        "lastfm"
        "listenbrainz"
        "listenbrainz_radio"
      ];

      csv = values: lib.concatStringsSep "," (map toString values);
      pairs =
        values: lib.concatStringsSep "," (lib.mapAttrsToList (name: value: "${name}=${value}") values);

      whenSet =
        name: value:
        lib.optionalAttrs (value != null) {
          ${name} = value;
        };

      whenList =
        name: value:
        lib.optionalAttrs (value != [ ]) {
          ${name} = csv value;
        };

      whenPairs =
        name: value:
        lib.optionalAttrs (value != { }) {
          ${name} = pairs value;
        };

      whenJoined =
        separator: name: value:
        lib.optionalAttrs (value != [ ]) {
          ${name} = lib.concatStringsSep separator (map toString value);
        };

      whenTimeoutPairs =
        name: sources: timeouts:
        let
          rendered = lib.concatStringsSep "," (
            lib.concatMap (
              source: lib.optional (timeouts.${source} != null) "${source}=${timeouts.${source}}"
            ) sources
          );
        in
        lib.optionalAttrs (rendered != "") {
          ${name} = rendered;
        };

      remapScript = pkgs.writeShellScript "naviscout-secrets-env" (builtins.readFile ./secrets-env.sh);
      remapArgs = lib.concatMapStringsSep " " lib.escapeShellArg (
        [ secretEnvFile ]
        ++ cfg.environmentFiles
        ++ [ "--" ]
        ++ lib.mapAttrsToList (env: secret: "${env}=${secret}") cfg.secretEnv
      );
    in
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = args ? naviscout;
            message = "dots.system.services.music.naviscout needs the naviscout flake as a special argument.";
          }
          {
            assertion = !remapEnabled || cfg.environmentFiles != [ ];
            message = "dots.system.services.music.naviscout.secretEnv needs environmentFiles to read the secrets from.";
          }
          {
            assertion = (cfg.uid == null && cfg.gid == null) || cfg.dynamicUser == false;
            message = "dots.system.services.music.naviscout.uid/gid need dynamicUser = false.";
          }
        ];

        services.naviscout = {
          enable = true;
          inherit (cfg) upstreamUrl credentials;
          environmentFiles = cfg.environmentFiles ++ lib.optional remapEnabled secretEnvFile;
          settings = lib.mkMerge [
            (whenSet "NAVISCOUT_UPSTREAM_INSECURE_TLS" cfg.upstream.insecureTls)
            (whenSet "NAVISCOUT_UPSTREAM_TIMEOUT" cfg.upstream.timeout)
            (whenSet "NAVISCOUT_UPSTREAM_MAX_BODY" cfg.upstream.maxBody)
            (whenSet "NAVISCOUT_PHANTOM_PREFIX" cfg.phantomPrefix)
            (whenSet "NAVISCOUT_TRIGGER" cfg.trigger)
            (whenSet "NAVISCOUT_MUSICBRAINZ_URL" cfg.musicbrainz.url)
            (whenSet "NAVISCOUT_MUSICBRAINZ_UA" cfg.musicbrainz.userAgent)
            (whenSet "NAVISCOUT_LASTFM_URL" cfg.lastfm.url)
            (whenSet "NAVISCOUT_LASTFM_DB_PATH" cfg.lastfm.dbPath)
            (whenSet "NAVISCOUT_COVERART_URL" cfg.coverArt.url)
            (whenSet "NAVISCOUT_DEEZER_URL" cfg.deezer.url)
            (whenList "NAVISCOUT_COVER_SOURCE_ORDER" cfg.cover.sourceOrder)
            (whenList "NAVISCOUT_ARTIST_SOURCE_ORDER" cfg.cover.artistSourceOrder)
            (whenSet "NAVISCOUT_COVER_MAX_CONCURRENCY" cfg.cover.maxConcurrency)
            (whenSet "NAVISCOUT_COVER_QUEUE_SIZE" cfg.cover.queueSize)
            (whenSet "NAVISCOUT_COVER_WAIT_TIMEOUT" cfg.cover.waitTimeout)
            (whenSet "NAVISCOUT_COVER_CACHE_MAX_BYTES" cfg.coverCache.maxBytes)
            (whenSet "NAVISCOUT_LIDARR_URL" cfg.lidarr.url)
            (whenSet "NAVISCOUT_LIDARR_ROOT_FOLDER" cfg.lidarr.rootFolder)
            (whenSet "NAVISCOUT_LIDARR_QUALITY_PROFILE_ID" cfg.lidarr.qualityProfileId)
            (whenSet "NAVISCOUT_LIDARR_METADATA_PROFILE_ID" cfg.lidarr.metadataProfileId)
            (whenSet "NAVISCOUT_LIDARR_MONITOR" cfg.lidarr.monitor)
            (whenSet "NAVISCOUT_PLAYBACK_ENABLED" cfg.playback.enable)
            (whenSet "NAVISCOUT_YTDLP_BINARY" cfg.ytdlp.binary)
            (whenSet "NAVISCOUT_YTDLP_FORMAT" cfg.ytdlp.format)
            (whenSet "NAVISCOUT_YTDLP_COOKIES" cfg.ytdlp.cookiesFile)
            (whenSet "NAVISCOUT_YTDLP_RESOLVE_TIMEOUT" cfg.ytdlp.resolveTimeout)
            (whenJoined " " "NAVISCOUT_YTDLP_EXTRA_ARGS" cfg.ytdlp.extraArgs)
            (whenSet "NAVISCOUT_YTDLP_RESOLVE_CACHE_TTL" cfg.ytdlp.resolveCacheTtl)
            (whenSet "NAVISCOUT_YTDLP_MAX_CONCURRENCY" cfg.ytdlp.maxConcurrency)
            (whenSet "NAVISCOUT_YTDLP_SEARCH_TEMPLATE" cfg.ytdlp.searchTemplate)
            (whenSet "NAVISCOUT_YTDLP_SEARCH_RESULTS" cfg.ytdlp.searchResults)
            (whenSet "NAVISCOUT_YTDLP_MUSIC" cfg.ytdlp.music)
            (whenSet "NAVISCOUT_YTDLP_MUSIC_TIMEOUT" cfg.ytdlp.musicTimeout)
            (whenList "NAVISCOUT_YTDLP_SOURCE_ORDER" cfg.ytdlp.sourceOrder)
            (whenTimeoutPairs "NAVISCOUT_YTDLP_SOURCE_TIMEOUTS" fallbackSourceNames cfg.ytdlp.sourceTimeouts)
            (whenSet "NAVISCOUT_YTDLP_LINK_LOOKUP" cfg.ytdlp.linkLookup)
            (whenSet "NAVISCOUT_YTDLP_LINK_TIMEOUT" cfg.ytdlp.linkTimeout)
            (whenSet "NAVISCOUT_YTDLP_LINK_TTL" cfg.ytdlp.linkTtl)
            (whenSet "NAVISCOUT_YTDLP_LINK_CACHE_MAX" cfg.ytdlp.linkCacheMax)
            (whenSet "NAVISCOUT_LISTENBRAINZ_URL" cfg.listenbrainz.url)
            (whenSet "NAVISCOUT_LISTENBRAINZ_LABS_URL" cfg.listenbrainz.labsUrl)
            (whenSet "NAVISCOUT_LISTENBRAINZ_CACHE_TTL" cfg.listenbrainz.cacheTtl)
            (whenSet "NAVISCOUT_LISTENBRAINZ_CACHE_MAX" cfg.listenbrainz.cacheMax)
            (whenSet "NAVISCOUT_YTDLP_RESOLVED_PATH" cfg.ytdlp.resolvedPath)
            (whenSet "NAVISCOUT_YTDLP_RESOLVED_MAX_ENTRIES" cfg.ytdlp.resolvedMaxEntries)
            (whenSet "NAVISCOUT_WARM_TRACKS" cfg.warmTracks)
            (whenSet "NAVISCOUT_STREAM_MAX_CONCURRENCY" cfg.stream.maxConcurrency)
            (whenSet "NAVISCOUT_STREAM_OVERFLOW" cfg.stream.overflow)
            (whenSet "NAVISCOUT_PLAY_WAIT" cfg.playWait)
            (whenSet "NAVISCOUT_CACHE_ENABLED" cfg.cache.enable)
            (whenSet "NAVISCOUT_CACHE_TTL" cfg.cache.ttl)
            (whenSet "NAVISCOUT_CACHE_MAX_BYTES" cfg.cache.maxBytes)
            (whenSet "NAVISCOUT_NATIVE_ENABLED" cfg.native.enable)
            (whenList "NAVISCOUT_NATIVE_ENDPOINTS" cfg.native.endpoints)
            (whenSet "NAVISCOUT_SEARCH_DEADLINE" cfg.search.deadline)
            (whenSet "NAVISCOUT_SEARCH_COLD_DEADLINE" cfg.search.coldDeadline)
            (whenSet "NAVISCOUT_ARTIST_DEADLINE" cfg.search.artistDeadline)
            (whenSet "NAVISCOUT_ALBUM_DEADLINE" cfg.search.albumDeadline)
            (whenSet "NAVISCOUT_CATALOG_PATH" cfg.catalog.path)
            (whenSet "NAVISCOUT_CATALOG_MAX_ENTRIES" cfg.catalog.maxEntries)
            (whenSet "NAVISCOUT_CATALOG_TTL" cfg.catalog.ttl)
            (whenSet "NAVISCOUT_CATALOG_SEARCH_TTL" cfg.catalog.searchTtl)
            (whenSet "NAVISCOUT_CATALOG_ENRICH" cfg.catalog.enrich)
            (whenSet "NAVISCOUT_CATALOG_REQUIRE_DATE" cfg.catalog.requireDate)
            (whenSet "NAVISCOUT_CATALOG_REFRESH" cfg.catalog.refresh)
            (whenList "NAVISCOUT_CATALOG_EXCLUDE_ARTISTS" cfg.catalog.excludeArtists)
            (whenList "NAVISCOUT_CATALOG_EXCLUDE_RELEASE_TYPES" cfg.catalog.excludeReleaseTypes)
            (whenSet "NAVISCOUT_GENRE_DISPLAY_MODE" cfg.genreDisplay.mode)
            (whenPairs "NAVISCOUT_GENRE_DISPLAY_GENRE_MODES" cfg.genreDisplay.genreModes)
            (whenPairs "NAVISCOUT_GENRE_DISPLAY_EXCEPTIONS" cfg.genreDisplay.exceptions)
            (whenList "NAVISCOUT_GENRE_DISPLAY_MINOR_WORDS" cfg.genreDisplay.minorWords)
            (whenPairs "NAVISCOUT_GENRE_DISPLAY_WORD_SUBSTITUTIONS" cfg.genreDisplay.wordSubstitutions)
            (whenSet "NAVISCOUT_MOOD_ENABLED" cfg.mood.enable)
            (whenList "NAVISCOUT_MOOD_EXCLUDE" cfg.mood.exclude)
            (whenSet "NAVISCOUT_MAX_TAG_LENGTH" cfg.maxTagLength)
            (whenSet "NAVISCOUT_STATIONS_ENABLED" cfg.stations.enable)
            (whenSet "NAVISCOUT_STATION_SIZE" cfg.stations.size)
            (whenSet "NAVISCOUT_STATION_TTL" cfg.stations.ttl)
            (whenSet "NAVISCOUT_STATION_HISTORY_WINDOW" cfg.stations.historyWindow)
            (whenSet "NAVISCOUT_STATION_REPLAY_CAP" cfg.stations.replayCap)
            (whenList "NAVISCOUT_STATION_PINNED" cfg.stations.pinned)
            (whenSet "NAVISCOUT_STATION_REFRESH_INTERVAL" cfg.stations.refreshInterval)
            (whenSet "NAVISCOUT_STATION_STREAM_TTL" cfg.stations.streamTtl)
            (whenSet "NAVISCOUT_STATION_FFMPEG" cfg.stations.ffmpeg)
            (whenSet "NAVISCOUT_STATION_LASTFM_CONCURRENCY" cfg.stations.lastfmConcurrency)
            (whenSet "NAVISCOUT_STATION_DEADLINE" cfg.stations.deadline)
            (whenList "NAVISCOUT_STATION_SOURCES" cfg.stations.sources)
            (whenTimeoutPairs "NAVISCOUT_STATION_SOURCE_TIMEOUTS" stationSourceNames
              cfg.stations.sourceTimeouts
            )
            (whenSet "NAVISCOUT_LOG_LEVEL" cfg.logLevel)
            (whenSet "NAVISCOUT_SLOW_LOG_THRESHOLD" cfg.slowLogThreshold)
          ];
        }
        // whenSet "listen" cfg.listen
        // whenSet "dataDir" cfg.dataDir
        // whenSet "cacheDir" cfg.cacheDir
        // whenSet "user" cfg.user
        // whenSet "group" cfg.group
        // whenSet "dynamicUser" cfg.dynamicUser
        // whenSet "restart" cfg.restart
        // whenSet "restartSec" cfg.restartSec
        // whenSet "openFirewall" cfg.openFirewall;

        users = {
          users = lib.mkIf (cfg.user != null && cfg.uid != null) {
            ${cfg.user}.uid = cfg.uid;
          };
          groups = lib.mkIf (cfg.group != null && cfg.gid != null) {
            ${cfg.group}.gid = cfg.gid;
          };
        };

        systemd.services.${serviceName} = lib.mkIf remapEnabled {
          after = [ "${serviceName}-env.service" ];
          wants = [ "${serviceName}-env.service" ];
        };
      }

      (lib.mkIf remapEnabled {
        systemd.services."${serviceName}-env" = {
          description = "Map the naviscout secrets into their NAVISCOUT_ env names";
          after = [ "secretspec.service" ];
          wants = [ "secretspec.service" ];
          before = [ "${serviceName}.service" ];
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
      })
    ];
}
