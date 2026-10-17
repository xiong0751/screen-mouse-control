# 屏幕与鼠标控制（Screen & Mouse Control）

一个 DeepSeek Harness 插件：让智能体能够**截取电脑屏幕**并**操控鼠标**来操作电脑（Windows）。

## 功能

安装后，智能体会获得以下工具：

| 工具 | 说明 |
|------|------|
| `screen_capture` | 截取整个屏幕 / 指定区域 / 全部显示器，图片直接回传给智能体「看」 |
| `computer_info` | 查询屏幕边界（主屏/虚拟屏）与当前鼠标位置 |
| `mouse_move` | 移动鼠标到指定坐标，支持平滑动画 |
| `mouse_click` | 左/中/右键单击或双击，可先移动到目标位置再点击 |
| `mouse_drag` | 按下 → 拖动 → 释放（选文本、拖窗口、拖拽） |
| `mouse_scroll` | 滚轮滚动（上下/水平），可先移动到目标窗口 |

截图与鼠标共用同一套像素坐标：智能体「看到什么位置，就点什么位置」，DPI 缩放下也保持一致。

## 目录结构

```
screen-mouse-control/
├── package.json            # bundle 清单（声明 dsh.bundle.patch）
├── cordis.patch.yml        # Loader 补丁：插入插件行
├── index.js                # 宿主端：注册智能体工具（零 npm 依赖）
├── powershell/control.ps1  # 原生引擎：截图 + 鼠标控制
├── locale/en.json          # 英文界面元数据
├── locale/zh.json          # 中文界面元数据
└── icon.svg                # 插件图标
```

## 安装

1. 打开 DeepSeek Harness 的「插件」面板；
2. 安装本目录（`screen-mouse-control`）作为 bundle。

安装后无需重启（新 bundle 可通过 HMR 激活），智能体即可调用上述工具。

## 原理

- **宿主端** `index.js`：通过 `ctx.tools.register` 注册工具，仅使用 Node 内置模块；截图经
  `ctx.attachments.saveImage` 作为图片附件回传给模型（超过图片上限时自动降级为更小的 JPEG）。
- **原生引擎** `powershell/control.ps1`：调用 Windows PowerShell 5.1 的
  `System.Drawing.CopyFromScreen` 截图、`user32.dll` 的 `SetCursorPos` / `mouse_event` 操控鼠标。
- 参数通过环境变量传递，避免命令注入问题。

## 要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带，无需额外安装）

## 许可证

[MIT](./LICENSE)
