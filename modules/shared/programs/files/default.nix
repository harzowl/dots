{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./eza { inherit target root; })
  ];
}
