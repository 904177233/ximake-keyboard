"""dump iloader 弹窗/错误模态的完整文本。"""
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


# 找含 "Try again" 的最外层容器，取其完整 innerText
print(ev(r"""
(function(){
  var nodes = [...document.querySelectorAll('div,section,aside')];
  var hits = nodes.filter(function(e){
    var t = e.innerText || '';
    return t.indexOf('Try again') >= 0 && t.length < 2000;
  });
  if (!hits.length) return 'NO_MODAL';
  // 取最短的那个（最内层完整容器）
  hits.sort(function(a,b){ return (a.innerText||'').length - (b.innerText||'').length; });
  return hits[0].innerText;
})()
"""))

print()
print('=== 整个 HTML 里所有含 error/Error 的属性值 ===')
print(ev(r"""
(function(){
  var out = [];
  document.querySelectorAll('[class*=error],[class*=Error],[data-error]').forEach(function(e){
    out.push((e.className||'') + ' :: ' + (e.innerText||'').slice(0,300));
  });
  return out.join('\n---\n').slice(0, 1500);
})()
"""))
ws.close()
