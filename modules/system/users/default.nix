{
  config,
  lib,
  ...
}:
let
  cfg = config.dots.system.users;

  # `root` is accepted as an entry (`dots.system.users.root`) but is special:
  # it is not a normal user and ignores `role`, `shell` and `passwordlessSudo`.
  normalUsers = lib.removeAttrs cfg [ "root" ];
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

          passwordlessSudo = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Add the user to the `nopasswd` group, whose members get passwordless sudo; intended for admins (role = \"admin\").";
          };
        };
      }
    );

    default = { };
    description = ''
      Users to create on this node. The special name `root` targets the
      existing root account and only honours `keys`, `displayName` and
      `initialPassword`.
    '';
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg != { }) {
      users.users = lib.mapAttrs' (
        name: u:
        lib.nameValuePair name (
          if name == "root" then
            # root already exists; the login shell and group memberships are not
            # managed here. Only the authorized keys and description are.
            lib.mkMerge [
              { openssh.authorizedKeys.keys = u.keys; }
              (lib.mkIf (u.initialPassword != null) { initialPassword = u.initialPassword; })
              (lib.mkIf (u.displayName != null) { description = u.displayName; })
            ]
          else
            lib.mkMerge [
              {
                isNormalUser = true;
                openssh.authorizedKeys.keys = u.keys;
              }
              (lib.mkIf (u.role == "admin") { extraGroups = [ "wheel" ]; })
              (lib.mkIf (u.role == "admin" && u.passwordlessSudo) { extraGroups = [ "nopasswd" ]; })
              (lib.mkIf (u.shell == "fish") { shell = config.dots.system.programs.shell.fish.package; })
              (lib.mkIf (u.shell == "zsh") { shell = config.dots.system.programs.shell.zsh.package; })
              (lib.mkIf (u.initialPassword != null) { initialPassword = u.initialPassword; })
              (lib.mkIf (u.displayName != null) { description = u.displayName; })
            ]
        )
      ) cfg;
    })

    (lib.mkIf (lib.any (u: u.shell == "fish") (lib.attrValues normalUsers)) {
      dots.system.programs.shell.fish.enable = lib.mkDefault true;
    })

    (lib.mkIf (lib.any (u: u.shell == "zsh") (lib.attrValues normalUsers)) {
      dots.system.programs.shell.zsh.enable = lib.mkDefault true;
    })

    {
      assertions = [
        {
          assertion = lib.all (u: u.role == "admin" || !u.passwordlessSudo) (lib.attrValues normalUsers);
          message = "`dots.system.users.<name>.passwordlessSudo` requires `role = \"admin\"`.";
        }
      ];
    }

    (lib.mkIf (lib.any (u: u.role == "admin" && u.passwordlessSudo) (lib.attrValues normalUsers)) {
      # A dedicated group with passwordless sudo; opted-in admins are added to it
      # (see the user's `extraGroups`). `!authenticate` rather than a `NOPASSWD:`
      # rule, because the default `%wheel` rule still prompts for `sudo -v`.
      users.groups.nopasswd = { };
      security.sudo.extraConfig = "Defaults:%nopasswd !authenticate";
    })
  ];
}
