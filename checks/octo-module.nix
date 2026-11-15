# Evaluates a minimal host that enables the Octo module and asserts the rendered
# containers: the three of them, Octo's exact environment names, Lidarr-only
# downloads with no Soulseek source, the secret remap, and the sidecar wiring.
{ lib, pkgs }:
let
  music = import ../modules/system/services/music;

  # The navidrome module beside octo declares this consumer list; the check only
  # cares about what octo renders.
  secretspecStub =
    { lib, ... }:
    {
      options.dots.system.secretspec.consumers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };

  system =
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      modules = [
        music
        secretspecStub
        (_: {
          system.stateVersion = "26.05";
          boot.loader.grub.devices = [ "nodev" ];
          fileSystems."/" = {
            device = "/dev/sda1";
            fsType = "ext4";
          };

          dots.system.services.music.octo = {
            enable = true;
            network = {
              name = "music";
              subnet = "10.90.0.0/24";
            };
            dataDir = "/srv/octo/shim-data";
            configDir = "/srv/octo/config";
            cacheDir = "/srv/octo/cache";
            musicDir = "/srv/music";
            shimUrl = "http://10.90.0.10:4184";
            admin.username = "dummy-admin";
            environmentFiles = [ "/run/secretspec/env" ];
            lidarr = {
              baseUrl = "http://lidarr.example.test:8686";
              rootFolderPath = "/music";
            };
            memoryLimit = "1g";
          };
        })
      ];
    }).config;

  containers = system.virtualisation.oci-containers.containers;
  octoContainer = containers.octo;
  shim = containers.yt-dlp-shim;
  sonic = containers.octo-sonic;
  env = octoContainer.environment;

  expectedEnv = {
    Subsonic__Url = "http://10.90.0.10:4184";
    Subsonic__AdminUsername = "dummy-admin";
    Subsonic__DownloadSource = "Lidarr";
    Subsonic__DownloadOnStar = "true";
    Subsonic__DownloadAlbumOnStar = "true";
    Subsonic__DownloadAlbumOnSongStar = "false";
    Subsonic__StorageMode = "Stream";
    Subsonic__DownloadMode = "Track";
    Subsonic__SkipOwnedSongs = "true";
    Subsonic__EnableSyncCatalog = "true";
    Subsonic__SyncCatalogClients = "Symfonium";
    Subsonic__SyncCatalogMaxSongs = "1000";
    Subsonic__CoverBadge = "true";
    Subsonic__SizeFlagClients = "Amperfy";
    Library__DownloadPath = "/music";
    YouTube__ShimUrl = "http://yt-dlp-shim:8080";
    Lidarr__BaseUrl = "http://lidarr.example.test:8686";
    Lidarr__RootFolderPath = "/music";
    Lidarr__QualityProfileId = "0";
    Lidarr__MetadataProfileId = "0";
    Lidarr__CompletionMode = "Accepted";
    Lidarr__ImportTimeoutSeconds = "1800";
    Admin__SignIn = "required";
    Updates__Check = "false";
  };

  expectedShimEnv = {
    YTDLP_PLAYER_CLIENT = "visionos";
    SHIM_THREADS = "128";
    MAX_CONCURRENT_YTDLP = "5";
    GATE_RESERVE_INTERACTIVE = "2";
    BG_GATE_WAIT_SEC = "10";
    SEARCH_CACHE_MAX = "1024";
    URL_CACHE_MAX = "512";
    URL_CACHE_TTL = "3600";
    DOWNLOAD_ROOT = "/music";
    YTDLP_PATH = "/opt/ytdlp/yt-dlp";
    META_DB_PATH = "/var/lib/ytshim/meta.db";
  };

  sonicFlags = [
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
    "1"
    "--memory"
    "2g"
  ];

  wrongEnv = lib.filter (name: (env.${name} or null) != expectedEnv.${name}) (
    lib.attrNames expectedEnv
  );
  wrongShimEnv = lib.filter (name: (shim.environment.${name} or null) != expectedShimEnv.${name}) (
    lib.attrNames expectedShimEnv
  );

  names = lib.sort (a: b: a < b) (lib.attrNames containers);
  soulseekKeys = lib.filter (name: lib.hasPrefix "Soulseek" name) (lib.attrNames env);

  sidecars = [
    "docker-yt-dlp-shim.service"
    "docker-octo-sonic.service"
  ];
  unordered = lib.filter (
    unit: !(builtins.elem unit system.systemd.services.docker-octo.after)
  ) sidecars;

  networkFlag = "--network=music";
  offNetwork = lib.filter (name: !(builtins.elem networkFlag containers.${name}.extraOptions)) [
    "octo"
    "yt-dlp-shim"
    "octo-sonic"
  ];

  missingSonicFlags = lib.filter (flag: !(builtins.elem flag sonic.extraOptions)) sonicFlags;

  failures =
    lib.optional (
      names != [
        "octo"
        "octo-sonic"
        "yt-dlp-shim"
      ]
    ) "containers = ${builtins.toJSON names}, want octo, octo-sonic and yt-dlp-shim"
    ++ lib.optional (wrongEnv != [ ]) "wrong octo environment: ${lib.concatStringsSep ", " wrongEnv}"
    ++ lib.optional (
      soulseekKeys != [ ]
    ) "octo still has a Soulseek source: ${lib.concatStringsSep ", " soulseekKeys}"
    ++ lib.optional (
      wrongShimEnv != [ ]
    ) "wrong shim environment: ${lib.concatStringsSep ", " wrongShimEnv}"
    ++ lib.optional (
      octoContainer.ports != [ "5274:8080" ]
    ) "octo ports = ${builtins.toJSON octoContainer.ports}, want 5274:8080"
    ++ lib.optional (
      !(builtins.elem "--memory=1g" octoContainer.extraOptions)
    ) "octo memory limit was not rendered"
    ++ lib.optional (
      !(builtins.elem "/run/octo.env" octoContainer.environmentFiles)
    ) "octo does not read the remapped secret file"
    ++ lib.optional (!(system.systemd.services ? octo-env)) "the secret remap unit is missing"
    ++ lib.optional (
      system.systemd.services ? octo-env
      && !(builtins.elem "docker-octo.service" system.systemd.services.octo-env.before)
    ) "the secret remap unit does not run before the container"
    ++ lib.optional (
      unordered != [ ]
    ) "octo is not ordered after: ${lib.concatStringsSep ", " unordered}"
    ++ lib.optional (
      offNetwork != [ ]
    ) "containers outside the network: ${lib.concatStringsSep ", " offNetwork}"
    ++ lib.optional (!(system.systemd.services ? docker-network-music)) "the network unit is missing"
    ++ lib.optional (
      missingSonicFlags != [ ]
    ) "sonic hardening flags missing: ${lib.concatStringsSep ", " missingSonicFlags}"
    ++ lib.optional (
      sonic.volumes != [ "/srv/music:/music:ro" ]
    ) "sonic music volume = ${builtins.toJSON sonic.volumes}, want a read-only mount"
    ++ lib.optional (sonic.environment.SONIC_ENABLED != "true") "sonic did not get its enabled flag";
in
if failures == [ ] then
  pkgs.runCommand "octo-module" { } ''
    mkdir -p "$out"
    printf '%s\n' "octo renders its three containers with exact env names" > "$out/README"
  ''
else
  throw ''
    octo-module check failed:
      ${lib.concatStringsSep "\n  " failures}

    rendered octo environment:
    ${builtins.toJSON env}
  ''
