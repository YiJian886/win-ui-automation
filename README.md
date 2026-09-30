# win-ui-automation

三个 PowerShell 脚本，用来给任意 Windows 桌面程序截图、找控件、点鼠标、敲键盘。纯 .NET + Win32 调用，默认不需要装任何东西。

起因是要自动化一个没有对外接口的 Windows 客户端。先试了 UIAutomation，发现对 Electron 壳的程序基本没用（整个窗口只暴露两个空的 Pane，拿不到任何控件名字），最后只能回到最土的办法：截图当眼睛，注入鼠标键盘当手。

后来发现"最土的办法"不该是唯一办法 —— 见下面「控件树优先，画面兜底」那节。

## 三个脚本

### screenshot.ps1 —— 截图

```powershell
# 截整个虚拟桌面（多显示器一起）
.\screenshot.ps1

# 列出所有可见窗口
.\screenshot.ps1 -List

# 按标题正则截某个窗口。用 PrintWindow，窗口被别的窗口挡住也能截到
.\screenshot.ps1 -Window '记事本'

# 截屏幕上一块矩形
.\screenshot.ps1 -Region 0,0,800,600
```

### ui.ps1 —— 操作和找控件

```powershell
# 列出窗口。-All 会把隐藏的、托盘的窗口也列出来
.\ui.ps1 -List -All

# 激活窗口：还原 + 置前 + 抢焦点
.\ui.ps1 -Activate '记事本'

# 按名字找控件（默认先查控件树，查不到再认画面）
.\ui.ps1 -Window '记事本' -FindElement '保存'

# 按名字点控件
.\ui.ps1 -Window '记事本' -ClickElement '保存'

# 强制只走画面识别（对付控件树是空的程序）
.\ui.ps1 -Window '某Electron应用' -ClickElement '设置' -Strategy vision

# 按坐标点。带 -Window 是窗口内相对坐标，不带是屏幕绝对坐标
.\ui.ps1 -Window '记事本' -ClickAt '300,200'
.\ui.ps1 -Window '记事本' -ClickAt '300,200' -DoubleClick
.\ui.ps1 -Window '记事本' -ClickAt '300,200' -RightClick
.\ui.ps1 -Window '记事本' -ClickAt '300,200' -Scroll -3

# 打字。走 SendInput 的 Unicode 通道，中文直接打，不经过输入法
.\ui.ps1 -Type '你好，世界'

# 按键，支持组合
.\ui.ps1 -Key 'enter'
.\ui.ps1 -Key 'ctrl+a'

# 拖拽
.\ui.ps1 -Drag '100,100,400,400'

# 只移动鼠标 + 滚轮，不点击。翻长列表用这个，避免误触到列表项
.\ui.ps1 -Window '记事本' -ScrollAt '300,400' -Scroll -5
```

### guard.ps1 —— 操作保护闸

自动化跟人抢鼠标是很讨厌的事。`ui.ps1` 默认会先调它，确认真人已经有一段时间
没碰过电脑才动手。

```powershell
# 人现在在用电脑吗？真人静默多久了？
.\guard.ps1 -Status

# 等到真人连续 10 秒没碰键鼠
.\guard.ps1 -WaitIdle 10

# 观察 5 秒，看有没有真人输入（验证钩子有没有用）
.\guard.ps1 -Watch 5
```

`ui.ps1` 里对应两个开关：

```powershell
# 默认就是这样：动手前先等真人静默 10 秒
.\ui.ps1 -Window '记事本' -ClickElement '保存'

# 确实没人在用，跳过保护
.\ui.ps1 -Window '记事本' -ClickElement '保存' -GuardSeconds 0

# 改等待时长 / 超时
.\ui.ps1 -Window '记事本' -ClickElement '保存' -GuardSeconds 5 -GuardTimeout 60
```

### vision.ps1 —— 从画面里认元素

```powershell
# 截记事本，认出上面所有文字和坐标
.\vision.ps1 -Window '记事本'

# 只看名字里带"保存"的
.\vision.ps1 -Window '记事本' -Match '保存'

# 输出 JSON，给别的程序吃
.\vision.ps1 -Image .\shots\a.png -Json

# 用 OmniParser 后端（需要自己起服务，见下）
.\vision.ps1 -Window '某应用' -Backend omniparser
```

## 怎么找到要点的东西：控件树优先，画面兜底

这是这套脚本最核心的设计，也是踩了坑才想明白的。

同一台机器上我测了两个程序：

