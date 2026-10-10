# fd — a simple, fast alternative to `find`. Uses the system package on the
# system target and `home.packages` on the home target.
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "search"
    "fd"
  ];
  description = "fd (a fast `find` replacement)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.fd;
        description = "The fd package to use.";
      };

      ignores = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Patterns written to `~/.config/fd/ignore`.";
      };
    };

  home =
    args: cfg:
    args.lib.mkMerge [
      { home.packages = [ cfg.package ]; }
      (args.lib.mkIf (cfg.ignores != [ ]) {
        xdg.configFile."fd/ignore".text = args.lib.concatStringsSep "\n" cfg.ignores;
      })
    ];

  system = args: cfg: { environment.systemPackages = [ cfg.package ]; };
}
