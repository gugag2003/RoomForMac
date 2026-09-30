# dmgbuild settings for the RoomForMac disk image window. Read only by
# scripts/make-dmg-layout.sh, which runs dmgbuild once to make packaging/dmg/DS_Store;
# dmgbuild never runs in CI and never ships. dmgbuild executes this file and reads
# the variables it sets; `defines` holds the -D values the script passes.
#
# The numbers below are one design with scripts/make-dmg-background.swift: the
# window is the size of the background picture, and the arrow on the background is
# drawn between the two icon positions. Change them together, then regenerate.
import os.path

application = defines.get("app")  # noqa: F821 (dmgbuild provides `defines`)
if not application:
    raise ValueError("pass -D app=<path to RoomForMac.app>")
appname = os.path.basename(application.rstrip("/"))

# The throwaway image is HFS+, like the real one. The volume icon and the
# license agreement are not part of the layout.
filesystem = "HFS+"
format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}

# dmgbuild finds background@2x.png next to background.png, joins the two with
# `tiffutil -cathidpicheck` and stores the result as /.background.tiff.
background = defines.get("background", "packaging/dmg/background.png")

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 180

# The window: position on screen, then width and height in points.
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = "auto"
include_list_view_settings = "auto"
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 12
icon_size = 128

# Where the icon centres sit, in points from the window's top left corner.
icon_locations = {
    appname: (165, 120),
    "Applications": (495, 120),
}
