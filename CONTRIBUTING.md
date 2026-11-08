# 参与墨语 / Contributing

谢谢你愿意帮忙！墨语目前由一个人维护，下面这些最有用。

## 报告打错的字

请附上：

1. 你打的拼音，原样贴出来（例如 `jintianhenmang`）；
2. 你想要的结果；
3. 候选栏里实际出现的前几个候选；
4. 用的是 26 键还是九宫格，墨语的版本号（键盘设置页最下面）。

这类问题会直接加进 [`tools/imecheck`](tools/imecheck/main.swift) 当回归测试。

## 改代码

- 没有 Mac 也能参与：fork 本仓库，推送后 GitHub Actions 会编译并跑测试。
- 新增或删除 Swift 文件后要重新生成工程：`python scripts/gen_xcodeproj.py`。
- 提交前跑一遍本地检查：`python scripts/qa/final_acceptance.py`。
- `ios/Shared` 里的代码 App 和键盘都会编译，不能引用 `ios/AIKeyboard` 或 `ios/AIKeyboardExtension` 里的东西。
- 写键盘相关的代码前，先看 [键盘扩展能力边界](docs/09-iOS键盘扩展能力边界技术约束清单.md)：很多 API 在键盘扩展里用不了。
- 改拼音引擎的打分时，`tools/dict/build_binary.py` 里的 Python 评测代码要同步改，并用 `--eval` 看整句准确率有没有变差。看没参与调参的那两组句子（HOLDOUT、UNSEEN），调参用过的那组全对不算数。

## 许可证

提交的代码按 [GPL-3.0](LICENSE) 发布。

---

## English

Thanks for helping! Moyu is maintained by one person.

- **Wrong conversions**: include the exact Pinyin you typed, the result you expected, the top candidates you saw, the layout (QWERTY or 9-key) and the version shown at the bottom of the keyboard settings. These become regression tests in `tools/imecheck`.
- **No Mac needed**: fork, push, and GitHub Actions builds the app and runs the tests.
- Run `python scripts/gen_xcodeproj.py` after adding or removing Swift files, and `python scripts/qa/final_acceptance.py` before submitting.
- Code in `ios/Shared` is compiled into both the app and the keyboard, so it must not reference code in either target.
- When changing scoring in the Pinyin engine, keep the Python benchmark in `tools/dict/build_binary.py` in sync and check the held-out sets with `--eval`.

Contributions are released under [GPL-3.0](LICENSE).
