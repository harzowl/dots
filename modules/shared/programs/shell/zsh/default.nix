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
    "zsh"
  ];
  description = "zsh shell";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.zsh;
        description = "The zsh package to use.";
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Additional settings forwarded verbatim to zsh shell";
      };
    };

  home = _args: cfg: {
    programs.zsh = {
      enable = true;
      inherit (cfg) package;
    }
    // cfg.settings;
  };

  system = _args: cfg: {
    programs.zsh = {
      enable = true;
    }
    // cfg.settings;

    environment.systemPackages = [ cfg.package ];
  };
}
