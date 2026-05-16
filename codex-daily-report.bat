<# : batch
@echo off
setlocal EnableExtensions
set "HYBRID_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand SQBuAHYAbwBrAGUALQBFAHgAcAByAGUAcwBzAGkAbwBuACAAKABHAGUAdAAtAEMAbwBuAHQAZQBuAHQAIAAtAEwAaQB0AGUAcgBhAGwAUABhAHQAaAAgACQAZQBuAHYAOgBIAFkAQgBSAEkARABfAFMARQBMAEYAIAAtAFIAYQB3ACAALQBFAG4AYwBvAGQAaQBuAGcAIABVAFQARgA4ACkACgBlAHgAaQB0ACAAJABMAEEAUwBUAEUAWABJAFQAQwBPAEQARQA=
set "EXIT_CODE=%ERRORLEVEL%"
if /i "%DAILY_NO_PAUSE%"=="1" exit /b %EXIT_CODE%
echo.
echo [DAILY] Press any key to close...
pause >nul
exit /b %EXIT_CODE%
#>

# 设置错误处理策略：一旦出错立即停止
$ErrorActionPreference = 'Stop'

$global:SpinnerChars = @('|', '/', '-', '\')
$global:SpinnerIndex = 0

function Write-Spinner {
    param([string]$Text)
    $char = $global:SpinnerChars[$global:SpinnerIndex % 4]
    $global:SpinnerIndex++
    try {
        [System.Console]::Write("`r$char $Text")
    } catch {
        # Fallback if no console
    }
}

function Clear-Spinner {
    try {
        $width = 80
        try { $width = [System.Console]::WindowWidth - 1 } catch {}
        [System.Console]::Write("`r$([string]::new(' ', $width))`r")
    } catch {}
}

# ==========================================
# 核心配置参数 (支持通过环境变量覆盖)
# ==========================================
$WorkDir = ''
$OutputDir = Join-Path $HOME 'Desktop'
$CodexHome = Join-Path $HOME '.codex'
$ReportDate = ''
$TargetChars = 320
$UseApi = $true
$ApiKey = ''
$BaseUrl = ''
$Model = ''
$ConfigPath = Join-Path $CodexHome 'config.json'

$maxTextChars = 220
$maxSessionEvents = 40
$maxSessionTextItems = 12
$maxDigestChars = 7000
$reportTaskKeywords = @('日报', 'codex会话', '生成codex', '总结200字', '桌面')
$toolLabels = @{
    shell_command       = '命令执行'
    apply_patch         = '补丁改写'
    update_plan         = '计划更新'
    spawn_agent         = '子代理规划'
    send_input          = '子代理追问'
    wait_agent          = '子代理等待'
    lsp_document_symbols = '符号分析'
    lsp_find_references = '引用检索'
    lsp_diagnostics     = '诊断检查'
}
$commandLabels = @{
    'Get-ChildItem' = '目录浏览'
    'Get-Content'   = '文件读取'
    'Select-String' = '文本检索'
    'python'        = 'Python脚本'
    'mvn'           = 'Maven验证'
    'git'           = 'Git检查'
}


function Load-LocalConfig {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            if ($config.Profiles) { $script:Profiles = $config.Profiles }
            if ($config.LastProfile) { $script:LastProfile = $config.LastProfile }
            
            # 兼容老配置格式
            if ($null -eq $script:Profiles -and $config.ApiKey -and $config.BaseUrl) {
                $script:Profiles = @(
                    @{
                        Name = "默认节点"
                        BaseUrl = $config.BaseUrl
                        ApiKey = $config.ApiKey
                        Model = $config.Model
                    }
                )
                $script:LastProfile = "默认节点"
            }
        } catch {}
    }
    
    if ($null -eq $script:Profiles) {
        $script:Profiles = @()
    }
}

function Save-LocalConfig {
    $config = @{
        Profiles = $script:Profiles
        LastProfile = $script:LastProfile
    }
    if (-not (Test-Path -LiteralPath $CodexHome)) {
        New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
    }
    $configJson = $config | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($ConfigPath, $configJson, [System.Text.UTF8Encoding]::new($false))
}

function Get-RemoteModels {
    param($Url, $Key)
    try {
        $uri = $Url.TrimEnd('/') + '/models'
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Method = 'GET'
        $request.Headers['Authorization'] = "Bearer $Key"
        $request.Timeout = 10000
        
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $json = $reader.ReadToEnd() | ConvertFrom-Json
        $reader.Close()
        $response.Close()
        
        return @($json.data | ForEach-Object { $_.id })
    } catch {
        return $null
    }
}


function Truncate-Visual {
    param([string]$str, [int]$maxWidth)
    if ([string]::IsNullOrEmpty($str)) { return "" }
    $len = 0
    $result = ""
    for ($i=0; $i -lt $str.Length; $i++) {
        if ([int]$str[$i] -gt 255) { $len += 2 } else { $len += 1 }
        if ($len -gt $maxWidth -and $i -lt $str.Length - 1) {
            return $result + "..."
        }
        $result += $str[$i]
    }
    return $result
}

function Show-InteractiveMenu {
    param(
        [string]$Title,
        [array]$Items,
        [string]$DisplayProperty,
        [switch]$MultiSelect,
        [string]$SelectedProperty,
        [string]$FooterText
    )

    $Host.UI.RawUI.CursorSize = 0
    $selectedIndex = 0

    while ($true) {
        Clear-Host
        Write-Host "========== $Title ==========" -ForegroundColor Green
        
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $Items[$i]
            $prefix = "   "
            $color = "Gray"
            if ($i -eq $selectedIndex) {
                $prefix = " > "
                $color = "Cyan"
            }
            
            $text = ""
            if ($MultiSelect) {
                $isChecked = $item.$SelectedProperty
                if ($isChecked) {
                    $prefix += "[√] "
                    if ($color -eq "Gray") { $color = "White" }
                } else {
                    $prefix += "[ ] "
                }
            } else {
                $prefix += "[ ] "
            }
            
            $text = $item.$DisplayProperty
            
            $maxWidth = $Host.UI.RawUI.WindowSize.Width - 10
            $truncated = Truncate-Visual -str $text -maxWidth $maxWidth
            Write-Host "$prefix$truncated" -ForegroundColor $color
        }
        
        if ($FooterText) {
            Write-Host ""
            Write-Host $FooterText -ForegroundColor Yellow
        }

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").Character
        $keyCode = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").VirtualKeyCode
        
        if ($keyCode -eq 38 -or $key -eq 'w' -or $key -eq 'W') {
            $selectedIndex--
            if ($selectedIndex -lt 0) { $selectedIndex = $Items.Count - 1 }
        }
        elseif ($keyCode -eq 40 -or $key -eq 's' -or $key -eq 'S') {
            $selectedIndex++
            if ($selectedIndex -ge $Items.Count) { $selectedIndex = 0 }
        }
        elseif ($keyCode -eq 32) { # Space
            if ($MultiSelect) {
                $item = $Items[$selectedIndex]
                if ($item.IsAction) {
                    return $item
                } else {
                    $item.$SelectedProperty = -not $item.$SelectedProperty
                }
            }
        }
        elseif ($keyCode -eq 13) { # Enter
            $item = $Items[$selectedIndex]
            if ($MultiSelect) {
                if ($item.IsAction) {
                    return $item
                } else {
                    $item.$SelectedProperty = -not $item.$SelectedProperty
                }
            } else {
                return $item
            }
        }
        elseif ($keyCode -eq 27) { # Esc
            return $null
        }
    }
}

