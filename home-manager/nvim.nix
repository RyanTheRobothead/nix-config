{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;

    plugins = with pkgs.vimPlugins; [
      lightline-vim
      vim-gitgutter
      nord-nvim
      nvim-tree-lua
      undotree
      vim-tmux-navigator
    ];

    extraConfig = ''
      " Lightline
      set noshowmode
      set laststatus=2
      let g:lightline = {
            \ 'colorscheme': 'nord',
            \ }

      " Colors
      syntax enable
      colorscheme nord
      set background=dark

      " True color support
      if has("termguicolors")
        set termguicolors
      endif

      " Encoding
      set encoding=utf-8

      " GitGutter
      set updatetime=250
      let g:gitgutter_sign_added = '+'
      let g:gitgutter_sign_removed = '-'
      let g:gitgutter_sign_modified = 'Δ'
      let g:gitgutter_sign_modified_removed = 'Δ-'

      " Line numbers
      set number

      " Tabs
      set tabstop=2
      set shiftwidth=4

      " Indentation
      set autoindent
      set smartindent

      " Split opening positions
      set splitright
      set splitbelow

      " Remove error bells
      set noerrorbells visualbell t_vb=

      " Keep cursor relatively centered
      set scrolloff=10

      " Performance improvements
      set lazyredraw

      " Search
      set incsearch
      set ignorecase
      set smartcase

      " Read if file changes
      set autoread

      " Autocomplete
      set wildmenu
      set completeopt=menu,menuone
      inoremap <expr> <CR> pumvisible() ? "\<C-y>" : "\<C-g>u\<CR>"

      " Remap Leader Key
      let mapleader = ","

      " nvim-tree Quick Access
      noremap <leader>n :NvimTreeToggle<CR>
      inoremap <leader>n <Esc>:NvimTreeToggle<CR>
      vnoremap <leader>n :NvimTreeToggle<CR>

      " undotree Quick Access
      noremap <leader>u :UndotreeToggle<CR>
      inoremap <leader>u <Esc>:UndotreeToggle<CR>
      vnoremap <leader>u :UndotreeToggle<CR>

      " undotree configurations
      let g:undotree_WindowLayout = 3
      let g:undotree_ShortIndicators = 1

      " Whitespace
      set list
      set listchars=tab:→\ ,trail:∴
      set showbreak=\ ↩\

      " Quick Escape
      inoremap ,, <Esc>
      vnoremap ,, <Esc>
      onoremap ,, <Esc>

      " Fingers are already there...
      nnoremap <C-j> <C-d>
      nnoremap <C-k> <C-u>
      vnoremap <C-j> <C-d>
      vnoremap <C-k> <C-u>

      " Because shift is hard to let go of okay
      command! Wq wq
      command! WQ wq
      command! W w
      command! Q q

      " Persistent Undo
      if has("persistent_undo")
         let target_path = expand('~/.undodir')
          if !isdirectory(target_path)
              call mkdir(target_path, "p", 0700)
          endif
          let &undodir=target_path
          set undofile
      endif

      " Syntax stuff
      autocmd Filetype gitcommit setlocal spell textwidth=72
    '';

    extraLuaConfig = ''
      -- nvim-tree setup (replacement for NERDTree)
      require("nvim-tree").setup({
        view = {
          width = 30,
        },
        renderer = {
          icons = {
            show = {
              file = false,
              folder = false,
              folder_arrow = true,
              git = true,
            },
          },
        },
      })
    '';
  };
}
