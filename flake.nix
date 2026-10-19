{
  description = "Simplified NixOS system/home configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, home-manager, ... }@inputs:
    {
      nixosModules = {
        default =
          { pkgs, ... }:
          {
            imports = [ (import ./modules/system) ];
            _module.args.pkgsUnstable = import inputs."nixpkgs-unstable" {
              system = pkgs.stdenv.hostPlatform.system;
            };
          };

        home = {
          imports = [
            home-manager.nixosModules.home-manager
            (import ./modules/system/home)
          ];
        };

        presetServer = import ./presets/server.nix;
      };

      homeModules.default = import ./modules/home;

      formatter.x86_64-linux = inputs.nixpkgs.legacyPackages.x86_64-linux.nixfmt;

      packages.x86_64-linux.subsonic-auth =
        inputs.nixpkgs.legacyPackages.x86_64-linux.callPackage
          ./modules/system/services/music/subsonic-auth/package.nix
          { };

      checks.x86_64-linux = {
        subsonic-auth = self.packages.x86_64-linux.subsonic-auth;

        lints =
          let
            pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.fileFilter (file: file.hasExt "nix") ./.;
            };
          in
          pkgs.runCommand "lints"
            {
              nativeBuildInputs = [
                pkgs.statix
                pkgs.deadnix
              ];
            }
            ''
              bash ${./scripts/lints.sh} ${src}
              touch "$out"
            '';

        secret-scan =
          let
            pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
          in
          pkgs.runCommand "secret-scan"
            {
              nativeBuildInputs = [
                pkgs.gitleaks
                pkgs.python3
              ];
            }
            ''
              export HOME="$TMPDIR"
              gitleaks detect --no-git --source ${self} --redact --exit-code 1 --no-banner
              python3 ${self}/scripts/secret-scan.py ${self}
              touch "$out"
            '';

        guards =
          let
            pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
          in
          pkgs.runCommand "guards"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.git
                pkgs.gnugrep
                pkgs.gnused
                pkgs.python3
              ];
            }
            ''
              bash ${self}/tests/secret-scan/run.sh
              bash ${self}/tests/personal-data/run.sh
              touch "$out"
            '';

        env-keys =
          let
            pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
            toEnvKey = import ./lib/camelToUpperSnake.nix { inherit (pkgs) lib; };
            cases = {
              listen = "LISTEN";
              upstreamUrl = "UPSTREAM_URL";
              cacheDir = "CACHE_DIR";
              cacheEnabled = "CACHE_ENABLED";
              coverCacheDir = "COVER_CACHE_DIR";
              lastfmDbPath = "LASTFM_DB_PATH";
              catalogDb = "CATALOG_DB";
              catalogExcludeReleaseTypes = "CATALOG_EXCLUDE_RELEASE_TYPES";
              genreDisplayMode = "GENRE_DISPLAY_MODE";
              genreDisplayGenreModes = "GENRE_DISPLAY_GENRE_MODES";
              genreDisplayExceptions = "GENRE_DISPLAY_EXCEPTIONS";
              genreDisplayMinorWords = "GENRE_DISPLAY_MINOR_WORDS";
              genreDisplayWordSubstitutions = "GENRE_DISPLAY_WORD_SUBSTITUTIONS";
              lidarrMonitor = "LIDARR_MONITOR";
              ytdlpSourceOrder = "YTDLP_SOURCE_ORDER";
              ytdlpSourceTimeouts = "YTDLP_SOURCE_TIMEOUTS";
              stationsEnabled = "STATIONS_ENABLED";
              stationPinned = "STATION_PINNED";
              stationSize = "STATION_SIZE";
              stationTTL = "STATION_TTL";
              stationSources = "STATION_SOURCES";
              stationSourceTimeouts = "STATION_SOURCE_TIMEOUTS";
              maxTagLength = "MAX_TAG_LENGTH";
              musicbrainzUa = "MUSICBRAINZ_UA";
              stationStreamTTL = "STATION_STREAM_TTL";
              ytdlpResolveCacheTtl = "YTDLP_RESOLVE_CACHE_TTL";
              oauth2ProxyClientId = "OAUTH2_PROXY_CLIENT_ID";
              maxPlayers = "MAX_PLAYERS";
              apiClient = "API_CLIENT";
            };
          in
          pkgs.runCommand "env-keys" { } ''
            ${pkgs.lib.concatStringsSep "\n" (
              pkgs.lib.mapAttrsToList (name: want: ''
                got='${toEnvKey name}'
                if [ "$got" != '${want}' ]; then
                  echo "env key for ${name} = $got, want ${want}" >&2
                  exit 1
                fi
              '') cases
            )}
            touch "$out"
          '';

        navidrome-sync =
          let
            pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
          in
          pkgs.runCommand "navidrome-sync"
            {
              nativeBuildInputs = [ pkgs.bash ];
            }
            ''
              bash ${self}/tests/navidrome-sync/run.sh
              touch "$out"
            '';

        slskd-import =
          let
            pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
          in
          pkgs.runCommand "slskd-import"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.python3
              ];
            }
            ''
              bash ${self}/tests/slskd-import/run.sh
              touch "$out"
            '';
      };
    };
}
