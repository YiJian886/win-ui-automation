# AGENTS.md

给在这个仓库里干活的 AI agent 看的。人也可以读。

## 这是什么

一套纯 PowerShell 的 Windows 桌面自动化工具：截图、找控件、点鼠标、敲键盘。
四个脚本 + 一个共用模块，零外部依赖（Windows 自带的 PowerShell 5.1 就能跑）。

| 文件 | 干什么 |
|---|---|
| `screenshot.ps1` | 截图：全屏 / 按标题截窗口 / 矩形 |
| `ui.ps1` | 操作：点击、打字、按键、拖拽，以及按名字找控件（批量模式也在这） |
| `vision.ps1` | 从截图里认元素：Windows 自带 OCR 或 OmniParser |
| `guard.ps1` | 操作保护闸：动手前确认用户已经有一阵子没碰键鼠 |
| `native.ps1` | C# 编译缓存，被上面几个 dot-source，不用直接调 |

**动手改之前先通读 `README.md`** —— 踩过的坑全在里面，尤其是「踩过的坑」那一节。

## 怎么跑

```powershell
# 执行策略默认是 Restricted，必须带 Bypass
powershell -NoProfile -ExecutionPolicy Bypass -File .\ui.ps1 -List
```

## 用这套工具时的规矩

这些是从实际翻车里总结出来的，不是理论。

1. **别猜坐标。** 先 `-FindElement` 或 `-ClickElement` 按名字找。
   实在要用坐标，也必须从 **1:1 的原图**上量 —— 把截图缩小之后目测，
   看错一行是常事（README 里有个真实案例：`我的` 按钮估成 y=515，实际 y=408，
   正好落在两行之间，白跑一轮）。
2. **多步操作用批量模式。** 一次进程跑完一串，比逐个调用快 37%，
   而且省掉每次的进程启动开销。
3. **别绕过 `-GuardSeconds`。** 默认会等用户静默 10 秒再动手，
   这是防止跟人抢鼠标的。调试时可以临时设 0，但别写进正式脚本。
4. **干完把焦点还回去。** 单次调用会自动还原；如果用 `-Activate` 切走了，
   收尾跑一句 `-RestoreFocus`。用户被晾在别的程序里是很讨厌的事。
5. **找控件优先于找像素。** `-FindElement` 默认先查 UI Automation 控件树，
   查不到才截图识别。控件树给出的坐标不受遮挡、缩放、滚动影响，可靠得多。

## 改这个仓库时的规矩

1. **所有 .ps1 必须存成 UTF-8 带 BOM。** 这不是风格问题 —— PowerShell 5.1 读
   `.ps1` 是按 ANSI(GBK) 解码的，不带 BOM 的中文会全变乱码，而且是语法级报错，
   连报错信息本身都是乱码，极难定位。改完检查前三个字节是不是 `239,187,191`。

   ```powershell
   $c = Get-Content -Raw -Encoding UTF8 .\x.ps1
   [System.IO.File]::WriteAllText((Resolve-Path .\x.ps1), $c, (New-Object System.Text.UTF8Encoding($true)))
   ```

2. **目标是 Windows PowerShell 5.1，不是 PowerShell 7。** PS7 专有的参数
   （`Invoke-WebRequest -NoProxy`、`Select-Object -Reverse` 之类）写进去会直接
   报参数找不到。同理，`Add-Type` 用的 C# 编译器不支持 C# 7 语法
   （比如弃元 `out uint _`）。

3. **改完必须两个策略各测一遍**：一个控件树完整的程序（比如浏览器/记事本），
   一个控件树是空的程序（Electron 壳，比如很多国产客户端）。
   只测一边的话，很容易把另一半搞坏还不知道。

4. **别破坏操作保护。** `guard.ps1` 用全局低级钩子区分"真人输入"和
   "自己注入的输入"，靠的是 `INJECTED` 标志位。改动注入逻辑时，
   记账（`Set-InjectMark`）必须紧挨着注入动作 —— 中间隔太久会让下一次
   误判成真人操作，白白多等一整个静默期。

5. **函数定义要放在调用点之前。** PowerShell 按执行顺序解析，
   定义在后面会报 `The term 'Invoke-Xxx' is not recognized`。

## 环境差异的坑

- 多显示器和非 100% 缩放是最容易出问题的地方。所有坐标运算都依赖
  `SetProcessDpiAwarenessContext` 已经调用过（在 C# 类里统一做了）。
  如果你新增了取坐标的地方，别绕开它。
- 有些程序（视频播放器、GPU 合成画面）用 `PrintWindow` / `CopyFromScreen`
  会截成黑屏。这不是本仓库的 bug，见 README 第 6 条。
