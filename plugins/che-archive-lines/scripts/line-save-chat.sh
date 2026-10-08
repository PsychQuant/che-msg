#!/bin/bash
# LINE 聊天記錄自動儲存腳本
# 使用相對座標（相對於視窗右上角）
#
# 依賴：cliclick (brew install cliclick)
# 權限：需要 Accessibility 權限

set -e

CONFIG_DIR="$HOME/.config/che-archive-lines"
CONFIG_FILE="$CONFIG_DIR/config.json"
ACTION=${1:-help}

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 整數檢查：設定值會進 $((…)) 算術展開，而 bash 會展開其中的陣列下標，
# 非整數的值（例如 a[$(指令)]）會被當成運算式、執行裡面的指令 (#149)。
# 不接受前導零：bash 會把 010 當八進位讀成 8，08 則直接報錯。
is_int() {
    [[ "$1" =~ ^-?(0|[1-9][0-9]{0,5})$ ]]
}

# 檢查 cliclick 是否安裝
check_dependencies() {
    if ! command -v cliclick &> /dev/null; then
        echo -e "${RED}錯誤：找不到 cliclick${NC}"
        echo "請執行：brew install cliclick"
        exit 1
    fi
}

# 取得 LINE 視窗資訊
get_window_info() {
    osascript -e 'tell application "System Events" to tell process "LINE"
        set w to front window
        set p to position of w
        set s to size of w
        set px to item 1 of p as integer
        set py to item 2 of p as integer
        set sx to item 1 of s as integer
        set sy to item 2 of s as integer
        return (px as text) & " " & (py as text) & " " & (sx as text) & " " & (sy as text)
    end tell' 2>/dev/null
}

# 解析視窗資訊（空格分隔：x y w h）。這些值也會進 $((…))，所以同樣只接受整數。
parse_window_info() {
    local info=$1
    WIN_X=$(echo "$info" | awk '{print $1}')
    WIN_Y=$(echo "$info" | awk '{print $2}')
    WIN_W=$(echo "$info" | awk '{print $3}')
    WIN_H=$(echo "$info" | awk '{print $4}')
    if ! is_int "$WIN_X" || ! is_int "$WIN_Y" || ! is_int "$WIN_W" || ! is_int "$WIN_H"; then
        echo -e "${RED}錯誤：LINE 視窗的位置或大小不是整數（osascript 回傳了非預期的值）${NC}"
        exit 1
    fi
}

# 讀取設定。回傳 0 = 成功；1 = 沒有設定檔（尚未校準）；2 = 設定檔有值不是整數。
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi
    OFFSET_X=$(cat "$CONFIG_FILE" | grep -o '"offset_x":[^,}]*' | cut -d':' -f2 | tr -d ' ')
    OFFSET_Y=$(cat "$CONFIG_FILE" | grep -o '"offset_y":[^,}]*' | cut -d':' -f2 | tr -d ' ')
    MENU_OFFSET_Y=$(cat "$CONFIG_FILE" | grep -o '"menu_offset_y":[^,}]*' | cut -d':' -f2 | tr -d ' ')
    # 只有完全沒有 menu_offset_y 這個 key 時才用預設值；key 在但讀不出值就停下來。
    if ! grep -q '"menu_offset_y"' "$CONFIG_FILE"; then
        MENU_OFFSET_Y=240
    fi

    if ! is_int "$OFFSET_X" || ! is_int "$OFFSET_Y" || ! is_int "$MENU_OFFSET_Y"; then
        echo -e "${RED}錯誤：設定檔 $CONFIG_FILE 的偏移值必須是整數（最多六位數，不能有前導零或正號），請重新執行 calibrate${NC}"
        return 2
    fi
    return 0
}

# 讀取設定；失敗就說明原因並結束
require_config() {
    local rc=0
    load_config || rc=$?
    if [ "$rc" -eq 1 ]; then
        echo -e "${RED}錯誤：尚未校準，請先執行 calibrate${NC}"
    fi
    if [ "$rc" -ne 0 ]; then
        exit 1
    fi
}

