Build me a native macOS screenshot app called Snapkeep, in ~/Projects/snapkeep, and install it to /Applications.

## My Mac

- macOS 27, Apple Silicon.
- Only the Command Line Tools are installed (Swift 6.4, macOS 27 SDK). There is no Xcode, so build with `swiftc` and a `build.sh` that assembles the `.app` bundle (Info.plist, icon optional) and signs it ad hoc.
- No code-signing certificate, so macOS will ask for Screen Recording permission again after each rebuild. Tell me when I need to re-grant it.
- macshot is also installed and uses `Cmd+Shift+X/F/S/T/R/H`. Don't clash with those or with Apple's `Cmd+Shift+3/4/5`.

## What I want

1. **Screenshots stay on screen.** Every capture opens a floating preview window that stays until I close it. It never closes on a timer. Several previews can be open at once, cascading so they don't cover each other.
2. **Copying is instant.** Every capture is copied to the clipboard automatically (as PNG), so I can paste straight away. The preview also has a big Copy button, and `Cmd+C` copies.
3. **I can select text directly in the image**, like Live Text in Preview, and copy just that part. Use VisionKit (`ImageAnalyzer` + `ImageAnalysisOverlayView`), not `VNRecognizeTextRequest` with `.accurate`: I tried macshot and its OCR felt slow because it uses accurate mode with automatic language detection. Start the analysis as soon as the preview opens. A "Copy Text" button copies all the text.
4. **Text-only capture.** A separate shortcut captures an area and copies only its text, then shows a small confirmation that fades out. No preview window for this one.
5. **Drawing is easier than the Mac's Markup.** The toolbar is always visible on the preview and the tools work immediately, without opening an editor: pen, highlighter, arrow, rectangle, text, 4–5 colour swatches, undo, clear. "Select text" switches back to selecting text. Copy and Save include the drawings at the image's full pixel resolution.
6. **Easy to reach.**
   - `Cmd+Shift+2`: capture an area (drag an area, or press Space to pick a window, Esc to cancel).
   - `Cmd+Shift+1`: capture an area's text.
   - A menu bar icon, no Dock icon. Menu: Capture, Capture Text, Show Last Screenshot, Open Screenshots Folder, Close All Previews, Open at Login, Quit.
7. **Screenshots are kept on disk.** Every capture is saved automatically to `~/Pictures/Screenshots/screenshot-YYYY-MM-DD_HH-mm-ss.png` (create the folder if needed). Save writes the version with drawings back to the same file. A button shows the file in Finder.

## Keys in the preview

| Key | Action |
| --- | --- |
| `Cmd+C` | Copy the selected text if any is selected, otherwise the image with drawings |
| `Cmd+S` | Save the image with drawings |
| `Cmd+Z` | Undo the last drawing |
| `Cmd+W` | Close the preview |
| `V` `P` `H` `A` `R` `T` | Select text, Pen, Highlighter, Arrow, Rectangle, Text |

## Ideas taken from Omarchy's screenshot tool (Omasnap)

- Each capture is copied and saved automatically, with no extra step.
- One shortcut for the whole flow; the picker handles both area and window.
- Screenshots live in `~/Pictures/Screenshots` with date-stamped names.
- Simple keys in the editor instead of menus.

## Suggested approach (change it if you find something better)

- Capture with `/usr/sbin/screencapture -i -x <file>`, which gives the native area/window picker.
- Global shortcuts with Carbon `RegisterEventHotKey`, which doesn't need Accessibility permission.
- Open at Login with `SMAppService.mainApp`.
- Preview window: an `NSPanel` at floating level, resizable, aspect ratio locked, max about 70% of the screen. The drawing layer sits above the Live Text overlay and lets clicks through when "Select text" is chosen.
- Store drawings in image coordinates so they stay in place when the window is resized.
- No third-party dependencies and no network access.

## Not in the first version

Scrolling capture, screen recording, uploading, blur/redaction, crop.

## When you're done

Build it, install it, launch it, and give me a short checklist to test each item above. Report anything you couldn't get working instead of hiding it.
