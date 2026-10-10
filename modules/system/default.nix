{
  imports = [
    ./core
    ./host-type
    ./lxc
    ./networking
    ./nix
    ./security
    ./secretspec
    ./services
    ./users
    (import ../shared { target = "system"; })
  ];
}
