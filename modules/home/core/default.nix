{ root ? [ "dots" "home" ] }:
{ lib, ... }:
{
  imports = [ (import ./state { inherit root; }) ];

  options = lib.setAttrByPath (root ++ [ "core" "enable" ]) (
    lib.mkEnableOption "Dots home core module" // { default = true; }
  );
}
