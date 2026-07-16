# 珍珠小子独立桌宠 App / Standalone Desktop Pet

不开 Codex 也能让珍珠小子待在桌面上：单文件 Swift/AppKit 原生 App，零依赖，
直接读取本仓库的 `bead-girl/spritesheet.webp`（Codex pet 标准 8 列 × 9 行图集，
每格 192×208），按 Codex 官方的帧时长逐帧播放。

## 构建

```bash
cd desktop-app
./build.sh
```

产物为 `~/Desktop/珍珠小子.app`，双击启动。无 Dock 图标；右键宠物可退出。

## 行为

- 常驻 idle 待机动画（呼吸、眨眼）
- 每 20–50 秒随机小动作：散步（窗口真实移动）、挥手、跳跃、干活、等待、张望，偶尔沮丧
- **鼠标 hover** → 抱抱（需要扩展雪碧图第 10 行；没有时暂用挥手代替）
- 按住拖动可搬家；右键菜单：打招呼 / 跳一跳 / 去散步 / 认真干活 / 换体型（小中大）/ 退出

## 待办（暂停中）

两组新动画帧还没生成，生成方式待定（Codex 生成 / 代码拼合 / OpenAI API）：

1. **认真干活**：替换第 7 行（running/work）为「面对电脑打字」的姿势
2. **抱抱**：新增第 10 行（hug，6 帧，时长 160×5 + 300ms），hover 时循环播放

App 端逻辑已就绪：加载器自动识别 9 行或 10 行图集（10 行版命名为
`bead-girl/spritesheet-extended.webp`，build.sh 会优先打包它），有 hug 行时
hover 自动切换为抱抱。
