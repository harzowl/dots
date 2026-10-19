{
  optionPath, # path under `dots.`, e.g. [ "system" "services" "openssh" ]
  description, # shown in the generated `enable` option
  options ? (_: { }),
  toConfig, # args -> cfg -> attrset
  when ? (cfg: cfg.enable),
  imports ? [ ],
}:
{
  config,
  lib,
  # deadnix: skip
  pkgs,
  ...
}@args:
let
  cfg = lib.getAttrFromPath ([ "dots" ] ++ optionPath) config;
  args' = args // {
    pkgsUnstable = config._module.args.pkgsUnstable or null;
  };
in
{
  imports = if lib.isFunction imports then imports args' else imports;

  options = lib.setAttrByPath ([ "dots" ] ++ optionPath) (
    { enable = lib.mkEnableOption description; } // options args'
  );

  config = lib.mkIf (when cfg) (toConfig args' cfg);
}
