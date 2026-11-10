#!/bin/bash
# 在模拟器里把墨语键盘弹出来截图。键盘自己按 MOYU_SIM_CHECK 的顺序换高度和页面。
set -uo pipefail

OUT=build/sim-shots
APP=build/dd/Build/Products/Debug-iphonesimulator/AIKeyboard.app
APP_ID=com.example.moyu
KEYBOARD_ID=com.example.moyu.keyboard
ENGLISH="en_US@sw=QWERTY;hw=Automatic"
mkdir -p "$OUT"

defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false

UDID=$(python3 - <<'PY'
import json
import re
import subprocess

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
runtimes = [k for k in data["devices"] if "iOS" in k and data["devices"][k]]
# 运行环境的名字可能带机型后缀（iOS-27-2-iPhone19-4），只取主次版本号
runtimes.sort(key=lambda k: [int(p) for p in re.search(r"iOS-(\d+)-(\d+)", k).groups()], reverse=True)
chosen = None
for runtime in runtimes:
    phones = [d for d in data["devices"][runtime] if d["name"].startswith("iPhone")]
    pro = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]]
    if pro:
        chosen = pro[0]
        break
    plain = [d for d in phones if "Duo" not in d["name"] and "Fold" not in d["name"]]
    chosen = chosen or (plain[0] if plain else None)
if chosen is None:
    chosen = data["devices"][runtimes[0]][0]
print(chosen["udid"])
PY
)
echo "设备 $UDID"
if [ -z "$UDID" ]; then
  echo "::error::没选到模拟器"
  exit 1
fi
xcrun simctl list devices available > "$OUT/devices.txt"
xcrun simctl list devices | grep "$UDID" | tee "$OUT/device.txt"

xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"

SPAWN="xcrun simctl spawn $UDID"
$SPAWN pluginkit -e use -i "$KEYBOARD_ID" || true
$SPAWN pluginkit -m -p com.apple.keyboard-service -v 2>&1 | tee "$OUT/plugins.txt" || true
$SPAWN defaults write .GlobalPreferences AppleKeyboards -array "$KEYBOARD_ID" "$ENGLISH"
$SPAWN defaults write .GlobalPreferences AppleKeyboardsExpanded -int 1
$SPAWN defaults write com.apple.Preferences KeyboardsCurrentAndNext -array "$KEYBOARD_ID" "$ENGLISH"
$SPAWN defaults write com.apple.Preferences KeyboardLastUsed -string "$KEYBOARD_ID"
$SPAWN defaults write com.apple.Preferences KeyboardLastChosen -string "$KEYBOARD_ID"
$SPAWN defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true
$SPAWN defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true

# 重启一次，系统才会读这些设置
xcrun simctl shutdown "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
# 没有窗口时截图可能拿不到画面，把模拟器窗口开出来
open -a Simulator --args -CurrentDeviceUDID "$UDID" || true
sleep 15

$SPAWN defaults read .GlobalPreferences AppleKeyboards 2>&1 | tee "$OUT/keyboards.txt" || true
# 先给麦克风、语音识别权限，免得系统弹框挡住画面（不支持的项会报错，不管它）
for service in microphone speech-recognition photos-add; do
  xcrun simctl privacy "$UDID" grant "$service" "$APP_ID" 2>&1 | tee -a "$OUT/privacy.txt" || true
done
xcrun simctl launch "$UDID" "$APP_ID" | tee "$OUT/launch.txt"
sleep 15

for index in $(seq -w 1 44); do
  # 后一半切到深色，两种外观都看得到
  if [ "$index" = "23" ]; then
    xcrun simctl ui "$UDID" appearance dark 2>&1 | tee -a "$OUT/screenshot.txt" || true
  fi
  if ! xcrun simctl io "$UDID" screenshot --type=png "$OUT/shot-$index.png" 2>&1 | tee -a "$OUT/screenshot.txt"; then
    echo "第 $index 张 simctl 失败"
  fi
  # simctl 截不到时退回截整个桌面
  if [ ! -s "$OUT/shot-$index.png" ]; then
    screencapture -x "$OUT/desktop-$index.png" 2>&1 | tee -a "$OUT/screenshot.txt" || true
  fi
  sleep 4
done

# App 自己能不能从链接打开语音（键盘里点麦克风走的就是这个）
xcrun simctl openurl "$UDID" "moyu://voice" 2>&1 | tee -a "$OUT/openurl.txt" || true
sleep 6
xcrun simctl io "$UDID" screenshot --type=png "$OUT/shot-zz-openurl.png" >/dev/null 2>&1 || true
sleep 6
xcrun simctl io "$UDID" screenshot --type=png "$OUT/shot-zz-openurl-2.png" >/dev/null 2>&1 || true
ps ax | grep -i "AIKeyboard" | grep -v grep | cut -c1-120 | tee "$OUT/processes-after-openurl.txt" || true

count=$(ls "$OUT" | grep -c "^shot-.*\.png$" || true)
echo "截到 $count 张"
if [ "$count" -eq 0 ]; then
  echo "::error::一张截图都没有"
  exit 1
fi

# 键盘进程还在不在、有没有崩溃报告。扩展崩了系统会退回自带键盘，截图上看不出来
ps ax | grep -i "AIKeyboard" | grep -v grep | cut -c1-200 | tee "$OUT/processes.txt" || true
mkdir -p "$OUT/crash"
find "$HOME/Library/Logs/DiagnosticReports" -iname "*AIKeyboard*" -exec cp {} "$OUT/crash/" \; 2>/dev/null || true
ls -la "$OUT/crash" | tee "$OUT/crash-list.txt"
screencapture -x "$OUT/desktop-end.png" 2>&1 | tee -a "$OUT/screenshot.txt" || true

$SPAWN log show --last 3m --style compact --predicate 'process == "AIKeyboardExtension"' 2>/dev/null | tail -n 200 > "$OUT/keyboard.log" || true
ls -la "$OUT"
