{
  name,
  system ? { },
  home ? { },
}:
_: {
  dots.system.users.${name} = system;
  dots.home.users.${name} = home;
}
