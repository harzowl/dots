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

    users = lib.mapAttrs (
      name: userCfg:
      lib.mkMerge [
        { imports = [ (import ../../home { root = [ ]; }) ]; }
        # Shell modules read `loginShell` and enable themselves when it matches,
        # so aliases land in a shell that is actually generated.
        { _module.args.loginShell = config.dots.system.users.${name}.shell or null; }
        userCfg
      ]
    ) config.dots.home.users;
  };
}
