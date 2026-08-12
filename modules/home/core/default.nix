{ lib, ... }:
{
  imports = [
    ./state
  ];

  options.dots.home.core.enable = lib.mkEnableOption "Dots home core module" // {
    default = true;
  };
}
