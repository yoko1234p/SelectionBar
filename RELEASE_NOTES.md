# 0.5.6 — source update (not yet a downloadable release)

- **English:** Keep selection monitoring working after BarPilot opens and closes while the same app remains active. The monitor preserves input events, restores a system-disabled tap and keeps toolbar buttons clickable. Verified with 169 tests and a real BarPilot interaction.
- **繁體中文：** 修正同一 App 保持前台時，BarPilot 展開再收起後選字工具列失效。保留原有輸入事件、恢復系統停用的監聽，工具列按鈕仍可操作。通過 169 項測試及 BarPilot 實機操作。
- **简体中文：** 修复同一 App 保持前台时，BarPilot 展开再收起后选字工具栏失效。保留原有输入事件、恢复系统停用的监听，工具栏按钮仍可操作。通过 169 项测试及 BarPilot 实机操作。

# 0.5.5 — source update (not yet a downloadable release)

- **English:** Fix invisible selection toolbars after hidden/login launches without stealing focus or opening settings. Ignore unrelated background-app exits and restore selection monitoring after wake. Verified with 168 unit tests and native hidden-launch checks.
- **繁體中文：** 修正隱藏／登入啟動後工具列無法顯示，保留來源 App 焦點，不彈出設定。避免無關背景程式結束打斷選字，並補上喚醒後的監聽恢復。通過 168 項單元測試及原生隱藏啟動檢查。
- **简体中文：** 修复隐藏／登录启动后工具栏无法显示，保留来源 App 焦点，不弹出设置。避免无关后台程序退出打断选字，并补上唤醒后的监听恢复。通过 168 项单元测试及原生隐藏启动检查。

# SelectionBar v0.5.2-preview.1

## English — First public preview

Act on selected text without losing your place.

- Open spelling, text-transform, link and other configured actions near a selection.
- Save selected material to a chosen EdgeNotes folder or note when installed.
- Load supported extension packages after reviewing requested capabilities.

**Install a preview:** Download the macOS ZIP from [Releases](https://github.com/yoko1234p/SelectionBar/releases/tag/v0.5.2-preview.1), unzip, and move `SelectionBar.app` to Applications. This preview uses ad-hoc signing and is **not notarized**. On first launch, use Finder’s **Open** context menu; if macOS blocks it, review **System Settings → Privacy & Security → Open Anyway**. Grant only the permissions you need. Do not install over a working copy without backing up local data.

**Requirements and limits:** Selection across apps needs Accessibility permission. Extension compatibility is a maintained subset, not every PopClip extension; script extensions can execute code, so inspect them before enabling. EdgeNotes handoff is optional.

Before installing, check the asset SHA-256 values in `SHA256SUMS`. The source ZIP and GitHub's generated source archives are provided with this release.

## 繁體中文 — 首個公開預覽版

選好文字，直接處理。

- 在選字附近使用拼字、文字轉換、連結及自訂操作。
- 安裝 EdgeNotes 後，可將選取內容送往指定資料夾或筆記。
- 檢查擴充套件權限後，可載入支援的套件。

**安裝預覽版:** 從 [Releases](https://github.com/yoko1234p/SelectionBar/releases/tag/v0.5.2-preview.1) 下載 macOS ZIP，解壓後將 `SelectionBar.app` 移至「應用程式」。預覽版使用臨時簽署，**未經 Apple 公證**。首次開啟時在 Finder 按右鍵選「開啟」；若系統阻擋，請到「系統設定 → 私隱與保安 → 仍要開啟」核對。只授予所需權限，覆蓋現用版本前先備份本機資料。

**系統要求與限制:** 跨 App 選字需要輔助使用權限。擴充兼容只涵蓋已維護的部分，並非所有 PopClip 擴充；啟用腳本前請檢查。EdgeNotes 連接為可選功能。

安裝前請對照 `SHA256SUMS` 的 SHA-256 值。本版同時提供原始碼 ZIP 和 GitHub 自動產生的原始碼封存檔。

## 简体中文 — 首个公开预览版

选中文字，直接处理。

- 在选中文字附近使用拼写、文本转换、链接及自定义操作。
- 安装 EdgeNotes 后，可将选中内容发送到指定文件夹或笔记。
- 检查扩展包权限后，可加载支持的套件。

**安装预览版:** 从 [Releases](https://github.com/yoko1234p/SelectionBar/releases/tag/v0.5.2-preview.1) 下载 macOS ZIP，解压后将 `SelectionBar.app` 移至“应用程序”。预览版使用临时签名，**未经 Apple 公证**。首次打开时在 Finder 右键选择“打开”；若系统阻止，请到“系统设置 → 隐私与安全性 → 仍要打开”核对。只授予所需权限，覆盖现用版本前先备份本地数据。

**系统要求与限制:** 跨 App 选中文字需要辅助功能权限。扩展兼容仅涵盖已维护的部分，并非所有 PopClip 扩展；启用脚本前请检查。EdgeNotes 连接为可选功能。

安装前请核对 `SHA256SUMS` 的 SHA-256 值。本版同时提供源代码 ZIP 和 GitHub 自动生成的源代码压缩包。
