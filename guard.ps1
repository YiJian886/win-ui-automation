#Requires -Version 5.1
<#
.SYNOPSIS
    人在操作电脑吗？—— 给自动化脚本用的操作保护闸。

.DESCRIPTION
    自动化跟人抢鼠标是很讨厌的事。这个脚本让 ui.ps1 在动手之前先确认
    "真人已经有一段时间没碰过电脑了"，真人在用就等，等不到就中止。

    难点在于分清"真人操作"和"自动化自己注入的操作"：

      - ui.ps1 用 SendInput 注入，事件带 INJECTED 标志。
        所以这里挂全局低级钩子（WH_MOUSE_LL / WH_KEYBOARD_LL），
        靠标志位把它们挑出来扔掉。
      - 但钩子只有"装上之后"的视野，没有历史。而每次调用 ui.ps1 都是新进程，
        如果只看钩子，"连续点十下"就会变成"每下都干等十秒"。
      - 所以再配一个状态文件：每次注入前把当时的系统输入时刻记下来，
        并判断那一次输入到底是人干的还是自己干的。这样下次再问
        "真人静默多久了"就能直接算出来，不用空等。

.PARAMETER WaitIdle
    等到真人连续 N 秒没碰键鼠再返回。ui.ps1 动手前调的就是这个。

.PARAMETER Timeout
    最多等多少秒，默认 120。超时退出码 1。

.PARAMETER MarkInject
    在注入键鼠之前调一次，把当前输入时刻记账，供后面的 WaitIdle 判断。

.PARAMETER Status
    立刻报告当前状态，不阻塞。

.PARAMETER Watch
    观察 N 秒，报告期间发生的真人输入次数。用来验证钩子是否有效。

.PARAMETER Quiet
    不打印，只看退出码。

.EXAMPLE
    .\guard.ps1 -Status
.EXAMPLE
    .\guard.ps1 -WaitIdle 10
.EXAMPLE
    .\guard.ps1 -Watch 5
#>
[CmdletBinding(DefaultParameterSetName = 'Wait')]
param(
    [Parameter(ParameterSetName = 'Wait')]
    [double]$WaitIdle = 10,

    [Parameter(ParameterSetName = 'Wait')]
    [double]$Timeout = 120,

    [Parameter(ParameterSetName = 'Mark', Mandatory = $true)]
    [switch]$MarkInject,

    [Parameter(ParameterSetName = 'Status', Mandatory = $true)]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Watch', Mandatory = $true)]
    [double]$Watch,

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# 状态文件放临时目录，记录两个时刻：
#   InjectTick  最近一次"自动化注入"发生的时刻
#   HumanTick   最近一次"确认是真人干的"输入时刻
$StatePath = Join-Path $env:TEMP 'dsh-ui-guard.json'

if (-not ('InputGuard' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public class InputGuard
{
    const int WH_KEYBOARD_LL = 13;
    const int WH_MOUSE_LL    = 14;
    const uint LLMHF_INJECTED = 0x00000001;
    const uint LLKHF_INJECTED = 0x00000010;
    const uint PM_REMOVE = 0x0001;

    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll")]
    static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max, uint remove);
    [DllImport("kernel32.dll")]
    static extern uint GetTickCount();
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }

    [StructLayout(LayoutKind.Sequential)]
    struct MSLLHOOKSTRUCT { public int ptX; public int ptY; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    // 这两个委托必须用静态字段兜住，否则被 GC 回收后钩子直接失效
    static HookProc _mouseProc;
    static HookProc _kbdProc;
    static IntPtr _hMouse = IntPtr.Zero;
    static IntPtr _hKbd   = IntPtr.Zero;

    static volatile uint _lastRealInputTick;
    static volatile int  _realEventCount;

    static IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            MSLLHOOKSTRUCT d = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
            if ((d.flags & LLMHF_INJECTED) == 0)
            {
                _lastRealInputTick = GetTickCount();
                _realEventCount++;
            }
        }
        return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    static IntPtr KbdHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            KBDLLHOOKSTRUCT d = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            if ((d.flags & LLKHF_INJECTED) == 0)
            {
                _lastRealInputTick = GetTickCount();
                _realEventCount++;
            }
        }
        return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    public static bool Install()
    {
        _mouseProc = MouseHook;
        _kbdProc   = KbdHook;
        IntPtr hMod = GetModuleHandle(null);
        _hMouse = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, hMod, 0);
        _hKbd   = SetWindowsHookEx(WH_KEYBOARD_LL, _kbdProc, hMod, 0);
        return (_hMouse != IntPtr.Zero || _hKbd != IntPtr.Zero);
    }

    public static void Uninstall()
    {
        if (_hMouse != IntPtr.Zero) { UnhookWindowsHookEx(_hMouse); _hMouse = IntPtr.Zero; }
        if (_hKbd   != IntPtr.Zero) { UnhookWindowsHookEx(_hKbd);   _hKbd   = IntPtr.Zero; }
    }

    // 低级钩子要在装钩子的线程上抽消息才会被回调
    public static void Pump()
    {
        MSG msg;
        while (PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_REMOVE)) { }
    }

    public static uint NowTick() { return GetTickCount(); }

    public static void ResetCounter() { _realEventCount = 0; _lastRealInputTick = GetTickCount(); }

    public static int LastRealEventAgeMs()
    {
        if (_realEventCount == 0) return -1;
        return (int)(GetTickCount() - _lastRealInputTick);
    }

    // 系统层面"上次输入"的时刻，注意它把注入的也算在内
    public static uint LastInputTick()
    {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref li)) return 0;
        return li.dwTime;
    }

    public static int SystemIdleMs()
    {
        uint t = LastInputTick();
        if (t == 0) return -1;
        return (int)(GetTickCount() - t);
    }

    // 观察指定时长，返回期间真人输入次数
    public static int Watch(int ms)
    {
        ResetCounter();
        uint start = GetTickCount();
        while ((GetTickCount() - start) < (uint)ms)
        {
            Pump();
            Thread.Sleep(40);
        }
        return _realEventCount;
    }
}
'@
}

