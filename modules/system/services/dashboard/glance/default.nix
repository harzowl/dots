# Glance — a lightweight self-hosted dashboard. The container reads a single
# `glance.yml`; here it is generated from a list of public services (grouped by
# category), so the dashboard is a view of the fleet rather than a hand-kept
# list. Services that should stay private simply aren't passed in.
let
  mkDotsModule = import ../../../../../lib/mkDotsModule.nix;
  mkDockerService = import ../../../../../lib/mkDockerService.nix;

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
        description = "Search URL template (`{QUERY}` is substituted); defaults to DuckDuckGo.";
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
    };

  toConfig =
    args: cfg:
    let
      lib = args.lib;
      pkgs = args.pkgs;

      link =
        s:
        { inherit (s) title url; }
        // lib.optionalAttrs (s.icon != null) { inherit (s) icon; };

      group =
        p: cat:
        {
          name = cat;
          links = map link (lib.filter (s: s.category == cat) p.services);
        };

      # A predefined layout per page: a search bar, live service status tiles,
      # and category-grouped bookmarks.
      page =
        p:
        {
          name = p.name;
          columns = [
            {
              size = "full";
              widgets = [
                (
                  { type = "search"; }
                  // (
                    if cfg.search != null then
                      { "url-template" = cfg.search; }
                    else
                      { "search-engine" = "duckduckgo"; }
                  )
                )
                {
                  type = "monitor";
                  title = "Services";
                  cache = "1m";
                  sites = map link p.services;
                }
                {
                  type = "bookmarks";
                  groups = map (group p) (lib.unique (map (s: s.category) p.services));
                }
              ];
            }
          ];
        };

      config = (pkgs.formats.yaml { }).generate "glance.yml" {
        pages = map page cfg.pages;
      };
    in
    (mkDockerService.config {
      spec = cfg // {
        volumes = cfg.volumes ++ [ "${config}:/app/config/glance.yml:ro" ];
      };
      inherit defaults;
    }) args;
}
