{
  nixpkgs,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
in
rec {
  # Creates a NixOS configuration for a Proxmox LXC container.
  mkLxc =
    {
      hostname,
      modules,
      system ? "x86_64-linux",
    }:
    lib.nixosSystem {
      inherit system;
      modules = [
        ({ modulesPath, ... }: {
          imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];
          networking.hostName = lib.mkDefault hostname;
          nix.settings.sandbox = false;
          proxmoxLXC.manageNetwork = false;
          services.openssh.enable = true;
        })
      ]
      ++ modules;
    };

  # Returns role-based configuration attributes for a user.
  mkUserRole =
    {
      name,
      role,
    }:
    assert lib.assertOneOf "mkUserRole.role" role [
      "admin"
      "user"
    ];
    {
      users.users.${name}.extraGroups = if role == "admin" then [ "wheel" ] else [ ];
    };

  # Returns shell configuration attributes for a user.
  mkUserShell =
    {
      name,
      shell,
    }:
    assert lib.assertOneOf "mkUserShell.shell" shell [
      "bash"
      "fish"
    ];
    lib.optionalAttrs (shell == "fish") {
      programs.fish.enable = true;
      users.users.${name}.shell = pkgs.fish;
    };

  # Creates a user with authorized keys and default groups.
  mkUser =
    {
      name,
      keys ? [ ],
      role ? "user",
      shell ? "fish",
      initialPassword ? null,
    }:
    lib.foldl' lib.recursiveUpdate { } [
      {
        users.users.${name} = {
          inherit initialPassword;
          isNormalUser = true;
          openssh.authorizedKeys.keys = keys;
        };
      }
      (mkUserRole { inherit name role; })
      (mkUserShell { inherit name shell; })
    ];
}
