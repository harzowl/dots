{
  target,
  root ? [
    "dots"
    target
  ],
}:
{
  imports = [
    (import ./neovim { inherit target root; })
  ];
}