function Manage-ApiNodes {
    Load-LocalConfig
    
    while ($true) {
        $menuItems = New-Object System.Collections.Generic.List[object]
        
        if ($script:Profiles) {
            foreach ($profile in $script:Profiles) {
                $displayName = "$($profile.Name) ($($profile.BaseUrl))"
                if ($profile.Name -eq $script:LastProfile) {
                    $displayName = "* " + $displayName
                }
                $menuItems.Add([pscustomobject]@{ Display = $displayName; Action = 'Select'; Profile = $profile })
            }
        }
        
        $menuItems.Add([pscustomobject]@{ Display = "------------------------------------"; Action = 'None' })
        $menuItems.Add([pscustomobject]@{ Display = "[新建 API 节点]"; Action = 'New' })
        if ($script:Profiles.Count -gt 0) {
            $menuItems.Add([pscustomobject]@{ Display = "[编辑 API 节点]"; Action = 'Edit' })
            $menuItems.Add([pscustomobject]@{ Display = "[删除 API 节点]"; Action = 'Delete' })
        }
        $menuItems.Add([pscustomobject]@{ Display = "[退出系统]"; Action = 'Exit' })

        $choice = Show-InteractiveMenu -Title "请选择或管理 API 节点" -Items $menuItems -DisplayProperty "Display" -FooterText "使用 ↑↓ 切换，回车确认"
        
        if ($null -eq $choice -or $choice.Action -eq 'Exit') { exit 0 }
        if ($choice.Action -eq 'None') { continue }
        if ($choice.Action -eq 'Select') {
            $script:LastProfile = $choice.Profile.Name
            Save-LocalConfig
            return $choice.Profile
        }
        
        if ($choice.Action -eq 'New') {
            Clear-Host
            Write-Host "========== 新建 API 节点 ==========" -ForegroundColor Green
            $name = Read-Host "输入节点名称 (例如 Codex Default)"
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            
            $url = Read-Host "输入 Base URL (例如 https://www.codexcc.site)"
            if ([string]::IsNullOrWhiteSpace($url)) { continue }
            $url = $url.TrimEnd('/')
            if (-not $url.EndsWith('/v1')) { $url += '/v1' }
            
            $key = Read-Host "输入 API Key"
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            
            $newProfile = [pscustomobject]@{ Name = $name; BaseUrl = $url; ApiKey = $key; Model = "" }
            $script:Profiles += $newProfile
            $script:LastProfile = $name
            Save-LocalConfig
        }
        
        if ($choice.Action -eq 'Edit') {
            $editItems = New-Object System.Collections.Generic.List[object]
            foreach ($profile in $script:Profiles) { $editItems.Add([pscustomobject]@{ Display = $profile.Name; Profile = $profile }) }
            $editItems.Add([pscustomobject]@{ Display = "[返回]"; Action = 'Back' })
            $editChoice = Show-InteractiveMenu -Title "选择要编辑的节点" -Items $editItems -DisplayProperty "Display"
            if ($null -ne $editChoice -and $editChoice.Action -ne 'Back') {
                Clear-Host
                Write-Host "========== 编辑 API 节点: $($editChoice.Profile.Name) ==========" -ForegroundColor Green
                $newName = Read-Host "名称 [$($editChoice.Profile.Name)] (回车保持不变)"
                if (-not [string]::IsNullOrWhiteSpace($newName)) { $editChoice.Profile.Name = $newName }
                $newUrl = Read-Host "Base URL [$($editChoice.Profile.BaseUrl)] (回车保持不变)"
                if (-not [string]::IsNullOrWhiteSpace($newUrl)) {
                    $newUrl = $newUrl.TrimEnd('/')
                    if (-not $newUrl.EndsWith('/v1')) { $newUrl += '/v1' }
                    $editChoice.Profile.BaseUrl = $newUrl
                }
                $newKey = Read-Host "API Key [****] (回车保持不变)"
                if (-not [string]::IsNullOrWhiteSpace($newKey)) { $editChoice.Profile.ApiKey = $newKey }
                Save-LocalConfig
            }
        }
        
        if ($choice.Action -eq 'Delete') {
            $delItems = New-Object System.Collections.Generic.List[object]
            foreach ($profile in $script:Profiles) { $delItems.Add([pscustomobject]@{ Display = $profile.Name; Profile = $profile }) }
            $delItems.Add([pscustomobject]@{ Display = "[返回]"; Action = 'Back' })
            $delChoice = Show-InteractiveMenu -Title "选择要删除的节点" -Items $delItems -DisplayProperty "Display"
            if ($null -ne $delChoice -and $delChoice.Action -ne 'Back') {
                $newProfiles = @()
                foreach ($profile in $script:Profiles) {
                    if ($profile.Name -ne $delChoice.Profile.Name) { $newProfiles += $profile }
                }
                $script:Profiles = $newProfiles
                if ($script:LastProfile -eq $delChoice.Profile.Name) { $script:LastProfile = "" }
                Save-LocalConfig
            }
        }
    }
}

function Use-EnvOverride {
    param(
        [string]$Name,
        $CurrentValue
    )

    $candidate = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $CurrentValue
    }
    return $candidate
}

$WorkDir = Use-EnvOverride -Name 'DAILY_WORKDIR' -CurrentValue $WorkDir
$OutputDir = Use-EnvOverride -Name 'DAILY_OUTPUT_DIR' -CurrentValue $OutputDir
$CodexHome = Use-EnvOverride -Name 'DAILY_CODEX_HOME' -CurrentValue $CodexHome
$ReportDate = Use-EnvOverride -Name 'DAILY_DATE' -CurrentValue $ReportDate
$ApiKey = Use-EnvOverride -Name 'DAILY_API_KEY' -CurrentValue $ApiKey
$BaseUrl = Use-EnvOverride -Name 'DAILY_BASE_URL' -CurrentValue $BaseUrl
$Model = Use-EnvOverride -Name 'DAILY_MODEL' -CurrentValue $Model

