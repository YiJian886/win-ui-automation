#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 屏幕抓取 —— 全屏 / 指定显示器 / 指定窗口 / 任意矩形区域。

.DESCRIPTION
    纯 .NET + Win32 P/Invoke 实现，不依赖任何外部工具。
    窗口抓取优先用 PrintWindow(PW_RENDERFULLCONTENT=2)，即使窗口被遮挡
    也能抓到内容；失败时回退到按窗口矩形从屏幕拷贝。

.PARAMETER List
    列出所有可见顶层窗口（标题 + 句柄 + 矩形），不截图。

.PARAMETER Window
    按标题正则匹配窗口并只截该窗口。匹配到多个时取第一个，用 -All 可全部截。

.PARAMETER Region
    截取屏幕坐标矩形，格式 x,y,w,h（如 -Region 0,0,800,600）。

.PARAMETER Out
    输出 PNG 路径。默认 <脚本目录>\shots\shot-<时间戳>.png

.PARAMETER BringToFront
    截图前把目标窗口置前（仅影响窗口模式；PrintWindow 不需要）。

.EXAMPLE
    .\screenshot.ps1
    截整个虚拟桌面（所有显示器）。

.EXAMPLE
    .\screenshot.ps1 -List

.EXAMPLE
    .\screenshot.ps1 -Window 'Edge' -Out .\shots\edge.png

.EXAMPLE
    .\screenshot.ps1 -Region 0,0,1024,768
#>
[CmdletBinding(DefaultParameterSetName = 'Screen')]
param(
    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$List,

    [Parameter(ParameterSetName = 'Window', Mandatory = $true)]
    [string]$Window,

    [Parameter(ParameterSetName = 'Region', Mandatory = $true)]
    [string]$Region,

    [Parameter(ParameterSetName = 'Window')]
    [switch]$All,

    [Parameter(ParameterSetName = 'Window')]
    [switch]$BringToFront,

    [string]$Out
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

. (Join-Path $PSScriptRoot 'native.ps1')
Import-NativeType -TypeName 'WinCap' -Source @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WinCap
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public class WinInfo
    {
        public IntPtr Handle;
        public string Title;
        public int X, Y, W, H;
        public bool Minimized;
    }

    public static List<WinInfo> ListVisibleWindows()
    {
        var result = new List<WinInfo>();
        EnumWindows((h, l) =>
        {
            if (!IsWindowVisible(h)) return true;
            int len = GetWindowTextLength(h);
            if (len == 0) return true;
            var sb = new StringBuilder(len + 1);
            GetWindowText(h, sb, sb.Capacity);
            string title = sb.ToString();
            if (string.IsNullOrWhiteSpace(title)) return true;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            result.Add(new WinInfo {
                Handle = h, Title = title,
                X = r.Left, Y = r.Top,
                W = r.Right - r.Left, H = r.Bottom - r.Top,
                Minimized = IsIconic(h)
            });
            return true;
        }, IntPtr.Zero);
        return result;
    }

    // ---- DPI 感知 ----
    // 必须显式声明，否则本进程是 DPI-unaware：GetWindowRect 返回被虚拟化的
    // 逻辑坐标（如 2048x1152），而 SetCursorPos/GetPhysicalCursorPos 用物理像素
    // （2560x1440），两者相差缩放比（本机 1.25x），导致按截图坐标点击会偏 25%。
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern IntPtr SetProcessDpiAwarenessContext(IntPtr value);

    public static string EnableDpiAwareness()
    {
        try {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 == (HANDLE)-4
            if (SetProcessDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero) return "PerMonitorV2";
        } catch { }
        try {
            if (SetProcessDPIAware()) return "SystemAware";
        } catch { }
        return "unchanged";
    }
}
'@


# 尽早声明 DPI 感知，务必在任何取坐标/抓屏之前调用
$script:DpiMode = [WinCap]::EnableDpiAwareness()

function Get-DefaultOut {
    param([string]$Kind)
    if ($Out) { return $Out }
    $dir = Join-Path $PSScriptRoot 'shots'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir ("shot-{0}-{1}.png" -f $Kind, (Get-Date -Format 'yyyyMMdd-HHmmss')))
}

