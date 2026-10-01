# dmgbuild settings for the Weft disk image. Used by release.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=<Weft.app> -D background=<png> "Weft" <out.dmg>
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
background = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Weft.app"]

# Must match the spots drawn in make-dmg-background.swift (600x400 window).
window_rect = ((200, 120), (600, 400))
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (160, 190),
    "Applications": (440, 190),
}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
