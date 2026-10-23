# SelectionBar

[English](README.md) · [**繁體中文**](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

![SelectionBar banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.5.2--preview.1-eb91da?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**選好文字，直接處理。** 個人 macOS 工具系列的獨立 App。

## 主要功能

- 在選字附近使用拼字、文字轉換、連結及自訂操作。
- 安裝 EdgeNotes 後，可將選取內容送往指定資料夾或筆記。
- 檢查擴充套件權限後，可載入支援的套件。

## 安裝預覽版

從 [Releases](https://github.com/yoko1234p/SelectionBar/releases/tag/v0.5.2-preview.1) 下載 macOS ZIP，解壓後將 `SelectionBar.app` 移至「應用程式」。預覽版使用臨時簽署，**未經 Apple 公證**。首次開啟時在 Finder 按右鍵選「開啟」；若系統阻擋，請到「系統設定 → 私隱與保安 → 仍要開啟」核對。只授予所需權限，覆蓋現用版本前先備份本機資料。

## 從原始碼建置

```sh
cd SelectionBar
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh
```

所需的本機 `Shared/` 套件和建置工具已包含在 repo；建置不會自動安裝或啟動 App。
請先查看[擴充兼容清單](SelectionBar/docs/compatibility.md)。

## 系統要求與限制

macOS 14 或以上；原始碼建置需 Xcode 27／Swift 6 和 Python 3。 跨 App 選字需要輔助使用權限。擴充兼容只涵蓋已維護的部分，並非所有 PopClip 擴充；啟用腳本前請檢查。EdgeNotes 連接為可選功能。

## 參與及授權

原創 App 程式碼以 GPL-3.0-only 發布；附帶的第三方及資料授權須各自保留。詳見 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。
