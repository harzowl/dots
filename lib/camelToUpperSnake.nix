# camelCase -> UPPER_SNAKE, treating a run of capitals as one word, so
# `stationTTL` -> `STATION_TTL` (not `STATION_T_T_L`) and `APIClient` ->
# `API_CLIENT`.
{ lib }:
key:
let
  chars = lib.stringToCharacters key;
  count = lib.length chars;
  at = i: lib.elemAt chars i;
  isUpper = c: builtins.match "[A-Z]" c != null;
  isLower = c: builtins.match "[a-z]" c != null;
  isDigit = c: builtins.match "[0-9]" c != null;
  boundary =
    i:
    i > 0
    && isUpper (at i)
    && (
      isLower (at (i - 1))
      || isDigit (at (i - 1))
      || (isUpper (at (i - 1)) && i + 1 < count && isLower (at (i + 1)))
    );
  pieces = lib.imap0 (i: c: (if boundary i then "_" else "") + c) chars;
in
lib.toUpper (lib.concatStrings pieces)
