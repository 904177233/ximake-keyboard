"""关闭错误对话框并重新触发登录，让 Apple 重新推送 2FA 验证码。

流程：Dismiss 错误 → 清空并重填 Apple ID/密码 → 点 Login
→ 等 2FA 面板出现（出现即说明 Apple 已发码）
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


def key(kind, key_name, code, vk=0, modifiers=0):
    p = {'type': kind, 'key': key_name, 'code': code,
         'windowsVirtualKeyCode': vk, 'nativeVirtualKeyCode': vk, 'modifiers': modifiers}
    if kind == 'char':
        p['text'] = key_name
        p['unmodifiedText'] = key_name
    _send('Input.dispatchKeyEvent', p)


def click(label):
    return ev(
        '(function(){var b=[...document.querySelectorAll("button")]'
        '.find(x=>x.innerText.trim()==="%s");'
        'if(!b)return "NO_BTN";b.click();return "OK";})()' % label
    )


def fill(index, text):
    focused = ev(
        '(function(){var e=document.querySelectorAll("input")[%d];'
        'if(!e)return "NO_EL";e.focus();e.click();'
        'return document.activeElement===e?"FOCUSED":"NOT";})()' % index
    )
    if focused != 'FOCUSED':
        return 'FOCUS_FAIL:' + str(focused)
    for kind in ('keyDown', 'keyUp'):
        key(kind, 'a', 'KeyA', 65, modifiers=2)
    for kind in ('keyDown', 'keyUp'):
        key(kind, 'Backspace', 'Backspace', 8)
    ev('(function(){var e=document.querySelectorAll("input")[%d];'
       'Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set.call(e,"");'
       'e.dispatchEvent(new Event("input",{bubbles:true}));})()' % index)
    _send('Input.insertText', {'text': text})
    return ev('document.querySelectorAll("input")[%d].value' % index)


# ① 关掉错误对话框
for lbl in ('Dismiss', '✕'):
    r = click(lbl)
    if r == 'OK':
        print('dismissed via', lbl)
        break
time.sleep(1)

# ② 如果还在 2FA 面板（有 Verification Code 输入框），先取消它
in_2fa = ev(r"""
(function(){
  var ins = [...document.querySelectorAll('input')];
  return ins.some(function(e){
    var p = ((e.placeholder||'')+' '+(e.getAttribute('aria-label')||'')).toLowerCase();
    return p.indexOf('verification')>=0;
  });
})()
""")
print('still in 2FA panel:', in_2fa)
if in_2fa:
    # 2FA 面板通常有关闭 ✕，点一下退回登录页
    click('✕')
    time.sleep(1)

# ③ 重填并点 Login
print('email ->', fill(0, APPLE_ID))
print('pwd   ->', 'SET' if fill(1, PASSWORD) else 'FAIL')
print('login ->', click('Login'))

# ④ 等 2FA 面板
for i in range(30):
    time.sleep(2)
    body = ev('document.body.innerText') or ''
    if 'Verification Code' in body:
        print('2FA_PANEL_READY after', (i + 1) * 2, 's  → Apple 应已推送新验证码')
        ws.close()
        sys.exit(0)
    if 'Auth error' in body:
        line = [ln for ln in body.split('\n') if 'Auth error' in ln]
        print('AUTH_ERROR:', ' | '.join(line[:1]))
        ws.close()
        sys.exit(1)
print('TIMEOUT: 2FA 面板未出现')
print((ev('document.body.innerText') or '')[:400])
ws.close()
sys.exit(7)
