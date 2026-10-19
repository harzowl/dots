{
  target, # "system" | "home" — which projection to emit
  root ? [
    "dots"
    target
  ], # option-path prefix the program is declared under
  optionPath, # path under `root`, e.g. [ "programs" "monitoring" "bottom" ]
  description, # shown in the generated `enable` option
  options ? (_: { }),
  home, # args -> cfg -> attrset (home-manager config)
  system, # args -> cfg -> attrset (NixOS config)
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
  fullPath = root ++ optionPath;
  cfg = lib.getAttrFromPath fullPath config;
  withRoot = args // {
    inherit root;
  };
in
{
  imports = if lib.isFunction imports then imports args else imports;

  options = lib.setAttrByPath fullPath ({ enable = lib.mkEnableOption description; } // options args);

  config = lib.mkIf cfg.enable (if target == "home" then home withRoot cfg else system withRoot cfg);
}
