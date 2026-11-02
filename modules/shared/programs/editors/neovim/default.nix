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
    "editors"
    "neovim"
  ];
  description = "Neovim via nvf";

  options =
    { lib, ... }:
    {
      viAlias = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create a `vi` alias for `nvim`.";
      };

      vimAlias = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create a `vim` alias for `nvim`.";
      };

      defaultEditor = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Set `EDITOR=nvim` in the user's sessions.";
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "nvf settings (`programs.nvf.settings`), merged over `viAlias` and `vimAlias`; settings win on overlap.";
      };
    };

  home = args: cfg: {
    programs.nvf = {
      enable = true;
      inherit (cfg) defaultEditor;
      settings = args.lib.recursiveUpdate {
        vim = {
          inherit (cfg) viAlias vimAlias;
          theme.enable = false;
          options.termguicolors = false;
        };
      } cfg.settings;
    };
  };

  system = _: _: { };
}
