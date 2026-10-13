{ lib, ... }:
{
  imports = [
    ./domain
    ./hostname
    ./state
    ./timezone
    ./tmp
  ];

  options.dots.system.core.enable = lib.mkEnableOption "Dots core module" // {
    default = true;
  };
}
