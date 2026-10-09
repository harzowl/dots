{ root ? [ "dots" "home" ], ... }:
{
  imports = [
    (import ./core { inherit root; })
    (import ./programs { inherit root; })
    (import ../shared {
      target = "home";
      inherit root;
    })
  ];
}
