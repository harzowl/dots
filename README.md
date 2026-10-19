# ❄️ dots

Simplified NixOS system/home configuration — a module library (`dots.system.*`)
that consuming hosts compose.

## `/tmp` on tmpfs

`dots.system.core.tmp` mounts `/tmp` as a RAM-backed tmpfs that is empty on
every boot. It is a single toggle with an overridable size:

```nix
{ dots.system.core.tmp = { useTmpfs = true; reservedSize = "512M"; }; }
```

`useTmpfs` defaults to `false` and `reservedSize` to `"256M"` — a safe default
that fits even a small (≤1 GB) host. When `useTmpfs` is on, the module sets
`boot.tmp.useTmpfs`, `boot.tmp.tmpfsSize` (the NixOS option keeps its kernel
name) and `boot.tmp.cleanOnBoot` (the latter two `lib.mkDefault`, so a host can
still pin them). Despite the name, `reservedSize` is a cap, not a reservation —
tmpfs pages live in RAM on demand — so raise it only on a host with the memory
headroom to back it (`"50%"` follows systemd's percentage of RAM).

## Adding a service — security checklist

Work through this before a new service or vhost is called done. It encodes the
invariants in [`AGENTS.md`](./AGENTS.md); the modules below implement them, so
most of the list is "use the default and don't opt out".

1. **No credential in a URL or query string.** Anything the service hands a
   client to replay must be **derived and short-lived** — an HMAC-signed,
   expiry-bearing token minted after the real credential is validated — never
   the account credential itself. Return the derived token; never the
   credential it was minted from. (See `services.music.subsonic-auth`.)
2. **No long-lived secret in a log.** The Caddy module injects a
   credential-redacting `log` filter — `t`, `s`, `p`, `token`, `code`, `state`
   and the `Referer` header — into **every** vhost by default
   (`accessLogFormat`; opt out with `= null`, never a per-service opt-in).
   Suppress a component's own request log if it can print a query string (e.g.
   oauth2-proxy's `/oauth2/callback`, via `oauth2ProxyExcludeLoggingPaths`).
   Verify the generated config, not just that it evaluates.
3. **Pass secrets in, never bake them in.** Secrets arrive through
   `environmentFiles`, systemd credentials or a mounted file — never as a module
   `settings` value (that lands in the Nix store) and never in generated config.
   Never log a secret. A service that needs renamed variables declares
   `secretEnv`; `mkSecretEnv` writes the runtime dotenv, so the consuming unit
   never spells the remap out. A change to an `environmentFiles` file **restarts
   the consuming container**: `mkDockerService` wires a `systemd.path` watcher
   per file, since a Nix-config change alone only restarts on unit-definition
   changes (verified by rewriting the file and watching the container restart).
4. **Derive, don't persist.** Prefer stateless verification (signature + expiry)
   over a server-side session store, so a restart cannot resurrect or strand a
   credential; bound revocation with a short TTL and key rotation.
5. **Fixtures are dummies.** Any test, mock or example value is obviously fake
   (`dummy-DO-NOT-USE-…`). Never paste a value from a log, a config, the live
   system, an env var, or a real account. Identity is data too: never commit
   your own username, email, domain or host name — use a `dummy-DO-NOT-USE-…`
   identity and a reserved example address (`.invalid`, `.test`, `example.com`).
6. **Run the scanner.** `nix flake check` runs `checks.*.secret-scan`
   (`gitleaks` plus `scripts/secret-scan.py`), which fails on a credential-shaped
   string in any tracked file, test fixtures included — and on any address that
   is not on a reserved example domain. The pre-commit hook also runs
   `scripts/personal-data-guard.sh`, which derives the committer's own email,
   domain, FQDN and login and fails if they appear in a staged file.
7. **Guard the default.** Add a test or an assertion that the safe behaviour is
   the default (e.g. every generated vhost has redaction, `/auth/login` never
   returns the raw credential), so a future change cannot regress it silently.

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
— `type(scope): description`, with the **type required** (`feat`, `fix`, `docs`,
`style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`), the scope
optional, and `!` (or a `BREAKING CHANGE:` footer) marking a break. Keep the
description imperative and lowercase, with no trailing period. The
[`.githooks/commit-msg`](./.githooks/commit-msg) hook enforces the header once
`core.hooksPath` points at `.githooks`.
