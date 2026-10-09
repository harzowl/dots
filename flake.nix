{
  description = "Simplified NixOS system/home configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, home-manager, ... }:
    {
      # NixOS module library: options under dots.system.*
      nixosModules.default = import ./modules/system;

      # NixOS Home Manager integration: options under dots.home.users.*
      nixosModules.home = {
        imports = [
          home-manager.nixosModules.home-manager
          (import ./modules/system/home)
        ];
      };

      # Home Manager module library: options under dots.home.*
      homeModules.default = import ./modules/home;
    };
}
