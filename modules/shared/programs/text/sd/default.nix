# sd, defined once. sd has no config file, so `settings` become default flags on
# an `sd` wrapper that execs the real binary (see lib/mkCliFlags.nix).
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
  mkCliFlags = import ../../../../../lib/mkCliFlags.nix;

  wrapper =
    args: cfg:
    args.pkgs.writeShellScriptBin "sd" ''
      exec ${cfg.package}/bin/sd ${mkCliFlags { inherit (args) lib; inherit (cfg) settings; }} "$@"
    '';
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "text"
    "sd"
  ];
  description = "sd (sed alternative)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.sd;
        description = "The sd package to use.";
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Flags added to the `sd` command (see lib/mkCliFlags.nix).";
      };
    };

  home = args: cfg: { home.packages = [ (wrapper args cfg) ]; };

  system = args: cfg: { environment.systemPackages = [ (wrapper args cfg) ]; };
}
