# Notes for agents working in this repo

`dots` is the module library (`dots.system.*`). Host files in consuming repos stay
thin and put reusable behaviour here.

## Security invariants (binding)

- **Never write a real secret into code, tests, fixtures, or examples.** Test and
  mock values must be obviously fake (`dummy-DO-NOT-USE-…`); never copy a value
  from a log, a config, the live system, or an env var. A secret committed in a
  test is a leak, and a secret pasted into the working tree is one `git add` away
  from being one.
- **Never put a long-lived credential in a URL or query string.** Anything a
  module hands a client to replay (e.g. a Subsonic `t`) must be **derived and
  short-lived** — an HMAC-signed, expiry-bearing token — never the account
  credential. Return the derived token, never the credential it was minted from.
- **Redact credentials from every access log.** A vhost that can see `t`/`s`/`p`/
  `token`/`code`/`state` in a query must strip them from its log; make this the
  module **default** so new services inherit it (opt-out, never opt-in).
- **Pass secrets in, never bake them in.** Secrets arrive via `environmentFiles`
  / systemd credentials — never as a module `settings` value (that lands in the
  Nix store) and never in generated config. Never log a secret.

## Commit messages (binding)

Every commit follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>(<optional-scope>): <description>
```

- **A type is required**; the scope is optional. Use one of `feat`, `fix`,
  `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- Keep the description imperative and lowercase, with no trailing period.
- A breaking change carries `!` after the type/scope (or a `BREAKING CHANGE:`
  footer in the body).
- `.githooks/commit-msg` (enabled with `git config core.hooksPath .githooks`)
  rejects a non-conforming header; merge, revert and `fixup!`/`squash!` messages
  are exempt.

## Module authors (binding)

- **Every reusable behaviour is an option, not a copy-paste.** A consuming host
  should express it declaratively; if a host has to hand-write `systemd.*`,
  `networking.*`, a `script` or any per-host glue to make a service work, the
  module is missing an option. Add it here — a service dependency (`dependsOn`),
  a network, an env var, ordering — so the next host gets it for free.
- **Never embed a config blob in a `.nix` file.** A Caddyfile fragment, a script
  or any other config goes in its own file beside the module (`keycloak/reconcile.sh`,
  a `caddy/*.conf`) and is referenced, never inlined as a `''…''` string.
  Host-derived values are `@PLACEHOLDER@`s the caller substitutes.
- **A module defaults only what is inherent to the service.** Its name, image
  and port — nothing environmental. Timezone, PUID/PGID, umask, host paths
  (`/var/lib/…`), secrets and the network/firewall shape are the **consumer's**
  and must not appear as a default in `dots`. A literal that already has a home
  elsewhere (the timezone lives in the consuming repo's preset) is *referenced*,
  never retyped here.
- **A module owns its service's shared configuration.** A setting every consumer
  would otherwise restate — an issuer URL, a provider, a scope, common env — is
  a **module default**, so a consumer names only what is its own. If two hosts
  repeat the same block, the module is missing a default.
- **Never hardcode what an option can carry.** A literal IP, port, hostname or
  path in a module (or a host file) is a bug: it cannot be changed in one place
  and it will drift. Give it an option (or reference the one that already
  exists) and derive from it. Duplication is the thing to hunt, not just
  addresses.
- **Nest a repeated attribute path; never write it per line.** Two adjacent
  assignments that share a prefix belong in one attrset —
  `networking.firewall = { allowedTCPPorts = …; allowedUDPPorts = …; };` — not
  two dotted lines. `semgrep/nix-nest-repeated-attribute-path.yaml` (run by the
  pre-commit hook) fails the commit that does otherwise.
- **A comment must earn its place.** Comment only a non-obvious *why* — a
  security invariant, a footgun, a workaround — never what the code already
  says, never structure, never the next line. If deleting it loses no
  information, delete it.
- **Shape service modules with `mkDockerService.options` / `.config`**, so their
  options *are* the container's: a new `mkDockerService` option then reaches
  every container service (feishin, navidrome, the gates, the shim, …) with no
  per-module change.
- Adding a service or a vhost inherits the security invariants above; do not opt
  out, and do not re-implement them in the host.
