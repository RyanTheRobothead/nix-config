" .vimrc

"Plugins
"call plug#begin()
"Plug 'itchyny/lightline.vim'
"Plug 'tpope/vim-surround'
"Plug 'airblade/vim-gitgutter'
"Plug 'ctrlpvim/ctrlp.vim'
"Plug 'ervandew/supertab'
"Plug 'tpope/vim-fugitive'
"Plug 'mg979/vim-visual-multi'
"Plug 'easymotion/vim-easymotion'
"Plug 'dominikduda/vim_current_word'
"Plug 'arcticicestudio/nord-vim'
"Plug 'preservim/nerdtree'
"Plug 'mbbill/undotree'
"Plug 'christoomey/vim-tmux-navigator'
"call plug#end()

"Lightline
set noshowmode
set laststatus=2
let g:lightline = {
      \ 'colorscheme': 'nord',
      \ }

"Colors
syntax enable
colorscheme nord
set background=dark

"GUI Options
"if has('gui')
"	set guifont=Consolas:h12:b
"	set guioptions-=T  "remove toolbar
"	set guioptions-=t  "remove tearoff options
"	set guioptions-=L  "remove left-hand scroll bar
"	set lines=40 columns=85
"	set shell=C:\WINDOWS\system32\cmd.exe
"else
	if has("termguicolor")
		set termguicolors
	end
"end

"Encoding
set encoding=utf-8


"GitGutter
set updatetime=250
let g:gitgutter_sign_added = '+'
let g:gitgutter_sign_removed = '-'
let g:gitgutter_sign_modified = 'Δ'
let g:gitgutter_sign_modified_removed = 'Δ-'

"Line numbers
set number

"Tabs
set tabstop=2
set shiftwidth=4
set scrolloff=10
set expandtab

"Indentation
set autoindent
set smartindent

"Fix backspace
"if has('gui')
"	set backspace=2
"end


"Split opening positions
set splitright
set splitbelow

"Remove error bells
set noerrorbells visualbell t_vb=
autocmd GUIEnter * set visualbell t_vb=

"Keep cursor relatively centered
set scrolloff=10

"Performance improvements
set lazyredraw
set ttyfast
set t_ut=

"Search
set incsearch
set ignorecase
set smartcase

"Read if file changes
set autoread

"Autocomplete
set wildmenu
set completeopt=menu,menuone
inoremap <expr> <CR> pumvisible() ? "\<C-y>" : "\<C-g>u\<CR>"

"Remap Leader Key
let mapleader = "," " map leader to comma
"NerdTree Quick Access
noremap <leader>n :NERDTreeToggle<CR>
inoremap <leader>n :NERDTreeToggle<CR>
vnoremap <leader>n :NERDTreeToggle<CR>
"undotree Quick Access
noremap <leader>u :UndotreeToggle<CR>
inoremap <leader>u :UndotreeToggle<CR>
vnoremap <leader>u :UndotreeToggle<CR>
"undotree configurations
let g:undotree_WindowLayout = 3
let g:undotree_ShortIndicators = 1

"Cursor and Whitespace
"set cursorline
":hi CursorLine cterm=NONE ctermbg=darkgray ctermfg=white guibg=darkgray guifg=white
":hi CursorColumn cterm=NONE ctermbg=darkgray ctermfg=white guibg=darkgray guifg=white
":noremap <Leader>l :set cursorline! <CR>
":noremap <Leader>c :set cursorcolumn! <CR>
":inoremap <Leader>l :set cursorline! <CR>
":inoremap <Leader>c :set cursorcolumn! <CR>
":vnoremap <Leader>l :set cursorline! <CR>
":vnoremap <Leader>c :set cursorcolumn! <CR>
"Whitespace
set list
set listchars=tab:\→\ ,trail:∴
set showbreak=\ ↩\
"Visual Cursor
let &t_SI = "\e[5 q"
let &t_EI = "\e[2 q"


"Quick Escape
inoremap ,, <Esc>
vnoremap ,, <Esc>
onoremap ,, <Esc>

"Fingers are already there...
nnoremap <C-j> <C-d>
nnoremap <C-k> <C-u>
vnoremap <C-j> <C-d>
vnoremap <C-k> <C-u>

"Because shift is hard to let go of okay
command! Wq wq
command! WQ wq
command! W w
command! Q q

" Persistent Undo
if has("persistent_undo")
   let target_path = expand('~/.undodir')

    " create the directory and any parent directories
    " if the location does not exist.
    if !isdirectory(target_path)
        call mkdir(target_path, "p", 0700)
    endif

    let &undodir=target_path
    set undofile
endif

" Syntax stuff
autocmd Filetype gitcommit setlocal spell textwidth=72 " Git commit messages
