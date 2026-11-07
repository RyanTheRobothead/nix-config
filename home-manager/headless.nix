# local.headless: the server profile of core.nix. It keeps out anything that
# pulls in a GUI toolkit (GTK vim, clipboard helpers, fastfetch's GPU and
# image libraries), which would only widen an internet-facing host's closure.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.local.headless = lib.mkEnableOption "the server profile, with no GUI toolkits";

  config = lib.mkMerge [
    (lib.mkIf (!config.local.headless) {
      home.packages = [ pkgs.fastfetch ];
    })
    (lib.mkIf config.local.headless {
      # Same plugins and vimrc, without GTK
      programs.vim.packageConfigurable = pkgs.vim-full.override { guiSupport = "none"; };
      # Neovim's wrapper otherwise adds wl-clipboard
      programs.neovim.waylandSupport = false;
    })
  ];
}
