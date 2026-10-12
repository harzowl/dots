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

      # `nix fmt` (and the pre-commit hook) format Nix with nixfmt.
      formatter.x86_64-linux = inputs.nixpkgs.legacyPackages.x86_64-linux.nixfmt;

      # The music.subsonic-auth shim binary. Its `go test` suite runs in
      # buildGoModule's checkPhase, so `nix build .#subsonic-auth` (and the
      # `checks` entry below, which `nix flake check` evaluates) is the test gate.
      packages.x86_64-linux.subsonic-auth =
        inputs.nixpkgs.legacyPackages.x86_64-linux.callPackage
          ./modules/system/services/music/subsonic-auth/package.nix
          { };

      checks.x86_64-linux.subsonic-auth = self.packages.x86_64-linux.subsonic-auth;

      # Credential scan over the whole flake source (test files and fixtures
      # included): gitleaks' format rules plus scripts/secret-scan.py's
      # high-entropy token-shape check. Fails the build on any credential-shaped
      # string, so a real secret can never be committed here or in a consumer
      # that runs this check.
      checks.x86_64-linux.secret-scan =
        let
          pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        in
        pkgs.runCommand "secret-scan"
          {
            nativeBuildInputs = [
              pkgs.gitleaks
              pkgs.python3
            ];
          }
          ''
            export HOME="$TMPDIR"
            gitleaks detect --no-git --source ${self} --redact --exit-code 1 --no-banner
            python3 ${self}/scripts/secret-scan.py ${self}
            touch "$out"
          '';
    };
}
