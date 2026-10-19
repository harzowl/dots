{
  lib,
  pkgs,
  service, # unit-name prefix, e.g. "navidrome"
  target, # dotenv file the consumer reads, e.g. "/run/navidrome-lastfm.env"
  environmentFiles, # dotenv sources the secrets are read from, in order
  mapping, # TARGET = "SOURCE" pairs, e.g. { ND_LASTFM_APIKEY = "LASTFM_API_KEY"; }
  consumer ? "${service}.service",
  provider ? "secretspec.service",
  unit ? "${service}-env",
}:
let
  script = pkgs.writeShellScript "secret-env" (builtins.readFile ./secrets-env.sh);

  args = lib.concatMapStringsSep " " lib.escapeShellArg (
    [ target ]
    ++ environmentFiles
    ++ [ "--" ]
    ++ lib.mapAttrsToList (name: source: "${name}=${source}") mapping
  );
in
{
  environmentFile = target;
  unitName = unit;
  unit = {
    description = "Map the ${service} secrets into their runtime environment names";
    after = [ provider ];
    requires = [ provider ];
    before = [ consumer ];
    partOf = [ consumer ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.coreutils
      pkgs.gnused
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${script} ${args}";
    };
  };
}
