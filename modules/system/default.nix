{
  imports = [
    ./core
    ./host-type
    ./lxc
    ./nix
    ./security
    ./secretspec
    ./services
    ./users
    (import ../shared { target = "system"; })
  ];
}
