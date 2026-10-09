{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./bottom { inherit target root; })
    (import ./duf { inherit target root; })
    (import ./dust { inherit target root; })
  ];
}
