{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./bat { inherit target root; })
    (import ./sd { inherit target root; })
  ];
}
