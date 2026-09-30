#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 原生 UI 操作 —— 给任意桌面程序注入鼠标与键盘输入。

.DESCRIPTION
    纯 user32.dll SendInput 实现，不依赖 AutoHotkey / pyautogui。
    配合 screenshot.ps1 构成完整闭环：截图看懂界面 -> 注入点击/键盘 -> 再截图确认。

    注意：输入注入操作的是真实的系统光标和键盘焦点，运行期间会占用鼠标键盘。

.PARAMETER List
    列出窗口。默认只看可见窗口，加 -All 连隐藏/托盘窗口一起列。

.PARAMETER Process
    按进程名过滤（如 notepad）。

.PARAMETER Activate
    按标题正则或进程名激活窗口：还原 + 置前 + 抢焦点。

.PARAMETER ClickAt
    点击坐标 "x,y"。给了 -Window 时坐标相对该窗口左上角，否则是屏幕绝对坐标。

.PARAMETER DoubleClick / RightClick
    配合 -ClickAt 使用，双击 / 右键。

.PARAMETER Type
    键入文本（走 SendInput Unicode，支持中文，不受输入法影响）。

.PARAMETER Key
    按键。支持 "enter"、"tab"、"f5"、"ctrl+a"、"ctrl+shift+s" 这类写法。

.PARAMETER Drag
    拖拽 "x1,y1,x2,y2"。

.PARAMETER Scroll
    滚轮。正数向上，负数向下（配合 -ClickAt 先把鼠标移过去）。

.PARAMETER DelayMs
    每次注入后的等待毫秒数，默认 120。

.EXAMPLE
    .\ui.ps1 -List
.EXAMPLE
    .\ui.ps1 -Process notepad -List -All
.EXAMPLE
    .\ui.ps1 -Activate 'notepad'
.EXAMPLE
    .\ui.ps1 -Window '记事本' -ClickAt 400,300
.EXAMPLE
    .\ui.ps1 -Type 'hello 中文'
.EXAMPLE
    .\ui.ps1 -Key 'ctrl+a'
.EXAMPLE
    .\ui.ps1 -ClickAt 500,500 -Scroll -3
