{
  imports = [
    ./core
    ./lxc
    ./programs
    ./services
    ./users
    (import ../shared { target = "system"; })
  ];
}
