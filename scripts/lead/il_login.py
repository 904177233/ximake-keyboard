"""通过 CDP 驱动 iloader 登录：先清空输入框，再键入，避免内容累加。

关键教训：上一版直接用 `Input.insertText`，它会在光标处**追加**而不是替换，
重试几次后 Apple ID 变成 `z***3@icloud.comz904177233@icloud.com`，
Apple 返回 `Auth error -20970: Your account information was entered incorrectly.`
正确做法：先 focus + 全选（Ctrl+A）+ 退格清空，再 insertText。
"""
import json
import sys
import time
import urllib.request

import websocket

APPLE_ID = 'z904177233@icloud.com'
PASSWORD = 'Zjcisme123@'

TARGETS = json.load(urllib.request.urlopen('http://127.0.0.1:9333/json/list', timeout=5))
ws = websocket.create_connection(TARGETS[0]['webSocketDebuggerUrl'], suppress_origin=True, timeout=30)
_id = [0]

CTRL_A = 65


def _send(method, params):
    _id[0] += 1
    ws.send(json.dumps({'id': _id[0], 'method': method, 'params': params}))
    while True:
        msg = json.loads(ws.recv())
        if msg.get('id') == _id[0]:
            return msg.get('result', {})


def ev(expr):
    res = _send('Runtime.evaluate', {'expression': expr, 'returnByValue': True})
    if 'exceptionDetails' in res:
        return '__ERR__ ' + str(res['exceptionDetails'].get('text', ''))
    return res.get('result', {}).get('value')


def key(kind, key_name, code, windows_vk=0, modifiers=0):
    """发一个原始按键事件（kind = keyDown / keyUp / char）。"""
    params = {
        'type': kind,
        'key': key_name,
        'code': code,
        'windowsVirtualKeyCode': windows_vk,
        'nativeVirtualKeyCode': windows_vk,
        'modifiers': modifiers,
    }
    if kind == 'char':
        params['text'] = key_name
        params['unmodifiedText'] = key_name
    _send('Input.dispatchKeyEvent', params)


def clear_and_type(index, text):
    """focus 第 index 个 input → 全选 → 退格 → insertText。"""
    focused = ev(
        '(function(){var e=document.querySelectorAll("input")[%d];'
        'if(!e)return "NO_EL";e.focus();e.click();'
        'return document.activeElement===e?"FOCUSED":"NOT";})()' % index
    )
    if focused != 'FOCUSED':
        return 'FOCUS_FAIL:' + str(focused)

    # 全选（Ctrl+A）后按退格清空
    for kind in ('keyDown', 'keyUp'):
        key(kind, 'a', 'KeyA', CTRL_A, modifiers=2)   # modifiers=2 → Ctrl
    for kind in ('keyDown', 'keyUp'):
        key(kind, 'Backspace', 'Backspace', 8)

    blank = ev('document.querySelectorAll("input")[%d].value' % index)
    if blank:
        # 兜底：用原生 setter 强制清空
        ev(
            '(function(){var e=document.querySelectorAll("input")[%d];'
            'var p=HTMLInputElement.prototype;'
            'Object.getOwnPropertyDescriptor(p,"value").set.call(e,"");'
            'e.dispatchEvent(new Event("input",{bubbles:true}));})()' % index
        )

    _send('Input.insertText', {'text': text})
    return ev('document.querySelectorAll("input")[%d].value' % index)


def click(label):
    return ev(
        '(function(){var b=[...document.querySelectorAll("button")]'
        '.find(x=>x.innerText.trim()==="%s");'
        'if(!b)return "NO_BTN";if(b.disabled)return "DISABLED";b.click();return "OK";})()' % label
    )


# 关掉残留弹窗
for lbl in ('Dismiss', 'Cancel', 'Close', '✕'):
    click(lbl)
time.sleep(1)

print('email ->', clear_and_type(0, APPLE_ID))
print('pwd   ->', 'SET' if clear_and_type(1, PASSWORD) else 'FAIL')

print('login ->', click('Login'))

outcome = 'TIMEOUT'
for i in range(30):
    time.sleep(3)
    body = ev('document.body.innerText') or ''
    if 'LOGGED IN AS' in body:
        outcome = 'LOGGED_IN'
        break
    if 'Auth error' in body:
        line = [l for l in body.split('\n') if 'Auth error' in l]
        outcome = 'AUTH_ERROR: ' + ' | '.join(line[:1])
        break
    low = body.lower()
    if 'verification code' in low or 'two-factor' in low:
        outcome = 'NEED_2FA'
        break

print('OUTCOME:', outcome, 'after', (i + 1) * 3, 's')
print('--- BODY ---')
print((ev('document.body.innerText') or '')[:600])
ws.close()
sys.exit(0 if outcome in ('LOGGED_IN', 'NEED_2FA') else 1)
