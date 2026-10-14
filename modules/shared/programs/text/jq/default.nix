# jq, defined once. It reads no config file, so there is nothing to project but
# the package: `home` installs it into the user's profile, `system` into
# `environment.systemPackages`.
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
