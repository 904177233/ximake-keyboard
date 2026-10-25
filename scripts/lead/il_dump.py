"""dump 所有可见文本节点，找完整错误信息。"""
import json
import urllib.request

import websocket

TARGETS = json.load(urllib.request.urlopen('http://127.0.0.1:9333/json/list', timeout=5))
ws = websocket.create_connection(TARGETS[0]['webSocketDebuggerUrl'], suppress_origin=True, timeout=25)
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


# 所有"叶子级"文本 + 是否有 modal
print('=== 有 modal 吗 ===')
print(ev(r"""
JSON.stringify({
  modals: document.querySelectorAll('[class*=modal],[class*=dialog],[role=dialog]').length,
  bodyLen: document.body.innerText.length
})
"""))

print()
print('=== 所有文本叶子（去重, 长度>12）===')
print(ev(r"""
(function(){
  var seen = {}, out = [];
  document.querySelectorAll('*').forEach(function(e){
    if (e.children.length > 0) return;
    var t = (e.textContent || '').trim();
    if (t.length > 12 && !seen[t]) { seen[t] = 1; out.push(t); }
  });
  return out.slice(0, 40).join('\n');
})()
"""))
ws.close()
