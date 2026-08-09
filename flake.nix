{
  description = "Opinionated NixOS system/home configuration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }@inputs:
    {
      # NixOS module library: options under dots.system.*
      nixosModules.default = import ./modules/system;

      # Home Manager module library: options under dots.home.*
      homeModules.default = import ./modules/home;
    };
}
