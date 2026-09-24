# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The disk image window, for dmgbuild: the app on the left, Applications on the right,
# the drawn arrow between them (background.swift), nothing else. dmgbuild writes the
# window's .DS_Store itself rather than scripting Finder, so it works on a runner with
# no one at the screen.
#
# package-release.sh passes -D app=… -D background=… -D icon=…
#
# The window size and the two icon centres have to agree with background.swift.

import os.path

app = defines["app"]  # noqa: F821 — dmgbuild supplies `defines`
app_name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

icon = defines.get("icon") or None  # noqa: F821
background = defines["background"]  # noqa: F821 — its @2x sibling is found and combined

format = "UDZO"
filesystem = "HFS+"

# 640 × 420 below a 32-point title bar. The background is taller than that on purpose —
# see background.swift for why, and for how much of it a user may actually see.
window_rect = ((200, 140), (640, 452))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (170, 222),
    "Applications": (470, 222),
}
