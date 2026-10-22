# Agent 品牌标识

内置 Codex 与 Claude Code 标识来自 theSVG：

- https://thesvg.org/icon/codex — /icons/codex/dark.svg
- https://thesvg.org/icon/claude-code — /icons/claude-code/color.svg

标识权利归各自所有者，用于识别对应应用，不主张商标权或获得背书。

原始 SVG 与 96 像素 PNG 一并保留。无第三方依赖的 `scripts/prepare-agent-icons.py` 在交给 Apple 渲染器前展开 SVG 路径分隔符（包括紧凑弧线标志），避免 CoreSVG 误读合法紧凑语法；路径值与品牌几何形状不变。Agent 面板未复制第三方应用实现。
