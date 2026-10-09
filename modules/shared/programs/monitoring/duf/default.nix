# duf, defined once. duf has no config file, so `settings` are turned into flags
# on a `duf` wrapper that execs the real binary, e.g.
# `settings.only = [ "special" ]` runs `duf --only special`.
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
  mkCliFlags = import ../../../../../lib/mkCliFlags.nix;

  # Defaults: hide duf's `special` table (pseudo/duplicate/inaccessible
  # filesystems), and use duf's `ansi` theme so colors come from the terminal's
  # base16 palette instead of its built-in RGB theme. Override via `settings`.
  defaults = {
    hide = [ "special" ];
    theme = "ansi";
  };

  wrapper =
    args: cfg:
    let
      settings = args.lib.recursiveUpdate defaults cfg.settings;
    in
    args.pkgs.writeShellScriptBin "duf" ''
      exec ${cfg.package}/bin/duf ${mkCliFlags { inherit (args) lib; inherit settings; }} "$@"
    '';
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "monitoring"
    "duf"
  ];
  description = "duf disk usage/free utility";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.duf;
        description = "The duf package to use.";
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = ''
          Flags added to the `duf` command. Keys become `--<key>` (underscores
          become dashes), `true` emits a bare flag, `false`/`null` are omitted,
          lists are comma-joined, and other values are passed as the argument.
          For example `{ only = [ "special" ]; }` runs `duf --only special`.

          Merged over the built-in defaults (`--hide special`, `--theme ansi`):
          setting a key overrides that default, other defaults stay.
        '';
      };
    };

  home = args: cfg: { home.packages = [ (wrapper args cfg) ]; };

  system = args: cfg: { environment.systemPackages = [ (wrapper args cfg) ]; };
}
