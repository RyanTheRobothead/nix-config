# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal Nix configuration repository managing system configurations across multiple machines using Nix flakes, NixOS, nix-darwin (macOS), and Home Manager. The repository supports hybrid Linux/macOS environments with declarative system and user configurations.

## System Update Commands

### Just Commands (Recommended)
The repository includes a `justfile` that provides convenient commands for all operations:

```bash
# List all available commands
just

# Auto-detect current system and switch configuration
just auto-switch

# Auto-detect current system and build configuration
just auto-build

# Host-specific commands
just switch <host>           # NixOS hosts: aegis, killingtime, bigbox
just switch-darwin <host>    # Darwin hosts: primemover
just switch-hm <host>        # Home Manager: luckierdodge@stark, luckierdodge@lastprism, luckierdodge@cerberus

# Build without switching
just build <host>
just build-darwin <host>
just build-hm <host>

# Flake management
just update                  # Update all flake inputs
just update-input <input>    # Update specific input
just check                   # Check flake configuration
just fmt                     # Format Nix files

# Maintenance
just clean                   # Clean user generations
just clean-system           # Clean system generations
just clean-all              # Clean both
just optimize               # Optimize Nix store
just repair                 # Repair Nix store
just generations            # Show generations
just hosts                  # Show all available hosts
```

### Direct Commands (Manual)

#### NixOS Systems
```bash
# Apply system configuration for specific hosts
sudo nixos-rebuild switch --impure --flake .#aegis
sudo nixos-rebuild switch --impure --flake .#killingtime
sudo nixos-rebuild switch --impure --flake .#bigbox

# Build without switching (test configuration)
sudo nixos-rebuild build --impure --flake .#hostname
```

#### macOS Systems (nix-darwin)
```bash
# Apply Darwin configuration
sudo darwin-rebuild switch --flake .#primemover
```

#### Home Manager (Standalone)
```bash
# Apply user environment configurations
home-manager switch --flake .#luckierdodge@stark
home-manager switch --flake .#luckierdodge@lastprism
home-manager switch --flake .#luckierdodge@cerberus
```

#### Development Commands
```bash
# Format all Nix files
nix fmt

# Check flake configuration
nix flake check

# Update flake inputs
nix flake update

# Garbage collection
nix-collect-garbage -d
sudo nix-collect-garbage -d  # NixOS systems
```

### Pre-commit Hooks
The repository includes pre-commit hooks for code quality and formatting:

```bash
# Install pre-commit hooks (run once)
pre-commit install

# Run hooks on all files
pre-commit run --all-files

# Run hooks on staged files only
pre-commit run
```

**Configured hooks:**
- **nixfmt**: Automatic Nix code formatting
- **check-yaml**: Validates YAML syntax
- **check-toml**: Validates TOML syntax
- **check-ast**: Validates Python AST
- **check-merge-conflict**: Detects merge conflict markers
- **check-added-large-files**: Prevents large files from being committed
- **mixed-line-ending**: Ensures consistent line endings
- **end-of-file-fixer**: Ensures files end with a newline
- **trailing-whitespace**: Removes trailing whitespace
- **check-json5**: Validates JSON5 syntax

The hooks will automatically run before each commit. Use `just fmt` or `nix fmt` to manually format Nix files.

## Audiobook Ripping (aegis)

`ripbook` rips multi-disc audiobook CDs into a single chaptered `.m4b` placed
directly in the Audiobookshelf library. Defined in `modules/nixos/audiobook-ripper.nix`
(script body in `modules/nixos/ripbook.sh`), enabled only on `aegis` since it is the
only host with an optical drive.

```bash
ripbook                      # start a book: prompts for metadata, then loops discs
ripbook --discs 9            # skip the per-disc prompt; just feed discs in
ripbook --list               # show books left half-ripped
ripbook --resume <slug>      # continue after a failure or Ctrl-C
ripbook --encode-only <slug> # re-encode already-ripped discs (e.g. at a new bitrate)
ripbook --help
```

