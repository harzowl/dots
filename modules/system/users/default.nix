{
  config,
  lib,
  ...
}:
let
  systemCfg = config.dots.system;
  shellCfg = systemCfg.programs.shell;
  cfg = systemCfg.users;
in
{
  options.dots.system.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          role = lib.mkOption {
            type = lib.types.enum [
              "admin"
              "user"
            ];
            default = "user";
            description = "admin adds the user to the wheel group.";
          };

          shell = lib.mkOption {
            type = lib.types.enum [
              "bash"
              "fish"
              "zsh"
            ];
            default = "fish";
            description = "Login shell.";
          };

          keys = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "SSH authorized keys for the user.";
          };

          initialPassword = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Initial password in plaintext (hashed with SHA-512 at activation). Use initialHashedPassword for a pre-hashed value.";
          };

          displayName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Display name for the user.";
          };

          emailAddress = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Email address for the user.";
          };
        };
      }
    );

    default = { };
    description = "Users to create on this node.";
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg != { }) {
      users.users = lib.mapAttrs' (
        name: u:
        lib.nameValuePair name (
          lib.mkMerge [
            {
              isNormalUser = true;
              openssh.authorizedKeys.keys = u.keys;
            }
            (lib.mkIf (u.role == "admin") { extraGroups = [ "wheel" ]; })
            (lib.mkIf (u.shell == "fish") { shell = shellCfg.fish.package; })
            (lib.mkIf (u.shell == "zsh") { shell = shellCfg.zsh.package; })
            (lib.mkIf (u.initialPassword != null) { initialPassword = u.initialPassword; })
            (lib.mkIf (u.displayName != null) { description = u.displayName; })
          ]
        )
      ) cfg;
    })

    (lib.mkIf (lib.any (u: u.shell == "fish") (lib.attrValues cfg)) {
      shellCfg.fish.enable = lib.mkDefault true;
    })

    (lib.mkIf (lib.any (u: u.shell == "zsh") (lib.attrValues cfg)) {
      shellCfg.zsh.enable = lib.mkDefault true;
    })
  ];
}
