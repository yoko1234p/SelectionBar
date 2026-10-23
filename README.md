# SelectionBar

[**English**](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

![SelectionBar banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.5.2--preview.1-eb91da?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**Act on selected text without losing your place.** A standalone project in the personal macOS tools collection.

## What it does

- Open spelling, text-transform, link and other configured actions near a selection.
- Save selected material to a chosen EdgeNotes folder or note when installed.
- Load supported extension packages after reviewing requested capabilities.

## Install a preview

Download the macOS ZIP from [Releases](https://github.com/yoko1234p/SelectionBar/releases/tag/v0.5.2-preview.1), unzip, and move `SelectionBar.app` to Applications. This preview uses ad-hoc signing and is **not notarized**. On first launch, use Finder’s **Open** context menu; if macOS blocks it, review **System Settings → Privacy & Security → Open Anyway**. Grant only the permissions you need. Do not install over a working copy without backing up local data.

## Build from source

```sh
cd SelectionBar
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh
```

The required local `Shared/` packages and build helpers are included. Building does not install or launch the app.
Check the [extension compatibility list](SelectionBar/docs/compatibility.md).

## Requirements and limits

macOS 14+; Xcode 27/Swift 6 and Python 3 for source builds. Selection across apps needs Accessibility permission. Extension compatibility is a maintained subset, not every PopClip extension; script extensions can execute code, so inspect them before enabling. EdgeNotes handoff is optional.

## Contribute and license

Original application code is GPL-3.0-only. Keep bundled third-party and data notices; see [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md).
