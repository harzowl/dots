# nh, defined once. Both NixOS and home-manager expose `programs.nh`, so the same
# definition drives either target. Ported from nix-dotfiles, including the
# `patches.nerd-font-icons` overlay that swaps nix-output-monitor's glyphs for
# Nerd Font codepoints (on by default).
{ target, root ? [ "dots" target ] }:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;

  # Replace nix-output-monitor's unicode glyphs with Nerd Font codepoints so they
  # render in a patched font. Ported verbatim from nix-dotfiles.
  nomOverlay =
    args: _final: prev:
    {
      nix-output-monitor = prev.nix-output-monitor.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          sed -i -e ${
            args.lib.escapeShellArg ''
              s/↓/\\xf072e/
              s/↑/\\xf0737/
              s/⏱/\\xf520/
              s/⏵/\\xf04b/
              s/✔/\\xf00c/
              s/⏸/\\xf04d/
              s/⚠/\\xf071/
              s/∅/\\xf1da/
              s/∑/\\xf04a0/
            ''
          } lib/NOM/Print.hs
        '';
      });
    };
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "nix"
    "nh"
  ];
  description = "nh (yet another Nix CLI helper)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.nh;
        description = "The nh package to use.";
      };

      flake = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Default flake for `nh` (sets `NH_FLAKE`).";
      };

      clean = {
        enable = lib.mkEnableOption "periodic garbage collection with `nh clean`";

        dates = lib.mkOption {
          type = lib.types.singleLineStr;
          default = "weekly";
          description = "systemd calendar spec for the `nh clean` timer.";
        };

        extraArgs = lib.mkOption {
          type = lib.types.singleLineStr;
          default = "";
          example = "--keep 5 --keep-since 3d";
          description = "Extra arguments given to the automatic `nh clean`.";
        };
      };

      patches.nerd-font-icons = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Patch nix-output-monitor to use Nerd Font glyphs instead of its default
          unicode symbols (ported from nix-dotfiles).
        '';
      };
    };

  home =
    args: cfg:
    args.lib.mkMerge [
      {
        programs.nh = {
          enable = true;
          inherit (cfg) package flake;
          clean = {
            inherit (cfg.clean) enable dates extraArgs;
          };
        };
      }
      (args.lib.mkIf cfg.patches.nerd-font-icons {
        nixpkgs.overlays = [ (nomOverlay args) ];
      })
    ];

  system =
    args: cfg:
    args.lib.mkMerge [
      {
        programs.nh = {
          enable = true;
          inherit (cfg) package flake;
          clean = {
            inherit (cfg.clean) enable dates extraArgs;
          };
        };
      }
      (args.lib.mkIf cfg.patches.nerd-font-icons {
        nixpkgs.overlays = [ (nomOverlay args) ];
      })
    ];
}
