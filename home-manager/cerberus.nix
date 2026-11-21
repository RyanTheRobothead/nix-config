{
  inputs,
  outputs,
  lib,
  config,
  pkgs,
  ...
}:
{
  home.packages = with pkgs; [
    # Add your packages here
    graphviz
  ];
  home.homeDirectory = "/home/luckierdodge";
  # Set by home.nix before the workstation profile was dropped
  home.stateVersion = "23.05";
  local.headless = true;
}
