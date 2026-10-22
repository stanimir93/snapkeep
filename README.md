# Snapkeep

A menu bar screenshot app for macOS. Every capture is copied to the clipboard, saved to
`~/Pictures/Screenshots`, and opened in a floating preview that stays until you close it. In the
preview you can select text straight from the image (Live Text) and draw on it.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `⇧⌘2` | Capture an area or a window |
| `⇧⌘1` | Capture an area's text and copy it. No preview and no file. |

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

## Build

Needs only the Command Line Tools (Swift 6, macOS 14 SDK or later). No Xcode, no dependencies.

```sh
./build.sh            # build/Snapkeep.app, signed ad hoc
./build.sh install    # also replace /Applications/Snapkeep.app and launch it
./build.sh test       # self-tests: file names, full-resolution export, Live Text
```

Each ad-hoc build has a new signature, so macOS forgets the Screen Recording permission.
`./build.sh install` resets the old entry, and macOS asks again on the next launch. After you
allow it, quit Snapkeep from its menu and open it again.

To check the layout without screen access:

```sh
build/Snapkeep.app/Contents/MacOS/Snapkeep --render-preview some.png out-dir/
build/Snapkeep.app/Contents/MacOS/Snapkeep --render-overlay screen.png out-dir/
```

`--render-preview` writes `window-plain.png`, `window-drawn.png` (with sample drawings) and
`export.png`, and prints how long Live Text took. `--render-overlay` draws the capture overlay over
`screen.png` while hovering a window and with a snapped selection, and writes the cropped capture.

## How it works

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
