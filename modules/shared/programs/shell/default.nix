{
  target,
  root ? [
    "dots"
    target
  ],
}:
{
  imports = [
    (import ./atuin { inherit target root; })
    (import ./fish { inherit target root; })
    (import ./starship { inherit target root; })
    (import ./zoxide { inherit target root; })
    (import ./zsh { inherit target root; })
  ];
}
