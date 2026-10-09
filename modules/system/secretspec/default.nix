# Materialise a SecretSpec profile into runtime files at boot.
#
# SecretSpec (https://secretspec.dev) is a provider-agnostic secrets resolver.
# This module runs it as a systemd oneshot which resolves the declared secrets
# from their configured provider — e.g. a SOPS-encrypted file — and writes them
# under a RAM-backed runtime directory, where services consume them as
# `environmentFile`s or systemd credentials. Plaintext never enters the Nix
# store or persistent storage.
#
#   dots.system.secretspec = {
#     enable = true;
#     manifest = ./secretspec.toml;
#     provider = "sops://secrets.enc.yaml";
#     environment.SOPS_AGE_KEY_FILE = "/etc/secretspec/age.key";
#     secrets = [ "STALWART_ADMIN_SECRET" ];
#     consumers = [ "stalwart.service" ];
#   };
#
# Resolved values appear at `/run/secretspec/env` (the whole profile) and
# `/run/secretspec/<NAME>` for each entry in `secrets`.
{
  config,
  lib,
  pkgs,
  nixpkgsUnstable ? null,
  ...
}:
let
  cfg = config.dots.system.secretspec;

  secretspec =
    if nixpkgsUnstable != null then
      nixpkgsUnstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.secretspec
    else
      pkgs.secretspec;

  providerArg = lib.optionalString (cfg.provider != null) " --provider ${lib.escapeShellArg cfg.provider}";
  scopeArg = lib.optionalString (cfg.scope != null) " --scope ${lib.escapeShellArg cfg.scope}";
  manifest = lib.escapeShellArg (toString cfg.manifest);
  profileArg = " --profile ${lib.escapeShellArg cfg.profile}";
in
{
  options.dots.system.secretspec = {
    enable = lib.mkEnableOption "SecretSpec secret materialisation";

    package = lib.mkOption {
      type = lib.types.package;
      default = secretspec;
      defaultText = lib.literalExpression "secretspec (nixpkgs-unstable)";
      description = "The secretspec CLI to use.";
    };

    manifest = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to the `secretspec.toml` manifest (required).";
    };

    profile = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "SecretSpec profile to resolve.";
    };

    provider = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "sops://secrets.enc.yaml";
      description = "Provider override; defaults to the manifest's own provider selection.";
    };

    scope = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "searxng";
      description = "Resolve only this `[scopes]` subset into the env file, so a service does not receive unrelated secrets.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { SOPS_AGE_KEY_FILE = "/etc/secretspec/age.key"; };
      description = "Environment for the resolver, e.g. `SOPS_AGE_KEY_FILE`.";
    };

    envFile = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Also export the whole profile as a dotenv file at `/run/secretspec/env`.";
    };

    secrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "STALWART_ADMIN_SECRET" ];
      description = "Secret names to materialise individually at `/run/secretspec/<NAME>`.";
    };

    consumers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "stalwart.service" ];
      description = "Units ordered after the resolver so they can read the materialised secrets.";
    };

    files = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = { "secrets.enc.yaml" = ../secrets.enc.yaml; };
      description = ''
        Extra files deployed under `/etc/secretspec/<name>` for the provider to
        read, e.g. the SOPS-encrypted file referenced by the manifest. Deployed
        through `environment.etc` so they are tracked into the system closure.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.manifest != null;
        message = "dots.system.secretspec.manifest must be set.";
      }
    ];

    # The manifest (and any provider files) go under /etc/secretspec so they
    # enter the system closure: a bare store path referenced only from the
    # unit's script is not tracked and would be missing on the target.
    environment.etc =
      { "secretspec/secretspec.toml".source = cfg.manifest; }
      // lib.mapAttrs' (name: path: lib.nameValuePair "secretspec/${name}" { source = path; }) cfg.files;

    systemd.services = lib.mkMerge [
      {
        secretspec = {
          description = "Resolve secrets with SecretSpec";
      wantedBy = [ "multi-user.target" ];
      before = cfg.consumers;
      environment = cfg.environment;
      # `sops` is shelled out to by the sops provider; secretspec must be on PATH.
      path = [ pkgs.sops cfg.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "secretspec";
        RuntimeDirectoryMode = "0700";
      };
      script = ''
        set -eu
        ${lib.optionalString cfg.envFile ''
          ${cfg.package}/bin/secretspec export \
            --file /etc/secretspec/secretspec.toml${profileArg}${scopeArg}${providerArg} --format dotenv \
            > /run/secretspec/env
          chmod 600 /run/secretspec/env
        ''}
        ${lib.concatMapStrings (name: ''
          ${cfg.package}/bin/secretspec get \
            --file /etc/secretspec/secretspec.toml${profileArg}${providerArg} ${lib.escapeShellArg name} \
            > /run/secretspec/${lib.escapeShellArg name}
          chmod 600 /run/secretspec/${lib.escapeShellArg name}
        '') cfg.secrets}
      '';
        };
      }
      (lib.genAttrs (map (u: lib.removeSuffix ".service" u) cfg.consumers) (_: {
        after = [ "secretspec.service" ];
        wants = [ "secretspec.service" ];
      }))
    ];
  };
}
