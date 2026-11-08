<div align="center">

<img src="design/appicon/icon-180.png" width="96" alt="Moyu icon">

# Moyu (墨语)

**An open-source Chinese AI keyboard for iOS: a from-scratch Pinyin engine, plus AI you can use right inside the keyboard.**

No backend. Your API keys stay in the iPhone Keychain, and requests go straight to the provider you choose.

[中文](README.md) · [Install](#install) · [How it's built without a Mac](#4-built-without-a-mac) · [Handoff notes (Chinese)](docs/16-交接文档.md)

![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)
![Platform: iOS 16+](https://img.shields.io/badge/platform-iOS%2016%2B-lightgrey)
![Swift 5](https://img.shields.io/badge/Swift-5-orange)
![Build: GitHub Actions](https://img.shields.io/badge/build-GitHub%20Actions-2088FF)

</div>

![Moyu running in the iOS 27 simulator: QWERTY layout, AI chat, hold-space voice input, keyboard settings](docs/images/showcase.png)

<sub>These screenshots were captured by CI after it opened the Moyu keyboard in the iOS 27 simulator. Left to right: QWERTY layout, AI chat inside the keyboard, hold-space-to-talk, keyboard settings. The chat and voice text are demo content filled in by the test script.</sub>

---

## Why

Most Chinese keyboards either can't use your own AI, or send what you type to their servers. Moyu aims for:

- Pinyin typing that is good on its own, not a demo with AI bolted on;
- AI features (polish, translate, reply, draw, chat) available in any app's text field, without switching apps;
- Your own API key, so you decide what you pay for and where your text goes.

## Highlights

### 1. A Pinyin engine written from scratch

The engine doesn't depend on Rime or the system IME. It lives in [`ios/Shared/IMECore`](ios/Shared/IMECore) and serves both the QWERTY and 9-key (T9) layouts.

- **Sentence conversion**: dynamic programming over the Pinyin string picks the best segmentation. You can pick word by word, and the rest keeps converting.
- **Abbreviated sentences**: `wbzd` → 我不知道 ("I don't know"). Choices you make are learned, so after one pick `wcgl` → 我吃过了.
- **Sentence-level typo correction**: a two-layer DP allows one mistyped letter anywhere in the sentence (adjacent key, swapped letters, extra or missing letter). `jintianhebmang` → 今天很忙, `nihap` → 你好.
- **Personal dictionary**: words you typed rank higher next time, and the app lets you view, search and delete them.
- **ü and polyphones**: `lve` and `lue` both give 略. Each reading of a polyphonic character is ranked by its real frequency, so rare classical readings don't take over sentences.
- **Lexicon**: 274k entries in a memory-mapped binary file. Keyboard extensions get very little memory, so the dictionary can't be loaded whole. It's built from jieba, rime-essay, OpenCC and rime-ice by the scripts in [`tools/dict`](tools/dict).

Measured numbers, without cherry-picking:

| Metric | Result |
|---|---|
| Converting a long sentence (CI Mac) | ~1.2 ms; ~7 ms with typo correction |
| Fully correct sentences, held-out sets of 45 / 50 | 40 / 42 |
| One random typo per sentence (182 sentences) | 100 fixed and ranked first, 15 more ranked second |
| Correctly typed input wrongly "corrected" to first place | 0 of 225 |

Most remaining errors are homophones that need context (菜/才, 哪里/那里). A bigram language model is next.

### 2. AI inside the keyboard

- **Polish, translate, reply, expand**: the result replaces the original text in the field, with a choice of tone.
- **Image generation**: Seedream (Volcengine) and Wanx (Alibaba), with aspect ratio and style options. Images can be saved to Photos.
- **Chat**: chat right in the keyboard, with reasoning levels, answer length and web search (off / auto / always). One tap inserts an answer into the field.
- **AI next-sentence suggestions** in the candidate bar after you commit text.
- **11 provider presets**: DeepSeek, Qwen, Kimi, Zhipu GLM, Doubao, OpenRouter, SiliconFlow, OpenAI, Anthropic Claude, Seedream, Wanx. Pick one and paste a key. Any OpenAI-compatible endpoint and Gemini also work.
- **Robust against provider churn**: when a model is retired, Moyu looks up an available one and switches. It also tolerates gateways that break the SSE format (full-width colons, missing blank lines between events).

### 3. Working around iOS keyboard-extension limits

Keyboard extensions are among the most restricted places in iOS:

| Limit | What Moyu does |
|---|---|
| Keyboard extensions can't use the microphone | The host app runs a background voice session. The keyboard signals start/stop with Darwin notifications, and the transcript comes back through notification state values |
| Free signing has no App Group, so the app and keyboard are separate sandboxes | Tries App Group, then a Keychain access group, then a marked pasteboard handoff, and shows in the UI which path works |
| Setting the keyboard height directly is ignored | Content-driven sizing; the keyboard can be dragged taller or shorter in place (verified in the simulator) |
| Tight memory | Memory-mapped lexicon |

### 4. Built without a Mac

The author only has a Windows PC. The whole project was built without a Mac:

- **Build and package**: [GitHub Actions](.github/workflows/build.yml) compiles an unsigned IPA on macOS runners.
- **Simulator test run**: [a second workflow](.github/workflows/sim-check.yml) opens the Moyu keyboard in the iOS simulator, walks through pages and heights from a script, and uploads a screenshot of each step. The image above came from it.
- **Tests run before compiling**; the build stops if they fail:
  - [`tools/imecheck`](tools/imecheck/main.swift) runs the Pinyin engine against the real lexicon (54 checks).
  - [`tools/apicheck`](tools/apicheck/main.swift) tests the AI request logic against a fake server: model fallback, error messages, web-search parsing and more (35 checks).
- **Generated project file**: `ios/AIKeyboard.xcodeproj` is generated from the source tree by [`scripts/gen_xcodeproj.py`](scripts/gen_xcodeproj.py), so it can be maintained from Windows.

### 5. Privacy

- No server of our own, and no analytics, tracking or crash reporting.
- API keys are stored in the system Keychain.
- Typing works without Full Access; only the AI features need network access.
- Text is sent only when you use an AI feature, and only to the provider you configured.

## Install

> **Why isn't it on the App Store?** Moyu is a one-person side project. Publishing on the App Store requires the Apple Developer Program at $99 per year, which I currently can't afford. So Moyu is distributed as open source and sideloaded.

How to install today (free, but it has to be re-signed every 7 days):

1. Download a package from [Releases](https://github.com/904177233/ximake-keyboard/releases/latest). Each version has two:
   - `…-appgroup-unsigned.ipa` declares an App Group so the app and keyboard can share settings. Try this one first.
   - `…-unsigned.ipa` is for signing tools that don't support App Groups.

   For the latest development build, download the most recent run from [Actions](https://github.com/904177233/ximake-keyboard/actions/workflows/build.yml) (requires a GitHub login; files are kept for 7 days).
2. Sign and install it with your free Apple ID using SideStore, AltStore, iloader or similar.
3. Settings › General › Keyboard › Keyboards › Add New Keyboard › 墨语, then turn on Allow Full Access.
4. Open the Moyu app, go to the AI tab, pick a provider and paste your key.

## Build it yourself

```bash
python scripts/gen_xcodeproj.py          # regenerate the Xcode project after adding/removing Swift files
python scripts/qa/final_acceptance.py    # static checks, no Mac needed
python tools/dict/build_binary.py --eval # rebuild the lexicon and run the sentence benchmark
python tools/dict/typo_eval.py           # tune typo correction
```

With a Mac, open `ios/AIKeyboard.xcodeproj` in Xcode. Without one, fork the repo, push, and download the IPA from Actions.

## Roadmap

- [ ] Bigram language model for context-dependent homophones
- [ ] Testing on more devices (mainly iPhone 14 Pro / iOS 27 so far)
- [ ] Typo correction for the 9-key layout
- [ ] English UI
- [ ] TestFlight / App Store, if a developer account ever becomes affordable

## Contributing

Issues and PRs are welcome, especially: sentences that convert wrong (please include what you typed and the candidates you saw), device-specific problems, and better frequency data. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

The code is released under [GPL-3.0](LICENSE). Data sources and their licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The rime-ice data is GPL-3.0, so builds that include the lexicon are distributed under GPL-3.0 as a whole.