| 程序 | 内核 | UI Automation 能读到什么 |
|---|---|---|
| Microsoft Edge | Chromium | **40 个**可交互元素，带名字、AutomationId、精确坐标 |
| 某 Electron 客户端 | Electron | **1 个**元素，0 个有名字。等多久都一样 |

区别不在"是不是 Chromium"，而在**辅助功能树有没有被打开**。Edge 默认开着，很多 Electron 应用默认关着。关掉的时候，UIA 里就是一片空白。

所以 `-FindElement` / `-ClickElement` 的策略是：

1. **先查控件树**。有名字就能直接定位，坐标是程序自己报的，不受窗口遮挡、缩放、滚动影响。
2. **查不到就认画面**。截一张图，用 OCR 把文字和坐标认出来，按文字找。这条路不依赖目标程序配合，代价是慢、且只能认到"看得见的东西"。
3. 两条都没有，报错，提示你换 `-Strategy` 试试。

`-Strategy uia` 强制只走控件树，`-Strategy vision` 强制只走画面，默认 `auto` 是先控件树后画面。

控件树那条路还会优先用 `InvokePattern` 直接触发控件，比模拟点击可靠（窗口被挡住也不影响）；不能 Invoke 才退回点坐标。

另外控件树里那些**滚出可视区的元素**会被过滤掉 —— 页面上同名文字一抓一大把，不过滤就可能点到屏幕外面去（坐标是很大的负数）。

### 视觉后端：OCR 还是 OmniParser

`vision.ps1` 有两个后端：

**ocr**（默认）用的是 Windows 自带的 `Windows.Media.Ocr`。零依赖，不用装东西，能认出屏幕上的所有文字和位置。找按钮靠的就是按钮上的字。