# 儲存設定
save_config() {
    local offset_x=$1
    local offset_y=$2
    local menu_offset_y=${3:-240}

    if ! is_int "$offset_x" || ! is_int "$offset_y" || ! is_int "$menu_offset_y"; then
        echo -e "${RED}錯誤：偏移值必須是整數，設定檔沒有寫入${NC}"
        exit 1
    fi

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
{
  "version": "1.0",
  "offset_x": $offset_x,
  "offset_y": $offset_y,
  "menu_offset_y": $menu_offset_y,
  "description": "相對於視窗右上角的偏移值",
  "calibrated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    echo -e "${GREEN}設定已儲存到 $CONFIG_FILE${NC}"
}

# 校準模式
calibrate() {
    echo "═══════════════════════════════════════════"
    echo " LINE 座標校準"
    echo "═══════════════════════════════════════════"
    echo ""

    # 啟動 LINE
    echo "啟動 LINE..."
    osascript -e 'tell application "LINE" to activate' 2>/dev/null || true
    sleep 0.5

    # 取得視窗資訊
    local info
    # LINE 沒開或沒有視窗時 osascript 會失敗；不讓 set -e 在這裡安靜結束，改由下面說明原因。
    info=$(get_window_info) || info=""
    if [ -z "$info" ]; then
        echo -e "${RED}錯誤：無法取得 LINE 視窗資訊${NC}"
        echo "請確認 LINE 已開啟並有聊天視窗"
        exit 1
    fi

    parse_window_info "$info"
    echo "LINE 視窗: 位置($WIN_X, $WIN_Y) 大小(${WIN_W}x${WIN_H})"
    echo ""
    echo -e "${YELLOW}請把滑鼠移到 LINE 聊天視窗右上角的「⋮」按鈕上${NC}"
    echo "準備好後按 Enter 鍵..."
    read -r

    # 取得滑鼠位置
    local pos
    pos=$(cliclick p)
    local mouse_x mouse_y
    mouse_x=$(echo "$pos" | cut -d',' -f1)
    mouse_y=$(echo "$pos" | cut -d',' -f2)
    if ! is_int "$mouse_x" || ! is_int "$mouse_y"; then
        echo -e "${RED}錯誤：無法取得滑鼠位置（cliclick 回傳的不是整數），設定檔沒有寫入${NC}"
        exit 1
    fi

    # 計算相對偏移（從視窗右上角）
    local offset_x offset_y
    offset_x=$((mouse_x - WIN_X - WIN_W))
    offset_y=$((mouse_y - WIN_Y))

    echo ""
    echo "滑鼠絕對座標: $pos"
    echo "相對偏移（從視窗右上角）: ($offset_x, $offset_y)"
    echo ""

    # 詢問「儲存聊天」在選單中的位置
    echo "「儲存聊天」選項在「⋮」下方幾個像素？（選單每項約 30px，預設 240 = 第 8 項）"
    echo "按 Enter 使用預設值 240，或輸入像素值（整數，例如 270）："
    read -r menu_input
    local menu_offset_y=${menu_input:-240}
    if ! is_int "$menu_offset_y"; then
        echo -e "${RED}錯誤：請輸入整數像素值（例如 240；最多六位數，不能有前導零或正號），設定檔沒有寫入${NC}"
        exit 1
    fi

    # 儲存設定
    save_config "$offset_x" "$offset_y" "$menu_offset_y"

    echo ""
    echo "═══════════════════════════════════════════"
    echo -e "${GREEN}校準完成！${NC}"
    echo ""
    echo "使用方式："
    echo "  line-save-chat.sh save    # 自動儲存當前聊天"
    echo "  line-save-chat.sh test    # 測試點擊位置"
    echo "═══════════════════════════════════════════"
}

# 測試點擊位置
test_click() {
    require_config

    echo "測試點擊「⋮」按鈕..."

    # 啟動 LINE
    osascript -e 'tell application "LINE" to activate' 2>/dev/null || true
    sleep 0.3

    # 取得視窗資訊
    local info
    # LINE 沒開或沒有視窗時 osascript 會失敗；不讓 set -e 在這裡安靜結束，改由下面說明原因。
    info=$(get_window_info) || info=""
    if [ -z "$info" ]; then
        echo -e "${RED}錯誤：無法取得 LINE 視窗資訊${NC}"
        echo "請確認 LINE 已開啟並有聊天視窗"
        exit 1
    fi
    parse_window_info "$info"

    # 計算絕對座標
    local btn_x btn_y
    btn_x=$((WIN_X + WIN_W + OFFSET_X))
    btn_y=$((WIN_Y + OFFSET_Y))

    echo "視窗位置: ($WIN_X, $WIN_Y)"
    echo "視窗大小: ${WIN_W}x${WIN_H}"
    echo "偏移值: ($OFFSET_X, $OFFSET_Y)"
    echo "點擊座標: ($btn_x, $btn_y)"
    echo ""
    echo "點擊中..."

    cliclick c:$btn_x,$btn_y

    echo -e "${GREEN}完成！請確認選單是否正確打開${NC}"
}

# 儲存聊天
save_chat() {
    require_config

    echo "自動儲存 LINE 聊天..."

    # 啟動 LINE
    osascript -e 'tell application "LINE" to activate' 2>/dev/null || true
    sleep 0.3

    # 取得視窗資訊
    local info
    # LINE 沒開或沒有視窗時 osascript 會失敗；不讓 set -e 在這裡安靜結束，改由下面說明原因。
    info=$(get_window_info) || info=""
    if [ -z "$info" ]; then
        echo -e "${RED}錯誤：無法取得 LINE 視窗資訊${NC}"
        exit 1
    fi
    parse_window_info "$info"

    # 計算按鈕絕對座標
    local btn_x btn_y
    btn_x=$((WIN_X + WIN_W + OFFSET_X))
    btn_y=$((WIN_Y + OFFSET_Y))

    echo "視窗: ($WIN_X, $WIN_Y) ${WIN_W}x${WIN_H}"
    echo "點擊「⋮」按鈕: ($btn_x, $btn_y)"

    # 點擊「⋮」按鈕
    cliclick c:$btn_x,$btn_y
    sleep 0.5

    # 點擊「儲存聊天」
    local save_y
    save_y=$((btn_y + MENU_OFFSET_Y))
    echo "點擊「儲存聊天」: ($btn_x, $save_y)"
    cliclick c:$btn_x,$save_y

    echo ""
    echo -e "${GREEN}完成！請在儲存對話框中選擇位置${NC}"
}

# 顯示說明
show_help() {
    echo "LINE 聊天記錄自動儲存工具"
    echo ""
    echo "使用方式："
    echo "  $0 calibrate  - 校準「⋮」按鈕座標（第一次使用必須執行）"
    echo "  $0 save       - 自動儲存當前聊天"
    echo "  $0 test       - 測試點擊位置"
    echo "  $0 help       - 顯示此說明"
    echo ""
    echo "步驟："
    echo "  1. 開啟 LINE 並進入要儲存的聊天"
    echo "  2. 執行 $0 calibrate 進行座標校準"
    echo "  3. 之後執行 $0 save 即可自動儲存"
    echo ""
    echo "設定檔位置: $CONFIG_FILE"
    echo ""
    echo "依賴："
    echo "  - cliclick (brew install cliclick)"
    echo "  - Accessibility 權限（系統設定 > 隱私權與安全性 > 輔助使用）"
}

# 主程式
check_dependencies

case $ACTION in
    calibrate)
        calibrate
        ;;
    save)
        save_chat
        ;;
    test)
        test_click
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}未知的操作: $ACTION${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
