{
  imports = [
    ./core
    ./lxc
    ./nix
    ./services
    ./sudo
    ./users
    (import ../shared { target = "system"; })
  ];
}
