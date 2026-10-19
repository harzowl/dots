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
      [
        flag
        (lib.concatStringsSep "," (map toString value))
      ]
    else
      [
        flag
        (toString value)
      ];

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
