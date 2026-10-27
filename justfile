# Nix Configuration Management
# Usage: just <command> [host]

# Default recipe that shows available commands
default:
    @just --list

# Variables for host configurations
nixos_hosts := "aegis"
hm_hosts := "luckierdodge@cerberus"

# NixOS Commands

# Build NixOS configuration without switching
build host="":
    #!/usr/bin/env bash
    if [ -z "{{ host }}" ]; then
        echo "Available NixOS hosts: {{ nixos_hosts }}"
        echo "Usage: just build <host>"
        exit 1
    fi
    echo "Building NixOS configuration for {{ host }}..."
    sudo nixos-rebuild build --flake .#{{ host }}

# Switch to NixOS configuration
switch host="": kill-discord
    #!/usr/bin/env bash
    if [ -z "{{ host }}" ]; then
        echo "Available NixOS hosts: {{ nixos_hosts }}"
        echo "Usage: just switch <host>"
        exit 1
    fi
    echo "Switching to NixOS configuration for {{ host }}..."
    sudo nixos-rebuild switch --flake .#{{ host }}

# Test NixOS configuration (switch with rollback on next boot)
test host="": kill-discord
    #!/usr/bin/env bash
    if [ -z "{{ host }}" ]; then
        echo "Available NixOS hosts: {{ nixos_hosts }}"
        echo "Usage: just test <host>"
        exit 1
    fi
    echo "Testing NixOS configuration for {{ host }}..."
    sudo nixos-rebuild test --flake .#{{ host }}

# Home Manager Commands

# Build Home Manager configuration without switching
build-hm host="":
    #!/usr/bin/env bash
    if [ -z "{{ host }}" ]; then
        echo "Available Home Manager hosts: {{ hm_hosts }}"
        echo "Usage: just build-hm <host>"
        exit 1
    fi
    echo "Building Home Manager configuration for {{ host }}..."
    home-manager build --flake .#{{ host }}

# Switch to Home Manager configuration
switch-hm host="":
    #!/usr/bin/env bash
    if [ -z "{{ host }}" ]; then
        echo "Available Home Manager hosts: {{ hm_hosts }}"
        echo "Usage: just switch-hm <host>"
        exit 1
    fi
    echo "Switching to Home Manager configuration for {{ host }}..."
    home-manager switch --flake .#{{ host }}

# Smart Commands (Auto-detect platform)

# Auto-detect current hostname and switch accordingly
auto-switch: kill-discord
    #!/usr/bin/env bash
    hostname=$(hostname)
    echo "Detected hostname: $hostname"

    case $hostname in
        aegis)
            echo "Switching NixOS configuration for $hostname..."
            sudo nixos-rebuild switch --flake .#$hostname
            ;;
        cerberus)
            echo "Switching Home Manager configuration for luckierdodge@$hostname..."
            home-manager switch --flake .#luckierdodge@$hostname
            ;;
        *)
            echo "Unknown hostname: $hostname"
            echo "Available configurations:"
            echo "  NixOS: {{ nixos_hosts }}"
            echo "  Home Manager: {{ hm_hosts }}"
            exit 1
            ;;
    esac

# Auto-detect current hostname and build accordingly
auto-build:
    #!/usr/bin/env bash
    hostname=$(hostname)
    echo "Detected hostname: $hostname"

    case $hostname in
        aegis)
            echo "Building NixOS configuration for $hostname..."
            sudo nixos-rebuild build --flake .#$hostname
            ;;
        cerberus)
            echo "Building Home Manager configuration for luckierdodge@$hostname..."
            home-manager build --flake .#luckierdodge@$hostname
            ;;
        *)
            echo "Unknown hostname: $hostname"
            echo "Available configurations:"
            echo "  NixOS: {{ nixos_hosts }}"
            echo "  Home Manager: {{ hm_hosts }}"
            exit 1
            ;;
    esac

# Flake Management

# Kill Discord, which ends up in a broken state if left running across a system switch
kill-discord:
    #!/usr/bin/env bash
    # Match on process name (not -f), so this doesn't match the recipe's own shell
    if pkill -i discord; then
        echo "Stopping Discord..."
        for _ in $(seq 20); do
            pgrep -i discord >/dev/null || exit 0
            sleep 0.5
        done
        pkill -9 -i discord || true
    fi

# Update all flake inputs
update:
    echo "Updating flake inputs..."
    nix flake update

# Update specific flake input
update-input input:
    echo "Updating flake input: {{ input }}..."
    nix flake lock --update-input {{ input }}

# Check flake configuration
check:
    echo "Checking flake configuration..."
    nix flake check

# Show flake info
info:
    echo "Flake information:"
    nix flake show

# Format all Nix files
fmt:
    echo "Formatting Nix files..."
    nix fmt

# DNS Commands (dns/dnsconfig.js, applied to deSEC)

# Validate the DNS config offline
dns-check:
    nix develop .#dns -c dnscontrol check --config dns/dnsconfig.js

# Show what dns-push would change at deSEC (needs DESEC_TOKEN; e.g. --domains <zone>)
dns-preview *args:
    @test -n "${DESEC_TOKEN:-}" || { echo "Set DESEC_TOKEN first"; exit 1; }
    nix develop .#dns -c dnscontrol preview --config dns/dnsconfig.js --creds dns/creds.json {{ args }}

# Apply the DNS config to deSEC (needs DESEC_TOKEN)
dns-push *args:
    @test -n "${DESEC_TOKEN:-}" || { echo "Set DESEC_TOKEN first"; exit 1; }
    nix develop .#dns -c dnscontrol push --config dns/dnsconfig.js --creds dns/creds.json {{ args }}

# Compare a zone's records with a nameserver (default: the zone's live NS)
dns-verify zone ns="":
    nix develop .#dns -c dns/verify.sh {{ zone }} {{ ns }}

# Development and Maintenance

# Clean up old generations (user)
clean:
    echo "Cleaning up old user generations..."
    nix-collect-garbage -d

# Clean up old generations (system) - requires sudo
clean-system:
    echo "Cleaning up old system generations..."
    sudo nix-collect-garbage -d

# Full cleanup (both user and system)
clean-all: clean clean-system

# Show current generations
generations:
    echo "System generations:"
    sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
    echo ""
    echo "User generations:"
    nix-env --list-generations

# Optimize nix store
optimize:
    echo "Optimizing Nix store..."
    nix store optimise

# Repair nix store
repair:
    echo "Repairing Nix store..."
    nix store repair

# Show all available hosts
hosts:
    echo "Available configurations:"
    echo "  NixOS hosts: {{ nixos_hosts }}"
    echo "  Home Manager hosts: {{ hm_hosts }}"
    echo ""
    echo "Commands:"
    echo "  just switch <host>        - Switch NixOS configuration"
    echo "  just switch-hm <host>     - Switch Home Manager configuration"
    echo "  just auto-switch          - Auto-detect and switch current host"
    echo "  just auto-build           - Auto-detect and build current host"
