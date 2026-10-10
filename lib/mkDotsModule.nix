# Builds a module that:
#   - declares options at dots.<optionPath> with an auto-added `enable` switch
#   - applies `toConfig args cfg` as config while `when cfg` holds
#   - passes through `imports` (may be a function of the module args)
#
# `options`, `imports`, `toConfig` are functions of the module args
# ({ config, lib, pkgs, modulesPath, ... }) when they need them;
# `toConfig` always takes `args` first, then `cfg`.
{
  optionPath, # path under `dots.`, e.g. [ "system" "services" "openssh" ]
  description, # shown in the generated `enable` option
  options ? (_: { }),
  toConfig, # args -> cfg -> attrset
  when ? (cfg: cfg.enable),
  imports ? [ ],
}:
{ config, lib, pkgs, modulesPath, ... }@args:
let
  cfg = lib.getAttrFromPath ([ "dots" ] ++ optionPath) config;
  # `_module.args.pkgsUnstable` (nixpkgs-unstable, exposed by the dots modules)
  # isn't part of this wrapper's function arguments, so surface it for
  # `options`/`toConfig`.
  args' = args // { pkgsUnstable = config._module.args.pkgsUnstable or null; };
in
{
  imports = if lib.isFunction imports then imports args' else imports;

  options = lib.setAttrByPath ([ "dots" ] ++ optionPath) (
    { enable = lib.mkEnableOption description; } // options args'
  );

  config = lib.mkIf (when cfg) (toConfig args' cfg);
}
