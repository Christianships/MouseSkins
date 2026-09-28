# msig

Custom cursor themes for macOS: a menu bar app and CLI in one binary. It's a
small, self-built stand-in for [Mousecape](https://github.com/alexzielenski/Mousecape)
and reads Mousecape `.cape` files directly.

```sh
./build.sh            # build, install to ~/Applications, link ~/.local/bin/msig, launch
msig import ~/Downloads/Bibata.cape
msig apply Bibata
msig scale 1.5
msig reset
msig login on         # open the menu bar app at login (re-applies your theme)
```

Opening the app (or choosing Show Panel from the menu bar icon) brings up a small
floating panel in the middle of the screen, like Spotlight. Click a theme tile to apply
it. The slider sets cursor size, and the switch turns Open at login on or off. Use +
to import, or drop `.cape` files and theme folders onto the panel. Right-click a tile
to show it in Finder or trash it. Esc or clicking elsewhere closes the panel. When msig
starts at login it stays in the menu bar and doesn't show the panel.

If you use AeroSpace, float the panel so it isn't tiled:

```toml
[[on-window-detected]]
    if.app-id = 'dev.christianaguilar.msig'
    run = ['layout floating']
```

The app re-applies the saved theme at login, on wake, and when
displays change, since WindowServer drops cursor registrations in some of those cases.

## Themes

Themes live in `~/Library/Application Support/msig/themes/`, in either format:

**Mousecape `.cape`**: drop the file in, or run `msig import file.cape`.

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
- Keys are friendly names (`msig names` lists them) or full `com.apple.…` identifiers.

## How it works

It uses the same private CoreGraphics calls as Mousecape: `CGSRegisterCursorWithImages`
replaces a named system cursor for the whole login session (see `Sources/CGSPrivate.h`).
Since macOS 26, the pointer is also drawn from `ArrowS` / `IBeamS`, so Arrow and IBeam
get registered under every matching system name.

The stock Arrow and IBeam only exist inside WindowServer, and once a theme replaces
them they can't be read back until you log out. The first time msig runs in a session
that nothing has themed yet, it saves them to
`~/Library/Application Support/msig/macos-default.cape`, and `reset` restores from that
file. It skips the save while Mousecape is running, so don't run both.
