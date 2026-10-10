{
  imports = [
    ./core
    ./host-type
    ./lxc
    ./memory
    ./networking
    ./nix
    ./security
    ./secretspec
    ./services
    ./users
    (import ../shared { target = "system"; })
  ];
}
