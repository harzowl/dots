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
              services = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      title = lib.mkOption { type = lib.types.str; };
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
          };
        };
      };
    };

  toConfig =
    args: cfg:
    let
      lib = args.lib;
      pkgs = args.pkgs;

      link =
        s:
        {
          inherit (s) title url;
        }
        // lib.optionalAttrs (s.icon != null) { inherit (s) icon; }
        // lib.optionalAttrs (s.checkUrl != null) { "check-url" = s.checkUrl; };

      page = p: {
        name = p.name;
        columns = [
          {
            size = "full";
            widgets =
              lib.optional (cfg.search != null) {
                type = "search";
                "search-engine" = cfg.search;
              }
              ++ [
                {
                  type = "monitor";
                  title = "Services";
                  cache = "1m";
                  sites = map link p.services;
                }
              ];
          }
        ];
      };

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
        // lib.optionalAttrs (presets != { }) { inherit presets; };

      themeWanted =
        cfg.theme.default != null
        || cfg.theme.allThemes
        || cfg.theme.presets != { }
        || cfg.theme.disablePicker;

      config = (pkgs.formats.yaml { }).generate "glance.yml" (
        {
          pages = map page cfg.pages;
        }
        // lib.optionalAttrs (cfg.branding != { }) { inherit (cfg) branding; }
        // lib.optionalAttrs themeWanted { theme = theme; }
      );
    in
    (mkDockerService.config {
      spec = cfg // {
        volumes = cfg.volumes ++ [ "${config}:/app/config/glance.yml:ro" ];
      };
      inherit defaults;
    })
      args;
}