#>
[CmdletBinding(DefaultParameterSetName = 'None')]
param(
    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$List,

    [string]$Process,

    [Parameter(ParameterSetName = 'List')]
    [switch]$All,

    [Parameter(ParameterSetName = 'Activate', Mandatory = $true)]
    [string]$Activate,

    [Parameter(ParameterSetName = 'Click', Mandatory = $true)]
    [string]$ClickAt,

    # 不绑定参数集：-ClickAt / -ScrollAt 都能用
    [string]$Window,

    [Parameter(ParameterSetName = 'Click')]
    [switch]$DoubleClick,

    [Parameter(ParameterSetName = 'Click')]
    [switch]$RightClick,

    [Parameter(ParameterSetName = 'Type', Mandatory = $true)]
    [string]$Type,

    [Parameter(ParameterSetName = 'Key', Mandatory = $true)]
    [string]$Key,

    [Parameter(ParameterSetName = 'Drag', Mandatory = $true)]
    [string]$Drag,

    [Parameter(ParameterSetName = 'ScrollAt', Mandatory = $true)]
    [string]$ScrollAt,

    [Parameter(ParameterSetName = 'FindElement', Mandatory = $true)]
    [string]$FindElement,

    [Parameter(ParameterSetName = 'ClickElement', Mandatory = $true)]
    [string]$ClickElement,

    # 不绑定参数集 = 所有模式都可用
    [int]$Scroll = 0,

    # 定位策略：uia 只看控件树，vision 只看画面，auto 先控件树再画面
    [ValidateSet('uia', 'vision', 'auto')]
    [string]$Strategy = 'auto',

    [ValidateSet('ocr', 'omniparser', 'auto')]
    [string]$VisionBackend = 'ocr',

    [string]$OmniParserUrl = $(if ($env:OMNIPARSER_URL) { $env:OMNIPARSER_URL } else { 'http://127.0.0.1:7860' }),

    # 批量模式：一串操作在一个进程里跑完，省掉每次调用的进程启动开销。
    # 每行一条：动词 参数。见 .EXAMPLE 和 README。
    [string[]]$Script,

    [Parameter(ParameterSetName = 'Batch')]
    [string]$ScriptFile,

    [Parameter(ParameterSetName = 'Batch')]
    [switch]$IgnoreErrors,

    # 批量跑完不把焦点还回原来的窗口（默认会还）
    [switch]$NoRestoreFocus,

    # 操作保护：动手之前先确认真人已经静默这么多秒。0 = 关闭保护。
    [double]$GuardSeconds = 10,

    # 等真人静默最多等多久，超时就中止本次操作
    [double]$GuardTimeout = 120,

    [int]$DelayMs = 120
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

if (-not ('UiCap' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class UiCap
{
    // ---------------- 窗口枚举 ----------------
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public class WinInfo
    {
        public IntPtr Handle;
        public uint Pid;
        public string ProcessName;
        public string Title;
        public int X, Y, W, H;
        public bool Minimized;
        public bool Visible;
    }

    public static List<WinInfo> ListWindows(bool includeHidden)
    {
        var result = new List<WinInfo>();
        var procNames = new Dictionary<uint, string>();
        EnumWindows((h, l) =>
        {
            bool vis = IsWindowVisible(h);
            if (!vis && !includeHidden) return true;
            int len = GetWindowTextLength(h);
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            string pname = "";
            if (!procNames.TryGetValue(pid, out pname))
            {
                try { pname = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; }
                catch { pname = "?"; }
                procNames[pid] = pname;
            }
            var sb = new StringBuilder(len + 1);
            GetWindowText(h, sb, sb.Capacity);
            result.Add(new WinInfo {
                Handle = h, Pid = pid, ProcessName = pname,
                Title = sb.ToString(),
                X = r.Left, Y = r.Top,
                W = r.Right - r.Left, H = r.Bottom - r.Top,
                Minimized = IsIconic(h), Visible = vis
            });
            return true;
        }, IntPtr.Zero);
        return result;
    }

    // 强制激活：AttachThreadInput 绕过前台窗口锁定
    public static bool ForceActivate(IntPtr hWnd)
    {
        if (IsIconic(hWnd)) ShowWindow(hWnd, 9);   // SW_RESTORE
        else ShowWindow(hWnd, 5);                  // SW_SHOW
        IntPtr fg = GetForegroundWindow();
        uint fgPid;
        uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
        uint ourThread = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != ourThread)
        {
            attached = AttachThreadInput(fgThread, ourThread, true);
        }
        BringWindowToTop(hWnd);
        SetForegroundWindow(hWnd);
        SetFocus(hWnd);
        if (attached) AttachThreadInput(fgThread, ourThread, false);
        return GetForegroundWindow() == hWnd;
    }

    // ---------------- SendInput ----------------
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData;
        public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan;
        public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT {
        public uint uMsg; public ushort wParamL; public ushort wParamH;
    }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    const uint INPUT_MOUSE = 0;
    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_UNICODE = 0x0004;
    const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP = 0x0004;
    const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    const uint MOUSEEVENTF_WHEEL = 0x0800;

    static INPUT MouseInput(uint flags, int data)
    {
        var i = new INPUT();
        i.type = INPUT_MOUSE;
        i.u.mi.dwFlags = flags;
        i.u.mi.mouseData = (uint)data;
        return i;
    }

    static INPUT KeyInput(ushort vk, ushort scan, uint flags)
    {
        var i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = vk;
        i.u.ki.wScan = scan;
        i.u.ki.dwFlags = flags;
        return i;
    }

    static void Send(INPUT[] inputs)
    {
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (sent != inputs.Length)
            throw new Exception("SendInput 只发送了 " + sent + "/" + inputs.Length + " 个事件 (Win32 错误 " + Marshal.GetLastWin32Error() + ")");
    }

    public static void MoveTo(int x, int y)
    {
        if (!SetCursorPos(x, y)) throw new Exception("SetCursorPos(" + x + "," + y + ") 失败");
    }

    public static void Click(bool right, int count, int holdMs)
    {
        for (int n = 0; n < count; n++)
        {
            uint down = right ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN;
            uint up   = right ? MOUSEEVENTF_RIGHTUP   : MOUSEEVENTF_LEFTUP;
            // 分两次发送并在中间保持按住：Chromium/Electron 应用做手势识别，
            // 同一批 SendInput 里 down+up 零间隔会被当作无效点击而丢弃。
            Send(new INPUT[] { MouseInput(down, 0) });
            if (holdMs > 0) System.Threading.Thread.Sleep(holdMs);
            Send(new INPUT[] { MouseInput(up, 0) });
            if (count > 1) System.Threading.Thread.Sleep(80);
        }
    }

    public static void Scroll(int notches)
    {
        Send(new INPUT[] { MouseInput(MOUSEEVENTF_WHEEL, notches * 120) });
    }

    public static void TypeText(string text)
    {
        foreach (char c in text)
        {
            var down = KeyInput(0, c, KEYEVENTF_UNICODE);
            var up   = KeyInput(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
            Send(new INPUT[] { down, up });
        }
    }

    public static void KeyPress(ushort vk, bool extended)
    {
        KeyDown(vk, extended);
        KeyUp(vk, extended);
    }

    public static void KeyDown(ushort vk, bool extended)
    {
        uint f = extended ? KEYEVENTF_EXTENDEDKEY : 0;
        Send(new INPUT[] { KeyInput(vk, 0, f) });
    }

    public static void KeyUp(ushort vk, bool extended)
    {
        uint f = extended ? KEYEVENTF_EXTENDEDKEY : 0;
        Send(new INPUT[] { KeyInput(vk, 0, f | KEYEVENTF_KEYUP) });
    }

    public static void MouseButton(bool right, bool down)
    {
        uint flag;
        if (right) flag = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
        else       flag = down ? MOUSEEVENTF_LEFTDOWN  : MOUSEEVENTF_LEFTUP;
        Send(new INPUT[] { MouseInput(flag, 0) });
    }

    // ---- DPI 感知 ----
    // 关键：SetCursorPos 用物理像素且不做 DPI 虚拟化，而 DPI-unaware 进程的
    // GetWindowRect 返回虚拟化的逻辑坐标。两者相差缩放比（本机 1.25x），
    // 不声明感知的话，按窗口相对坐标点击会稳定偏移 25%。
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern IntPtr SetProcessDpiAwarenessContext(IntPtr value);

    public static string EnableDpiAwareness()
    {
        try {
            if (SetProcessDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero) return "PerMonitorV2";
        } catch { }
        try {
            if (SetProcessDPIAware()) return "SystemAware";
        } catch { }
        return "unchanged";
    }

    public static string GetCursorInfo()
    {
        POINT p;
        if (!GetCursorPos(out p)) return "?";
        return p.X + "," + p.Y;
    }

    // 记账要用：GetTickCount 取当前 tick，GetLastInputInfo 取"上次输入"的 tick
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    public static uint LastInputTick()
    {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref li)) return 0;
        return li.dwTime;
    }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
}
'@
}

