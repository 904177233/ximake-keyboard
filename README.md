<div align="center">

<img src="design/appicon/icon-180.png" width="96" alt="墨语图标">

# 墨语 Moyu

**一个开源的 iOS 中文 AI 输入法：自己写的拼音引擎，加上键盘里直接能用的 AI。**

没有后端，API Key 只存在你手机的钥匙串里，请求直连你自己选的服务商。

[English](README.en.md) · [安装](#安装) · [构建](#没有-mac-怎么开发) · [交接文档](docs/16-交接文档.md)

![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)
![Platform: iOS 16+](https://img.shields.io/badge/platform-iOS%2016%2B-lightgrey)
![Swift 5](https://img.shields.io/badge/Swift-5-orange)
![Build: GitHub Actions](https://img.shields.io/badge/build-GitHub%20Actions-2088FF)

</div>

![墨语在 iOS 27 模拟器里的截图：26 键、AI 对话、长按空格说话、键盘设置](docs/images/showcase.png)

<sub>上图是 CI 在 iOS 27 模拟器里真的弹出墨语键盘后自动截的图，从左到右：26 键、键盘里的 AI 对话、长按空格说话、键盘设置。对话和语音里的文字是测试脚本填的演示内容。</sub>

---

## 为什么做这个

市面上的中文输入法要么不能接自己的 AI，要么要把你打的字传到它们的服务器。墨语想做的是：

- 拼音打字本身要好用，不能因为加了 AI 就变成半成品；
- AI 功能在任何 App 的聊天框里都能直接用（润色、翻译、回复、画图、对话），不用来回切 App；
- 用你自己的 Key，钱花在哪、字发给谁，你自己说了算。

## 亮点

### 1. 自己写的拼音引擎

不依赖 Rime 或系统输入法，内核在 [`ios/Shared/IMECore`](ios/Shared/IMECore)，26 键和九宫格共用一套。

- **整句转换**：在拼音串上做动态规划，找分数最高的切法；可以逐词选，选一个词，剩下的拼音接着转换。
- **简拼整句**：`wbzd` → 我不知道，`wcgl` 选过一次「我吃过了」以后就排第一。
- **整句纠错**：整句 DP 分两层，允许句子里有一个字母打错（按到相邻键、两个字母打反、多打、少打）。`jintianhebmang` → 今天很忙，`nihap` → 你好。
- **个人词库**：打过的词下次排在前面，App 里可以查看、搜索、删除。
- **ü 和多音字**：`lve` / `lue` 都能打出「略」；多音字的每个读音按真实字频排序，不会让古音冒出来抢位置。
- **词库**：27.4 万词条，做成内存映射的二进制文件（键盘扩展能用的内存很少，不能整个读进来）。数据来自 jieba、rime-essay、OpenCC、rime-ice，构建脚本在 [`tools/dict`](tools/dict)。

数字都是实测的，不挑好看的说：

| 项目 | 结果 |
|---|---|
| 长句一次转换（CI 的 Mac 上） | 约 1.2 毫秒；带纠错约 7 毫秒 |
| 没参与调参的 45 句 / 50 句整句全对 | 40 / 42 句 |
| 每句随机打错一个字母（182 句） | 100 句纠对并排第一，另有 15 句排第二 |
| 打对的句子被误纠成首选 | 225 条里 0 条 |

剩下的错误大多是同音字要看上下文（菜 / 才、哪里 / 那里），下一步要做二元语言模型。

### 2. 键盘里直接用 AI

- **润色、翻译、回复、扩写**：结果直接替换输入框里的原文；可以选语气。
- **画图**：即梦（Seedream）、通义万相，可以选画幅和风格，画过的图能存进相册。
- **对话**：键盘里就能聊，有推理档位、回答长短、联网搜索（关 / 自动 / 总是），回答一键放进输入框。
- **AI 猜下一句**：上屏后在候选栏给出可能的下一句。
- **11 家服务商预设**：DeepSeek、通义千问、Kimi、智谱、豆包、OpenRouter、硅基流动、OpenAI、Anthropic Claude、即梦、通义万相。选一家、粘贴 Key 就能用，也支持任何 OpenAI 兼容接口和 Gemini。
- **抗折腾**：模型名下线了会自动查可用模型换上；兼容不守 SSE 规范的网关（全角冒号、分片之间没空行这种）。

### 3. 绕开 iOS 键盘扩展的限制

键盘扩展是 iOS 里限制最多的地方，很多「理所当然」的功能都得绕路：

| 限制 | 墨语的做法 |
|---|---|
| 键盘扩展不能用麦克风 | 宿主 App 开一个后台语音会话，键盘用 Darwin 通知喊开始/结束，识别结果经系统通知的状态值传回键盘 |
| 免费签名没有 App Group，App 和键盘是两个隔离的沙盒 | 依次尝试 App Group、钥匙串访问组、剪贴板标记，并在界面上如实显示是否打通 |
| 直接给键盘设高度会被系统忽略 | 用内容把高度撑起来，键盘可以在键盘上直接拖高拖低（模拟器实测） |
| 内存很紧 | 词库用内存映射，不整块读入 |

细节见 [docs/09-iOS键盘扩展能力边界技术约束清单.md](docs/09-iOS键盘扩展能力边界技术约束清单.md)。

### 4. 没有 Mac 怎么开发

作者只有一台 Windows 电脑，整个项目是在没有 Mac 的情况下做出来的：

- **编译和打包**：推到 GitHub，[Actions](.github/workflows/build.yml) 用 macOS 机器编译出未签名的 IPA。
- **模拟器实测**：[另一个工作流](.github/workflows/sim-check.yml)在 iOS 模拟器里真的弹出墨语键盘，按脚本走一遍各个页面和高度，每一步截图上传。上面那张图就是这么来的。
- **测试先跑**：编译之前先跑两套测试，失败就不往下编。
  - [`tools/imecheck`](tools/imecheck/main.swift)：用真词库跑拼音内核，54 项检查。
  - [`tools/apicheck`](tools/apicheck/main.swift)：用假服务器测 AI 请求逻辑（换模型、报错、联网搜索解析等），35 项检查。
- **工程文件是生成的**：`ios/AIKeyboard.xcodeproj` 由 [`scripts/gen_xcodeproj.py`](scripts/gen_xcodeproj.py) 从源码树生成，Windows 上也能改。

### 5. 隐私

- 没有自己的服务器，没有统计、埋点或崩溃上报。
- API Key 存在系统钥匙串里。
- 不开「完全访问」也能正常打字，只是 AI 连不上网。
- 只有你点了 AI 功能时，相关文字才会发给你自己配置的服务商。

## 安装

> **为什么不在 App Store？** 墨语是我一个人业余做的。上架 App Store 需要加入 Apple Developer Program，每年 99 美元，这笔钱我目前负担不起，所以墨语只能以开源加侧载的方式发布。

现在的安装方式（免费，但每 7 天要重签一次）：

1. 在本仓库的 [Actions](https://github.com/904177233/ximake-keyboard/actions/workflows/build.yml) 里打开最近一次成功的构建，下载 `AIKeyboard-unsigned-ipa`。里面有两个包：
   - `AIKeyboard-appgroup-unsigned.ipa`：带 App Group 声明，App 和键盘能共享设置，优先用这个；
   - `AIKeyboard-unsigned.ipa`：签名工具不支持 App Group 时用这个。

   下载 Actions 里的文件要先登录 GitHub，文件保留 7 天。过期了可以 fork 本仓库，自己跑一次构建。
2. 用 SideStore、AltStore、iloader 等工具，以自己的免费 Apple ID 签名装到 iPhone。
3. 设置 › 通用 › 键盘 › 键盘 › 添加新键盘 › 墨语，打开「允许完全访问」。
4. 打开墨语 App，在「AI」页选一家服务商、粘贴 Key。

详细步骤和常见问题：[安装与续签指南](docs/04-安装与续签指南.md) · [常见问题](docs/05-常见问题.md)。

## 自己构建

```bash
# 新增或删除 Swift 文件后，重新生成 Xcode 工程
python scripts/gen_xcodeproj.py

# 本地静态检查（不需要 Mac）
python scripts/qa/final_acceptance.py

# 重新生成词库并跑整句评测（需要先下载数据，见 docs/16-交接文档.md）
python tools/dict/build_binary.py --eval

# 纠错调参
python tools/dict/typo_eval.py
```

有 Mac 的话直接用 Xcode 打开 `ios/AIKeyboard.xcodeproj`。没有 Mac 就 fork 本仓库，推送后在 Actions 里拿安装包。

## 目录

```
ios/
├── Shared/                 App 和键盘都编译
│   ├── IMECore/            拼音引擎
│   ├── Networking/         AI 请求：OpenAI 兼容 / Anthropic / Gemini，即梦 / 万相，联网搜索
│   ├── Voice/              App 和键盘之间的语音通道
│   ├── Storage/            配置、钥匙串、App 和键盘共享
│   └── dict/               词库（生成的二进制文件）
├── AIKeyboard/             宿主 App
└── AIKeyboardExtension/    键盘扩展
tools/dict/                 词库构建、整句评测、纠错调参
tools/imecheck/             拼音内核回归测试
tools/apicheck/             AI 请求逻辑测试（假服务器）
scripts/                    工程生成、静态检查、CI 辅助
docs/                       设计文档、限制清单、交接文档
```

## 接下来想做的

- [ ] 二元语言模型，解决同音字要看上下文的问题
- [ ] 更多真机型号上的测试（目前主要在 iPhone 14 Pro / iOS 27 上用）
- [ ] 九宫格的纠错
- [ ] 英文界面
- [ ] 如果有一天能负担开发者账号，上架 TestFlight / App Store

## 参与

欢迎提 Issue 和 PR，尤其是：打错的整句（请附上你打的拼音和看到的候选）、不同机型上的问题、更好的词频数据。参与方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

代码以 [GPL-3.0](LICENSE) 发布。词库数据的来源和各自的许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。其中 rime-ice 的数据是 GPL-3.0，所以带词库的安装包整体也按 GPL-3.0 分发。
