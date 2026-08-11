{ lib, ... }:
{
  imports = [
    ./domain
    ./hostname
  ];

  options.dots.system.core.enable = lib.mkEnableOption "Dots core module" // {
    default = true;
  };
}
