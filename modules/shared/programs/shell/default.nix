{ target, root ? [ "dots" target ] }:
{
  imports = [
    (import ./fish { inherit target root; })
    (import ./starship { inherit target root; })
    (import ./zsh { inherit target root; })
  ];
}
