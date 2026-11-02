# dots

Declarative NixOS and Home Manager modules for a small self-hosted fleet.
`dots` provides the shared system, user, service and program configuration;
consuming repositories supply the host-specific values.

## What it provides

- NixOS modules under `dots.system.*`
- Home Manager modules under `dots.home.*`
- Reusable service modules for Docker containers, authentication, media,
  downloads, networking and secrets
- Shared CLI program configuration
- A hardened server preset

## Requirements

- Nix with flakes enabled
- NixOS 26.05 or a compatible `nixpkgs`
- Home Manager for the home modules

## Usage

Add the flake input:

```nix
{
  inputs.dots.url = "github:harzowl/dots";

  outputs = { self, nixpkgs, dots, ... }: {
    nixosConfigurations.machine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        dots.nixosModules.default
        dots.nixosModules.home
        ./configuration.nix
      ];
    };
  };
}
```

Then configure the host and its users:

```nix
{
  dots = {
    system = {
      core = {
        hostname = "machine";
        domain = "example.test";
      };

      users.alice = {
        role = "admin";
        keys = [ "ssh-ed25519 AAAA..." ];
      };
    };

    home = {
      users.alice = {
        programs.text.delta.enable = true;
      };
    };
  };
}
```

`dots.nixosModules.home` wires Home Manager and the `nvf` module into every
user declared in `dots.home.users`.

## Repository layout

```text
modules/system/   NixOS modules and services
modules/home/     Home Manager core modules
modules/shared/   Shared program modules used by both targets
lib/              Module, Docker and shell helpers
presets/          Ready-made module combinations
tests/            Shell-based module checks
scripts/          Lint, personal-data and secret-scan helpers
```

## Development

```sh
nix flake check
nix fmt
```

`nix flake check` runs the repository checks, including the module tests, lints
and secret scan. The pre-commit hook uses the same lint and personal-data
rules:

```sh
git config core.hooksPath .githooks
```

Commits follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):
for example `feat(system): add a service` or `fix(networking): correct a route`.

## Secrets

Secrets are supplied at runtime through secret files, systemd credentials or
environment files. They must never be placed in module `settings` or committed
to the repository. See [`AGENTS.md`](./AGENTS.md) for the full repository
rules.

## License

MIT
