{ target }:
{
  imports = [
    (import ./monitoring { inherit target; })
  ];
}
