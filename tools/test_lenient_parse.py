"""复刻 Swift 侧 `extractJSONObjects` + `parseSSEBodyAsCompletion` 的逻辑，
用用户真机上贴出的那段不规范响应做离线验证。

目的：在没有 Xcode、装不上机的情况下，先证明「按花括号深度抠 JSON」这套算法
确实能从这种畸形报文里还原出正文。算法与 Swift 版逐行对应，任何一边改了都要同步。
"""

import json

# 用户 m14903 贴出的原始响应（全角冒号 + 无空行 + 多对象首尾相连 + 行内换行）
SAMPLE = (
    'data：{"id":"3d6beb0b-4afa-439d-92d9-a4832ac57693","object":"chat.completion.chunk",'
    '"created":1792949140,"model":"deepseek-flash","system_fingerprint":"e72d3c7f",'
    '"choices":[{"index":0,"delta":{"content":"你"},"logprobs":null,"finish_reason":null}]}'
    'data：{"id":"3d6beb0b-4afa-439d-92d9-a4832ac57693","object":"chat.completion.chunk",'
    '"created":1792949140,"model":"deepseek-flash",'
    '"choices":[{"index":0,"delta":{"content":"好"},"logprobs":null,"finish_reason":null}]}'
    'data：{"id":"3d6beb0b-4afa-439d-92d9-a4832ac57693","object":"chat.completion.chunk",'
    '"created":1792949140,"model":"deepseek-flash",'
    '"choices":[{"index":0,"delta":{"content":"，我是墨语"},"logprobs":null,"finish_reason":"stop"}],'
    '"usage":{"prompt_tokens":9,"completion_tokens":5,"total_tokens":14}}'
    'data：[DONE]'
)


def extract_json_objects(text: str) -> list[str]:
    """按花括号深度抠出平衡的 JSON 对象（与 Swift 版 extractJSONObjects 等价）。"""
    results: list[str] = []
    depth = 0
    start = None
    in_string = False
    escaped = False

    for i, ch in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '"':
                if depth > 0:
                    in_string = True
            elif ch == '{':
                if depth == 0:
                    start = i
                depth += 1
            elif ch == '}':
                if depth > 0:
                    depth -= 1
                    if depth == 0 and start is not None:
                        results.append(text[start:i + 1])
                        start = None
    return results


def parse_lenient(text: str):
    """与 Swift 版 parseSSEBodyAsCompletion 等价：拼正文 + 收 usage/finish_reason。"""
    lowered = text.lower()
    if not ('data' in lowered or 'chat.completion.chunk' in lowered):
        return None

    objects = extract_json_objects(text)
    if not objects:
        return None

    out = {'text': '', 'reasoning': '', 'finish_reason': None, 'usage': None, 'chunks': 0}
    saw_any_choice = False

    for obj in objects:
        try:
            root = json.loads(obj)
        except json.JSONDecodeError:
            continue
        if isinstance(root.get('usage'), dict):
            u = root['usage']
            out['usage'] = {
                'prompt': u.get('prompt_tokens', 0),
                'completion': u.get('completion_tokens', 0),
                'total': u.get('total_tokens', 0),
            }
        choices = root.get('choices')
        if not isinstance(choices, list) or not choices:
            continue
        first = choices[0]
        if not isinstance(first, dict):
            continue
        saw_any_choice = True
        out['chunks'] += 1
        container = first.get('delta') or first.get('message') or {}
        content = container.get('content')
        if isinstance(content, str):
            out['text'] += content
        elif isinstance(content, list):
            out['text'] += ''.join(p.get('text', '') for p in content if isinstance(p, dict))
        chain = container.get('reasoning_content')
        if isinstance(chain, str):
            out['reasoning'] += chain
        fr = first.get('finish_reason')
        if isinstance(fr, str) and fr:
            out['finish_reason'] = fr

    if not saw_any_choice:
        return None
    if not out['text'].strip():
        return None
    return out


def main() -> int:
    print('=' * 70)
    print('宽松解析离线验证（复刻 Swift 实现）')
    print('=' * 70)
    print(f'样本长度：{len(SAMPLE)} 字符')

    objs = extract_json_objects(SAMPLE)
    print(f'抠出 JSON 对象：{len(objs)} 个')
    for i, o in enumerate(objs, 1):
        print(f'  [{i}] {o[:64]}…')
    assert len(objs) == 3, f'应抠出 3 个对象，实际 {len(objs)}'

    result = parse_lenient(SAMPLE)
    assert result is not None, '解析失败，不应为 None'
    print('-' * 70)
    print(f"正文        : {result['text']!r}")
    print(f'分片数      : {result["chunks"]}')
    print(f"finish      : {result['finish_reason']}")
    print(f"usage       : {result['usage']}")
    assert result['text'] == '你好，我是墨语', f'正文不对：{result["text"]!r}'
    assert result['chunks'] == 3
    assert result['finish_reason'] == 'stop'
    assert result['usage']['total'] == 14

    # 边界 1：标准非流式 JSON 不应被这个分支吞掉（它没有 data 字样）
    plain = '{"choices":[{"message":{"content":"hi"}}]}'
    assert parse_lenient(plain) is None, '普通 JSON 不该走宽松分支'
    print('边界 1 通过：普通 JSON 不会被宽松分支接管')

    # 边界 2：正文里带花括号（代码）不应把括号算乱
    tricky = ('data:{"choices":[{"delta":{"content":"函数长这样：{a:1}"},"finish_reason":"stop"}]}')
    r2 = parse_lenient(tricky)
    assert r2 is not None and r2['text'] == '函数长这样：{a:1}', f'嵌套花括号失败：{r2}'
    print('边界 2 通过：正文里的 { } 不会被误算')

    # 边界 3：只有思维链、没有正文 → 返回 None（交给上层的空正文判定）
    only_reasoning = ('data:{"choices":[{"delta":{"reasoning_content":"想一想"},"finish_reason":"length"}]}')
    assert parse_lenient(only_reasoning) is None, '只有思维链时应返回 None'
    print('边界 3 通过：只有思维链时交回上层判定')

    # 边界 4：半角冒号的规范 SSE 也应能解析（向后兼容）
    standard = 'data: {"choices":[{"delta":{"content":"OK"}}]}\n\ndata: [DONE]\n\n'
    r4 = parse_lenient(standard)
    assert r4 is not None and r4['text'] == 'OK', f'规范 SSE 失败：{r4}'
    print('边界 4 通过：规范 SSE 仍可用')

    print('=' * 70)
    print('全部通过 ✔')
    print('=' * 70)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
