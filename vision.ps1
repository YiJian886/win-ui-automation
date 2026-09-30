#Requires -Version 5.1
<#
.SYNOPSIS
    从截图里找出界面元素（文字 + 坐标），给 ui.ps1 当眼睛用。

.DESCRIPTION
    两个后端：

    ocr         Windows 自带的 OCR（Windows.Media.Ocr）。零依赖，不用装任何东西，
                能认出屏幕上的所有文字及其外框。找按钮靠的是按钮上的字。

    omniparser  微软 OmniParser。除了文字还能认出图标，并给图标生成语义描述。
                需要你自己起一个服务（见 README），脚本这边只发 HTTP 请求。

    坐标一律相对截图左上角。配合 ui.ps1 的 -Window 相对坐标可以直接点。

.PARAMETER Image
    要识别的 PNG 路径。不给就用 -Window / -Region 现场截一张。

.PARAMETER Window
    现场截这个窗口（标题正则），交给识别。

.PARAMETER Region
    现场截这块矩形 x,y,w,h。

.PARAMETER Backend
    ocr / omniparser / auto（auto = 先试 omniparser，连不上就退回 ocr）。

.PARAMETER OmniParserUrl
    OmniParser 服务地址。默认取环境变量 OMNIPARSER_URL，没有就用 http://127.0.0.1:7860。

.PARAMETER Match
    只输出文字匹配这个正则的元素。

.PARAMETER Json
    输出 JSON，方便别的程序吃。

.PARAMETER Out
    截图落盘路径（只在现场截图时用）。

.EXAMPLE
    .\vision.ps1 -Window '记事本'
    截记事本，OCR 出所有文字和坐标。

.EXAMPLE
    .\vision.ps1 -Window '记事本' -Match '保存|另存为'
    只看名字里带"保存"的元素。

.EXAMPLE
    .\vision.ps1 -Image .\shots\a.png -Backend omniparser -Json
