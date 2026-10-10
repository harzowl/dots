{
  description = "Simplified NixOS system/home configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, home-manager, ... }@inputs:
    {
      # NixOS module library: options under dots.system.*
      nixosModules.default =
        { pkgs, ... }:
        {
          imports = [ (import ./modules/system) ];
          # nixpkgs-unstable for the current packages the modules default to
          # (secretspec, searxng); the consumer supplies nothing.
          _module.args.pkgsUnstable = import inputs."nixpkgs-unstable" {
            system = pkgs.stdenv.hostPlatform.system;
          };
        };

      # NixOS Home Manager integration: options under dots.home.users.*
      nixosModules.home = {
        imports = [
          home-manager.nixosModules.home-manager
          (import ./modules/system/home)
        ];
      };

      # Home Manager module library: options under dots.home.*
      homeModules.default = import ./modules/home;

      # Reusable, overridable baseline bundles (see presets/). They are NixOS
      # modules, so compose them with `imports = [ dots.nixosModules.presetServer ];`.
      nixosModules.presetServer = import ./presets/server.nix;
    };
}
