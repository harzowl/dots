# Builds a module for a program that is DEFINED ONCE but surfaced under both
# `dots.system.*` and `dots.home.*`. The importer passes its `target`
# ("system" | "home"); the factory prepends it to `optionPath`, so this single
# source file both declares `dots.system.<optionPath>` and
# `dots.home.<optionPath>`, and emits the target-appropriate projection:
#
#   target = "system" -> `system args cfg` (NixOS config)
#   target = "home"   -> `home args cfg`   (home-manager config)
#
# `options`, `home`, `system` and `imports` are functions of the module args when
# they need them; `home` and `system` take `args` first, then `cfg`.
{
  target, # "system" | "home" — which projection to emit
  root ? [ "dots" target ], # option-path prefix the program is declared under
  optionPath, # path under `root`, e.g. [ "programs" "monitoring" "bottom" ]
  description, # shown in the generated `enable` option
  options ? (_: { }),
  home, # args -> cfg -> attrset (home-manager config)
  system, # args -> cfg -> attrset (NixOS config)
  imports ? [ ],
}:
{ config, lib, pkgs, modulesPath, ... }@args:
let
  fullPath = root ++ optionPath;
  cfg = lib.getAttrFromPath fullPath config;
in
{
  imports = if lib.isFunction imports then imports args else imports;

  options = lib.setAttrByPath fullPath (
    { enable = lib.mkEnableOption description; } // options args
  );

  config = lib.mkIf cfg.enable (
    if target == "home" then home args cfg else system args cfg
  );
}
