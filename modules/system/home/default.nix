{ config, lib, ... }:
{
  options.dots.home.users = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = ''
      Per-user Home Manager configuration. Each entry is wired to
      `home-manager.users.<name>`, with the dots home tree (core, programs and
      shell aliases) rooted directly under the user, e.g.
      `dots.home.users.<name>.programs.monitoring.bottom.enable`.
    '';
  };

  config.home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    # Back up unmanaged files that would otherwise be clobbered, so activation
    # never fails on a pre-existing ~/.config/... file.
    backupFileExtension = lib.mkDefault "hm-backup";

    users = lib.mapAttrs (
      name: userCfg:
      let
        shell = config.dots.system.users.${name}.shell or null;
      in
      lib.mkMerge [
        { imports = [ (import ../../home { root = [ ]; }) ]; }
        # Enable the login shell's program so its config (theme, aliases, ...) is
        # actually generated. Options live at `programs.shell.<shell>`.
        (lib.optionalAttrs (shell == "fish") {
          programs.shell.fish.enable = lib.mkDefault true;
        })
        (lib.optionalAttrs (shell == "zsh") {
          programs.shell.zsh.enable = lib.mkDefault true;
        })
        userCfg
      ]
    ) config.dots.home.users;
  };
}
