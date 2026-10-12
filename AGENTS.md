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
