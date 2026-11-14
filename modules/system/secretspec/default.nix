{
  config,
  lib,
  pkgs,
  pkgsUnstable,
  ...
}:
let
  cfg = config.dots.system.secretspec;

  inherit (pkgsUnstable) secretspec;

  providerArg = lib.optionalString (
    cfg.provider != null
  ) " --provider ${lib.escapeShellArg cfg.provider}";
  scopeArg = lib.optionalString (cfg.scope != null) " --scope ${lib.escapeShellArg cfg.scope}";
  profileArg = " --profile ${lib.escapeShellArg cfg.profile}";

  envPath = "/run/secretspec/env";

  manifestData =
    if cfg.manifest == null then { } else builtins.fromTOML (builtins.readFile cfg.manifest);

  # The scope is the source of truth for what a host needs: its `[scopes.<name>]`
  # secrets land in the env file and are materialised by name too, so a service
  # can read either. A host lists nothing; an option that genuinely needs a
  # named file adds it to `secrets`.
  scopeSecrets =
    if cfg.scope == null || !(manifestData ? scopes) || !(manifestData.scopes ? ${cfg.scope}) then
      [ ]
    else
      manifestData.scopes.${cfg.scope}.secrets or [ ];

  profileSecrets =
    if
      cfg.manifest == null || !(manifestData ? profiles) || !(manifestData.profiles ? ${cfg.profile})
    then
      [ ]
    else
      builtins.attrNames (removeAttrs manifestData.profiles.${cfg.profile} [ "defaults" ]);
  materialisedSecrets = lib.unique (scopeSecrets ++ cfg.secrets);

  profileEntry =
    name:
    if
      cfg.manifest == null || !(manifestData ? profiles) || !(manifestData.profiles ? ${cfg.profile})
    then
      { }
    else
      manifestData.profiles.${cfg.profile}.${name} or { };

  requiredSecret = name: (profileEntry name).required or true;
  requiredSecrets = lib.filter requiredSecret materialisedSecrets;
  # `get` errors on a declared-but-unset optional secret; the env file already
  # carries every value that exists, so an absent optional is not a failure.
  optionalSecrets = lib.filter (name: !(requiredSecret name)) materialisedSecrets;

  asList =
    value:
    if value == null then
      [ ]
    else if lib.isList value then
      value
    else
      [ value ];

  referencesSecretspec =
    value:
    lib.any (part: part == envPath || lib.hasPrefix "/run/secretspec/" part) (
      lib.splitString ":" value
    );

  # A unit that reads the scope env file, or a named `/run/secretspec/<NAME>`
  # credential, is a consumer whether or not the host remembers to list it.
  ociConsumers =
    lib.mapAttrsToList (name: _: "${config.virtualisation.oci-containers.backend}-${name}.service")
      (
        lib.filterAttrs (
          _: container: builtins.elem envPath (container.environmentFiles or [ ])
        ) config.virtualisation.oci-containers.containers
      );

  systemdConsumers = lib.mapAttrsToList (name: _: "${name}.service") (
    lib.filterAttrs (
      name: service:
      name != "secretspec"
      && (
        builtins.elem envPath (asList (service.serviceConfig.EnvironmentFile or null))
        || lib.any referencesSecretspec (asList (service.serviceConfig.LoadCredential or null))
      )
    ) config.systemd.services
  );

  derivedConsumers = lib.unique (ociConsumers ++ systemdConsumers);
  effectiveConsumers = lib.unique (derivedConsumers ++ cfg.consumers);

  # Deriving from the merged `systemd.services` means this module cannot also add
  # an entry for every derived systemd unit — the list would feed its own key set
  # and recurse. Container units and explicit extras are known without that read,
  # so they also get `after`/`wants`; a derived systemd unit is still ordered by
  # the resolver's `before`.
  orderingConsumers = lib.unique (ociConsumers ++ cfg.consumers);

  # The manifest and the provider files the resolver reads, pinned to THIS
  # generation's store paths. Resolving against `/etc` is a race: on a switch
  # the unit restarts before `/etc/static` flips, so it would read the previous
  # generation's manifest and miss secrets the new one added. A relative
  # provider (e.g. `sops://secrets.enc.yaml`) resolves against the manifest's
  # directory, so the files are linked beside it.
  secretspecDir = pkgs.linkFarm "secretspec-runtime" (
    [
      {
        name = "secretspec.toml";
        path = cfg.manifest;
      }
    ]
    ++ lib.mapAttrsToList (name: path: { inherit name path; }) cfg.files
  );
  manifestFile = "${secretspecDir}/secretspec.toml";

  missingFromManifest = lib.filter (name: !(builtins.elem name profileSecrets)) materialisedSecrets;
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
      description = "The `[scopes]` subset to resolve; its secrets are materialised automatically.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        SOPS_AGE_KEY_FILE = "/etc/secretspec/age.key";
      };
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
      example = [ "WG_HOST_PRIVATE_KEY" ];
      description = ''
        Extra secret names to materialise individually at `/run/secretspec/<NAME>`,
        on top of the scope's secrets. Only for a unit that needs a file rather
        than the env file.
      '';
    };

    consumers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "wireguard-wg0.service" ];
      description = ''
        Extra units to order after the resolver, on top of the ones derived from
        services that read `/run/secretspec`. Only for a unit that reads a named
        file the module cannot see.
      '';
    };

    scopeSecrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = scopeSecrets;
      description = "The secrets declared by the manifest scope (read-only).";
    };

    materialisedSecrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = materialisedSecrets;
      description = "Every secret written under `/run/secretspec` — scope plus extras (read-only).";
    };

    derivedConsumers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = derivedConsumers;
      description = "Units discovered reading `/run/secretspec` (read-only).";
    };

    effectiveConsumers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = effectiveConsumers;
      description = "Derived consumers plus the explicit extras (read-only).";
    };

    files = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = {
        "secrets.enc.yaml" = ../secrets.enc.yaml;
      };
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
      {
        assertion =
          cfg.manifest == null || (manifestData ? profiles && manifestData.profiles ? ${cfg.profile});
        message = "dots.system.secretspec: profile '${cfg.profile}' is not in the manifest.";
      }
      {
        assertion = cfg.scope == null || (manifestData ? scopes && manifestData.scopes ? ${cfg.scope});
        message = "dots.system.secretspec: scope '${toString cfg.scope}' is not in the manifest.";
      }
      {
        assertion = missingFromManifest == [ ];
        message = "dots.system.secretspec: not declared in profile '${cfg.profile}': ${lib.concatStringsSep ", " missingFromManifest}";
      }
    ];

    environment.etc = {
      "secretspec/secretspec.toml".source = cfg.manifest;
    }
    // lib.mapAttrs' (name: path: lib.nameValuePair "secretspec/${name}" { source = path; }) cfg.files;

    systemd.services = lib.mkMerge [
      {
        secretspec = {
          description = "Resolve secrets with SecretSpec";
          wantedBy = [ "multi-user.target" ];
          before = effectiveConsumers;
          inherit (cfg) environment;
          restartTriggers = [ cfg.manifest ] ++ lib.attrValues cfg.files;
          path = [
            pkgs.sops
            cfg.package
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            RuntimeDirectory = "secretspec";
            RuntimeDirectoryMode = "0700";
            WorkingDirectory = secretspecDir;
          };
          script = ''
            set -eu
            ${lib.optionalString cfg.envFile ''
              ${cfg.package}/bin/secretspec export \
                --file ${manifestFile}${profileArg}${scopeArg}${providerArg} --format dotenv \
                > /run/secretspec/env
              chmod 600 /run/secretspec/env
            ''}
            ${lib.concatMapStrings (name: ''
              ${cfg.package}/bin/secretspec get \
                --file ${manifestFile}${profileArg}${providerArg} ${lib.escapeShellArg name} \
                > /run/secretspec/${lib.escapeShellArg name}
              chmod 600 /run/secretspec/${lib.escapeShellArg name}
            '') requiredSecrets}
            ${lib.concatMapStrings (name: ''
              if ${cfg.package}/bin/secretspec get \
                --file ${manifestFile}${profileArg}${providerArg} ${lib.escapeShellArg name} \
                > /run/secretspec/${lib.escapeShellArg name} 2>/dev/null; then
                chmod 600 /run/secretspec/${lib.escapeShellArg name}
              else
                rm -f /run/secretspec/${lib.escapeShellArg name}
              fi
            '') optionalSecrets}
          '';
        };
      }
      (lib.genAttrs (map (u: lib.removeSuffix ".service" u) orderingConsumers) (_: {
        after = [ "secretspec.service" ];
        wants = [ "secretspec.service" ];
      }))
    ];
  };
}
