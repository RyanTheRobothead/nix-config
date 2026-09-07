# Declarative GNOME settings via dconf.
#
# These are re-applied on every home-manager activation, so changing any of
# these keys in the Settings GUI will be reverted on the next rebuild. Change
# them here instead.
#
# To discover the key behind a GUI toggle:
#   dconf watch /
{ lib, ... }:
{
  dconf.settings = {
    # Settings > Power > Screen Blank: 15 minutes
    "org/gnome/desktop/session" = {
      idle-delay = lib.hm.gvariant.mkUint32 900;
    };

    "org/gnome/desktop/interface" = {
      # Settings > Multitasking > Hot Corner: off
      enable-hot-corners = false;
    };

    # Show minimize and maximize buttons in the titlebar alongside close
    "org/gnome/desktop/wm/preferences" = {
      button-layout = "appmenu:minimize,maximize,close";
    };
  };
}
