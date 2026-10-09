{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./monitoring { inherit target root; })
  ];
}
