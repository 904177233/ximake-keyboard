# premium-ui-motion

将模糊的高级 UI / 动画需求转为可执行提示词、设计规范或前端实现。

## 使用

已放在项目的 `.agents/skills/` 中，DeepSeek Harness 能自动发现。新会话中直接说：

- `用 premium-ui-motion，把这个页面改得高级一些，保留现有功能。`
- `用 premium-ui-motion，给 SaaS 官网写一段瑞士排版风格的完整设计提示词。`
- `用 premium-ui-motion，为任务卡加入 180ms 的状态切换和 reduced-motion 降级。`

不指定名称时，提出“高级感 UI、玻璃拟态、精致动画、设计提示词”等需求也会匹配。

## 文件

- `SKILL.md`：工作流程、参数化动效规范、可复制的提示词模板。
- `references/style-atlas.md`：33 种设计风格选择速查。
- `references/quality-checklist.md`：内容、动效、响应式、无障碍与实现验收。

风格方法参考 [SPICYTATER AI 协作表达指南](https://spicytater.cn/terms/catalog/design-styles)。此 Skill 是方法提炼与独立编写，不复制其页面或代码。
