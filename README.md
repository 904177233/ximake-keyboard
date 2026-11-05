# 墨语（Moyu）

一个 iOS 第三方输入法：中文拼音 + AI。零后端，API Key 只存在手机里，直连你自己的服务商。

- 拼音：26 键和九宫格，全拼、简拼、混拼，模糊音，逐词选词，记住常打的词
- AI：润色、翻译、回复、扩写、画图、键盘内对话、猜下一句
- 服务商：任何 OpenAI 兼容接口，加上 Anthropic、Gemini；画图支持即梦和通义万相
- 主题：六套双色主题，浅色深色都有，空格键上可以放自己的小形象

先看效果：浏览器打开 [design/prototype-v3.html](design/prototype-v3.html)，能直接打字。

## 目录

```
ios/
├── Shared/               App 和键盘都编译
│   ├── IMECore/          拼音内核
│   ├── Networking/       AI 请求（三家协议 + 三家画图）
│   ├── Models/  Prompts/  Storage/
│   ├── Theme/            主题和颜色，全项目唯一来源
│   └── dict/             词库
├── AIKeyboard/           宿主 App
└── AIKeyboardExtension/  键盘扩展
tools/dict/               词库生成
tools/imecheck/           内核回归测试（云编译时运行）
```

## 构建

没有 Mac 也能构建：推到 GitHub，Actions 用 macOS 编译出未签名 IPA，再用 iloader 签名安装。

新增或删除 Swift 文件后要重新生成工程：

```
python scripts/gen_xcodeproj.py
```

本地检查：

```
python scripts/qa/final_acceptance.py
```

改词库：

```
python tools/dict/build_binary.py --eval
```

## 文档

- [交接文档](docs/16-交接文档.md)：这次重做了什么，还有什么没验证
- [安装与续签](docs/04-安装与续签指南.md)
- [常见问题](docs/05-常见问题.md)
- [键盘扩展能力边界](docs/09-iOS键盘扩展能力边界技术约束清单.md)：写代码前必读
- `docs/archive/`、`design/archive/`：旧版文档，只作参考
