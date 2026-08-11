let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "services"
    "openssh"
  ];
  description = "OpenSSH server";

  toConfig = _: _: {
    services.openssh.enable = true;
  };
}
