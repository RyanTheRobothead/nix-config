# The shell environment every host gets: zsh, tmux, vim and neovim, git,
# the dotfiles and small CLI tools. Workstations add their toolchains and
# agents on top in home.nix; servers (SleeperService) import only this.
{ pkgs, ... }:
{
  imports = [
    ./headless.nix
    ./nvim.nix
    ./scripts.nix
  ];

  home = {
    username = "luckierdodge";
    sessionVariables = {
      EDITOR = "nvim";
    };
  };

  home.packages = with pkgs; [
    htop
    duf
    tmux
    fzf
    starship
    tree
    dust
    just
    zellij
    emojify
    git-lfs
  ];

  # Enable home-manager and git
  programs.home-manager.enable = true;
  programs.git.enable = true;
  programs.git.lfs.enable = true;

  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  # Nicely reload system units when changing configs
  #systemd.user.startServices = "sd-switch";

  # Dotfiles
  home.file = {
    ".aliases".source = ./dotfiles/.aliases;
    ".bashrc".source = ./dotfiles/.bashrc;
    ".dircolors".source = ./dotfiles/.dircolors;
    ".gitconfig".source = ./dotfiles/.gitconfig;
    ".gitmessage".source = ./dotfiles/.gitmessage;
    ".profile".source = ./dotfiles/.profile;
    ".tmux".source = ./dotfiles/.tmux;
    #".tmux.conf".source = ./dotfiles/.tmux.conf;
    ".config/starship/starship.toml".source = ./dotfiles/starship.toml;
    ".config/nix/nix.conf".source = ./dotfiles/nix.conf;
    ".ssh/.keep".source = builtins.toFile "keep" "";
    ".zsh/completions/_sk".source = ./dotfiles/completions/_sk;
  };

  # Starship
  programs.starship.enable = true;

  # ZSH
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    enableCompletion = true;
    autocd = true;
    history = {
      extended = true;
      ignoreDups = true;
      ignorePatterns = [
        "exit"
        "ls"
        "ll"
        "la"
        "c"
        "clear"
        "cd"
      ];
      share = true;
      save = 20000;
      size = 20000;
    };
    initContent = (builtins.readFile ./dotfiles/.zshrc) + ''
      fpath+=("$HOME/.zsh/completions")
    '';
    oh-my-zsh = {
      enable = true;
      theme = "robbyrussel";
      plugins = [
        "git"
        "python"
        "vscode"
        "colored-man-pages"
        "command-not-found"
        "docker-compose"
        "docker"
        "pip"
        "ssh-agent"
        "sudo"
        "tmux"
        "starship"
        "fzf"
        "direnv"
      ];
    };
    zplug = {
      enable = false;
      plugins = [
        #{ name = "lukechilds/zsh-nvm"; }
      ];
    };
  };

  # VIM
  programs.vim = {
    enable = true;
    plugins = with pkgs.vimPlugins; [
      lightline-vim
      #  vim-surround
      vim-gitgutter
      #  ctrlp-vim
      #  supertab
      #  vim-fugitive
      #  vim-visual-multi
      #  vim-easymotion
      #  vim_current_word
      nord-vim
      nerdtree
      undotree
      vim-tmux-navigator
    ];
    extraConfig = (builtins.readFile ./dotfiles/.vimrc);
  };

  # TMUX
  programs.tmux = {
    enable = true;
    #shell = "\${pkgs.zsh}/bin/zsh";
    shortcut = "a";
    newSession = true;
    mouse = true;
    keyMode = "vi";
    historyLimit = 20000;
    escapeTime = 50;
    clock24 = true;
    aggressiveResize = true;
    plugins = with pkgs.tmuxPlugins; [
      battery
      prefix-highlight
      online-status
      sidebar
      copycat
      open
      sysstat
      vim-tmux-navigator
    ];
    extraConfig = (builtins.readFile ./dotfiles/.tmux.conf);
  };

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };
}
