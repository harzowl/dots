{
  imports = [
    ./core
    ./lxc
    ./nix
    ./services
    ./users
    (import ../shared { target = "system"; })
  ];
}