# ---------------------------------------------------------------- 状态文件
function Read-State {
    if (Test-Path $StatePath) {
        try {
            $o = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            return [pscustomobject]@{
                InjectTick = [uint32]$o.InjectTick
                HumanTick  = [uint32]$o.HumanTick
            }
        } catch { }
    }
    return [pscustomobject]@{ InjectTick = [uint32]0; HumanTick = [uint32]0 }
}

function Write-State {
    param([uint32]$InjectTick, [uint32]$HumanTick)
    [pscustomobject]@{ InjectTick = $InjectTick; HumanTick = $HumanTick } |
        ConvertTo-Json -Compress | Set-Content -Path $StatePath -Encoding UTF8
}

# tick 是 32 位会回绕的。直接用 [uint32]($Now - $Then) 在 $Then > $Now 时会算出负数，
# 强转会抛异常并把等待循环整个打断，所以这里先按 64 位算再取模。
function Get-TickDelta {
    param([uint32]$Now, [uint32]$Then)
    $d = [int64]$Now - [int64]$Then
    if ($d -lt 0) { $d += 4294967296 }
    return [uint32]($d % 4294967296)
}

# 判断"最近一次输入"是不是自动化自己注入的
function Test-LastInputIsOurs {
    param($State, [uint32]$LastTick)
    if ($State.InjectTick -eq 0) { return $false }
    return ((Get-TickDelta -Now $LastTick -Then $State.InjectTick) -lt 500)
}

# 推算真人静默了多久。-1 表示算不出来（没有可信的历史）。
function Get-HumanIdleMs {
    $st = Read-State
    $now = [InputGuard]::NowTick()
    $last = [InputGuard]::LastInputTick()

    if (Test-LastInputIsOurs -State $st -LastTick $last) {
        if ($st.HumanTick -ne 0) {
            return (Get-TickDelta -Now $now -Then $st.HumanTick)
        }
        # 没有真人输入的历史。但"最近一次输入是我自己注入的"这件事本身
        # 就能推出一个可信下界：既然那之后没人碰过，真人至少从我记账那刻
        # 起就静默了。没有这一条的话，状态文件刚建好时头两次调用会白等。
        return (Get-TickDelta -Now $now -Then $st.InjectTick)
    }
    return (Get-TickDelta -Now $now -Then $last)
}

# ---------------------------------------------------------------- -MarkInject
if ($MarkInject) {
    $st = Read-State
    $now = [InputGuard]::NowTick()
    $last = [InputGuard]::LastInputTick()

    # 关键一步：在注入之前看一眼"上一次输入是谁干的"。
    # 如果它不是我们上次注入的那一下，那就是真人干的，记下来。
    if ($last -ne 0 -and -not (Test-LastInputIsOurs -State $st -LastTick $last)) {
        $st.HumanTick = $last
    }

    Write-State -InjectTick $now -HumanTick $st.HumanTick
    if (-not $Quiet) {
        Write-Host ("记账: 注入时刻={0} 已确认的真人输入时刻={1}" -f $now, $st.HumanTick)
    }
    exit 0
}

