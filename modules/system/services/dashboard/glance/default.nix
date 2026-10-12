let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

  # Built-in Glance themes, exposed through the `theme` option below.
  builtinThemes = import ./themes.nix;

  defaults = {
    name = "glance";
    image = "glanceapp/glance:latest";
    ports = [ "8082:8080" ];
    volumes = [ "/var/lib/glance:/app/data" ];
  };
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "dashboard"
    "glance"
  ];
  description = "Glance dashboard (OCI container)";

  options =
    { lib, ... }:
    (mkDockerService.options { inherit lib defaults; })
    // {
      search = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "`search-engine`: a built-in name or a URL with `{QUERY}`.";
      };

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = ''
          Glance build to run instead of the upstream OCI image. It is packaged
          into a container image on the host, so use it for a local build.
          Takes precedence over `patches`.
        '';
      };

      patches = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = ''
          Patch files applied to the upstream Glance build (nixpkgs-unstable),
          which is then packaged into a local container image. Use it to add
          upstream features the widget lacks — e.g. the bundled
          `patches/monitor-tags.patch` (per-site `tags`) and
          `patches/monitor-description.patch` (per-site `description`). Ignored
          when `package` is set.
        '';
      };

      branding = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Glance's top-level `branding` block, e.g. `app-name` / `logo-text`.";
      };

      pages = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              name = lib.mkOption { type = lib.types.str; };
              search = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Render the global search widget on this page.";
              };
              widgets = lib.mkOption {
                type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
                default = [ ];
                description = "Raw Glance widgets appended to the page's full column.";
              };
              headWidgets = lib.mkOption {
                type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
                default = [ ];
                description = ''
                  Raw Glance widgets (an attrset each) rendered full-width above
                  the page's columns (`head-widgets`).
                '';
              };
              columns = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      size = lib.mkOption {
                        type = lib.types.str;
                        default = "full";
                        description = "Column width: `full` or `small`.";
                      };
                      widgets = lib.mkOption {
                        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
                        default = [ ];
                        description = "Raw Glance widgets (an attrset each) in this column.";
                      };
                    };
                  }
                );
                default = [ ];
                description = ''
                  Explicit page columns (`columns`). When set it replaces the
                  default single `full` column built from `search`, `services`
                  and `widgets`; a page allows 1–2 `full` columns (plus `small`).
                '';
              };
              services = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      title = lib.mkOption { type = lib.types.str; };
                      description = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = ''
                          A short line rendered under the site's title, e.g.
                          what the service is. Needs a Glance built with the
                          description patch (`patches` or `package`).
                        '';
                      };
                      url = lib.mkOption { type = lib.types.str; };
                      icon = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Glance icon (`si:name`, `di:name`, `mdi:name`, or a URL).";
                      };
                      category = lib.mkOption {
                        type = lib.types.str;
                        default = "Services";
                      };
                      checkUrl = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = ''
                          URL probed for the monitor status, when it differs from
                          `url`. Set it to the app's own health endpoint for a
                          site behind an auth gate, so the check measures the app
                          rather than the gate's unauthenticated response.
                        '';
                      };
                      tags = lib.mkOption {
                        type = lib.types.listOf (
                          lib.types.submodule {
                            options = {
                              title = lib.mkOption { type = lib.types.str; };
                              url = lib.mkOption { type = lib.types.str; };
                            };
                          }
                        );
                        default = [ ];
                        description = ''
                          Links rendered after the site's status line, e.g. how
                          the service is authorized. Needs a Glance built with
                          the tags patch (`patches` or `package`).
                        '';
                      };
                    };
                  }
                );
                default = [ ];
              };
            };
          }
        );
        default = [ ];
        description = "Dashboard pages; each lists services grouped by category.";
      };

      theme = lib.mkOption {
        default = { };
        description = "Default theme and the presets offered in the picker.";
        type = lib.types.submodule {
          options = {
            default = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Preset name (from the built-ins or `presets`) used as the default theme.";
            };

            allThemes = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Expose every built-in Glance theme in the picker.";
            };

            presets = lib.mkOption {
              type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
              default = { };
              description = "Extra presets (`name` -> theme properties), merged over the built-ins.";
            };

            disablePicker = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Hide the theme picker and force the default theme.";
            };

            customCSSFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "URL of a CSS file loaded after the bundle (`theme.custom-css-file`).";
            };
          };
        };
      };
    };

  toConfig =
    args: cfg:
    let
      lib = args.lib;
      pkgs = args.pkgs;
      pkgsUnstable = args.pkgsUnstable;

      # Applied to the upstream build; the bundled patches add per-site `tags`
      # and `description` to the monitor widget (upstream has neither).
      patchedGlance =
        if cfg.patches != [ ] then
          pkgsUnstable.glance.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ cfg.patches;
          })
        else
          null;

      glancePackage = if cfg.package != null then cfg.package else patchedGlance;

      # A local build runs from a Nix-built image loaded into the backend,
      # instead of the upstream image; `image` must match the loaded tag.
      imageName = "${cfg.name}-patched";
      imageTag = if glancePackage == null then null else glancePackage.version or "latest";
      containerImage =
        if glancePackage == null then
          null
        else
          pkgs.dockerTools.buildLayeredImage {
            name = imageName;
            tag = imageTag;
            # HTTPS monitor checks need the CA bundle.
            contents = [ pkgs.cacert ];
            config = {
              Entrypoint = [
                "${glancePackage}/bin/glance"
                "--config"
                "/app/config/glance.yml"
              ];
              WorkingDir = "/app";
              Env = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" ];
              ExposedPorts = {
                "8080/tcp" = { };
              };
            };
          };

      image = if glancePackage == null then cfg.image else "${imageName}:${imageTag}";

      link =
        s:
        {
          inherit (s) title url;
        }
        // lib.optionalAttrs (s.description != null) { inherit (s) description; }
        // lib.optionalAttrs (s.icon != null) { inherit (s) icon; }
        // lib.optionalAttrs (s.checkUrl != null) { "check-url" = s.checkUrl; }
        // lib.optionalAttrs (s.tags != [ ]) { inherit (s) tags; };

      page =
        p:
        {
          name = p.name;
          columns =
            if p.columns != [ ] then
              p.columns
            else
              [
                {
                  size = "full";
                  widgets =
                    lib.optional (cfg.search != null && p.search) {
                      type = "search";
                      "search-engine" = cfg.search;
                    }
                    ++ lib.optional (p.services != [ ]) {
                      type = "monitor";
                      title = "Services";
                      cache = "1m";
                      sites = map link p.services;
                    }
                    ++ p.widgets;
                }
              ];
        }
        // lib.optionalAttrs (p.headWidgets != [ ]) { head-widgets = p.headWidgets; };

      # Presets offered in the picker: the built-ins (if enabled) plus any extras.
      presets = (lib.optionalAttrs cfg.theme.allThemes builtinThemes) // cfg.theme.presets;

      # The default theme's colours come from the named preset (built-in or extra).
      defaultColors =
        if cfg.theme.default == null then
          { }
        else
          builtinThemes.${cfg.theme.default} or cfg.theme.presets.${cfg.theme.default} or { };

      theme =
        defaultColors
        // {
          disable-picker = cfg.theme.disablePicker;
        }
        // lib.optionalAttrs (cfg.theme.customCSSFile != null) {
          custom-css-file = cfg.theme.customCSSFile;
        }
        // lib.optionalAttrs (presets != { }) { inherit presets; };

      themeWanted =
        cfg.theme.default != null
        || cfg.theme.allThemes
        || cfg.theme.presets != { }
        || cfg.theme.disablePicker
        || cfg.theme.customCSSFile != null;

      config = (pkgs.formats.yaml { }).generate "glance.yml" (
        {
          pages = map page cfg.pages;
        }
        // lib.optionalAttrs (cfg.branding != { }) { inherit (cfg) branding; }
        // lib.optionalAttrs themeWanted { theme = theme; }
      );
    in
    lib.mkMerge [
      (mkDockerService.config {
        spec = cfg // {
          inherit image;
          volumes = cfg.volumes ++ [ "${config}:/app/config/glance.yml:ro" ];
        };
        inherit defaults;
      } args)
      (lib.mkIf (containerImage != null) {
        virtualisation.oci-containers.containers.${cfg.name}.imageFile = containerImage;
      })
    ];
}
