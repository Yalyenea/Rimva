# Rimva

English | [简体中文](README.zh-CN.md)

A lightweight native macOS app for screenshots, backgrounds, annotations, copying, and saving.

## Install

Requires macOS 14 or later. Supports Apple silicon and Intel Macs.

1. Download the universal ZIP from [Releases](https://github.com/Yalyenea/Rimva/releases) and extract it.
2. Drag `Rimva.app` to Applications.
3. Release builds are not notarized by Apple. If macOS blocks the app, run this in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Rimva.app
   ```

4. Open Rimva and allow screen recording in System Settings → Privacy & Security → Screen Recording. You may need to grant access again after an update.

## Features

- Region, window, full-screen, and scrolling capture.
- Arrows, rectangles, text, numbered steps, solid redactions, cropping, undo, and redo.
- 12 Rosé Pine background presets: six color palettes, each with gradient and abstract variants. Custom images, image folders, and macOS wallpapers are also supported.
- Padding, separate screenshot and background corner radii, screenshot opacity, shadows, and light and dark backgrounds. Screenshot corners can remain transparent with the background disabled.
- Canvas zooming, scrolling, and panning for editing long screenshots.
- English and Simplified Chinese, system language and appearance, and Rosé Pine and Standard themes.
- Configurable global shortcuts, automatic copying and saving, and PNG export.
- Quiet launch at login and an optional menu bar icon.

The editor's background button opens a floating panel. It shares styles with Settings, so changes stay in sync. Padding sets the image margins directly.

The padding slider marks 0, 32, 64, 96, 128, and 160 px, while dragging accepts every integer value. In the editor, `⇧↑` / `⇧↓` moves between padding marks; `⇧+` / `⇧−` adjusts screenshot corners by 1 px.

## Capture

Press `⌃⌥S` to open the capture launcher, then choose a mode:

| Key | Action |
| --- | --- |
| `1` | Region capture |
| `2` | Scrolling capture |
| `3` | Window capture |
| `4` | Full-screen capture |
| `5` | Open editor |
| `6` | Open settings |

You can also click the launcher controls. The launcher stays above other windows; the editor and settings buttons are stacked at the right.

Press the capture shortcut again to cancel an active capture. Switching to another app cancels region or window selection.

Window capture highlights the window under the pointer, including system menu bar popovers. Click or press Return to capture its native corners, transparency, and shadow. The launcher and window selector preserve the current window's focus so system popovers can stay open. Press Space to switch between region and window modes.

Region and full-screen capture show a confirmation bar. Choose Capture to apply automatic output actions, or Edit to open the editor. Escape cancels; Return captures. The bar avoids the notch, menu bar, and Dock, moving inside the selection when needed.

Region capture keeps dimensions, aspect ratio, and action buttons on one row, in the order Edit → Cancel → Capture. Enter a width and height in pixels, or choose Free, 1:1, 4:3, or 16:9. Escape cancels even when a dimension field or ratio panel has focus.

Open Editor After Capture is off by default. After copying or saving, Rimva returns to the previous app and shows a confirmation with an Edit button for four seconds. Hover to keep it visible. Choose Edit to continue working on that capture.

After the confirmation disappears, `⌃⌥S` → `5` restores the latest original if the editor is empty. Existing edits are preserved. If automatic output is disabled or fails, Rimva opens the editor to retain the image.

For scrolling capture, select the scrolling content, excluding fixed sidebars and scrollbars. Scroll down in sections; Rimva stitches when scrolling settles. Choose Done to apply automatic output actions, or Open in Editor to continue editing. If matching is unreliable, you can roll back, select a new region, or keep the portion already stitched.

The first capture requires screen recording access in System Settings.

## Edit and save

Hover over a tool to see its name and shortcut. Typing in a text field does not trigger tool shortcuts.

| Shortcut | Tool | Shortcut | Tool |
| --- | --- | --- | --- |
| `V` | Select | `A` | Arrow |
| `R` | Rectangle | `T` | Text |
| `N` | Number | `M` | Redact |
| `C` | Crop | `B` | Background panel |

Copying keeps the editor open. After editing, press `⌘↵` to copy the updated image. Use `⌘S` to save or `⇧⌘S` to save as. Closing or replacing an unsaved image prompts you to save.

The stacked-image icon at the top right opens capture history. It reads PNG, JPG, and JPEG files from the top level of the configured save folder and keeps local originals of new captures. An automatically saved capture appears once. Select a thumbnail to edit it in the current window, or use its Copy button to copy the original.

Opening history, changing the save folder, or selecting Refresh reloads the files. Switching images prompts you to save unsaved edits.

Quiet Launch at Login runs Rimva in the background. If the menu bar icon is hidden, press `⌃⌥S` → `6` to open Settings.

## Development

Requires macOS 14 or later, Xcode 26 or later, and [just](https://github.com/casey/just). Rimva uses Swift Package Manager with no third-party dependencies. Its Icon Composer assets require Xcode 26 or later.

### Configure a stable signing identity

List available code signing identities:

```sh
just signing-identities
```

Write a long-term certificate's SHA-1 or full name to `.codesign-identity` in the project root. This local, single-line file is ignored by Git. An environment variable takes precedence:

```sh
export RIMVA_CODESIGN_IDENTITY='<certificate SHA-1 or full name>'
```

The certificate and its private key must be in the keychain. A missing identity stops the build. Local builds require a stable certificate; keep personal certificate details out of commits.

### Build and test

```sh
just run          # Build and launch the Debug app
just test         # Run tests in Release configuration
just build        # Build the Release app
just build-debug  # Build the Debug app
just verify       # Verify the app signature
just preview all  # Render both themes, languages, and appearances
```

UI previews are saved to `.tmp/ui-preview/`. Use `just preview-live` to open a separate sample window.

The app bundle is `.tmp/Rimva.app`, with the fixed bundle identifier `com.yfff.Rimva`. Quit any running instance before `just run`. The command launches the signed app bundle. Running `zsh scripts/build.sh` directly defaults to Debug.

Use Release builds from `just build` or `just install` for scrolling capture and performance checks.

### Install and update a local build

Use `/Applications/Rimva.app` for daily use:

```sh
just install  # Build and install Release; quit Rimva first
just launch   # Launch the installed app
```

The installer verifies signatures and rejects updates while Rimva is running. It requires the old and new signing identities to match. When intentionally migrating from an older ad hoc signature to a stable certificate, allow that identity change once:

```sh
RIMVA_ALLOW_IDENTITY_CHANGE=1 just install
just launch
```

After migration, grant screen recording access again in System Settings. Keeping the same certificate, bundle identifier, and install path should preserve access during normal updates. Follow any macOS request to confirm access again.

### GitHub releases

GitHub Actions runs tests, builds a universal macOS app, and verifies its signature and both architectures. Pushing a tag that matches the version in `Sources/Info.plist`, such as `v0.1.0`, creates a release with the ZIP and `SHA256SUMS`. Release builds use ad hoc signing and are not notarized by Apple.

Run the Release workflow manually in Actions to produce build artifacts without publishing a release.

## Project layout

- `Sources/Rimva/`: application, capture flow, editor, settings, and export.
- `Sources/RimvaCore/`: image rendering, scrolling stitcher, background models, and localization resources.
- `Tests/RimvaCoreTests/`: rendering, stitching, background, and localization tests.
- `Tests/RimvaTests/`: editor state, tool shortcuts, capture selection, and export tests.
- `PLAN.md`: early product planning.
