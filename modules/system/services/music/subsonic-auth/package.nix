# The subsonic-auth binary. Statically linked so it runs in any minimal base
# image (the module bind-mounts it into `alpine`), and its unit tests run in the
# default `checkPhase`, so `nix build`/`nix flake check` exercise them.
{
  lib,
  buildGoModule,
}:
buildGoModule {
  pname = "subsonic-auth";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  # No external dependencies (standard library only): nothing to vendor.
  vendorHash = null;

  # Static (no cgo): the binary is bind-mounted into `alpine` (musl), which a
  # glibc-linked binary would not run on.
  env.CGO_ENABLED = "0";

  ldflags = [ "-s" ];

  meta = {
    description = "Reverse proxy authenticating native Subsonic clients against Keycloak personal access tokens";
    license = lib.licenses.mit;
    mainProgram = "subsonic-auth";
    platforms = lib.platforms.linux;
  };
}
