# win-ui-automation

两个 PowerShell 脚本，用来给任意 Windows 桌面程序截图、点鼠标、敲键盘。纯 .NET + Win32 调用，不需要装任何东西。

起因是要自动化一个没有对外接口的 Windows 客户端。先试了 UIAutomation，发现对 Electron 壳的程序基本没用（整个窗口只暴露两个空的 Pane，拿不到任何控件名字），最后只能回到最土的办法：截图当眼睛，注入鼠标键盘当手。

## 两个脚本

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

### ui.ps1 —— 操作

```powershell
# 列出窗口。-All 会把隐藏的、托盘的窗口也列出来
.\ui.ps1 -List -All

# 激活窗口：还原 + 置前 + 抢焦点
.\ui.ps1 -Activate '记事本'

# 点击。带 -Window 就是窗口内相对坐标，不带就是屏幕绝对坐标
.\ui.ps1 -Window '记事本' -ClickAt '300,200'

# 双击 / 右键 / 滚轮
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

### 2. DPI 缩放，最坑的一个

进程默认是 DPI-unaware 的。这种状态下：

- `GetWindowRect`、`SystemInformation.VirtualScreen` 给的是**被虚拟化过的逻辑坐标**
- `SetCursorPos`、`GetPhysicalCursorPos` 用的是**物理像素**，不做虚拟化

125% 缩放下两者差 1.25 倍。表现是点击稳定落在目标的 1/1.25 处，看起来像"点不准"，其实是坐标系搞错了。

两个脚本都在开头调了 `SetProcessDpiAwarenessContext(-4)`，失败就退回 `SetProcessDPIAware()`。改完之后，全屏报 2560x1440、窗口报 `127,30 2305x1320`，跟 UIAutomation 报的坐标和 Win+PrtScn 截出来的图三方对齐了。

### 3. Chromium / Electron 会丢掉零间隔的点击

`down` 和 `up` 放在同一批 `SendInput` 里发出去，Chromium 的手势识别会当成无效事件丢掉，界面上什么都不会发生。得分成两次发，中间保持按住 60ms 左右。

### 4. 目标窗口不在前台，也就白点

点击会落到当前的前台窗口上。所以 `-ClickAt` 里加了检查：目标不在前台就先激活一次。

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

## 已知限制

- UIAutomation 对 Electron / Chromium 壳基本没用，只能靠坐标硬点
- 硬件叠加层内容（视频播放器、部分 GPU 合成画面）用 `CopyFromScreen` 或 `PrintWindow` 可能截成黑屏或空白
- 输入注入用的是真实的系统光标和键盘焦点，脚本运行期间会占用你的鼠标键盘
- 只在 Windows 11 + Windows PowerShell 5.1 上验证过

## 环境说明

Windows 11，Windows PowerShell 5.1。

注意不是 PowerShell 7。这两个版本有些参数不通用，比如 `Invoke-WebRequest -NoProxy`、`Select-Object -Reverse` 都只有 7 才有，写在 5.1 里会直接报参数找不到。
