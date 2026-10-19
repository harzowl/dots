{
  target,
  root ? [
    "dots"
    target
  ],
}:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "shell"
    "atuin"
  ];
  description = "atuin (shell history search)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.atuin;
        description = "The atuin package to use.";
      };

      replaceNativeSearch = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Bind Ctrl-R to atuin's search instead of the shell's built-in reverse
          search. atuin's `init` does this by default in every shell, so this
          only does something when set to `false` (it then passes
          `--disable-ctrl-r`).
        '';
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Contents of atuin's `config.toml`.";
      };

      theme = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "autumn";
        description = ''
          atuin's `[theme] name`: a built-in (`default`, `autumn`, `marine`,
          `default-powershell`, `(none)`) or a theme file in
          `~/.config/atuin/themes/`. `null` leaves atuin's own default, whose
          colours are ANSI palette entries — so they follow the terminal's
          scheme rather than hardcoding hex.
        '';
      };

      flags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Extra `atuin init` flags, e.g. `--disable-up-arrow` or `--disable-ai`.
        '';
      };
    };

  home = args: cfg: {
    programs.atuin = {
      enable = true;
      inherit (cfg) package;
      settings =
        cfg.settings
        // args.lib.optionalAttrs (cfg.theme != null) {
          theme = (cfg.settings.theme or { }) // {
            name = cfg.theme;
          };
        };
      flags = cfg.flags ++ args.lib.optional (!cfg.replaceNativeSearch) "--disable-ctrl-r";
      enableFishIntegration = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
      enableNushellIntegration = true;
    };
  };

  system = _args: cfg: { environment.systemPackages = [ cfg.package ]; };
}
