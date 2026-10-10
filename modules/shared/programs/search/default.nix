{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./fd { inherit target root; })
    (import ./ripgrep { inherit target root; })
  ];
}
