# SelectionBar

Run useful actions on selected text, with spelling, extensions and quick collection into notes.

**文字與筆記系列：選字操作、拼字建議、擴充與快速收藏。** Interfaces support English, Traditional Chinese and Simplified Chinese.

## Features

- Open supported actions for the current selection.
- Use spelling, text transformations, links and configurable actions.
- Choose destination folders/notes for optional EdgeNotes handoffs.
- Install supported extension packages and review their requested capabilities.

## Build and test

Requires macOS 14+, Xcode 27/Swift 6 and Python 3. This repository includes its required shared packages; keep `Shared/` and `scripts/` beside `SelectionBar/`.

```sh
cd SelectionBar
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh
```

The app bundle is written to `SelectionBar/dist/SelectionBar.app`. Building does not install or launch it. See [SIGNING.md](SIGNING.md) for ad-hoc development and your own signing identity.

## Use and limitations

Accessibility is needed for selection and interaction with other apps. Extension compatibility is a maintained subset; see [compatibility.md](SelectionBar/docs/compatibility.md). Script extensions can execute code, so review their source and permissions before enabling them. Optional note handoffs require EdgeNotes; other actions work independently.

## Development and license

This app is under active development. Report the macOS version, reproduction steps and actual validation results with changes. Use synthetic data for file, clipboard and permission tests. Validate interface catalogs from the repository root with `python3 scripts/localization/check-catalogs.py`.

Original maintained code is **GPL-3.0-only**. Keep the separate dependency/data notices listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). See [LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md).
