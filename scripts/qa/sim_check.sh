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
import subprocess

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
runtimes = [k for k in data["devices"] if "iOS" in k and data["devices"][k]]
newest = sorted(runtimes, key=lambda k: [int(p) for p in k.rsplit("iOS-", 1)[1].split("-")])[-1]
devices = [d for d in data["devices"][newest] if d["name"].startswith("iPhone")]
pro = [d for d in devices if "Pro" in d["name"] and "Max" not in d["name"]]
device = (pro or devices)[0]
print(device["udid"])
PY
)
echo "设备 $UDID"
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
sleep 10

$SPAWN defaults read .GlobalPreferences AppleKeyboards 2>&1 | tee "$OUT/keyboards.txt" || true
xcrun simctl launch "$UDID" "$APP_ID" | tee "$OUT/launch.txt"
sleep 15

for index in $(seq -w 1 16); do
  xcrun simctl io "$UDID" screenshot "$OUT/shot-$index.png" >/dev/null 2>&1
  sleep 5
done

$SPAWN log show --last 3m --style compact --predicate 'process == "AIKeyboardExtension"' 2>/dev/null | tail -n 200 > "$OUT/keyboard.log" || true
ls -la "$OUT"
