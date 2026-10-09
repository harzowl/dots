{
  description = "Simplified NixOS system/home configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Current secretspec (>= 0.17 for the sops/age/systemd-credential providers);
    # the pinned 26.05 nixpkgs still ships 0.10.x.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, home-manager, ... }@inputs:
    {
      # NixOS module library: options under dots.system.*
      nixosModules.default = {
        imports = [ (import ./modules/system) ];
        # Expose nixpkgs-unstable to the module tree so `dots.system.secretspec`
        # can default to a current secretspec build.
        _module.args.nixpkgsUnstable = inputs."nixpkgs-unstable";
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
