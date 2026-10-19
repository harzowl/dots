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

      settings = lib.mkOption {
        inherit ((pkgs.formats.yaml { })) type;
        default = { };
        description = "beets configuration keys, merged over `directory` and `library`.";
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

      config = (pkgs.formats.yaml { }).generate "beets-config.yaml" (
        lib.recursiveUpdate {
          directory = cfg.musicDir;
          library = cfg.libraryDb;
        } cfg.settings
      );

      beet = pkgs.writeShellScriptBin "beet" (
        lib.replaceStrings
          [ "@PACKAGE@" "@CONFIG@" ]
          [ "${cfg.package}" (lib.escapeShellArg cfg.configFile) ]
          (builtins.readFile ./beet.sh)
      );
    in
    {
      environment = {
        etc.${lib.removePrefix "/etc/" cfg.configFile}.source = config;
        systemPackages = [ beet ];
      };

      systemd.tmpfiles.rules = [
        "d ${dirOf cfg.configFile} 0755 ${owner.user} ${owner.group} -"
        "d ${dirOf cfg.libraryDb} 0755 ${owner.user} ${owner.group} -"
      ];
    };
}
