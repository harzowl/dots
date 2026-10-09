{
  imports = [
    ./core
    ./lxc
    ./nix
    ./programs
    ./services
    ./users
    (import ../shared { target = "system"; })
  ];
}
