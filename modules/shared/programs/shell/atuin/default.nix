# atuin — shell history search. home-manager ships `programs.atuin`, so the home
# target uses it (with shell integration for every shell); the system target
# just installs the package.
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

      # Shell-agnostic by construction: `atuin init` binds Ctrl-R in every shell
      # it supports and is what each integration (fish, zsh, bash, nushell) runs,
      # so this is a flag to that one command rather than per-shell config.
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
      inherit (cfg)
        package
        settings
        ;
      flags = cfg.flags ++ args.lib.optional (!cfg.replaceNativeSearch) "--disable-ctrl-r";
      enableFishIntegration = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
      enableNushellIntegration = true;
    };
  };

  system = args: cfg: { environment.systemPackages = [ cfg.package ]; };
}
