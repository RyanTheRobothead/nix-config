# .bashrc

# If not running interactively, don't do anything
case $- in
	*i*) ;;
	*) return;;
esac

# Source our universal aliases
source $HOME/.aliases

# History options
shopt -s histappend
export HISTIGNORE="exit:ls:ll:la:c:clear:cd"
HISTTIMEFORMAT='%F %T '
HISTCONTROL=ignoreboth
HISTSIZE=10000
HISTFILESIZE=20000

# Check window size after each command
shopt -s checkwinsize

# Enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
	if [ -f /usr/share/bash-completion/bash_completion ]; then
		. /usr/share/bash-completion/bash_completion
	elif [ -f /etc/bash_completion ]; then
		. /etc/bash_completion
	fi
fi

# Set PATH to include private bin if it exists, after the system ones so
# nothing user-writable can stand in for sudo, git and friends
if [ -d "$HOME/bin" ] ; then
	PATH="$PATH:$HOME/bin"
fi

# Set TERM to support colors
TERM='xterm-256color'

if [ -f "$HOME/.dircolors" ]; then
	eval `dircolors -b "$HOME/.dircolors"`
fi


# Prompt Colors
Red='\[\e[01;31m\]'
Green='\[\e[01;32m\]'
Yellow='\[\e[01;33m\]'
Blue='\[\e[01;34m\]'
Purple='\[\e[01;35m\]'
Cyan='\[\e[01;36m\]'
White='\[\e[01;37m\]'
Reset='\[\e[00m\]'

# Fetches the git branch
git_branch()
{
	git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/'
}

# Add prompt info for git branch
git_prompt()
{
	if [ -n "$(git_branch)" ]; then
		# If we're in a git branch,
		# print branch name with color indicating whether or not it's clean
		if [[ $(git st) == "" ]]; then
			echo "$White.$Green$(git_branch)"
		else
			echo "$White.$Yellow$(git_branch)"
		fi
	else
		echo ""
	fi
}

# Print different colored prompt terminator depending on exit code of previous command
exit_prompt()
{
	if [[ $? -eq 0 ]]; then
		echo "$Green♪"
	else
		echo "$Red♪"
	fi
}

# Add prompt info for docker container
docker_prompt()
{
	if [[ -z "$CONTAINER_NAME" ]]; then
		echo "$Blue\h"
	else
		echo "$Purple$CONTAINER_NAME$White→${Red}\h$White"
	fi
}

# Command run to display prompt
set_prompt ()
{
	exit_code="$(exit_prompt)"
	PS1="$Cyan\u$White@$(docker_prompt)$White($Cyan\w$(git_prompt)$White)$exit_code $Reset"
}

export PROMPT_DIRTRIM=2
PROMPT_COMMAND='history -a ; history -n ; set_prompt'

# If this is an xterm set title to user@host:dir
case "$TERM" in
	xterm*|rxvt*)
		PS1="\[\e]0;\u@\h: \w\a\]$PS1"
		;;
	*)
		;;
esac

# Automatically start SSH agent if this is machine has an SSH key setup
if [ -f "$HOME/.ssh/id_ed25519" ]; then
	if [ -x "$(command -v ssh-agent)" ]; then
		# Check if the ssh-agent is already running
		if [[ "$(ps -u $USER | grep ssh-agent | wc -l)" -lt "1" ]]; then
			# Start the ssh-agent and redirect the environment variables into a file
			mkdir -p $HOME/.ssh
			touch $HOME/.ssh/ssh-agent
			ssh-agent -s -t 86400 > $HOME/.ssh/ssh-agent
			# Load the environment variables from the file
			. $HOME/.ssh/ssh-agent > /dev/null
			# Add the default key to the ssh-agent
			ssh-add $HOME/.ssh/id_ed25519
		else
			if [ -f $HOME/.ssh/ssh-gent ]; then
				. $HOME/.ssh/ssh-agent > /dev/null
			fi
		fi
	fi
fi

for file in \
	$HOME/.bash_environment \
	/.container_environment \
	$HOME/.nix-profile/etc/profile.d/nix.sh \
	$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh
do
	[[ -f "$file" ]] && source $file
done

# Machine Specific Settings and Environment Config
case "$HOSTNAME" in
	Normandy)
		export PATH="$PATH:~/.cargo/bin/cargo:~/julia/bin"
		#export DISPLAY=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2; exit;}'):0.0
		export START_TMUX=FALSE

		export NVM_DIR="$HOME/.nvm"
		[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
		[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

		if [ ! -n "$CONTAINER_NAME" ]; then
			if [ -n "`service docker status | grep not`" ]; then
				sudo /usr/sbin/service docker start
			fi
		fi

		export PATH="$PATH:/home/luckierdodge/.local/bin"
		export PYTHONPATH="/home/luckierdodge/.local/bin"

		export NVM_DIR="$HOME/.nvm"
		[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
		[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
		;;
	*)
		:
		;;
esac

# Automatically launches TMUX on machines where we've set
# the START_TMUX flag in .bash_environment
if [ "$START_TMUX" = "TRUE" ] && [ "$TMUX" = "" ]; then
	#  Launch tmux if not already launched and create a new session
	tmux has-session -t Home 2>/dev/null
	if [ $? != 0 ]; then
		homemux
	else
		homemuxnew
	fi
fi
