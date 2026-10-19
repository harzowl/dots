{
  target,
  ...
}:
{
  imports = if target == "system" then [ ./beets ] else [ ];
}
