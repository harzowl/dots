# Converts a settings attrset into a command-line flag string, for wrapping CLIs
# whose options are plain flags (e.g. duf).
#
#   - key            -> --key        (underscores become dashes: only_mp -> --only-mp)
#   - true           -> --key        (bare flag)
#   - false / null   -> omitted
#   - list           -> --key v1,v2  (comma-joined)
#   - anything else  -> --key <value>
#
# Values are shell-escaped, so the result is safe to splice into a shell script.
{
  lib,
  settings,
}:
let
  flagOf =
    name: value:
    let
      flag = "--" + builtins.replaceStrings [ "_" ] [ "-" ] name;
    in
    if value == true then
      flag
    else if value == false || value == null then
      null
    else if lib.isList value then
      "${flag} ${lib.escapeShellArg (lib.concatStringsSep "," (map toString value))}"
    else
      "${flag} ${lib.escapeShellArg (toString value)}";
in
lib.concatStringsSep " " (builtins.filter (v: v != null) (lib.mapAttrsToList flagOf settings))
