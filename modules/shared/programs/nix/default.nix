{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./nh { inherit target root; })
  ];
}
