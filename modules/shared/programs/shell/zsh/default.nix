# zsh, defined once for both targets. NixOS's `programs.zsh` has no `package`
# option, so the system target installs it via `environment.systemPackages`.
{ target, root ? [ "dots" target ] }:
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

  home =
    args: cfg:
    {
      programs.zsh = {
        enable = true;
        package = cfg.package;
      }
      // cfg.settings;
    };

  system =
    args: cfg:
    {
      programs.zsh = {
        enable = true;
      }
      // cfg.settings;

      environment.systemPackages = [ cfg.package ];
    };
}