$targetCharsOverride = [Environment]::GetEnvironmentVariable('DAILY_TARGET_CHARS')
if (-not [string]::IsNullOrWhiteSpace($targetCharsOverride)) {
    $parsedTargetChars = 0
    if ([int]::TryParse($targetCharsOverride, [ref]$parsedTargetChars)) {
        $TargetChars = $parsedTargetChars
    }
}

$useApiOverride = [Environment]::GetEnvironmentVariable('DAILY_USE_API')
if (-not [string]::IsNullOrWhiteSpace($useApiOverride)) {
    $UseApi = $useApiOverride.Trim().ToLowerInvariant() -notin @('0', 'false', 'no')
}

if ([string]::IsNullOrWhiteSpace($ReportDate)) {
    $ReportDate = Get-Date -Format 'yyyy-MM-dd'
}

if ($TargetChars -lt 200) {
    $TargetChars = 200
}
elseif ($TargetChars -gt 500) {
    $TargetChars = 500
}

function Select-InteractiveWorkDir {
    if (-not [string]::IsNullOrWhiteSpace($WorkDir)) { return }
    Write-Host "正在检索历史分析过的项目目录(进度: 读取中)..." -ForegroundColor Cyan
    $recentDirs = New-Object System.Collections.Generic.List[string]
    $sessionRoot = Join-Path $CodexHome 'sessions'
    if (Test-Path -LiteralPath $sessionRoot) {
        $recentFiles = Get-ChildItem -Path $sessionRoot -Recurse -Filter '*.jsonl' | Sort-Object LastWriteTime -Descending | Select-Object -First 80
        foreach ($file in $recentFiles) {
            $fileContent = Get-Content $file.FullName -TotalCount 8 -Encoding UTF8 -ErrorAction SilentlyContinue
            foreach ($line in $fileContent) {
                if ($line -match '"cwd"\s*:\s*"([^"]+)"') {
                    $cwd = $Matches[1].Replace('\\', '\')
                    if (Test-Path -LiteralPath $cwd) {
                        if (-not $recentDirs.Contains($cwd)) {
                            [void]$recentDirs.Add($cwd)
                        }
                    }
                }
            }
        }
    }

    # 如果没有检索到历史会话目录，则保持列表为空（用户将直接进入“自选其他目录”流程）

    Write-Host "`n========== 请选择要生成日报的工作目录 ==========" -ForegroundColor Green
    for ($i=0; $i -lt $recentDirs.Count; $i++) {
        Write-Host " [$($i+1)] $($recentDirs[$i])" -ForegroundColor Cyan
    }
    $customIdx = $recentDirs.Count + 1
    Write-Host " [$customIdx] 自选其他目录 (将弹出文件夹选择框)..." -ForegroundColor Yellow

    $choice = Read-Host "`n请输入对应序号"
    if ($choice -eq [string]$customIdx) {
        Write-Host "请在弹出的窗口中选择目录..." -ForegroundColor Cyan
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.BrowseForFolder(0, "请选择要生成日报的工作目录", 0, 0)
        if ($folder) {
            $script:WorkDir = $folder.Self.Path
        } else {
            Write-Host "未选择目录，取消生成。" -ForegroundColor Red
            exit 1
        }
    } elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $recentDirs.Count) {
        $script:WorkDir = $recentDirs[[int]$choice - 1]
    } else {
        Write-Host "无效的选择，退出。" -ForegroundColor Red
        exit 1
    }
    Write-Host "选定的工作目录: $WorkDir`n" -ForegroundColor Green
}
Select-InteractiveWorkDir


