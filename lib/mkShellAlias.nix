{
  aliases, # attrset of name -> command, e.g. { htop = "btm -b"; }
  shells ? [
    "bash"
    "fish"
    "zsh"
  ],
}:
{ lib, ... }:
lib.foldl' lib.recursiveUpdate { } (
  map (shell: lib.setAttrByPath [ "programs" shell "shellAliases" ] aliases) shells
)
