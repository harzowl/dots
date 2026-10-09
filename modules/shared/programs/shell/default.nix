{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./starship { inherit target root; })
  ];
}
