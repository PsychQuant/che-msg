---
name: archive-lines
description: 自動儲存 LINE macOS 聊天記錄（依座標點擊「⋮」→「儲存聊天」）。
argument-hint: "[calibrate|save|test|help]"
disable-model-invocation: true
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh save)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh test)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh help)
---

# Archive Lines

自動化 LINE macOS 的「儲存聊天」功能。

## 使用方式

```
/che-archive-lines:archive-lines calibrate   # 第一次使用：校準按鈕位置（在使用者自己的終端機執行）
/che-archive-lines:archive-lines save        # 自動儲存當前聊天
/che-archive-lines:archive-lines test        # 測試點擊位置
/che-archive-lines:archive-lines help        # 顯示說明
```

這個 skill 只在使用者主動輸入時執行（`disable-model-invocation: true`）：腳本會依座標點擊 LINE 視窗、移動滑鼠。`allowed-tools` 只預先放行三句指令：這支腳本加上 `save`、`test` 或 `help`（Claude Code 會把規則裡的 `${CLAUDE_PLUGIN_ROOT}` 代換成 plugin 的安裝路徑）。不論使用者輸入的是哪個操作，三句在那一輪都免詢問，所以只能執行 Step 1 解析出來的那一個。`calibrate` 和任何其他指令都不在其中，照使用者的一般權限設定處理。放行只在叫用 skill 的那一輪有效：使用者送出下一則訊息後，如果再執行這支腳本（例如使用者說「再存一次」），照使用者的一般權限設定處理，auto 模式下由 classifier 判斷，不一定會詢問。

LINE 本機的訊息資料庫（`.edb`）是加密的，讀得懂的資料來源只有「儲存聊天」匯出的 `.txt`。

## 執行步驟

### Step 1: 解析參數

使用者輸入的參數：`$ARGUMENTS`

參數只接受 `calibrate`、`save`、`test`、`help` 四個字之一，空白視同 `help`。不是這四個字之一時，不要執行任何指令，回覆使用者這四個可用的操作即可。指令裡只放這四個字本身，不放使用者輸入的其他文字。

### Step 2: 執行 help、save 或 test

每次執行都只用下面列出的那一行指令，單獨一個 Bash 呼叫：不要加 `cd`、`&&`、`;`、管線、重導向或其他指令，也不要先存進變數。多出來的部分不在這個 skill 預先放行的範圍內。

#### help - 顯示說明

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh" help
```

#### save - 儲存模式

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh" save
```

流程：
1. 讀取校準設定
2. 啟動 LINE
3. 取得當前視窗位置
4. 計算絕對座標（視窗位置 + 相對偏移）
5. 點擊「⋮」按鈕
6. 等待 0.5 秒
7. 點擊「儲存聊天」選項
8. 等待儲存對話框出現

#### test - 測試模式

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh" test
```

只點擊「⋮」按鈕，不點擊選單，用於確認校準是否正確。

### Step 3: calibrate（交給使用者在自己的終端機執行）

**不要用 Bash 工具執行 calibrate**，它也不在預先放行的範圍內。校準要等使用者把滑鼠移到「⋮」上再按 Enter，Bash 工具沒有互動式終端：直接執行會在等 Enter 時退出；用管線送兩行以上的輸入進去，則會把當下的滑鼠位置寫成校準結果，覆蓋掉原本正確的設定（第二行是空行時，選單位移寫入預設值 240；PsychQuant/che-msg#52）。

請把下面這行指令原樣顯示給使用者，請他貼到自己的終端機（Terminal.app、iTerm）執行，完成後再回來：

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/line-save-chat.sh" calibrate
```

同時提醒使用者：腳本會先把 LINE 叫到前景，這時鍵盤輸入會進 LINE，直接按 Enter 可能把 LINE 輸入框裡的草稿送出去。要先用 Cmd-Tab 切回終端機（不要用滑鼠點），確認終端機視窗沒有蓋住 LINE 右上角的「⋮」，再把滑鼠移到「⋮」上，在終端機按 Enter。

校準流程（在使用者的終端機裡）：
1. 啟動 LINE（LINE 跳到前景）
2. 取得視窗位置和大小
3. 提示使用者把滑鼠移到「⋮」按鈕
4. 使用者切回終端機按 Enter 後，記錄滑鼠位置
5. 計算相對偏移值（相對於視窗右上角）
6. 再提示輸入「儲存聊天」選項相對於「⋮」的垂直位移（像素）：直接按 Enter 用預設值 240，輸入的值必須是整數，否則不寫入設定檔
7. 儲存到 `~/.config/che-archive-lines/config.json`（三個偏移值都必須是整數，否則不寫入）

### Step 4: 輸出結果

```
═══════════════════════════════════════════
 Archive Lines 完成
═══════════════════════════════════════════

操作: save
狀態: 成功
說明: 請在儲存對話框中選擇位置

═══════════════════════════════════════════
```

## 設定檔格式

`~/.config/che-archive-lines/config.json`:

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

## 依賴需求

- **cliclick**: `brew install cliclick`
- **LINE macOS**: 已安裝並登入
- **Accessibility 權限**: Terminal 需要輔助使用權限

## 注意事項

1. **首次使用必須校準**: 執行 `/che-archive-lines:archive-lines calibrate`，Claude 會顯示要在終端機執行的指令
2. **視窗大小變化無影響**: 使用相對座標，自動計算
3. **手動選擇儲存位置**: 腳本會開啟儲存對話框，需手動選擇路徑
4. **僅支援當前聊天**: 每次只能儲存正在查看的聊天
5. **macOS 限定**: 僅支援 macOS 版 LINE

## 故障排除

### 選單沒有打開
- 執行 `/che-archive-lines:archive-lines test` 確認點擊位置
- 重新執行 `/che-archive-lines:archive-lines calibrate` 校準

### 點擊到錯誤位置
- LINE 視窗可能被其他視窗遮擋
- 確認 LINE 是前景應用程式

### 權限錯誤
- 系統設定 > 隱私權與安全性 > 輔助使用
- 將 Terminal/iTerm 加入允許清單
