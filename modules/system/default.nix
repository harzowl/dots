{
  imports = [
    ./core
    ./host-type
    ./lxc
    ./nix
    ./security
    ./services
    ./users
    (import ../shared { target = "system"; })
  ];
}
