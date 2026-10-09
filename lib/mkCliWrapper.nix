# Builds a `writeShellScriptBin` wrapper that runs `<package>/bin/<name>` with the
# default flags derived from `settings`, but only adds a default whose flag the
# user did not already pass. So `dust --depth 0` overrides a configured
# `--depth 1` instead of the tool erroring on a repeated flag.
#
# Settings -> flags: keys become `--<key>` (underscores to dashes), `true` is a
# bare flag, `false`/`null` are omitted, lists are comma-joined, and other values
# are passed as the argument.
{
  lib,
  pkgs,
  name, # binary name (also the wrapper name)
  package,
  settings,
}:
let
  toTokens =
    key: value:
    let
      flag = "--" + builtins.replaceStrings [ "_" ] [ "-" ] key;
    in
    if value == true then
      [ flag ]
    else if value == false || value == null then
      [ ]
    else if lib.isList value then
      [ flag (lib.concatStringsSep "," (map toString value)) ]
    else
      [ flag (toString value) ];

  tokens = builtins.concatLists (lib.mapAttrsToList toTokens settings);
in
pkgs.writeShellScriptBin name ''
  defaults=(${lib.escapeShellArgs tokens})

  out=()
  i=0
  n=''${#defaults[@]}
  while (( i < n )); do
    tok=''${defaults[i]}
    val=""
    if (( i + 1 < n )) && [[ ''${defaults[i+1]} != --* ]]; then
      val=''${defaults[i+1]}
    fi

    present=0
    for a in "$@"; do
      if [[ $a == "$tok" || $a == "$tok"=* ]]; then
        present=1
        break
      fi
    done

    if (( present == 0 )); then
      out+=("$tok")
      [[ -n $val ]] && out+=("$val")
    fi

    if [[ -n $val ]]; then (( i += 2 )); else (( i += 1 )); fi
  done

  exec ${package}/bin/${name} "''${out[@]}" "$@"
''
