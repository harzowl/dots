{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./ripgrep { inherit target root; })
  ];
}