#>
[CmdletBinding()]
param(
    [string]$Image,
    [string]$Window,
    [string]$Region,

    [ValidateSet('ocr', 'omniparser', 'auto')]
    [string]$Backend = 'ocr',

    [string]$OmniParserUrl = $(if ($env:OMNIPARSER_URL) { $env:OMNIPARSER_URL } else { 'http://127.0.0.1:7860' }),

    [string]$Match,
    [switch]$Json,
    [string]$Out,
    [double]$BoxThreshold = 0.05,
    [double]$IouThreshold = 0.1
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 准备图片
function Resolve-Image {
    if ($Image) {
        if (-not (Test-Path $Image)) { throw "找不到图片: $Image" }
        return (Resolve-Path $Image).Path
    }
    if (-not $Window -and -not $Region) {
        throw '要么给 -Image，要么给 -Window / -Region 让脚本自己截。'
    }

    $ss = Join-Path $PSScriptRoot 'screenshot.ps1'
    if (-not (Test-Path $ss)) { throw "同目录下找不到 screenshot.ps1，没法现场截图。" }

    $target = if ($Out) { $Out } else {
        $dir = Join-Path $PSScriptRoot 'shots'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Join-Path $dir ("vision-{0}.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }

    $ssArgs = @{ Out = $target }
    if ($Window) { $ssArgs['Window'] = $Window }
    if ($Region) { $ssArgs['Region'] = $Region }

    $res = & $ss @ssArgs
    if (-not $res -or -not $res.Path) { throw '截图失败。' }
    return $res.Path
}

$imgPath = Resolve-Image
Add-Type -AssemblyName System.Drawing
$bmp = [System.Drawing.Bitmap]::FromFile($imgPath)
$imgW = $bmp.Width
$imgH = $bmp.Height
$bmp.Dispose()

# ---------------------------------------------------------------- OCR 后端
# Windows.Media.Ocr 是 WinRT 类型，PowerShell 5.1 里要手动等它的异步操作。
$script:AsTaskGeneric = $null

function Initialize-WinRt {
    if ($script:AsTaskGeneric) { return }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $m = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    }
    if (-not $m) { throw '拿不到 WinRT 的 AsTask 方法，当前 PowerShell 可能不支持。' }
    $script:AsTaskGeneric = $m[0]
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime]
}

function Await-WinRt {
    param($Operation, [Type]$ResultType)
    $task = $script:AsTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait(-1) | Out-Null
    return $task.Result
}

function Get-OcrElements {
    param([string]$Path)

    Initialize-WinRt

    $file = Await-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    $stream = Await-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $software = Await-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (-not $engine) {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language 'en-US'))
    }
    if (-not $engine) { throw '系统没装任何 OCR 语言包，-Backend ocr 用不了。' }

    $result = Await-WinRt ($engine.RecognizeAsync($software)) ([Windows.Media.Ocr.OcrResult])

    $stream.Dispose()

    foreach ($line in $result.Lines) {
        # 一行里可能有好几个词，取它们的并集当这一行的框
        $x1 = [double]::MaxValue; $y1 = [double]::MaxValue
        $x2 = [double]::MinValue; $y2 = [double]::MinValue
        foreach ($word in $line.Words) {
            $r = $word.BoundingRect
            if ($r.X -lt $x1) { $x1 = $r.X }
            if ($r.Y -lt $y1) { $y1 = $r.Y }
            if (($r.X + $r.Width) -gt $x2) { $x2 = $r.X + $r.Width }
            if (($r.Y + $r.Height) -gt $y2) { $y2 = $r.Y + $r.Height }
        }
        if ($x1 -eq [double]::MaxValue) { continue }

        [pscustomobject]@{
            Source = 'ocr'
            Type   = 'text'
            Text   = $line.Text
            # Windows OCR 会在汉字之间插空格（"评 论"），匹配时用去掉空格的版本
            Norm   = ($line.Text -replace '\s+', '')
            X1     = [int]$x1
            Y1     = [int]$y1
            X2     = [int]$x2
            Y2     = [int]$y2
            X      = [int](($x1 + $x2) / 2)
            Y      = [int](($y1 + $y2) / 2)
            W      = [int]($x2 - $x1)
            H      = [int]($y2 - $y1)
            Score  = 1.0
        }
    }
}

