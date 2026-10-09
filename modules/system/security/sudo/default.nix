# sudo prompt, opt-in per host. Sets the terminal password prompt (SUDO_PROMPT)
# and keeps it across sudo's environment reset. Value ported from nix-dotfiles.
{ config, lib, ... }:
let
  cfg = config.dots.system.security.sudo;
in
{
  options.dots.system.security.sudo = {
    enable = lib.mkEnableOption "sudo prompt customisation";

    prompt = lib.mkOption {
      type = lib.types.str;
      default = "%p 󱕵 ❯ ";
      description = ''
        Value of `SUDO_PROMPT` (the terminal password prompt). Set as a session
        variable and kept across sudo's environment reset.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.sessionVariables.SUDO_PROMPT = cfg.prompt;

    # sudo resets the environment, so keep SUDO_PROMPT for the elevated shell.
    security.sudo.extraConfig = ''Defaults env_keep += "SUDO_PROMPT"'';
  };
}
