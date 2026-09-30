#Requires -Version 5.1
<#
.SYNOPSIS
    C# 代码的编译缓存。给 ui.ps1 / screenshot.ps1 / guard.ps1 共用。

.DESCRIPTION
    这几个脚本都靠 Add-Type -TypeDefinition 现场编译一段 C# 来调 Win32。
    实测编译一段 263 行的 P/Invoke 类要 ~103 ms，而加载一个预编译好的 DLL
    只要 ~10 ms。

    所以这里按源码内容做哈希，编好的 DLL 缓存在本地，下次直接加载。
    源码一改哈希就变，自然失效，不用手动清。

    说实话这点收益不大（每次调用省 ~93 ms，批量模式下一次任务才省一次），
    但它是纯收益、零风险，顺手就做了。

    缓存位置：%LOCALAPPDATA%\win-ui-automation\native\
#>
[CmdletBinding()]
param()

function Import-NativeType {
    [CmdletBinding()]
    param(
        # C# 源码
        [Parameter(Mandatory = $true)][string]$Source,
        # 源码里主要的那个类型名，用来判断是否已经加载过
        [Parameter(Mandatory = $true)][string]$TypeName,
        # 忽略缓存，强制重新编译
        [switch]$Force
    )

    # 已经加载过就不用再折腾
    if ($TypeName -as [type]) { return }

    $cacheDir = Join-Path $env:LOCALAPPDATA 'win-ui-automation\native'

    try {
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null }
    } catch {
        # 缓存目录建不出来就直接现场编译，别把事情搞砸
        Add-Type -TypeDefinition $Source
        return
    }

    # 哈希里带上 PowerShell 版本：不同版本的编译器产出的程序集不通用
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Source + '|' + $PSVersionTable.PSVersion.ToString())
    $hash = ($sha.ComputeHash($keyBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $dll = Join-Path $cacheDir ("{0}-{1}.dll" -f $TypeName, $hash.Substring(0, 16))

    if ($Force -and (Test-Path $dll)) { Remove-Item $dll -Force -ErrorAction SilentlyContinue }

    # 加载 DLL 用 Assembly.LoadFrom 而不是 Add-Type -Path。
    # 实测 Add-Type -Path 净开销 89 ms（比现场编译只快 14 ms，等于白折腾），
    # 而 LoadFrom 只要 22 ms。类型照样能被 [TypeName] 解析到。
    if (Test-Path $dll) {
        try {
            [void][System.Reflection.Assembly]::LoadFrom($dll)
            return
        } catch {
            # 缓存坏了（被杀软改过、编译中途断电之类），删掉重编
            Write-Verbose "缓存 DLL 加载失败，重新编译: $($_.Exception.Message)"
            Remove-Item $dll -Force -ErrorAction SilentlyContinue
        }
    }

    Add-Type -TypeDefinition $Source -OutputAssembly $dll
    [void][System.Reflection.Assembly]::LoadFrom($dll)

    # 顺手清掉过期的缓存（源码改版后留下的旧 DLL）
    try {
        Get-ChildItem $cacheDir -Filter "$TypeName-*.dll" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $dll } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}