# 必须在任何坐标运算之前声明 DPI 感知
$script:DpiMode = [UiCap]::EnableDpiAwareness()

function Resolve-Point {
    param([string]$Spec, [int]$Count = 2)
    $parts = @($Spec -split '[,;\s]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ne $Count) { throw "坐标需要 $Count 个值，收到 $($parts.Count) 个：$Spec" }
    return ($parts | ForEach-Object { [int]$_ })
}

function Find-TargetWindow {
    param([string]$Pattern)
    $wins = [UiCap]::ListWindows($true) | Where-Object {
        $_.Title -match $Pattern -or $_.ProcessName -match $Pattern
    }
    return @($wins | Sort-Object { -($_.W * $_.H) })
}

# 操作保护闸。
# 自动化跟人抢鼠标是很讨厌的事，所以任何注入键鼠的操作动手之前，
# 都先确认真人已经有一段时间没碰过电脑了。真人在用就等，等不到就中止。
# 只读操作（-List / -FindElement）不过闸，因为它们不碰鼠标键盘。
function Invoke-InputGuard {
    if ($GuardSeconds -le 0) { return }

    $guard = Join-Path $PSScriptRoot 'guard.ps1'
    if (-not (Test-Path $guard)) {
        Write-Warning "找不到 guard.ps1，本次操作没有保护。"
        return
    }

    try {
        & $guard -WaitIdle $GuardSeconds -Timeout $GuardTimeout -Quiet | Out-Null
        $code = $LASTEXITCODE
    } catch {
        Write-Warning "操作保护执行异常，本次放行：$($_.Exception.Message)"
        return
    }

    if ($code -ne 0) {
        throw "操作保护：$GuardTimeout 秒内检测到你一直在用电脑，本次操作已中止。确认不用了可以加 -GuardSeconds 0 跳过。"
    }

}

# 注入之前记账，告诉状态文件"接下来这几下是我干的"。
# 必须紧挨着注入动作调用：中间隔太久的话，下次判断就会把这一下
# 误认成真人操作，白白多等一整个静默期。
function Set-InjectMark {
    $statePath = Join-Path $env:TEMP 'dsh-ui-guard.json'
    $now  = [UiCap]::GetTickCount()
    $last = [UiCap]::LastInputTick()

    $injectTick = [uint32]0
    $humanTick  = [uint32]0
    if (Test-Path $statePath) {
        try {
            $o = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $injectTick = [uint32]$o.InjectTick
            $humanTick  = [uint32]$o.HumanTick
        } catch { }
    }

    # 上一次输入如果不在我上次记账之后的 600ms 内，那就不是自己刚发的，是真人。
    # 这个窗口敢开这么小，是因为记账已经挪到紧挨注入了。
    if ($last -ne 0 -and $injectTick -ne 0) {
        $d = [int64]$last - [int64]$injectTick
        if ($d -lt 0) { $d += 4294967296 }
        if ($d -gt 600) { $humanTick = $last }
    }

    [pscustomobject]@{ InjectTick = $now; HumanTick = $humanTick } |
        ConvertTo-Json -Compress | Set-Content -Path $statePath -Encoding UTF8
}

# ---------------------------------------------------------------- -List
if ($List) {
    $wins = [UiCap]::ListWindows([bool]$All)
    if ($Process) { $wins = $wins | Where-Object { $_.ProcessName -match $Process } }
    $rows = $wins | Sort-Object ProcessName, { -$_.W } | ForEach-Object {
        [pscustomobject]@{
            Proc      = $_.ProcessName
            Pid       = $_.Pid
            Handle    = ('0x{0:X}' -f $_.Handle.ToInt64())
            Rect      = "$($_.X),$($_.Y) $($_.W)x$($_.H)"
            Visible   = $_.Visible
            Minimized = $_.Minimized
            Title     = if ($_.Title.Length -gt 60) { $_.Title.Substring(0, 60) + '…' } else { $_.Title }
        }
    }
    $rows | Format-Table -AutoSize
    return
}

# ---------------------------------------------------------------- -Activate
if ($Activate) {
    $wins = Find-TargetWindow -Pattern $Activate
    if (-not $wins) { throw "没有匹配 '$Activate' 的窗口（进程名或标题）。用 -List -All 看全部。" }
    foreach ($w in $wins) {
        $ok = [UiCap]::ForceActivate($w.Handle)
        Start-Sleep -Milliseconds 350
        [pscustomobject]@{
            Activated = $ok
            Process   = $w.ProcessName
            Handle    = ('0x{0:X}' -f $w.Handle.ToInt64())
            Title     = $w.Title
            Rect      = "$($w.X),$($w.Y) $($w.W)x$($w.H)"
        }
        if ($ok) { break }   # 激活成功一个就够
    }
    Start-Sleep -Milliseconds $DelayMs
    return
}

# ---------------------------------------------------------------- -Type
# 从原来的 -Type 块抽出来的，批处理模式和单次调用共用
function Invoke-Type {

    Invoke-InputGuard
    Set-InjectMark
    [UiCap]::TypeText($Type)
    Start-Sleep -Milliseconds $DelayMs
    [pscustomobject]@{ Typed = $Type; Length = $Type.Length }
    return
}

# 从原来的 -Key 块抽出来的，批处理模式和单次调用共用
function Invoke-Key {

    Invoke-InputGuard
    $map = @{
        'enter'=13; 'tab'=9; 'esc'=27; 'escape'=27; 'space'=32; 'backspace'=8; 'delete'=46; 'del'=46
        'up'=38; 'down'=40; 'left'=37; 'right'=39; 'home'=36; 'end'=35; 'pageup'=33; 'pagedown'=34
        'insert'=45; 'capslock'=20; 'printscreen'=44
        'f1'=112;'f2'=113;'f3'=114;'f4'=115;'f5'=116;'f6'=117;'f7'=118;'f8'=119;'f9'=120;'f10'=121;'f11'=122;'f12'=123
        'ctrl'=17; 'control'=17; 'alt'=18; 'shift'=16; 'win'=91
    }
    # 扩展键需要用 KEYEVENTF_EXTENDEDKEY 发送
    $extended = @(37,38,39,40,33,34,35,36,45,46,44,91,92)

    $tokens = @($Key.ToLower() -split '\+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -eq 0) { throw '-Key 是空的' }
    $mainKey = $tokens[-1]
    $mods = @()
    if ($tokens.Count -gt 1) { $mods = $tokens[0..($tokens.Count - 2)] }

    $codes = @()
    foreach ($m in $mods) {
        if (-not $map.ContainsKey($m)) { throw "不认识的修饰键 '$m'（支持 ctrl/alt/shift/win）" }
        $codes += [int]$map[$m]
    }

    if ($map.ContainsKey($mainKey)) {
        $mainVk = [int]$map[$mainKey]
    } elseif ($mainKey.Length -eq 1) {
        $mainVk = [int][char]([string]$mainKey).ToUpper()[0]
    } else {
        throw "不认识的按键 '$mainKey'"
    }

    # 逆序释放修饰键；用 try/finally 保证异常时也一定释放，
    # 否则会留下"卡住的修饰键"（按了下 Win 键不放 = 后续按键全变系统快捷键）
    Set-InjectMark
    $reversed = @($codes)
    [array]::Reverse($reversed)
    try {
        # 按下修饰键（保持按住）
        foreach ($c in $codes) {
            [UiCap]::KeyDown([uint16]$c, ($extended -contains $c))
            Start-Sleep -Milliseconds 25
        }

        # 敲主键
        [UiCap]::KeyPress([uint16]$mainVk, ($extended -contains $mainVk))
        Start-Sleep -Milliseconds 25
    }
    finally {
        foreach ($c in $reversed) {
            try { [UiCap]::KeyUp([uint16]$c, ($extended -contains $c)) } catch { }
            Start-Sleep -Milliseconds 25
        }
    }

    Start-Sleep -Milliseconds $DelayMs
    [pscustomobject]@{ Key = $Key; Vk = $mainVk; Modifiers = ($mods -join '+'); Released = ($reversed.Count -gt 0) }
    return
}

# 从原来的 -Drag 块抽出来的，批处理模式和单次调用共用
function Invoke-Drag {

    Invoke-InputGuard
    $p = Resolve-Point -Spec $Drag -Count 4
    [UiCap]::MoveTo($p[0], $p[1])
    Start-Sleep -Milliseconds 150
    Set-InjectMark
    [UiCap]::MouseButton($false, $true)      # 左键按下并保持
    Start-Sleep -Milliseconds 100

    # 分步移动，模拟真实拖拽轨迹（很多程序要求中间有 move 事件）
    $steps = 12
    for ($i = 1; $i -le $steps; $i++) {
        $nx = [int]($p[0] + ($p[2] - $p[0]) * $i / $steps)
        $ny = [int]($p[1] + ($p[3] - $p[1]) * $i / $steps)
        [UiCap]::MoveTo($nx, $ny)
        Start-Sleep -Milliseconds 25
    }

    Start-Sleep -Milliseconds 100
    [UiCap]::MouseButton($false, $false)     # 抬起
    Start-Sleep -Milliseconds $DelayMs
    [pscustomobject]@{ From = "$($p[0]),$($p[1])"; To = "$($p[2]),$($p[3])"; Steps = $steps }
    return
}

# 从原来的 -ScrollAt 块抽出来的，批处理模式和单次调用共用
function Invoke-ScrollAt {

    Invoke-InputGuard
    $pt = Resolve-Point -Spec $ScrollAt -Count 2
    $sx = $pt[0]; $sy = $pt[1]

    if ($Window) {
        $wins = Find-TargetWindow -Pattern $Window
        if (-not $wins) { throw "没有匹配 '$Window' 的窗口" }
        $w = $wins[0]
        $fgNow = [UiCap]::GetForegroundWindow()
        if ($fgNow -ne $w.Handle) {
            [UiCap]::ForceActivate($w.Handle) | Out-Null
            Start-Sleep -Milliseconds 400
        }
        $sx = $w.X + $sx
        $sy = $w.Y + $sy
    }

    Set-InjectMark
    [UiCap]::MoveTo($sx, $sy)
    Start-Sleep -Milliseconds 250

    $notches = if ($Scroll -ne 0) { $Scroll } else { -3 }
    # 分次滚动，让页面有渲染时间
    $step = if ($notches -gt 0) { 1 } else { -1 }
    for ($i = 0; $i -lt [math]::Abs($notches); $i++) {
        [UiCap]::Scroll($step)
        Start-Sleep -Milliseconds 120
    }

    Start-Sleep -Milliseconds $DelayMs
    [pscustomobject]@{ ScrolledAt = "$sx,$sy"; Notches = $notches }
    return
}

# 从原来的 -ClickAt 块抽出来的，批处理模式和单次调用共用
function Invoke-ClickAt {

    Invoke-InputGuard
    $pt = Resolve-Point -Spec $ClickAt -Count 2
    $x = $pt[0]; $y = $pt[1]

    if ($Window) {
        $wins = Find-TargetWindow -Pattern $Window
        if (-not $wins) { throw "没有匹配 '$Window' 的窗口" }
        $w = $wins[0]
        if (-not $w.Visible -or $w.Minimized) {
            [UiCap]::ForceActivate($w.Handle) | Out-Null
            Start-Sleep -Milliseconds 300
            $w = ([UiCap]::ListWindows($true) | Where-Object { $_.Handle -eq $w.Handle })
        }
        $x = $w.X + $x
        $y = $w.Y + $y
    }

    # 目标窗口不在前台时先激活；Chromium 应用的第一击常被吞掉用于激活窗口
    $fgNow = [UiCap]::GetForegroundWindow()
    if ($Window -and $w -and $fgNow -ne $w.Handle) {
        [UiCap]::ForceActivate($w.Handle) | Out-Null
        Start-Sleep -Milliseconds 400
    }

    Set-InjectMark
    [UiCap]::MoveTo($x, $y)
    Start-Sleep -Milliseconds 120

    $count = if ($DoubleClick) { 2 } else { 1 }
    [UiCap]::Click([bool]$RightClick, $count, 60)

    if ($Scroll -ne 0) {
        Start-Sleep -Milliseconds 60
        [UiCap]::Scroll($Scroll)
    }

    Start-Sleep -Milliseconds $DelayMs
    [pscustomobject]@{
        ClickedAt = "$x,$y"
        Button    = if ($RightClick) { 'right' } else { 'left' }
        Count     = $count
        Scroll    = $Scroll
    }
    return
}

# 从原来的 -FindElement 块抽出来的，批处理模式和单次调用共用
function Invoke-FindElement {

    if (-not $Window) { throw '-FindElement 需要配 -Window 指定在哪个窗口里找。' }
    $wins = Find-TargetWindow -Pattern $Window
    if (-not $wins) { throw "没有匹配 '$Window' 的窗口。" }
    $w = $wins[0]

    $found = @()
    $used = ''

    if ($Strategy -ne 'vision') {
        $found = @(Get-UiaElements -Handle $w.Handle -Pattern $FindElement)
        if ($found.Count) { $used = 'uia' }
    }
    if (-not $found -and $Strategy -ne 'uia') {
        $found = @(Get-VisionElements -Handle $w.Handle -Pattern $FindElement -Backend $VisionBackend -OmniUrl $OmniParserUrl)
        if ($found.Count) { $used = "vision/$VisionBackend" }
    }

    if (-not $found) {
        Write-Host "没找到匹配 '$FindElement' 的元素（策略=$Strategy）。"
        Write-Host "控件树空的窗口（比如 Electron 壳）本来就读不到，试试 -Strategy vision。"
        return
    }

    Write-Verbose "命中来源: $used"
    $found | Select-Object Source, Type,
        @{ n = 'Text'; e = { if ($_.Text.Length -gt 40) { $_.Text.Substring(0, 40) + '…' } else { $_.Text } } },
        X, Y, W, H | Format-Table -AutoSize
    return
}

# 从原来的 -ClickElement 块抽出来的，批处理模式和单次调用共用
function Invoke-ClickElement {

    Invoke-InputGuard
    if (-not $Window) { throw '-ClickElement 需要配 -Window 指定在哪个窗口里点。' }
    $wins = Find-TargetWindow -Pattern $Window
    if (-not $wins) { throw "没有匹配 '$Window' 的窗口。" }
    $w = $wins[0]

    $fgNow = [UiCap]::GetForegroundWindow()
    if ($fgNow -ne $w.Handle) {
        [UiCap]::ForceActivate($w.Handle) | Out-Null
        Start-Sleep -Milliseconds 400
        $w = ([UiCap]::ListWindows($true) | Where-Object { $_.Handle -eq $w.Handle })
    }

    $target = $null
    $used = ''

    if ($Strategy -ne 'vision') {
        $uia = @(Get-UiaElements -Handle $w.Handle -Pattern $ClickElement)
        if ($uia.Count) {
            # 排序：能被 Invoke 的优先 -> 文字完全同名的优先 -> 面积小的优先
            # （面积小通常意味着控件更具体；页面上同名的大块文本容器会排在后面）
            $want = $ClickElement -replace '\s+', ''
            $ranked = $uia | Sort-Object -Property @(
                @{ Expression = { if ($_.CanInvoke) { 0 } else { 1 } } },
                @{ Expression = { if ($_.Norm -eq $want) { 0 } else { 1 } } },
                @{ Expression = { $_.W * $_.H } }
            )
            $target = $ranked[0]
            $used = 'uia'
        }
    }

    if (-not $target -and $Strategy -ne 'uia') {
        # 注意要套 @()：函数返回单元素数组时 PowerShell 会展开成标量，标量的 .Count 取不到值
        $vis = @(Get-VisionElements -Handle $w.Handle -Pattern $ClickElement -Backend $VisionBackend -OmniUrl $OmniParserUrl)
        if ($vis.Count) {
            $target = ($vis | Sort-Object { $_.W * $_.H })[0]
            $used = "vision/$($script:LastVisionBackend)"
        }
    }

    if (-not $target) {
        throw "找不到 '$ClickElement'（策略=$Strategy）。用 -FindElement 先看看窗口里有什么。"
    }

    # UIA 给的是屏幕绝对坐标；视觉识别给的是图片内坐标，得加窗口原点
    if ($used -eq 'uia') {
        $ax = $target.X; $ay = $target.Y
    } else {
        $ax = $w.X + $target.X; $ay = $w.Y + $target.Y
    }

    $clicked = 'click'
    if ($used -eq 'uia' -and $target.CanInvoke) {
        # 能 Invoke 就直接触发，比模拟点击稳（被遮挡也不怕）。
        # Invoke 本身不算注入，但万一它失败要退回模拟点击，所以这里先记账。
        Set-InjectMark
        try {
            $pattern = $target.Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $pattern.Invoke()
            $clicked = 'invoke'
        } catch {
            [UiCap]::MoveTo($ax, $ay)
            Start-Sleep -Milliseconds 80
            [UiCap]::Click($false, 1, 60)
        }
    } else {
        Set-InjectMark
        [UiCap]::MoveTo($ax, $ay)
        Start-Sleep -Milliseconds 80
        [UiCap]::Click($false, 1, 60)
    }

    Start-Sleep -Milliseconds $DelayMs
    [pscustomobject]@{
        Matched = $ClickElement
        Via     = $used
        How     = $clicked
        Text    = $target.Text
        Type    = $target.Type
        At      = "$ax,$ay"
    }
    return
}

function Get-UiaElements {
    param([IntPtr]$Handle, [string]$Pattern)

    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
    if (-not $root) { return @() }

    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)

    # 窗口自身的范围。页面里滚出可视区的元素坐标会是很小的负数，
    # 同名文字一抓一大把，不过滤就会点到屏幕外面去。
    $wr = [UiCap+RECT]::new()
    [void][UiCap]::GetWindowRect($Handle, [ref]$wr)

    $out = @()
    foreach ($e in $all) {
        try {
            $name = $e.Current.Name
            if (-not $name) { continue }

            # 归一化后匹配，跟视觉那条路保持一致
            $norm = $name -replace '\s+', ''
            if ($norm -notmatch $Pattern -and $name -notmatch $Pattern) { continue }

            $r = $e.Current.BoundingRectangle
            # 有些元素宽高是 Infinity（虚拟化的列表容器），坐标没法用
            if ([double]::IsInfinity($r.Width) -or [double]::IsInfinity($r.Height)) { continue }
            if ($r.Width -le 0 -or $r.Height -le 0) { continue }

            # 只留中心点落在窗口内的元素
            $cx = $r.X + $r.Width / 2
            $cy = $r.Y + $r.Height / 2
            if ($cx -lt $wr.Left -or $cx -gt $wr.Right) { continue }
            if ($cy -lt $wr.Top -or $cy -gt $wr.Bottom) { continue }

            # 能不能直接 Invoke。能的话比模拟点击稳，被遮挡也不怕
            $patObj = $null
            $canInvoke = $false
            try { $canInvoke = $e.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$patObj) } catch { }

            $out += [pscustomobject]@{
                Source   = 'uia'
                Type     = ($e.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '')
                Text     = $name
                Norm     = $norm
                Id       = $e.Current.AutomationId
                X1       = [int]$r.X
                Y1       = [int]$r.Y
                X2       = [int]($r.X + $r.Width)
                Y2       = [int]($r.Y + $r.Height)
                X        = [int]($r.X + $r.Width / 2)
                Y        = [int]($r.Y + $r.Height / 2)
                W        = [int]$r.Width
                H        = [int]$r.Height
                Element  = $e
                CanInvoke = $canInvoke
            }
        } catch { }
    }
    return $out
}

