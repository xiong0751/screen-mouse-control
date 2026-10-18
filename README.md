# 屏幕与鼠标控制（Screen & Mouse Control）

一个 DeepSeek Harness 插件：让智能体能够**读取屏幕内容**并**操控鼠标/键盘**来操作 Windows 电脑。
提供**前台**（截图 + OCR + 真实输入）与**后台**（UI 自动化 + 窗口消息）两套方案。

当前版本 **1.1.0**。

## 工具清单

### 屏幕读取
| 工具 | 说明 |
|------|------|
| `screen_capture` | 截取整个屏幕 / 指定区域 / 全部显示器，图片直接回传给模型「看」 |
| `screen_ocr` | 一次调用完成截图 + OCR，返回全文与每个词的可点击中心坐标 (cx, cy) |
| `click_text` | 一次调用完成「截图 → OCR → 找文字 → 点击」，支持偏移点击 |
| `computer_info` | 查询屏幕边界（主屏/虚拟屏）与当前鼠标位置 |

### 鼠标
| 工具 | 说明 |
|------|------|
| `mouse_move` | 移动鼠标到指定坐标，支持平滑动画 |
| `mouse_click` | 左/中/右键单击或双击，可先移动到目标位置再点击 |
| `mouse_drag` | 按下 → 拖动 → 释放（选文本、拖窗口、拖拽） |
| `mouse_scroll` | 滚轮滚动（上下/水平），可先移动到目标窗口 |

### 键盘与剪贴板
| 工具 | 说明 |
|------|------|
| `type_text` | 向当前焦点窗口输入文本（ASCII 安全） |
| `press_keys` | 发送快捷键（`^c` 复制、`^v` 粘贴、`%{F4}` 关窗、`{ENTER}` 等） |
| `clipboard_set` / `clipboard_get` | 设置 / 读取剪贴板文本 |

### 常用快捷指令（`computer_action`，23 个动作）
- **打开**：`open`、`open_explorer`、`open_settings`、`open_task_manager`、`open_notepad`、`open_calculator`、`open_cmd`、`open_powershell`
- **电源**：`lock`、`sleep`、`hibernate`、`restart`、`shutdown`
- **音量**：`volume_up`、`volume_down`、`volume_mute`
- **显示**：`show_desktop`、`switch_display`（Win+P）、`open_screensaver`、`set_brightness`
- **系统**：`empty_recycle_bin`、`toggle_wifi`、`toggle_bluetooth`（后两者需管理员权限）

### 通用执行
| 工具 | 说明 |
|------|------|
| `run_powershell` | 以当前用户身份执行任意 PowerShell 命令并返回输出（万能后门） |

### 后台操作（不截屏 / 不移动鼠标 / 不抢焦点）
| 工具 | 说明 |
|------|------|
| `bg_list_windows` | 列出顶层窗口（pid/进程/标题/矩形） |
| `bg_find` | 按 name/type/automationId/className 查 UI 元素（UIA 元素树，无像素） |
| `bg_read` | 读取窗口/元素文本（ValuePattern/TextPattern/Name） |
| `bg_act` | 后台 click / type / keys / scroll / window 操作 |

截图与鼠标共用同一套像素坐标：智能体「看到什么位置，就点什么位置」，DPI 缩放下也保持一致。

## 目录结构

```
screen-mouse-control/
├── package.json             # bundle 清单（声明 dsh.bundle.patch）
├── cordis.patch.yml         # Loader 补丁：插入插件行
├── index.js                 # 宿主端：注册全部工具（零 npm 依赖）
├── powershell/control.ps1   # 前台：截图 + 鼠标
├── powershell/vision.ps1    # 单进程截图 + OCR；click_text
├── powershell/shortcuts.ps1 # 快捷指令 + 键盘 + 剪贴板
├── powershell/background.ps1# 后台：UI 自动化读 + 窗口消息写
├── locale/en.json           # 英文界面元数据
├── locale/zh.json           # 中文界面元数据
└── icon.svg                 # 插件图标
```

## 安装

1. 打开 DeepSeek Harness 的「插件」面板；
2. 安装本目录（`screen-mouse-control`）作为 bundle；
3. 若被插件市场的禁用列表拦截，重新启用即可（重启后生效）。

## 原理

- **宿主端** `index.js`：通过 `ctx.tools.register` 注册工具，仅使用 Node 内置模块；参数经环境变量传给 PowerShell 引擎。
- **前台引擎**：
  - `control.ps1`：`System.Drawing.CopyFromScreen` 截图，`user32.dll` 的 `SetCursorPos` / `mouse_event` 操控鼠标。
  - `vision.ps1`：单进程内「截图 + Windows 内置 OCR」（`Windows.Media.Ocr`），返回文字与屏幕坐标。
  - `shortcuts.ps1`：`Start-Process` / `SendKeys` / `user32` 实现快捷指令、键盘、剪贴板。
- **后台引擎** `background.ps1`：`System.Windows.Automation`（UI Automation）读取元素树；`user32` 的
  `PostMessage` 向窗口句柄投递鼠标/键盘/滚轮消息，**不移动光标、不注入前台输入**。

## 后台模式限制

- 对经典 Win32 / Qt 程序效果好。
- **Chromium / Electron**：页面辅助功能树只在窗口前台时暴露（后台时 `bg_find` 看不到网页元素）；
  其 UIA provider 在写值/聚焦时可能自行激活窗口，无法完全静默。需要静默自动化网页请用
  DevTools 协议（CDP）等专用方案。
- `bg_act type` 写入优先级：ValuePattern → WM_SETTEXT（有原生句柄时）→ WM_CHAR 投递（无聚焦兜底）。

## 要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带，无需额外安装）
- 管理员权限仅 `toggle_wifi` / `toggle_bluetooth` 需要

## 版本

- **1.1.0**：新增读屏 OCR、快捷指令、键盘/剪贴板、通用 PowerShell、后台自动化；修复中文编码。

## 许可证

[MIT](./LICENSE)
