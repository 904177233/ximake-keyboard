"""填入 iloader 的 2FA 验证码并提交。"""
import json
import sys
import time
import urllib.request

import websocket

CODE = sys.argv[1] if len(sys.argv) > 1 else ''

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


# 找到验证码输入框（placeholder 含 Verification Code）
idx = ev(r"""
(function(){
  var ins = [...document.querySelectorAll('input')];
  for (var i = 0; i < ins.length; i++) {
    var ph = (ins[i].placeholder || '') + (ins[i].getAttribute('aria-label') || '');
    if (ph.toLowerCase().indexOf('verification') >= 0 || ph.toLowerCase().indexOf('code') >= 0) return i;
  }
  return -1;
})()
""")
print('code input index =', idx)
if idx is None or idx < 0:
    print('NO_CODE_INPUT')
    print((ev('document.body.innerText') or '')[:500])
    ws.close()
    sys.exit(2)

# focus + 全选 + 退格清空
ev('(function(){var e=document.querySelectorAll("input")[%d];e.focus();e.click();return 1;})()' % idx)
for kind in ('keyDown', 'keyUp'):
    key(kind, 'a', 'KeyA', 65, modifiers=2)
for kind in ('keyDown', 'keyUp'):
    key(kind, 'Backspace', 'Backspace', 8)
ev('(function(){var e=document.querySelectorAll("input")[%d];'
   'Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set.call(e,"");'
   'e.dispatchEvent(new Event("input",{bubbles:true}));})()' % idx)

_send('Input.insertText', {'text': CODE})
print('value now =', ev('document.querySelectorAll("input")[%d].value' % idx))

# 点提交按钮
sub = ev(r"""
(function(){
  var labels = ['Submit', 'Verify', 'Continue', 'Next', 'Sign In', 'Log in', 'Login'];
  var bs = [...document.querySelectorAll('button')];
  for (var i = 0; i < labels.length; i++) {
    var b = bs.find(function(x){ return x.innerText.trim() === labels[i]; });
    if (b && !b.disabled) { b.click(); return labels[i]; }
  }
  return 'NO_SUBMIT_BTN';
})()
""")
print('submit ->', sub)

outcome = 'TIMEOUT'
for i in range(40):
    time.sleep(3)
    body = ev('document.body.innerText') or ''
    if 'LOGGED IN AS' in body:
        outcome = 'LOGGED_IN'
        break
    if 'Auth error' in body or 'incorrect' in body.lower() or 'invalid code' in body.lower():
        line = [l for l in body.split('\n') if 'Auth error' in l or 'incorrect' in l.lower() or 'invalid' in l.lower()]
        outcome = 'ERROR: ' + ' | '.join(line[:2])
        break
    if 'Two-Factor' in body and 'Verification Code' in body:
        # 仍停在验证码页，继续等
        pass

print('OUTCOME:', outcome, 'after', (i + 1) * 3, 's')
print('--- BODY (600) ---')
print((ev('document.body.innerText') or '')[:600])
ws.close()
sys.exit(0 if outcome == 'LOGGED_IN' else 1)