function Normalize-PathValue {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetFullPath($PathValue).TrimEnd('\')
    }
    catch {
        return $PathValue.TrimEnd('\')
    }
}

function Test-SameOrChildPath {
    param(
        [string]$Candidate,
        [string]$Root
    )

    $candidateValue = Normalize-PathValue $Candidate
    $rootValue = Normalize-PathValue $Root
    if ([string]::IsNullOrWhiteSpace($candidateValue) -or [string]::IsNullOrWhiteSpace($rootValue)) {
        return $false
    }
    if ($candidateValue.Equals($rootValue, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $candidateValue.StartsWith($rootValue + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Clean-Text {
    param(
        [AllowNull()][string]$Text,
        [int]$Limit = $maxTextChars
    )

    if ($null -eq $Text) {
        $sourceText = ''
    }
    else {
        $sourceText = [string]$Text
    }

    $compact = [regex]::Replace($sourceText, '\s+', ' ').Trim()
    if ($compact.Length -le $Limit) {
        return $compact
    }
    return $compact.Substring(0, [Math]::Max($Limit - 1, 0)).TrimEnd() + '...'
}

function Strip-SkillLinkPrefix {
    param([string]$Text)

    if ($null -eq $Text) {
        $sourceText = ''
    }
    else {
        $sourceText = [string]$Text
    }

    return ([regex]::Replace($sourceText, '^\s*(\[[^\]]+\]\([^)]+\)\s*)+', '')).Trim()
}

function Test-NoiseMessage {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $true
    }
    if ($Text.StartsWith('# AGENTS.md instructions for ')) {
        return $true
    }
    if ($Text.Contains('<INSTRUCTIONS>') -and $Text.Contains('AUTONOMOUS CODING AGENT')) {
        return $true
    }
    if ($Text.Contains('<subagent_notification>') -or $Text.Contains('agent_message') -or $Text.Contains('memory_citation')) {
        return $true
    }
    if ($Text.TrimStart().StartsWith('PLEASE IMPLEMENT THIS PLAN', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $false
}

function Normalize-TaskText {
    param([string]$Text)

    $normalized = Strip-SkillLinkPrefix $Text
    $normalized = [regex]::Replace($normalized, '^[请麻烦帮忙我需要把将]+\s*', '')
    return Clean-Text $normalized
}

function Test-ReportTask {
    param([string]$Text)

    $normalized = (Normalize-TaskText $Text).ToLowerInvariant()
    foreach ($keyword in $reportTaskKeywords) {
        if ($normalized.Contains($keyword.ToLowerInvariant())) {
            return $true
        }
    }
    return $false
}

function Test-ProjectBusinessMessage {
    param([string]$Text)

    if (Test-NoiseMessage $Text) { return $false }
    if (Test-ReportTask $Text) { return $false }
    if (Test-ProceduralAssistantMessage $Text) { return $false }

    $normalized = Normalize-TaskText $Text
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    return $true
}

function Test-ProceduralAssistantMessage {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $true
    }

    $normalized = Normalize-TaskText $Text
    $toolOrProcessKeywords = @(
        '我先', '接下来', '正在', '我已经定位', '我已经看到',
        '使用 skill', '使用feqi', 'rg ', 'Get-Content', 'shell_command',
        'apply_patch', 'mvn ', 'git ', '命令', '终端', '脚本', '桌面',
        '日志原材料', '会话采集', '日报', '<subagent_notification>',
        'agent_message', 'memory_citation', 'phase'
    )

    foreach ($keyword in $toolOrProcessKeywords) {
        if ($normalized.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Truncate-Sentence {
    param(
        [string]$Text,
        [int]$Limit
    )

    $effectiveLimit = [Math]::Max($Limit, 10)
    $compact = Clean-Text -Text $Text -Limit $effectiveLimit
    if ($compact.Length -le $Limit) {
        return $compact
    }
    return $compact.Substring(0, [Math]::Max($Limit - 1, 0)).TrimEnd('；', '，', '。', ' ') + '...'
}

function Compact-TaskTheme {
    param([string]$Text)

    $normalized = Normalize-TaskText $Text
    $normalized = [regex]::Replace($normalized, '[，,；;]+', '、')
    $normalized = [regex]::Replace($normalized, '^(检查|排查|补充|实现|编写|写一个脚本|自动读取|查看|确认)', '')
    $normalized = $normalized.Trim(' ', '、')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $normalized = '相关功能处理'
    }
    return Truncate-Sentence -Text $normalized -Limit 28
}

function Compact-BusinessPoint {
    param([string]$Text)

    $normalized = Normalize-TaskText $Text
    $normalized = [regex]::Replace($normalized, '\[([^\]]+)\]', '$1')
    $normalized = [regex]::Replace($normalized, '^\s*\d+[\.、]\s*', '')
    $normalized = [regex]::Replace($normalized, '\s+\d+[\.、].*$', '')
    $normalized = [regex]::Replace($normalized, '[，,；;]+', '、')
    $normalized = [regex]::Replace($normalized, '^(请|麻烦|帮我|帮忙|看一下|检查一下)\s*', '')
    $normalized = [regex]::Replace($normalized, '^(把|将|需要|要求|希望|请先|先)\s*', '')
    $normalized = [regex]::Replace($normalized, '^(需求进行变更|需求变更)\s*', '')
    $normalized = [regex]::Replace($normalized, '\s*[:：]\s*', ' ')
    $normalized = [regex]::Replace($normalized, '\s+', ' ').Trim()

    if ($normalized.Length -gt 26) {
        $normalized = ($normalized -split '[。；;]')[0].Trim()
    }
    $normalized = $normalized.Trim(' ', '、')

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $normalized = '处理项目业务事项'
    }
    elseif ($normalized -notmatch '^(排查|检查|确认|修复|修改|调整|新增|实现|补充|梳理|核对|优化|处理)') {
        if ($normalized -match '(异常|报错|失败|问题|未)') {
            $normalized = "排查$normalized"
        }
        else {
            $normalized = "处理$normalized"
        }
    }

    return Truncate-Sentence -Text $normalized -Limit 32
}

function Load-MemoryText {
    param([string]$RepoRoot)

    $memoryPath = Join-Path $RepoRoot 'docs\MEMORY.md'
    if (-not (Test-Path -LiteralPath $memoryPath)) {
        return ''
    }
    return Get-Content -LiteralPath $memoryPath -Raw -Encoding UTF8
}

function Test-MemoryHasSegments {
    param(
        [string]$MemoryText,
        [string[]]$Segments
    )

    foreach ($segment in $Segments) {
        if (-not $MemoryText.Contains($segment)) {
            return $false
        }
    }
    return $true
}

function Infer-ModuleLabel {
    param(
        [string]$TaskText,
        [string]$MemoryText
    )
    return '功能优化与处理'
}

function New-CountMap {
    return @{}
}

function Add-Count {
    param(
        [hashtable]$Map,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }
    if ($Map.ContainsKey($Name)) {
        $Map[$Name] += 1
    }
    else {
        $Map[$Name] = 1
    }
}

function Get-TopCounts {
    param(
        [hashtable]$Map,
        [int]$Limit
    )

    return $Map.GetEnumerator() |
        Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
        Select-Object -First $Limit
}

function Extract-MessageText {
    param($Content)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Content)) {
        if ($null -ne $item.text -and -not [string]::IsNullOrWhiteSpace([string]$item.text)) {
            [void]$parts.Add(([string]$item.text).Trim())
        }
    }
    return Clean-Text ($parts -join ' ')
}

function Summarize-Command {
    param($Payload)

    if ($null -ne $Payload.parsed_cmd) {
        $parsed = @($Payload.parsed_cmd)
        if ($parsed.Count -gt 0 -and $null -ne $parsed[0].cmd) {
            return Clean-Text -Text ([string]$parsed[0].cmd) -Limit 160
        }
    }

    $command = $Payload.command
    if ($command -is [System.Array]) {
        $command = ($command | ForEach-Object { [string]$_ }) -join ' '
    }
    if ($command) {
        return Clean-Text -Text ([string]$command) -Limit 160
    }
    return ''
}

function New-SessionDigest {
    param(
        [string]$SessionFile,
        [string]$Cwd
    )

    return [pscustomobject]@{
        SessionFile        = $SessionFile
        Cwd                = $Cwd
        UserMessages       = New-Object System.Collections.Generic.List[string]
        AssistantMessages  = New-Object System.Collections.Generic.List[string]
        Tools              = New-CountMap
        Commands           = New-CountMap
        Failures           = New-Object System.Collections.Generic.List[string]
    }
}

function Load-JsonObjects {
    param([string]$SessionFile)

    $objects = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $SessionFile)) {
        return $objects
    }

    foreach ($line in Get-Content -LiteralPath $SessionFile -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            [void]$objects.Add(($line | ConvertFrom-Json))
        }
        catch {
            continue
        }
    }
    return $objects
}

function Extract-SessionCwd {
    param($Objects)

    $cwdValues = New-Object System.Collections.Generic.List[string]
    foreach ($obj in @($Objects)) {
        if ($obj.type -ne 'session_meta') {
            continue
        }
        $cwd = [string]$obj.payload.cwd
        if ([string]::IsNullOrWhiteSpace($cwd)) {
            continue
        }
        $normalized = Normalize-PathValue $cwd
        if ($normalized -and -not $cwdValues.Contains($normalized)) {
            [void]$cwdValues.Add($normalized)
        }
    }

    if ($cwdValues.Count -ne 1) {
        return $null
    }
    return $cwdValues[0]
}

function Collect-SessionDigest {
    param(
        [string]$SessionFile,
        [string]$RepoRoot
    )

    $objects = Load-JsonObjects -SessionFile $SessionFile
    if ($objects.Count -eq 0) {
        return $null
    }

    $sessionCwd = Extract-SessionCwd -Objects $objects
    if ([string]::IsNullOrWhiteSpace($sessionCwd) -or -not (Test-SameOrChildPath -Candidate $sessionCwd -Root $RepoRoot)) {
        return $null
    }

    $digest = New-SessionDigest -SessionFile $SessionFile -Cwd $sessionCwd
    $eventCount = 0

    foreach ($obj in @($objects)) {
        if ($eventCount -ge $maxSessionEvents) {
            break
        }

        $payload = $obj.payload
        if ($obj.type -eq 'response_item') {
            if ($payload.type -eq 'message') {
                $role = [string]$payload.role
                if ($role -notin @('user', 'assistant')) {
                    continue
                }

                $text = Extract-MessageText -Content $payload.content
                if ($role -eq 'user') {
                    $text = Strip-SkillLinkPrefix $text
                }
                if (Test-NoiseMessage $text) {
                    continue
                }

                if ($role -eq 'user' -and $digest.UserMessages.Count -lt $maxSessionTextItems) {
                    [void]$digest.UserMessages.Add($text)
                    $eventCount += 1
                }
                elseif ($role -eq 'assistant' -and $digest.AssistantMessages.Count -lt $maxSessionTextItems) {
                    if (-not (Test-ProceduralAssistantMessage $text)) {
                        [void]$digest.AssistantMessages.Add($text)
                        $eventCount += 1
                    }
                }
            }
        }
    }

    return $digest
}

# 【核心逻辑】扫描会话文件：同时从实时 sessions 和归档 archived_sessions 中抓取当天的记录
function Discover-MatchingSessions {
    param([string]$ReportDateValue, [string]$RepoRoot, [string]$CodexHomeValue)

    $parsedDate = [datetime]::ParseExact($ReportDateValue, 'yyyy-MM-dd', $null)
    $sessionRoot = Join-Path $CodexHomeValue 'sessions'
    $digests = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $sessionRoot)) { return $digests }

    $foldersToScan = @()
    for ($i = 0; $i -le 7; $i++) {
        $dateToCheck = $parsedDate.AddDays(-$i)
        $dir = Join-Path (Join-Path (Join-Path $sessionRoot $dateToCheck.ToString('yyyy')) $dateToCheck.ToString('MM')) $dateToCheck.ToString('dd')
        if (Test-Path -LiteralPath $dir) { $foldersToScan += $dir }
    }

    $allFiles = @()
    foreach ($folder in $foldersToScan) {
        $allFiles += @(Get-ChildItem -LiteralPath $folder -Filter '*.jsonl')
    }

    for ($i=0; $i -lt $allFiles.Count; $i++) {
        $file = $allFiles[$i]
        if ($file.LastWriteTime.ToString('yyyy-MM-dd') -ne $ReportDateValue) { continue }

        Write-Spinner "正在解析会话文件 ($($i+1)/$($allFiles.Count)): $($file.Name)"
        $digest = Collect-SessionDigest -SessionFile $file.FullName -RepoRoot $RepoRoot
        if ($null -ne $digest) {
            $alias = "未命名会话"
            $creationTime = $file.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
            
            $fileContent = Get-Content $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
            $foundAlias = $false
            foreach ($line in $fileContent) {
                if ($line -match '"alias"\s*:\s*"([^"]+)"' -or $line -match '"title"\s*:\s*"([^"]+)"') {
                    $alias = $Matches[1]
                    $foundAlias = $true
                    break
                }
            }
            if (-not $foundAlias -and $digest.UserMessages.Count -gt 0) {
                $firstMsg = $digest.UserMessages[0]
                $alias = if ($firstMsg.Length -gt 25) { $firstMsg.Substring(0, 25) + "..." } else { $firstMsg }
            }

            $digest | Add-Member -MemberType NoteProperty -Name "Alias" -Value $alias
            $digest | Add-Member -MemberType NoteProperty -Name "CreationTime" -Value $creationTime
            $digest | Add-Member -MemberType NoteProperty -Name "Selected" -Value $true
            
            [void]$digests.Add($digest)
        }
    }
    Clear-Spinner
    
    if ($digests.Count -gt 0) {
        $sorted = $digests | Sort-Object CreationTime -Descending
        $digests.Clear()
        foreach ($s in $sorted) { [void]$digests.Add($s) }
    }
    return $digests
}