function Save-Bitmap {
    param([System.Drawing.Bitmap]$Bitmap, [string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $f = Get-Item $Path
    [pscustomobject]@{
        Path   = $f.FullName
        SizeKB = [math]::Round($f.Length / 1KB, 1)
        Pixels = "$($Bitmap.Width)x$($Bitmap.Height)"
    }
}

# ---------------------------------------------------------------- -List
if ($List) {
    $wins = [WinCap]::ListVisibleWindows() | Sort-Object { $_.Title }
    $i = 0
    $rows = foreach ($w in $wins) {
        [pscustomobject]@{
            Id        = $i++
            Handle    = ('0x{0:X}' -f $w.Handle.ToInt64())
            Rect      = "$($w.X),$($w.Y) $($w.W)x$($w.H)"
            Minimized = $w.Minimized
            Title     = if ($w.Title.Length -gt 70) { $w.Title.Substring(0, 70) + '…' } else { $w.Title }
        }
    }
    $rows | Format-Table -AutoSize
    return
}

# ---------------------------------------------------------------- 窗口模式
if ($Window) {
    $wins = [WinCap]::ListVisibleWindows() | Where-Object { $_.Title -match $Window }
    if (-not $wins) { throw "没有匹配 '$Window' 的可见窗口。用 -List 看有哪些。" }
    if (-not $All) { $wins = @($wins | Select-Object -First 1) }

    $singlePath = Get-DefaultOut -Kind 'win'
    $multiDir = Split-Path -Parent $singlePath
    $multiBase = [System.IO.Path]::GetFileNameWithoutExtension($singlePath)

    foreach ($w in $wins) {
        if ($BringToFront -and -not $w.Minimized) {
            [WinCap]::ShowWindow($w.Handle, 9) | Out-Null   # SW_RESTORE
            [WinCap]::SetForegroundWindow($w.Handle) | Out-Null
            Start-Sleep -Milliseconds 250
        }

        $w = ([WinCap]::ListVisibleWindows() | Where-Object { $_.Handle -eq $w.Handle })
        if (-not $w) { continue }
        $width = [math]::Max($w.W, 1); $height = [math]::Max($w.H, 1)

        $bmp = New-Object System.Drawing.Bitmap($width, $height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        $ok = [WinCap]::PrintWindow($w.Handle, $hdc, 2)   # PW_RENDERFULLCONTENT
        $g.ReleaseHdc($hdc)
        $g.Dispose()

        if (-not $ok) {
            # 回退：从屏幕按窗口矩形抓（要求窗口未被完全遮挡）
            $bmp.Dispose()
            $bmp = New-Object System.Drawing.Bitmap($width, $height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($w.X, $w.Y, 0, 0, (New-Object System.Drawing.Size($width, $height)))
            $g.Dispose()
        }

        $path = if ($All) {
            Join-Path $multiDir ("$multiBase-$($w.Handle.ToInt64()).png")
        } else { $singlePath }

        $res = Save-Bitmap -Bitmap $bmp -Path $path
        $bmp.Dispose()
        [pscustomobject]@{ Path = $res.Path; SizeKB = $res.SizeKB; Pixels = $res.Pixels; Window = $w.Title }
    }
    return
}

# ---------------------------------------------------------------- 区域模式
if ($Region) {
    # -File 调用时参数是字符串 "x,y,w,h"；直接调用时可能是数组。两种都吃。
    $parts = if ($Region -is [string]) {
        @($Region -split '[,;\s]+' | Where-Object { $_ -ne '' })
    } else { @($Region) }
    if ($parts.Count -ne 4) { throw "-Region 需要 4 个值 x,y,w,h（收到 $($parts.Count) 个：$($parts -join '|')）" }
    $x = [int]$parts[0]; $y = [int]$parts[1]; $w = [int]$parts[2]; $h = [int]$parts[3]
    if ($w -le 0 -or $h -le 0) { throw "-Region 的宽高必须为正数（收到 ${w}x${h}）" }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    $res = Save-Bitmap -Bitmap $bmp -Path (Get-DefaultOut -Kind 'region')
    $bmp.Dispose()
    [pscustomobject]@{ Path = $res.Path; SizeKB = $res.SizeKB; Pixels = $res.Pixels; Region = "$x,$y $($w)x$($h)" }
    return
}

# ---------------------------------------------------------------- 全屏模式（默认）
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
$g.Dispose()
$res = Save-Bitmap -Bitmap $bmp -Path (Get-DefaultOut -Kind 'full')
$bmp.Dispose()
[pscustomobject]@{
    Path    = $res.Path
    SizeKB  = $res.SizeKB
    Pixels  = $res.Pixels
    Virtual = "origin=($($vs.X),$($vs.Y)) size=$($vs.Width)x$($vs.Height)"
}
