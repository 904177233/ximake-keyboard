"""读取 iloader 当前的错误对话框全文，并关闭它。"""
import json
import urllib.request

import websocket

TARGETS = json.load(urllib.request.urlopen('http://127.0.0.1:9333/json/list', timeout=5))
ws = websocket.create_connection(TARGETS[0]['webSocketDebuggerUrl'], suppress_origin=True, timeout=25)
_id = [0]


def ev(expr):
    _id[0] += 1
    ws.send(json.dumps({
        'id': _id[0], 'method': 'Runtime.evaluate',
        'params': {'expression': expr, 'returnByValue': True},
    }))
    while True:
        msg = json.loads(ws.recv())
        if msg.get('id') == _id[0]:
            res = msg.get('result', {})
            if 'exceptionDetails' in res:
                return '__ERR__ ' + str(res['exceptionDetails'].get('text', ''))
            return res.get('result', {}).get('value')


print('=== 弹窗 / 错误全文 ===')
print(ev(r"""
(function(){
  var out = [];
  document.querySelectorAll('*').forEach(function(e){
    var t = (e.innerText || '').trim();
    if (t && (t.indexOf('Error') >= 0 || t.indexOf('error') >= 0 ||
              t.indexOf('Failed') >= 0 || t.indexOf('failed') >= 0 ||
              t.indexOf('Try again') >= 0 || t.indexOf('Dismiss') >= 0)) {
      if (e.children.length === 0 || (e.innerText || '').length < 900) out.push(t);
    }
  });
  return out.slice(-4).join('\n@@@\n');
})()
"""))

print()
print('=== 顶层 body 末尾 900 字 ===')
body = ev('document.body.innerText') or ''
print(body[-900:])

print()
print('=== 关闭弹窗 ===')
print(ev(r"""
(function(){
  var b = [...document.querySelectorAll('button')].find(x => x.innerText.trim() === 'Dismiss');
  if (!b) return 'NO_DISMISS_BTN';
  b.click();
  return 'DISMISSED';
})()
"""))
ws.close()