function Get-UniqueCompact {
    param(
        [string[]]$Items,
        [int]$Limit
    )

    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    $result = New-Object System.Collections.Generic.List[string]

    foreach ($item in @($Items)) {
        $value = Clean-Text $item
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        if ($seen.Add($value)) {
            [void]$result.Add($value)
        }
        if ($result.Count -ge $Limit) {
            break
        }
    }

    return $result
}

function Localize-ToolName {
    param([string]$Name)

    if ($toolLabels.ContainsKey($Name)) {
        return $toolLabels[$Name]
    }
    return $Name
}

function Localize-CommandName {
    param([string]$Name)

    if ($commandLabels.ContainsKey($Name)) {
        return $commandLabels[$Name]
    }
    return $Name
}

function Aggregate-DigestText {
    param(
        [string]$ReportDateValue,
        [string]$RepoRoot,
        $Sessions
    )

    $tasks = New-Object System.Collections.Generic.List[string]
    $assistantNotes = New-Object System.Collections.Generic.List[string]

    foreach ($session in @($Sessions)) {
        foreach ($task in @($session.UserMessages | Select-Object -First 3)) {
            if (Test-ProjectBusinessMessage $task) {
                [void]$tasks.Add($task)
            }
        }
        foreach ($note in @($session.AssistantMessages | Select-Object -First 2)) {
            if (Test-ProjectBusinessMessage $note) {
                [void]$assistantNotes.Add($note)
            }
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("日期: $ReportDateValue")
    [void]$lines.Add("仓库: $RepoRoot")
    [void]$lines.Add("会话数: $($Sessions.Count)")
    [void]$lines.Add('业务需求/变更:')
    foreach ($task in Get-UniqueCompact -Items $tasks -Limit 8) {
        [void]$lines.Add("- $task")
    }

    [void]$lines.Add('完成反馈:')
    foreach ($note in Get-UniqueCompact -Items $assistantNotes -Limit 6) {
        [void]$lines.Add("- $note")
    }

    $digestText = ($lines -join [Environment]::NewLine)
    if ($digestText.Length -gt $maxDigestChars) {
        return $digestText.Substring(0, $maxDigestChars)
    }
    return $digestText
}

function Build-FocusPoints {
    param(
        $Sessions,
        [string]$MemoryText
    )

    $focusPoints = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)

    foreach ($session in @($Sessions)) {
        foreach ($task in @($session.UserMessages)) {
            if (-not (Test-ProjectBusinessMessage $task)) {
                continue
            }
            $moduleLabel = Infer-ModuleLabel -TaskText $task -MemoryText $MemoryText
            $theme = Compact-BusinessPoint $task
            $key = "$moduleLabel|$theme"
            if ($seen.Add($key)) {
                [void]$focusPoints.Add([pscustomobject]@{ Module = $moduleLabel; Theme = $theme })
            }
            if ($focusPoints.Count -ge 3) {
                return $focusPoints
            }
        }
    }

    return $focusPoints
}

function Build-FallbackBody {
    param(
        [string]$ReportDateValue,
        [string]$RepoRoot,
        $Sessions,
        [int]$TargetCharsValue
    )

    if ($Sessions.Count -eq 0) {
        return @"
# $ReportDateValue 日报

1. 今日未发现该仓库的业务会话，暂无可归档内容。
2. 请先在项目内完成当日需求或变更，再重新生成日报。
"@.Trim()
    }

    $memoryText = Load-MemoryText -RepoRoot $RepoRoot

    $focusPoints = Build-FocusPoints -Sessions $Sessions -MemoryText $memoryText
    $points = New-Object System.Collections.Generic.List[string]
    foreach ($point in @($focusPoints | Select-Object -First 4)) {
        if ([string]::IsNullOrWhiteSpace($point.Theme)) {
            continue
        }
        [void]$points.Add((Truncate-Sentence -Text $point.Theme -Limit 40))
    }

    if ($points.Count -eq 0) {
        return @"
# $ReportDateValue 日报

1. 今日未发现项目业务相关会话，暂无可归档内容。
"@.Trim()
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# $ReportDateValue 日报")
    [void]$lines.Add('')
    $index = 1
    foreach ($point in $points) {
        [void]$lines.Add("$index. $point")
        $index++
    }

    return ($lines -join [Environment]::NewLine).Trim()
}

function Extract-OutputText {
    param($ResponseData)

    if ($null -ne $ResponseData.output_text -and -not [string]::IsNullOrWhiteSpace([string]$ResponseData.output_text)) {
        return ([string]$ResponseData.output_text).Trim()
    }

    $fragments = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($ResponseData.output)) {
        foreach ($content in @($item.content)) {
            if ($null -ne $content.text -and -not [string]::IsNullOrWhiteSpace([string]$content.text)) {
                [void]$fragments.Add(([string]$content.text).Trim())
            }
        }
    }

    return ($fragments -join [Environment]::NewLine).Trim()
}

function Ensure-ReportHeader {
    param(
        [string]$Markdown,
        [string]$ReportDateValue
    )

    if ($null -eq $Markdown) {
        $normalized = ''
    }
    else {
        $normalized = [string]$Markdown
    }

    $normalized = $normalized.Trim()
    if (-not $normalized.StartsWith('# ')) {
        $normalized = "# $ReportDateValue 日报`r`n`r`n$normalized"
    }
    return $normalized
}

function Get-ReportBodyText {
    param(
        [string]$Markdown,
        [string]$ReportDateValue
    )

    $normalized = Ensure-ReportHeader -Markdown $Markdown -ReportDateValue $ReportDateValue
    $pattern = '^#\s+' + [regex]::Escape($ReportDateValue) + '\s+日报\s*'
    return ([regex]::Replace($normalized, $pattern, '', [System.Text.RegularExpressions.RegexOptions]::Singleline)).Trim()
}

function Get-ReportBodyLength {
    param(
        [string]$Markdown,
        [string]$ReportDateValue
    )

    return (Get-ReportBodyText -Markdown $Markdown -ReportDateValue $ReportDateValue).Length
}

function Compress-ReportMarkdownLocally {
    param(
        [string]$Markdown,
        [string]$ReportDateValue,
        [int]$MaxChars
    )

    $normalized = Ensure-ReportHeader -Markdown $Markdown -ReportDateValue $ReportDateValue
    $bodyText = Get-ReportBodyText -Markdown $normalized -ReportDateValue $ReportDateValue
    if ($bodyText.Length -le $MaxChars) {
        return $normalized
    }

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($normalized -split "\r?\n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\d+\.\s*(.+)$') {
            [void]$items.Add($Matches[1])
        }
    }

    if ($items.Count -eq 0) {
        $items.Add($bodyText) | Out-Null
    }

    $perLineLimit = [Math]::Max(30, [int](($MaxChars - 40) / [Math]::Max($items.Count, 1)))
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# $ReportDateValue 日报")
    [void]$lines.Add('')
    $index = 1
    foreach ($item in @($items | Select-Object -First 4)) {
        [void]$lines.Add("$index. $(Truncate-Sentence -Text $item -Limit $perLineLimit)")
        $index++
    }

    return ($lines -join [Environment]::NewLine).Trim()
}

