import os

# dmgbuild settings file. This is read by the `dmgbuild` CLI (or Python API).
# It uses environment variables exported by the shell wrapper script:
#  - DMG_APP_PATH: path to the .app bundle to put in the DMG
#  - DMG_VOLUME_NAME: volume name to display when the DMG is mounted
#  - DMG_BACKGROUND: absolute path to the background image to use

APP_PATH = os.environ.get('DMG_APP_PATH')
VOLUME_NAME = os.environ.get('DMG_VOLUME_NAME', 'GravityNotch')
BACKGROUND = os.environ.get('DMG_BACKGROUND', '')
BADGE_ICON = os.environ.get('DMG_BADGE_ICON', '')

# If DMG_BACKGROUND not provided, default to the hiDPI TIFF in .background.
if not BACKGROUND:
    BACKGROUND = os.path.join(os.path.dirname(__file__), '.background', 'background.tiff')

# Basic DMG metadata
volume_name = VOLUME_NAME
format = 'UDZO'
compression_level = 9

# Files and symlinks to include in the DMG
files = [APP_PATH] if APP_PATH else []
symlinks = {'Applications': '/Applications'}

# Background image path (dmgbuild will copy this file into the DMG's .background)
background = BACKGROUND

# Window rectangle: ((left, top), (width, height))
window_rect = ((200, 200), (660, 400))

# Icon size (points)
icon_size = 128
text_size = 12

# Icon locations: map filename (or bundle name) -> (x, y) in window coords
app_basename = os.path.basename(APP_PATH) if APP_PATH else 'GravityNotch.app'
icon_locations = {
    app_basename: (175, 185),
    'Applications': (485, 185),
}

# Finder window appearance: no toolbar, no sidebar, no status/path/tab bars
show_statusbar = False
show_tabview = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# Optionally set a custom icon for the DMG volume (leave empty to skip)
if BADGE_ICON and os.path.exists(BADGE_ICON):
    badge_icon = BADGE_ICON
