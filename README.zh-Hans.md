# SelectionBar

[English](README.md) · [繁體中文](README.zh-Hant.md) · [**简体中文**](README.zh-Hans.md)

![SelectionBar banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.5.2--preview.1-eb91da?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**选中文字，直接处理。** 个人 macOS 工具系列的独立 App。

## 主要功能

- 在选中文字附近使用拼写、文本转换、链接及自定义操作。
- 安装 EdgeNotes 后，可将选中内容发送到指定文件夹或笔记。
- 检查扩展包权限后，可加载支持的套件。

## 安装预览版

从 [Releases](https://github.com/yoko1234p/SelectionBar/releases/tag/v0.5.2-preview.1) 下载 macOS ZIP，解压后将 `SelectionBar.app` 移至“应用程序”。预览版使用临时签名，**未经 Apple 公证**。首次打开时在 Finder 右键选择“打开”；若系统阻止，请到“系统设置 → 隐私与安全性 → 仍要打开”核对。只授予所需权限，覆盖现用版本前先备份本地数据。

## 从源代码构建

```sh
cd SelectionBar
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh
```

所需的本地 `Shared/` 包和构建工具已包含在仓库；构建不会自动安装或启动应用。
请先查看[扩展兼容列表](SelectionBar/docs/compatibility.md)。

## 系统要求与限制

macOS 14 或更高版本；源代码构建需 Xcode 27／Swift 6 和 Python 3。 跨 App 选中文字需要辅助功能权限。扩展兼容仅涵盖已维护的部分，并非所有 PopClip 扩展；启用脚本前请检查。EdgeNotes 连接为可选功能。

## 参与及授权

原创应用代码按 GPL-3.0-only 发布；附带的第三方及数据许可须分别保留。详见 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。
