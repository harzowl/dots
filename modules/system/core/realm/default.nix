{ lib, ... }:
{
  options.dots.system.core.realm = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      SSO realm name, shared by every service that authenticates against the
      identity provider (the gate modules build the issuer URL from it).
    '';
  };
}
