# zram: an in-memory compressed swap device, sized as a fraction of RAM. It is a
# fast OOM cushion — pages are compressed in RAM instead of paged to disk — so it
# should sit at a higher priority than any disk swap and be treated as a safety
# net, not usable memory.
#
#   dots.system.memory.zram = {
#     enable = true;
#     memoryPercent = 50;    # ≤ this percentage of RAM, compressed
#     algorithm = "zstd";
#   };
let
  mkDotsModule = import ../../../../lib/mkDotsModule.nix;
in
mkDotsModule {
  optionPath = [
    "system"
    "memory"
    "zram"
  ];
  description = "zram compressed swap";

  options =
    { lib, ... }:
    {
      memoryPercent = lib.mkOption {
        type = lib.types.ints.positive;
        default = 50;
        description = "Maximum amount of memory that may be stored in the zram swap, as a percentage of RAM (compressed).";
      };

      priority = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = "Swap priority — keep it above any disk swap so zram is filled first.";
      };

      algorithm = lib.mkOption {
        type = lib.types.either (
          lib.types.enum [
            "842"
            "lzo"
            "lzo-rle"
            "lz4"
            "lz4hc"
            "zstd"
          ]
        ) lib.types.str;
        default = "zstd";
        description = "Compression algorithm (`zstd` = good ratio and fast).";
      };

      writebackDevice = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Write incompressible pages to this device instead of holding them in RAM.";
      };
    };

  toConfig =
    _: cfg:
    {
      zramSwap = {
        enable = true;
        inherit (cfg) memoryPercent priority algorithm writebackDevice;
      };
    };
}
