{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./bottom { inherit target root; })
  ];
}
