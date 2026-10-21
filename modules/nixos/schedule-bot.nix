# schedule_bot: Discord availability polls for game nights.
#
# The service itself (DynamicUser, state in /var/lib/schedule-bot) comes from
# the schedule-bot flake's own NixOS module; this file only wires in the bot
# token. The token reaches it as an EnvironmentFile rendered by sops-nix, so it
# never lands in the Nix store. Poll state is disposable, so it isn't backed up.
{ config, inputs, ... }:
{
  imports = [ inputs.schedule-bot.nixosModules.default ];

  sops.secrets.schedule_bot_discord_token = {
    format = "yaml";
    sopsFile = ../../secrets/schedule-bot.yaml;
  };

  sops.templates."schedule-bot-env" = {
    content = ''
      DISCORD_TOKEN=${config.sops.placeholder.schedule_bot_discord_token}
    '';
    restartUnits = [ "schedule-bot.service" ];
  };

  services.schedule-bot = {
    enable = true;
    environmentFile = config.sops.templates."schedule-bot-env".path;
    # timezone defaults to time.timeZone (America/Chicago)
    # For Gatus (dockerfiles/aegis/gatus/config.yaml). Listening on all addresses
    # is fine: the firewall only lets the tailnet and Docker bridges reach it.
    healthCheck = {
      port = 8095;
      address = "0.0.0.0";
    };
  };
}
