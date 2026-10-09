{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./sd { inherit target root; })
  ];
}