Flow: reads the disc TOC, computes a MusicBrainz disc ID and offers any match as a
*suggestion*, prompts for author/title/series/year/narrator and the disc count, then
rips each disc with `cdparanoia` and ejects. When the book's disc count is known
(prompted, or `--discs N`) the next disc is picked up as soon as it is loaded, with no
prompt in between; leave the count blank to be asked after each disc instead. Once every
disc is in, it concatenates them into one AAC `.m4b` with a chapter per CD track.

Because count mode has no per-disc prompt to catch it, `ripbook` compares each newly
loaded disc against the previous one's TOC and refuses to rip the same disc twice.

Output follows the Audiobookshelf directory convention:
`<library>/<Author>/[<Series>/][Vol N - ][Year - ]<Title>[ {Narrator}]/<Title>.m4b`

Intermediate WAVs and resume state live under `services.audiobookRipper.workDir`
(~700 MB per disc); they are deleted after a successful encode unless `--keep`.
Rips are resumable at track granularity, so a failed disc only re-reads what is missing.

**Correctness guards.** The USB drive intermittently returns a corrupt table of contents
(tracks merged, others reported zero-length) and occasionally rips past a track boundary
while still exiting successfully. Both silently produce a book with misaligned chapters,
so `ripbook` defends against them:

- A TOC is only believed once two independent reads agree on a self-consistent table
  (ascending, non-overlapping starts; every track a real length).
- Every ripped track is checked byte-exact against the TOC — CD audio is exactly
  2352 bytes per sector plus a 44-byte WAV header — and re-ripped on mismatch
  (`--retries`, default 3). Resumed rips re-validate already-present files.

Occasional `retry` lines during a rip are the drive, not a bug. Persistent failures on
one track mean a dirty or damaged disc.

## Architecture Overview

### Flake Structure
- **flake.nix**: Main entry point defining all system configurations, inputs, and outputs
- **nixos/**: NixOS system configurations per machine
- **darwin/**: macOS nix-darwin configurations
- **home-manager/**: User environment configurations (can be standalone or integrated)
- **modules/**: Reusable modules for both NixOS and Home Manager
- **overlays/**: Package overlays and modifications
- **pkgs/**: Custom package definitions

### Configuration Pattern
The repository uses a modular approach where:
1. Each machine has its own configuration file (e.g., `nixos/aegis.nix`, `darwin/primemover.nix`)
2. Common base configurations are in `nixos/configuration.nix` and `home-manager/home.nix`
3. Machine-specific configurations import and extend the base configurations
4. Home Manager is integrated into system configurations for seamless user environment management

### Key Features
- **Multi-platform**: Supports both NixOS and macOS via nix-darwin
- **Secrets Management**: Uses sops-nix for encrypted secrets
- **Remote Development**: Includes VSCode Server configuration
- **Container Support**: Docker configuration with IPv6 support
- **Desktop Environment**: KDE Plasma 6 with Wayland support
- **Package Management**: Flatpak integration for GUI applications

### Machine Configurations
- **aegis**: x86_64-linux NixOS system
- **killingtime**: x86_64-linux NixOS system
- **bigbox**: x86_64-linux NixOS system
- **primemover**: aarch64-darwin macOS system
- **stark, lastprism, cerberus**: Home Manager only configurations

### Development Environment
The configuration includes development tools like:
- Git, GitHub CLI, Docker
- Programming languages (Node.js, Python, Haskell)
- Terminal tools (tmux, zsh, starship, fzf)
- Editors (Vim, VSCode)
- Claude Code CLI
- **just**: Command runner for task automation
- **pre-commit**: Git hook framework for code quality

When modifying configurations, always test with `just build <host>` or equivalent before switching to avoid breaking system state. The pre-commit hooks will automatically validate and format code before commits.
