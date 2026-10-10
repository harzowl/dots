{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./files { inherit target root; })
    (import ./monitoring { inherit target root; })
    (import ./nix { inherit target root; })
    (import ./search { inherit target root; })
    (import ./shell { inherit target root; })
    (import ./text { inherit target root; })
  ];
}
