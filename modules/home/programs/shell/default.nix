{ root ? [ "dots" "home" ], ... }:
{
  imports = [
    (import ./fish { inherit root; })
    (import ./zsh { inherit root; })
  ];
}
