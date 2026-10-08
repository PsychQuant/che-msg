# che-archive-lines

自動化 LINE macOS 聊天記錄的歸檔流程。

## 背景

LINE macOS 版使用 Qt 框架，其 UI 元素不支援 macOS Accessibility API，因此無法使用標準的 AppleScript 來自動化操作。此 plugin 使用座標點擊方式來實現自動化。

## 功能

- **calibrate**: 校準「⋮」選單按鈕的位置
- **save**: 自動點擊「儲存聊天」功能
- **test**: 測試點擊位置是否正確

## 安裝

### 從 Marketplace 安裝

```bash
/plugin marketplace add PsychQuant/che-msg
/plugin install che-archive-lines@che-msg
```

### 之前從 psychquant-claude-plugins 安裝過？

1.1.0 以前這個 plugin 由 `psychquant-claude-plugins` marketplace 發布，1.1.1 起改由本 repository 的 `che-msg` marketplace 發布。在終端機裡先移除舊的、再裝新的：

```bash
claude plugin uninstall che-archive-lines@psychquant-claude-plugins   # 當初裝在專案範圍的話加 --scope project
claude plugin marketplace add PsychQuant/che-msg
claude plugin install che-archive-lines@che-msg
```

校準設定在 `~/.config/che-archive-lines/config.json`，不在 plugin 目錄裡，換安裝來源後不必重新校準。

### 依賴

```bash
brew install cliclick
```

還需要在「系統設定 > 隱私權與安全性 > 輔助使用」中授權 Terminal/iTerm。

## 使用方式

指令的完整名稱是 `/che-archive-lines:archive-lines`；skill 設了 `name: archive-lines`，所以沒有其他指令使用 `/archive-lines` 這個名字時，短名也能叫用。

這個 skill 只在你主動輸入時執行，Claude 不會自己觸發，因為腳本會依座標點擊 LINE 視窗、移動滑鼠。它只預先放行三句指令：這支腳本加上 `save`、`test` 或 `help`。叫用 skill 的那一輪，不論你輸入的是哪個操作，這三句都直接執行、不詢問，除非你的設定裡有符合的 deny／ask 規則，或受管設定（managed settings）另有規定。`calibrate` 和其他任何指令都不在預先放行的範圍內，照你平常的權限設定處理。你送出下一則訊息後放行就失效：之後 Claude 若再執行這支腳本（例如你說「再存一次」），照你平常的權限設定處理，auto 模式下由 classifier 判斷，不一定會詢問。

### 第一次使用

1. 開啟 LINE 並進入任一聊天視窗
2. 執行校準：

```
/che-archive-lines:archive-lines calibrate
```

3. 校準要在終端機裡等你按 Enter，Claude 的 Bash 工具沒有互動式終端，做不到這件事（[#145](https://github.com/PsychQuant/psychquant-claude-plugins/issues/145)）。所以 Claude 不會自己執行校準，而是顯示一行含完整路徑的指令，請貼到你自己的終端機（Terminal.app、iTerm）執行
4. 腳本會先把 LINE 叫到前景，這時鍵盤輸入會進 LINE：直接按 Enter 可能把 LINE 輸入框裡的草稿送出去。先用 Cmd-Tab 切回終端機（不要用滑鼠點），確認終端機視窗沒有蓋住 LINE 右上角的「⋮」，再把滑鼠移到「⋮」按鈕上，在終端機按 Enter
5. 接著回答「儲存聊天」選項在「⋮」下方幾個像素：直接按 Enter 用預設值 240；要輸入的話必須是整數（例如 270），否則不會寫入設定檔

### 儲存聊天

```
/che-archive-lines:archive-lines save
```

執行後會：
1. 自動點擊「⋮」按鈕
2. 自動點擊「儲存聊天」選項
3. 開啟儲存對話框（需手動選擇儲存位置）

### 測試

```
/che-archive-lines:archive-lines test
```

僅點擊「⋮」按鈕，用於確認校準是否正確。

## 設定檔

校準資訊儲存在 `~/.config/che-archive-lines/config.json`。手動修改時，三個偏移值都只能是整數（不能有前導零）；腳本讀到其他值會停下來，要求重新校準（[#149](https://github.com/PsychQuant/psychquant-claude-plugins/issues/149)）。

```json
{
  "version": "1.0",
  "offset_x": -30,
  "offset_y": 100,
  "menu_offset_y": 240,
  "description": "相對於視窗右上角的偏移值",
  "calibrated_at": "2026-01-15T10:00:00Z"
}
```

## 資料來源

LINE macOS 版本機的訊息資料庫（`~/Library/Containers/jp.naver.line.mac/…/db/*.edb`）是加密的，無法直接讀取。讀得懂的資料來源只有「儲存聊天」匯出的 `.txt`，也就是這個 plugin 觸發的功能。讀取匯出檔的 LINE MCP 由 [PsychQuant/che-msg#41](https://github.com/PsychQuant/che-msg/issues/41) 追蹤。

匯出的 `.txt` 是對話雙方的逐字內容，請不要 commit 進 git remote。

## 技術原理

1. **相對座標**: 按鈕位置以視窗右上角為基準計算偏移，視窗移動或縮放時自動調整
2. **cliclick**: 使用 cliclick 工具進行滑鼠點擊
3. **osascript**: 使用 AppleScript 取得視窗位置和大小

## 限制

- 僅支援 macOS 版 LINE
- 每次只能儲存當前開啟的聊天
- 儲存對話框需手動選擇位置
- 需要 Accessibility 權限

## 故障排除

### 選單沒有打開

1. 執行 `/che-archive-lines:archive-lines test` 確認點擊位置
2. 如果點擊位置不對，重新執行 `/che-archive-lines:archive-lines calibrate`

### 權限錯誤

1. 開啟「系統設定 > 隱私權與安全性 > 輔助使用」
2. 將 Terminal 或 iTerm 加入允許清單
3. 重新啟動 Terminal

### cliclick 找不到

```bash
brew install cliclick
```

## 授權

MIT License

## 作者

Che Cheng
