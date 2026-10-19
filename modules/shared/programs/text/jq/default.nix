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
    "text"
    "jq"
  ];
  description = "jq (JSON processor)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.jq;
        description = "The jq package to use.";
      };
    };

  home = _args: cfg: { home.packages = [ cfg.package ]; };

  system = _args: cfg: { environment.systemPackages = [ cfg.package ]; };
}