function Invoke-ResponsesRequest {
    param(
        [string]$SystemText,
        [string]$UserText
    )

    $payloadObject = @{
        model = $Model
        input = @(
            @{
                role = 'system'
                content = @(
                    @{
                        type = 'input_text'
                        text = $SystemText
                    }
                )
            },
            @{
                role = 'user'
                content = @(
                    @{
                        type = 'input_text'
                        text = $UserText
                    }
                )
            }
        )
    }

    $requestBody = $payloadObject | ConvertTo-Json -Depth 10 -Compress
    $uri = $BaseUrl.TrimEnd('/') + '/responses'
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Method = 'POST'
    $request.ContentType = 'application/json; charset=utf-8'
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 60000
    $request.Headers['Authorization'] = "Bearer $ApiKey"

    $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($requestBody)
    $requestStream = $null
    $response = $null
    $reader = $null

    try {
        $requestStream = $request.GetRequestStream()
        $requestStream.Write($requestBytes, 0, $requestBytes.Length)
        $requestStream.Flush()
        
        $asyncResult = $request.BeginGetResponse($null, $null)
        while (-not $asyncResult.IsCompleted) {
            Write-Spinner "正在调用大模型生成报告，请耐心等待..."
            Start-Sleep -Milliseconds 150
        }
        Clear-Spinner
        
        $response = $request.EndGetResponse($asyncResult)
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $responseText = $reader.ReadToEnd()
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        if ($requestStream) { $requestStream.Dispose() }
    }

    $responseData = $responseText | ConvertFrom-Json
    $outputText = Extract-OutputText -ResponseData $responseData
    if ([string]::IsNullOrWhiteSpace($outputText)) {
        throw 'Responses API returned no output text.'
    }
    return $outputText
}

