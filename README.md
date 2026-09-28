# MouseSkins

Custom cursor themes for macOS: a menu bar app and CLI in one binary. It applies
cursor skins system-wide, reads `.cape` cursor theme files, and downloads new skins
from GitHub.

```sh
./build.sh            # build, install to ~/Applications, link ~/.local/bin/mouseskins, launch
mouseskins import ~/Downloads/Bibata.cape
mouseskins apply Bibata
mouseskins scale 1.5
mouseskins reset
mouseskins login on         # open the menu bar app at login (re-applies your theme)
mouseskins skins bibata     # search downloadable skins
mouseskins get Bibata       # download one into the library
```

Opening the app (or choosing Show Panel from the menu bar icon) brings up a floating
panel in the middle of the screen, like Spotlight. It has four tabs:

- **Home**: a strip of your themes (double-click to apply). The selected theme shows
  Applied/Animated badges and its cursors grouped by role (Normal Select, Text Select,
  Vertical Resize…). The toolbar has import, export as `.cape`, trash, and apply. You
  can also drop `.cape` files or theme folders onto the panel.
- **Skins**: browse and download `.cape` skins published on GitHub (Microtribute's
  mac-cursors, GinoXiscatti's collection, Bibata, Posy, Breeze and more; about 75 in
  all). Search, filter by source, **Get** or **Get & Apply**. The **+** button adds any
  GitHub repo with `.cape` files as a source, and the globe menu links to more places
  to look (GitHub topic and code searches, RW Designer plus capeify for Windows cursor packs).
  Lists are cached for a day, since anonymous GitHub API calls are limited to 60 an hour.
- **Edit**: pick a group, drag the red dot on the preview (or use the X/Y sliders or
  Center) to set the hotspot, change the frame time of an animated cursor, or replace
  the image. An edit applies to every cursor in the group. Save writes it back to the
  theme's `.cape` or folder and re-applies it if it's the current theme.
- **Settings**: apply at login, show/hide the menu bar icon, cursor scale (1–4×), and
  left-hand mode (mirrors pointer-style cursors).

Esc or clicking elsewhere closes the panel, and it reopens on the tab you left. When MouseSkins
starts at login it stays in the menu bar and doesn't show the panel.

If you use AeroSpace, float the panel so it isn't tiled:

```toml
[[on-window-detected]]
    if.app-id = 'dev.christianaguilar.mouseskins'
    run = ['layout floating']
```

The app re-applies the saved theme at login, on wake, and when
displays change, since WindowServer drops cursor registrations in some of those cases.

## Themes

Themes live in `~/Library/Application Support/MouseSkins/themes/`, in either format:

**`.cape` file**: drop the file in, or run `mouseskins import file.cape`.

**Folder**: `MyTheme/theme.json` next to PNGs:

```json
{
  "name": "My Theme",
  "author": "me",
  "cursors": {
    "arrow":    { "hotspot": [4, 2] },
    "pointing": { "image": "hand.png", "hotspot": [10, 3] },
    "wait":     { "hotspot": [16, 16], "frames": 8, "duration": 0.08 }
  }
}
```

- An image defaults to `<key>.png`. A matching `@2x.png` is used for Retina if present.
- Size is in points and defaults to the 1x image size (per frame).
- An animated cursor stacks its frames top to bottom in one image (max 24 frames).
- Keys are friendly names (`mouseskins names` lists them) or full `com.apple.…` identifiers.

## How it works

It uses private CoreGraphics calls: `CGSRegisterCursorWithImages`
replaces a named system cursor for the whole login session (see `Sources/CGSPrivate.h`).
Since macOS 26, the pointer is also drawn from `ArrowS` / `IBeamS`, so Arrow and IBeam
get registered under every matching system name.

The stock Arrow and IBeam only exist inside WindowServer, and once a theme replaces
them they can't be read back until you log out. The first time MouseSkins runs in a session
that nothing has themed yet, it saves them to
`~/Library/Application Support/MouseSkins/macos-default.cape`, and `reset` restores from that
file. It skips the save while another cursor app is running, so don't run two at once.
