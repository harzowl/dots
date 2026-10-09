{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./monitoring { inherit target root; })
    (import ./search { inherit target root; })
    (import ./shell { inherit target root; })
  ];
}
