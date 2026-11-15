let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;
  mkSecretEnv = import ../../../../../lib/mkSecretEnv.nix;

  octoDefaults = {
    name = "octo";
    image = "ghcr.io/winters27/octo:2026.11.13";
  };

  shimContainer = {
    name = "yt-dlp-shim";
    image = "ghcr.io/winters27/octo-yt-dlp-shim:2026.11.13";
  };

  sonicContainer = {
    name = "octo-sonic";
    image = "ghcr.io/winters27/octo-sonic:2026.11.13";
  };

  sidecarPort = 8080;
  musicPath = "/music";
  configPath = "/app/config";
  ytdlpPath = "/opt/ytdlp";
  ytdlpCachePath = "/root/.cache/yt-dlp";
  ytShimDataPath = "/var/lib/ytshim";
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "music"
    "octo"
  ];
  description = "Octo music proxy with its yt-dlp and sonic sidecars (OCI containers)";

  options =
    { lib, ... }:
    (mkDockerService.options {
      inherit lib;
      defaults = octoDefaults;
    })
    // {
      port = lib.mkOption {
        type = lib.types.port;
        default = 5274;
        description = "Host port Octo is published on, on loopback only — the music-network gate reaches it as `octo:<containerPort>`.";
      };

      containerPort = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Port Octo listens on inside the container, and the one the gate reaches on the music network.";
      };

      network = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                description = "Name of the user-defined docker network.";
              };
              subnet = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Subnet to create the network with. Declare it identically on
                  every service that names the same network; it only needs to be
                  set once per network.
                '';
              };
            };
          }
        );
        default = null;
        description = ''
          User-defined network every container here joins, so Octo reaches its
          sidecars by name. No static container IP: the sidecars answer to their
          container names.
        '';
      };

      dataDir = lib.mkOption {
        type = lib.types.str;
        description = "Host directory for the shim's SQLite duration cache (mounted at `/var/lib/ytshim`).";
      };

      configDir = lib.mkOption {
        type = lib.types.str;
        description = "Host directory for Octo's settings (mounted at `/app/config`).";
      };

      cacheDir = lib.mkOption {
        type = lib.types.str;
        description = ''
          Host directory holding the self-updated yt-dlp binary and its player
          cache (mounted at `/opt/ytdlp` and `/root/.cache/yt-dlp`).
        '';
      };

      musicDir = lib.mkOption {
        type = lib.types.str;
        description = "Host directory holding the music library (mounted at `/music`; Octo writes downloads into it).";
      };

      shimUrl = lib.mkOption {
        type = lib.types.str;
        description = ''
          Subsonic endpoint Octo treats as its server — the subsonic-auth shim in
          front of Navidrome, as reachable from the container network.
        '';
      };

      admin = {
        username = lib.mkOption {
          type = lib.types.str;
          description = "Navidrome admin account Octo signs in with; its password arrives through `secretEnv`.";
        };
        signIn = lib.mkOption {
          type = lib.types.enum [
            "required"
            "off"
          ];
          default = "required";
          description = ''
            Dashboard and admin API sign-in. `off` only behind a proxy that signs
            people in itself; anything else keeps the sign-in on.
          '';
        };
      };

      lidarr = {
        baseUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Lidarr base URL as reachable from the container network; required when `download.source` is `lidarr`.";
        };
        rootFolderPath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Lidarr root folder hearts are added under; required when `download.source` is `lidarr`.";
        };
        qualityProfileId = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = "Lidarr quality profile id for what Octo adds; 0 lets Lidarr choose.";
        };
        metadataProfileId = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = "Lidarr metadata profile id for what Octo adds; 0 lets Lidarr choose.";
        };
        completionMode = lib.mkOption {
          type = lib.types.enum [
            "Accepted"
            "Imported"
          ];
          default = "Accepted";
          description = ''
            When a heart counts as handed off: once Lidarr accepts the album
            search, or once its import finishes (or times out).
          '';
        };
        importTimeoutSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 1800;
          description = "Longest wait for a Lidarr import in `Imported` completion mode.";
        };
      };

      download = {
        source = lib.mkOption {
          type = lib.types.enum [
            "lidarr"
            "none"
          ];
          default = "lidarr";
          description = ''
            Where a heart's permanent copy comes from. `none` keeps hearts from
            downloading anything: Octo still streams and hearts, and writes
            nothing.
          '';
        };
        onStar = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Download a starred song. Ignored when `download.source` is `none`.";
        };
        onAlbumStar = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Download a starred album. Ignored when `download.source` is `none`.";
        };
      };

      stream = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run the yt-dlp shim, which Octo streams unowned songs through.";
        };
        playerClient = lib.mkOption {
          type = lib.types.str;
          default = "visionos";
          description = ''
            YouTube player client the shim requests stream URLs from; empty
            leaves yt-dlp its own clients, whose URLs only play after a wait.
          '';
        };
      };

      sonic = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Make Octo's Sounds alike radio work from the sonic sidecar's analysis.";
        };
        cpus = lib.mkOption {
          type = lib.types.ints.positive;
          default = 1;
          description = "CPUs the sonic sidecar may use; docker refuses more than the host has.";
        };
      };

      coverBadge = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Mark covers of songs not in the library, which a heart downloads.";
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Dotenv files passed to the container and read by the `secretEnv` remap.
          This is the home for the credentials; they never enter the Nix store.
        '';
      };

      secretEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          Lidarr__ApiKey = "LIDARR_API_KEY";
          Subsonic__AdminPassword = "OCTO_ADMIN_PAT";
          LastFm__ApiKey = "LASTFM_API_KEY";
          LastFm__ApiSecret = "LASTFM_SECRET";
        };
        description = ''
          Map an Octo env name to a neutral secret name looked up in
          `environmentFiles`. The values are re-emitted into a runtime dotenv the
          container reads, so a secret never enters the typed settings. Set to
          `{ }` to disable the remap.
        '';
      };

      extraEnvironment = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        example.Subsonic__WaitForLosslessOnPlay = true;
        description = ''
          Extra exact-name variables for Octo, merged last — this is how a host
          overrides one of the module's own defaults.
        '';
      };

      shimImage = lib.mkOption {
        type = lib.types.str;
        default = shimContainer.image;
        description = "OCI image for the yt-dlp shim sidecar.";
      };

      sonicImage = lib.mkOption {
        type = lib.types.str;
        default = sonicContainer.image;
        description = "OCI image for the sonic sidecar.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      remapEnabled = cfg.secretEnv != { };

      remap = mkSecretEnv {
        inherit lib pkgs;
        service = cfg.name;
        target = "/run/octo.env";
        inherit (cfg) environmentFiles;
        mapping = cfg.secretEnv;
        consumer = "docker-${cfg.name}.service";
      };

      network =
        if cfg.network == null then
          null
        else
          {
            inherit (cfg.network) name subnet;
            ip = null;
          };

      lidarrEnabled = cfg.download.source == "lidarr";
      downloadsEnabled = cfg.download.source != "none";

      octoEnvironment = {
        Subsonic__Url = cfg.shimUrl;
        Subsonic__AdminUsername = cfg.admin.username;
        Subsonic__DownloadSource = "Lidarr";
        Subsonic__DownloadOnStar = downloadsEnabled && cfg.download.onStar;
        Subsonic__DownloadAlbumOnStar = downloadsEnabled && cfg.download.onAlbumStar;
        Subsonic__DownloadAlbumOnSongStar = false;
        Subsonic__StorageMode = "Stream";
        Subsonic__DownloadMode = "Track";
        Subsonic__SkipOwnedSongs = true;
        Subsonic__EnableSyncCatalog = true;
        Subsonic__SyncCatalogClients = "Symfonium";
        Subsonic__SyncCatalogMaxSongs = 1000;
        Subsonic__CoverBadge = cfg.coverBadge;
        Subsonic__SizeFlagClients = "Amperfy";
        Library__DownloadPath = musicPath;
        Lidarr__QualityProfileId = cfg.lidarr.qualityProfileId;
        Lidarr__MetadataProfileId = cfg.lidarr.metadataProfileId;
        Lidarr__CompletionMode = cfg.lidarr.completionMode;
        Lidarr__ImportTimeoutSeconds = cfg.lidarr.importTimeoutSeconds;
        Admin__SignIn = cfg.admin.signIn;
        Updates__Check = false;
      }
      // lib.optionalAttrs cfg.stream.enable {
        YouTube__ShimUrl = "http://${shimContainer.name}:${toString sidecarPort}";
      }
      // lib.optionalAttrs (lidarrEnabled && cfg.lidarr.baseUrl != null) {
        Lidarr__BaseUrl = cfg.lidarr.baseUrl;
      }
      // lib.optionalAttrs (lidarrEnabled && cfg.lidarr.rootFolderPath != null) {
        Lidarr__RootFolderPath = cfg.lidarr.rootFolderPath;
      }
      // cfg.environment
      // cfg.extraEnvironment;

      sidecar =
        {
          defaults,
          environment,
          volumes,
          extraOptions ? [ ],
        }:
        mkDockerService.config {
          spec = {
            inherit (defaults) name image;
            inherit (cfg) backend;
            inherit
              environment
              network
              volumes
              extraOptions
              ;
            openFirewall = false;
            ports = [ ];
            udpPorts = [ ];
            settings = { };
            cmd = [ ];
            entrypoint = null;
            gpuPassthrough = false;
            memoryLimit = null;
            environmentFiles = [ ];
            dockerMods = [ ];
            dependsOn = [ ];
            inherit (cfg) startLimitBurst startLimitIntervalSec;
          };
        } args;

      shimVolumes = [
        "${cfg.musicDir}:${musicPath}"
        "${cfg.cacheDir}/bin:${ytdlpPath}"
        "${cfg.cacheDir}/player:${ytdlpCachePath}"
        "${cfg.dataDir}:${ytShimDataPath}"
      ];

      sonicOptions = [
        "--user"
        "65534:65534"
        "--read-only"
        "--tmpfs"
        "/tmp"
        "--cap-drop"
        "ALL"
        "--security-opt"
        "no-new-privileges:true"
        "--cpus"
        (toString cfg.sonic.cpus)
        "--memory"
        "2g"
      ];
    in
    lib.mkMerge [
      (mkDockerService.config {
        spec = cfg // {
          ports = [ "127.0.0.1:${toString cfg.port}:${toString cfg.containerPort}" ];
          openFirewall = false;
          volumes = [
            "${cfg.configDir}:${configPath}"
            "${cfg.musicDir}:${musicPath}"
          ];
          environmentFiles = cfg.environmentFiles ++ lib.optional remapEnabled remap.environmentFile;
          environment = octoEnvironment;
          dependsOn = lib.optional cfg.stream.enable shimContainer.name ++ [ sonicContainer.name ];
          inherit network;
        };
        defaults = octoDefaults;
      } args)

      (lib.mkIf cfg.stream.enable (sidecar {
        defaults = shimContainer // {
          image = cfg.shimImage;
        };
        environment = {
          YTDLP_PLAYER_CLIENT = cfg.stream.playerClient;
          SHIM_THREADS = 128;
          MAX_CONCURRENT_YTDLP = 5;
          GATE_RESERVE_INTERACTIVE = 2;
          BG_GATE_WAIT_SEC = 10;
          SEARCH_CACHE_MAX = 1024;
          URL_CACHE_MAX = 512;
          URL_CACHE_TTL = 3600;
          DOWNLOAD_ROOT = musicPath;
          YTDLP_PATH = "${ytdlpPath}/yt-dlp";
          META_DB_PATH = "${ytShimDataPath}/meta.db";
        };
        volumes = shimVolumes;
      }))

      (sidecar {
        defaults = sonicContainer // {
          image = cfg.sonicImage;
        };
        environment = {
          MUSIC_ROOT = musicPath;
          ANALYSE_CONCURRENCY = 1;
          SONIC_ENABLED = cfg.sonic.enable;
        };
        volumes = [ "${cfg.musicDir}:${musicPath}:ro" ];
        extraOptions = sonicOptions;
      })

      {
        assertions = [
          {
            assertion = !remapEnabled || cfg.environmentFiles != [ ];
            message = "dots.system.services.music.octo.secretEnv needs environmentFiles to read the secrets from.";
          }
          {
            assertion = !lidarrEnabled || (cfg.lidarr.baseUrl != null && cfg.lidarr.rootFolderPath != null);
            message = "dots.system.services.music.octo.lidarr.baseUrl and rootFolderPath are needed when download.source is lidarr.";
          }
        ];

        systemd.services = {
          "${remap.unitName}" = lib.mkIf remapEnabled remap.unit;

          "docker-${cfg.name}" = lib.mkIf remapEnabled {
            after = [ "${remap.unitName}.service" ];
            wants = [ "${remap.unitName}.service" ];
          };
        };
      }
    ];
}
