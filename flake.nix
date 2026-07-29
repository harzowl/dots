{
  description = "NixOS flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = import ./lib { inherit nixpkgs system; };
    in
    {
      nixosConfigurations = {
        lxc-test = lib.mkLxc {
          hostname = "test";
          modules = [
            (lib.mkUser {
              name = "testuser";
              role = "admin";
            })
            { system.stateVersion = "26.05"; }
          ];
        };
      };
    };
}
