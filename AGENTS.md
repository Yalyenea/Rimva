# Rimva

Native macOS screenshot app using Swift, AppKit, and Swift Package Manager.

## UI

- Keep it lightweight, compact, flat, and restrained. Use cool, muted theme colors consistently across windows and controls.
- Hide the editor title bar and status bar. Use an icon-only toolbar with tooltips, tight spacing, and precise alignment.
- Group related settings; avoid sparse pages and unnecessary sidebars. Keep windows resizable and preserve their size when switching content.
- Give previews ample space and preserve image proportions. Prefer direct selection for a few options and sliders for continuous values.
- Keep labels and buttons short. Remove redundant descriptions; keep control sizes stable during interaction.
- Support English and Chinese; follow system language and appearance by default.
- Preview major UI changes before implementation, using actual features and settings.

## Development

- Read [README.md](README.md); use [Justfile](Justfile): `just run` for development, `just build` for Release, `just test` for core tests.
- Develop with `.tmp/Rimva.app`; install to `/Applications/Rimva.app` with `just install`, then `just launch`. Quit existing instances before running or installing; never use `open -n` or `swift run`.
- Keep code and file structure simple. Avoid silent fallbacks and unnecessary compatibility layers. Run checks proportional to risk.
- Store temporary files and builds in `.tmp/`, discarded files in `.tmp/trash/`.

## Verification and delivery

- Inspect UI changes in the built app: alignment, resizing, themes, both languages, and interaction states. Open it for user testing.
- Use Release builds for scrolling capture and performance checks. Check alignment, duplicates, missing content, fixed elements, blank sections, small final scrolls, and upward scrolling.
- Verify signing identity and screen recording access after updates through the app and an actual capture. Report what was tested.
- Use a new branch for features and fixes. Commit, merge, and push only when requested; update relevant docs before committing.
- Before publishing, check for secrets and personal data. Exclude local signing configuration, certificate details, personal paths, test screenshots, logs, and builds; use a GitHub privacy email.