# ---------------------------------------------------------------- -Status
if ($Status) {
    $st = Read-State
    $now = [InputGuard]::NowTick()
    $last = [InputGuard]::LastInputTick()
    $isOurs = Test-LastInputIsOurs -State $st -LastTick $last
    $humanIdle = Get-HumanIdleMs

    $ok = [InputGuard]::Install()
    $realAge = [InputGuard]::LastRealEventAgeMs()
    [InputGuard]::Uninstall()

    if (-not $Quiet) {
        Write-Host "钩子装上: $ok"
        Write-Host "系统空闲（含注入输入）: $([InputGuard]::SystemIdleMs()) ms"
        Write-Host "最近一次输入是自动化注入的: $isOurs"
        if ($humanIdle -ge 0) { Write-Host "推算真人静默: $humanIdle ms" } else { Write-Host "推算真人静默: 未知（还没有记账历史）" }
        if ($realAge -ge 0) { Write-Host "本次钩子观察到真人输入: $realAge ms 前" } else { Write-Host "本次钩子未见真人输入" }
    }

    [pscustomobject]@{
        SystemIdleMs    = [InputGuard]::SystemIdleMs()
        LastWasInjected = $isOurs
        HumanIdleMs     = $humanIdle
    }
    exit 0
}

# ---------------------------------------------------------------- -Watch
if ($PSBoundParameters.ContainsKey('Watch')) {
    $ms = [int]($Watch * 1000)
    $ok = [InputGuard]::Install()
    if (-not $Quiet) { Write-Host "观察 $Watch 秒（钩子装上: $ok）..." }
    $count = [InputGuard]::Watch($ms)
    [InputGuard]::Uninstall()

    if (-not $Quiet) {
        if ($count -gt 0) { Write-Host "检测到真人输入 $count 次" } else { Write-Host "这段时间没有真人输入" }
    }
    [pscustomobject]@{ Seconds = $Watch; RealEvents = $count }
    exit 0
}

# ---------------------------------------------------------------- -WaitIdle
$needMs    = [int]($WaitIdle * 1000)
$timeoutMs = [int]($Timeout * 1000)

# 第一关：先算账。推算出来真人早就静默够久了就直接放行，不用等。
$humanIdle = Get-HumanIdleMs
if ($humanIdle -ge $needMs) {
    if (-not $Quiet) { Write-Host "放行：真人已静默 $([math]::Round($humanIdle/1000,1)) 秒" }
    exit 0
}

# 第二关：静默不够，装钩子实等。
# 只认"真人"事件，所以自动化自己注入的输入不会把等待无限拖下去。
$ok = [InputGuard]::Install()
if (-not $ok) {
    Write-Warning "操作保护未能生效：全局钩子装不上。"
    exit 0
}

if (-not $Quiet) {
    if ($humanIdle -ge 0) {
        Write-Host "真人 $([math]::Round($humanIdle/1000,1)) 秒前还在操作，等到静默 $WaitIdle 秒再继续（最多等 $Timeout 秒）..."
    } else {
        Write-Host "等真人静默 $WaitIdle 秒（最多等 $Timeout 秒）..."
    }
}

[InputGuard]::ResetCounter()
$sw = [Diagnostics.Stopwatch]::StartNew()
$passed = $false

while ($sw.Elapsed.TotalMilliseconds -lt $timeoutMs) {
    [InputGuard]::Pump()

    # 钩子见过真人输入就按钩子算，否则退回状态文件推算的值
    $realAge = [InputGuard]::LastRealEventAgeMs()
    $idle = if ($realAge -ge 0) { $realAge } else { Get-HumanIdleMs }

    if ($idle -ge $needMs) { $passed = $true; break }
    Start-Sleep -Milliseconds 60
}

$elapsed = $sw.Elapsed.TotalSeconds
[InputGuard]::Uninstall()

if (-not $passed) {
    if (-not $Quiet) { Write-Host "超时：$Timeout 秒内你一直在操作，本次放弃。" }
    exit 1
}

if (-not $Quiet) { Write-Host "可以了：真人已静默够久（等待耗时 $([math]::Round($elapsed,1)) 秒）" }
exit 0
