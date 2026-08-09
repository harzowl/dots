{ lib, ... }:
{
  imports = [
    ./hostname
  ];

  options.dots.system.core.enable = lib.mkEnableOption "Dots core module";
}
