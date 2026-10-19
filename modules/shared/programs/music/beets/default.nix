let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
in
mkDotsModule {
  optionPath = [
    "programs"
    "music"
    "beets"
  ];
  description = "beets music library manager (manual CLI only)";

  options =
    { lib, pkgs, ... }:
    {
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Owner of the state directory and library database; null leaves root's ownership.";
      };

      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Group of the state directory and library database; null leaves root's ownership.";
      };

      musicDir = lib.mkOption {
        type = lib.types.str;
        description = "Directory beets organises the library into.";
      };

      libraryDb = lib.mkOption {
        type = lib.types.str;
        description = "Path to the SQLite library database.";
      };

      configFile = lib.mkOption {
        type = lib.types.str;
        default = "/etc/beets/config.yaml";
        description = "Managed configuration path beets reads.";
      };

      secrets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "fetchart.fanarttv_key" = "FANARTTV_KEY";
        };
        description = "Dotted beets config keys whose values are read from environment variables at runtime, never from the store.";
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/run/secretspec/env" ];
        description = "Environment files the runtime config unit reads the secret values from.";
      };

      settings = lib.mkOption {
        inherit ((pkgs.formats.yaml { })) type;
        default = { };
        description = "beets configuration keys, merged over `directory` and `library`; a section with `enable = true` is listed in `plugins`.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.beets;
        description = "beets package to use.";
      };
    };

  toConfig =
    args: cfg:
    let
      inherit (args) lib pkgs;

      owner = {
        user = if cfg.user != null then cfg.user else "-";
        group = if cfg.group != null then cfg.group else "-";
      };

      sections = lib.mapAttrs (
        _: section:
        if lib.isAttrs section && section ? enable then removeAttrs section [ "enable" ] else section
      ) cfg.settings;

      plugins = lib.attrNames (
        lib.filterAttrs (
          _: section: lib.isAttrs section && section ? enable && section.enable == true
        ) cfg.settings
      );

      config = (pkgs.formats.yaml { }).generate "beets-config.yaml" (
        lib.recursiveUpdate {
          directory = cfg.musicDir;
          library = cfg.libraryDb;
          inherit plugins;
        } (lib.filterAttrs (_: section: section != { }) sections)
      );

      runtimeConfig = "/run/beets/config.yaml";
      configPath = if cfg.secrets == { } then cfg.configFile else runtimeConfig;

      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

      secretArgs = lib.concatStrings (
        lib.mapAttrsToList (path: variable: " " + lib.escapeShellArg "${path}=${variable}") cfg.secrets
      );

      beet = pkgs.writeShellScriptBin "beet" (
        lib.replaceStrings [ "@PACKAGE@" "@CONFIG@" ] [ "${cfg.package}" (lib.escapeShellArg configPath) ] (
          builtins.readFile ./beet.sh
        )
      );
    in
    {
      assertions = [
        {
          assertion = !(cfg.settings ? plugins);
          message = "beets: set `settings.<plugin>.enable`, not `settings.plugins`; the module owns the plugin list.";
        }
        {
          assertion = cfg.secrets == { } || cfg.environmentFiles != [ ];
          message = "beets: `secrets` needs a non-empty `environmentFiles` to read the values from.";
        }
      ];

      environment = {
        etc.${lib.removePrefix "/etc/" cfg.configFile}.source = config;
        systemPackages = [ beet ];
      };

      systemd = {
        services = lib.mkIf (cfg.secrets != { }) {
          beets-config = {
            description = "Render the beets config with runtime secrets";
            wantedBy = [ "multi-user.target" ];
            after = [ "secretspec.service" ];
            wants = [ "secretspec.service" ];
            partOf = [ "secretspec.service" ];
            path = [ python ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              RuntimeDirectory = "beets";
              RuntimeDirectoryMode = "0700";
              EnvironmentFile = cfg.environmentFiles;
            }
            // lib.optionalAttrs (cfg.user != null) { User = cfg.user; }
            // lib.optionalAttrs (cfg.group != null) { Group = cfg.group; };
            script = ''
              set -eu
              exec ${python}/bin/python3 ${./render-config.py} \
                ${lib.escapeShellArg config} \
                ${lib.escapeShellArg runtimeConfig}${secretArgs}
            '';
          };
        };

        tmpfiles.rules = [
          "d ${dirOf cfg.configFile} 0755 ${owner.user} ${owner.group} -"
          "d ${dirOf cfg.libraryDb} 0755 ${owner.user} ${owner.group} -"
        ];
      };
    };
}
