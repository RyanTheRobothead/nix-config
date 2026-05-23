{ pkgs, lib, ... }:

let
  # === Clipboard ===

  copy = pkgs.writeShellScriptBin "copy" ''
    set -euo pipefail
    if hash pbcopy 2>/dev/null; then
      cmd='pbcopy'
    elif hash wl-copy 2>/dev/null; then
      cmd='wl-copy'
    elif hash xclip 2>/dev/null; then
      cmd='xclip -selection clipboard'
    else
      echo 'cannot find a copy program' >&2
      exit 1
    fi
    if [ $# -gt 0 ]; then
      printf '%s' "$*" | $cmd
    else
      exec perl -pe 'chomp if eof' | $cmd
    fi
  '';

  pasta = pkgs.writeShellScriptBin "pasta" ''
    set -euo pipefail
    if hash pbpaste 2>/dev/null; then
      exec pbpaste
    elif hash wl-paste 2>/dev/null; then
      exec wl-paste
    elif hash xclip 2>/dev/null; then
      exec xclip -selection clipboard -o
    else
      echo 'cannot find a paste program' >&2
      exit 1
    fi
  '';

  pastas = pkgs.writeShellScriptBin "pastas" ''
    set -euo pipefail
    trap 'exit 0' SIGINT
    last_value=""
    while true; do
      value="$(pasta)"
      if [ "$last_value" != "$value" ]; then
        echo "$value"
        last_value="$value"
      fi
      sleep 0.1
    done
  '';

  cpwd = pkgs.writeShellScriptBin "cpwd" ''
    set -euo pipefail
    pwd | tr -d '\n' | copy
  '';

  # === File / System ===

  recycle = pkgs.writeShellScriptBin "recycle" ''
    set -euo pipefail
    if [[ "$(uname)" == 'Darwin' ]]; then
      for arg in "$@"; do
        file="$(realpath "$arg")"
        /usr/bin/osascript -e "tell application \"Finder\" to delete POSIX file \"$file\"" > /dev/null
      done
    else
      trash-put "$@"
    fi
  '';

  touchsh = pkgs.writeShellScriptBin "touchsh" ''
    set -euo pipefail
    if [ ! $# -eq 1 ]; then
      echo 'touchsh takes one argument' 1>&2
      exit 1
    elif [ -e "$1" ]; then
      echo "$1 already exists" 1>&2
      exit 1
    fi
    echo '#!/usr/bin/env bash
    set -e
    set -u
    set -o pipefail

    ' > "$1"
    chmod u+x "$1"
    "$EDITOR" "$1"
  '';

  dsDestroy = pkgs.writeShellScriptBin "ds-destroy" ''
    set -euo pipefail
    find . -name .DS_Store -delete
  '';

  # === Text Processing ===

  line = pkgs.writeShellScriptBin "line" ''
    set -eu
    lineno="$1"; shift
    sed -n "''${lineno}p" -- "$@"
  '';

  scratch = pkgs.writeShellScriptBin "scratch" ''
    set -euo pipefail
    file="$(mktemp)"
    echo "Editing $file"
    exec "$EDITOR" "$file"
  '';

  markdownquote = pkgs.writeScriptBin "markdownquote" ''
    #!${pkgs.python3}/bin/python3
    import sys

    lines = [' '.join(sys.argv[1:])] if len(sys.argv) > 1 else (l.rstrip('\n') for l in sys.stdin)

    for line in lines:
        trimmed = line.strip()
        if trimmed == "":
            print(">")
        elif trimmed.startswith(">"):
            print(trimmed)
        else:
            print("> " + trimmed)
  '';

  length = pkgs.writeShellScriptBin "length" ''
    set -eu
    if [ $# -gt 0 ]; then
      printf '%s' "$*" | wc -c | awk '{print $1}'
    else
      wc -c | awk '{print $1}'
    fi
  '';

  jsonformat = pkgs.writeShellScriptBin "jsonformat" ''
    set -euo pipefail
    if hash node 2>/dev/null; then
      node -e '
      process.stdin.setEncoding("utf8")
      let jsonString = ""
      process.stdin.on("readable", () => {
        const chunk = process.stdin.read()
        if (chunk) { jsonString += chunk }
      })
      process.stdin.on("end", () => {
        console.log(
          require("util").inspect(
            JSON.parse(jsonString.trim()),
            { depth: 100, colors: true }
          )
        )
      })
      '
    elif hash jq 2>/dev/null; then
      jq
    else
      cat
    fi
  '';

  uppered = pkgs.writeShellScriptBin "uppered" ''
    set -euo pipefail
    if [ $# -gt 0 ]; then
      printf '%s\n' "$*" | tr '[:lower:]' '[:upper:]'
    else
      tr '[:lower:]' '[:upper:]'
    fi
  '';

  lowered = pkgs.writeShellScriptBin "lowered" ''
    set -euo pipefail
    if [ $# -gt 0 ]; then
      printf '%s\n' "$*" | tr '[:upper:]' '[:lower:]'
    else
      tr '[:upper:]' '[:lower:]'
    fi
  '';

  nato = pkgs.writeScriptBin "nato" ''
    #!${pkgs.ruby}/bin/ruby

    DICTIONARY = {
      "a" => "Alfa",   "b" => "Bravo",   "c" => "Charlie",
      "d" => "Delta",  "e" => "Echo",    "f" => "Foxtrot",
      "g" => "Golf",   "h" => "Hotel",   "i" => "India",
      "j" => "Juliett","k" => "Kilo",    "l" => "Lima",
      "m" => "Mike",   "n" => "November","o" => "Oscar",
      "p" => "Papa",   "q" => "Quebec",  "r" => "Romeo",
      "s" => "Sierra", "t" => "Tango",   "u" => "Uniform",
      "v" => "Victor", "w" => "Whiskey", "x" => "X-ray",
      "y" => "Yankee", "z" => "Zulu",
      "0" => "Zero",   "1" => "One",     "2" => "Two",
      "3" => "Three",  "4" => "Four",    "5" => "Five",
      "6" => "Six",    "7" => "Seven",   "8" => "Eight",
      "9" => "Nine"
    }

    input = ARGV.empty? ? $stdin.read : ARGV.join(' ')
    input.split.each do |word|
      letters = word.downcase.each_char.map do |char|
        DICTIONARY.fetch char, char
      end
      puts letters.join(' ')
    end
  '';

  uplus = pkgs.writeScriptBin "u+" ''
    #!${pkgs.python3}/bin/python3
    import argparse
    import unicodedata

    def main():
        parser = argparse.ArgumentParser()
        parser.add_argument("hex_number", type=str)
        args = parser.parse_args()
        as_int = int(args.hex_number, 16)
        as_chr = chr(as_int)
        print(as_chr)
        print(unicodedata.name(as_chr))

    if __name__ == "__main__":
        main()
  '';

  # === Date / Time ===

  iso = pkgs.writeShellScriptBin "iso" ''
    set -euo pipefail
    date '+%Y-%m-%d'
  '';

  timer = pkgs.writeShellScriptBin "timer" ''
    set -euo pipefail
    sleep "$1"
    notify 'timer complete' "$1"
  '';

  rn = pkgs.writeShellScriptBin "rn" ''
    set -eu
    date "+%l:%M%p on %A, %B %e, %Y"
    echo
    day=$(date +%e | tr -d ' ')
    cal | grep -E --colour=auto "\b''${day}\b|^"
  '';

  # === Process Management ===

  each = pkgs.writeScriptBin "each" ''
    #!${pkgs.python3}/bin/python3
    import argparse
    import re
    import shlex
    import subprocess
    import sys

    def eprint(*args):
        print(*args, file=sys.stderr)

    def parse_args():
        parser = argparse.ArgumentParser(
            description="Run each line through a command. An easier xargs.",
        )
        parser.add_argument("command", type=str, help="The command to run, such as `cat {}`.")
        result = parser.parse_args()
        if "{}" not in result.command:
            eprint("command must contain at least one {}")
            sys.exit(1)
        return result

    def delimiters_to_re(delimiters):
        escaped = map(re.escape, delimiters)
        re_str = "|".join(escaped)
        return re.compile(re_str)

    def run(command, command_arg):
        result = subprocess.run(
            command.replace("{}", shlex.quote(command_arg)),
            stdin=sys.stdin,
            stdout=sys.stdout,
            stderr=sys.stderr,
            shell=True,
            text=False,
            check=False,
        )
        if result.returncode != 0:
            sys.exit(result.returncode)

    def main():
        args = parse_args()
        delimiters = ["\n", "\r"]
        delimiters_re = delimiters_to_re(delimiters)
        all_stdin = sys.stdin.read()
        command_args = delimiters_re.split(all_stdin)
        for command_arg in command_args:
            if command_arg == "":
                continue
            run(command=args.command, command_arg=command_arg)

    if __name__ == "__main__":
        main()
  '';

  running = pkgs.writeShellScriptBin "running" ''
    set -eu
    process_list="$(ps -eo 'pid command')"
    if [[ $# != 0 ]]; then
      process_list="$(echo "$process_list" | grep -Fiw "$@")"
    fi
    echo "$process_list" |
      grep -Fv "''${BASH_SOURCE[0]}" |
      grep -Fv grep |
      GREP_COLORS='mt=00;35' grep -E --colour=auto '^\s*[[:digit:]]+'
  '';

  murder = pkgs.writeScriptBin "murder" ''
    #!${pkgs.ruby}/bin/ruby

    SIGNALS = [
      [15, 3],
      [2, 3],
      [1, 4],
      [9, 0]
    ]

    def i?(arg)
      arg.to_i != 0
    end

    def running?(pid)
      `ps -p #{pid}`.lines.length == 2
    end

    def go_ahead?
      %w(y yes yas).include? $stdin.gets.strip.downcase
    end

    def kill(pid, code)
      `kill -#{code} #{pid}`
    end

    def murder_pid(pid)
      SIGNALS.each do |signal|
        break unless running? pid
        code, wait = signal
        kill(pid, code)
        sleep 0.5
        sleep(wait) if running? pid
      end
    end

    def murder_names(name)
      loop do
        should_loop = false
        running = `ps -eo 'pid command' | grep -Fiw '#{name}' | grep -Fv grep`
        running.lines.each do |line|
          pid, fullname = line.split(nil, 2)
          next if Process.pid == pid.to_i
          print "murder #{fullname.chomp} (pid #{pid})? "
          if go_ahead?
            murder_pid(pid)
            should_loop = true
            break
          end
        end
        break unless should_loop
      end
    end

    def murder_port(arg)
      loop do
        should_loop = false
        lsofs = `lsof -i #{arg}`
        lsofs.lines.drop(1).each do |line|
          pid = line.split(nil, 3)[1]
          fullname = `ps -eo 'command' #{pid}`.lines.drop(1).first
          print "murder #{fullname.chomp} (pid #{pid})? "
          if go_ahead?
            murder_pid(pid)
            should_loop = true
            break
          end
        end
        break unless should_loop
      end
    end

    def murder(arg)
      is_pid = i?(arg)
      is_port = arg[0] == ':' && i?(arg.slice(1, arg.size))
      if is_pid
        murder_pid arg
      elsif is_port
        murder_port arg
      else
        murder_names arg
      end
    end

    if ARGV.size < 1
      puts 'usage:'
      puts 'murder 123    # kill by pid'
      puts 'murder ruby   # kill by process name'
      puts 'murder :3000  # kill by port'
      exit 1
    else
      ARGV.each { |arg| murder(arg) }
    end
  '';

  waitfor = pkgs.writeShellScriptBin "waitfor" ''
    set -euo pipefail
    pid="$1"
    if hash caffeinate 2>/dev/null; then
      caffeinate -w "$pid"
    elif hash systemd-inhibit 2>/dev/null; then
      systemd-inhibit \
        --who=waitfor \
        --why="Awaiting PID $pid" \
        tail --pid="$pid" -f /dev/null
    else
      tail --pid="$pid" -f /dev/null
    fi
  '';

  bb = pkgs.writeShellScriptBin "bb" ''
    set -eu
    if test -t 1; then
      exec 1>/dev/null
    fi
    if test -t 2; then
      exec 2>/dev/null
    fi
    "$@" &
  '';

  prettypath = pkgs.writeShellScriptBin "prettypath" ''
    set -eu
    echo "$PATH" | tr ':' '\n'
  '';

  tryna = pkgs.writeShellScriptBin "tryna" ''
    set -u
    "$@"
    while [[ ! "$?" -eq 0 ]]; do
      sleep 0.5
      "$@"
    done
  '';

  # === Notifications / System ===

  notifyScript = pkgs.writeScriptBin "notify" ''
    #!${pkgs.ruby}/bin/ruby
    require 'date'
    require 'json'

    def exec_cmd(*args)
      begin
        pid = spawn(*args)
      rescue Errno::ENOENT
        return false
      end
      Process.wait2(pid)[1].exited?
    end

    def notify(title, description)
      return if exec_cmd('notify-send', '--expire-time=5000', title, description)

      js = "
        var app = Application.currentApplication()
        app.includeStandardAdditions = true
        app.displayNotification(#{JSON.generate(description)}, {
          withTitle: #{JSON.generate(title)},
        })
      "
      return if exec_cmd('osascript', '-l', 'JavaScript', '-e', js)

      $stderr.puts("can't send notifications")
      exit(1)
    end

    title = ARGV[0] || "Notification"
    description = ARGV[1] || DateTime.now.iso8601

    notify(title, description)
  '';

  uuid = pkgs.writeScriptBin "uuid" ''
    #!${pkgs.ruby}/bin/ruby
    require 'securerandom'
    puts SecureRandom.uuid
  '';

  # === Quick References ===

  httpstatus = pkgs.writeShellScriptBin "httpstatus" ''
    set -eu
    statuses="100 Continue
    101 Switching Protocols
    102 Processing
    200 OK
    201 Created
    202 Accepted
    203 Non-Authoritative Information
    204 No Content
    205 Reset Content
    206 Partial Content
    207 Multi-Status
    208 Already Reported
    300 Multiple Choices
    301 Moved Permanently
    302 Found
    303 See Other
    304 Not Modified
    305 Use Proxy
    307 Temporary Redirect
    400 Bad Request
    401 Unauthorized
    402 Payment Required
    403 Forbidden
    404 Not Found
    405 Method Not Allowed
    406 Not Acceptable
    407 Proxy Authentication Required
    408 Request Timeout
    409 Conflict
    410 Gone
    411 Length Required
    412 Precondition Failed
    413 Request Entity Too Large
    414 Request-URI Too Large
    415 Unsupported Media Type
    416 Request Range Not Satisfiable
    417 Expectation Failed
    418 I'm a teapot
    420 Blaze it
    422 Unprocessable Entity
    423 Locked
    424 Failed Dependency
    426 Upgrade Required
    428 Precondition Required
    429 Too Many Requests
    431 Request Header Fields Too Large
    449 Retry With
    500 Internal Server Error
    501 Not Implemented
    502 Bad Gateway
    503 Service Unavailable
    504 Gateway Timeout
    505 HTTP Version Not Supported
    506 Variant Also Negotiates
    507 Insufficient Storage
    509 Bandwidth Limit Exceeded
    510 Not Extended
    511 Network Authentication Required"

    if [ $# -eq 0 ]; then
      echo "$statuses"
    else
      echo "$statuses" | grep -i --color=never "$@"
    fi
  '';

  alphabet = pkgs.writeShellScriptBin "alphabet" ''
    set -euo pipefail
    echo 'abcdefghijklmnopqrstuvwxyz'
    echo 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  '';

in
{
  home.packages = [
    copy
    pasta
    pastas
    cpwd
    recycle
    touchsh
    dsDestroy
    line
    scratch
    markdownquote
    length
    jsonformat
    uppered
    lowered
    nato
    uplus
    iso
    timer
    rn
    each
    running
    murder
    waitfor
    bb
    prettypath
    tryna
    notifyScript
    uuid
    httpstatus
    alphabet
    pkgs.ruby
    pkgs.perl
    pkgs.python3
    pkgs.jq
    pkgs.lsof
  ]
  ++ lib.optionals pkgs.stdenv.isLinux [
    pkgs.wl-clipboard
    pkgs.xclip
    pkgs.libnotify
    pkgs.trash-cli
  ];

  programs.zsh.initContent = ''
    mkcd() { mkdir -p "$1" && cd "$1" }
    tempcd() { cd "$(mktemp -d)" }
  '';
}
