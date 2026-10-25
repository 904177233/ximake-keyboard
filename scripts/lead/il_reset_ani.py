"""重置 iloader 的 Anisette State，然后重新登录。"""
import json
import sys
import time
import urllib.request

import websocket

TARGETS = json.load(urllib.request.urlopen('http://127.0.0.1:9333/json/list', timeout=5))
ws = websocket.create_connection(TARGETS[0]['webSocketDebuggerUrl'], suppress_origin=True, timeout=30)
_id = [0]


def ev(expr):
    _id[0] += 1
    ws.send(json.dumps({'id': _id[0], 'method': 'Runtime.evaluate',
                        'params': {'expression': expr, 'returnByValue': True}}))
    while True:
        msg = json.loads(ws.recv())
        if msg.get('id') == _id[0]:
            res = msg.get('result', {})
            if 'exceptionDetails' in res:
                return '__ERR__ ' + str(res['exceptionDetails'].get('text', ''))
            return res.get('result', {}).get('value')


def click(label):
    return ev(
        '(function(){var b=[...document.querySelectorAll("button")]'
        '.find(x=>x.innerText.trim()==="%s");'
        'if(!b)return "NO_BTN";if(b.disabled)return "DISABLED";b.click();return "OK";})()' % label
    )


def body():
    return ev('document.body.innerText') or ''


# 关掉可能残留的弹窗
for lbl in ('Dismiss', 'OK', 'Cancel'):
    click(lbl)

print('=== 点 Reset Anisette State ===')
print(click('Reset Anisette State'))
time.sleep(3)

print('=== 可能出现确认框，尝试点确认 ===')
for lbl in ('Confirm', 'Yes', 'Reset', 'OK'):
    r = click(lbl)
    if r == 'OK':
        print('  confirmed via', lbl)
        break
    print('  ', lbl, '->', r)
time.sleep(4)

print()
print('=== 重置后 body（截 500）===')
print(body()[:500])
ws.close()
