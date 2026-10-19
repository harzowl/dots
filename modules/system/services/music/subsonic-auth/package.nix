{
  lib,
  buildGoModule,
}:
buildGoModule {
  pname = "subsonic-auth";
  version = "0.1.0";

  src = lib.cleanSource ./.;

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
