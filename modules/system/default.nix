{
  imports = [
    ./core
    ./lxc
    ./nix
    ./security
    ./services
    ./users
    (import ../shared { target = "system"; })
  ];
}