# 【远程调用】构建 prompt 并请求远程 AI 模型生成最终日报内容
function Call-ResponsesApi {
    param(
        [string]$DigestText,
        [int]$TargetCharsValue,
        [string]$ReportDateValue
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'DAILY_API_KEY is empty.'
    }

    $instructions = @"
你是开发日报整理助手。请只依据提供的摘要素材，用自然中文输出简洁 Markdown 日报。
正文长度控制在 200-500 字之间，优先接近 $TargetCharsValue 字。
输出格式固定为：
# $ReportDateValue 日报

1.<session alias>: ...
2.<session alias>: ...
3.<session alias>: ...
..
n.<session alias>: ...
要求：
- 【严格限定】：要求只包括“业务性质”的工作内容，必须直接与产品业务、页面需求或核心业务逻辑挂钩。
- 【绝对忽略】：忽略所有的工具开发、自动化脚本开发、聊天、题外话、闲话以及本地环境配置等无关内容。
- 按每个对话的需求或变更主题列出要点，一条对应一个业务主题。
- 每条尽量短，优先写成“动词 + 业务主题 + 完成度”的句子。
- 不要编造未出现的信息，不要输出代码块，不要输出系统路径和具体类名，概括成中文业务语言。
"@.Trim()

    $reportMarkdown = Ensure-ReportHeader -Markdown (Invoke-ResponsesRequest -SystemText $instructions -UserText $DigestText) -ReportDateValue $ReportDateValue
    $bodyLength = Get-ReportBodyLength -Markdown $reportMarkdown -ReportDateValue $ReportDateValue

    if ($bodyLength -lt 200 -or $bodyLength -gt 500) {
        $rewriteInstructions = @"
请把这份日报压缩或扩写到 200-500 字之间，保留标题和编号列表形式。
请再次检查并删除任何工具开发、聊天或闲话，仅保留业务性质的工作。
不要新增事实，不要输出代码块，不要改变日期。
"@.Trim()

        try {
            $reportMarkdown = Ensure-ReportHeader -Markdown (Invoke-ResponsesRequest -SystemText $rewriteInstructions -UserText $reportMarkdown) -ReportDateValue $ReportDateValue
        }
        catch {
            $reportMarkdown = Compress-ReportMarkdownLocally -Markdown $reportMarkdown -ReportDateValue $ReportDateValue -MaxChars 500
        }
    }

    if ((Get-ReportBodyLength -Markdown $reportMarkdown -ReportDateValue $ReportDateValue) -gt 500) {
        $reportMarkdown = Compress-ReportMarkdownLocally -Markdown $reportMarkdown -ReportDateValue $ReportDateValue -MaxChars 500
    }

    return $reportMarkdown
}

function Build-ReportMarkdown {
    param(
        [string]$ReportDateValue,
        [string]$RepoRoot,
        $Sessions,
        [int]$TargetCharsValue
    )

    $digestText = Aggregate-DigestText -ReportDateValue $ReportDateValue -RepoRoot $RepoRoot -Sessions $Sessions
    $body = ''
    $hasBusinessMaterial = $digestText -match '(?m)^-\s+\S+'

    if ($Sessions.Count -eq 0) {
        Clear-Spinner
        Write-Host '未找到会话记录，将使用空白模板。' -ForegroundColor Yellow
    }
    elseif (-not $hasBusinessMaterial) {
        Clear-Spinner
        Write-Host '未找到有效的业务相关会话，将使用本地生成。' -ForegroundColor Yellow
    }
    elseif (-not $UseApi) {
        Clear-Spinner
        Write-Host '远程AI已禁用，将使用本地生成。' -ForegroundColor DarkGray
    }
    elseif ([string]::IsNullOrWhiteSpace($ApiKey)) {
        Clear-Spinner
        Write-Host 'API KEY 为空，跳过远程请求，将使用本地生成。' -ForegroundColor Red
    }

    if ($Sessions.Count -gt 0 -and $hasBusinessMaterial -and $UseApi -and -not [string]::IsNullOrWhiteSpace($ApiKey)) {
        try {
            $body = Call-ResponsesApi -DigestText $digestText -TargetCharsValue $TargetCharsValue -ReportDateValue $ReportDateValue
        }
        catch {
            Clear-Spinner
            Write-Host 'API 调用失败，退化为本地简易生成！' -ForegroundColor Red
            $body = ''
        }
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        return Build-FallbackBody -ReportDateValue $ReportDateValue -RepoRoot $RepoRoot -Sessions $Sessions -TargetCharsValue $TargetCharsValue
    }

    return (Ensure-ReportHeader -Markdown $body -ReportDateValue $ReportDateValue)
}

# ==========================================
# 程序执行主入口
# ==========================================
$currentProfile = Manage-ApiNodes
$script:ApiKey = $currentProfile.ApiKey
$script:BaseUrl = $currentProfile.BaseUrl
$script:Model = $currentProfile.Model

if ([string]::IsNullOrWhiteSpace($script:Model)) {
    Write-Spinner "正在从服务器获取可用模型列表..."
    $models = Get-RemoteModels -Url $script:BaseUrl -Key $script:ApiKey
    Clear-Spinner
    
    if ($null -ne $models -and $models.Count -gt 0) {
        $modelItems = New-Object System.Collections.Generic.List[object]
        foreach ($m in $models) { $modelItems.Add([pscustomobject]@{ Display = $m; Value = $m }) }
        $mChoice = Show-InteractiveMenu -Title "从服务器获取到以下模型，请勾选选择" -Items $modelItems -DisplayProperty "Display"
        if ($null -ne $mChoice) {
            $script:Model = $mChoice.Value
        } else {
            $script:Model = $models[0]
        }
    } else {
        $script:Model = Read-Host "未获取到模型列表，请手动输入模型名称 (例如 gpt-4o)"
    }
    
    foreach ($p in $script:Profiles) {
        if ($p.Name -eq $currentProfile.Name) {
            $p.Model = $script:Model
            break
        }
    }
    Save-LocalConfig
}

$repoRoot = Normalize-PathValue $WorkDir
$codexHomeRoot = Normalize-PathValue $CodexHome
$outputDirRoot = Normalize-PathValue $OutputDir
$outputDirRoot = Normalize-PathValue $OutputDir

