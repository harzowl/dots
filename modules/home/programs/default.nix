{ root ? [ "dots" "home" ], ... }:
{
  imports = [ (import ./shell { inherit root; }) ];
}
