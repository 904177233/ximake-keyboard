"""检查 iloader 登录状态与设备选择状态。"""
import json
import urllib.request

import websocket

TARGETS = json.load(urllib.request.urlopen('http://127.0.0.1:9333/json/list', timeout=5))
ws = websocket.create_connection(TARGETS[0]['webSocketDebuggerUrl'], suppress_origin=True, timeout=25)

_id = [0]


def ev(expr, await_=False):
    _id[0] += 1
    ws.send(json.dumps({
        'id': _id[0],
        'method': 'Runtime.evaluate',
        'params': {'expression': expr, 'returnByValue': True, 'awaitPromise': await_},
    }))
    while True:
        msg = json.loads(ws.recv())
        if msg.get('id') == _id[0]:
            return msg.get('result', {}).get('result', {}).get('value')


body = ev('document.body.innerText') or ''
print('LOGGED_IN:', 'LOGGED IN AS' in body)
print('HAS_2FA :', 'Two-Factor' in body or 'verification code' in body.lower())
print('HAS_DEVICE_SELECTED:', 'Selected' in body)
print('INPUTS:', ev('JSON.stringify([...document.querySelectorAll("input")].map((e,i)=>({i,t:e.type,p:e.placeholder,v:e.value})))'))
print()
print('--- BODY ---')
print(body[:900])
ws.close()
