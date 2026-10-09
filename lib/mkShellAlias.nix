# Builds a config fragment that defines shell aliases in every shell dots
# supports, so an alias works regardless of the user's shell. Returned as a
# module (a function of the module args), so it drops straight into an `imports`
# list, or can be applied to `args` to obtain a plain attrset:
#
#   imports = [ (mkShellAlias { aliases = { htop = "btm -b"; }; }) ];
#
# `shells` can be extended for a shell not covered by the defaults. Aliases are
# written to `programs.<shell>.shellAliases`, which exists in both NixOS and
# home-manager; a shell that is not enabled simply ignores them.
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