**omniparser** 用微软的 [OmniParser](https://github.com/microsoft/OmniParser)，除了文字还能认出**图标**，并给图标生成语义描述（"放大镜"、"齿轮"之类）。它是个 Python 模型，脚本这边只负责发 HTTP 请求，服务得你自己起：

```powershell
# 起好服务后，默认连 http://127.0.0.1:7860
$env:OMNIPARSER_URL = 'http://127.0.0.1:7860'
.\vision.ps1 -Window '某应用' -Backend omniparser
```

现成的部署方式有 [addy999/omniparser-api](https://github.com/addy999/omniparser-api)（Docker 镜像，起了就有 `/process_image` 接口）。`-Backend auto` 会先探一下服务在不在，连不上就自动退回 ocr，不会卡住。

**说清楚代价**：OmniParser 官方 `requirements.txt` 拉了 torch、torchvision、easyocr、paddlepaddle、paddleocr、transformers、ultralytics、opencv……外加一堆跟推理无关的（anthropic、boto3、groq、gradio、streamlit）。几个 GB，而且钉在 `numpy==1.26.4`、`openai==1.3.5` 这种老版本上。真要装建议单独开 Python 3.12 的 conda/uv 环境，别往系统 Python 里灌。

## 怎么跑

系统默认的执行策略是 Restricted，直接跑 .ps1 会被拦。逐次加 Bypass 就行，不用去改系统设置：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\screenshot.ps1 -List
```

## 踩过的坑

这部分大概比脚本本身有用。

### 1. 写 .ps1 必须存成 UTF-8 带 BOM

Windows PowerShell 5.1 读 .ps1 是按 ANSI 解码的，中文系统上就是 GBK。文件不带 BOM 的话，中文注释和字符串会全部变成乱码，而且是语法级报错——麻烦的是报错信息本身也是乱码，很难看出真正原因。

补 BOM：

```powershell
$c = Get-Content -Raw -Encoding UTF8 .\x.ps1
[System.IO.File]::WriteAllText((Resolve-Path .\x.ps1), $c, (New-Object System.Text.UTF8Encoding($true)))
```

写这个 README 的过程中我又踩了两次，一次是临时诊断脚本，一次是复现脚本。**用别的工具生成 .ps1 之后一定要检查前三个字节是不是 239,187,191。**

### 2. DPI 缩放，最坑的一个

进程默认是 DPI-unaware 的。这种状态下：

- `GetWindowRect`、`SystemInformation.VirtualScreen` 给的是**被虚拟化过的逻辑坐标**
- `SetCursorPos`、`GetPhysicalCursorPos` 用的是**物理像素**，不做虚拟化

125% 缩放下两者差 1.25 倍。表现是点击稳定落在目标的 1/1.25 处，看起来像"点不准"，其实是坐标系搞错了。

三个脚本都在开头调了 `SetProcessDpiAwarenessContext(-4)`，失败就退回 `SetProcessDPIAware()`。改完之后，全屏报 2560x1440、窗口报 `127,30 2305x1320`，跟 UIAutomation 报的坐标和 Win+PrtScn 截出来的图三方对齐了。

### 3. Chromium / Electron 会丢掉零间隔的点击

`down` 和 `up` 放在同一批 `SendInput` 里发出去，Chromium 的手势识别会当成无效事件丢掉，界面上什么都不会发生。得分成两次发，中间保持按住 60ms 左右。

### 4. 目标窗口不在前台，也就白点

点击会落到当前的前台窗口上。所以 `-ClickAt`、`-ClickElement` 里都加了检查：目标不在前台就先激活一次。

激活不能只调 `SetForegroundWindow`，Windows 有前台窗口锁定，得先用 `AttachThreadInput` 把当前前台窗口的线程和自己的线程接上，再调才有效。

### 5. 组合键的修饰键必须 try/finally 释放

这个我真踩了：`-Key 'win+printscreen'` 的释放循环里写了个 PowerShell 7 才有的参数，报错中断，结果 **Win 键按下去没抬起来**，之后所有按键都变成系统快捷键了。

现在按下和释放包在 `try/finally` 里，出错也一定会把修饰键放开。写这类注入代码，修饰键和鼠标按键都一样，别图省事。

### 6. 窗口全黑，不一定是防录屏

有个程序截出来整片纯色。第一反应是它开了防录屏，查 `GetWindowDisplayAffinity` 返回 0，没开。

真实原因是那程序当时在托盘里休眠，窗口壳还在，但里面的渲染器没醒。杀掉进程重开就正常了。

建议的排查顺序：先查 `GetWindowDisplayAffinity`，再试一次 Win+PrtScn（走的是系统自己的截图通道，跟 BitBlt 不是一条路），最后再考虑重启目标程序。

### 7. 坐标别在缩略图上量

把截图缩小以后目测坐标很容易看错行。要么裁 1:1 的原图量，要么把那一小块放大再看。

### 8. 函数返回单个对象时，`.Count` 是空的

这个坑了我半天，值得单独说。

PowerShell 函数 `return @($x)`，如果 `$x` 里只有一个元素，返回时会**展开成标量**。然后 `$vis.Count` 不是 1，而是**空**（`$null`），`if ($vis.Count)` 直接判假，于是"明明找到了却说找不到"。

解决办法：调用点套一层 `@()`。

```powershell
$vis = @(Get-VisionElements ...)   # 这样 .Count 才是可靠的
if ($vis.Count) { ... }
```

### 9. 脚本之间互相调用时，多行输出会变成字符串数组

`ui.ps1` 会调 `vision.ps1` 拿 JSON。脚本输出的多行字符串被 PowerShell 捕获时是**字符串数组**，直接丢给 `ConvertFrom-Json` 会失败（报 `InputObject is null`）。

先拼回去：

```powershell
$parsed = (@($json) -join "`n") | ConvertFrom-Json
```

单独在命令行跑 `vision.ps1` 不会遇到这个问题，只有进程内互相调用才会，所以特别隐蔽。

### 10. 分清"人操作"和"自己注入的操作"

做操作保护的时候需要的：怎么知道用户正在用电脑？

- `GetLastInputInfo` 能给"上次输入是多久以前"，但它**把 SendInput 注入的也算进去**，
  所以自动化自己点一下，它立刻认为"刚刚有人操作"，会把自己无限卡住。
- 正解是挂全局低级钩子（`WH_MOUSE_LL` / `WH_KEYBOARD_LL`），钩子事件的
  `LLMHF_INJECTED` / `LLKHF_INJECTED` 标志位能区分来源。
- 但钩子只有"装上之后"的视野，没有历史，而每次调用都是新进程。
  所以再配一个状态文件记录"注入时刻"和"已确认的真人输入时刻"，
  下次就能算出真人到底静默了多久，不用每次白等。

实测：观察 10 秒期间注入 3 次点击，钩子报告"没有真人输入"，过滤是准的。

### 11. tick 是无符号 32 位，会回绕

`GetTickCount()` 返回 `uint32`，49.7 天回绕一次。算时间差时如果直接
`[uint32]($now - $then)`，一旦 `$then > $now` 就会算出负数，强转 `uint32` 抛异常。
在 `$ErrorActionPreference = 'Stop'` 下这个异常会把整个等待循环打断，
表现是"保护莫名其妙直接超时"。

```powershell
$d = [int64]$Now - [int64]$Then
if ($d -lt 0) { $d += 4294967296 }
return [uint32]($d % 4294967296)
```

## 类似的轮子

写完之后搜了一圈，这个方向项目很多。按类别列一下，省得你重复造。

**Windows MCP 服务器**（跟这套东西最像，但走 MCP 协议）

- [sbroenne/mcp-windows](https://github.com/sbroenne/mcp-windows) —— C#/.NET，MIT。它的 README 里有一节直接叫 "Why not just use screenshots?"，观点跟截图路线正相反：能读控件属性就别靠看图。它列了对比表（找按钮、读表格、看勾选框状态），核心论据是 **token 更省、更可靠**。这个批评是成立的。
- [RandyNorthrup/win32-mcp-server](https://github.com/RandyNorthrup/win32-mcp-server)、`orangeenterprisesinc/windows-automation-mcp`（基于 FlaUI）等一批同类。

**电脑操控代理框架**（完整的"截图→决策→执行"闭环）

- [google-gemini/computer-use-preview](https://github.com/google-gemini/computer-use-preview)
- [e2b-dev/open-computer-use](https://github.com/e2b-dev/open-computer-use)
- [injaenity/pi-computer-use](https://github.com/injaenity/pi-computer-use) —— 支持 Windows
- [showlab/computer_use_ootb](https://github.com/showlab/computer_use_ootb) —— Windows + macOS 开箱即用
- [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux) —— Linux 版

这套脚本大致相当于它们最底下那一层（截图 + 注入）。

**经典 GUI 自动化库**

- [AutoHotkey/AutoHotkey](https://github.com/AutoHotkey/AutoHotkey) —— Windows 宏/自动化老牌工具
- [asweigart/pyautogui](https://github.com/asweigart/pyautogui) —— Python 跨平台，事实标准
- [pywinauto/pywinauto](https://github.com/pywinauto/pywinauto) —— Python，基于控件属性，跟 mcp-windows 一路
- [Hello-Mr-Crab/pywechat](https://github.com/Hello-Mr-Crab/pywechat) —— 微信 RPA，用 pywinauto 实现

**纯视觉元素识别**

- [microsoft/OmniParser](https://github.com/microsoft/OmniParser) —— 把界面截图解析成结构化元素列表。社区部署：[addy999/omniparser-api](https://github.com/addy999/omniparser-api)（Docker + FastAPI）、[NON906/omniparser-autogui-mcp](https://github.com/NON906/omniparser-autogui-mcp)（OmniParser + pyautogui + MCP）
- [showlab/Awesome-GUI-Agent](https://github.com/showlab/Awesome-GUI-Agent) —— 论文合集

### 那这套东西还留着干什么

功能上它是最小内核，上面任何一个的头部项目都是它的超集。差别在这几点：

1. **零依赖**。Windows 自带 PowerShell 5.1 就能跑，不用 Python、不用 .NET SDK、不用 npm。上面那一堆基本都要先配环境。
2. **就三个文件，几十 KB**。可以随手塞进任何机器。
3. **两条路都留着**。mcp-windows 那类只走控件树，遇到 Electron 壳直接没辙；纯坐标那类又浪费了规范程序给出的信息。这里默认先控件树、不行就认画面，两头都占。
4. **DPI 那个坑写透了**。翻了一圈这些项目的文档，很少见到明确讲 `SetCursorPos` 用物理像素而 `GetWindowRect` 给虚拟化坐标的。

想正经做项目，该用 `pyautogui`（要 Python）或 `mcp-windows`（要 .NET，走 MCP，token 更省）。这套更适合：没 Python 环境、不让装东西、或者目标程序是 UIA 啃不动的壳子。

## 已知限制

- 控件树那条路依赖目标程序打开辅助功能，Electron 应用默认是关的
- 视觉那条路只能认到"当前画面上看得见的东西"，滚动、遮挡、动画都会影响
- 视觉后端只认文字和坐标，不理解语义（"那个蓝色的按钮"这种说不出来）
- 硬件叠加层内容（视频播放器、部分 GPU 合成画面）用 `CopyFromScreen` 或 `PrintWindow` 可能截成黑屏或空白
- 输入注入用的是真实的系统光标和键盘焦点，脚本运行期间会占用你的鼠标键盘
- 只在 Windows 11 + Windows PowerShell 5.1 上验证过

## 环境说明

Windows 11，Windows PowerShell 5.1。

注意不是 PowerShell 7。这两个版本有些参数不通用，比如 `Invoke-WebRequest -NoProxy`、`Select-Object -Reverse` 都只有 7 才有，写在 5.1 里会直接报参数找不到。