function Get-VisionElements {
    param([IntPtr]$Handle, [string]$Pattern, [string]$Backend, [string]$OmniUrl)

    $vision = Join-Path $PSScriptRoot 'vision.ps1'
    if (-not (Test-Path $vision)) { throw "同目录下找不到 vision.ps1，没法走视觉兜底。" }


    $dir = Join-Path $PSScriptRoot 'shots'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $png = Join-Path $dir ("ui-vision-{0}.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    # 用 PrintWindow 抓这个窗口，被遮挡也能抓到
    $bmp = $null
    $r = [UiCap+RECT]::new()
    [void][UiCap]::GetWindowRect($Handle, [ref]$r)
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { throw '窗口尺寸为 0，抓不到图。' }

    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [UiCap]::PrintWindow($Handle, $hdc, 2)
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    if (-not $ok) {
        $bmp.Dispose()
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
        $g.Dispose()
    }
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    $json = & $vision -Image $png -Match $Pattern -Backend $Backend -OmniParserUrl $OmniUrl -Json
    # 脚本输出是多行字符串，PowerShell 捕获时会拆成字符串数组，先拼回去再解析
    $parsed = (@($json) -join "`n") | ConvertFrom-Json
    # 记住实际用了哪个后端（auto 会自己挑），好在结果里如实报告
    $script:LastVisionBackend = $parsed.backend
    if (-not $parsed.elements) { return @() }
    return @($parsed.elements)
}

# ---------------------------------------------------------------- -Script / -ScriptFile
# 批量模式：一串操作在同一个进程里顺序跑完。
#
# 为什么要这个：每次调用 ui.ps1 都要重新起一个 PowerShell 进程、重新编译那段 C#，
# 实测每次固定开销约 0.4 秒。十步的任务光启动就浪费四秒。批量模式把这些省掉，
# 顺带也让模型侧不用来回十几次。
#
# 格式：一行一条，`动词 参数`。空行和 # 开头的行忽略。
if ($Script -or $ScriptFile) {

    # -Script 可以是一行数组，也可以是一整个多行字符串（命令行里传数组会被拆散，
    # 所以多行字符串反而是更可靠的用法）
    $lines = if ($ScriptFile) {
        if (-not (Test-Path $ScriptFile)) { throw "找不到脚本文件: $ScriptFile" }
        @(Get-Content $ScriptFile -Encoding UTF8)
    } else {
        @($Script | ForEach-Object { $_ -split "`r?`n" })
    }

    # 逐行可以切换目标窗口；命令行给的 -Window 作为初始值
    $batchWindow = $Window
    $batchIndex = 0
    $batchFailed = 0
    $batchAborted = $false

    # 记下任务开始前你正在看哪个窗口。跑完要还回去，
    # 省得每次自动化折腾完，还得你自己手动切回对话界面。
    $startFg = [UiCap]::GetForegroundWindow()

    Write-Host "批量执行开始，共 $($lines.Count) 行"

    foreach ($rawLine in $lines) {
        $batchIndex++
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }

        $sp = $line -split '\s+', 2
        $verb = $sp[0].ToLower()
        $arg = if ($sp.Count -gt 1) { $sp[1].Trim() } else { '' }

        # 让被调用的函数看到当前的目标窗口
        $Window = $batchWindow

        try {
            switch ($verb) {

                'window' {
                    $batchWindow = $arg
                    Write-Host "  [$batchIndex] 目标窗口 -> $arg"
                }

                'focus' {
                    $wins = Find-TargetWindow -Pattern $arg
                    if (-not $wins) { throw "没有匹配 '$arg' 的窗口" }
                    [void][UiCap]::ForceActivate($wins[0].Handle)
                    Start-Sleep -Milliseconds 300
                    Write-Host "  [$batchIndex] 焦点切到 $arg"
                }

                'activate' {
                    $Window = $arg
                    $wins = Find-TargetWindow -Pattern $arg
                    if (-not $wins) { throw "没有匹配 '$arg' 的窗口" }
                    [void][UiCap]::ForceActivate($wins[0].Handle)
                    Start-Sleep -Milliseconds 350
                    Write-Host "  [$batchIndex] 激活 $arg"
                }

                'click' {
                    Set-Variable -Name ClickAt -Value $arg -Scope Script
                    Set-Variable -Name DoubleClick -Value $false -Scope Script
                    Set-Variable -Name RightClick -Value $false -Scope Script
                    Invoke-ClickAt
                    Write-Host "  [$batchIndex] click $arg"
                }

                'dblclick' {
                    Set-Variable -Name ClickAt -Value $arg -Scope Script
                    Set-Variable -Name DoubleClick -Value $true -Scope Script
                    Set-Variable -Name RightClick -Value $false -Scope Script
                    Invoke-ClickAt
                    Write-Host "  [$batchIndex] dblclick $arg"
                }

                'rightclick' {
                    Set-Variable -Name ClickAt -Value $arg -Scope Script
                    Set-Variable -Name DoubleClick -Value $false -Scope Script
                    Set-Variable -Name RightClick -Value $true -Scope Script
                    Invoke-ClickAt
                    Write-Host "  [$batchIndex] rightclick $arg"
                }

                'findelement' {
                    Set-Variable -Name FindElement -Value $arg -Scope Script
                    Invoke-FindElement
                    Write-Host "  [$batchIndex] findelement $arg"
                }

                'clickelement' {
                    Set-Variable -Name ClickElement -Value $arg -Scope Script
                    Invoke-ClickElement | Out-Null
                    Write-Host "  [$batchIndex] clickelement $arg"
                }

                'type' {
                    Set-Variable -Name Type -Value $arg -Scope Script
                    Invoke-Type | Out-Null
                    Write-Host "  [$batchIndex] type $arg"
                }

                'key' {
                    Set-Variable -Name Key -Value $arg -Scope Script
                    Invoke-Key | Out-Null
                    Write-Host "  [$batchIndex] key $arg"
                }

                'drag' {
                    Set-Variable -Name Drag -Value $arg -Scope Script
                    Invoke-Drag | Out-Null
                    Write-Host "  [$batchIndex] drag $arg"
                }

                'scrollat' {
                    # scrollat x,y 数量
                    $bits = @($arg -split '\s+' | Where-Object { $_ -ne '' })
                    if ($bits.Count -lt 3) { throw "scrollat 需要 x,y 和滚动格数，例如: scrollat 2025,600 -8" }
                    Set-Variable -Name ScrollAt -Value $bits[0] -Scope Script
                    Set-Variable -Name Scroll -Value ([int]$bits[1]) -Scope Script
                    Invoke-ScrollAt | Out-Null
                    Write-Host "  [$batchIndex] scrollat $($bits[0]) $($bits[1])"
                }

                'scroll' {
                    # scroll 数量：在光标当前位置滚，不移动鼠标
                    Invoke-InputGuard
                    Set-InjectMark
                    [UiCap]::Scroll([int]$arg)
                    Write-Host "  [$batchIndex] scroll $arg"
                }

                'move' {
                    Invoke-InputGuard
                    Set-InjectMark
                    $pt = Resolve-Point -Spec $arg -Count 2
                    [UiCap]::MoveTo($pt[0], $pt[1])
                    Write-Host "  [$batchIndex] move $arg"
                }

                'wait' {
                    $sec = [double]$arg
                    Start-Sleep -Milliseconds ([int]($sec * 1000))
                    Write-Host "  [$batchIndex] wait $sec 秒"
                }

                'guard' {
                    Set-Variable -Name GuardSeconds -Value ([double]$arg) -Scope Script
                    Write-Host "  [$batchIndex] 操作保护阈值 -> $arg 秒"
                }

                'screenshot' {
                    $ss = Join-Path $PSScriptRoot 'screenshot.ps1'
                    $out = if ($arg) { $arg } else {
                        $dir = Join-Path $PSScriptRoot 'shots'
                        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                        Join-Path $dir ("batch-{0}.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                    }
                    if ($batchWindow) { & $ss -Window $batchWindow -Out $out | Out-Null }
                    else { & $ss -Out $out | Out-Null }
                    Write-Host "  [$batchIndex] screenshot -> $out"
                }

                'echo' {
                    Write-Host "  [$batchIndex] $arg"
                }

                default {
                    throw "不认识的动词 '$verb'"
                }
            }
        }
        catch {
            $batchFailed++
            Write-Warning "第 $batchIndex 行失败（$line）: $($_.Exception.Message)"
            if (-not $IgnoreErrors) {
                Write-Host "批量执行中止于第 $batchIndex 行。要跳过错误继续跑，加 -IgnoreErrors。"
                $batchAborted = $true
                break
            }
        }
    }

    # 不管成功还是失败，都把焦点还回任务开始前的窗口。
    # 这一步是用户明确要求的：自动化跑完不要把人晾在别的程序里。
    if (-not $NoRestoreFocus -and $startFg -ne [IntPtr]::Zero) {
        [void][UiCap]::ForceActivate($startFg)
        Start-Sleep -Milliseconds 250
        Write-Host "已把焦点还回任务开始前的窗口。"
    }

    if ($batchAborted) { exit 1 }
    if ($batchFailed -gt 0) {
        Write-Host "批量执行结束，$batchFailed 行失败（已按 -IgnoreErrors 跳过）。"
        exit 1
    }
    Write-Host "批量执行完成，$($lines.Count) 行全部处理。"
    exit 0
}

if ($Type) { Invoke-Type; return }

# ---------------------------------------------------------------- -Key
if ($Key) { Invoke-Key; return }

# ---------------------------------------------------------------- -Drag
if ($Drag) { Invoke-Drag; return }

# ---------------------------------------------------------------- -ScrollAt
# 只移动光标 + 滚轮，不点击。用于在长列表（如评论区）里翻页，
# 避免点击落在列表项上引发副作用。
if ($ScrollAt) { Invoke-ScrollAt; return }

# ---------------------------------------------------------------- -ClickAt
if ($ClickAt) { Invoke-ClickAt; return }

# ---------------------------------------------------------------- 定位：控件树
# 用 UI Automation 读窗口的控件树。靠谱的程序（Win32/WinUI/浏览器）都能读出
# 带名字和精确坐标的控件；Electron 壳默认关掉辅助功能，树是空的 —— 那就得靠
# 下面的视觉兜底。


# ---------------------------------------------------------------- 定位：视觉
# 截图 + 识别（Windows 自带 OCR 或 OmniParser），按文字找元素。
# 返回的坐标是相对截图的，调用方负责加上窗口原点。


# ---------------------------------------------------------------- -FindElement
if ($FindElement) { Invoke-FindElement; return }

# ---------------------------------------------------------------- -ClickElement
if ($ClickElement) { Invoke-ClickElement; return }

Write-Host "没有指定操作。用 -List / -Activate / -ClickAt / -Type / -Key / -Drag / -ScrollAt / -FindElement / -ClickElement，或看 .EXAMPLE"
