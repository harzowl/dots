# Shared program sources: each module is DEFINED ONCE here and imported by BOTH
# `modules/system` and `modules/home`, each passing its own `target`. The factory
# prepends the target to the option path, so a single definition surfaces as
# `dots.system.<path>` and `dots.home.<path>`; the end-user configures whichever
# namespace they want, and each target emits its own projection.
{ target }:
{
  imports = [
    (import ./programs { inherit target; })
  ];
}
