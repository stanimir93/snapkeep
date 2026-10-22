<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Snapkeep icon">
</p>

<h1 align="center">Snapkeep</h1>

<p align="center">
  A menu bar screenshot app for macOS that keeps your screenshots on screen, on the clipboard and on disk.
</p>

---

Every capture is copied to the clipboard, saved to `~/Pictures/Screenshots`, and opened in a
floating preview that stays until you close it. In the preview you can select text straight from
the image (Live Text) and draw on it.

## Features

- **Copied and saved automatically.** Paste right after you capture. Each file is named
  `screenshot-YYYY-MM-DD_HH-mm-ss.png`.
- **Previews that stay.** Each capture opens a floating window that never closes on a timer.
  Several can be open at once.
- **Select text in the image.** Live Text is ready as soon as the preview opens. Copy part of the
  text, or all of it with Copy Text.
- **Text-only capture.** One shortcut copies the text in an area and skips the preview.
- **Quick drawing.** Pen, highlighter, arrow, rectangle and text are always on the toolbar, no
  editor to open. Copy and Save include the drawings at full resolution.
- **Snapping selection.** The screen freezes while you select, and edges snap to windows and to
  the lines between panes.
- **Lightweight.** Native Swift with no dependencies and no network access. It lives in the menu
  bar, not the Dock.

## Requirements

- macOS 14 Sonoma or later, on Apple Silicon
- The Command Line Tools with Swift 6 (`xcode-select --install`). You don't need Xcode.

## Install

There is no download yet, so you build it from source. That takes about a minute.

```sh
git clone https://github.com/stanimir93/snapkeep.git
cd snapkeep
./build.sh install
```

This builds `Snapkeep.app`, copies it to `/Applications` and opens it. A camera icon appears in
the menu bar.

### First launch

1. When Snapkeep opens, macOS asks for **Screen Recording** permission. If you miss the prompt,
   choose **Grant Screen Recording Access…** in the menu bar menu.
2. Turn on Snapkeep in **System Settings → Privacy & Security → Screen & System Audio Recording**.
3. Quit Snapkeep from its menu and open it again.

To start Snapkeep with your Mac, choose **Open at Login** in its menu.

> [!NOTE]
> The app is signed ad hoc, so every build gets a new signature and macOS forgets the permission.
> `./build.sh install` clears the old entry. Repeat the steps above after each rebuild.

## Usage

| Shortcut | Action |
| --- | --- |
| `⇧⌘2` | Capture an area or a window |
| `⇧⌘1` | Capture the text in an area and copy it. No preview and no file. |

Both freeze the screen and dim it. Nothing is captured until you confirm:

| While selecting | Action |
| --- | --- |
| Hover, click | Highlight the window under the pointer, click to select it |
| Drag | Select an area. Edges snap to window borders and to the lines between sections of an app (sidebars, toolbars, panes). |
| Drag inside / handles | Move the selection / resize it |
| Arrow keys | Move the selection 1 pt (10 with Shift) |
| `F` | Select the whole screen |
| `Tab` | Turn snapping on or off |
| `⌥` while dragging | Drag without snapping |
| Return, double-click, **Capture** | Capture the selection |
| `Esc` | Cancel |

In a preview:

| Key | Action |
| --- | --- |
| `⌘C` | Copy the selected text if any is selected, otherwise the image with drawings |
| `⌘S` | Save the image with drawings back to its file |
| `⌘Z` | Undo the last drawing |
| `⌘W` | Close the preview |
| `⌘⌫` | Move the screenshot to the Trash and close the preview |
| `Return` | Copy the image |
| `V` `P` `H` `A` `R` `T` | Select text, Pen, Highlighter, Arrow, Rectangle, Text |
| `Esc` | Clear the text selection |

The menu bar icon also has **Show Last Screenshot**, **Open Screenshots Folder**, **Close All
Previews** and **Open at Login**.

## Development

```sh
./build.sh            # build/Snapkeep.app, signed ad hoc
./build.sh install    # also replace /Applications/Snapkeep.app and launch it
./build.sh test       # self-tests: file names, full-resolution export, Live Text
```

To check the layout without screen access:

```sh
build/Snapkeep.app/Contents/MacOS/Snapkeep --render-preview some.png out-dir/
build/Snapkeep.app/Contents/MacOS/Snapkeep --render-overlay screen.png out-dir/
```

`--render-preview` writes `window-plain.png`, `window-drawn.png` (with sample drawings) and
`export.png`, and prints how long Live Text took. `--render-overlay` draws the capture overlay over
`screen.png` while hovering a window and with a snapped selection, and writes the cropped capture.

### Project layout

| Path | What's there |
| --- | --- |
| `Sources/Snapkeep/` | The app: capture overlay, preview window, drawing canvas, Live Text, menu bar |
| `Tests/SelfTest.swift` | Self-tests run by `./build.sh test` |
| `Resources/` | `Info.plist` and the app icon |
| `scripts/` | Draws the icon and packs it into `AppIcon.icns` |
| `docs/original-brief.md` | The brief the first version was built from |

### How it works

- Capture freezes every display with ScreenCaptureKit (leaving out Snapkeep's own previews) and
  crops the selection from that frozen image, so what you see is exactly what you get.
- Window highlighting uses `CGWindowListCopyWindowInfo`. Line snapping looks for columns or rows of
  pixels that differ from their neighbours along most of the edge being dragged.
- Global shortcuts use Carbon `RegisterEventHotKey`, which needs no Accessibility permission.
- Live Text uses VisionKit's `ImageAnalyzer` and `ImageAnalysisOverlayView`. Analysis starts as
  soon as the preview opens.
- Drawings are stored in image pixels, so they stay in place when the window is resized. Copy and
  Save flatten them onto the original at full pixel resolution, keeping its colour profile and dpi.
- Open at Login uses `SMAppService.mainApp`.

## License

[MIT](LICENSE)
