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
        description = "beets configuration keys, merged over `directory` and `library`; a section with `enable = true` is listed in `plugins` under its optional `plugin` name, defaulting to the section name.";
      };

      extraPlugins = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        example = [ "/path/to/plugin.py" ];
        description = "Python plugin files installed under /etc/beets/plugins and appended to `pluginpath`.";
      };

      pluginData = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        example = [ "/path/to/descriptors.txt" ];
        description = "Data files installed beside `extraPlugins` under /etc/beets/plugins.";
      };

      externalPlugins = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "Source trees whose `beetsplug` directory is added to `pluginpath`.";
      };

      pythonPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Python packages the external plugins import, added to beets' `PYTHONPATH`.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.beets;
        description = "beets package to use.";
      };

      wrapper = lib.mkOption {
        type = lib.types.package;
        default = pkgs.beets;
        description = "Generated `beet` wrapper carrying the runtime config and plugin environment.";
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
        if lib.isAttrs section then
          removeAttrs section [
            "enable"
            "plugin"
          ]
        else
          section
      ) cfg.settings;

      plugins = lib.concatLists (
        lib.mapAttrsToList (
          name: section:
          lib.optional (lib.isAttrs section && section ? enable && section.enable == true) (
            section.plugin or name
          )
        ) cfg.settings
      );

      pluginDir = "/etc/beets/plugins";
      installedFiles = cfg.extraPlugins ++ cfg.pluginData;
      installedNames = map (file: baseNameOf (toString file)) installedFiles;
      externalPluginPaths = map (plugin: "${plugin}/beetsplug") cfg.externalPlugins;
      userPluginPath = cfg.settings.pluginpath or [ ];
      hasPluginPath = cfg.extraPlugins != [ ] || cfg.externalPlugins != [ ] || cfg.settings ? pluginpath;

      config = (pkgs.formats.yaml { }).generate "beets-config.yaml" (
        (lib.recursiveUpdate {
          directory = cfg.musicDir;
          library = cfg.libraryDb;
          inherit plugins;
        } (lib.filterAttrs (_: section: section != { }) (removeAttrs sections [ "pluginpath" ])))
        // lib.optionalAttrs hasPluginPath {
          pluginpath = [ pluginDir ] ++ externalPluginPaths ++ userPluginPath;
        }
      );

      runtimeConfig = "/run/beets/config.yaml";
      configPath = if cfg.secrets == { } then cfg.configFile else runtimeConfig;

      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ] ++ cfg.pythonPackages);
      pythonPath = "${python}/${pkgs.python3.sitePackages}";

      secretArgs = lib.concatStrings (
        lib.mapAttrsToList (path: variable: " " + lib.escapeShellArg "${path}=${variable}") cfg.secrets
      );

      beet = pkgs.writeShellScriptBin "beet" (
        lib.replaceStrings
          [ "@PACKAGE@" "@CONFIG@" "@FFMPEG@" "@PYTHONPATH@" ]
          [ "${cfg.package}" (lib.escapeShellArg configPath) "${pkgs.ffmpeg}" pythonPath ]
          (builtins.readFile ./beet.sh)
      );
    in
    {
      dots.programs.music.beets.wrapper = beet;

      assertions = [
        {
          assertion = !(cfg.settings ? plugins);
          message = "beets: set `settings.<plugin>.enable`, not `settings.plugins`; the module owns the plugin list.";
        }
        {
          assertion = cfg.secrets == { } || cfg.environmentFiles != [ ];
          message = "beets: `secrets` needs a non-empty `environmentFiles` to read the values from.";
        }
        {
          assertion = lib.all (plugin: lib.hasSuffix ".py" (baseNameOf (toString plugin))) cfg.extraPlugins;
          message = "beets: every `extraPlugins` entry must be a `.py` file.";
        }
        {
          assertion = builtins.length (lib.unique installedNames) == builtins.length installedNames;
          message = "beets: `extraPlugins` and `pluginData` entries must have distinct basenames.";
        }
        {
          assertion = lib.all (
            plugin: !(builtins.pathExists "${plugin}") || builtins.pathExists "${plugin}/beetsplug"
          ) cfg.externalPlugins;
          message = "beets: every `externalPlugins` entry must contain a `beetsplug` directory.";
        }
      ];

      environment = {
        etc = {
          ${lib.removePrefix "/etc/" cfg.configFile}.source = config;
        }
        // lib.listToAttrs (
          map (
            file: lib.nameValuePair "beets/plugins/${baseNameOf (toString file)}" { source = file; }
          ) installedFiles
        );
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