# ---------------------------------------------------------------- OmniParser 后端
function Get-OmniParserElements {
    param([string]$Path, [string]$BaseUrl)

    $url = $BaseUrl.TrimEnd('/') + '/process_image'
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $boundary = [System.Guid]::NewGuid().ToString('N')

    $head = "--$boundary`r`n" +
            "Content-Disposition: form-data; name=`"image_file`"; filename=`"shot.png`"`r`n" +
            "Content-Type: image/png`r`n`r`n"
    $mid = "`r`n--$boundary`r`n" +
           "Content-Disposition: form-data; name=`"box_threshold`"`r`n`r`n$BoxThreshold`r`n" +
           "--$boundary`r`n" +
           "Content-Disposition: form-data; name=`"iou_threshold`"`r`n`r`n$IouThreshold`r`n" +
           "--$boundary--`r`n"

    $headBytes = [System.Text.Encoding]::UTF8.GetBytes($head)
    $midBytes = [System.Text.Encoding]::UTF8.GetBytes($mid)
    $body = New-Object byte[] ($headBytes.Length + $bytes.Length + $midBytes.Length)
    [Array]::Copy($headBytes, 0, $body, 0, $headBytes.Length)
    [Array]::Copy($bytes, 0, $body, $headBytes.Length, $bytes.Length)
    [Array]::Copy($midBytes, 0, $body, $headBytes.Length + $bytes.Length, $midBytes.Length)

    $resp = Invoke-RestMethod -Uri $url -Method Post -ContentType "multipart/form-data; boundary=$boundary" -Body $body -TimeoutSec 180

    # 返回的 label_coordinates 是 Python dict 的字符串表示，坐标是 0~1 的比值
    $coords = @{}
    $raw = [string]$resp.label_coordinates
    foreach ($m in [regex]::Matches($raw, "(\d+)\s*:\s*\[\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*\]")) {
        $coords[[int]$m.Groups[1].Value] = @(
            [double]$m.Groups[2].Value, [double]$m.Groups[3].Value,
            [double]$m.Groups[4].Value, [double]$m.Groups[5].Value
        )
    }

    # parsed_content_list 每行形如：  3: icon, Text: 搜索
    $labels = @{}
    foreach ($line in ([string]$resp.parsed_content_list -split "`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^(\d+)\s*:\s*(.*)$') {
            $labels[[int]$matches[1]] = $matches[2].Trim()
        }
    }

    foreach ($idx in ($coords.Keys | Sort-Object)) {
        $c = $coords[$idx]
        $label = if ($labels.ContainsKey($idx)) { $labels[$idx] } else { '' }

        $type = 'icon'
        $text = $label
        if ($label -match '(?i)^icon\s*,\s*(?:Text:\s*)?(.*)$') {
            $type = 'icon'
            $text = $matches[1].Trim()
        } elseif ($label -match '(?i)^text\s*,\s*(?:Text:\s*)?(.*)$') {
            $type = 'text'
            $text = $matches[1].Trim()
        }

        $x1 = $c[0] * $imgW; $y1 = $c[1] * $imgH
        $x2 = $c[2] * $imgW; $y2 = $c[3] * $imgH
        if ($x1 -gt $x2) { $tmp = $x1; $x1 = $x2; $x2 = $tmp }
        if ($y1 -gt $y2) { $tmp = $y1; $y1 = $y2; $y2 = $tmp }

        [pscustomobject]@{
            Source = 'omniparser'
            Type   = $type
            Text   = $text
            Norm   = ($text -replace '\s+', '')
            X1     = [int]$x1
            Y1     = [int]$y1
            X2     = [int]$x2
            Y2     = [int]$y2
            X      = [int](($x1 + $x2) / 2)
            Y      = [int](($y1 + $y2) / 2)
            W      = [int]($x2 - $x1)
            H      = [int]($y2 - $y1)
            Score  = 1.0
        }
    }
}

# ---------------------------------------------------------------- 跑后端
function Test-OmniParser {
    param([string]$BaseUrl)
    try {
        $r = Invoke-WebRequest -Uri ($BaseUrl.TrimEnd('/') + '/docs') -UseBasicParsing -TimeoutSec 3
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

$usedBackend = $Backend
if ($Backend -eq 'auto') {
    if (Test-OmniParser $OmniParserUrl) { $usedBackend = 'omniparser' }
    else {
        Write-Verbose "OmniParser 服务连不上（$OmniParserUrl），退回 ocr"
        $usedBackend = 'ocr'
    }
}

Write-Verbose "识别 $imgPath  (${imgW}x${imgH})，后端=$usedBackend"

$elements = switch ($usedBackend) {
    'ocr'         { Get-OcrElements -Path $imgPath }
    'omniparser'  { Get-OmniParserElements -Path $imgPath -BaseUrl $OmniParserUrl }
}

$list = @($elements)
if ($Match) { $list = @($list | Where-Object { $_.Text -match $Match -or $_.Norm -match $Match }) }

if ($Json) {
    [pscustomobject]@{
        image    = $imgPath
        width    = $imgW
        height   = $imgH
        backend  = $usedBackend
        count    = $list.Count
        elements = $list
    } | ConvertTo-Json -Depth 4
    return
}

if ($list.Count -eq 0) {
    Write-Host "没识别到元素$(if ($Match) { "（匹配 '$Match'）" })。"
    return
}

$list | Select-Object Source, Type,
    @{ n = 'Text'; e = { if ($_.Text.Length -gt 46) { $_.Text.Substring(0, 46) + '…' } else { $_.Text } } },
    X, Y, W, H |
    Format-Table -AutoSize
