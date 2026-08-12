{ lib, ... }:
{
  imports = [
    ./domain
    ./hostname
    ./state
  ];

  options.dots.system.core.enable = lib.mkEnableOption "Dots core module" // {
    default = true;
  };
}
