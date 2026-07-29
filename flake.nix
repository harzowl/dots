{
  description = "NixOS flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    colmena.url = "github:zhaofengli/colmena";
    colmena.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, colmena, ... }:
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

      colmenaHive = colmena.lib.makeHive {
        meta = {
          nixpkgs = import nixpkgs { inherit system; };
        };
        "lxc-test" = {
          imports = lib.mkLxcModules { hostname = "test"; };
          deployment.targetHost = "test";
        }
        // (lib.mkUser {
          name = "testuser";
          role = "admin";
        })
        // { system.stateVersion = "26.05"; };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ colmena.packages.${system}.colmena ];
      };
    };
}
