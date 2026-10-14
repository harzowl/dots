# fzf — a command-line fuzzy finder. home-manager ships `programs.fzf`, so the
# home target uses it (with its key bindings); the system target just installs
# the package.
{
  target,
  root ? [
    "dots"
    target
  ],
}:
let
  mkSharedProgram = import ../../../../../lib/mkSharedProgram.nix;

  # Applied to every fzf invocation through `FZF_DEFAULT_OPTS`, ahead of the
  # consumer's `defaultOptions` — which appends rather than replaces, so the
  # presentation cannot be lost and the consumer's options still win.
  presentation = [
    "--style=full"
    "--pointer=❯"
    "--prompt='❯ '"
    "--marker=❯"
  ];
in
mkSharedProgram {
  inherit target root;
  optionPath = [
    "programs"
    "shell"
    "fzf"
  ];
  description = "fzf (a command-line fuzzy finder)";

  options =
    { lib, pkgs, ... }:
    {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.fzf;
        description = "The fzf package to use.";
      };

      replaceNativeSearch = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Install fzf's key bindings (Ctrl-R history, Ctrl-T files, Alt-C cd)
          in place of each shell's native ones. When `false`, fzf is installed
          and configured but its key bindings are not installed.
        '';
      };

      datedHistory = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Replace Ctrl-R with a history search that shows a human-readable
          local date per entry (read from the shell's own history) and inserts
          only the command. Takes effect only when `replaceNativeSearch` is
          also set; `false` keeps fzf's stock history widget.
        '';
      };

      defaultOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra command line options given to fzf by default (forwarded to `programs.fzf.defaultOptions`).";
      };

      defaultCommand = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The command fzf runs as its default source (forwarded to `programs.fzf.defaultCommand`).";
      };
    };

  home =
    args: cfg:
    let
      inherit (args) lib pkgs;

      # One formatter, shared by every shell: each shell's reader emits
      # `<epoch>\t<command>` and this renders the date. `@DATE@` pins GNU
      # coreutils' `date`, whose `-d @epoch` the readers rely on.
      historyDate = pkgs.writeShellScript "history-date" (
        lib.replaceStrings [ "@DATE@" ] [ "${pkgs.coreutils}/bin/date" ] (
          builtins.readFile ./history-date.sh
        )
      );

      widget =
        file:
        lib.mkAfter (lib.replaceStrings [ "@HISTORY_DATE@" ] [ "${historyDate}" ] (builtins.readFile file));

      enabled = cfg.replaceNativeSearch && cfg.datedHistory;
    in
    {
      programs = {
        fzf = {
          enable = true;
          inherit (cfg) package defaultCommand;
          defaultOptions = presentation ++ cfg.defaultOptions;
          enableFishIntegration = cfg.replaceNativeSearch;
          enableBashIntegration = cfg.replaceNativeSearch;
          enableZshIntegration = cfg.replaceNativeSearch;
        };

        fish.interactiveShellInit = lib.mkIf enabled (widget ./history.fish);
        zsh.initContent = lib.mkIf enabled (widget ./history.zsh);
      };
    };

  system = args: cfg: { environment.systemPackages = [ cfg.package ]; };
}
