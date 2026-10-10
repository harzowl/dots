# eza, defined once. Imported by both `modules/system` and `modules/home` (each
# passing its target), so the same definition surfaces as
# `dots.system.programs.files.eza` and `dots.home.programs.files.eza`.
#
#   system target -> install the package system-wide
#   home target   -> manage `programs.eza` per user
#
# `aliasLs` replaces `ls` with eza in every shell, and `aliases` adds any extra
# ones (e.g. `{ t = "eza --tree"; }`).
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;
  mkShellAlias = import ../../../../../lib/mkShellAlias.nix;
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "files"
    "eza"
  ];
  description = "eza (a modern ls replacement)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.eza;
        description = "The eza package to install.";
      };

      icons = lib.mkOption {
        type = lib.types.enum [
          "auto"
          "always"
          "never"
        ];
        default = "auto";
        description = "When to show icons (forwarded to `programs.eza.icons` on the home target).";
      };

      extraOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra eza flags (forwarded to `programs.eza.extraOptions` on the home target).";
      };

      aliasLs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Define `ls` as an alias for `eza` in every shell.";
      };

      aliases = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra shell aliases, e.g. `{ t = \"eza --tree\"; }`.";
      };
    };

  home =
    args: cfg:
    args.lib.mkMerge [
      {
        programs.eza = {
          enable = true;
          inherit (cfg) package icons extraOptions;
        };
      }
      (args.lib.mkIf cfg.aliasLs (mkShellAlias { aliases = { ls = "eza"; }; } args))
      (args.lib.mkIf (cfg.aliases != { }) (mkShellAlias { inherit (cfg) aliases; } args))
    ];

  system =
    args: cfg:
    args.lib.mkMerge [
      { environment.systemPackages = [ cfg.package ]; }
      (args.lib.mkIf cfg.aliasLs (mkShellAlias { aliases = { ls = "eza"; }; } args))
      (args.lib.mkIf (cfg.aliases != { }) (mkShellAlias { inherit (cfg) aliases; } args))
    ];
}
