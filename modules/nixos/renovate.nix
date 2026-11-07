# Self-hosted Renovate.
#
# Opens PRs against the repos listed below on a daily timer. Pinned by
# flake.lock and sandboxed by the upstream module (DynamicUser, no home
# directory, no capabilities); the GitHub token reaches it only as a systemd
# credential. Per-repo rules live in each repo's renovate.json. When Forgejo
# lands, repoint `platform` and `endpoint` at it; nothing else changes.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Renovate exits 0 even when it can't update a branch: a failed lock
  # update or a refused PR shows only as "Errored" on the repo's Dependency
  # Dashboard, which nobody reads. After every run, post each newly errored
  # branch to Discord, again weekly while it stays errored, and say so if
  # the run itself failed.
  renovateCheck = pkgs.writeShellApplication {
    name = "renovate-check";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      systemd
    ];
    text = builtins.readFile ./renovate-check.sh;
  };
in
{
  sops.secrets.renovate_github_token = {
    format = "yaml";
    sopsFile = ../../secrets/renovate.yaml;
  };
  # Classic PAT with only read:packages; ghcr.io rejects fine-grained tokens,
  # and anonymous tag listings of large repos (Immich) get throttled
  sops.secrets.renovate_ghcr_token = {
    format = "yaml";
    sopsFile = ../../secrets/renovate.yaml;
  };

  services.renovate = {
    enable = true;
    # Daily; each repo's schedule decides when update PRs actually open. Off
    # the hour: ghcr.io throttled Immich's anonymous auth probe at 04:00:19
    # on alternate days, when every other Renovate runs too
    schedule = "*-*-* 04:17:00";
    credentials.RENOVATE_TOKEN = config.sops.secrets.renovate_github_token.path;
    # Picked up by detectHostRulesFromEnv as a docker host rule for ghcr.io
    credentials.DOCKER_GHCR_IO_PASSWORD = config.sops.secrets.renovate_ghcr_token.path;
    environment.DOCKER_GHCR_IO_USERNAME = "RyanTheRobothead";
    # The journal gets info; the last two runs' debug logs stay here, as
    # lookup failures only say why at debug
    environment.LOG_FILE = "/var/log/renovate/debug.log";
    environment.LOG_FILE_LEVEL = "debug";
    # The nix manager shells out to nix to update flake.lock; it talks to the
    # daemon over its socket, which the sandbox allows
    runtimePackages = [ config.nix.package ];
    settings = {
      platform = "github";
      repositories = [
        "RyanTheRobothead/dockerfiles"
        "RyanTheRobothead/nix-config"
      ];
      # Repos carry their own renovate.json; never open onboarding PRs
      onboarding = false;
      requireConfig = "required";
      detectHostRulesFromEnv = true;
    };
  };

  systemd.services.renovate.unitConfig = {
    OnSuccess = [ "renovate-check.service" ];
    OnFailure = [ "renovate-check.service" ];
  };

  systemd.services.renovate-check = {
    description = "Report Renovate failures and errored branches";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = {
      RENOVATE_REPOS = lib.concatStringsSep " " config.services.renovate.settings.repositories;
      # @ryantherobothead, as in vulnscan
      PING_USER = "250137556899987468";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe renovateCheck;
      DynamicUser = true;
      StateDirectory = "renovate-check";
      LoadCredential = [
        "github-token:${config.sops.secrets.renovate_github_token.path}"
        "discord-webhook:${config.sops.secrets.vulnscan_discord_webhook.path}"
      ];
      CapabilityBoundingSet = [ "" ];
      NoNewPrivileges = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        # systemctl, for the run's result
        "AF_UNIX"
      ];
      SystemCallArchitectures = "native";
    };
  };

  systemd.services.renovate.serviceConfig = {
    LogsDirectory = "renovate";
    # Renovate appends to LOG_FILE; keep one previous run
    ExecStartPre = "-${pkgs.coreutils}/bin/mv -f /var/log/renovate/debug.log /var/log/renovate/debug.log.1";
  };
}
