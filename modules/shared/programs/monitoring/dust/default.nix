# dust, defined once. dust has no config file, so `settings` become default flags
# on a `dust` wrapper that execs the real binary (see lib/mkCliFlags.nix).
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
  mkCliFlags = import ../../../../../lib/mkCliFlags.nix;

  wrapper =
    args: cfg:
    args.pkgs.writeShellScriptBin "dust" ''
      exec ${cfg.package}/bin/dust ${mkCliFlags { inherit (args) lib; inherit (cfg) settings; }} "$@"
    '';
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "monitoring"
    "dust"
  ];
  description = "dust (du alternative)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.dust;
        description = "The dust package to use.";
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Flags added to the `dust` command (see lib/mkCliFlags.nix).";
      };
    };

  home = args: cfg: { home.packages = [ (wrapper args cfg) ]; };

  system = args: cfg: { environment.systemPackages = [ (wrapper args cfg) ]; };
}
