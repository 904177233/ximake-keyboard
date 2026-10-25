"""在后台等待 2FA 验证码文件出现，一旦出现立刻填入并提交。

设计原因：2FA 验证码有效期约 5 分钟，而人工往返一轮要 10 分钟，
必然过期。改为后台常驻轮询 `%TEMP%\\moyu_2fa_code.txt`，
只要文件里出现 6 位数字就在 1 秒内提交。

用法：
    python tools/_il_2fa_wait.py [--timeout 1800]

日志：%TEMP%\\moyu_2fa.log
"""
import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.request

import websocket

CODE_FILE = os.path.join(tempfile.gettempdir(), 'moyu_2fa_code.txt')
LOG_FILE = os.path.join(tempfile.gettempdir(), 'moyu_2fa.log')


def log(msg):
    line = '%s %s' % (time.strftime('%H:%M:%S'), msg)
    print(line, flush=True)
    with open(LOG_FILE, 'a', encoding='utf-8') as fh:
        fh.write(line + '\n')


def connect():
    targets = json.load(urllib.request.urlopen('http://127.0.0.1:9333/json/list', timeout=5))
    return websocket.create_connection(
        targets[0]['webSocketDebuggerUrl'], suppress_origin=True, timeout=30
    )


class Driver:
    def __init__(self):
        self.ws = connect()
        self._id = 0

    def _send(self, method, params):
        self._id += 1
        self.ws.send(json.dumps({'id': self._id, 'method': method, 'params': params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get('id') == self._id:
                return msg.get('result', {})

    def ev(self, expr):
        res = self._send('Runtime.evaluate', {'expression': expr, 'returnByValue': True})
        if 'exceptionDetails' in res:
            return '__ERR__ ' + str(res['exceptionDetails'].get('text', ''))
        return res.get('result', {}).get('value')

    def key(self, kind, key_name, code, vk=0, modifiers=0):
        params = {'type': kind, 'key': key_name, 'code': code,
                  'windowsVirtualKeyCode': vk, 'nativeVirtualKeyCode': vk, 'modifiers': modifiers}
        if kind == 'char':
            params['text'] = key_name
            params['unmodifiedText'] = key_name
        self._send('Input.dispatchKeyEvent', params)

    def close(self):
        try:
            self.ws.close()
        except Exception:  # noqa: BLE001
            pass


def find_code_input(d):
    return d.ev(r"""
(function(){
  var ins = [...document.querySelectorAll('input')];
  for (var i = 0; i < ins.length; i++) {
    var ph = ((ins[i].placeholder || '') + ' ' + (ins[i].getAttribute('aria-label') || '')).toLowerCase();
    if (ph.indexOf('verification') >= 0 || ph.indexOf('code') >= 0) return i;
  }
  return -1;
})()
""")


def submit_code(code):
    """填入验证码并提交，返回 (ok, message)。"""
    d = Driver()
    try:
        idx = find_code_input(d)
        if idx is None or idx < 0:
            body = d.ev('document.body.innerText') or ''
            return False, 'NO_CODE_INPUT | ' + body[:200].replace('\n', ' ')

        # focus + 全选 + 退格 + 兜底清空
        d.ev('(function(){var e=document.querySelectorAll("input")[%d];e.focus();e.click();return 1;})()' % idx)
        for kind in ('keyDown', 'keyUp'):
            d.key(kind, 'a', 'KeyA', 65, modifiers=2)
        for kind in ('keyDown', 'keyUp'):
            d.key(kind, 'Backspace', 'Backspace', 8)
        d.ev(
            '(function(){var e=document.querySelectorAll("input")[%d];'
            'Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set.call(e,"");'
            'e.dispatchEvent(new Event("input",{bubbles:true}));})()' % idx
        )
        d._send('Input.insertText', {'text': code})
        now = d.ev('document.querySelectorAll("input")[%d].value' % idx)
        log('  填入后输入框值 = %r' % (now,))
        if str(now) != code:
            return False, 'FILL_MISMATCH got=%r want=%r' % (now, code)

        clicked = d.ev(r"""
(function(){
  var labels = ['Submit', 'Verify', 'Continue', 'Next', 'Sign In'];
  var bs = [...document.querySelectorAll('button')];
  for (var i = 0; i < labels.length; i++) {
    var b = bs.find(function(x){ return x.innerText.trim() === labels[i] && !x.disabled; });
    if (b) { b.click(); return labels[i]; }
  }
  return 'NO_SUBMIT_BTN';
})()
""")
        log('  提交按钮 = %s' % clicked)
        if clicked == 'NO_SUBMIT_BTN':
            return False, 'NO_SUBMIT_BTN'

        # 轮询结果
        for i in range(50):
            time.sleep(2)
            body = d.ev('document.body.innerText') or ''
            if 'LOGGED IN AS' in body:
                return True, 'LOGGED_IN after %ds' % ((i + 1) * 2)
            if 'Auth error' in body:
                line = [ln for ln in body.split('\n') if 'Auth error' in ln]
                return False, 'AUTH_ERROR ' + ' | '.join(line[:1])
            low = body.lower()
            if 'incorrect' in low or 'invalid' in low:
                line = [ln for ln in body.split('\n') if 'incorrect' in ln.lower() or 'invalid' in ln.lower()]
                return False, 'REJECTED ' + ' | '.join(line[:1])
        return False, 'TIMEOUT waiting result'
    finally:
        d.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--timeout', type=int, default=1800)
    args = ap.parse_args()

    # 清掉旧码
    if os.path.exists(CODE_FILE):
        os.remove(CODE_FILE)
    open(LOG_FILE, 'w', encoding='utf-8').close()
    log('等待验证码文件：%s（最多 %ds）' % (CODE_FILE, args.timeout))

    deadline = time.time() + args.timeout
    seen = None
    while time.time() < deadline:
        if os.path.exists(CODE_FILE):
            try:
                raw = open(CODE_FILE, encoding='utf-8', errors='ignore').read()
            except OSError:
                raw = ''
            m = re.search(r'\d{6}', raw)
            if m:
                code = m.group(0)
                if code != seen:
                    seen = code
                    log('收到验证码 %s，开始提交' % code)
                    ok, msg = submit_code(code)
                    log('结果：%s | %s' % ('SUCCESS' if ok else 'FAILED', msg))
                    if ok:
                        try:
                            os.remove(CODE_FILE)
                        except OSError:
                            pass
                        return 0
                    # 失败就继续等新码
                    try:
                        os.remove(CODE_FILE)
                    except OSError:
                        pass
        time.sleep(1)

    log('超时，未收到有效验证码')
    return 7


if __name__ == '__main__':
    sys.exit(main())