if (-not (Test-Path -LiteralPath $repoRoot)) {
    Write-Host "工作目录不存在: $repoRoot" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $codexHomeRoot)) {
    Write-Host "Codex 目录不存在: $codexHomeRoot" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($outputDirRoot)) {
    Write-Host '输出目录为空' -ForegroundColor Red
    exit 1
}

Write-Host "正在加载目录 $repoRoot 下的会话数据..." -ForegroundColor Cyan

function Get-VisualWidth {
    param([string]$str)
    if ([string]::IsNullOrEmpty($str)) { return 0 }
    $len = 0
    for ($i=0; $i -lt $str.Length; $i++) {
        if ([int]$str[$i] -gt 255) { $len += 2 } else { $len += 1 }
    }
    return $len
}

function Truncate-Visual {
    param([string]$str, [int]$maxWidth)
    if ([string]::IsNullOrEmpty($str)) { return "" }
    $len = 0
    $res = ""
    for ($i=0; $i -lt $str.Length; $i++) {
        $c = $str[$i]
        $cw = if ([int]$c -gt 255) { 2 } else { 1 }
        if ($len + $cw -gt $maxWidth) { break }
        $len += $cw
        $res += $c
    }
    return $res
}

# 【交互界面】TUI 会话筛选菜单：支持上下键切换、回车勾选，自动处理中文字符宽度防止错位
function Show-InteractiveSessionMenu {
    param($Sessions)
    
    if ($Sessions.Count -eq 0) { return @() }
    
    $cursorIdx = 0
    $confirmIdx = $Sessions.Count
    $running = $true
    
    $w = 100
    try { $w = [System.Console]::WindowWidth } catch {}
    if ($w -lt 60) { $w = 80 }
    
    try { [System.Console]::CursorVisible = $false } catch {}
    
    for ($i=0; $i -lt ($Sessions.Count + 4); $i++) { Write-Host "" }
    
    while ($running) {
        try { [System.Console]::SetCursorPosition(0, [System.Console]::CursorTop - ($Sessions.Count + 4)) } catch { break }
        
        $header = "========== 请勾选需要总结的会话 =========="
        $hp = $w - 2 - (Get-VisualWidth $header)
        if ($hp -lt 0) { $hp = 0 }
        Write-Host ($header + (" " * $hp)) -ForegroundColor Cyan
        
        for ($i=0; $i -lt $Sessions.Count; $i++) {
            $sess = $Sessions[$i]
            $prefix = if ($i -eq $cursorIdx) { " > " } else { "   " }
            Write-Host -NoNewline $prefix
            
            if ($sess.Selected) {
                Write-Host -NoNewline "[√] " -ForegroundColor Green
            } else {
                Write-Host -NoNewline "[ ] " -ForegroundColor DarkGray
            }
            
            $color = if ($i -eq $cursorIdx) { "Yellow" } else { "White" }
            $text = "$($sess.Alias) ($($sess.CreationTime)) : $($sess.Preview)"
            
            $maxTextWidth = $w - 10
            $textToPrint = Truncate-Visual $text $maxTextWidth
            $vw = Get-VisualWidth $textToPrint
            $padding = $maxTextWidth - $vw
            if ($padding -lt 0) { $padding = 0 }
            
            Write-Host ($textToPrint + (" " * $padding)) -ForegroundColor $color
        }
        
        $confirmPrefix = if ($cursorIdx -eq $confirmIdx) { " > " } else { "   " }
        $confirmColor = if ($cursorIdx -eq $confirmIdx) { "Green" } else { "White" }
        $cfText = "[确认选中的会话并开始生成]"
        $cfp = $w - 8 - (Get-VisualWidth $cfText)
        if ($cfp -lt 0) { $cfp = 0 }
        Write-Host ($confirmPrefix + $cfText + (" " * $cfp)) -ForegroundColor $confirmColor
        
        $hint = "操作提示: ↑↓ 切换选项 | Enter 勾选/确认 | 控制台若闪烁属正常现象"
        $hintText = Truncate-Visual $hint ($w - 2)
        $hintPad = $w - 2 - (Get-VisualWidth $hintText)
        if ($hintPad -lt 0) { $hintPad = 0 }
        Write-Host ($hintText + (" " * $hintPad)) -ForegroundColor DarkGray
        
        $sep = "-" * ($w - 2)
        Write-Host $sep -ForegroundColor Cyan
        
        try {
            $key = [System.Console]::ReadKey($true).Key
        } catch {
            break
        }
        
        if ($key -eq 'UpArrow') {
            $cursorIdx--
            if ($cursorIdx -lt 0) { $cursorIdx = $confirmIdx }
        } elseif ($key -eq 'DownArrow') {
            $cursorIdx++
            if ($cursorIdx -gt $confirmIdx) { $cursorIdx = 0 }
        } elseif ($key -eq 'Enter') {
            if ($cursorIdx -eq $confirmIdx) {
                $running = $false
            } else {
                $Sessions[$cursorIdx].Selected = -not $Sessions[$cursorIdx].Selected
            }
        }
    }
    
    try { [System.Console]::CursorVisible = $true } catch {}
    
    $selected = @($Sessions | Where-Object { $_.Selected })
    return $selected
}

$sessionsList = Discover-MatchingSessions -ReportDateValue $ReportDate -RepoRoot $repoRoot -CodexHomeValue $codexHomeRoot
if ($sessionsList -is [System.Collections.IList] -and $sessionsList.GetType().GetMethod('ToArray')) {
    $sessions = $sessionsList.ToArray()
}
else {
    $sessions = @($sessionsList)
}
Write-Host "`n"
$sessions = Show-InteractiveSessionMenu -Sessions $sessions
if ($sessions.Count -eq 0) {
    Write-Host "未选择任何会话，将使用空白模板。" -ForegroundColor Yellow
}


Write-Spinner "正在聚合和处理摘要..."
$markdown = Build-ReportMarkdown -ReportDateValue $ReportDate -RepoRoot $repoRoot -Sessions $sessions -TargetCharsValue $TargetChars

[System.IO.Directory]::CreateDirectory($outputDirRoot) | Out-Null
$outputPath = Join-Path $outputDirRoot ($ReportDate + '.md')
[System.IO.File]::WriteAllText($outputPath, $markdown, [System.Text.UTF8Encoding]::new($false))

Clear-Spinner
Write-Host "报告生成成功！路径: $outputPath" -ForegroundColor Green
Write-Host "提取到的相关会话数: $($sessions.Count)" -ForegroundColor Green
try { Start-Process $outputPath } catch { }
exit 0
