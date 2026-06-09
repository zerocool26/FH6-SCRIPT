<#
FH6 Companion Doctor v5.2

External Forza Horizon 6 companion, diagnostics, save/cache manager, crash lab,
telemetry listener, device doctor, launcher, and support-package builder.

Safety model:
  - Never modifies the Steam game install or forzahorizon6.exe.
  - Never injects into the game, reads game memory, automates gameplay, or edits saves.
  - Cleanup operations are limited to FH6 user/save/cache/crash-report roots.
  - Backup is enabled by default for destructive actions.
  - Telemetry uses FH6's official one-way "Data Out" UDP feature.

Run:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "$env:USERPROFILE\Downloads\FH6TOOLBELT\Tools\FH6-CompanionDoctor.ps1"
#>

[CmdletBinding()]
param(
    [switch]$NoGui,
    [switch]$Snapshot,
    [switch]$Diff,
    [switch]$SelfTest,
    [switch]$Manifest,
    [switch]$PortableBundle,
    [switch]$Universal
)

$ErrorActionPreference = 'Stop'

$script:ToolVersion = '5.2'
$script:UserDownloads = Join-Path $env:USERPROFILE 'Downloads'
$script:ToolRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $script:UserDownloads }
$script:ToolRootName = Split-Path -Path $script:ToolRoot -Leaf
$script:ToolParent = Split-Path -Path $script:ToolRoot -Parent
if ($script:ToolRootName -eq 'Tools' -and (Split-Path -Path $script:ToolParent -Leaf) -eq 'FH6TOOLBELT') {
    $script:ProjectRoot = $script:ToolParent
    $script:IsToolbeltMode = $true
} elseif ($script:ToolRootName -eq 'FH6TOOLBELT') {
    $script:ProjectRoot = $script:ToolRoot
    $script:IsToolbeltMode = $true
} else {
    $script:ProjectRoot = $script:ToolParent
    $script:IsToolbeltMode = $false
}
$script:DataRoot = if ($script:IsToolbeltMode) { Join-Path $script:ProjectRoot 'CompanionDoctorData' } else { $script:UserDownloads }

$script:Config = [ordered]@{
    AppId        = '2483190'
    GameName     = 'Forza Horizon 6'
    ExeName      = 'forzahorizon6.exe'
    LocalRoot    = Join-Path $env:LOCALAPPDATA 'ForzaHorizon6'
    SharedRoot   = Join-Path (Join-Path $env:LOCALAPPDATA 'ForzaHorizon6') 'LocalStorage_Shared'
    XboxPgsRoot  = Join-Path $env:SystemDrive 'XboxGames\GameSave\pgs'
    Downloads    = $script:ToolRoot
    UserDownloads = $script:UserDownloads
    ProjectRoot  = $script:ProjectRoot
    DataRoot     = $script:DataRoot
    ToolbeltMode = $script:IsToolbeltMode
    BackupRoot   = Join-Path $script:DataRoot 'FH6_CompanionDoctor_Backups'
    ReportRoot   = Join-Path $script:DataRoot 'FH6_CompanionDoctor_Reports'
    PackageRoot  = Join-Path $script:DataRoot 'FH6_CompanionDoctor_SupportPackages'
    LogRoot      = Join-Path $script:DataRoot 'FH6_CompanionDoctor_Logs'
    TelemetryRoot = Join-Path $script:DataRoot 'FH6_CompanionDoctor_Telemetry'
    SnapshotRoot = Join-Path $script:DataRoot 'FH6_CompanionDoctor_Snapshots'
    SessionRoot  = Join-Path $script:DataRoot 'FH6_CompanionDoctor_Sessions'
    BundleRoot   = Join-Path $script:DataRoot 'FH6_CompanionDoctor_PortableBundles'
    UniversalRoot = Join-Path $script:DataRoot 'CrashScope_Universal'
    ManifestPath = Join-Path $script:ToolRoot 'FH6_CompanionDoctor_Manifest.json'
    SettingsPath = Join-Path $script:ToolRoot 'FH6_CompanionDoctor_Settings.json'
}

$script:RunLogPath = $null
$script:Items = @()
$script:ItemsById = @{}
$script:UdpClient = $null
$script:TelemetryCsvPath = $null
$script:TelemetryPacketCount = 0
$script:TelemetryLastPacket = $null
$script:MonitorActive = $false
$script:MonitorRunCount = 0
$script:MonitorLastAction = 'Idle'
$script:SessionActive = $false
$script:SessionId = $null
$script:SessionStart = $null
$script:SessionBeforeSnapshot = $null
$script:SessionSeenProcess = $false
$script:CrashWatchActive = $false
$script:CrashWatchLastTime = $null
$script:CrashWatchDetectedCount = 0
$script:CrashWatchLastAction = 'Idle'
$script:StabilityCache = @{}

function New-ToolDirectory {
    foreach ($path in @($script:Config.BackupRoot, $script:Config.ReportRoot, $script:Config.PackageRoot, $script:Config.LogRoot, $script:Config.TelemetryRoot, $script:Config.SnapshotRoot, $script:Config.SessionRoot, $script:Config.BundleRoot, $script:Config.UniversalRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Get-DefaultSettings {
    [pscustomobject]@{
        TelemetryPort     = 5606
        TelemetryCsv      = $true
        BackupByDefault   = $true
        DryRunByDefault   = $false
        StopGameByDefault = $false
        MonitorMode       = 'Saves only'
        MonitorSeconds    = 30
        CrashWatchSeconds = 15
        CrashWatchAutoPackage = $false
        CorrelationMinutes = 10
        LastTab           = 'Dashboard'
    }
}

function Read-CompanionSettings {
    $defaults = Get-DefaultSettings
    if (-not (Test-Path -LiteralPath $script:Config.SettingsPath)) { return $defaults }
    try {
        $loaded = Get-Content -LiteralPath $script:Config.SettingsPath -Raw | ConvertFrom-Json
        foreach ($prop in $defaults.PSObject.Properties.Name) {
            if ($null -eq $loaded.$prop) { $loaded | Add-Member -NotePropertyName $prop -NotePropertyValue $defaults.$prop }
        }
        return $loaded
    }
    catch {
        return $defaults
    }
}

function Write-CompanionSettings {
    param([Parameter(Mandatory)][object]$Settings)
    New-ToolDirectory
    $Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Config.SettingsPath -Encoding UTF8
}

function Get-FullPathSafe {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) { return (Resolve-Path -LiteralPath $Path).Path }
        return [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $Path
    }
}

function Test-PathUnderRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $full = (Get-FullPathSafe -Path $Path).TrimEnd('\')
    $rootFull = (Get-FullPathSafe -Path $Root).TrimEnd('\')
    return ($full.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase))
}

function ConvertTo-SafeName {
    param([Parameter(Mandatory)][string]$Text)
    $safe = $Text -replace '^[A-Za-z]:\\', ''
    $safe = $safe -replace '[\\/:*?"<>|]', '_'
    $safe = $safe -replace '\s+', '_'
    if ($safe.Length -gt 160) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').Substring(0, 12)
        $safe = $safe.Substring(0, 140) + '_' + $hash
    }
    return $safe
}

function Get-ChildStats {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        return [pscustomobject]@{ Items = 1; SizeBytes = [int64]$item.Length }
    }
    $count = 0
    [int64]$size = 0
    Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $count++
        if (-not $_.PSIsContainer) { $size += [int64]$_.Length }
    }
    return [pscustomobject]@{ Items = $count; SizeBytes = $size }
}

function New-FH6Record {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [bool]$Cleanable = $true,
        [bool]$DefaultSelected = $false,
        [string]$Risk = 'Normal'
    )
    $exists = Test-Path -LiteralPath $Path
    $stats = [pscustomobject]@{ Items = 0; SizeBytes = 0 }
    $modified = $null
    if ($exists) {
        try {
            $item = Get-Item -LiteralPath $Path -Force
            $modified = $item.LastWriteTime
            $stats = Get-ChildStats -Path $Path
        }
        catch {
            $Risk = 'Read warning'
        }
    }
    [pscustomobject]@{
        Id              = [guid]::NewGuid().ToString('N')
        Category        = $Category
        Path            = $Path
        Exists          = $exists
        Items           = $stats.Items
        SizeBytes       = $stats.SizeBytes
        SizeMB          = [math]::Round(($stats.SizeBytes / 1MB), 2)
        LastWriteTime   = $modified
        Description     = $Description
        Cleanable       = $Cleanable
        DefaultSelected = $DefaultSelected
        Risk            = $Risk
    }
}

function Get-SteamLibraries {
    $steamRoots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Steam'),
        (Join-Path $env:ProgramFiles 'Steam')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    $libraries = New-Object System.Collections.Generic.List[string]
    foreach ($root in $steamRoots) {
        if (-not $libraries.Contains($root)) { [void]$libraries.Add($root) }
        $libraryFile = Join-Path (Join-Path $root 'steamapps') 'libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryFile) {
            $raw = Get-Content -LiteralPath $libraryFile -Raw -ErrorAction SilentlyContinue
            if ($raw) {
                [regex]::Matches($raw, '"path"\s+"([^"]+)"') | ForEach-Object {
                    $path = $_.Groups[1].Value -replace '\\\\', '\'
                    if ((Test-Path -LiteralPath $path) -and -not $libraries.Contains($path)) {
                        [void]$libraries.Add($path)
                    }
                }
            }
        }
    }
    return $libraries.ToArray()
}

function Get-SteamInstallInfo {
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($library in Get-SteamLibraries) {
        $manifest = Join-Path (Join-Path $library 'steamapps') "appmanifest_$($script:Config.AppId).acf"
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        $raw = Get-Content -LiteralPath $manifest -Raw -ErrorAction SilentlyContinue
        $installDir = 'ForzaHorizon6'
        $name = $script:Config.GameName
        $stateFlags = ''
        $lastUpdated = ''
        $sizeOnDisk = ''
        if ($raw -match '"installdir"\s+"([^"]+)"') { $installDir = $Matches[1] }
        if ($raw -match '"name"\s+"([^"]+)"') { $name = $Matches[1] }
        if ($raw -match '"StateFlags"\s+"([^"]+)"') { $stateFlags = $Matches[1] }
        if ($raw -match '"LastUpdated"\s+"([^"]+)"') { $lastUpdated = $Matches[1] }
        if ($raw -match '"SizeOnDisk"\s+"([^"]+)"') { $sizeOnDisk = $Matches[1] }
        $gameDir = Join-Path (Join-Path $library 'steamapps\common') $installDir
        $exe = Join-Path $gameDir $script:Config.ExeName
        [void]$found.Add([pscustomobject]@{
            Library       = $library
            LibraryLength = $library.Length
            Manifest      = $manifest
            Name          = $name
            InstallDir    = $gameDir
            Exe           = $exe
            ExeExists     = Test-Path -LiteralPath $exe
            StateFlags    = $stateFlags
            LastUpdated   = $lastUpdated
            SizeOnDisk    = $sizeOnDisk
        })
    }
    return $found.ToArray()
}

function Get-SteamUserDataTargets {
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($library in Get-SteamLibraries) {
        $userdata = Join-Path $library 'userdata'
        if (-not (Test-Path -LiteralPath $userdata)) { continue }
        Get-ChildItem -LiteralPath $userdata -Force -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $appFolder = Join-Path $_.FullName $script:Config.AppId
            if (Test-Path -LiteralPath $appFolder) {
                [void]$records.Add((New-FH6Record -Category 'Save' -Path $appFolder -Description 'Steam userdata/cloud metadata for FH6 app ID 2483190.' -Cleanable $true -DefaultSelected $true -Risk 'Cloud'))
            }
        }
    }
    return $records.ToArray()
}

function Get-SteamLogRows {
    $rows = New-Object System.Collections.Generic.List[object]
    $patterns = @($script:Config.AppId, 'ForzaHorizon6', 'Forza Horizon 6', 'cloud', 'sync')
    foreach ($library in Get-SteamLibraries) {
        $logRoot = Join-Path $library 'logs'
        if (-not (Test-Path -LiteralPath $logRoot)) { continue }
        Get-ChildItem -LiteralPath $logRoot -Force -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match 'cloud|content|appinfo|shader|bootstrap|client'
        } | ForEach-Object {
            $file = $_
            try {
                $matches = Select-String -LiteralPath $file.FullName -Pattern $patterns -SimpleMatch -ErrorAction SilentlyContinue |
                    Select-Object -Last 80
                foreach ($m in $matches) {
                    [void]$rows.Add([pscustomobject]@{
                        File       = $file.Name
                        LineNumber = $m.LineNumber
                        Text       = $m.Line.Trim()
                        Path       = $file.FullName
                    })
                }
            }
            catch {}
        }
    }
    return $rows.ToArray()
}

function Get-SteamLogSummary {
    $rows = @(Get-SteamLogRows)
    if ($rows.Count -eq 0) { return 'No recent FH6/appID/cloud entries found in Steam logs.' }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Steam log matches: $($rows.Count)")
    foreach ($r in $rows | Select-Object -Last 20) {
        [void]$lines.Add("  $($r.File):$($r.LineNumber) $($r.Text)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-FH6Process {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(forzahorizon6|ForzaHorizon6)$' }
}

function Get-GamingServicesVersion {
    try {
        $pkg = Get-AppxPackage Microsoft.GamingServices -ErrorAction Stop
        if ($pkg) { return $pkg.Version.ToString() }
    }
    catch {
        return "Unavailable: $($_.Exception.Message)"
    }
    return 'Not found'
}

function Get-XboxServiceRows {
    $serviceNames = @(
        'GamingServices',
        'GamingServicesNet',
        'XblAuthManager',
        'XblGameSave',
        'XboxGipSvc',
        'XboxNetApiSvc',
        'InstallService',
        'ClipSVC',
        'TokenBroker'
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($name in $serviceNames) {
        try {
            $svc = Get-Service -Name $name -ErrorAction Stop
            [void]$rows.Add([pscustomobject]@{
                Name        = $svc.Name
                DisplayName = $svc.DisplayName
                Status      = $svc.Status.ToString()
                StartType   = $svc.StartType.ToString()
            })
        }
        catch {
            [void]$rows.Add([pscustomobject]@{
                Name        = $name
                DisplayName = ''
                Status      = 'Not found'
                StartType   = ''
            })
        }
    }
    return $rows.ToArray()
}

function Get-VisualCRedistRows {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        Get-ItemProperty -Path $root -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -match 'Microsoft Visual C\+\+.*Redistributable'
        } | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{
                Name        = $_.DisplayName
                Version     = $_.DisplayVersion
                Publisher   = $_.Publisher
                InstallDate = $_.InstallDate
            })
        }
    }
    return @($rows | Sort-Object Name, Version -Unique)
}

function Get-MediaFoundationStatus {
    $system32 = Join-Path $env:WINDIR 'System32'
    $files = @('mfplat.dll', 'mf.dll', 'mfreadwrite.dll') | ForEach-Object {
        $path = Join-Path $system32 $_
        [pscustomobject]@{
            File   = $_
            Path   = $path
            Exists = Test-Path -LiteralPath $path
        }
    }
    $missing = @($files | Where-Object { -not $_.Exists })
    [pscustomobject]@{
        Status  = if ($missing.Count -eq 0) { 'OK' } else { 'Warn' }
        Detail  = if ($missing.Count -eq 0) { 'Media Foundation DLLs present.' } else { 'Missing: ' + (($missing | Select-Object -ExpandProperty File) -join ', ') }
        Files   = $files
    }
}

function Get-WERReportRows {
    $roots = @(
        (Join-Path $env:PROGRAMDATA 'Microsoft\Windows\WER\ReportArchive'),
        (Join-Path $env:PROGRAMDATA 'Microsoft\Windows\WER\ReportQueue')
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Force -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match 'forzahorizon6|ForzaHorizon6|AppCrash_forzahorizon6'
        } | Sort-Object LastWriteTime -Descending | Select-Object -First 40 | ForEach-Object {
            $wer = Join-Path $_.FullName 'Report.wer'
            $eventType = ''
            $bucket = ''
            if (Test-Path -LiteralPath $wer -ErrorAction SilentlyContinue) {
                try {
                    $content = Get-Content -LiteralPath $wer -ErrorAction SilentlyContinue
                    $eventType = (($content | Where-Object { $_ -match '^EventType=' } | Select-Object -First 1) -replace '^EventType=', '')
                    $bucket = (($content | Where-Object { $_ -match '^Bucket=' } | Select-Object -First 1) -replace '^Bucket=', '')
                }
                catch {}
            }
            [void]$rows.Add([pscustomobject]@{
                Root          = $root
                Name          = $_.Name
                LastWriteTime = $_.LastWriteTime
                EventType     = $eventType
                Bucket        = $bucket
                Path          = $_.FullName
            })
        }
    }
    return $rows.ToArray()
}

function ConvertTo-RedactedText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $redacted = $Text
    if ($env:USERPROFILE) {
        $redacted = $redacted.Replace($env:USERPROFILE, '%USERPROFILE%')
    }
    if ($env:USERNAME) {
        $redacted = $redacted -replace [regex]::Escape($env:USERNAME), '%USERNAME%'
    }
    return $redacted
}

function Get-StartupProgramRows {
    $rows = New-Object System.Collections.Generic.List[object]
    $registryRoots = @(
        @{ Scope = 'CurrentUser'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' },
        @{ Scope = 'CurrentUser'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' },
        @{ Scope = 'LocalMachine'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' },
        @{ Scope = 'LocalMachine'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce' },
        @{ Scope = 'LocalMachine32'; Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }
    )
    foreach ($root in $registryRoots) {
        try {
            $props = Get-ItemProperty -LiteralPath $root.Path -ErrorAction Stop
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
                [void]$rows.Add([pscustomobject]@{
                    Source  = 'Registry'
                    Scope   = $root.Scope
                    Name    = $prop.Name
                    Command = [string]$prop.Value
                    Path    = $root.Path
                })
            }
        }
        catch {}
    }

    $startupFolders = @(
        @{ Scope = 'CurrentUser'; Path = [Environment]::GetFolderPath('Startup') },
        @{ Scope = 'AllUsers'; Path = [Environment]::GetFolderPath('CommonStartup') }
    )
    foreach ($folder in $startupFolders) {
        if (-not $folder.Path -or -not (Test-Path -LiteralPath $folder.Path)) { continue }
        Get-ChildItem -LiteralPath $folder.Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{
                Source  = 'Startup folder'
                Scope   = $folder.Scope
                Name    = $_.Name
                Command = $_.FullName
                Path    = $folder.Path
            })
        }
    }

    try {
        Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon|Startup' }
        } | Select-Object -First 120 | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{
                Source  = 'Scheduled task'
                Scope   = $_.TaskPath
                Name    = $_.TaskName
                Command = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join '; '
                Path    = $_.TaskPath
            })
        }
    }
    catch {}

    return $rows.ToArray()
}

function Get-ProcessMitigationRows {
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $mitigation = Get-ProcessMitigation -Name $script:Config.ExeName -ErrorAction Stop
        foreach ($area in $mitigation.PSObject.Properties) {
            if ($null -eq $area.Value -or $area.MemberType -notin @('Property','NoteProperty')) { continue }
            foreach ($prop in $area.Value.PSObject.Properties) {
                [void]$rows.Add([pscustomobject]@{
                    Scope   = 'Image'
                    Area    = $area.Name
                    Setting = $prop.Name
                    Value   = [string]$prop.Value
                })
            }
        }
    }
    catch {
        [void]$rows.Add([pscustomobject]@{
            Scope   = 'Image'
            Area    = 'Unavailable'
            Setting = $script:Config.ExeName
            Value   = $_.Exception.Message
        })
    }

    try {
        $system = Get-ProcessMitigation -System -ErrorAction Stop
        foreach ($area in $system.PSObject.Properties) {
            if ($null -eq $area.Value -or $area.MemberType -notin @('Property','NoteProperty')) { continue }
            foreach ($prop in $area.Value.PSObject.Properties) {
                [void]$rows.Add([pscustomobject]@{
                    Scope   = 'System'
                    Area    = $area.Name
                    Setting = $prop.Name
                    Value   = [string]$prop.Value
                })
            }
        }
    }
    catch {}

    return $rows.ToArray()
}

function Get-ConflictProcesses {
    $patterns = @(
        'Afterburner', 'RTSS', 'Riva', 'Discord', 'obs', 'Logitech', 'lghub',
        'Nahimic', 'Sonic', 'Wallpaper', 'WeMod', 'Windhawk', 'XSplit',
        'EVGAPrecision', 'A-Volute', 'SteelSeries', 'Overwolf', 'GameBar',
        'PresentMon', 'SpecialK', 'ReShade', 'Medal', 'Outplayed',
        'Interceptor', 'Interception', 'MacType', 'Warsaw'
    )
    $regex = ($patterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match $regex -or $_.Path -match $regex
    } | Select-Object ProcessName, Id, Path | Sort-Object ProcessName, Id)
}

function Get-ConflictSummary {
    $hits = @(Get-ConflictProcesses)
    if ($hits.Count -eq 0) { return 'No common overlay/hook/conflict processes found.' }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("$($hits.Count) possible overlay/hook/conflict process(es) found:")
    foreach ($hit in $hits) {
        [void]$lines.Add("  $($hit.ProcessName) pid=$($hit.Id) $($hit.Path)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-AllowedRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    if ($script:Config.LocalRoot) { [void]$roots.Add($script:Config.LocalRoot) }
    if ($script:Config.XboxPgsRoot) { [void]$roots.Add($script:Config.XboxPgsRoot) }
    foreach ($library in Get-SteamLibraries) {
        $userdata = Join-Path $library 'userdata'
        if (Test-Path -LiteralPath $userdata) { [void]$roots.Add($userdata) }
    }
    return $roots.ToArray()
}

function Assert-FH6SafeTarget {
    param([Parameter(Mandatory)][object]$Record)
    if (-not $Record.Cleanable) { throw "Refusing to modify non-cleanable item: $($Record.Path)" }
    if (-not (Test-Path -LiteralPath $Record.Path)) { return }

    $full = Get-FullPathSafe -Path $Record.Path
    if ($full -match '\\steamapps\\common\\ForzaHorizon6(\\|$)' -or $full -match '\\forzahorizon6\.exe$') {
        throw "Refusing to modify game install path: $full"
    }
    if ($full -match '^[A-Za-z]:\\?$') { throw "Refusing to modify drive root: $full" }
    if ($full.Equals((Get-FullPathSafe -Path $env:USERPROFILE), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify user profile root: $full"
    }

    $allowed = $false
    foreach ($root in Get-AllowedRoots) {
        if (Test-PathUnderRoot -Path $full -Root $root) { $allowed = $true; break }
    }
    if (-not $allowed) { throw "Refusing to modify item outside known FH6 user/cache roots: $full" }
}

function Get-FH6Inventory {
    $records = New-Object System.Collections.Generic.List[object]

    if (Test-Path -LiteralPath $script:Config.SharedRoot) {
        Get-ChildItem -LiteralPath $script:Config.SharedRoot -Force -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^User_' -or $_.Name -eq 'ForzaUserConfigSelections' -or $_.Name -match '^InputTranslationManager_'
        } | ForEach-Object {
            [void]$records.Add((New-FH6Record -Category 'Save' -Path $_.FullName -Description 'FH6 AppData account/profile save or user-setting container.' -Cleanable $true -DefaultSelected $true -Risk 'Save'))
        }
    }

    if (Test-Path -LiteralPath $script:Config.XboxPgsRoot) {
        Get-ChildItem -LiteralPath $script:Config.XboxPgsRoot -Force -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^u_.+_16D460$'
        } | ForEach-Object {
            [void]$records.Add((New-FH6Record -Category 'Save' -Path $_.FullName -Description 'Xbox Gaming Services FH6 account save container: profile, liveries, tunes, photos, garage/estate data, and save version.' -Cleanable $true -DefaultSelected $true -Risk 'Save'))
        }
    }

    foreach ($r in Get-SteamUserDataTargets) { [void]$records.Add($r) }

    $cacheTargets = @(
        @{ Path = Join-Path $script:Config.LocalRoot 'CmsCache'; Description = 'FH6 content-management cache.' },
        @{ Path = Join-Path $script:Config.LocalRoot 'LocalStorage_Cache'; Description = 'FH6 local cache and thumbnails.' },
        @{ Path = Join-Path $script:Config.LocalRoot 'fullscreen_choice'; Description = 'FH6 fullscreen/display startup choice.' },
        @{ Path = Join-Path $script:Config.LocalRoot 'LastLaunch.timestamp'; Description = 'FH6 last launch marker.' },
        @{ Path = Join-Path $script:Config.LocalRoot 'NarratorCachedSetting'; Description = 'Cached accessibility startup setting.' }
    )
    foreach ($target in $cacheTargets) {
        if (Test-Path -LiteralPath $target.Path) {
            [void]$records.Add((New-FH6Record -Category 'Cache/Settings' -Path $target.Path -Description $target.Description -Cleanable $true -DefaultSelected $false -Risk 'Low'))
        }
    }

    if (Test-Path -LiteralPath $script:Config.LocalRoot) {
        Get-ChildItem -LiteralPath $script:Config.LocalRoot -Force -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^report_\d{4}_\d{2}_\d{2}_'
        } | ForEach-Object {
            [void]$records.Add((New-FH6Record -Category 'Crash Report' -Path $_.FullName -Description 'Local FH6 pre-crash report folder. Useful for diagnosis, safe to clear after exporting.' -Cleanable $true -DefaultSelected $false -Risk 'Diagnostic'))
        }
    }

    foreach ($install in Get-SteamInstallInfo) {
        [void]$records.Add((New-FH6Record -Category 'Install Info' -Path $install.Exe -Description "Steam install detected. This tool will not modify game files. Library: $($install.Library)" -Cleanable $false -DefaultSelected $false -Risk 'Never delete'))
    }

    return $records.ToArray()
}

function Invoke-Preflight {
    param(
        [bool]$StopGame,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $processes = @(Get-FH6Process)
    if ($processes.Count -eq 0) { return $true }
    if ($StopGame) {
        foreach ($p in $processes) {
            & $Log "Stopping FH6 process: $($p.ProcessName) pid=$($p.Id)"
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
        }
        Start-Sleep -Seconds 1
        return $true
    }
    throw "FH6 is currently running. Close it first or enable 'Stop FH6 if running'."
}

function Backup-FH6Targets {
    param(
        [Parameter(Mandatory)][object[]]$Records,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $existing = @($Records | Where-Object { $_.Exists -and $_.Cleanable -and (Test-Path -LiteralPath $_.Path) })
    if ($existing.Count -eq 0) { return $null }

    New-Item -ItemType Directory -Path $script:Config.BackupRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stage = Join-Path $env:TEMP "FH6_CompanionDoctor_Backup_$stamp"
    $zip = Join-Path $script:Config.BackupRoot "FH6_CompanionDoctor_Backup_$stamp.zip"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    try {
        $manifest = @()
        foreach ($record in $existing) {
            Assert-FH6SafeTarget -Record $record
            $safeName = ConvertTo-SafeName -Text $record.Path
            $dest = Join-Path $stage $safeName
            & $Log "Backing up: $($record.Path)"
            Copy-Item -LiteralPath $record.Path -Destination $dest -Recurse -Force -ErrorAction Stop
            $manifest += [pscustomobject]@{
                Category      = $record.Category
                OriginalPath  = $record.Path
                Description   = $record.Description
                Items         = $record.Items
                SizeMB        = $record.SizeMB
                LastWriteTime = $record.LastWriteTime
            }
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8
        $content = @(Get-ChildItem -LiteralPath $stage -Force | Select-Object -ExpandProperty FullName)
        Compress-Archive -LiteralPath $content -DestinationPath $zip -Force
        & $Log "Backup written: $zip"
        return $zip
    }
    finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Restore-FH6Backup {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [bool]$DryRun = $false,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "Backup zip does not exist: $ZipPath" }
    if (-not (Test-PathUnderRoot -Path $ZipPath -Root $script:Config.BackupRoot)) {
        throw "Refusing to restore a backup outside FH6 Companion Doctor backup root: $ZipPath"
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stage = Join-Path $env:TEMP "FH6_CompanionDoctor_Restore_$stamp"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $stage -Force
        $manifestPath = Join-Path $stage 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Backup manifest.json is missing. Cannot restore safely.' }
        $manifest = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
        foreach ($entry in $manifest) {
            $targetPath = [string]$entry.OriginalPath
            $safeName = ConvertTo-SafeName -Text $targetPath
            $source = Join-Path $stage $safeName
            if (-not (Test-Path -LiteralPath $source)) {
                & $Log "Restore source missing, skipped: $source"
                continue
            }
            Assert-FH6SafeTarget -Record ([pscustomobject]@{ Path = $targetPath; Cleanable = $true })
            $parent = Split-Path -Path $targetPath -Parent
            if (-not (Test-Path -LiteralPath $parent) -and -not $DryRun) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            if (Test-Path -LiteralPath $targetPath) {
                $existing = Get-Item -LiteralPath $targetPath -Force
                $existingParent = if ($existing.PSIsContainer) { $existing.Parent.FullName } else { Split-Path -Path $existing.FullName -Parent }
                $moveLeaf = "$($existing.Name).pre_restore_$stamp"
                $movePath = Join-Path $existingParent $moveLeaf
                if ($DryRun) {
                    & $Log "DRY RUN rename existing before restore: $targetPath -> $movePath"
                }
                else {
                    Rename-Item -LiteralPath $targetPath -NewName $moveLeaf -ErrorAction Stop
                    & $Log "Renamed existing before restore: $targetPath -> $movePath"
                }
            }
            if ($DryRun) {
                & $Log "DRY RUN restore: $source -> $targetPath"
            }
            else {
                Copy-Item -LiteralPath $source -Destination $targetPath -Recurse -Force -ErrorAction Stop
                & $Log "Restored: $targetPath"
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Rename-FH6Targets {
    param(
        [Parameter(Mandatory)][object[]]$Records,
        [bool]$DryRun = $false,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    foreach ($record in $Records) {
        if (-not $record.Exists -or -not (Test-Path -LiteralPath $record.Path)) {
            & $Log "Missing, skipped: $($record.Path)"
            continue
        }
        Assert-FH6SafeTarget -Record $record
        $item = Get-Item -LiteralPath $record.Path -Force
        $parent = if ($item.PSIsContainer) { $item.Parent.FullName } else { Split-Path -Path $item.FullName -Parent }
        $newLeaf = "$($item.Name).fh6companion_$stamp"
        $newPath = Join-Path $parent $newLeaf
        if ($DryRun) {
            & $Log "DRY RUN rename: $($record.Path) -> $newPath"
        }
        else {
            Rename-Item -LiteralPath $record.Path -NewName $newLeaf -ErrorAction Stop
            & $Log "Renamed: $($record.Path) -> $newPath"
        }
    }
}

function Remove-FH6Targets {
    param(
        [Parameter(Mandatory)][object[]]$Records,
        [bool]$DryRun = $false,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    foreach ($record in $Records) {
        if (-not $record.Exists -or -not (Test-Path -LiteralPath $record.Path)) {
            & $Log "Missing, skipped: $($record.Path)"
            continue
        }
        Assert-FH6SafeTarget -Record $record
        if ($DryRun) {
            & $Log "DRY RUN delete: $($record.Path)"
        }
        else {
            Remove-Item -LiteralPath $record.Path -Recurse -Force -ErrorAction Stop
            & $Log "Deleted: $($record.Path)"
        }
    }
}

function Get-CrashReportRows {
    $rows = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $script:Config.LocalRoot) {
        Get-ChildItem -LiteralPath $script:Config.LocalRoot -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^report_\d{4}_\d{2}_\d{2}_' } |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                $xmlPath = Join-Path $_.FullName 'PreCrashReport.xml'
                $build = ''; $gpu = ''; $driver = ''
                if (Test-Path -LiteralPath $xmlPath) {
                    try {
                        [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw
                        $build = $xml.PreCrashReport.BUILD.Value
                        $gpu = $xml.PreCrashReport.THP_GPU0Description.Value
                        $driver = $xml.PreCrashReport.THP_GPU0Driver.Value
                    }
                    catch {}
                }
                [void]$rows.Add([pscustomobject]@{
                    Time       = $_.LastWriteTime
                    Name       = $_.Name
                    Build      = $build
                    GPU        = $gpu
                    Driver     = $driver
                    Path       = $_.FullName
                })
            }
    }
    return $rows.ToArray()
}

function Get-CrashEventRows {
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $since = (Get-Date).AddDays(-7)
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } -ErrorAction SilentlyContinue |
            Where-Object { ($_.ProviderName -match 'Application Error|Windows Error Reporting') -and ($_.Message -match 'forzahorizon6|Forza Horizon 6') } |
            Sort-Object TimeCreated -Descending |
            Select-Object -First 40 |
            ForEach-Object {
                $message = ($_.Message -replace "`r?`n", ' ')
                $code = if ($message -match 'Exception code:\s*(0x[0-9a-fA-F]+)') { $Matches[1] } elseif ($message -match 'P8:\s*([a-zA-Z0-9]+)') { $Matches[1] } else { 'unknown' }
                $eventName = if ($message -match 'Event Name:\s*([^\s]+)') { $Matches[1] } else { $_.ProviderName }
                $module = if ($message -match 'Faulting module name:\s*([^,]+)') { $Matches[1].Trim() } else { '' }
                [void]$rows.Add([pscustomobject]@{
                    Time       = $_.TimeCreated
                    Provider   = $_.ProviderName
                    EventName  = $eventName
                    Code       = $code
                    Module     = $module
                    Message    = $message
                })
            }
    }
    catch {}
    return $rows.ToArray()
}

function Get-UniversalCrashRows {
    param(
        [string]$Target = '',
        [int]$Days = 14,
        [int]$Max = 300
    )
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $since = (Get-Date).AddDays(-[Math]::Max(1, $Days))
        $providers = 'Application Error|Windows Error Reporting|Application Hang'
        $targetPattern = if ([string]::IsNullOrWhiteSpace($Target)) { '' } else { [regex]::Escape(($Target -replace '\.exe$', '')) }
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match $providers } |
            Sort-Object TimeCreated -Descending |
            Select-Object -First ([Math]::Max($Max * 4, 400)) |
            ForEach-Object {
                $message = ($_.Message -replace "`r?`n", ' ')
                if ($targetPattern -and $message -notmatch $targetPattern) { return }
                $app = if ($message -match 'Faulting application name:\s*([^,\s]+)') {
                    $Matches[1].Trim()
                }
                elseif ($message -match 'P1:\s*([^,\s]+)') {
                    $Matches[1].Trim()
                }
                elseif ($message -match 'The program\s+([^\s]+)\s+version') {
                    $Matches[1].Trim()
                }
                else {
                    ''
                }
                if ($app -and $app -notmatch '\.exe$') { $app = "$app.exe" }
                $code = if ($message -match 'Exception code:\s*(0x[0-9a-fA-F]+)') {
                    $Matches[1]
                }
                elseif ($message -match 'P8:\s*([a-zA-Z0-9]+)') {
                    $Matches[1]
                }
                elseif ($message -match '(0x887A[0-9a-fA-F]+|0xc000[0-9a-fA-F]+|c000[0-9a-fA-F]+)') {
                    $Matches[1]
                }
                else {
                    'unknown'
                }
                $eventName = if ($message -match 'Event Name:\s*([^\s]+)') { $Matches[1] } else { $_.ProviderName }
                $module = if ($message -match 'Faulting module name:\s*([^,]+)') { $Matches[1].Trim() } elseif ($message -match 'P4:\s*([^,\s]+)') { $Matches[1].Trim() } else { '' }
                $kind = if ($eventName -match 'BEX|APPCRASH|Application Error') { 'Crash' } elseif ($eventName -match 'Hang|AppHang') { 'Hang' } elseif ($eventName -match 'LiveKernelEvent') { 'GPU/Kernel' } else { 'WER' }
                [void]$rows.Add([pscustomobject]@{
                    Time      = $_.TimeCreated
                    App       = $app
                    Provider  = $_.ProviderName
                    EventId   = $_.Id
                    EventName = $eventName
                    Code      = $code
                    Module    = $module
                    Kind      = $kind
                    Message   = $message
                })
            }
    }
    catch {}
    return @($rows | Where-Object { $_.App -or -not $Target } | Select-Object -First $Max)
}

function Get-WERUniversalReportRows {
    param([string]$Target = '')
    $roots = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { [string]::IsNullOrWhiteSpace($Target) -or $_.Name -match [regex]::Escape(($Target -replace '\.exe$', '')) } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 100 |
            ForEach-Object {
                $app = if ($_.Name -match 'AppCrash_([^_]+)') { $Matches[1] } elseif ($_.Name -match 'AppHang_([^_]+)') { $Matches[1] } else { '' }
                [void]$rows.Add([pscustomobject]@{
                    Time   = $_.LastWriteTime
                    Name   = $_.Name
                    App    = $app
                    Type   = if ($_.Name -match 'AppHang') { 'Hang' } elseif ($_.Name -match 'LiveKernel') { 'GPU/Kernel' } else { 'Crash' }
                    Root   = $root
                    Path   = $_.FullName
                })
            }
    }
    return $rows.ToArray()
}

function Get-CrashCodeTaxonomy {
    param([string]$Code, [string]$EventName = '', [string]$Module = '')
    $codeText = ([string]$Code).ToLowerInvariant()
    if ($EventName -match 'LiveKernelEvent' -or $Module -match 'nvlddmkm|amdkmdag|igdkmdn|dxgkrnl') {
        return [pscustomobject]@{ Class='GPU/Kernel'; Severity='High'; Meaning='GPU driver reset, TDR, or kernel graphics path failure.'; NextAction='Check GPU driver, overlays, HAGS/MPO/capture features, thermals, power, and WPR/GPU evidence.' }
    }
    switch -Regex ($codeText) {
        '0xc0000005|c0000005' { return [pscustomobject]@{ Class='Access violation'; Severity='High'; Meaning='The process accessed invalid memory. Common causes include injected overlays/hooks, graphics/runtime bugs, corrupt data, or driver interactions.'; NextAction='Capture a dump, isolate overlays/hooks, test clean boot, repair runtimes, and compare the fault module.' } }
        '0xc0000409|c0000409' { return [pscustomobject]@{ Class='Stack buffer overrun'; Severity='High'; Meaning='A fast-fail or stack corruption pattern. Often needs dump evidence and conflict/runtime isolation.'; NextAction='Capture LocalDump/ProcDump evidence, remove injectors/overlays, and update/repair runtimes.' } }
        '0xc0000374|c0000374' { return [pscustomobject]@{ Class='Heap corruption'; Severity='High'; Meaning='Heap corruption or allocator damage. Often caused before the crash point.'; NextAction='Use full dump evidence, disable overlays/mods/injectors, and test clean boot.' } }
        '0xe06d7363|e06d7363' { return [pscustomobject]@{ Class='C++ exception'; Severity='Medium'; Meaning='Unhandled Microsoft C++ exception. Often points to runtime, config, data, or dependency issues.'; NextAction='Repair Visual C++ redistributables, collect WER/dump data, and compare app logs.' } }
        '0xc0000142|c0000142' { return [pscustomobject]@{ Class='DLL initialization failure'; Severity='High'; Meaning='A dependency or injected DLL failed during startup.'; NextAction='Check VC++/.NET/driver dependencies, security software, overlays, and install integrity.' } }
        '0xc000007b|c000007b' { return [pscustomobject]@{ Class='Bad image / architecture mismatch'; Severity='High'; Meaning='Often x86/x64 dependency mismatch or corrupt runtime DLL.'; NextAction='Repair VC++ runtimes, DirectX runtime dependencies, and verify the application install.' } }
        '0xc0000135|c0000135' { return [pscustomobject]@{ Class='Missing dependency'; Severity='High'; Meaning='A required DLL/runtime was not found.'; NextAction='Install/repair required runtimes, .NET/Desktop Runtime, VC++ redists, and app prerequisites.' } }
        '0x887a0005|0x887a0006|0x887a0007|0x887a0020' { return [pscustomobject]@{ Class='DXGI/GPU device fault'; Severity='High'; Meaning='DirectX device removed/hung/reset style fault.'; NextAction='Check GPU driver clean install, overlays, HAGS/MPO/capture, power/thermal limits, and WPR/GPU traces.' } }
        default { return [pscustomobject]@{ Class='Unknown/generic'; Severity='Medium'; Meaning='The crash code is not mapped yet or was not present in the event.'; NextAction='Group fingerprints, collect WER/LocalDump evidence, and correlate with drivers, overlays, and recent changes.' } }
    }
}

function Get-UniversalCrashFingerprintRows {
    param([string]$Target = '')
    $events = @(Get-UniversalCrashRows -Target $Target)
    if ($events.Count -eq 0) {
        return @([pscustomobject]@{ Count=0; App=$Target; FirstSeen=''; LastSeen=''; EventName='<none>'; Code=''; Module=''; Class='No evidence'; Severity='Info'; NextAction='No matching Windows crash events found.' })
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $events | Group-Object App, EventName, Code, Module | Sort-Object Count -Descending | ForEach-Object {
        $groupRows = @($_.Group | Sort-Object Time)
        $tax = Get-CrashCodeTaxonomy -Code $groupRows[0].Code -EventName $groupRows[0].EventName -Module $groupRows[0].Module
        [void]$rows.Add([pscustomobject]@{
            Count      = $_.Count
            App        = $groupRows[0].App
            FirstSeen  = $groupRows[0].Time
            LastSeen   = $groupRows[-1].Time
            EventName  = $groupRows[0].EventName
            Code       = $groupRows[0].Code
            Module     = $groupRows[0].Module
            Class      = $tax.Class
            Severity   = $tax.Severity
            NextAction = $tax.NextAction
        })
    }
    return $rows.ToArray()
}

function Get-UniversalCrashTaxonomyRows {
    param([string]$Target = '')
    $rows = New-Object System.Collections.Generic.List[object]
    $fingerprints = @(Get-UniversalCrashFingerprintRows -Target $Target | Where-Object { $_.Count -gt 0 })
    foreach ($fp in $fingerprints) {
        $tax = Get-CrashCodeTaxonomy -Code $fp.Code -EventName $fp.EventName -Module $fp.Module
        [void]$rows.Add([pscustomobject]@{
            App        = $fp.App
            Count      = $fp.Count
            Code       = $fp.Code
            Module     = $fp.Module
            Class      = $tax.Class
            Severity   = $tax.Severity
            Meaning    = $tax.Meaning
            NextAction = $tax.NextAction
        })
    }
    if ($rows.Count -eq 0) {
        [void]$rows.Add([pscustomobject]@{ App=$Target; Count=0; Code=''; Module=''; Class='No evidence'; Severity='Info'; Meaning='No matching crash fingerprints found.'; NextAction='Run the game once, reproduce the crash, then scan again.' })
    }
    return $rows.ToArray()
}

function Get-ExternalEvidenceToolRows {
    $tools = @(
        @{ Name='DxDiag'; Command='dxdiag.exe'; Purpose='DirectX, GPU, audio, display, and input context.' },
        @{ Name='ProcDump'; Command='procdump.exe'; Purpose='Microsoft Sysinternals crash/hang dump capture.' },
        @{ Name='WPR'; Command='wpr.exe'; Purpose='Windows Performance Recorder ETW traces for system/GPU/perf behavior.' },
        @{ Name='SFC'; Command='sfc.exe'; Purpose='System File Checker for corrupted Windows system files.' },
        @{ Name='DISM'; Command='dism.exe'; Purpose='Windows image health check and repair.' },
        @{ Name='WinDbg'; Command='windbg.exe'; Purpose='Crash dump inspection and module/fault analysis.' }
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($tool in $tools) {
        $cmd = Get-Command $tool.Command -ErrorAction SilentlyContinue
        [void]$rows.Add([pscustomobject]@{
            Tool    = $tool.Name
            Status  = if ($cmd) { 'Available' } else { 'Missing' }
            Command = $tool.Command
            Path    = if ($cmd) { $cmd.Source } else { '' }
            Purpose = $tool.Purpose
        })
    }
    return $rows.ToArray()
}

function Get-LocalDumpConfigRows {
    param([string]$Target = '')
    $basePaths = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps',
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($base in $basePaths) {
        foreach ($key in @($base, $(if ($Target) { Join-Path $base $Target } else { $null }))) {
            if (-not $key) { continue }
            try {
                $prop = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                [void]$rows.Add([pscustomobject]@{
                    Scope      = if ($key -eq $base) { 'Default' } else { 'Per-app' }
                    Hive       = if ($base -match 'HKEY_LOCAL_MACHINE') { 'HKLM' } else { 'HKCU' }
                    Target     = if ($key -eq $base) { '<all apps>' } else { Split-Path -Path $key -Leaf }
                    DumpFolder = [string]$prop.DumpFolder
                    DumpCount  = [string]$prop.DumpCount
                    DumpType   = [string]$prop.DumpType
                    Status     = 'Configured'
                })
            }
            catch {
                [void]$rows.Add([pscustomobject]@{
                    Scope      = if ($key -eq $base) { 'Default' } else { 'Per-app' }
                    Hive       = if ($base -match 'HKEY_LOCAL_MACHINE') { 'HKLM' } else { 'HKCU' }
                    Target     = if ($key -eq $base) { '<all apps>' } else { Split-Path -Path $key -Leaf }
                    DumpFolder = ''
                    DumpCount  = ''
                    DumpType   = ''
                    Status     = 'Not configured'
                })
            }
        }
    }
    return $rows.ToArray()
}

function Get-UniversalCrashActionRows {
    param([string]$Target = '')
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Action($Priority, $Area, $State, $Action, $Evidence) {
        [void]$rows.Add([pscustomobject]@{ Priority=$Priority; Area=$Area; State=$State; Action=$Action; Evidence=$Evidence })
    }
    $events = @(Get-UniversalCrashRows -Target $Target)
    $fingerprints = @(Get-UniversalCrashFingerprintRows -Target $Target | Where-Object { $_.Count -gt 0 })
    $tools = @(Get-ExternalEvidenceToolRows)
    $dumps = @(Get-LocalDumpConfigRows -Target $Target)
    $conflicts = @(Get-ConflictProcesses)
    if ($events.Count -eq 0) {
        Add-Action 3 'Evidence' 'Waiting' 'Reproduce the crash once, then scan again or enable Crash Watch.' 'No matching Windows crash evidence was found.'
    }
    else {
        Add-Action 1 'Fingerprint' 'Active' 'Group the top crash signature and test whether it changes after each fix.' "$($events.Count) event(s); top=$($fingerprints[0].App) $($fingerprints[0].Code) $($fingerprints[0].Module)"
    }
    $high = @($fingerprints | Where-Object { $_.Severity -eq 'High' })
    if ($high.Count -gt 0) {
        Add-Action 1 'High Severity Pattern' 'Warn' $high[0].NextAction "$($high[0].Class): $($high[0].Count)x $($high[0].Code)"
    }
    $dumpConfigured = @($dumps | Where-Object { $_.Status -eq 'Configured' -and ($_.Target -eq $Target -or $_.Target -eq '<all apps>') })
    if ($events.Count -gt 0 -and $dumpConfigured.Count -eq 0) {
        Add-Action 2 'Deeper Evidence' 'Ready' 'Use the LocalDump/ProcDump command generator before the next repro if you need developer-grade evidence.' 'No matching LocalDumps registry configuration detected.'
    }
    if (@($tools | Where-Object { $_.Tool -eq 'ProcDump' -and $_.Status -eq 'Missing' }).Count -gt 0) {
        Add-Action 3 'Tooling' 'Info' 'ProcDump is not on PATH. Use Sysinternals ProcDump when dump evidence is needed.' 'ProcDump missing from PATH.'
    }
    if ($conflicts.Count -gt 0) {
        Add-Action 1 'Overlay/Hook Isolation' 'Warn' 'Stop visible overlay, capture, performance, tuning, and input-hook tools before a clean repro.' (($conflicts | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')
    }
    Add-Action 3 'Windows Health' 'Ready' 'Run DISM/SFC from an elevated terminal if crashes span multiple unrelated games/apps.' 'Use the generated command playbook; this tool does not silently run repairs.'
    Add-Action 4 'Packaging' 'Ready' 'Export a Universal CrashScope report after every major repro or fix attempt.' "Universal data root: $($script:Config.UniversalRoot)"
    return @($rows | Sort-Object Priority, Area)
}

function Get-CrashScopeCommandText {
    param([string]$Target = 'game.exe')
    if ([string]::IsNullOrWhiteSpace($Target)) { $Target = 'game.exe' }
    if ($Target -notmatch '\.exe$') { $Target = "$Target.exe" }
    $dumpFolder = Join-Path $script:Config.UniversalRoot 'LocalDumps'
    return @"
CrashScope Command Playbook
===========================
Target: $Target

These commands are intentionally generated for you to review and run manually.
They do not modify game install files.

1. Create a dump folder:
   mkdir "$dumpFolder"

2. Configure Windows Error Reporting LocalDumps for this target:
   reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\$Target" /v DumpFolder /t REG_EXPAND_SZ /d "$dumpFolder" /f
   reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\$Target" /v DumpCount /t REG_DWORD /d 10 /f
   reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\$Target" /v DumpType /t REG_DWORD /d 2 /f

3. Optional ProcDump crash capture if Sysinternals ProcDump is installed:
   procdump.exe -ma -e -x "$dumpFolder" $Target

4. Optional ProcDump hang capture after the process is running:
   procdump.exe -ma -h $Target "$dumpFolder"

5. Optional WPR trace for system/GPU/performance context:
   wpr.exe -start GeneralProfile
   rem Reproduce the issue, then:
   wpr.exe -stop "$($script:Config.UniversalRoot)\CrashScopeTrace.etl"

6. Windows health checks for multi-game/system-wide crashes, run in elevated terminal:
   DISM.exe /Online /Cleanup-Image /RestoreHealth
   sfc /scannow
"@
}

function Export-UniversalCrashReport {
    param([string]$Target = '')
    New-ToolDirectory
    $safeTarget = if ([string]::IsNullOrWhiteSpace($Target)) { 'all-apps' } else { ConvertTo-SafeName -Text $Target }
    $path = Join-Path $script:Config.UniversalRoot ("CrashScope_Report_{0}_{1}.txt" -f $safeTarget, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('CrashScope Universal Crash Report')
    [void]$lines.Add('=================================')
    [void]$lines.Add("Generated: $(Get-Date)")
    [void]$lines.Add("Target: $(if ($Target) { $Target } else { '<all application crashes>' })")
    [void]$lines.Add('')
    [void]$lines.Add('== Action Plan ==')
    foreach ($a in Get-UniversalCrashActionRows -Target $Target) { [void]$lines.Add("[P$($a.Priority)] $($a.Area) [$($a.State)]: $($a.Action) Evidence=$($a.Evidence)") }
    [void]$lines.Add('')
    [void]$lines.Add('== Crash Intelligence ==')
    [void]$lines.Add((Get-CrashIntelligenceSummary -Target $Target))
    [void]$lines.Add('')
    [void]$lines.Add('== Fingerprints ==')
    foreach ($f in Get-UniversalCrashFingerprintRows -Target $Target) { [void]$lines.Add("$($f.Count)x $($f.App) $($f.EventName) $($f.Code) module=$($f.Module) class=$($f.Class) first=$($f.FirstSeen) last=$($f.LastSeen)") }
    [void]$lines.Add('')
    [void]$lines.Add('== Taxonomy ==')
    foreach ($t in Get-UniversalCrashTaxonomyRows -Target $Target) { [void]$lines.Add("$($t.App) $($t.Code) $($t.Class): $($t.Meaning) Next=$($t.NextAction)") }
    [void]$lines.Add('')
    [void]$lines.Add('== Recent Crash Events ==')
    foreach ($e in Get-UniversalCrashRows -Target $Target | Select-Object -First 80) { [void]$lines.Add("$($e.Time) $($e.App) $($e.EventName) $($e.Code) module=$($e.Module) provider=$($e.Provider)") }
    [void]$lines.Add('')
    [void]$lines.Add('== WER Report Folders ==')
    foreach ($w in Get-WERUniversalReportRows -Target $Target | Select-Object -First 80) { [void]$lines.Add("$($w.Time) $($w.Type) $($w.Name) $($w.Path)") }
    [void]$lines.Add('')
    [void]$lines.Add('== Evidence Tool Readiness ==')
    foreach ($tool in Get-ExternalEvidenceToolRows) { [void]$lines.Add("$($tool.Tool) [$($tool.Status)] $($tool.Path) - $($tool.Purpose)") }
    [void]$lines.Add('')
    [void]$lines.Add('== LocalDump Configuration ==')
    foreach ($dump in Get-LocalDumpConfigRows -Target $Target) { [void]$lines.Add("$($dump.Hive) $($dump.Scope) $($dump.Target) [$($dump.Status)] folder=$($dump.DumpFolder) count=$($dump.DumpCount) type=$($dump.DumpType)") }
    [void]$lines.Add('')
    [void]$lines.Add((Get-CrashScopeCommandText -Target $(if ($Target) { $Target } else { 'game.exe' })))
    ($lines -join [Environment]::NewLine) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function ConvertTo-DateTimeSafe {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return [datetime]$Value }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        if ($text -match '^\d{14}\.\d{6}[\+\-]\d{3}$' -or $text -match '^\d{14}\.\d{6}') {
            return [System.Management.ManagementDateTimeConverter]::ToDateTime($text)
        }
    }
    catch {}
    try {
        if ($text -match '^\d{8}$') {
            return [datetime]::ParseExact($text, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    catch {}
    try { return [datetime]$text } catch { return $null }
}

function Get-UniversalReliabilityRows {
    param([string]$Target = '', [int]$Days = 30)
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $since = (Get-Date).AddDays(-[Math]::Max(1, $Days))
        $targetPattern = if ([string]::IsNullOrWhiteSpace($Target)) { '' } else { [regex]::Escape(($Target -replace '\.exe$', '')) }
        Get-CimInstance -ClassName Win32_ReliabilityRecords -ErrorAction Stop |
            Where-Object {
                $time = ConvertTo-DateTimeSafe $_.TimeGenerated
                $matchesTarget = (-not $targetPattern) -or $_.Message -match $targetPattern -or $_.ProductName -match $targetPattern -or $_.SourceName -match $targetPattern
                $time -and $time -ge $since -and $matchesTarget
            } |
            Sort-Object TimeGenerated -Descending |
            Select-Object -First 120 |
            ForEach-Object {
                [void]$rows.Add([pscustomobject]@{
                    TimeGenerated = ConvertTo-DateTimeSafe $_.TimeGenerated
                    SourceName    = $_.SourceName
                    ProductName   = $_.ProductName
                    EventId       = $_.EventIdentifier
                    Message       = $_.Message
                })
            }
    }
    catch {
        [void]$rows.Add([pscustomobject]@{ TimeGenerated=$null; SourceName='Unavailable'; ProductName=''; EventId=''; Message=$_.Exception.Message })
    }
    return $rows.ToArray()
}

function Get-GpuTdrEventRows {
    param([int]$Days = 30)
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $since = (Get-Date).AddDays(-[Math]::Max(1, $Days))
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since } -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProviderName -match 'Display|nvlddmkm|amdkmdag|amdwddmg|igfx|igdkmd|dxgkrnl|WHEA' -or
                $_.Message -match 'display driver|stopped responding|recovered|LiveKernelEvent|TDR|device removed|DXGI'
            } |
            Sort-Object TimeCreated -Descending |
            Select-Object -First 120 |
            ForEach-Object {
                [void]$rows.Add([pscustomobject]@{
                    Time     = $_.TimeCreated
                    Provider = $_.ProviderName
                    EventId  = $_.Id
                    Level    = $_.LevelDisplayName
                    Signal   = if ($_.Message -match 'stopped responding|recovered') { 'Display driver reset/recovery' } elseif ($_.Message -match 'WHEA') { 'Hardware error' } else { 'GPU/System signal' }
                    Message  = ($_.Message -replace "`r?`n", ' ')
                })
            }
    }
    catch {}
    return $rows.ToArray()
}

function Get-RecentSystemChangeRows {
    param([datetime]$Anchor = (Get-Date), [int]$DaysBack = 14)
    $rows = New-Object System.Collections.Generic.List[object]
    $windowStart = $Anchor.AddDays(-[Math]::Max(1, $DaysBack))
    try {
        Get-HotFix -ErrorAction SilentlyContinue | ForEach-Object {
            $time = ConvertTo-DateTimeSafe $_.InstalledOn
            if ($time -and $time -ge $windowStart -and $time -le $Anchor.AddDays(1)) {
                [void]$rows.Add([pscustomobject]@{
                    Time = $time
                    Type = 'Windows Update'
                    Name = $_.HotFixID
                    Detail = "$($_.Description) installed by $($_.InstalledBy)"
                    Relevance = 'OS patch level can affect drivers, graphics stack, runtimes, and security components.'
                })
            }
        }
    }
    catch {}
    try {
        foreach ($driver in Get-DriverInventoryRows) {
            $time = ConvertTo-DateTimeSafe $driver.DriverDate
            if ($time -and $time -ge $windowStart -and $time -le $Anchor.AddDays(1)) {
                [void]$rows.Add([pscustomobject]@{
                    Time = $time
                    Type = 'Driver'
                    Name = $driver.DeviceName
                    Detail = "$($driver.DeviceClass) $($driver.Manufacturer) version=$($driver.DriverVersion) inf=$($driver.InfName)"
                    Relevance = if ($driver.DeviceClass -match 'DISPLAY') { 'Display driver changes are highly relevant to DXGI, TDR, access violation, and BEX game crashes.' } else { 'Device driver changes may affect input/audio/USB/runtime stability.' }
                })
            }
        }
    }
    catch {}
    $uninstallRoots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        try {
            Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
                $key = $_
                $prop = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                if (-not $prop.DisplayName) { return }
                $time = ConvertTo-DateTimeSafe $prop.InstallDate
                if (-not $time) { $time = ConvertTo-DateTimeSafe $key.GetValue('InstallDate') }
                if ($time -and $time -ge $windowStart -and $time -le $Anchor.AddDays(1)) {
                    [void]$rows.Add([pscustomobject]@{
                        Time = $time
                        Type = 'Software Install'
                        Name = $prop.DisplayName
                        Detail = "Version=$($prop.DisplayVersion); Publisher=$($prop.Publisher)"
                        Relevance = 'New overlays, launchers, runtimes, anti-cheat, capture tools, or driver helpers can correlate with new crash signatures.'
                    })
                }
            }
        }
        catch {}
    }
    return @($rows | Sort-Object Time -Descending)
}

function Get-UniversalCrashHeatmapRows {
    param([string]$Target = '', [int]$Days = 30)
    $events = @(Get-UniversalCrashRows -Target $Target -Days $Days -Max 500)
    if ($events.Count -eq 0) {
        return @([pscustomobject]@{ Count=0; App=$Target; Code=''; Module=''; Class='No evidence'; FirstSeen=''; LastSeen=''; EventsPerDay=0; SuggestedFocus='Reproduce the crash and scan again.' })
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $events | Group-Object App, Code, Module | Sort-Object Count -Descending | ForEach-Object {
        $groupRows = @($_.Group | Sort-Object Time)
        $tax = Get-CrashCodeTaxonomy -Code $groupRows[0].Code -EventName $groupRows[0].EventName -Module $groupRows[0].Module
        $spanDays = [Math]::Max(1, (([datetime]$groupRows[-1].Time) - ([datetime]$groupRows[0].Time)).TotalDays)
        [void]$rows.Add([pscustomobject]@{
            Count       = $_.Count
            App         = $groupRows[0].App
            Code        = $groupRows[0].Code
            Module      = $groupRows[0].Module
            Class       = $tax.Class
            FirstSeen   = $groupRows[0].Time
            LastSeen    = $groupRows[-1].Time
            EventsPerDay = [math]::Round($_.Count / $spanDays, 2)
            SuggestedFocus = $tax.NextAction
        })
    }
    return $rows.ToArray()
}

function Get-UniversalRootCauseScoreRows {
    param([string]$Target = '')
    $scores = @{}
    $evidence = @{}
    function Add-Score($Cause, [int]$Points, $Why) {
        if (-not $scores.ContainsKey($Cause)) { $scores[$Cause] = 0; $evidence[$Cause] = New-Object System.Collections.Generic.List[string] }
        $scores[$Cause] += $Points
        [void]$evidence[$Cause].Add($Why)
    }

    $events = @(Get-UniversalCrashRows -Target $Target)
    $fingerprints = @(Get-UniversalCrashFingerprintRows -Target $Target | Where-Object { $_.Count -gt 0 })
    $conflicts = @(Get-ConflictProcesses)
    $captureRows = @(Get-WindowsGamingSettingRows | Where-Object { $_.Area -in @('Game Bar','Capture') -and $_.Interpretation -match 'Enabled|active' })
    $tdrRows = @(Get-GpuTdrEventRows -Days 30)
    $reliability = @(Get-UniversalReliabilityRows -Target $Target -Days 30 | Where-Object { $_.SourceName -ne 'Unavailable' })
    $latest = @($events | Select-Object -First 1)
    $changes = if ($latest.Count) { @(Get-RecentSystemChangeRows -Anchor ([datetime]$latest[0].Time) -DaysBack 14) } else { @(Get-RecentSystemChangeRows -Anchor (Get-Date) -DaysBack 14) }
    $runtimeWarnings = New-Object System.Collections.Generic.List[string]
    $mf = Get-MediaFoundationStatus
    if ($mf.Status -ne 'OK') { [void]$runtimeWarnings.Add("Media Foundation: $($mf.Detail)") }
    $redists = @(Get-VisualCRedistRows)
    $hasModernRedist = @($redists | Where-Object {
        $_.Name -match '2015-2022|2015.*2022|2017|2019|2022|v14' -or
        ($_.Version -and ([version]$_.Version -ge [version]'14.0.0.0'))
    }).Count -gt 0
    if (-not $hasModernRedist) { [void]$runtimeWarnings.Add('Modern VC++ redistributable not detected') }

    if ($events.Count -eq 0) { Add-Score 'Evidence gap' 25 'No matching Windows crash events found yet.' }
    foreach ($fp in $fingerprints) {
        if ($fp.Class -match 'Access violation|Stack buffer|Heap') { Add-Score 'Memory/runtime fault' ([Math]::Min(35, 10 + $fp.Count)) "$($fp.Count)x $($fp.Class) $($fp.Code) module=$($fp.Module)" }
        if ($fp.Class -match 'DXGI|GPU|Kernel' -or $fp.Module -match 'nvlddmkm|amdkmdag|igdk|dxgi|d3d|dxgkrnl') { Add-Score 'GPU driver/device path' ([Math]::Min(40, 12 + $fp.Count * 2)) "$($fp.Count)x $($fp.Class) module=$($fp.Module)" }
        if ($fp.Class -match 'Missing dependency|Bad image|DLL initialization|C\+\+') { Add-Score 'Dependency/runtime repair' ([Math]::Min(35, 12 + $fp.Count * 2)) "$($fp.Count)x $($fp.Class) $($fp.Code)" }
    }
    if ($conflicts.Count -gt 0) { Add-Score 'Overlay/hook/capture conflict' (20 + [Math]::Min(20, $conflicts.Count * 4)) (($conflicts | Select-Object -ExpandProperty ProcessName -Unique) -join ', ') }
    if ($captureRows.Count -gt 0) { Add-Score 'Overlay/hook/capture conflict' (10 + $captureRows.Count * 3) (($captureRows | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ') }
    if ($tdrRows.Count -gt 0) { Add-Score 'GPU driver/device path' (15 + [Math]::Min(25, $tdrRows.Count * 2)) "$($tdrRows.Count) GPU/System display event(s) in 30 days" }
    if ($runtimeWarnings.Count -gt 0) { Add-Score 'Dependency/runtime repair' 20 ($runtimeWarnings -join '; ') }
    if (@($changes | Where-Object { $_.Type -match 'Driver|Windows Update' }).Count -gt 0) { Add-Score 'Recent system change correlation' 18 "$(@($changes | Where-Object { $_.Type -match 'Driver|Windows Update' }).Count) recent driver/update change(s)" }
    if (@($changes | Where-Object { $_.Type -eq 'Software Install' }).Count -gt 0) { Add-Score 'Recent system change correlation' 10 "$(@($changes | Where-Object { $_.Type -eq 'Software Install' }).Count) recent software install(s)" }
    if ($reliability.Count -gt 3) { Add-Score 'Repeated reliability failure' 15 "$($reliability.Count) Reliability Monitor row(s)" }
    $multiApp = @(Get-UniversalCrashRows -Target '' -Days 14 -Max 300 | Where-Object { $_.App } | Select-Object -ExpandProperty App -Unique)
    if ($multiApp.Count -gt 3) { Add-Score 'System-wide instability' (15 + [Math]::Min(25, $multiApp.Count * 2)) "$($multiApp.Count) distinct crashing app(s) in recent Application/WER evidence" }
    $dumpConfigured = @(Get-LocalDumpConfigRows -Target $Target | Where-Object { $_.Status -eq 'Configured' -and ($_.Target -eq $Target -or $_.Target -eq '<all apps>') })
    if ($events.Count -gt 0 -and $dumpConfigured.Count -eq 0) { Add-Score 'Evidence gap' 20 'Crash events exist but LocalDumps are not configured for the target.' }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($cause in $scores.Keys) {
        $score = [Math]::Min(100, [int]$scores[$cause])
        $confidence = if ($score -ge 70) { 'High' } elseif ($score -ge 40) { 'Medium' } else { 'Low' }
        $next = switch -Regex ($cause) {
            'GPU' { 'Use CrashScope commands for WPR/LocalDumps, clean-install GPU driver, disable overlays/capture/HAGS-style variables for one repro, and compare TDR/DXGI evidence.'; break }
            'Overlay' { 'Stop overlay/hook/capture/tuning/input tools and run one clean repro, then verify whether the fingerprint changes or disappears.'; break }
            'Dependency|runtime' { 'Repair VC++/.NET/DirectX/media dependencies and verify install integrity, then rescan fingerprints.'; break }
            'system change' { 'Review recent driver/update/software changes around the crash anchor; roll back or isolate one change at a time.'; break }
            'System-wide' { 'Use DISM/SFC, driver health checks, memory/storage checks, and all-app CrashScope scan because failures are not isolated to one game.'; break }
            'Evidence gap' { 'Export CrashScope report and configure LocalDumps/ProcDump manually from the generated command playbook before the next repro.'; break }
            default { 'Follow the CrashScope action plan and collect stronger evidence before changing more variables.' }
        }
        [void]$rows.Add([pscustomobject]@{
            Cause      = $cause
            Score      = $score
            Confidence = $confidence
            Evidence   = (@($evidence[$cause]) | Select-Object -First 4) -join '; '
            NextAction = $next
        })
    }
    if ($rows.Count -eq 0) {
        [void]$rows.Add([pscustomobject]@{ Cause='No strong signal yet'; Score=0; Confidence='Info'; Evidence='No scoring rule matched.'; NextAction='Reproduce the crash, run Scan Target, then export a CrashScope report.' })
    }
    return @($rows | Sort-Object @{ Expression = 'Score'; Descending = $true }, Cause)
}

function Get-CrashIntelChangeCorrelationRows {
    param([string]$Target = '')
    $latest = @(Get-UniversalCrashRows -Target $Target | Select-Object -First 1)
    $anchor = if ($latest.Count) { [datetime]$latest[0].Time } else { Get-Date }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($change in Get-RecentSystemChangeRows -Anchor $anchor -DaysBack 21) {
        $distance = [math]::Round(($anchor - ([datetime]$change.Time)).TotalDays, 1)
        $weight = if ($change.Type -eq 'Driver' -and $change.Detail -match 'DISPLAY|NVIDIA|AMD|Intel') { 'High' } elseif ($distance -le 3) { 'Medium' } else { 'Low' }
        [void]$rows.Add([pscustomobject]@{
            Time = $change.Time
            Type = $change.Type
            Name = $change.Name
            DaysBeforeCrash = $distance
            Weight = $weight
            Detail = $change.Detail
            Relevance = $change.Relevance
        })
    }
    foreach ($tdr in Get-GpuTdrEventRows -Days 21 | Select-Object -First 40) {
        $distance = [math]::Round([Math]::Abs((([datetime]$tdr.Time) - $anchor).TotalDays), 1)
        [void]$rows.Add([pscustomobject]@{
            Time = $tdr.Time
            Type = 'GPU/System Event'
            Name = "$($tdr.Provider) $($tdr.EventId)"
            DaysBeforeCrash = if ($tdr.Time -le $anchor) { [math]::Round(($anchor - ([datetime]$tdr.Time)).TotalDays, 1) } else { -[math]::Round((([datetime]$tdr.Time) - $anchor).TotalDays, 1) }
            Weight = if ($distance -le 1) { 'High' } elseif ($distance -le 7) { 'Medium' } else { 'Low' }
            Detail = $tdr.Signal
            Relevance = $tdr.Message
        })
    }
    return @($rows | Sort-Object @{ Expression = { if ($_.Weight -eq 'High') { 0 } elseif ($_.Weight -eq 'Medium') { 1 } else { 2 } } }, Time -Descending)
}

function Get-CrashIntelligenceSummary {
    param([string]$Target = '')
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Crash Intelligence Summary')
    [void]$lines.Add('==========================')
    [void]$lines.Add("Target: $(if ($Target) { $Target } else { '<all application crashes>' })")
    [void]$lines.Add('')
    [void]$lines.Add('Likely causes:')
    foreach ($row in Get-UniversalRootCauseScoreRows -Target $Target | Select-Object -First 8) {
        [void]$lines.Add("  [$($row.Confidence) $($row.Score)] $($row.Cause)")
        [void]$lines.Add("    Evidence: $($row.Evidence)")
        [void]$lines.Add("    Next: $($row.NextAction)")
    }
    [void]$lines.Add('')
    [void]$lines.Add('Top heatmap:')
    foreach ($row in Get-UniversalCrashHeatmapRows -Target $Target | Select-Object -First 8) {
        [void]$lines.Add("  $($row.Count)x $($row.App) $($row.Code) module=$($row.Module) class=$($row.Class) last=$($row.LastSeen)")
    }
    [void]$lines.Add('')
    [void]$lines.Add('Change correlation:')
    foreach ($row in Get-CrashIntelChangeCorrelationRows -Target $Target | Select-Object -First 10) {
        [void]$lines.Add("  [$($row.Weight)] $($row.Time) $($row.Type) $($row.Name): $($row.Detail)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-SecurityBlockEventRows {
    param([string]$Target = '', [int]$Days = 30)
    $cacheKey = "SecurityBlock|$Target|$Days"
    if ($script:StabilityCache.ContainsKey($cacheKey)) { return $script:StabilityCache[$cacheKey] }
    $rows = New-Object System.Collections.Generic.List[object]
    $logName = 'Microsoft-Windows-Windows Defender/Operational'
    $ids = @(1121,1122,1123,1124,1127,1128,5007)
    $targetPattern = if ([string]::IsNullOrWhiteSpace($Target)) { '' } else { [regex]::Escape(($Target -replace '\.exe$', '')) }
    try {
        $since = (Get-Date).AddDays(-[Math]::Max(1, $Days))
        Get-WinEvent -FilterHashtable @{ LogName = $logName; Id = $ids; StartTime = $since } -ErrorAction Stop |
            Sort-Object TimeCreated -Descending |
            Select-Object -First 180 |
            ForEach-Object {
                $message = ($_.Message -replace "`r?`n", ' ')
                if ($targetPattern -and $message -notmatch $targetPattern) { return }
                $process = if ($message -match 'Process Name:\s*([^\s]+)') { $Matches[1].Trim() } elseif ($message -match 'Path:\s*([^\s]+\.exe)') { $Matches[1].Trim() } else { '' }
                $path = if ($message -match 'Path:\s*([^\s]+)') { $Matches[1].Trim() } else { '' }
                $category = switch ($_.Id) {
                    1121 { 'ASR blocked' }
                    1122 { 'ASR audited' }
                    1123 { 'Controlled Folder blocked' }
                    1124 { 'Controlled Folder audited' }
                    1127 { 'Controlled Folder sector blocked' }
                    1128 { 'Controlled Folder sector audited' }
                    5007 { 'Defender setting changed' }
                    default { 'Defender event' }
                }
                [void]$rows.Add([pscustomobject]@{
                    Time     = $_.TimeCreated
                    EventId  = $_.Id
                    Category = $category
                    Process  = $process
                    Path     = $path
                    Level    = $_.LevelDisplayName
                    Message  = $message
                })
            }
    }
    catch {}
    $result = $rows.ToArray()
    $script:StabilityCache[$cacheKey] = $result
    return $result
}

function Get-CrashEvidenceTimelineRows {
    param([string]$Target = '', [int]$Days = 30, [int]$Max = 600)
    $cacheKey = "EvidenceTimeline|$Target|$Days|$Max"
    if ($script:StabilityCache.ContainsKey($cacheKey)) { return $script:StabilityCache[$cacheKey] }
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Timeline($Time, $Lane, $Severity, $Subject, $Signal, $Confidence, $Detail, $Path) {
        if (-not $Time) { return }
        [void]$rows.Add([pscustomobject]@{
            Time       = $Time
            Lane       = $Lane
            Severity   = $Severity
            Subject    = $Subject
            Signal     = $Signal
            Confidence = $Confidence
            Detail     = $Detail
            Path       = $Path
        })
    }

    foreach ($event in Get-UniversalCrashRows -Target $Target -Days $Days -Max $Max) {
        $tax = Get-CrashCodeTaxonomy -Code $event.Code -EventName $event.EventName -Module $event.Module
        $confidence = if ($event.Provider -eq 'Application Error' -and $event.EventId -eq 1000) { 'High' } elseif ($event.Provider -match 'Windows Error Reporting') { 'Medium' } else { 'Medium' }
        Add-Timeline $event.Time 'Crash' $tax.Severity $event.App "$($event.EventName) $($event.Code)" $confidence "Module=$($event.Module); Class=$($tax.Class); Provider=$($event.Provider); EventId=$($event.EventId)" ''
    }

    foreach ($wer in Get-WERUniversalReportRows -Target $Target) {
        Add-Timeline $wer.Time 'WER' 'Medium' $wer.App $wer.Type 'Medium' $wer.Name $wer.Path
    }

    foreach ($rel in Get-UniversalReliabilityRows -Target $Target -Days $Days | Where-Object { $_.SourceName -ne 'Unavailable' }) {
        Add-Timeline $rel.TimeGenerated 'Reliability' 'Medium' $rel.ProductName "$($rel.SourceName) $($rel.EventId)" 'Medium' $rel.Message ''
    }

    foreach ($tdr in Get-GpuTdrEventRows -Days $Days) {
        $sev = if ($tdr.Level -match 'Error|Critical|Warning' -or $tdr.Signal -match 'Hardware|reset') { 'High' } else { 'Medium' }
        Add-Timeline $tdr.Time 'GPU/TDR' $sev 'System graphics' "$($tdr.Provider) $($tdr.EventId)" 'Medium' "$($tdr.Signal): $($tdr.Message)" ''
    }

    foreach ($sec in Get-SecurityBlockEventRows -Target $Target -Days $Days) {
        $sev = if ($sec.EventId -in @(1121,1123,1127)) { 'High' } elseif ($sec.EventId -in @(1122,1124,1128)) { 'Medium' } else { 'Low' }
        $confidence = if ($sec.EventId -in @(1121,1123,1127)) { 'High' } else { 'Medium' }
        Add-Timeline $sec.Time 'Security' $sev $sec.Process "$($sec.Category) $($sec.EventId)" $confidence $sec.Message $sec.Path
    }

    $anchor = Get-Date
    $latestCrash = @(Get-UniversalCrashRows -Target $Target -Days $Days -Max 1 | Select-Object -First 1)
    if ($latestCrash.Count -gt 0 -and $latestCrash[0].Time) { $anchor = [datetime]$latestCrash[0].Time }
    foreach ($change in Get-RecentSystemChangeRows -Anchor $anchor -DaysBack ([Math]::Min($Days, 30))) {
        $sev = if ($change.Type -match 'Driver|Windows Update') { 'Medium' } else { 'Low' }
        Add-Timeline $change.Time 'Change' $sev $change.Name $change.Type 'Low' "$($change.Detail); $($change.Relevance)" ''
    }

    if ([string]::IsNullOrWhiteSpace($Target) -or $Target -match 'forzahorizon6|forza') {
        foreach ($report in Get-CrashReportRows) {
            Add-Timeline $report.Time 'FH6 Report' 'Medium' $script:Config.ExeName $report.Name 'High' "Build=$($report.Build); GPU=$($report.GPU); Driver=$($report.Driver)" $report.Path
        }
        foreach ($item in Get-FH6Inventory | Where-Object { $_.LastWriteTime }) {
            Add-Timeline $item.LastWriteTime 'User Data' ($(if ($item.Risk -match 'Save') { 'Medium' } else { 'Low' })) $item.Category $item.Risk 'Low' "$($item.SizeMB) MB; $($item.Items) item(s); $($item.Description)" $item.Path
        }
    }

    $result = @($rows | Sort-Object Time -Descending | Select-Object -First $Max)
    $script:StabilityCache[$cacheKey] = $result
    return $result
}

function Get-CrashEvidenceInsightRows {
    param([string]$Target = '')
    $cacheKey = "EvidenceInsights|$Target"
    if ($script:StabilityCache.ContainsKey($cacheKey)) { return $script:StabilityCache[$cacheKey] }
    $rows = New-Object System.Collections.Generic.List[object]
    $timeline = @(Get-CrashEvidenceTimelineRows -Target $Target -Days 30 -Max 600)
    $scores = @(Get-UniversalRootCauseScoreRows -Target $Target)
    $rank = 1
    function Add-Insight($Lane, $Status, $Count, $Latest, $Signal, $Interpretation, $NextAction) {
        [void]$rows.Add([pscustomobject]@{
            Rank           = $script:InsightRank
            Lane           = $Lane
            Status         = $Status
            Count          = $Count
            Latest         = $Latest
            Signal         = $Signal
            Interpretation = $Interpretation
            NextAction     = $NextAction
        })
        $script:InsightRank++
    }
    $script:InsightRank = 1

    foreach ($score in $scores | Select-Object -First 6) {
        Add-Insight 'Root Cause' $score.Confidence $score.Score '' $score.Cause $score.Evidence $score.NextAction
    }

    foreach ($group in $timeline | Group-Object Lane | Sort-Object Count -Descending) {
        $items = @($group.Group | Sort-Object Time -Descending)
        $highCount = @($items | Where-Object { $_.Severity -eq 'High' }).Count
        $status = if ($highCount -gt 0) { 'High' } elseif ($items.Count -ge 5) { 'Medium' } else { 'Info' }
        $latest = if ($items.Count) { $items[0].Time } else { '' }
        $signal = if ($items.Count) { $items[0].Signal } else { '' }
        $interpretation = switch ($group.Name) {
            'Crash' { 'Application crash fingerprints are the strongest local signal for whether a fix changed behavior.' }
            'GPU/TDR' { 'Display resets, WHEA, or GPU driver events near crashes point to the graphics driver/device path.' }
            'Security' { 'Security blocks/audits can stop writes or alter runtime behavior; verify trust before allowlisting anything.' }
            'Change' { 'Recent updates, drivers, and installs are correlation clues; isolate one variable at a time.' }
            'WER' { 'WER folders can contain the most support-useful crash bucket context.' }
            'Reliability' { 'Reliability Monitor confirms repeated app/system failure patterns.' }
            'FH6 Report' { 'FH6 local reports add build, GPU, and driver context around the crash.' }
            'User Data' { 'User-data changes help verify whether fresh-start tests actually changed the local state.' }
            default { 'Timeline evidence lane.' }
        }
        $next = switch ($group.Name) {
            'Crash' { 'Group by code/module, run one controlled test, and compare whether the top fingerprint persists.' }
            'GPU/TDR' { 'Use the generated WPR/DxDiag/GPU playbook, disable overlays/capture, and test a clean GPU-driver path.' }
            'Security' { 'Open the selected event detail, confirm the process/path, and test with audit/allowlist only if trusted.' }
            'Change' { 'Compare the latest crash anchor with driver/update/install timing; roll back or isolate a single change.' }
            'WER' { 'Export support package and preserve WER folders before they age out.' }
            default { 'Use the runbook below to pick the next low-risk step.' }
        }
        Add-Insight $group.Name $status $items.Count $latest $signal $interpretation $next
    }

    if ($rows.Count -eq 0) {
        Add-Insight 'Evidence' 'Info' 0 '' 'No evidence yet' 'No crash-adjacent evidence was found in the scanned windows.' 'Reproduce once, then run Stability Analyze or start Crash Watch.'
    }
    $script:InsightRank = $null
    $result = @($rows | Sort-Object Rank)
    $script:StabilityCache[$cacheKey] = $result
    return $result
}

function Get-CrashStabilityRunbookRows {
    param([string]$Target = '')
    $cacheKey = "StabilityRunbook|$Target"
    if ($script:StabilityCache.ContainsKey($cacheKey)) { return $script:StabilityCache[$cacheKey] }
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-RunStep($Step, $Phase, $Mode, $Action, $Why, $SuccessCheck, $Risk) {
        [void]$rows.Add([pscustomobject]@{
            Step         = $Step
            Phase        = $Phase
            Mode         = $Mode
            Action       = $Action
            Why          = $Why
            SuccessCheck = $SuccessCheck
            Risk         = $Risk
        })
    }

    $scores = @(Get-UniversalRootCauseScoreRows -Target $Target)
    $timeline = @(Get-CrashEvidenceTimelineRows -Target $Target -Days 30 -Max 400)
    $events = @($timeline | Where-Object { $_.Lane -eq 'Crash' })
    $gpu = @($timeline | Where-Object { $_.Lane -eq 'GPU/TDR' })
    $security = @($timeline | Where-Object { $_.Lane -eq 'Security' })
    $changes = @($timeline | Where-Object { $_.Lane -eq 'Change' })
    $dumps = @(Get-LocalDumpConfigRows -Target $(if ($Target) { $Target } else { $script:Config.ExeName }))
    $dumpConfigured = @($dumps | Where-Object { $_.Status -eq 'Configured' -and ($_.Target -eq $Target -or $_.Target -eq '<all apps>' -or ($Target -eq '' -and $_.Target -eq '<all apps>')) })
    $topScore = @($scores | Select-Object -First 1)
    $targetText = if ($Target) { $Target } else { '<all apps>' }
    $step = 1

    Add-RunStep $step 'Anchor Evidence' 'Read-only' 'Export Stability Workbench and build a support package immediately after a crash.' "Target=$targetText; timeline rows=$($timeline.Count); top score=$(if ($topScore.Count) { $topScore[0].Cause } else { 'none' })" 'A new export/support zip exists after the latest crash timestamp.' 'Low'
    $step++

    if ($events.Count -gt 0 -and $dumpConfigured.Count -eq 0) {
        Add-RunStep $step 'Capture Stronger Evidence' 'Manual/Admin' 'Use the generated LocalDumps or ProcDump commands before the next repro; do not enable broad dump capture blindly.' "$($events.Count) crash event(s) but no matching LocalDumps configuration was detected." 'A dump or WER artifact exists for the next crash, or the command is intentionally skipped.' 'Medium'
        $step++
    }

    if (@($scores | Where-Object { $_.Cause -match 'Overlay|hook|capture' -and $_.Score -ge 20 }).Count -gt 0) {
        Add-RunStep $step 'Clean Overlay Repro' 'Safe test' 'Stop overlay, capture, tuning, input-hook, and performance-monitor tools for one launch.' (@($scores | Where-Object { $_.Cause -match 'Overlay|hook|capture' } | Select-Object -First 1).Evidence) 'The same crash fingerprint disappears, changes module/code, or still reproduces without those processes.' 'Low'
        $step++
    }

    if ($gpu.Count -gt 0 -or @($scores | Where-Object { $_.Cause -match 'GPU' }).Count -gt 0) {
        Add-RunStep $step 'GPU Path' 'Manual' 'Collect DxDiag/WPR evidence, clean-install the GPU driver if needed, and test without capture/HAGS-style variables.' "$($gpu.Count) GPU/TDR timeline row(s); $(@($scores | Where-Object { $_.Cause -match 'GPU' } | Select-Object -First 1).Evidence)" 'GPU/TDR rows stop appearing near the app crash, or the crash code/module changes.' 'Medium'
        $step++
    }

    if (@($scores | Where-Object { $_.Cause -match 'Memory|runtime|Dependency' }).Count -gt 0) {
        Add-RunStep $step 'Runtime/Memory Path' 'Repair' 'Repair Visual C++/.NET/DirectX/media prerequisites and keep a before/after fingerprint comparison.' (@($scores | Where-Object { $_.Cause -match 'Memory|runtime|Dependency' } | Select-Object -First 1).Evidence) 'The top access-violation/dependency fingerprint stops repeating after repair.' 'Low'
        $step++
    }

    if ($security.Count -gt 0) {
        Add-RunStep $step 'Security Blocks' 'Review' 'Inspect Defender/ASR/Controlled Folder events; only allowlist trusted signed game/tool paths if a block is confirmed.' "$($security.Count) security event(s) in the evidence window." 'No new security block appears at launch/crash time.' 'Medium'
        $step++
    }

    if ($changes.Count -gt 0) {
        Add-RunStep $step 'Recent Change Isolation' 'One variable' 'Compare crashes against recent driver/update/software changes and isolate or roll back one suspect at a time.' "$($changes.Count) change row(s) near the crash anchor." 'A single isolated change alters or removes the crash fingerprint.' 'Medium'
        $step++
    }

    if ([string]::IsNullOrWhiteSpace($Target) -or $Target -match 'forzahorizon6|forza') {
        Add-RunStep $step 'FH6 Local State' 'Backup first' 'With Steam Cloud off, use Deep Fresh for save/cache/settings user-data only, then launch once.' 'FH6 target detected; this is useful only after evidence is captured and backups exist.' 'New local state is created and the crash either clears or repeats with the same fingerprint.' 'Medium'
        $step++
    }

    Add-RunStep $step 'Escalation Package' 'Read-only' 'If the fingerprint survives clean tests, export CrashScope, Stability, support package, DxDiag, and dump evidence for vendor/support escalation.' 'Stable fingerprints after controlled tests are stronger than repeated blind cleanup.' 'Package contains timeline, scores, WER, Reliability, GPU, security, and dump/config evidence.' 'Low'
    $result = @($rows | Sort-Object Step)
    $script:StabilityCache[$cacheKey] = $result
    return $result
}

function Get-CrashStabilityRunbookText {
    param([string]$Target = '')
    $cacheKey = "StabilityRunbookText|$Target"
    if ($script:StabilityCache.ContainsKey($cacheKey)) { return $script:StabilityCache[$cacheKey] }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Crash Stability Runbook')
    [void]$lines.Add('=======================')
    [void]$lines.Add("Target: $(if ($Target) { $Target } else { '<all apps>' })")
    [void]$lines.Add("Generated: $(Get-Date)")
    [void]$lines.Add('')
    [void]$lines.Add('Evidence insights:')
    foreach ($row in Get-CrashEvidenceInsightRows -Target $Target | Select-Object -First 10) {
        [void]$lines.Add("  [$($row.Status)] $($row.Lane): count=$($row.Count) latest=$($row.Latest)")
        [void]$lines.Add("    $($row.Interpretation)")
        [void]$lines.Add("    Next: $($row.NextAction)")
    }
    [void]$lines.Add('')
    [void]$lines.Add('Runbook steps:')
    foreach ($step in Get-CrashStabilityRunbookRows -Target $Target) {
        [void]$lines.Add("  $($step.Step). $($step.Phase) [$($step.Mode), risk=$($step.Risk)]")
        [void]$lines.Add("     Action: $($step.Action)")
        [void]$lines.Add("     Why: $($step.Why)")
        [void]$lines.Add("     Success check: $($step.SuccessCheck)")
    }
    [void]$lines.Add('')
    [void]$lines.Add('Safety boundary:')
    [void]$lines.Add('  This runbook is external triage. It does not modify game install files, inject into processes, automate gameplay, read/write game memory, or edit saves for advantage.')
    $result = ($lines -join [Environment]::NewLine)
    $script:StabilityCache[$cacheKey] = $result
    return $result
}

function Export-CrashStabilityWorkbench {
    param([string]$Target = '')
    New-ToolDirectory
    $safeTarget = if ([string]::IsNullOrWhiteSpace($Target)) { 'all-apps' } else { ConvertTo-SafeName -Text $Target }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $base = Join-Path $script:Config.UniversalRoot ("StabilityWorkbench_{0}_{1}" -f $safeTarget, $stamp)
    $timeline = @(Get-CrashEvidenceTimelineRows -Target $Target)
    $insights = @(Get-CrashEvidenceInsightRows -Target $Target)
    $runbook = @(Get-CrashStabilityRunbookRows -Target $Target)
    $timeline | Export-Csv -LiteralPath "$base.timeline.csv" -NoTypeInformation -Encoding UTF8
    $insights | Export-Csv -LiteralPath "$base.insights.csv" -NoTypeInformation -Encoding UTF8
    $runbook | Export-Csv -LiteralPath "$base.runbook.csv" -NoTypeInformation -Encoding UTF8
    [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('o')
        Target      = if ($Target) { $Target } else { '<all apps>' }
        Timeline    = $timeline
        Insights    = $insights
        Runbook     = $runbook
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$base.json" -Encoding UTF8
    Get-CrashStabilityRunbookText -Target $Target | Set-Content -LiteralPath "$base.txt" -Encoding UTF8
    return "$base.txt"
}

function Get-CrashSummary {
    $lines = New-Object System.Collections.Generic.List[string]
    $reports = @(Get-CrashReportRows)
    [void]$lines.Add("Local FH6 crash report folders: $($reports.Count)")
    foreach ($r in $reports | Select-Object -First 8) {
        [void]$lines.Add("  $($r.Name): build=$($r.Build) gpu=$($r.GPU) driver=$($r.Driver)")
    }
    $events = @(Get-CrashEventRows)
    [void]$lines.Add("Recent Windows FH6 crash events: $($events.Count)")
    foreach ($e in $events | Select-Object -First 8) {
        [void]$lines.Add("  $($e.Time): $($e.EventName) $($e.Code) module=$($e.Module)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-CrashSignatureAnalysis {
    $events = @(Get-CrashEventRows)
    $reports = @(Get-CrashReportRows)
    $wer = @(Get-WERReportRows)
    $conflicts = @(Get-ConflictProcesses)
    $lines = New-Object System.Collections.Generic.List[string]

    [void]$lines.Add('Crash Signature Analysis')
    [void]$lines.Add('========================')
    [void]$lines.Add("Crash events analyzed: $($events.Count)")
    [void]$lines.Add("Local FH6 pre-crash reports: $($reports.Count)")
    [void]$lines.Add("WER report folders: $($wer.Count)")
    [void]$lines.Add('')

    if ($events.Count -eq 0) {
        [void]$lines.Add('No recent FH6 crash events were found in the Windows Application log.')
        return ($lines -join [Environment]::NewLine)
    }

    [void]$lines.Add('Grouped signatures:')
    $groups = $events | Group-Object EventName, Code, Module | Sort-Object Count -Descending
    foreach ($g in $groups | Select-Object -First 10) {
        [void]$lines.Add("  Count=$($g.Count) Signature=$($g.Name)")
    }
    [void]$lines.Add('')

    $latest = $events[0]
    [void]$lines.Add("Latest crash: $($latest.Time) $($latest.EventName) $($latest.Code) module=$($latest.Module)")
    if ($reports.Count -gt 0) {
        [void]$lines.Add("Latest FH6 report: $($reports[0].Name) build=$($reports[0].Build) gpu=$($reports[0].GPU) driver=$($reports[0].Driver)")
    }
    if ($wer.Count -gt 0) {
        [void]$lines.Add("Latest WER folder: $($wer[0].Name) event=$($wer[0].EventType) bucket=$($wer[0].Bucket)")
    }
    [void]$lines.Add('')

    [void]$lines.Add('Interpretation:')
    $codes = @($events | Select-Object -ExpandProperty Code -Unique)
    $names = @($events | Select-Object -ExpandProperty EventName -Unique)
    if ($codes -contains '0xc0000005' -or $codes -contains 'c0000005') {
        [void]$lines.Add('  - Repeated 0xc0000005/c0000005 access-violation style crashes usually point away from simple save corruption after a clean save wipe.')
        [void]$lines.Add('  - The highest-value next checks are overlays/hook processes, graphics drivers, Visual C++ runtimes, Media Foundation, clean boot, and support-package evidence.')
    }
    if ($names -contains 'BEX64') {
        [void]$lines.Add('  - BEX64 appears in the crash history. Treat process injection, overlays, monitoring/capture tools, and exploit-protection interactions as prime suspects.')
    }
    if ($latest.Module -eq 'unknown' -or [string]::IsNullOrWhiteSpace($latest.Module)) {
        [void]$lines.Add('  - The faulting module is unknown, which makes external process conflicts and low-level runtime/driver issues more plausible than a single named DLL failure.')
    }
    if ($conflicts.Count -gt 0) {
        [void]$lines.Add("  - Possible conflict processes currently detected: $((@($conflicts | Select-Object -ExpandProperty ProcessName -Unique)) -join ', ').")
    }
    else {
        [void]$lines.Add('  - No common conflict processes are currently detected, but a clean boot is still useful if crashes continue.')
    }
    [void]$lines.Add('')
    [void]$lines.Add('Recommended expert sequence:')
    [void]$lines.Add('  1. Build a Support Package immediately after a crash.')
    [void]$lines.Add('  2. Stop detected overlay/hook/monitoring tools and retry.')
    [void]$lines.Add('  3. Use Deep Fresh Start with Steam Cloud off, then launch once.')
    [void]$lines.Add('  4. If unchanged, run a clean boot and retry with no capture/overlay/performance tools.')
    [void]$lines.Add('  5. Reinstall/repair Visual C++ redistributables and confirm Media Foundation files are present.')
    [void]$lines.Add('  6. Use Steam Verify Integrity from Steam UI if missing/corrupt install files are suspected.')

    return ($lines -join [Environment]::NewLine)
}

function Get-CrashFingerprintRows {
    $events = @(Get-CrashEventRows)
    if ($events.Count -eq 0) {
        return @([pscustomobject]@{
            Count        = 0
            FirstSeen    = ''
            LastSeen     = ''
            EventName    = '<none>'
            Code         = ''
            Module       = ''
            Interpretation = 'No FH6 crash events were found.'
        })
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $events | Group-Object EventName, Code, Module | Sort-Object Count -Descending | ForEach-Object {
        $groupRows = @($_.Group | Sort-Object Time)
        $eventName = [string]$groupRows[0].EventName
        $code = [string]$groupRows[0].Code
        $module = [string]$groupRows[0].Module
        $interpretation = if ($code -match '0xc0000005|c0000005' -or $eventName -match 'BEX') {
            'Access-violation/BEX pattern. Prioritize overlay/conflict isolation, graphics/runtime repair, clean boot, and evidence capture.'
        }
        elseif ($module -and $module -ne 'unknown') {
            "Named module pattern. Compare module with drivers/runtimes and recent installs."
        }
        else {
            'Generic crash pattern. Use timeline and session capture to narrow the trigger.'
        }
        [void]$rows.Add([pscustomobject]@{
            Count        = $_.Count
            FirstSeen    = $groupRows[0].Time
            LastSeen     = $groupRows[-1].Time
            EventName    = $eventName
            Code         = $code
            Module       = $module
            Interpretation = $interpretation
        })
    }
    return $rows.ToArray()
}

function Get-LatestCrashEvidenceItem {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($e in Get-CrashEventRows) {
        if ($e.Time) {
            [void]$items.Add([pscustomobject]@{
                Time   = [datetime]$e.Time
                Source = 'Windows crash event'
                Signal = "$($e.EventName) $($e.Code)"
                Detail = "Module=$($e.Module); Provider=$($e.Provider)"
                Path   = ''
            })
        }
    }
    foreach ($r in Get-CrashReportRows) {
        if ($r.Time) {
            [void]$items.Add([pscustomobject]@{
                Time   = [datetime]$r.Time
                Source = 'FH6 crash report'
                Signal = $r.Name
                Detail = "Build=$($r.Build); GPU=$($r.GPU); Driver=$($r.Driver)"
                Path   = $r.Path
            })
        }
    }
    foreach ($w in Get-WERReportRows) {
        if ($w.LastWriteTime) {
            [void]$items.Add([pscustomobject]@{
                Time   = [datetime]$w.LastWriteTime
                Source = 'Windows Error Reporting'
                Signal = if ($w.EventType) { $w.EventType } else { $w.Name }
                Detail = "Bucket=$($w.Bucket)"
                Path   = $w.Path
            })
        }
    }
    return @($items | Sort-Object Time -Descending | Select-Object -First 1)
}

function Get-LatestSupportPackageAfter {
    param([datetime]$After)
    if (-not (Test-Path -LiteralPath $script:Config.PackageRoot)) { return $null }
    $packages = @(Get-ChildItem -LiteralPath $script:Config.PackageRoot -File -Filter 'FH6_CompanionDoctor_Support_*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($package in $packages) {
        if ($package.LastWriteTime -ge $After) { return $package }
    }
    return $null
}

function Get-GuidedWorkflowRows {
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Step($Phase, $Priority, $State, $Action, $Evidence, $NextButton) {
        [void]$rows.Add([pscustomobject]@{
            Phase      = $Phase
            Priority   = $Priority
            State      = $State
            Action     = $Action
            Evidence   = $Evidence
            Button     = $NextButton
        })
    }

    $latest = @(Get-LatestCrashEvidenceItem | Select-Object -First 1)
    $latestTime = if ($latest.Count) { [datetime]$latest[0].Time } else { $null }
    $package = if ($latestTime) { Get-LatestSupportPackageAfter -After $latestTime } else { $null }
    if ($latestTime -and -not $package) {
        Add-Step 'Evidence' 1 'Ready' 'Build a support package immediately after the latest crash.' "$($latest[0].Source): $($latest[0].Signal) at $latestTime" 'Support Package'
    }
    elseif ($latestTime -and $package) {
        Add-Step 'Evidence' 4 'OK' 'Support evidence exists after the latest detected crash.' "$($package.Name) written $($package.LastWriteTime)" 'Open Packages'
    }
    else {
        Add-Step 'Evidence' 3 'Info' 'No recent FH6 crash evidence found; run a tracked launch if the issue reproduces.' 'No crash event/report/WER anchor.' 'Session Launch'
    }

    $conflicts = @(Get-ConflictProcesses)
    if ($conflicts.Count -gt 0) {
        Add-Step 'Isolation' 1 'Warn' 'Stop possible overlay/hook/monitor processes before the next FH6 launch.' (($conflicts | Select-Object -ExpandProperty ProcessName -Unique) -join ', ') 'Show Conflicts'
    }
    else {
        Add-Step 'Isolation' 3 'OK' 'No common conflict process is visible right now.' 'Clean boot is still useful if BEX64 continues.' 'Startup'
    }

    $gamingSettings = @(Get-WindowsGamingSettingRows)
    $captureRows = @($gamingSettings | Where-Object { $_.Area -in @('Game Bar','Capture') -and $_.Interpretation -match 'Enabled|active' })
    if ($captureRows.Count -gt 0) {
        Add-Step 'Capture Stack' 2 'Warn' 'Disable Windows Game Bar/capture for one clean repro attempt.' (($captureRows | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ') 'Platform Audit'
    }
    else {
        Add-Step 'Capture Stack' 4 'OK' 'No enabled Windows capture setting was detected by the audit.' 'Capture/Game Bar rows are not active.' 'Platform Audit'
    }

    $inventory = @(Get-FH6Inventory)
    $saveRows = @($inventory | Where-Object { $_.Exists -and $_.Cleanable -and $_.Category -eq 'Save' })
    $cacheRows = @($inventory | Where-Object { $_.Exists -and $_.Cleanable -and $_.Category -eq 'Cache/Settings' })
    if ($saveRows.Count -gt 0 -or $cacheRows.Count -gt 0) {
        Add-Step 'User Data' 2 'Ready' 'With Steam Cloud off, use Deep Fresh for a clean local save/cache test.' "$($saveRows.Count) save root(s), $($cacheRows.Count) cache/settings root(s)." 'Deep Fresh'
    }
    else {
        Add-Step 'User Data' 4 'OK' 'No existing cleanable save/cache roots were found.' 'Fresh local data may already be cleared.' 'Scan Saves'
    }

    $runtimeWarnings = New-Object System.Collections.Generic.List[string]
    $mf = Get-MediaFoundationStatus
    if ($mf.Status -ne 'OK') { [void]$runtimeWarnings.Add("Media Foundation: $($mf.Detail)") }
    $redists = @(Get-VisualCRedistRows)
    $hasModernRedist = @($redists | Where-Object {
        $_.Name -match '2015-2022|2015.*2022|2017|2019|2022|v14' -or
        ($_.Version -and ([version]$_.Version -ge [version]'14.0.0.0'))
    }).Count -gt 0
    if (-not $hasModernRedist) { [void]$runtimeWarnings.Add('Modern Visual C++ Redistributable not detected.') }
    if ($runtimeWarnings.Count -gt 0) {
        Add-Step 'Runtime' 1 'Warn' 'Repair Windows media/runtime prerequisites before repeating crash-loop tests.' ($runtimeWarnings -join '; ') 'Runtimes'
    }
    else {
        Add-Step 'Runtime' 4 'OK' 'Media Foundation and modern Visual C++ redists are present.' "$($redists.Count) Visual C++ entries found." 'Runtimes'
    }

    $fingerprints = @(Get-CrashFingerprintRows | Where-Object { $_.Count -gt 0 })
    if ($fingerprints.Count -gt 0) {
        $top = $fingerprints[0]
        Add-Step 'Crash Fingerprint' 1 'Warn' 'Track whether the same signature survives each change.' "$($top.Count)x $($top.EventName) $($top.Code) module=$($top.Module)" 'Fingerprints'
    }

    Add-Step 'Escalation' 3 'Ready' 'If the same fingerprint remains after isolation and fresh local data, export a redacted summary for support.' 'Keeps private paths reduced while preserving crash pattern and environment evidence.' 'Redacted Summary'
    return @($rows | Sort-Object Priority, Phase)
}

function Get-GuidedWorkflowSummary {
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('FH6 Guided Fix Workflow')
    [void]$lines.Add('=======================')
    foreach ($step in Get-GuidedWorkflowRows) {
        [void]$lines.Add("[P$($step.Priority)] $($step.Phase) [$($step.State)]")
        [void]$lines.Add("  Action: $($step.Action)")
        [void]$lines.Add("  Evidence: $($step.Evidence)")
        [void]$lines.Add("  Tool button: $($step.Button)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-EventTimelineRows {
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($e in Get-CrashEventRows) {
        [void]$rows.Add([pscustomobject]@{
            Time     = $e.Time
            Type     = 'Crash Event'
            Signal   = "$($e.EventName) $($e.Code)"
            Detail   = "Provider=$($e.Provider); Module=$($e.Module)"
            Path     = ''
        })
    }

    foreach ($r in Get-CrashReportRows) {
        [void]$rows.Add([pscustomobject]@{
            Time     = $r.Time
            Type     = 'FH6 Crash Report'
            Signal   = $r.Name
            Detail   = "Build=$($r.Build); Driver=$($r.Driver); GPU=$($r.GPU)"
            Path     = $r.Path
        })
    }

    foreach ($w in Get-WERReportRows) {
        [void]$rows.Add([pscustomobject]@{
            Time     = $w.LastWriteTime
            Type     = 'WER'
            Signal   = if ($w.EventType) { $w.EventType } else { $w.Name }
            Detail   = "Bucket=$($w.Bucket)"
            Path     = $w.Path
        })
    }

    foreach ($i in Get-FH6Inventory | Where-Object { $_.LastWriteTime }) {
        [void]$rows.Add([pscustomobject]@{
            Time     = $i.LastWriteTime
            Type     = $i.Category
            Signal   = $i.Risk
            Detail   = "$($i.SizeMB) MB; $($i.Items) item(s); $($i.Description)"
            Path     = $i.Path
        })
    }

    $steamLogPaths = @(Get-SteamLogRows | Select-Object -ExpandProperty Path -Unique)
    foreach ($path in $steamLogPaths) {
        if (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) {
            $item = Get-Item -LiteralPath $path -Force
            [void]$rows.Add([pscustomobject]@{
                Time     = $item.LastWriteTime
                Type     = 'Steam Log'
                Signal   = (Split-Path -Path $path -Leaf)
                Detail   = 'FH6/app/cloud/content match present in this log.'
                Path     = $path
            })
        }
    }

    return @($rows | Sort-Object Time -Descending)
}

function Get-EventTimelineSummary {
    $rows = @(Get-EventTimelineRows | Select-Object -First 60)
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('FH6 Event Timeline')
    [void]$lines.Add('==================')
    if ($rows.Count -eq 0) {
        [void]$lines.Add('No timeline rows found.')
        return ($lines -join [Environment]::NewLine)
    }
    foreach ($row in $rows) {
        $timeText = if ($row.Time) { ([datetime]$row.Time).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ') } else { '' }
        [void]$lines.Add(("{0} | {1} | {2} | {3}" -f $timeText, $row.Type, $row.Signal, $row.Detail))
        if ($row.Path) { [void]$lines.Add("  $($row.Path)") }
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-LatestFH6CrashTime {
    $times = @()
    $events = @(Get-CrashEventRows)
    if ($events.Count -gt 0 -and $events[0].Time) { $times += [datetime]$events[0].Time }
    $reports = @(Get-CrashReportRows)
    if ($reports.Count -gt 0 -and $reports[0].Time) { $times += [datetime]$reports[0].Time }
    $wer = @(Get-WERReportRows)
    if ($wer.Count -gt 0 -and $wer[0].LastWriteTime) { $times += [datetime]$wer[0].LastWriteTime }
    if ($times.Count -eq 0) { return $null }
    return @($times | Sort-Object -Descending | Select-Object -First 1)[0]
}

function Get-CrashCorrelationRows {
    param([int]$Minutes = 10)
    $latest = Get-LatestFH6CrashTime
    if (-not $latest) { return @() }
    $start = $latest.AddMinutes(-1 * [math]::Abs($Minutes))
    $end = $latest.AddMinutes([math]::Abs($Minutes))
    @(Get-EventTimelineRows | Where-Object {
        $_.Time -and ([datetime]$_.Time -ge $start) -and ([datetime]$_.Time -le $end)
    } | Sort-Object Time -Descending)
}

function Get-CrashCorrelationSummary {
    param([int]$Minutes = 10)
    $latest = Get-LatestFH6CrashTime
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Latest Crash Correlation Window')
    [void]$lines.Add('===============================')
    if (-not $latest) {
        [void]$lines.Add('No FH6 crash time was available for correlation.')
        return ($lines -join [Environment]::NewLine)
    }
    [void]$lines.Add("Anchor: $($latest.ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$lines.Add("Window: +/- $Minutes minute(s)")
    [void]$lines.Add('')
    $rows = @(Get-CrashCorrelationRows -Minutes $Minutes)
    if ($rows.Count -eq 0) {
        [void]$lines.Add('No timeline rows fell inside the window.')
        return ($lines -join [Environment]::NewLine)
    }
    foreach ($row in $rows) {
        $delta = [math]::Round((([datetime]$row.Time) - $latest).TotalSeconds, 1)
        [void]$lines.Add(("{0} ({1}s) | {2} | {3} | {4}" -f ([datetime]$row.Time).ToString('yyyy-MM-dd HH:mm:ss'), $delta, $row.Type, $row.Signal, $row.Detail))
        if ($row.Path) { [void]$lines.Add("  $($row.Path)") }
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-DriverInventoryRows {
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
            $_.DeviceClass -match 'DISPLAY|HIDCLASS|USB|MEDIA|SYSTEM' -or
            $_.DeviceName -match 'NVIDIA|Intel|AMD|Logitech|Thrustmaster|Fanatec|MOZA|Xbox|Controller|Wheel|USB'
        } | Sort-Object DeviceClass, DeviceName | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{
                DeviceName    = $_.DeviceName
                DeviceClass   = $_.DeviceClass
                Manufacturer  = $_.Manufacturer
                DriverVersion = $_.DriverVersion
                DriverDate    = $_.DriverDate
                InfName       = $_.InfName
                IsSigned      = $_.IsSigned
            })
        }
    }
    catch {}
    return $rows.ToArray()
}

function Get-InstallAuditRows {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($install in Get-SteamInstallInfo) {
        [void]$rows.Add([pscustomobject]@{ Check = 'Steam library'; Status = 'Info'; Value = $install.Library; Path = $install.Library })
        [void]$rows.Add([pscustomobject]@{ Check = 'Library path length'; Status = if ($install.LibraryLength -le 59) { 'OK' } else { 'Warn' }; Value = "$($install.LibraryLength) chars"; Path = $install.Library })
        [void]$rows.Add([pscustomobject]@{ Check = 'Manifest'; Status = if (Test-Path -LiteralPath $install.Manifest) { 'OK' } else { 'Warn' }; Value = "StateFlags=$($install.StateFlags); SizeOnDisk=$($install.SizeOnDisk); LastUpdated=$($install.LastUpdated)"; Path = $install.Manifest })
        [void]$rows.Add([pscustomobject]@{ Check = 'Executable exists'; Status = if ($install.ExeExists) { 'OK' } else { 'Warn' }; Value = $install.ExeExists; Path = $install.Exe })
        if ($install.ExeExists) {
            try {
                $exe = Get-Item -LiteralPath $install.Exe -Force
                $version = $exe.VersionInfo.FileVersion
                $sig = Get-AuthenticodeSignature -LiteralPath $install.Exe -ErrorAction SilentlyContinue
                [void]$rows.Add([pscustomobject]@{ Check = 'Executable version'; Status = 'Info'; Value = $version; Path = $install.Exe })
                [void]$rows.Add([pscustomobject]@{ Check = 'Executable signature'; Status = if ($sig.Status -eq 'Valid') { 'OK' } else { 'Info' }; Value = "$($sig.Status) $($sig.SignerCertificate.Subject)"; Path = $install.Exe })
                [void]$rows.Add([pscustomobject]@{ Check = 'Executable timestamp'; Status = 'Info'; Value = $exe.LastWriteTime; Path = $install.Exe })
            }
            catch {
                [void]$rows.Add([pscustomobject]@{ Check = 'Executable metadata'; Status = 'Warn'; Value = $_.Exception.Message; Path = $install.Exe })
            }
        }
        if (Test-Path -LiteralPath $install.InstallDir) {
            try {
                $top = @(Get-ChildItem -LiteralPath $install.InstallDir -Force -ErrorAction Stop)
                [void]$rows.Add([pscustomobject]@{ Check = 'Top-level install items'; Status = 'Info'; Value = $top.Count; Path = $install.InstallDir })
                foreach ($item in $top | Sort-Object LastWriteTime -Descending | Select-Object -First 12) {
                    [void]$rows.Add([pscustomobject]@{ Check = 'Recent top-level install item'; Status = 'Read-only'; Value = "$($item.LastWriteTime) $($item.Name)"; Path = $item.FullName })
                }
            }
            catch {
                [void]$rows.Add([pscustomobject]@{ Check = 'Install folder listing'; Status = 'Warn'; Value = $_.Exception.Message; Path = $install.InstallDir })
            }
        }
    }
    if ($rows.Count -eq 0) {
        [void]$rows.Add([pscustomobject]@{ Check = 'Steam install detection'; Status = 'Warn'; Value = 'No Steam FH6 manifest was detected.'; Path = '' })
    }
    return $rows.ToArray()
}

function Test-TelemetryPortAvailability {
    param([int]$Port = 5606)
    $result = [pscustomobject]@{
        Port       = $Port
        Status     = 'Unknown'
        Detail     = ''
        ActiveRows = @()
    }
    try {
        $active = @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)
        $result.ActiveRows = $active
        if ($active.Count -gt 0) {
            $owners = @()
            foreach ($row in $active) {
                $procName = ''
                try { $procName = (Get-Process -Id $row.OwningProcess -ErrorAction SilentlyContinue).ProcessName } catch {}
                $owners += "PID=$($row.OwningProcess) $procName Local=$($row.LocalAddress):$($row.LocalPort)"
            }
            $result.Status = 'Busy'
            $result.Detail = $owners -join '; '
        }
        else {
            $client = New-Object System.Net.Sockets.UdpClient($Port)
            $client.Close()
            $result.Status = 'Available'
            $result.Detail = 'Port can be bound by the telemetry listener.'
        }
    }
    catch {
        $result.Status = 'Warn'
        $result.Detail = $_.Exception.Message
    }
    return $result
}

function Get-TelemetryPreflightSummary {
    param([int]$Port = 5606)
    $portStatus = Test-TelemetryPortAvailability -Port $Port
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('FH6 Data Out Telemetry Preflight')
    [void]$lines.Add('================================')
    [void]$lines.Add("IP: 127.0.0.1")
    [void]$lines.Add("Port: $Port")
    [void]$lines.Add("Port status: $($portStatus.Status)")
    [void]$lines.Add("Detail: $($portStatus.Detail)")
    [void]$lines.Add('')
    [void]$lines.Add('In FH6 set:')
    [void]$lines.Add('  Settings > HUD and Gameplay > Data Out: On')
    [void]$lines.Add('  Data Out IP Address: 127.0.0.1')
    [void]$lines.Add("  Data Out IP Port: $Port")
    [void]$lines.Add('')
    [void]$lines.Add('The tool only listens. It sends no data back to FH6.')
    return ($lines -join [Environment]::NewLine)
}

function Get-RegistryValueSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch {
        return $null
    }
}

function Get-WindowsGamingSettingRows {
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Setting($Area, $Name, $Path, $ValueName, $Interpretation) {
        $value = Get-RegistryValueSafe -Path $Path -Name $ValueName
        [void]$rows.Add([pscustomobject]@{
            Area           = $Area
            Name           = $Name
            Value          = if ($null -eq $value) { '<missing>' } else { [string]$value }
            Interpretation = (& $Interpretation $value)
            Path           = "$Path\$ValueName"
        })
    }

    Add-Setting 'Game Mode' 'Auto Game Mode' 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' {
        param($v) if ($null -eq $v) { 'Missing; Windows default applies.' } elseif ([int]$v -eq 1) { 'Enabled.' } else { 'Disabled.' }
    }
    Add-Setting 'Game Bar' 'Game Bar startup panel' 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' {
        param($v) if ($null -eq $v) { 'Missing.' } elseif ([int]$v -eq 1) { 'Enabled; overlay UI may appear.' } else { 'Disabled.' }
    }
    Add-Setting 'Capture' 'App capture' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' {
        param($v) if ($null -eq $v) { 'Missing.' } elseif ([int]$v -eq 1) { 'Enabled; capture stack may be active.' } else { 'Disabled.' }
    }
    Add-Setting 'Capture' 'GameDVR enabled' 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' {
        param($v) if ($null -eq $v) { 'Missing.' } elseif ([int]$v -eq 1) { 'Enabled; consider disabling during crash tests.' } else { 'Disabled.' }
    }
    Add-Setting 'Graphics' 'Hardware accelerated GPU scheduling' 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' {
        param($v)
        if ($null -eq $v) { 'Missing/default.' }
        elseif ([int]$v -eq 2) { 'Enabled.' }
        elseif ([int]$v -eq 1) { 'Disabled.' }
        else { "Unknown value $v." }
    }
    Add-Setting 'Display' 'MPO overlay test mode' 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' {
        param($v) if ($null -eq $v) { 'Missing/default.' } else { "Custom value $v present." }
    }
    return $rows.ToArray()
}

function Get-PowerThermalRows {
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $active = (& powercfg /getactivescheme) 2>$null
        [void]$rows.Add([pscustomobject]@{ Area = 'Power'; Name = 'Active scheme'; Value = ($active -join ' ').Trim(); Detail = 'Use High performance/Best performance for crash repro tests on laptops.' })
    }
    catch {
        [void]$rows.Add([pscustomobject]@{ Area = 'Power'; Name = 'Active scheme'; Value = $_.Exception.Message; Detail = 'powercfg unavailable.' })
    }
    try {
        Get-CimInstance Win32_Battery -ErrorAction Stop | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{ Area = 'Power'; Name = 'Battery'; Value = "Status=$($_.BatteryStatus); Charge=$($_.EstimatedChargeRemaining)%"; Detail = 'Prefer AC power for FH6 crash testing.' })
        }
    }
    catch {
        [void]$rows.Add([pscustomobject]@{ Area = 'Power'; Name = 'Battery'; Value = 'No battery data or desktop system.'; Detail = '' })
    }
    try {
        Get-CimInstance Win32_Processor -ErrorAction Stop | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{ Area = 'CPU'; Name = $_.Name; Value = "Cores=$($_.NumberOfCores); Logical=$($_.NumberOfLogicalProcessors); MaxMHz=$($_.MaxClockSpeed)"; Detail = 'Read-only CPU inventory.' })
        }
    }
    catch {}
    return $rows.ToArray()
}

function Get-XboxAppPackageRows {
    $packageNames = @(
        'Microsoft.GamingServices',
        'Microsoft.GamingApp',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.WindowsStore',
        'Microsoft.StorePurchaseApp'
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($name in $packageNames) {
        try {
            $pkgs = @(Get-AppxPackage -Name $name -ErrorAction Stop)
            if ($pkgs.Count -eq 0) {
                [void]$rows.Add([pscustomobject]@{ Name = $name; Status = 'Not found'; Version = ''; PackageFullName = ''; InstallLocation = '' })
            }
            foreach ($pkg in $pkgs) {
                [void]$rows.Add([pscustomobject]@{
                    Name            = $pkg.Name
                    Status          = 'Installed'
                    Version         = $pkg.Version.ToString()
                    PackageFullName = $pkg.PackageFullName
                    InstallLocation = $pkg.InstallLocation
                })
            }
        }
        catch {
            [void]$rows.Add([pscustomobject]@{ Name = $name; Status = 'Unavailable'; Version = ''; PackageFullName = $_.Exception.Message; InstallLocation = '' })
        }
    }
    return $rows.ToArray()
}

function Test-CompanionWritablePath {
    param([Parameter(Mandatory)][string]$Path)
    $full = Get-FullPathSafe -Path $Path
    if ($full -match '\\steamapps\\common\\ForzaHorizon6(\\|$)') {
        return [pscustomobject]@{ Path = $Path; Exists = Test-Path -LiteralPath $Path; Status = 'Skipped'; Detail = 'Never write-test the game install.' }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Path = $Path; Exists = $false; Status = 'Missing'; Detail = 'Path does not exist.' }
    }
    $probe = Join-Path $Path ("fh6_companion_probe_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    try {
        'FH6 Companion Doctor write probe' | Set-Content -LiteralPath $probe -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Path = $Path; Exists = $true; Status = 'OK'; Detail = 'Temporary probe file created and removed.' }
    }
    catch {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Path = $Path; Exists = $true; Status = 'Warn'; Detail = $_.Exception.Message }
    }
}

function Get-PathPermissionRows {
    $paths = @(
        $script:Config.LocalRoot,
        $script:Config.SharedRoot,
        $script:Config.XboxPgsRoot,
        $script:Config.BackupRoot,
        $script:Config.ReportRoot,
        $script:Config.SnapshotRoot,
        $script:Config.SessionRoot,
        $script:Config.TelemetryRoot
    ) | Where-Object { $_ } | Select-Object -Unique
    @($paths | ForEach-Object { Test-CompanionWritablePath -Path $_ })
}

function Get-BackupIntegrityRows {
    New-ToolDirectory
    $rows = New-Object System.Collections.Generic.List[object]
    $zips = @(Get-ChildItem -LiteralPath $script:Config.BackupRoot -File -Filter '*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 30)
    if ($zips.Count -eq 0) {
        [void]$rows.Add([pscustomobject]@{ Name = '<none>'; Status = 'Info'; Entries = 0; SizeMB = 0; Path = $script:Config.BackupRoot; Detail = 'No backup zips found yet.' })
        return $rows.ToArray()
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    foreach ($zip in $zips) {
        $archive = $null
        try {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
            $manifest = @($archive.Entries | Where-Object { $_.FullName -eq 'manifest.json' })
            [void]$rows.Add([pscustomobject]@{
                Name    = $zip.Name
                Status  = if ($manifest.Count -gt 0) { 'OK' } else { 'Warn' }
                Entries = $archive.Entries.Count
                SizeMB  = [math]::Round(($zip.Length / 1MB), 2)
                Path    = $zip.FullName
                Detail  = if ($manifest.Count -gt 0) { 'Manifest present.' } else { 'manifest.json missing; restore may be unsafe.' }
            })
        }
        catch {
            [void]$rows.Add([pscustomobject]@{ Name = $zip.Name; Status = 'Warn'; Entries = 0; SizeMB = [math]::Round(($zip.Length / 1MB), 2); Path = $zip.FullName; Detail = $_.Exception.Message })
        }
        finally {
            if ($archive) { $archive.Dispose() }
        }
    }
    return $rows.ToArray()
}

function Get-ReliabilityRecordRows {
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        Get-CimInstance -ClassName Win32_ReliabilityRecords -ErrorAction Stop | Where-Object {
            $_.Message -match 'forzahorizon6|Forza Horizon 6|ForzaHorizon6' -or
            $_.ProductName -match 'forzahorizon6|Forza Horizon 6|ForzaHorizon6' -or
            $_.SourceName -match 'forzahorizon6|Forza Horizon 6|ForzaHorizon6'
        } | Sort-Object TimeGenerated -Descending | Select-Object -First 60 | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{
                TimeGenerated = $_.TimeGenerated
                SourceName    = $_.SourceName
                ProductName   = $_.ProductName
                EventId       = $_.EventIdentifier
                Message       = $_.Message
            })
        }
    }
    catch {
        [void]$rows.Add([pscustomobject]@{
            TimeGenerated = $null
            SourceName    = 'Unavailable'
            ProductName   = ''
            EventId       = ''
            Message       = $_.Exception.Message
        })
    }
    return $rows.ToArray()
}

function Get-DisplayTopologyRows {
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{
                Type        = 'GPU'
                Name        = $_.Name
                Detail      = "Mode=$($_.VideoModeDescription); Refresh=$($_.CurrentRefreshRate); RAM=$([math]::Round(($_.AdapterRAM / 1GB), 2)) GB"
                Driver      = $_.DriverVersion
                Status      = $_.Status
            })
        }
    }
    catch {}
    try {
        Get-CimInstance Win32_DesktopMonitor -ErrorAction Stop | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{
                Type        = 'Monitor'
                Name        = $_.Name
                Detail      = "Width=$($_.ScreenWidth); Height=$($_.ScreenHeight); PNP=$($_.PNPDeviceID)"
                Driver      = ''
                Status      = $_.Status
            })
        }
    }
    catch {}
    return $rows.ToArray()
}

function Get-GraphicsPreferenceRows {
    $rows = New-Object System.Collections.Generic.List[object]
    $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    try {
        $props = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        foreach ($prop in $props.PSObject.Properties) {
            if ($prop.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
            if ($prop.Name -match 'ForzaHorizon6|forzahorizon6|Forza Horizon 6|steamapps|2483190') {
                [void]$rows.Add([pscustomobject]@{
                    AppPath = $prop.Name
                    Value   = [string]$prop.Value
                    Source  = $path
                })
            }
        }
    }
    catch {}
    if ($rows.Count -eq 0) {
        [void]$rows.Add([pscustomobject]@{ AppPath = '<none>'; Value = 'No FH6-specific Windows graphics preference found.'; Source = $path })
    }
    return $rows.ToArray()
}

function Get-AppCompatLayerRows {
    $rows = New-Object System.Collections.Generic.List[object]
    $paths = @(
        'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers',
        'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    )
    foreach ($path in $paths) {
        try {
            $props = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
                if ($prop.Name -match 'ForzaHorizon6|forzahorizon6|Forza Horizon 6') {
                    [void]$rows.Add([pscustomobject]@{
                        AppPath = $prop.Name
                        Flags   = [string]$prop.Value
                        Source  = $path
                    })
                }
            }
        }
        catch {}
    }
    if ($rows.Count -eq 0) {
        [void]$rows.Add([pscustomobject]@{ AppPath = '<none>'; Flags = 'No FH6-specific compatibility layer flags found.'; Source = 'AppCompatFlags\Layers' })
    }
    return $rows.ToArray()
}

function Get-SecurityProductRows {
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction Stop | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{
                Type              = 'Antivirus'
                DisplayName       = $_.displayName
                ProductState      = $_.productState
                PathToSignedProductExe = $_.pathToSignedProductExe
                PathToSignedReportingExe = $_.pathToSignedReportingExe
            })
        }
    }
    catch {
        [void]$rows.Add([pscustomobject]@{
            Type              = 'Antivirus'
            DisplayName       = 'Unavailable'
            ProductState      = ''
            PathToSignedProductExe = $_.Exception.Message
            PathToSignedReportingExe = ''
        })
    }
    return $rows.ToArray()
}

function Get-OfficialReferenceRows {
    @(
        [pscustomobject]@{
            Area = 'Official PC crash guide'
            Url  = 'https://support.forza.net/hc/en-us/articles/360007593074-My-Game-is-Not-Launching-or-is-Crashing-on-PC'
            Why  = 'Forza Support crash guide covering Gaming Services, drivers, clean boot, overlays, software conflicts, power settings, Game Mode, and support steps.'
        },
        [pscustomobject]@{
            Area = 'FH6 crash error codes'
            Url  = 'https://support.forza.net/hc/en-us/articles/51642089902739-Forza-Horizon-6-PC-Crash-Error-Codes'
            Why  = 'Official FH6 PC crash code reference.'
        },
        [pscustomobject]@{
            Area = 'FH6 Data Out'
            Url  = 'https://support.forza.net/hc/en-us/articles/51744149102611-Forza-Horizon-6-Data-Out-Documentation'
            Why  = 'Official one-way UDP telemetry format used by the Telemetry tab.'
        },
        [pscustomobject]@{
            Area = 'FH6 Steam install troubleshooting'
            Url  = 'https://support.forza.net/hc/en-us/articles/51673672925459-FH6-Steam-Installation-Troubleshooting'
            Why  = 'Official Steam install/path troubleshooting reference.'
        },
        [pscustomobject]@{
            Area = 'FH6 known issues'
            Url  = 'https://support.forza.net/hc/en-us/articles/51701860097811-Forza-Horizon-6-Known-Issues'
            Why  = 'Known-issues page for comparing current crash/device behavior.'
        },
        [pscustomobject]@{
            Area = 'FH6 wheels/devices'
            Url  = 'https://support.forza.net/hc/en-us/articles/51674028831251-FH6-Supported-Wheels-and-Devices'
            Why  = 'Device and wheel support reference used by the Devices tab guidance.'
        },
        [pscustomobject]@{
            Area = 'Forza Code of Conduct'
            Url  = 'https://support.forza.net/hc/en-us/articles/360035563914-Forza-Code-of-Conduct'
            Why  = 'Boundary reference: this tool avoids cheating, memory editing, file tampering, automation, trainers, and unlock/save manipulation.'
        },
        [pscustomobject]@{
            Area = 'Windows application crash troubleshooting'
            Url  = 'https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-application-service-crashing-behavior'
            Why  = 'Microsoft guidance for Event ID 1000/1001 crash evidence and dump collection.'
        },
        [pscustomobject]@{
            Area = 'Windows Error Reporting LocalDumps'
            Url  = 'https://learn.microsoft.com/en-us/windows/win32/wer/collecting-user-mode-dumps'
            Why  = 'Official per-application dump configuration used by CrashScope command playbooks.'
        },
        [pscustomobject]@{
            Area = 'Sysinternals ProcDump'
            Url  = 'https://learn.microsoft.com/en-us/sysinternals/downloads/procdump'
            Why  = 'Microsoft Sysinternals utility for crash/hang dump capture when Event Viewer evidence is not enough.'
        },
        [pscustomobject]@{
            Area = 'Windows Performance Recorder and WPA'
            Url  = 'https://learn.microsoft.com/en-us/troubleshoot/windows-server/support-tools/support-tools-xperf-wpa-wpr'
            Why  = 'Official ETW recording workflow for system, driver, GPU, performance, and timing context.'
        },
        [pscustomobject]@{
            Area = 'Event Tracing for Windows'
            Url  = 'https://learn.microsoft.com/en-us/windows-hardware/test/wpt/event-tracing-for-windows'
            Why  = 'Core Windows tracing layer used by WPR/WPA for advanced system diagnosis.'
        },
        [pscustomobject]@{
            Area = 'DirectX Diagnostic Tool'
            Url  = 'https://support.microsoft.com/en-us/windows/open-and-run-dxdiag-exe-dad7792c-2ad5-f6cd-5a37-bf92228dfd85'
            Why  = 'Microsoft support reference for DxDiag hardware/driver diagnostics.'
        },
        [pscustomobject]@{
            Area = 'System File Checker'
            Url  = 'https://support.microsoft.com/en-us/windows/using-system-file-checker-in-windows-365e0031-36b1-6031-f804-8fd86e0ef4ca'
            Why  = 'Microsoft guidance for DISM/SFC repair flow when crashes affect multiple unrelated games or apps.'
        },
        [pscustomobject]@{
            Area = 'Game Bar known issues'
            Url  = 'https://learn.microsoft.com/en-us/gaming/game-bar/known-issues'
            Why  = 'Microsoft Game Bar/capture limitations relevant to overlay and capture-stack crash isolation.'
        },
        [pscustomobject]@{
            Area = 'Defender attack surface reduction events'
            Url  = 'https://learn.microsoft.com/en-us/defender-endpoint/attack-surface-reduction-windows-events'
            Why  = 'Official event IDs and log paths for ASR and Controlled Folder Access block/audit events used by the Stability timeline.'
        },
        [pscustomobject]@{
            Area = 'Controlled Folder Access'
            Url  = 'https://learn.microsoft.com/en-us/defender-endpoint/enable-controlled-folders'
            Why  = 'Microsoft Defender guidance for Controlled Folder Access behavior, audit mode, and event log review.'
        },
        [pscustomobject]@{
            Area = 'NVIDIA clean driver install'
            Url  = 'https://nvidia.custhelp.com/app/answers/detail/a_id/10/'
            Why  = 'Official NVIDIA clean driver installation guidance for GPU-driver crash isolation.'
        },
        [pscustomobject]@{
            Area = 'Windows GPU TDR'
            Url  = 'https://learn.microsoft.com/en-us/windows-hardware/drivers/display/timeout-detection-and-recovery'
            Why  = 'Microsoft WDDM Timeout Detection and Recovery reference for GPU hangs, resets, and device-removed style crash patterns.'
        },
        [pscustomobject]@{
            Area = 'Reliability Monitor records'
            Url  = 'https://learn.microsoft.com/en-us/previous-versions/windows/desktop/racwmiprov/win32-reliabilityrecords'
            Why  = 'WMI class used by Crash Intel to correlate Windows Reliability Monitor failures.'
        },
        [pscustomobject]@{
            Area = 'Application Verifier'
            Url  = 'https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/application-verifier-testing-applications'
            Why  = 'Advanced runtime verification concept. This tool does not enable it automatically, especially for games or protected processes.'
        },
        [pscustomobject]@{
            Area = 'GFlags and PageHeap'
            Url  = 'https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/gflags-and-pageheap'
            Why  = 'Advanced heap verification concept for developer-grade memory fault investigations; the tool documents but does not silently enable it.'
        },
        [pscustomobject]@{
            Area = 'Debug Diagnostic Tool'
            Url  = 'https://www.microsoft.com/en-us/download/details.aspx?id=103453'
            Why  = 'Microsoft DebugDiag is another user-mode crash/hang analysis option for advanced support workflows.'
        }
    )
}

function Get-ToolFileRows {
    $files = @(
        (Join-Path $script:Config.Downloads 'FH6-CompanionDoctor.ps1'),
        (Join-Path $script:Config.Downloads 'Run-FH6-CompanionDoctor.cmd'),
        (Join-Path $script:Config.Downloads 'FH6-CompanionDoctor-README.txt'),
        (Join-Path $script:Config.Downloads 'FH6-SaveDoctor.ps1'),
        (Join-Path $script:Config.Downloads 'Run-FH6-SaveDoctor.cmd'),
        (Join-Path $script:Config.Downloads 'FH6-SaveDoctor-README.txt')
    ) | Select-Object -Unique
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        if (Test-Path -LiteralPath $file) {
            $item = Get-Item -LiteralPath $file -Force
            $hash = Get-FileHash -LiteralPath $file -Algorithm SHA256
            [void]$rows.Add([pscustomobject]@{
                Name          = $item.Name
                Path          = $item.FullName
                Length        = $item.Length
                LastWriteTime = $item.LastWriteTime
                SHA256        = $hash.Hash
            })
        }
    }
    return $rows.ToArray()
}

function Get-ToolSafetyAuditRows {
    $rows = New-Object System.Collections.Generic.List[object]
    $scriptPath = Join-Path $script:Config.Downloads 'FH6-CompanionDoctor.ps1'
    $source = if (Test-Path -LiteralPath $scriptPath) { Get-Content -LiteralPath $scriptPath -Raw } else { '' }
    $forbiddenPatterns = @(
        '\bWriteProcessMemory\s*\(',
        '\bReadProcessMemory\s*\(',
        '\bOpenProcess\s*\(',
        '\bCreateRemoteThread\s*\(',
        '\bSetWindowsHookEx\s*\(',
        '\bSendInput\s*\(',
        '\bkeybd_event\s*\(',
        '\bmouse_event\s*\(',
        '\bVirtualAllocEx\s*\(',
        'ForzaHorizon6\\forzahorizon6.exe.*Remove-Item',
        'steamapps\\common\\ForzaHorizon6.*Remove-Item'
    )
    foreach ($pattern in $forbiddenPatterns) {
        $matched = $false
        if ($source) { $matched = [regex]::IsMatch($source, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
        [void]$rows.Add([pscustomobject]@{
            Check  = "Forbidden pattern: $pattern"
            Status = if ($matched) { 'Warn' } else { 'OK' }
            Detail = if ($matched) { 'Pattern appeared in script text; review manually.' } else { 'Not present.' }
        })
    }
    [void]$rows.Add([pscustomobject]@{
        Check  = 'Game install modification policy'
        Status = 'OK'
        Detail = 'Assert-FH6SafeTarget refuses steamapps\common\ForzaHorizon6 and forzahorizon6.exe paths before cleanup actions.'
    })
    [void]$rows.Add([pscustomobject]@{
        Check  = 'Telemetry direction'
        Status = 'OK'
        Detail = 'Telemetry listener uses UDP receive only. It does not send data back to FH6.'
    })
    [void]$rows.Add([pscustomobject]@{
        Check  = 'Destructive action defaults'
        Status = 'OK'
        Detail = 'Backup is enabled by default; Dry Run is available; delete/rename operations require selected cleanable records.'
    })
    return $rows.ToArray()
}

function Invoke-CompanionSelfTest {
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Test($Name, $Status, $Detail) {
        [void]$rows.Add([pscustomobject]@{ Test = $Name; Status = $Status; Detail = $Detail })
    }

    try {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Config.Downloads 'FH6-CompanionDoctor.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
        Add-Test 'PowerShell parser' ($(if ($errors.Count -eq 0) { 'OK' } else { 'Warn' })) "$($errors.Count) parser error(s)"
    }
    catch { Add-Test 'PowerShell parser' 'Warn' $_.Exception.Message }

    try { Add-Test 'Steam install detection' ($(if (@(Get-SteamInstallInfo).Count -gt 0) { 'OK' } else { 'Warn' })) "$(@(Get-SteamInstallInfo).Count) install row(s)" } catch { Add-Test 'Steam install detection' 'Warn' $_.Exception.Message }
    try { Add-Test 'FH6 inventory' 'OK' "$(@(Get-FH6Inventory).Count) inventory row(s)" } catch { Add-Test 'FH6 inventory' 'Warn' $_.Exception.Message }
    try { Add-Test 'Health collectors' 'OK' "$(@(Get-HealthRows).Count) health row(s)" } catch { Add-Test 'Health collectors' 'Warn' $_.Exception.Message }
    try { Add-Test 'Crash collectors' 'OK' "$(@(Get-CrashEventRows).Count) crash event row(s); $(@(Get-CrashReportRows).Count) FH6 report row(s)" } catch { Add-Test 'Crash collectors' 'Warn' $_.Exception.Message }
    try { Add-Test 'CrashScope universal collectors' 'OK' "$(@(Get-UniversalCrashRows -Target $script:Config.ExeName).Count) event row(s); $(@(Get-UniversalCrashFingerprintRows -Target $script:Config.ExeName).Count) fingerprint row(s)" } catch { Add-Test 'CrashScope universal collectors' 'Warn' $_.Exception.Message }
    try { Add-Test 'Crash intelligence scoring' 'OK' "$(@(Get-UniversalRootCauseScoreRows -Target $script:Config.ExeName).Count) score row(s); $(@(Get-UniversalCrashHeatmapRows -Target $script:Config.ExeName).Count) heatmap row(s)" } catch { Add-Test 'Crash intelligence scoring' 'Warn' $_.Exception.Message }
    try { Add-Test 'Stability workbench collectors' 'OK' "$(@(Get-CrashEvidenceTimelineRows -Target $script:Config.ExeName).Count) timeline row(s); $(@(Get-CrashEvidenceInsightRows -Target $script:Config.ExeName).Count) insight row(s); $(@(Get-CrashStabilityRunbookRows -Target $script:Config.ExeName).Count) runbook step(s)" } catch { Add-Test 'Stability workbench collectors' 'Warn' $_.Exception.Message }
    try { Add-Test 'CrashScope evidence tools' 'OK' "$(@(Get-ExternalEvidenceToolRows | Where-Object { $_.Status -eq 'Available' }).Count) available tool(s)" } catch { Add-Test 'CrashScope evidence tools' 'Warn' $_.Exception.Message }
    try { Add-Test 'Telemetry port 5606' (Test-TelemetryPortAvailability -Port 5606).Status (Test-TelemetryPortAvailability -Port 5606).Detail } catch { Add-Test 'Telemetry port 5606' 'Warn' $_.Exception.Message }
    try {
        $audit = @(Get-ToolSafetyAuditRows)
        $warnings = @($audit | Where-Object { $_.Status -eq 'Warn' }).Count
        Add-Test 'Safety audit' ($(if ($warnings -eq 0) { 'OK' } else { 'Warn' })) "$warnings warning row(s)"
    }
    catch { Add-Test 'Safety audit' 'Warn' $_.Exception.Message }
    try {
        $snap = New-StateSnapshot -Label 'selftest'
        Add-Test 'Snapshot writer' ($(if ((Test-Path -LiteralPath $snap.Json) -and (Test-Path -LiteralPath $snap.Text)) { 'OK' } else { 'Warn' })) "$($snap.Json)"
    }
    catch { Add-Test 'Snapshot writer' 'Warn' $_.Exception.Message }

    return $rows.ToArray()
}

function Write-ToolManifest {
    New-ToolDirectory
    $manifest = [pscustomobject]@{
        ToolName        = 'FH6 Companion Doctor'
        Version         = $script:ToolVersion
        GeneratedAt     = (Get-Date).ToString('o')
        SafetyBoundary  = @(
            'No game install modification',
            'No forzahorizon6.exe modification',
            'No memory read/write',
            'No injection/hooks',
            'No gameplay/input automation',
            'No save editing for advantage/unlocks/currency'
        )
        Folders         = [pscustomobject]@{
            Backups   = $script:Config.BackupRoot
            Reports   = $script:Config.ReportRoot
            Packages  = $script:Config.PackageRoot
            Logs      = $script:Config.LogRoot
            Telemetry = $script:Config.TelemetryRoot
            Snapshots = $script:Config.SnapshotRoot
            Sessions  = $script:Config.SessionRoot
            Bundles   = $script:Config.BundleRoot
        }
        Files           = @(Get-ToolFileRows)
        OfficialReferences = @(Get-OfficialReferenceRows)
        SafetyAudit     = @(Get-ToolSafetyAuditRows)
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Config.ManifestPath -Encoding UTF8
    return $script:Config.ManifestPath
}

function New-PortableToolBundle {
    param([scriptblock]$Log = { param($m) Write-Host $m })
    New-ToolDirectory
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stage = Join-Path $env:TEMP "FH6_CompanionDoctor_Portable_$stamp"
    $zip = Join-Path $script:Config.BundleRoot "FH6_CompanionDoctor_Portable_$stamp.zip"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        $manifestPath = Write-ToolManifest
        foreach ($file in Get-ToolFileRows) {
            & $Log "Adding tool file: $($file.Name)"
            Copy-Item -LiteralPath $file.Path -Destination (Join-Path $stage $file.Name) -Force
        }
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stage (Split-Path $manifestPath -Leaf)) -Force
        Get-OfficialReferenceRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'official-references.json') -Encoding UTF8
        Get-ToolSafetyAuditRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'safety-audit.json') -Encoding UTF8
        Invoke-CompanionSelfTest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'self-test.json') -Encoding UTF8
        $readme = @"
FH6 Companion Doctor Portable Bundle
Generated: $(Get-Date)

Run:
  Run-FH6-CompanionDoctor.cmd

Safety:
  This external tool does not modify FH6 game install files, does not inject into
  the game, does not read/write game memory, and does not automate gameplay.

Included:
  - Tool scripts and launcher
  - README
  - Manifest with SHA256 hashes
  - Official references
  - Safety audit
  - Self-test output
"@
        $readme | Set-Content -LiteralPath (Join-Path $stage 'PORTABLE-BUNDLE-README.txt') -Encoding UTF8
        $content = @(Get-ChildItem -LiteralPath $stage -Force | Select-Object -ExpandProperty FullName)
        Compress-Archive -LiteralPath $content -DestinationPath $zip -Force
        & $Log "Portable bundle written: $zip"
        return $zip
    }
    finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ExpertRecommendationRows {
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Recommendation($Priority, $Area, $Finding, $Action, $Evidence) {
        [void]$rows.Add([pscustomobject]@{
            Priority = $Priority
            Area     = $Area
            Finding  = $Finding
            Action   = $Action
            Evidence = $Evidence
        })
    }

    $events = @(Get-CrashEventRows)
    $conflicts = @(Get-ConflictProcesses)
    $wer = @(Get-WERReportRows)
    $redists = @(Get-VisualCRedistRows)
    $mf = Get-MediaFoundationStatus
    $installs = @(Get-SteamInstallInfo)
    $gs = Get-GamingServicesVersion
    $mitigations = @(Get-ProcessMitigationRows)
    $startup = @(Get-StartupProgramRows)
    $gamingSettings = @(Get-WindowsGamingSettingRows)
    $permissionRows = @(Get-PathPermissionRows)
    $packages = @(Get-XboxAppPackageRows)
    $backupRows = @(Get-BackupIntegrityRows)
    $reliabilityRows = @(Get-ReliabilityRecordRows | Where-Object { $_.SourceName -ne 'Unavailable' })
    $compatRows = @(Get-AppCompatLayerRows | Where-Object { $_.AppPath -ne '<none>' })
    $graphicsPrefs = @(Get-GraphicsPreferenceRows | Where-Object { $_.AppPath -ne '<none>' })
    $securityRows = @(Get-SecurityProductRows | Where-Object { $_.DisplayName -ne 'Unavailable' })
    $securityBlocks = @(Get-SecurityBlockEventRows -Target $script:Config.ExeName | Where-Object { $_.EventId -in @(1121,1123,1127) })

    $accessViolations = @($events | Where-Object { $_.Code -in @('0xc0000005','c0000005') })
    if ($accessViolations.Count -ge 3) {
        Add-Recommendation 1 'Crash Pattern' 'Repeated access-violation/BEX-style crashes detected.' 'Prioritize conflict process isolation, clean boot, graphics/runtime repair, and support package capture over more save wipes.' "$($accessViolations.Count) matching event(s)"
    }
    if ($conflicts.Count -gt 0) {
        Add-Recommendation 1 'Background Processes' 'Possible overlay/hook/conflict process detected.' 'Stop these tools before launching FH6, especially capture overlays, performance monitors, tuning tools, and input hooks.' (($conflicts | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')
    }
    $captureActive = @($gamingSettings | Where-Object { $_.Area -in @('Game Bar','Capture') -and $_.Interpretation -match 'Enabled|active' })
    if ($captureActive.Count -gt 0) {
        Add-Recommendation 2 'Windows Gaming Settings' 'Game Bar or capture stack appears enabled.' 'Disable Windows capture/Game Bar features for one clean repro attempt.' (($captureActive | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ')
    }
    $permissionWarnings = @($permissionRows | Where-Object { $_.Status -eq 'Warn' })
    if ($permissionWarnings.Count -gt 0) {
        Add-Recommendation 1 'Permissions' 'FH6/tool user-data path write warning detected.' 'Check folder permissions and security software for the warned paths before further save/cache cleanup.' (($permissionWarnings | ForEach-Object { "$($_.Path): $($_.Detail)" }) -join '; ')
    }
    $packageWarnings = @($packages | Where-Object { $_.Status -ne 'Installed' })
    if ($packageWarnings.Count -gt 0) {
        Add-Recommendation 2 'Xbox Apps' 'One or more Xbox/Store support packages are missing or unavailable.' 'Update/repair Xbox app, Microsoft Store, Xbox Identity Provider, and Gaming Services.' (($packageWarnings | ForEach-Object { "$($_.Name): $($_.Status)" }) -join '; ')
    }
    $backupWarnings = @($backupRows | Where-Object { $_.Status -eq 'Warn' })
    if ($backupWarnings.Count -gt 0) {
        Add-Recommendation 3 'Backups' 'One or more backup zips may not be safely restorable.' 'Keep using current Companion Doctor backups; avoid restoring archives without manifest.json.' (($backupWarnings | Select-Object -ExpandProperty Name) -join ', ')
    }
    if ($compatRows.Count -gt 0) {
        Add-Recommendation 2 'Compatibility' 'FH6-specific Windows compatibility layer flags are present.' 'Remove compatibility/admin/fullscreen-optimization flags for one clean repro attempt.' (($compatRows | ForEach-Object { "$($_.AppPath): $($_.Flags)" }) -join '; ')
    }
    if ($graphicsPrefs.Count -gt 0) {
        Add-Recommendation 3 'Graphics Preference' 'Windows has FH6-specific GPU preference entries.' 'If using a laptop/hybrid GPU, verify FH6 is assigned to the intended high-performance GPU.' (($graphicsPrefs | ForEach-Object { "$($_.AppPath): $($_.Value)" }) -join '; ')
    }
    if ($reliabilityRows.Count -gt 0) {
        Add-Recommendation 3 'Reliability Monitor' 'FH6 appears in Windows Reliability Monitor records.' 'Compare Reliability records with Event Timeline and session snapshots after the next crash.' "$($reliabilityRows.Count) reliability row(s)"
    }
    if ($securityRows.Count -gt 1) {
        Add-Recommendation 3 'Security Software' 'Multiple security products are visible.' 'For one clean repro, reduce unnecessary real-time scanners/overlays and avoid quarantining FH6 user/cache paths.' (($securityRows | Select-Object -ExpandProperty DisplayName) -join ', ')
    }
    if ($securityBlocks.Count -gt 0) {
        Add-Recommendation 2 'Security Blocks' 'Defender ASR or Controlled Folder Access block events mention FH6.' 'Review the Defender Operational event details; only allowlist trusted signed paths if a real block is confirmed.' "$($securityBlocks.Count) block event(s)"
    }
    if ($wer.Count -gt 0) {
        Add-Recommendation 2 'Crash Evidence' 'WER report folders exist for FH6.' 'Build a support package after reproducing the crash so WER/FH6/Event Viewer data is bundled together.' "$($wer.Count) WER folder(s)"
    }
    if ($mf.Status -ne 'OK') {
        Add-Recommendation 1 'Runtime' 'Media Foundation components appear missing.' 'Install/repair Windows Media Feature Pack or Media Foundation components before retrying.' $mf.Detail
    }
    $hasModernRedist = @($redists | Where-Object {
        $_.Name -match '2015-2022|2015.*2022|2017|2019|2022|v14' -or
        ($_.Version -and ([version]$_.Version -ge [version]'14.0.0.0'))
    }).Count -gt 0
    if (-not $hasModernRedist) {
        Add-Recommendation 1 'Runtime' 'Modern Visual C++ Redistributable was not detected.' 'Install/repair the latest x64 and x86 Microsoft Visual C++ Redistributables.' "$($redists.Count) redistributable entry/entries found"
    }
    try {
        if ([version]$gs -lt [version]'36.113.2002.0') {
            Add-Recommendation 1 'Gaming Services' 'Gaming Services is below FH6 minimum version.' 'Update Gaming Services from Microsoft Store before launching FH6.' $gs
        }
    }
    catch {
        Add-Recommendation 2 'Gaming Services' 'Gaming Services version could not be parsed.' 'Open Microsoft Store Downloads and check for Gaming Services updates.' $gs
    }
    foreach ($install in $installs) {
        if ($install.LibraryLength -gt 59) {
            Add-Recommendation 1 'Steam Install' 'Steam library path exceeds FH6 supported path-length guidance.' 'Move FH6 to a Steam library path with 59 characters or fewer.' "$($install.LibraryLength) chars: $($install.Library)"
        }
        if (-not $install.ExeExists) {
            Add-Recommendation 1 'Steam Install' 'FH6 executable was not found.' 'Use Steam Verify Integrity or reinstall FH6.' $install.Exe
        }
    }
    if ($events.Count -gt 0 -and $conflicts.Count -eq 0) {
        Add-Recommendation 3 'Clean Boot' 'Crashes continue but no common conflict process is currently visible.' 'Use a clean boot or temporarily disable nonessential startup apps, then retry.' "$($startup.Count) startup item(s) inventoried"
    }
    if (@($mitigations | Where-Object { $_.Scope -eq 'Image' -and $_.Area -ne 'Unavailable' }).Count -gt 0) {
        Add-Recommendation 3 'Exploit Protection' 'Image-specific process mitigation settings exist for FH6 executable name.' 'Review Windows Exploit Protection entries if crashes remain unchanged after clean boot.' 'Image mitigation rows found'
    }
    if ($rows.Count -eq 0) {
        Add-Recommendation 4 'Status' 'No urgent expert findings were generated.' 'Use Preflight + Launch, then create a snapshot/support package if the crash reproduces.' 'No high-priority rule matched'
    }

    return @($rows | Sort-Object Priority, Area)
}

function Get-ExpertRecommendationSummary {
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Expert Recommendation Scorecard')
    [void]$lines.Add('===============================')
    foreach ($r in Get-ExpertRecommendationRows) {
        [void]$lines.Add("[P$($r.Priority)] $($r.Area): $($r.Finding)")
        [void]$lines.Add("  Action: $($r.Action)")
        [void]$lines.Add("  Evidence: $($r.Evidence)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-DeviceRows {
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $regex = 'Logitech|Thrustmaster|Fanatec|MOZA|Turtle|HORI|Mad Catz|Xbox|Controller|Wheel|Pedal|Shifter|HID|USB Hub|Driving'
        Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object {
            $_.Name -match $regex -or $_.PNPClass -match 'HIDClass|USB|MEDIA'
        } | Sort-Object Name | ForEach-Object {
            [void]$rows.Add([pscustomobject]@{
                Name         = $_.Name
                Status       = $_.Status
                Class        = $_.PNPClass
                Manufacturer = $_.Manufacturer
                DeviceId     = $_.DeviceID
            })
        }
    }
    catch {}
    return $rows.ToArray()
}

function Get-HealthRows {
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Health($Area, $Check, $Status, $Detail, $Recommendation) {
        [void]$rows.Add([pscustomobject]@{
            Area           = $Area
            Check          = $Check
            Status         = $Status
            Detail         = $Detail
            Recommendation = $Recommendation
        })
    }

    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    Add-Health 'Account' 'Administrator' ($(if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'OK' } else { 'Info' })) "User=$env:USERNAME" 'Some official troubleshooting steps require admin, but routine scans do not.'

    $gs = Get-GamingServicesVersion
    $gsStatus = 'Warn'
    try { if ([version]$gs -ge [version]'36.113.2002.0') { $gsStatus = 'OK' } } catch {}
    Add-Health 'Gaming Services' 'Version' $gsStatus $gs 'FH6 requires Gaming Services 36.113.2002.0 or newer.'

    foreach ($install in Get-SteamInstallInfo) {
        $pathStatus = if ($install.LibraryLength -le 59) { 'OK' } else { 'Warn' }
        Add-Health 'Steam' 'Library path length' $pathStatus "$($install.LibraryLength) chars: $($install.Library)" 'FH6 Steam library path should be 59 characters or shorter.'
        Add-Health 'Steam' 'Game executable' ($(if ($install.ExeExists) { 'OK' } else { 'Warn' })) $install.Exe 'Use Steam verify integrity if the executable is missing.'
        Add-Health 'Steam' 'Manifest state' 'Info' "StateFlags=$($install.StateFlags); LastUpdated=$($install.LastUpdated)" 'StateFlags 4 usually means installed/ready.'
    }
    if (@(Get-SteamInstallInfo).Count -eq 0) {
        Add-Health 'Steam' 'Install detection' 'Warn' 'No appmanifest_2483190.acf found.' 'Install through Steam or confirm a different launcher/version.'
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Add-Health 'Windows' 'OS' 'Info' "$($os.Caption) build $($os.BuildNumber)" 'Keep Windows updated.'
        Add-Health 'Windows' 'Free memory' 'Info' ("{0:N1} GB free physical memory" -f ($os.FreePhysicalMemory / 1MB)) 'Close heavy background apps before crash testing.'
    }
    catch {
        Add-Health 'Windows' 'OS query' 'Warn' $_.Exception.Message 'Run as administrator if WMI/CIM is blocked.'
    }

    try {
        Get-CimInstance Win32_VideoController | ForEach-Object {
            Add-Health 'GPU' $_.Name 'Info' "Driver=$($_.DriverVersion); Date=$($_.DriverDate)" 'Use the latest stable vendor driver; test without overlays.'
        }
    }
    catch {
        Add-Health 'GPU' 'GPU query' 'Warn' $_.Exception.Message 'Run dxdiag support package.'
    }

    $driverRows = @(Get-DriverInventoryRows)
    Add-Health 'Drivers' 'Driver inventory' 'Info' "$($driverRows.Count) display/HID/USB/media/system driver row(s)" 'Use Driver Inventory when comparing graphics/input/USB driver state after changes.'

    $installAudit = @(Get-InstallAuditRows)
    $installWarnings = @($installAudit | Where-Object { $_.Status -eq 'Warn' }).Count
    Add-Health 'Install Audit' 'Read-only install checks' ($(if ($installWarnings -eq 0) { 'OK' } else { 'Warn' })) "$($installAudit.Count) row(s), $installWarnings warning(s)" 'Use Steam Verify Integrity only from Steam UI if install audit warnings appear.'

    $telemetryPort = Test-TelemetryPortAvailability -Port 5606
    Add-Health 'Telemetry' 'Default Data Out port 5606' ($(if ($telemetryPort.Status -eq 'Available') { 'OK' } elseif ($telemetryPort.Status -eq 'Busy') { 'Warn' } else { 'Info' })) $telemetryPort.Detail 'If busy, choose another port in the Telemetry tab and set the same port in FH6 Data Out.'

    $gamingSettings = @(Get-WindowsGamingSettingRows)
    $captureActive = @($gamingSettings | Where-Object { $_.Area -in @('Game Bar','Capture') -and $_.Interpretation -match 'Enabled|active' }).Count
    Add-Health 'Windows Gaming' 'Game Bar/Capture settings' ($(if ($captureActive -gt 0) { 'Warn' } else { 'OK' })) "$captureActive capture/overlay-related setting(s) appear enabled" 'Disable Game Bar/capture features during a clean crash repro test.'

    $powerRows = @(Get-PowerThermalRows)
    $powerScheme = @($powerRows | Where-Object { $_.Name -eq 'Active scheme' } | Select-Object -First 1)
    Add-Health 'Power' 'Active power profile' 'Info' ($(if ($powerScheme.Count) { $powerScheme[0].Value } else { 'Unknown' })) 'Use AC power and a high-performance profile during crash testing.'

    $packages = @(Get-XboxAppPackageRows)
    $missingPackages = @($packages | Where-Object { $_.Status -ne 'Installed' }).Count
    Add-Health 'Xbox Apps' 'Package inventory' ($(if ($missingPackages -eq 0) { 'OK' } else { 'Warn' })) "$($packages.Count) package rows, $missingPackages missing/unavailable" 'Repair/update Xbox app, Store, Identity Provider, and Gaming Services if package warnings appear.'

    $permissionRows = @(Get-PathPermissionRows)
    $permissionWarnings = @($permissionRows | Where-Object { $_.Status -eq 'Warn' }).Count
    Add-Health 'Permissions' 'FH6/tool writable paths' ($(if ($permissionWarnings -eq 0) { 'OK' } else { 'Warn' })) "$($permissionRows.Count) path(s), $permissionWarnings write warning(s)" 'If FH6 user/cache roots are unwritable, permissions or security software may block profile creation.'

    $backupRows = @(Get-BackupIntegrityRows)
    $backupWarnings = @($backupRows | Where-Object { $_.Status -eq 'Warn' }).Count
    Add-Health 'Backups' 'Backup zip integrity' ($(if ($backupWarnings -eq 0) { 'OK' } else { 'Warn' })) "$($backupRows.Count) backup row(s), $backupWarnings warning(s)" 'Backups should include manifest.json so restore can target original paths safely.'

    $reliabilityRows = @(Get-ReliabilityRecordRows | Where-Object { $_.SourceName -ne 'Unavailable' })
    Add-Health 'Reliability' 'Reliability Monitor records' ($(if ($reliabilityRows.Count -gt 0) { 'Warn' } else { 'Info' })) "$($reliabilityRows.Count) FH6 reliability record(s)" 'Reliability Monitor records can confirm crash timing even when local FH6 reports are sparse.'

    $displayRows = @(Get-DisplayTopologyRows)
    Add-Health 'Display' 'GPU/display topology' 'Info' "$($displayRows.Count) GPU/monitor row(s)" 'Use Display Topology to compare resolution, refresh, GPU, and monitor context.'

    $graphicsPrefs = @(Get-GraphicsPreferenceRows | Where-Object { $_.AppPath -ne '<none>' })
    Add-Health 'Graphics Preference' 'FH6 Windows GPU preference' ($(if ($graphicsPrefs.Count -gt 0) { 'Info' } else { 'OK' })) "$($graphicsPrefs.Count) FH6-specific preference row(s)" 'If crashes differ by GPU mode, review Windows graphics preference for FH6.'

    $compatRows = @(Get-AppCompatLayerRows | Where-Object { $_.AppPath -ne '<none>' })
    Add-Health 'Compatibility' 'FH6 compatibility layer flags' ($(if ($compatRows.Count -gt 0) { 'Warn' } else { 'OK' })) "$($compatRows.Count) FH6-specific compatibility row(s)" 'Remove forced compatibility/admin/fullscreen flags for one clean crash repro attempt if present.'

    $securityRows = @(Get-SecurityProductRows)
    Add-Health 'Security' 'Security product inventory' 'Info' "$($securityRows.Count) security product row(s)" 'Security software can block writes or inject scanning hooks; test with controlled exclusions only if trusted and necessary.'

    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            Add-Health 'Storage' $_.DeviceID 'Info' ("Free={0:N1} GB Total={1:N1} GB" -f ($_.FreeSpace / 1GB), ($_.Size / 1GB)) 'Keep enough free disk space for updates and shader/cache writes.'
        }
    }
    catch {}

    $conflicts = @(Get-ConflictProcesses)
    Add-Health 'Processes' 'Overlay/conflict scan' ($(if ($conflicts.Count -eq 0) { 'OK' } else { 'Warn' })) "$($conflicts.Count) possible match(es)" 'Disable overlays, monitoring, capture, input-hook, and tuning tools while testing.'

    $services = @(Get-XboxServiceRows)
    foreach ($svc in $services) {
        $status = if ($svc.Status -eq 'Running' -or $svc.Status -eq 'Stopped') { 'Info' } elseif ($svc.Status -eq 'Not found') { 'Warn' } else { 'Info' }
        Add-Health 'Xbox Services' $svc.Name $status "$($svc.Status) $($svc.StartType)" 'If FH6 authentication/cloud/game-save issues appear, repair Gaming Services and Xbox app components.'
    }

    $redists = @(Get-VisualCRedistRows)
    $hasModernRedist = @($redists | Where-Object {
        $_.Name -match '2015-2022|2015.*2022|2017|2019|2022|v14' -or
        ($_.Version -and ([version]$_.Version -ge [version]'14.0.0.0'))
    }).Count -gt 0
    Add-Health 'Runtime' 'Visual C++ redistributables' ($(if ($hasModernRedist) { 'OK' } else { 'Warn' })) "$($redists.Count) Visual C++ redistributable entries found" 'Install/repair the latest Microsoft Visual C++ Redistributable if crashes persist.'

    $mf = Get-MediaFoundationStatus
    Add-Health 'Runtime' 'Media Foundation' $mf.Status $mf.Detail 'FH6 error FH601 relates to Microsoft Media Foundation; install the Media Feature Pack on Windows N if needed.'

    $wer = @(Get-WERReportRows)
    Add-Health 'Crash Lab' 'WER report folders' ($(if ($wer.Count -gt 0) { 'Warn' } else { 'Info' })) "$($wer.Count) FH6 WER folder(s) found" 'Include WER data in a support package after reproducing the crash.'

    $steamLogRows = @(Get-SteamLogRows)
    Add-Health 'Steam' 'Log matches' ($(if ($steamLogRows.Count -gt 0) { 'Info' } else { 'Info' })) "$($steamLogRows.Count) FH6/app/cloud log match(es)" 'Use Steam Logs to inspect cloud/sync/content activity around launch attempts.'

    $evidenceTools = @(Get-ExternalEvidenceToolRows)
    $availableTools = @($evidenceTools | Where-Object { $_.Status -eq 'Available' })
    Add-Health 'CrashScope' 'Evidence tools' ($(if ($availableTools.Count -ge 4) { 'OK' } else { 'Info' })) "$($availableTools.Count)/$($evidenceTools.Count) tools available" 'DxDiag, WPR, SFC, DISM, ProcDump, and WinDbg availability controls how deep evidence capture can go.'

    $events = @(Get-CrashEventRows)
    $latest = if ($events.Count) { "$($events[0].Time) $($events[0].EventName) $($events[0].Code)" } else { 'No recent FH6 crash events found.' }
    Add-Health 'Crash Lab' 'Latest crash' ($(if ($events.Count) { 'Warn' } else { 'OK' })) $latest 'Export support package after reproducing a crash.'

    return $rows.ToArray()
}

function Get-StatusSummary {
    $processes = @(Get-FH6Process)
    $installs = @(Get-SteamInstallInfo)
    $installText = if ($installs.Count) { ($installs | ForEach-Object { "$($_.Exe) exists=$($_.ExeExists)" }) -join '; ' } else { 'Steam FH6 install not detected' }
    return @"
Game process running: $($processes.Count -gt 0)
Toolbelt mode: $($script:Config.ToolbeltMode)
Tool root: $($script:Config.Downloads)
Project root: $($script:Config.ProjectRoot)
Data root: $($script:Config.DataRoot)
Gaming Services: $(Get-GamingServicesVersion)
Steam install: $installText
Local FH6 root: $($script:Config.LocalRoot)
Xbox GameSave root: $($script:Config.XboxPgsRoot)
Backups: $($script:Config.BackupRoot)
Reports: $($script:Config.ReportRoot)
Support packages: $($script:Config.PackageRoot)
Logs: $($script:Config.LogRoot)
Snapshots: $($script:Config.SnapshotRoot)
Sessions: $($script:Config.SessionRoot)
Portable bundles: $($script:Config.BundleRoot)
CrashScope universal: $($script:Config.UniversalRoot)
Telemetry: configure FH6 Data Out to IP 127.0.0.1 and the port shown in the Telemetry tab.
Steam Cloud: turn it off in Steam > FH6 > Properties > General before deleting saves.
"@
}

function Export-FH6Report {
    param([object[]]$Records = @())
    New-ToolDirectory
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path = Join-Path $script:Config.ReportRoot "FH6_CompanionDoctor_Report_$stamp.txt"
    $body = New-Object System.Collections.Generic.List[string]
    [void]$body.Add("FH6 Companion Doctor Report")
    [void]$body.Add("Generated: $(Get-Date)")
    [void]$body.Add("")
    [void]$body.Add("== Status ==")
    [void]$body.Add((Get-StatusSummary))
    [void]$body.Add("")
    [void]$body.Add("== Health ==")
    foreach ($h in Get-HealthRows) {
        [void]$body.Add("[$($h.Status)] $($h.Area) / $($h.Check): $($h.Detail)")
        [void]$body.Add("  $($h.Recommendation)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Inventory ==")
    foreach ($record in $Records | Sort-Object Category, Path) {
        [void]$body.Add("[$($record.Category)] exists=$($record.Exists) cleanable=$($record.Cleanable) sizeMB=$($record.SizeMB) items=$($record.Items) modified=$($record.LastWriteTime)")
        [void]$body.Add("  $($record.Path)")
        [void]$body.Add("  $($record.Description)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Crashes ==")
    [void]$body.Add((Get-CrashSummary))
    [void]$body.Add("")
    [void]$body.Add("== Crash Signature Analysis ==")
    [void]$body.Add((Get-CrashSignatureAnalysis))
    [void]$body.Add("")
    [void]$body.Add("== Crash Fingerprints ==")
    foreach ($f in Get-CrashFingerprintRows) {
        [void]$body.Add("Count=$($f.Count) first=$($f.FirstSeen) last=$($f.LastSeen) event=$($f.EventName) code=$($f.Code) module=$($f.Module)")
        [void]$body.Add("  $($f.Interpretation)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Guided Fix Workflow ==")
    [void]$body.Add((Get-GuidedWorkflowSummary))
    [void]$body.Add("")
    [void]$body.Add("== CrashScope Universal Action Plan ==")
    foreach ($a in Get-UniversalCrashActionRows -Target $script:Config.ExeName) {
        [void]$body.Add("[P$($a.Priority)] $($a.Area) [$($a.State)]: $($a.Action)")
        [void]$body.Add("  $($a.Evidence)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Crash Intelligence ==")
    [void]$body.Add((Get-CrashIntelligenceSummary -Target $script:Config.ExeName))
    [void]$body.Add("")
    [void]$body.Add("== Stability Workbench ==")
    [void]$body.Add((Get-CrashStabilityRunbookText -Target $script:Config.ExeName))
    [void]$body.Add("")
    [void]$body.Add("== CrashScope Universal Fingerprints ==")
    foreach ($f in Get-UniversalCrashFingerprintRows -Target $script:Config.ExeName) {
        [void]$body.Add("$($f.Count)x $($f.App) $($f.EventName) $($f.Code) module=$($f.Module) class=$($f.Class) severity=$($f.Severity)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Expert Recommendations ==")
    [void]$body.Add((Get-ExpertRecommendationSummary))
    [void]$body.Add("")
    [void]$body.Add("== Tool Self-Test ==")
    foreach ($t in Invoke-CompanionSelfTest) {
        [void]$body.Add("[$($t.Status)] $($t.Test): $($t.Detail)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Tool Safety Audit ==")
    foreach ($a in Get-ToolSafetyAuditRows) {
        [void]$body.Add("[$($a.Status)] $($a.Check): $($a.Detail)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Official References ==")
    foreach ($ref in Get-OfficialReferenceRows) {
        [void]$body.Add("$($ref.Area): $($ref.Url)")
        [void]$body.Add("  $($ref.Why)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Event Timeline ==")
    [void]$body.Add((Get-EventTimelineSummary))
    [void]$body.Add("")
    [void]$body.Add("== Latest Crash Correlation ==")
    [void]$body.Add((Get-CrashCorrelationSummary -Minutes 10))
    [void]$body.Add("")
    [void]$body.Add("== Conflicts ==")
    [void]$body.Add((Get-ConflictSummary))
    [void]$body.Add("")
    [void]$body.Add("== Steam Logs ==")
    [void]$body.Add((Get-SteamLogSummary))
    [void]$body.Add("")
    [void]$body.Add("== Xbox Services ==")
    foreach ($s in Get-XboxServiceRows) {
        [void]$body.Add("$($s.Name) | $($s.Status) | $($s.StartType) | $($s.DisplayName)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Visual C++ Redistributables ==")
    foreach ($v in Get-VisualCRedistRows) {
        [void]$body.Add("$($v.Name) | Version=$($v.Version) | InstallDate=$($v.InstallDate)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Media Foundation ==")
    $mf = Get-MediaFoundationStatus
    [void]$body.Add("$($mf.Status): $($mf.Detail)")
    [void]$body.Add("")
    [void]$body.Add("== WER Reports ==")
    foreach ($w in Get-WERReportRows) {
        [void]$body.Add("$($w.LastWriteTime) | $($w.EventType) | $($w.Name) | $($w.Path)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Startup Programs ==")
    foreach ($s in Get-StartupProgramRows) {
        [void]$body.Add("$($s.Source) | $($s.Scope) | $($s.Name) | $($s.Command)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Process Mitigations ==")
    foreach ($m in Get-ProcessMitigationRows) {
        [void]$body.Add("$($m.Scope) | $($m.Area) | $($m.Setting) | $($m.Value)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Driver Inventory ==")
    foreach ($d in Get-DriverInventoryRows) {
        [void]$body.Add("$($d.DeviceClass) | $($d.DeviceName) | $($d.DriverVersion) | $($d.Manufacturer) | Signed=$($d.IsSigned)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Read-only Install Audit ==")
    foreach ($a in Get-InstallAuditRows) {
        [void]$body.Add("[$($a.Status)] $($a.Check): $($a.Value)")
        if ($a.Path) { [void]$body.Add("  $($a.Path)") }
    }
    [void]$body.Add("")
    [void]$body.Add("== Telemetry Port Preflight ==")
    [void]$body.Add((Get-TelemetryPreflightSummary -Port 5606))
    [void]$body.Add("")
    [void]$body.Add("== Windows Gaming Settings ==")
    foreach ($g in Get-WindowsGamingSettingRows) {
        [void]$body.Add("$($g.Area) | $($g.Name) | $($g.Value) | $($g.Interpretation)")
        [void]$body.Add("  $($g.Path)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Power and Thermal ==")
    foreach ($p in Get-PowerThermalRows) {
        [void]$body.Add("$($p.Area) | $($p.Name) | $($p.Value) | $($p.Detail)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Xbox App Packages ==")
    foreach ($pkg in Get-XboxAppPackageRows) {
        [void]$body.Add("$($pkg.Name) | $($pkg.Status) | $($pkg.Version) | $($pkg.PackageFullName)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Path Permissions ==")
    foreach ($perm in Get-PathPermissionRows) {
        [void]$body.Add("$($perm.Status) | Exists=$($perm.Exists) | $($perm.Path) | $($perm.Detail)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Backup Integrity ==")
    foreach ($backup in Get-BackupIntegrityRows) {
        [void]$body.Add("$($backup.Status) | $($backup.Name) | entries=$($backup.Entries) | sizeMB=$($backup.SizeMB) | $($backup.Detail)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Reliability Records ==")
    foreach ($r in Get-ReliabilityRecordRows) {
        [void]$body.Add("$($r.TimeGenerated) | $($r.SourceName) | $($r.ProductName) | $($r.EventId) | $($r.Message)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Display Topology ==")
    foreach ($d in Get-DisplayTopologyRows) {
        [void]$body.Add("$($d.Type) | $($d.Name) | $($d.Detail) | Driver=$($d.Driver) | Status=$($d.Status)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Graphics Preferences ==")
    foreach ($g in Get-GraphicsPreferenceRows) {
        [void]$body.Add("$($g.AppPath) | $($g.Value) | $($g.Source)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Compatibility Layers ==")
    foreach ($c in Get-AppCompatLayerRows) {
        [void]$body.Add("$($c.AppPath) | $($c.Flags) | $($c.Source)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Security Products ==")
    foreach ($s in Get-SecurityProductRows) {
        [void]$body.Add("$($s.Type) | $($s.DisplayName) | State=$($s.ProductState) | $($s.PathToSignedProductExe)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Devices ==")
    foreach ($d in Get-DeviceRows) {
        [void]$body.Add("$($d.Name) | Status=$($d.Status) | Class=$($d.Class) | Manufacturer=$($d.Manufacturer)")
    }
    $body -join [Environment]::NewLine | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function New-StateSnapshot {
    param([string]$Label = 'manual')
    New-ToolDirectory
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeLabel = ConvertTo-SafeName -Text $Label
    $jsonPath = Join-Path $script:Config.SnapshotRoot "FH6_StateSnapshot_${stamp}_$safeLabel.json"
    $txtPath = Join-Path $script:Config.SnapshotRoot "FH6_StateSnapshot_${stamp}_$safeLabel.txt"
    $snapshot = [pscustomobject]@{
        GeneratedAt    = (Get-Date).ToString('o')
        Label          = $Label
        Status         = Get-StatusSummary
        Health         = @(Get-HealthRows)
        Inventory      = @(Get-FH6Inventory)
        CrashReports   = @(Get-CrashReportRows)
        CrashEvents    = @(Get-CrashEventRows)
        Conflicts      = @(Get-ConflictProcesses)
        SteamInstalls  = @(Get-SteamInstallInfo)
        SteamLogRows   = @(Get-SteamLogRows)
        XboxServices   = @(Get-XboxServiceRows)
        VisualCRedists = @(Get-VisualCRedistRows)
        MediaFoundation = Get-MediaFoundationStatus
        WERReports     = @(Get-WERReportRows)
        CrashAnalysis  = Get-CrashSignatureAnalysis
        CrashFingerprints = @(Get-CrashFingerprintRows)
        Recommendations = @(Get-ExpertRecommendationRows)
        GuidedWorkflow = @(Get-GuidedWorkflowRows)
        UniversalCrashes = @(Get-UniversalCrashRows -Target $script:Config.ExeName)
        UniversalFingerprints = @(Get-UniversalCrashFingerprintRows -Target $script:Config.ExeName)
        UniversalActionPlan = @(Get-UniversalCrashActionRows -Target $script:Config.ExeName)
        CrashIntelScores = @(Get-UniversalRootCauseScoreRows -Target $script:Config.ExeName)
        CrashIntelHeatmap = @(Get-UniversalCrashHeatmapRows -Target $script:Config.ExeName)
        CrashIntelChanges = @(Get-CrashIntelChangeCorrelationRows -Target $script:Config.ExeName)
        StabilityTimeline = @(Get-CrashEvidenceTimelineRows -Target $script:Config.ExeName)
        StabilityInsights = @(Get-CrashEvidenceInsightRows -Target $script:Config.ExeName)
        StabilityRunbook = @(Get-CrashStabilityRunbookRows -Target $script:Config.ExeName)
        SecurityBlockEvents = @(Get-SecurityBlockEventRows -Target $script:Config.ExeName)
        ExternalEvidenceTools = @(Get-ExternalEvidenceToolRows)
        LocalDumpConfig = @(Get-LocalDumpConfigRows -Target $script:Config.ExeName)
        Timeline       = @(Get-EventTimelineRows)
        LatestCrashCorrelation = @(Get-CrashCorrelationRows -Minutes 10)
        StartupPrograms = @(Get-StartupProgramRows)
        ProcessMitigations = @(Get-ProcessMitigationRows)
        DriverInventory = @(Get-DriverInventoryRows)
        InstallAudit   = @(Get-InstallAuditRows)
        TelemetryPreflight = Test-TelemetryPortAvailability -Port 5606
        WindowsGamingSettings = @(Get-WindowsGamingSettingRows)
        PowerThermal = @(Get-PowerThermalRows)
        XboxAppPackages = @(Get-XboxAppPackageRows)
        PathPermissions = @(Get-PathPermissionRows)
        BackupIntegrity = @(Get-BackupIntegrityRows)
        ReliabilityRecords = @(Get-ReliabilityRecordRows)
        DisplayTopology = @(Get-DisplayTopologyRows)
        GraphicsPreferences = @(Get-GraphicsPreferenceRows)
        CompatibilityLayers = @(Get-AppCompatLayerRows)
        SecurityProducts = @(Get-SecurityProductRows)
        ToolSafetyAudit = @(Get-ToolSafetyAuditRows)
        OfficialReferences = @(Get-OfficialReferenceRows)
        ToolFiles = @(Get-ToolFileRows)
        Devices        = @(Get-DeviceRows)
    }
    $snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("FH6 Companion Doctor State Snapshot")
    [void]$lines.Add("Generated: $(Get-Date)")
    [void]$lines.Add("Label: $Label")
    [void]$lines.Add("")
    [void]$lines.Add("== Status ==")
    [void]$lines.Add($snapshot.Status)
    [void]$lines.Add("")
    [void]$lines.Add("== Health Warnings ==")
    foreach ($h in $snapshot.Health | Where-Object { $_.Status -ne 'OK' }) {
        [void]$lines.Add("[$($h.Status)] $($h.Area) / $($h.Check): $($h.Detail)")
        [void]$lines.Add("  $($h.Recommendation)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("== Latest Crashes ==")
    foreach ($e in $snapshot.CrashEvents | Select-Object -First 10) {
        [void]$lines.Add("$($e.Time) $($e.EventName) $($e.Code) module=$($e.Module)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("== Guided Workflow ==")
    foreach ($g in $snapshot.GuidedWorkflow | Sort-Object Priority | Select-Object -First 8) {
        [void]$lines.Add("[P$($g.Priority)] $($g.Phase) [$($g.State)]: $($g.Action)")
        [void]$lines.Add("  $($g.Evidence)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("== Crash Intelligence Scores ==")
    foreach ($score in $snapshot.CrashIntelScores | Select-Object -First 8) {
        [void]$lines.Add("[$($score.Confidence) $($score.Score)] $($score.Cause): $($score.NextAction)")
        [void]$lines.Add("  $($score.Evidence)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("== Stability Insights ==")
    foreach ($insight in $snapshot.StabilityInsights | Select-Object -First 10) {
        [void]$lines.Add("[$($insight.Status)] $($insight.Lane): count=$($insight.Count) signal=$($insight.Signal)")
        [void]$lines.Add("  $($insight.NextAction)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("== Stability Runbook ==")
    foreach ($runStep in $snapshot.StabilityRunbook | Select-Object -First 10) {
        [void]$lines.Add("$($runStep.Step). $($runStep.Phase) [$($runStep.Mode), risk=$($runStep.Risk)]: $($runStep.Action)")
        [void]$lines.Add("  Success: $($runStep.SuccessCheck)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("== CrashScope Universal Action Plan ==")
    foreach ($u in $snapshot.UniversalActionPlan | Sort-Object Priority | Select-Object -First 8) {
        [void]$lines.Add("[P$($u.Priority)] $($u.Area) [$($u.State)]: $($u.Action)")
        [void]$lines.Add("  $($u.Evidence)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("== Top Recommendations ==")
    foreach ($r in $snapshot.Recommendations | Sort-Object Priority | Select-Object -First 8) {
        [void]$lines.Add("[P$($r.Priority)] $($r.Area): $($r.Finding)")
        [void]$lines.Add("  $($r.Action)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("== Conflicts ==")
    foreach ($c in $snapshot.Conflicts) {
        [void]$lines.Add("$($c.ProcessName) pid=$($c.Id) $($c.Path)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("JSON: $jsonPath")
    $lines -join [Environment]::NewLine | Set-Content -LiteralPath $txtPath -Encoding UTF8
    return [pscustomobject]@{ Json = $jsonPath; Text = $txtPath }
}

function Get-StateSnapshotFiles {
    New-ToolDirectory
    @(Get-ChildItem -LiteralPath $script:Config.SnapshotRoot -File -Filter 'FH6_StateSnapshot_*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
}

function Compare-LatestStateSnapshots {
    $files = @(Get-StateSnapshotFiles | Select-Object -First 2)
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('FH6 State Snapshot Diff')
    [void]$lines.Add('=======================')
    if ($files.Count -lt 2) {
        [void]$lines.Add('Need at least two JSON snapshots. Use State Snapshot before and after a launch/crash attempt.')
        return ($lines -join [Environment]::NewLine)
    }

    $new = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
    $old = Get-Content -LiteralPath $files[1].FullName -Raw | ConvertFrom-Json
    [void]$lines.Add("New: $($files[0].Name) generated=$($new.GeneratedAt) label=$($new.Label)")
    [void]$lines.Add("Old: $($files[1].Name) generated=$($old.GeneratedAt) label=$($old.Label)")
    [void]$lines.Add('')

    function Count-ByCategory($items) {
        $map = @{}
        foreach ($g in @($items | Group-Object Category)) { $map[$g.Name] = $g.Count }
        return $map
    }
    $newInv = Count-ByCategory $new.Inventory
    $oldInv = Count-ByCategory $old.Inventory
    $allCategories = @($newInv.Keys + $oldInv.Keys | Sort-Object -Unique)
    [void]$lines.Add('Inventory category counts:')
    foreach ($cat in $allCategories) {
        $n = if ($newInv.ContainsKey($cat)) { $newInv[$cat] } else { 0 }
        $o = if ($oldInv.ContainsKey($cat)) { $oldInv[$cat] } else { 0 }
        $delta = $n - $o
        [void]$lines.Add("  $cat old=$o new=$n delta=$delta")
    }
    [void]$lines.Add('')

    $newCrash = @($new.CrashEvents)
    $oldCrash = @($old.CrashEvents)
    [void]$lines.Add("Crash event counts: old=$($oldCrash.Count) new=$($newCrash.Count) delta=$($newCrash.Count - $oldCrash.Count)")
    if ($newCrash.Count -gt 0) {
        [void]$lines.Add("Newest crash now: $($newCrash[0].Time) $($newCrash[0].EventName) $($newCrash[0].Code) module=$($newCrash[0].Module)")
    }
    if ($oldCrash.Count -gt 0) {
        [void]$lines.Add("Newest crash before: $($oldCrash[0].Time) $($oldCrash[0].EventName) $($oldCrash[0].Code) module=$($oldCrash[0].Module)")
    }
    [void]$lines.Add('')

    $newConflicts = @($new.Conflicts | ForEach-Object { "$($_.ProcessName):$($_.Id)" })
    $oldConflicts = @($old.Conflicts | ForEach-Object { "$($_.ProcessName):$($_.Id)" })
    $addedConflicts = @($newConflicts | Where-Object { $oldConflicts -notcontains $_ })
    $removedConflicts = @($oldConflicts | Where-Object { $newConflicts -notcontains $_ })
    [void]$lines.Add('Conflict process changes:')
    [void]$lines.Add("  Added: $(if ($addedConflicts.Count) { $addedConflicts -join ', ' } else { 'none' })")
    [void]$lines.Add("  Removed: $(if ($removedConflicts.Count) { $removedConflicts -join ', ' } else { 'none' })")
    [void]$lines.Add('')

    $newHealthWarn = @($new.Health | Where-Object { $_.Status -ne 'OK' } | ForEach-Object { "$($_.Area)/$($_.Check):$($_.Status):$($_.Detail)" })
    $oldHealthWarn = @($old.Health | Where-Object { $_.Status -ne 'OK' } | ForEach-Object { "$($_.Area)/$($_.Check):$($_.Status):$($_.Detail)" })
    $addedHealth = @($newHealthWarn | Where-Object { $oldHealthWarn -notcontains $_ })
    $removedHealth = @($oldHealthWarn | Where-Object { $newHealthWarn -notcontains $_ })
    [void]$lines.Add('Health warning changes:')
    [void]$lines.Add("  Added: $(if ($addedHealth.Count) { $addedHealth -join '; ' } else { 'none' })")
    [void]$lines.Add("  Removed: $(if ($removedHealth.Count) { $removedHealth -join '; ' } else { 'none' })")
    [void]$lines.Add('')

    [void]$lines.Add("Steam log match counts: old=$(@($old.SteamLogRows).Count) new=$(@($new.SteamLogRows).Count)")
    return ($lines -join [Environment]::NewLine)
}

function New-SupportPackage {
    param([scriptblock]$Log = { param($m) Write-Host $m })
    New-ToolDirectory
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stage = Join-Path $env:TEMP "FH6_CompanionDoctor_Support_$stamp"
    $zip = Join-Path $script:Config.PackageRoot "FH6_CompanionDoctor_Support_$stamp.zip"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        & $Log 'Collecting text report...'
        $report = Export-FH6Report -Records @(Get-FH6Inventory)
        Copy-Item -LiteralPath $report -Destination (Join-Path $stage (Split-Path $report -Leaf)) -Force

        & $Log 'Collecting dxdiag...'
        $dx = Join-Path $stage 'dxdiag.txt'
        try {
            Start-Process -FilePath 'dxdiag.exe' -ArgumentList @('/t', "`"$dx`"") -Wait -WindowStyle Hidden
        }
        catch {
            "dxdiag failed: $($_.Exception.Message)" | Set-Content -LiteralPath $dx -Encoding UTF8
        }

        & $Log 'Collecting crash events...'
        Get-CrashEventRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'fh6-crash-events.json') -Encoding UTF8
        Get-CrashReportRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'fh6-crash-reports.json') -Encoding UTF8
        Get-HealthRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'health.json') -Encoding UTF8
        Get-DeviceRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'devices.json') -Encoding UTF8
        Get-FH6Inventory | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'inventory.json') -Encoding UTF8
        Get-SteamLogRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'steam-log-matches.json') -Encoding UTF8
        Get-ConflictProcesses | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'conflict-processes.json') -Encoding UTF8
        Get-XboxServiceRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'xbox-services.json') -Encoding UTF8
        Get-VisualCRedistRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'visual-c-redists.json') -Encoding UTF8
        Get-MediaFoundationStatus | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'media-foundation.json') -Encoding UTF8
        Get-WERReportRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'wer-reports.json') -Encoding UTF8
        Get-CrashSignatureAnalysis | Set-Content -LiteralPath (Join-Path $stage 'crash-signature-analysis.txt') -Encoding UTF8
        Get-CrashFingerprintRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'crash-fingerprints.json') -Encoding UTF8
        Get-GuidedWorkflowRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'guided-fix-workflow.json') -Encoding UTF8
        Get-GuidedWorkflowSummary | Set-Content -LiteralPath (Join-Path $stage 'guided-fix-workflow.txt') -Encoding UTF8
        Get-UniversalCrashRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'crashscope-universal-crashes.json') -Encoding UTF8
        Get-UniversalCrashFingerprintRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'crashscope-fingerprints.json') -Encoding UTF8
        Get-UniversalCrashTaxonomyRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'crashscope-taxonomy.json') -Encoding UTF8
        Get-UniversalCrashActionRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'crashscope-action-plan.json') -Encoding UTF8
        Get-UniversalRootCauseScoreRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'crash-intel-root-cause-scores.json') -Encoding UTF8
        Get-UniversalCrashHeatmapRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'crash-intel-heatmap.json') -Encoding UTF8
        Get-CrashIntelChangeCorrelationRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'crash-intel-change-correlation.json') -Encoding UTF8
        Get-CrashIntelligenceSummary -Target $script:Config.ExeName | Set-Content -LiteralPath (Join-Path $stage 'crash-intelligence-summary.txt') -Encoding UTF8
        Get-CrashEvidenceTimelineRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'stability-evidence-timeline.json') -Encoding UTF8
        Get-CrashEvidenceInsightRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'stability-evidence-insights.json') -Encoding UTF8
        Get-CrashStabilityRunbookRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'stability-runbook.json') -Encoding UTF8
        Get-CrashStabilityRunbookText -Target $script:Config.ExeName | Set-Content -LiteralPath (Join-Path $stage 'stability-runbook.txt') -Encoding UTF8
        Get-SecurityBlockEventRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'security-block-events.json') -Encoding UTF8
        Get-ExternalEvidenceToolRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'external-evidence-tools.json') -Encoding UTF8
        Get-LocalDumpConfigRows -Target $script:Config.ExeName | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'localdump-config.json') -Encoding UTF8
        Get-CrashScopeCommandText -Target $script:Config.ExeName | Set-Content -LiteralPath (Join-Path $stage 'crashscope-command-playbook.txt') -Encoding UTF8
        Get-ExpertRecommendationRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'expert-recommendations.json') -Encoding UTF8
        Get-ExpertRecommendationSummary | Set-Content -LiteralPath (Join-Path $stage 'expert-recommendations.txt') -Encoding UTF8
        Get-EventTimelineRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'event-timeline.json') -Encoding UTF8
        Get-EventTimelineSummary | Set-Content -LiteralPath (Join-Path $stage 'event-timeline.txt') -Encoding UTF8
        Get-StartupProgramRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'startup-programs.json') -Encoding UTF8
        Get-ProcessMitigationRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'process-mitigations.json') -Encoding UTF8
        Get-DriverInventoryRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'driver-inventory.json') -Encoding UTF8
        Get-InstallAuditRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'read-only-install-audit.json') -Encoding UTF8
        Get-CrashCorrelationRows -Minutes 10 | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'latest-crash-correlation.json') -Encoding UTF8
        Get-CrashCorrelationSummary -Minutes 10 | Set-Content -LiteralPath (Join-Path $stage 'latest-crash-correlation.txt') -Encoding UTF8
        Get-TelemetryPreflightSummary -Port 5606 | Set-Content -LiteralPath (Join-Path $stage 'telemetry-port-preflight.txt') -Encoding UTF8
        Get-WindowsGamingSettingRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'windows-gaming-settings.json') -Encoding UTF8
        Get-PowerThermalRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'power-thermal.json') -Encoding UTF8
        Get-XboxAppPackageRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'xbox-app-packages.json') -Encoding UTF8
        Get-PathPermissionRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'path-permissions.json') -Encoding UTF8
        Get-BackupIntegrityRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'backup-integrity.json') -Encoding UTF8
        Get-ReliabilityRecordRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'reliability-records.json') -Encoding UTF8
        Get-DisplayTopologyRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'display-topology.json') -Encoding UTF8
        Get-GraphicsPreferenceRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'graphics-preferences.json') -Encoding UTF8
        Get-AppCompatLayerRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'compatibility-layers.json') -Encoding UTF8
        Get-SecurityProductRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'security-products.json') -Encoding UTF8
        Invoke-CompanionSelfTest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'tool-self-test.json') -Encoding UTF8
        Get-ToolSafetyAuditRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'tool-safety-audit.json') -Encoding UTF8
        Get-OfficialReferenceRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'official-references.json') -Encoding UTF8
        $manifestPath = Write-ToolManifest
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stage 'FH6_CompanionDoctor_Manifest.json') -Force

        $snapshot = New-StateSnapshot -Label 'support-package'
        Copy-Item -LiteralPath $snapshot.Json -Destination (Join-Path $stage 'state-snapshot.json') -Force
        Copy-Item -LiteralPath $snapshot.Text -Destination (Join-Path $stage 'state-snapshot.txt') -Force

        if (Test-Path -LiteralPath $script:Config.LocalRoot) {
            $destReports = Join-Path $stage 'FH6-local-crash-reports'
            New-Item -ItemType Directory -Path $destReports -Force | Out-Null
            Get-ChildItem -LiteralPath $script:Config.LocalRoot -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^report_\d{4}_\d{2}_\d{2}_' } |
                Select-Object -First 20 |
                ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destReports $_.Name) -Recurse -Force -ErrorAction SilentlyContinue }
        }

        if ($script:RunLogPath -and (Test-Path -LiteralPath $script:RunLogPath)) {
            Copy-Item -LiteralPath $script:RunLogPath -Destination (Join-Path $stage 'tool-run.log') -Force
        }

        $content = @(Get-ChildItem -LiteralPath $stage -Force | Select-Object -ExpandProperty FullName)
        Compress-Archive -LiteralPath $content -DestinationPath $zip -Force
        & $Log "Support package written: $zip"
        return $zip
    }
    finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Convert-BytesToTelemetryPacket {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if ($Bytes.Length -lt 324) { return $null }
    function I32($o) { [BitConverter]::ToInt32($Bytes, $o) }
    function U32($o) { [BitConverter]::ToUInt32($Bytes, $o) }
    function F32($o) { [BitConverter]::ToSingle($Bytes, $o) }
    function U16($o) { [BitConverter]::ToUInt16($Bytes, $o) }
    function U8($o) { [int]$Bytes[$o] }
    function S8($o) {
        $v = [int]$Bytes[$o]
        if ($v -gt 127) { return ($v - 256) }
        return $v
    }
    $speedMps = F32 256
    [pscustomobject]@{
        ReceivedAt        = Get-Date
        IsRaceOn          = I32 0
        TimestampMS       = U32 4
        EngineMaxRpm      = F32 8
        EngineIdleRpm     = F32 12
        CurrentEngineRpm  = F32 16
        VelocityX         = F32 32
        VelocityY         = F32 36
        VelocityZ         = F32 40
        Yaw               = F32 56
        Pitch             = F32 60
        Roll              = F32 64
        TireSlipFL        = F32 84
        TireSlipFR        = F32 88
        TireSlipRL        = F32 92
        TireSlipRR        = F32 96
        CarOrdinal        = I32 212
        CarClass          = I32 216
        PI                = I32 220
        DrivetrainType    = I32 224
        NumCylinders      = I32 228
        CarGroup          = U32 232
        PositionX         = F32 244
        PositionY         = F32 248
        PositionZ         = F32 252
        SpeedMps          = $speedMps
        SpeedMph          = $speedMps * 2.23693629
        PowerWatts        = F32 260
        TorqueNm          = F32 264
        TireTempFL        = F32 268
        TireTempFR        = F32 272
        TireTempRL        = F32 276
        TireTempRR        = F32 280
        BoostPsi          = F32 284
        Fuel              = F32 288
        DistanceMeters    = F32 292
        BestLap           = F32 296
        LastLap           = F32 300
        CurrentLap        = F32 304
        RaceTime          = F32 308
        LapNumber         = U16 312
        RacePosition      = U8 314
        Accel             = U8 315
        Brake             = U8 316
        Clutch            = U8 317
        HandBrake         = U8 318
        Gear              = U8 319
        Steer             = S8 320
    }
}

function Write-TelemetryCsv {
    param([Parameter(Mandatory)][object]$Packet)
    if (-not $script:TelemetryCsvPath) { return }
    if (-not (Test-Path -LiteralPath $script:TelemetryCsvPath)) {
        'ReceivedAt,TimestampMS,IsRaceOn,SpeedMph,RPM,Gear,Accel,Brake,Steer,CarOrdinal,CarClass,PI,BoostPsi,Fuel,LapNumber,RacePosition,BestLap,LastLap,CurrentLap,RaceTime,PositionX,PositionY,PositionZ' |
            Set-Content -LiteralPath $script:TelemetryCsvPath -Encoding UTF8
    }
    $line = '{0},{1},{2},{3:N2},{4:N0},{5},{6},{7},{8},{9},{10},{11},{12:N2},{13:N3},{14},{15},{16:N3},{17:N3},{18:N3},{19:N3},{20:N2},{21:N2},{22:N2}' -f `
        $Packet.ReceivedAt.ToString('o'), $Packet.TimestampMS, $Packet.IsRaceOn, $Packet.SpeedMph, $Packet.CurrentEngineRpm, $Packet.Gear, $Packet.Accel, $Packet.Brake, $Packet.Steer, $Packet.CarOrdinal, $Packet.CarClass, $Packet.PI, $Packet.BoostPsi, $Packet.Fuel, $Packet.LapNumber, $Packet.RacePosition, $Packet.BestLap, $Packet.LastLap, $Packet.CurrentLap, $Packet.RaceTime, $Packet.PositionX, $Packet.PositionY, $Packet.PositionZ
    Add-Content -LiteralPath $script:TelemetryCsvPath -Value $line -Encoding UTF8
}

function Start-NoGuiScan {
    New-ToolDirectory
    Write-Output (Get-StatusSummary)
    Write-Output ''
    Write-Output 'Health:'
    Get-HealthRows | Format-Table Area, Check, Status, Detail -AutoSize
    Write-Output ''
    Write-Output 'Inventory:'
    Get-FH6Inventory | Sort-Object Category, Path | Format-Table Category, Exists, Cleanable, SizeMB, Items, LastWriteTime, Path -AutoSize
    Write-Output ''
    Write-Output 'Crash summary:'
    Write-Output (Get-CrashSummary)
    Write-Output ''
    Write-Output 'Crash signature analysis:'
    Write-Output (Get-CrashSignatureAnalysis)
    Write-Output ''
    Write-Output 'Expert recommendations:'
    Write-Output (Get-ExpertRecommendationSummary)
    Write-Output ''
    Write-Output 'Event timeline:'
    Write-Output (Get-EventTimelineSummary)
    Write-Output ''
    Write-Output 'Latest crash correlation:'
    Write-Output (Get-CrashCorrelationSummary -Minutes 10)
    Write-Output ''
    Write-Output 'Conflicts:'
    Write-Output (Get-ConflictSummary)
    Write-Output ''
    Write-Output 'Steam logs:'
    Write-Output (Get-SteamLogSummary)
    Write-Output ''
    Write-Output 'Read-only install audit:'
    Get-InstallAuditRows | Format-Table Check, Status, Value, Path -AutoSize
    Write-Output ''
    Write-Output 'Telemetry port preflight:'
    Write-Output (Get-TelemetryPreflightSummary -Port 5606)
    Write-Output ''
    Write-Output 'Windows gaming settings:'
    Get-WindowsGamingSettingRows | Format-Table Area, Name, Value, Interpretation -AutoSize
    Write-Output ''
    Write-Output 'Path permissions:'
    Get-PathPermissionRows | Format-Table Status, Exists, Path, Detail -AutoSize
    Write-Output ''
    Write-Output 'Backup integrity:'
    Get-BackupIntegrityRows | Format-Table Status, Name, Entries, SizeMB, Detail -AutoSize
    Write-Output ''
    Write-Output 'Reliability records:'
    Get-ReliabilityRecordRows | Format-Table TimeGenerated, SourceName, ProductName, EventId -AutoSize
    Write-Output ''
    Write-Output 'Display topology:'
    Get-DisplayTopologyRows | Format-Table Type, Name, Detail, Driver, Status -AutoSize
    Write-Output ''
    Write-Output 'Compatibility layers:'
    Get-AppCompatLayerRows | Format-Table AppPath, Flags, Source -AutoSize
    Write-Output ''
    Write-Output 'Security products:'
    Get-SecurityProductRows | Format-Table Type, DisplayName, ProductState -AutoSize
    if ($Universal) {
        Write-Output ''
        Write-Output 'CrashScope universal action plan:'
        Get-UniversalCrashActionRows -Target $script:Config.ExeName | Format-Table Priority, Area, State, Action, Evidence -AutoSize
        Write-Output ''
        Write-Output 'CrashScope universal fingerprints:'
        Get-UniversalCrashFingerprintRows -Target $script:Config.ExeName | Format-Table Count, App, EventName, Code, Module, Class, Severity -AutoSize
        Write-Output ''
        Write-Output 'Crash Intelligence root-cause scores:'
        Get-UniversalRootCauseScoreRows -Target $script:Config.ExeName | Format-Table Cause, Score, Confidence, Evidence -AutoSize
        Write-Output ''
        Write-Output 'Crash Intelligence heatmap:'
        Get-UniversalCrashHeatmapRows -Target $script:Config.ExeName | Format-Table Count, App, Code, Module, Class, LastSeen, EventsPerDay -AutoSize
        Write-Output ''
        Write-Output 'Crash Intelligence change correlation:'
        Get-CrashIntelChangeCorrelationRows -Target $script:Config.ExeName | Format-Table Time, Type, Name, DaysBeforeCrash, Weight, Detail -AutoSize
        Write-Output ''
        Write-Output 'Stability evidence timeline:'
        Get-CrashEvidenceTimelineRows -Target $script:Config.ExeName | Select-Object -First 30 | Format-Table Time, Lane, Severity, Subject, Signal, Confidence -AutoSize
        Write-Output ''
        Write-Output 'Stability evidence insights:'
        Get-CrashEvidenceInsightRows -Target $script:Config.ExeName | Format-Table Rank, Lane, Status, Count, Signal, NextAction -AutoSize
        Write-Output ''
        Write-Output 'Stability runbook:'
        Get-CrashStabilityRunbookRows -Target $script:Config.ExeName | Format-Table Step, Phase, Mode, Risk, Action -AutoSize
        Write-Output ''
        Write-Output 'Security block/audit events:'
        Get-SecurityBlockEventRows -Target $script:Config.ExeName | Select-Object -First 20 | Format-Table Time, EventId, Category, Process, Level -AutoSize
        Write-Output ''
        Write-Output 'External evidence tools:'
        Get-ExternalEvidenceToolRows | Format-Table Tool, Status, Command, Path -AutoSize
        Write-Output ''
        Write-Output 'LocalDump config:'
        Get-LocalDumpConfigRows -Target $script:Config.ExeName | Format-Table Hive, Scope, Target, Status, DumpFolder, DumpCount, DumpType -AutoSize
    }
}

if ($NoGui) {
    Start-NoGuiScan
    if ($SelfTest) {
        Write-Output ''
        Write-Output 'Self-test:'
        Invoke-CompanionSelfTest | Format-Table Test, Status, Detail -AutoSize
        Write-Output ''
        Write-Output 'Safety audit:'
        Get-ToolSafetyAuditRows | Format-Table Check, Status, Detail -AutoSize
    }
    if ($Snapshot) {
        $snap = New-StateSnapshot -Label 'nogui'
        Write-Output ''
        Write-Output "Snapshot text: $($snap.Text)"
        Write-Output "Snapshot json: $($snap.Json)"
    }
    if ($Diff) {
        Write-Output ''
        Write-Output (Compare-LatestStateSnapshots)
    }
    if ($Manifest) {
        Write-Output ''
        Write-Output "Manifest: $(Write-ToolManifest)"
    }
    if ($PortableBundle) {
        Write-Output ''
        Write-Output "Portable bundle: $(New-PortableToolBundle)"
    }
    return
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and $PSCommandPath) {
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    return
}

New-ToolDirectory
$script:Settings = Read-CompanionSettings
$script:RunLogPath = Join-Path $script:Config.LogRoot ("FH6_CompanionDoctor_Run_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
"FH6 Companion Doctor started: $(Get-Date)" | Set-Content -LiteralPath $script:RunLogPath -Encoding UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "FH6 Companion Doctor v$script:ToolVersion"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1400, 960)
$form.MinimumSize = New-Object System.Drawing.Size(1360, 960)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, 10)
$tabs.Size = New-Object System.Drawing.Size(1360, 675)
$tabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($tabs)

$tabDashboard = New-Object System.Windows.Forms.TabPage
$tabDashboard.Text = 'Dashboard'
$tabDashboard.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabDashboard)

$tabGuided = New-Object System.Windows.Forms.TabPage
$tabGuided.Text = 'Guided Fix'
$tabGuided.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabGuided)

$tabCrashScope = New-Object System.Windows.Forms.TabPage
$tabCrashScope.Text = 'CrashScope'
$tabCrashScope.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabCrashScope)

$tabCrashIntel = New-Object System.Windows.Forms.TabPage
$tabCrashIntel.Text = 'Crash Intel'
$tabCrashIntel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabCrashIntel)

$tabStability = New-Object System.Windows.Forms.TabPage
$tabStability.Text = 'Stability'
$tabStability.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabStability)

$tabHealth = New-Object System.Windows.Forms.TabPage
$tabHealth.Text = 'Health'
$tabHealth.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabHealth)

$tabSaves = New-Object System.Windows.Forms.TabPage
$tabSaves.Text = 'Saves'
$tabSaves.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabSaves)

$tabCrash = New-Object System.Windows.Forms.TabPage
$tabCrash.Text = 'Crash Lab'
$tabCrash.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabCrash)

$tabTelemetry = New-Object System.Windows.Forms.TabPage
$tabTelemetry.Text = 'Telemetry'
$tabTelemetry.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabTelemetry)

$tabDevices = New-Object System.Windows.Forms.TabPage
$tabDevices.Text = 'Devices'
$tabDevices.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabDevices)

$tabLaunch = New-Object System.Windows.Forms.TabPage
$tabLaunch.Text = 'Launch'
$tabLaunch.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabLaunch)

$tabReports = New-Object System.Windows.Forms.TabPage
$tabReports.Text = 'Reports'
$tabReports.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$tabs.Controls.Add($tabReports)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(10, 695)
$txtLog.Size = New-Object System.Drawing.Size(1360, 185)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#101828')
$txtLog.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#E5E7EB')
$txtLog.BorderStyle = 'FixedSingle'
$txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$form.Controls.Add($txtLog)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.SizingGrip = $true
$statusStrip.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#E7ECF3')
$statusGame = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusCrash = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusTelemetry = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusMonitor = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusCrashWatch = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusSession = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusSafety = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusSafety.Spring = $true
$statusSafety.TextAlign = 'MiddleRight'
foreach ($item in @($statusGame,$statusCrash,$statusTelemetry,$statusMonitor,$statusCrashWatch,$statusSession,$statusSafety)) {
    $item.Text = 'Checking...'
    [void]$statusStrip.Items.Add($item)
}
$form.Controls.Add($statusStrip)

function Add-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    $txtLog.AppendText($line + [Environment]::NewLine)
    if ($script:RunLogPath) { Add-Content -LiteralPath $script:RunLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue }
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 30)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#B7C2D0')
    $b.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
    $b.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#172033')
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

function New-Grid {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Location = New-Object System.Drawing.Point($X, $Y)
    $g.Size = New-Object System.Drawing.Size($W, $H)
    $g.AutoSizeColumnsMode = 'Fill'
    $g.SelectionMode = 'FullRowSelect'
    $g.MultiSelect = $false
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.RowHeadersVisible = $false
    $g.BackgroundColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
    $g.BorderStyle = 'FixedSingle'
    $g.GridColor = [System.Drawing.ColorTranslator]::FromHtml('#D9E0EA')
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#243044')
    $g.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $g.DefaultCellStyle.SelectionBackColor = [System.Drawing.ColorTranslator]::FromHtml('#DDEBFF')
    $g.DefaultCellStyle.SelectionForeColor = [System.Drawing.ColorTranslator]::FromHtml('#111827')
    $g.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F7FAFE')
    return $g
}

function Show-TextWindow {
    param([string]$Title, [string]$Text)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = 'CenterParent'
    $dialog.Size = New-Object System.Drawing.Size(980, 650)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Both'
    $box.WordWrap = $false
    $box.Dock = 'Fill'
    $box.Font = New-Object System.Drawing.Font('Consolas', 9)
    $box.Text = $Text
    $dialog.Controls.Add($box)
    [void]$dialog.ShowDialog($form)
}

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 16000
$toolTip.InitialDelay = 450
$toolTip.ReshowDelay = 150
$toolTip.ShowAlways = $true

function Set-Tip {
    param([System.Windows.Forms.Control]$Control, [string]$Text)
    if ($Control -and -not [string]::IsNullOrWhiteSpace($Text)) {
        $toolTip.SetToolTip($Control, $Text)
    }
}

function Set-ButtonRole {
    param(
        [System.Windows.Forms.Button]$Button,
        [ValidateSet('Primary','Danger','Quiet','Default')]
        [string]$Role = 'Default'
    )
    if (-not $Button) { return }
    switch ($Role) {
        'Primary' {
            $Button.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#2563EB')
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#1D4ED8')
        }
        'Danger' {
            $Button.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FEE2E2')
            $Button.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#991B1B')
            $Button.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#FCA5A5')
        }
        'Quiet' {
            $Button.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#EEF2F7')
            $Button.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#334155')
            $Button.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#CBD5E1')
        }
        default {
            $Button.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
            $Button.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#172033')
            $Button.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#B7C2D0')
        }
    }
}

function New-SectionLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 300, [int]$H = 24)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $label.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#182235')
    return $label
}

function New-StatusTile {
    param([string]$Title, [int]$X, [int]$Y, [int]$W = 250, [int]$H = 70)
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $label.BorderStyle = 'FixedSingle'
    $label.BackColor = [System.Drawing.Color]::White
    $label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#111827')
    $label.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $label.AutoEllipsis = $true
    $label.Text = "$Title`r`nChecking..."
    return $label
}

function Set-StatusTile {
    param(
        [System.Windows.Forms.Label]$Tile,
        [string]$Title,
        [string]$Detail,
        [ValidateSet('OK','Warn','Info','Busy')]
        [string]$State = 'Info'
    )
    if (-not $Tile) { return }
    $Tile.Text = "$Title`r`n$Detail"
    switch ($State) {
        'OK' {
            $Tile.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#ECFDF3')
            $Tile.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#065F46')
        }
        'Warn' {
            $Tile.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFF1F2')
            $Tile.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#9F1239')
        }
        'Busy' {
            $Tile.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#EFF6FF')
            $Tile.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#1D4ED8')
        }
        default {
            $Tile.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFC')
            $Tile.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#334155')
        }
    }
}

function Apply-GridStatusStyle {
    param([System.Windows.Forms.DataGridView]$Grid)
    if (-not $Grid) { return }
    foreach ($column in $Grid.Columns) {
        if ($column.Name -match 'Path|Evidence|Detail|Recommendation|Action') { $column.FillWeight = 180 }
        elseif ($column.Name -match 'Time|Modified|Status|Priority|Type|Area') { $column.FillWeight = 80 }
        else { $column.FillWeight = 100 }
    }
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) { continue }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($name in @('Status','Priority','Type','Area','Check','Signal','Finding')) {
            if ($Grid.Columns[$name] -and $null -ne $row.Cells[$name].Value) { [void]$parts.Add([string]$row.Cells[$name].Value) }
        }
        $text = ($parts -join ' ')
        $bg = [System.Drawing.Color]::White
        $fg = [System.Drawing.ColorTranslator]::FromHtml('#111827')
        if ($text -match '\b(1|P1|Warn|Fail|Error|Crash|BEX|Access|Missing|Unavailable|Denied)\b') {
            $bg = [System.Drawing.ColorTranslator]::FromHtml('#FFF1F2')
            $fg = [System.Drawing.ColorTranslator]::FromHtml('#7F1D1D')
        }
        elseif ($text -match '\b(2|P2|Busy|Needs|Enabled|Pending|Compatibility|Security)\b') {
            $bg = [System.Drawing.ColorTranslator]::FromHtml('#FFFBEB')
            $fg = [System.Drawing.ColorTranslator]::FromHtml('#78350F')
        }
        elseif ($text -match '\b(OK|Available|Installed|Present|Passed|Healthy|Ready)\b') {
            $bg = [System.Drawing.ColorTranslator]::FromHtml('#ECFDF3')
            $fg = [System.Drawing.ColorTranslator]::FromHtml('#064E3B')
        }
        elseif ($text -match '\b(Info|Steam Log|Save|Cache|Snapshot)\b') {
            $bg = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFC')
            $fg = [System.Drawing.ColorTranslator]::FromHtml('#334155')
        }
        $row.DefaultCellStyle.BackColor = $bg
        $row.DefaultCellStyle.ForeColor = $fg
    }
}

function Update-GlobalStatus {
    try {
        $running = @(Get-FH6Process).Count -gt 0
        $statusGame.Text = if ($running) { 'Game: running' } else { 'Game: not running' }
        $latest = @(Get-CrashEventRows | Select-Object -First 1)
        $statusCrash.Text = if ($latest.Count) { "Latest crash: $($latest[0].Time) $($latest[0].Code)" } else { 'Latest crash: none found' }
        $statusTelemetry.Text = if ($script:UdpClient) { "Telemetry: listening UDP $([int]$numPort.Value), packets $script:TelemetryPacketCount" } else { "Telemetry: idle UDP $([int]$numPort.Value)" }
        $statusMonitor.Text = if ($script:MonitorActive) { "Monitor: running, ticks $script:MonitorRunCount" } else { 'Monitor: idle' }
        $statusCrashWatch.Text = if ($script:CrashWatchActive) { "Crash Watch: running, new $script:CrashWatchDetectedCount" } else { 'Crash Watch: idle' }
        $statusSession.Text = if ($script:SessionActive) { "Session: $script:SessionId" } else { 'Session: idle' }
        $statusSafety.Text = 'Safety: external-only, user data only'
    }
    catch {
        $statusGame.Text = 'Status refresh warning'
    }
}

# Dashboard tab
$lblDashTitle = New-Object System.Windows.Forms.Label
$lblDashTitle.Text = 'FH6 Companion Doctor'
$lblDashTitle.Location = New-Object System.Drawing.Point(10, 8)
$lblDashTitle.Size = New-Object System.Drawing.Size(330, 30)
$lblDashTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$lblDashTitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#111827')
$tabDashboard.Controls.Add($lblDashTitle)

$lblDashSubtitle = New-Object System.Windows.Forms.Label
$lblDashSubtitle.Text = 'External diagnostics, safe user-data refresh, crash evidence, device checks, and official Data Out telemetry.'
$lblDashSubtitle.Location = New-Object System.Drawing.Point(350, 15)
$lblDashSubtitle.Size = New-Object System.Drawing.Size(820, 22)
$lblDashSubtitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#475569')
$tabDashboard.Controls.Add($lblDashSubtitle)

$tileGame = New-StatusTile 'Game' 10 50 245 72
$tileHealth = New-StatusTile 'Health' 265 50 245 72
$tileCrash = New-StatusTile 'Crash Pattern' 520 50 245 72
$tileSaves = New-StatusTile 'Saves/Cache' 775 50 245 72
$tileTelemetry = New-StatusTile 'Telemetry' 1030 50 245 72
foreach ($tile in @($tileGame,$tileHealth,$tileCrash,$tileSaves,$tileTelemetry)) { $tabDashboard.Controls.Add($tile) }

$lblDashRecs = New-SectionLabel 'Recommended Next Moves' 10 136 360 24
$lblDashTimeline = New-SectionLabel 'Recent Evidence Timeline' 805 136 360 24
$tabDashboard.Controls.Add($lblDashRecs)
$tabDashboard.Controls.Add($lblDashTimeline)

$gridDashboardRecommendations = New-Grid 10 165 780 260
$gridDashboardTimeline = New-Grid 805 165 470 260
$tabDashboard.Controls.Add($gridDashboardRecommendations)
$tabDashboard.Controls.Add($gridDashboardTimeline)

$lblDashSummary = New-SectionLabel 'Current Picture' 10 438 250 24
$tabDashboard.Controls.Add($lblDashSummary)
$txtDashboardSummary = New-Object System.Windows.Forms.TextBox
$txtDashboardSummary.Location = New-Object System.Drawing.Point(10, 465)
$txtDashboardSummary.Size = New-Object System.Drawing.Size(1265, 88)
$txtDashboardSummary.Multiline = $true
$txtDashboardSummary.ReadOnly = $true
$txtDashboardSummary.ScrollBars = 'Vertical'
$txtDashboardSummary.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtDashboardSummary.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
$txtDashboardSummary.BorderStyle = 'FixedSingle'
$tabDashboard.Controls.Add($txtDashboardSummary)

$btnDashRefreshAll = New-Button 'Refresh All' 10 570 125 34
$btnDashRunbook = New-Button 'Runbook' 145 570 105 34
$btnDashDeepFresh = New-Button 'Deep Fresh' 260 570 115 34
$btnDashSession = New-Button 'Session Launch' 385 570 130 34
$btnDashSupport = New-Button 'Support Package' 525 570 145 34
$btnDashTelemetry = New-Button 'Telemetry Check' 680 570 140 34
$btnDashSteamCloud = New-Button 'Steam Cloud' 830 570 125 34
$btnDashReports = New-Button 'Open Reports' 965 570 125 34
$btnDashCrashWatch = New-Button 'Start Watch' 1100 570 120 34
$btnDashActionPlan = New-Button 'Action Plan' 1230 570 120 34
foreach ($b in @($btnDashRefreshAll,$btnDashRunbook,$btnDashDeepFresh,$btnDashSession,$btnDashSupport,$btnDashTelemetry,$btnDashSteamCloud,$btnDashReports,$btnDashCrashWatch,$btnDashActionPlan)) { $tabDashboard.Controls.Add($b) }
Set-ButtonRole $btnDashRefreshAll 'Primary'
Set-ButtonRole $btnDashDeepFresh 'Danger'
Set-ButtonRole $btnDashSession 'Primary'
Set-ButtonRole $btnDashSupport 'Primary'
$lblDashWatch = New-Object System.Windows.Forms.Label
$lblDashWatch.Text = 'Crash Watch'
$lblDashWatch.Location = New-Object System.Drawing.Point(10, 623)
$lblDashWatch.Size = New-Object System.Drawing.Size(90, 24)
$lblDashWatch.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$tabDashboard.Controls.Add($lblDashWatch)
$numCrashWatchSec = New-Object System.Windows.Forms.NumericUpDown
$numCrashWatchSec.Minimum = 10
$numCrashWatchSec.Maximum = 300
$numCrashWatchSec.Value = 15
$numCrashWatchSec.Location = New-Object System.Drawing.Point(105, 620)
$numCrashWatchSec.Size = New-Object System.Drawing.Size(65, 24)
$tabDashboard.Controls.Add($numCrashWatchSec)
$lblCrashWatchSec = New-Object System.Windows.Forms.Label
$lblCrashWatchSec.Text = 'sec'
$lblCrashWatchSec.Location = New-Object System.Drawing.Point(175, 623)
$lblCrashWatchSec.Size = New-Object System.Drawing.Size(32, 24)
$tabDashboard.Controls.Add($lblCrashWatchSec)
$chkCrashWatchPackage = New-Object System.Windows.Forms.CheckBox
$chkCrashWatchPackage.Text = 'Auto support package'
$chkCrashWatchPackage.AutoSize = $true
$chkCrashWatchPackage.Location = New-Object System.Drawing.Point(215, 622)
$tabDashboard.Controls.Add($chkCrashWatchPackage)
$lblCrashWatchStatus = New-Object System.Windows.Forms.Label
$lblCrashWatchStatus.Text = 'Idle'
$lblCrashWatchStatus.Location = New-Object System.Drawing.Point(380, 623)
$lblCrashWatchStatus.Size = New-Object System.Drawing.Size(860, 24)
$lblCrashWatchStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#475569')
$tabDashboard.Controls.Add($lblCrashWatchStatus)

# Guided Fix tab
$lblGuidedTitle = New-SectionLabel 'Evidence-Based Workflow' 10 12 300 26
$tabGuided.Controls.Add($lblGuidedTitle)
$btnGuidedRefresh = New-Button 'Refresh Plan' 310 10 125 32
$btnGuidedExport = New-Button 'Export Plan' 445 10 115 32
$btnGuidedCopy = New-Button 'Copy Top Action' 570 10 135 32
$btnGuidedSupport = New-Button 'Support Package' 715 10 145 32
$btnGuidedSession = New-Button 'Session Launch' 870 10 130 32
$btnGuidedDeepFresh = New-Button 'Deep Fresh' 1010 10 115 32
foreach ($b in @($btnGuidedRefresh,$btnGuidedExport,$btnGuidedCopy,$btnGuidedSupport,$btnGuidedSession,$btnGuidedDeepFresh)) { $tabGuided.Controls.Add($b) }
$gridGuidedPlan = New-Grid 10 55 820 535
$tabGuided.Controls.Add($gridGuidedPlan)
$txtGuidedDetail = New-Object System.Windows.Forms.TextBox
$txtGuidedDetail.Location = New-Object System.Drawing.Point(845, 55)
$txtGuidedDetail.Size = New-Object System.Drawing.Size(485, 535)
$txtGuidedDetail.Multiline = $true
$txtGuidedDetail.ReadOnly = $true
$txtGuidedDetail.ScrollBars = 'Vertical'
$txtGuidedDetail.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtGuidedDetail.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
$txtGuidedDetail.BorderStyle = 'FixedSingle'
$tabGuided.Controls.Add($txtGuidedDetail)

# CrashScope tab
$lblCrashScopeTitle = New-SectionLabel 'Universal CrashScope' 10 12 245 26
$tabCrashScope.Controls.Add($lblCrashScopeTitle)
$lblCrashScopeTarget = New-Object System.Windows.Forms.Label
$lblCrashScopeTarget.Text = 'Target exe:'
$lblCrashScopeTarget.Location = New-Object System.Drawing.Point(260, 17)
$lblCrashScopeTarget.Size = New-Object System.Drawing.Size(75, 22)
$tabCrashScope.Controls.Add($lblCrashScopeTarget)
$txtCrashScopeTarget = New-Object System.Windows.Forms.TextBox
$txtCrashScopeTarget.Text = $script:Config.ExeName
$txtCrashScopeTarget.Location = New-Object System.Drawing.Point(335, 14)
$txtCrashScopeTarget.Size = New-Object System.Drawing.Size(170, 24)
$tabCrashScope.Controls.Add($txtCrashScopeTarget)
$btnCrashScopeScanTarget = New-Button 'Scan Target' 515 10 115 32
$btnCrashScopeScanAll = New-Button 'Scan All' 640 10 95 32
$btnCrashScopeExport = New-Button 'Export' 745 10 85 32
$btnCrashScopeCommands = New-Button 'Commands' 840 10 105 32
$btnCrashScopeTools = New-Button 'Tools' 955 10 75 32
$btnCrashScopeOpen = New-Button 'Open Folder' 1040 10 110 32
foreach ($b in @($btnCrashScopeScanTarget,$btnCrashScopeScanAll,$btnCrashScopeExport,$btnCrashScopeCommands,$btnCrashScopeTools,$btnCrashScopeOpen)) { $tabCrashScope.Controls.Add($b) }

$lblCrashScopeEvents = New-SectionLabel 'Recent Windows Crash Evidence' 10 52 300 24
$lblCrashScopeFingerprints = New-SectionLabel 'Fingerprints and Taxonomy' 690 52 300 24
$tabCrashScope.Controls.Add($lblCrashScopeEvents)
$tabCrashScope.Controls.Add($lblCrashScopeFingerprints)
$gridUniversalCrashes = New-Grid 10 80 670 250
$gridUniversalFingerprints = New-Grid 690 80 640 250
$tabCrashScope.Controls.Add($gridUniversalCrashes)
$tabCrashScope.Controls.Add($gridUniversalFingerprints)

$lblCrashScopePlan = New-SectionLabel 'Action Plan' 10 342 220 24
$lblCrashScopeDetails = New-SectionLabel 'Evidence Tools, LocalDumps, Command Playbook' 690 342 420 24
$tabCrashScope.Controls.Add($lblCrashScopePlan)
$tabCrashScope.Controls.Add($lblCrashScopeDetails)
$gridUniversalPlan = New-Grid 10 370 670 245
$tabCrashScope.Controls.Add($gridUniversalPlan)
$txtCrashScopeDetail = New-Object System.Windows.Forms.TextBox
$txtCrashScopeDetail.Location = New-Object System.Drawing.Point(690, 370)
$txtCrashScopeDetail.Size = New-Object System.Drawing.Size(640, 245)
$txtCrashScopeDetail.Multiline = $true
$txtCrashScopeDetail.ReadOnly = $true
$txtCrashScopeDetail.ScrollBars = 'Both'
$txtCrashScopeDetail.WordWrap = $false
$txtCrashScopeDetail.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtCrashScopeDetail.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
$txtCrashScopeDetail.BorderStyle = 'FixedSingle'
$tabCrashScope.Controls.Add($txtCrashScopeDetail)

# Crash Intel tab
$lblCrashIntelTitle = New-SectionLabel 'Crash Intelligence Workbench' 10 12 300 26
$tabCrashIntel.Controls.Add($lblCrashIntelTitle)
$lblCrashIntelTarget = New-Object System.Windows.Forms.Label
$lblCrashIntelTarget.Text = 'Target exe:'
$lblCrashIntelTarget.Location = New-Object System.Drawing.Point(315, 17)
$lblCrashIntelTarget.Size = New-Object System.Drawing.Size(75, 22)
$tabCrashIntel.Controls.Add($lblCrashIntelTarget)
$txtCrashIntelTarget = New-Object System.Windows.Forms.TextBox
$txtCrashIntelTarget.Text = $script:Config.ExeName
$txtCrashIntelTarget.Location = New-Object System.Drawing.Point(390, 14)
$txtCrashIntelTarget.Size = New-Object System.Drawing.Size(170, 24)
$tabCrashIntel.Controls.Add($txtCrashIntelTarget)
$btnCrashIntelAnalyze = New-Button 'Analyze' 570 10 95 32
$btnCrashIntelAll = New-Button 'All Apps' 675 10 90 32
$btnCrashIntelExport = New-Button 'Export' 775 10 85 32
$btnCrashIntelPlaybook = New-Button 'Playbook' 870 10 100 32
$btnCrashIntelOpen = New-Button 'Open Folder' 980 10 110 32
foreach ($b in @($btnCrashIntelAnalyze,$btnCrashIntelAll,$btnCrashIntelExport,$btnCrashIntelPlaybook,$btnCrashIntelOpen)) { $tabCrashIntel.Controls.Add($b) }

$lblRootCause = New-SectionLabel 'Likely Root Causes' 10 52 230 24
$lblHeatmap = New-SectionLabel 'Crash Heatmap' 690 52 220 24
$tabCrashIntel.Controls.Add($lblRootCause)
$tabCrashIntel.Controls.Add($lblHeatmap)
$gridRootCauseScores = New-Grid 10 80 670 235
$gridCrashHeatmap = New-Grid 690 80 640 235
$tabCrashIntel.Controls.Add($gridRootCauseScores)
$tabCrashIntel.Controls.Add($gridCrashHeatmap)

$lblChanges = New-SectionLabel 'Change Correlation' 10 327 240 24
$lblIntelDetail = New-SectionLabel 'Interpretation' 690 327 220 24
$tabCrashIntel.Controls.Add($lblChanges)
$tabCrashIntel.Controls.Add($lblIntelDetail)
$gridChangeCorrelation = New-Grid 10 355 670 260
$tabCrashIntel.Controls.Add($gridChangeCorrelation)
$txtCrashIntelDetail = New-Object System.Windows.Forms.TextBox
$txtCrashIntelDetail.Location = New-Object System.Drawing.Point(690, 355)
$txtCrashIntelDetail.Size = New-Object System.Drawing.Size(640, 260)
$txtCrashIntelDetail.Multiline = $true
$txtCrashIntelDetail.ReadOnly = $true
$txtCrashIntelDetail.ScrollBars = 'Both'
$txtCrashIntelDetail.WordWrap = $false
$txtCrashIntelDetail.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtCrashIntelDetail.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
$txtCrashIntelDetail.BorderStyle = 'FixedSingle'
$tabCrashIntel.Controls.Add($txtCrashIntelDetail)

# Stability workbench tab
$lblStabilityTitle = New-SectionLabel 'Stability Evidence Workbench' 10 12 330 26
$tabStability.Controls.Add($lblStabilityTitle)
$lblStabilityTarget = New-Object System.Windows.Forms.Label
$lblStabilityTarget.Text = 'Target exe:'
$lblStabilityTarget.Location = New-Object System.Drawing.Point(345, 17)
$lblStabilityTarget.Size = New-Object System.Drawing.Size(75, 22)
$tabStability.Controls.Add($lblStabilityTarget)
$txtStabilityTarget = New-Object System.Windows.Forms.TextBox
$txtStabilityTarget.Text = $script:Config.ExeName
$txtStabilityTarget.Location = New-Object System.Drawing.Point(420, 14)
$txtStabilityTarget.Size = New-Object System.Drawing.Size(170, 24)
$tabStability.Controls.Add($txtStabilityTarget)
$btnStabilityAnalyze = New-Button 'Analyze' 600 10 95 32
$btnStabilityAll = New-Button 'All Apps' 705 10 90 32
$btnStabilityExport = New-Button 'Export' 805 10 85 32
$btnStabilityRunbook = New-Button 'Runbook' 900 10 95 32
$btnStabilitySupport = New-Button 'Support Zip' 1005 10 105 32
$btnStabilityOpen = New-Button 'Open Folder' 1120 10 110 32
foreach ($b in @($btnStabilityAnalyze,$btnStabilityAll,$btnStabilityExport,$btnStabilityRunbook,$btnStabilitySupport,$btnStabilityOpen)) { $tabStability.Controls.Add($b) }

$lblStabilityTimeline = New-SectionLabel 'Unified Evidence Timeline' 10 52 280 24
$lblStabilityInsights = New-SectionLabel 'Evidence Insights' 815 52 220 24
$tabStability.Controls.Add($lblStabilityTimeline)
$tabStability.Controls.Add($lblStabilityInsights)
$gridStabilityTimeline = New-Grid 10 80 795 285
$gridStabilityInsights = New-Grid 815 80 515 285
$tabStability.Controls.Add($gridStabilityTimeline)
$tabStability.Controls.Add($gridStabilityInsights)

$lblStabilityRunbook = New-SectionLabel 'Generated Runbook' 10 377 230 24
$lblStabilityDetail = New-SectionLabel 'Detail' 815 377 160 24
$tabStability.Controls.Add($lblStabilityRunbook)
$tabStability.Controls.Add($lblStabilityDetail)
$gridStabilityRunbook = New-Grid 10 405 795 210
$tabStability.Controls.Add($gridStabilityRunbook)
$txtStabilityDetail = New-Object System.Windows.Forms.TextBox
$txtStabilityDetail.Location = New-Object System.Drawing.Point(815, 405)
$txtStabilityDetail.Size = New-Object System.Drawing.Size(515, 210)
$txtStabilityDetail.Multiline = $true
$txtStabilityDetail.ReadOnly = $true
$txtStabilityDetail.ScrollBars = 'Both'
$txtStabilityDetail.WordWrap = $false
$txtStabilityDetail.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtStabilityDetail.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
$txtStabilityDetail.BorderStyle = 'FixedSingle'
$tabStability.Controls.Add($txtStabilityDetail)

# Health tab
$gridHealth = New-Grid 10 50 1280 520
$tabHealth.Controls.Add($gridHealth)
$btnHealthScan = New-Button 'Run Health Scan' 10 10 140
$tabHealth.Controls.Add($btnHealthScan)
$btnHealthReport = New-Button 'Export Report' 160 10 120
$tabHealth.Controls.Add($btnHealthReport)
$btnHealthSupport = New-Button 'Support Package' 290 10 140
$tabHealth.Controls.Add($btnHealthSupport)
$btnOpenLogs = New-Button 'Open Logs' 440 10 110
$tabHealth.Controls.Add($btnOpenLogs)
$btnShowConflicts = New-Button 'Show Conflicts' 560 10 130
$tabHealth.Controls.Add($btnShowConflicts)
$btnSteamLogs = New-Button 'Steam Logs' 700 10 110
$tabHealth.Controls.Add($btnSteamLogs)
$btnServiceDetails = New-Button 'Services' 820 10 100
$tabHealth.Controls.Add($btnServiceDetails)
$btnRuntimeDetails = New-Button 'Runtimes' 930 10 100
$tabHealth.Controls.Add($btnRuntimeDetails)
$btnRunbook = New-Button 'Runbook' 1040 10 100
$tabHealth.Controls.Add($btnRunbook)
$btnStartup = New-Button 'Startup' 1150 10 100
$tabHealth.Controls.Add($btnStartup)
$btnPlatformAudit = New-Button 'Platform Audit' 10 585 130
$tabHealth.Controls.Add($btnPlatformAudit)
$btnPermissionAudit = New-Button 'Permissions' 150 585 110
$tabHealth.Controls.Add($btnPermissionAudit)
$btnBackupAudit = New-Button 'Backup Audit' 270 585 120
$tabHealth.Controls.Add($btnBackupAudit)
$btnReliability = New-Button 'Reliability' 400 585 110
$tabHealth.Controls.Add($btnReliability)
$btnDisplayAudit = New-Button 'Display/GPU' 520 585 110
$tabHealth.Controls.Add($btnDisplayAudit)
$btnCompatAudit = New-Button 'Compat/GPU Prefs' 640 585 145
$tabHealth.Controls.Add($btnCompatAudit)
$btnSecurityAudit = New-Button 'Security' 795 585 100
$tabHealth.Controls.Add($btnSecurityAudit)

# Saves tab
$listSaves = New-Object System.Windows.Forms.ListView
$listSaves.Location = New-Object System.Drawing.Point(10, 50)
$listSaves.Size = New-Object System.Drawing.Size(1280, 460)
$listSaves.View = [System.Windows.Forms.View]::Details
$listSaves.CheckBoxes = $true
$listSaves.FullRowSelect = $true
$listSaves.GridLines = $true
[void]$listSaves.Columns.Add('Category', 105)
[void]$listSaves.Columns.Add('Exists', 55)
[void]$listSaves.Columns.Add('Size MB', 70)
[void]$listSaves.Columns.Add('Items', 60)
[void]$listSaves.Columns.Add('Modified', 135)
[void]$listSaves.Columns.Add('Risk', 90)
[void]$listSaves.Columns.Add('Path', 810)
$tabSaves.Controls.Add($listSaves)
$chkBackup = New-Object System.Windows.Forms.CheckBox
$chkBackup.Text = 'Back up before delete/rename'
$chkBackup.Checked = $true
$chkBackup.AutoSize = $true
$chkBackup.Location = New-Object System.Drawing.Point(10, 15)
$tabSaves.Controls.Add($chkBackup)
$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = 'Dry run'
$chkDryRun.AutoSize = $true
$chkDryRun.Location = New-Object System.Drawing.Point(230, 15)
$tabSaves.Controls.Add($chkDryRun)
$chkStopGame = New-Object System.Windows.Forms.CheckBox
$chkStopGame.Text = 'Stop FH6 if running'
$chkStopGame.AutoSize = $true
$chkStopGame.Location = New-Object System.Drawing.Point(320, 15)
$tabSaves.Controls.Add($chkStopGame)
$btnSaveScan = New-Button 'Scan' 10 525 90
$btnSelectSaves = New-Button 'Select Saves' 105 525 110
$btnSelectDeep = New-Button 'Select Save+Cache' 220 525 140
$btnClearSel = New-Button 'Clear Selection' 365 525 125
$btnBackup = New-Button 'Backup' 500 525 95
$btnRename = New-Button 'Rename' 600 525 95
$btnDelete = New-Button 'Delete' 700 525 95
$btnFresh = New-Button 'Fresh Start' 800 525 105
$btnDeepFresh = New-Button 'Deep Fresh' 910 525 105
$btnRestore = New-Button 'Restore Backup' 1020 525 125
foreach ($b in @($btnSaveScan,$btnSelectSaves,$btnSelectDeep,$btnClearSel,$btnBackup,$btnRename,$btnDelete,$btnFresh,$btnDeepFresh,$btnRestore)) { $tabSaves.Controls.Add($b) }
$lblMonitor = New-Object System.Windows.Forms.Label
$lblMonitor.Text = 'Monitor:'
$lblMonitor.Location = New-Object System.Drawing.Point(10, 588)
$lblMonitor.Size = New-Object System.Drawing.Size(65, 22)
$tabSaves.Controls.Add($lblMonitor)
$cmbMonitorMode = New-Object System.Windows.Forms.ComboBox
$cmbMonitorMode.DropDownStyle = 'DropDownList'
[void]$cmbMonitorMode.Items.Add('Saves only')
[void]$cmbMonitorMode.Items.Add('Saves + cache')
$cmbMonitorMode.SelectedIndex = 0
$cmbMonitorMode.Location = New-Object System.Drawing.Point(75, 584)
$cmbMonitorMode.Size = New-Object System.Drawing.Size(130, 24)
$tabSaves.Controls.Add($cmbMonitorMode)
$numMonitorSec = New-Object System.Windows.Forms.NumericUpDown
$numMonitorSec.Minimum = 10
$numMonitorSec.Maximum = 600
$numMonitorSec.Value = 30
$numMonitorSec.Location = New-Object System.Drawing.Point(215, 584)
$numMonitorSec.Size = New-Object System.Drawing.Size(70, 24)
$tabSaves.Controls.Add($numMonitorSec)
$btnMonitor = New-Button 'Start Monitor' 295 580 125
$tabSaves.Controls.Add($btnMonitor)
$lblMonitorStatus = New-Object System.Windows.Forms.Label
$lblMonitorStatus.Text = 'Idle'
$lblMonitorStatus.Location = New-Object System.Drawing.Point(430, 588)
$lblMonitorStatus.Size = New-Object System.Drawing.Size(800, 22)
$tabSaves.Controls.Add($lblMonitorStatus)

# Crash tab
$gridCrashReports = New-Grid 10 45 620 500
$gridCrashEvents = New-Grid 640 45 650 500
$tabCrash.Controls.Add($gridCrashReports)
$tabCrash.Controls.Add($gridCrashEvents)
$btnCrashRefresh = New-Button 'Refresh Crashes' 10 10 140
$btnCrashSummary = New-Button 'Show Summary' 160 10 120
$btnCrashAnalysis = New-Button 'Analyze' 290 10 100
$btnWerReports = New-Button 'WER Reports' 400 10 110
$btnTimeline = New-Button 'Timeline' 520 10 100
$btnCorrelation = New-Button 'Correlate' 630 10 100
$btnClearCrashReports = New-Button 'Clear Reports' 740 10 120
$btnFingerprints = New-Button 'Fingerprints' 870 10 120
$tabCrash.Controls.Add($btnCrashRefresh)
$tabCrash.Controls.Add($btnCrashSummary)
$tabCrash.Controls.Add($btnCrashAnalysis)
$tabCrash.Controls.Add($btnWerReports)
$tabCrash.Controls.Add($btnTimeline)
$tabCrash.Controls.Add($btnCorrelation)
$tabCrash.Controls.Add($btnClearCrashReports)
$tabCrash.Controls.Add($btnFingerprints)

# Telemetry tab
$lblTelem = New-Object System.Windows.Forms.Label
$lblTelem.Text = 'Configure FH6: Settings > HUD and Gameplay > Data Out On, IP 127.0.0.1, Port:'
$lblTelem.Location = New-Object System.Drawing.Point(10, 15)
$lblTelem.Size = New-Object System.Drawing.Size(560, 24)
$tabTelemetry.Controls.Add($lblTelem)
$numPort = New-Object System.Windows.Forms.NumericUpDown
$numPort.Minimum = 1024
$numPort.Maximum = 65535
$numPort.Value = 5606
$numPort.Location = New-Object System.Drawing.Point(570, 12)
$numPort.Size = New-Object System.Drawing.Size(90, 24)
$tabTelemetry.Controls.Add($numPort)
$chkTelemCsv = New-Object System.Windows.Forms.CheckBox
$chkTelemCsv.Text = 'Log CSV'
$chkTelemCsv.AutoSize = $true
$chkTelemCsv.Checked = $true
$chkTelemCsv.Location = New-Object System.Drawing.Point(675, 15)
$tabTelemetry.Controls.Add($chkTelemCsv)
$btnTelemStart = New-Button 'Start Listener' 760 10 120
$btnTelemStop = New-Button 'Stop' 885 10 90
$btnOpenTelemetry = New-Button 'Open Telemetry Logs' 985 10 150
$btnTelemPreflight = New-Button 'Port Preflight' 1145 10 120
$tabTelemetry.Controls.Add($btnTelemStart)
$tabTelemetry.Controls.Add($btnTelemStop)
$tabTelemetry.Controls.Add($btnOpenTelemetry)
$tabTelemetry.Controls.Add($btnTelemPreflight)
$txtTelemetry = New-Object System.Windows.Forms.TextBox
$txtTelemetry.Location = New-Object System.Drawing.Point(10, 50)
$txtTelemetry.Size = New-Object System.Drawing.Size(1280, 560)
$txtTelemetry.Multiline = $true
$txtTelemetry.ReadOnly = $true
$txtTelemetry.ScrollBars = 'Vertical'
$txtTelemetry.Font = New-Object System.Drawing.Font('Consolas', 12)
$tabTelemetry.Controls.Add($txtTelemetry)

# Devices tab
$gridDevices = New-Grid 10 45 1280 540
$tabDevices.Controls.Add($gridDevices)
$btnDevicesRefresh = New-Button 'Scan Devices' 10 10 120
$btnDeviceAdvice = New-Button 'Wheel Advice' 140 10 120
$btnDriverInventory = New-Button 'Driver Inventory' 270 10 135
$tabDevices.Controls.Add($btnDevicesRefresh)
$tabDevices.Controls.Add($btnDeviceAdvice)
$tabDevices.Controls.Add($btnDriverInventory)

# Launch tab
$txtPreflight = New-Object System.Windows.Forms.TextBox
$txtPreflight.Location = New-Object System.Drawing.Point(10, 50)
$txtPreflight.Size = New-Object System.Drawing.Size(1280, 520)
$txtPreflight.Multiline = $true
$txtPreflight.ReadOnly = $true
$txtPreflight.ScrollBars = 'Vertical'
$txtPreflight.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabLaunch.Controls.Add($txtPreflight)
$btnPreflight = New-Button 'Run Preflight' 10 10 120
$btnLaunchSteam = New-Button 'Launch FH6' 140 10 110
$btnPreflightLaunch = New-Button 'Preflight + Launch' 260 10 145
$btnSnapshotBefore = New-Button 'Snapshot' 415 10 100
$btnSteamCloudSteps = New-Button 'Steam Cloud Steps' 525 10 150
$btnOpenSteamInstall = New-Button 'Open Install Folder' 685 10 150
$btnInstallAudit = New-Button 'Install Audit' 845 10 120
$btnSessionLaunch = New-Button 'Session Launch' 975 10 130
$btnSessionFinish = New-Button 'Finish Session' 1115 10 130
foreach ($b in @($btnPreflight,$btnLaunchSteam,$btnPreflightLaunch,$btnSnapshotBefore,$btnSteamCloudSteps,$btnOpenSteamInstall,$btnInstallAudit,$btnSessionLaunch,$btnSessionFinish)) { $tabLaunch.Controls.Add($b) }

# Reports tab
$txtReports = New-Object System.Windows.Forms.TextBox
$txtReports.Location = New-Object System.Drawing.Point(10, 50)
$txtReports.Size = New-Object System.Drawing.Size(1280, 520)
$txtReports.Multiline = $true
$txtReports.ReadOnly = $true
$txtReports.ScrollBars = 'Vertical'
$txtReports.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabReports.Controls.Add($txtReports)
$btnExportReport = New-Button 'Export Report' 10 10 120
$btnSupportPackage = New-Button 'Build Support Package' 140 10 170
$btnStateSnapshot = New-Button 'State Snapshot' 320 10 130
$btnSnapshotDiff = New-Button 'Snapshot Diff' 460 10 125
$btnRedactedReport = New-Button 'Redacted Summary' 595 10 145
$btnOpenReports = New-Button 'Open Reports' 750 10 120
$btnOpenPackages = New-Button 'Open Packages' 880 10 130
$btnOpenSnapshots = New-Button 'Open Snapshots' 1020 10 130
$btnOpenSessions = New-Button 'Open Sessions' 1160 10 120
foreach ($b in @($btnExportReport,$btnSupportPackage,$btnStateSnapshot,$btnSnapshotDiff,$btnRedactedReport,$btnOpenReports,$btnOpenPackages,$btnOpenSnapshots,$btnOpenSessions)) { $tabReports.Controls.Add($b) }
$btnSelfTest = New-Button 'Self-Test' 10 585 100
$btnSafetyAudit = New-Button 'Safety Audit' 120 585 120
$btnManifest = New-Button 'Manifest' 250 585 100
$btnOfficialRefs = New-Button 'Official Refs' 360 585 120
$btnPortableBundle = New-Button 'Portable Bundle' 490 585 145
$btnOpenBundles = New-Button 'Open Bundles' 645 585 120
foreach ($b in @($btnSelfTest,$btnSafetyAudit,$btnManifest,$btnOfficialRefs,$btnPortableBundle,$btnOpenBundles)) { $tabReports.Controls.Add($b) }

function Apply-CompanionSettingsToUi {
    try {
        $numPort.Value = [Math]::Min([Math]::Max([int]$script:Settings.TelemetryPort, [int]$numPort.Minimum), [int]$numPort.Maximum)
        $chkTelemCsv.Checked = [bool]$script:Settings.TelemetryCsv
        $chkBackup.Checked = [bool]$script:Settings.BackupByDefault
        $chkDryRun.Checked = [bool]$script:Settings.DryRunByDefault
        $chkStopGame.Checked = [bool]$script:Settings.StopGameByDefault
        $numMonitorSec.Value = [Math]::Min([Math]::Max([int]$script:Settings.MonitorSeconds, [int]$numMonitorSec.Minimum), [int]$numMonitorSec.Maximum)
        $numCrashWatchSec.Value = [Math]::Min([Math]::Max([int]$script:Settings.CrashWatchSeconds, [int]$numCrashWatchSec.Minimum), [int]$numCrashWatchSec.Maximum)
        $chkCrashWatchPackage.Checked = [bool]$script:Settings.CrashWatchAutoPackage
        $modeIndex = $cmbMonitorMode.Items.IndexOf([string]$script:Settings.MonitorMode)
        if ($modeIndex -ge 0) { $cmbMonitorMode.SelectedIndex = $modeIndex }
        for ($i = 0; $i -lt $tabs.TabPages.Count; $i++) {
            if ($tabs.TabPages[$i].Text -eq [string]$script:Settings.LastTab) {
                $tabs.SelectedIndex = $i
                break
            }
        }
    }
    catch {
        Add-Log "Settings apply warning: $($_.Exception.Message)"
    }
}

function Save-CompanionSettingsFromUi {
    $settings = [pscustomobject]@{
        TelemetryPort     = [int]$numPort.Value
        TelemetryCsv      = [bool]$chkTelemCsv.Checked
        BackupByDefault   = [bool]$chkBackup.Checked
        DryRunByDefault   = [bool]$chkDryRun.Checked
        StopGameByDefault = [bool]$chkStopGame.Checked
        MonitorMode       = [string]$cmbMonitorMode.SelectedItem
        MonitorSeconds    = [int]$numMonitorSec.Value
        CrashWatchSeconds = [int]$numCrashWatchSec.Value
        CrashWatchAutoPackage = [bool]$chkCrashWatchPackage.Checked
        LastTab           = [string]$tabs.SelectedTab.Text
    }
    Write-CompanionSettings -Settings $settings
}

function Refresh-SaveInventory {
    $listSaves.Items.Clear()
    $script:ItemsById = @{}
    $script:Items = @(Get-FH6Inventory)
    foreach ($record in $script:Items | Sort-Object Category, Path) {
        $row = New-Object System.Windows.Forms.ListViewItem($record.Category)
        $row.Checked = [bool]($record.DefaultSelected -and $record.Exists -and $record.Cleanable)
        $row.Tag = $record.Id
        [void]$row.SubItems.Add([string]$record.Exists)
        [void]$row.SubItems.Add([string]$record.SizeMB)
        [void]$row.SubItems.Add([string]$record.Items)
        $modified = if ($record.LastWriteTime) { $record.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
        [void]$row.SubItems.Add($modified)
        [void]$row.SubItems.Add($record.Risk)
        [void]$row.SubItems.Add($record.Path)
        if (-not $record.Exists) {
            $row.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#64748B')
            $row.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFC')
        }
        elseif ($record.Risk -match 'High') {
            $row.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFF1F2')
            $row.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#7F1D1D')
        }
        elseif ($record.Risk -match 'Medium') {
            $row.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFBEB')
            $row.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#78350F')
        }
        else {
            $row.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#ECFDF3')
            $row.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#064E3B')
        }
        if (-not $record.Cleanable) { $row.ForeColor = [System.Drawing.Color]::Gray; $row.Checked = $false }
        [void]$listSaves.Items.Add($row)
        $script:ItemsById[$record.Id] = $record
    }
    Add-Log "Save inventory refreshed: $($script:Items.Count) records."
    Update-GlobalStatus
}

function Get-SelectedSaveRecords {
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($row in $listSaves.Items) {
        if ($row.Checked -and $script:ItemsById.ContainsKey($row.Tag)) {
            $record = $script:ItemsById[$row.Tag]
            if ($record.Cleanable) { [void]$selected.Add($record) }
        }
    }
    return $selected.ToArray()
}

function Select-SaveCategories {
    param([string[]]$Categories)
    foreach ($row in $listSaves.Items) {
        if ($script:ItemsById.ContainsKey($row.Tag)) {
            $record = $script:ItemsById[$row.Tag]
            $row.Checked = ($record.Cleanable -and $record.Exists -and ($Categories -contains $record.Category))
        }
    }
}

function Invoke-SaveAction {
    param([string]$Action, [object[]]$Records)
    if ($Records.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Nothing selected.', 'FH6 Companion Doctor', 'OK', 'Information') | Out-Null
        return
    }
    $preview = ($Records | Select-Object -First 8 | ForEach-Object { " - $($_.Path)" }) -join [Environment]::NewLine
    if ($Records.Count -gt 8) { $preview += [Environment]::NewLine + " - ...and $($Records.Count - 8) more" }
    $answer = [System.Windows.Forms.MessageBox]::Show("$Action $($Records.Count) item(s)?`n`n$preview`n`nSteam Cloud should be off before deleting FH6 saves.", "Confirm $Action", 'OKCancel', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { Add-Log "$Action cancelled."; return }
    try {
        Invoke-Preflight -StopGame $chkStopGame.Checked -Log ${function:Add-Log} | Out-Null
        if ($chkBackup.Checked -and -not $chkDryRun.Checked) { Backup-FH6Targets -Records $Records -Log ${function:Add-Log} | Out-Null }
        elseif ($chkBackup.Checked -and $chkDryRun.Checked) { Add-Log 'DRY RUN backup: would create a zip backup first.' }
        if ($Action -eq 'Rename') { Rename-FH6Targets -Records $Records -DryRun $chkDryRun.Checked -Log ${function:Add-Log} }
        elseif ($Action -eq 'Delete') { Remove-FH6Targets -Records $Records -DryRun $chkDryRun.Checked -Log ${function:Add-Log} }
        Refresh-SaveInventory
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "$Action failed", 'OK', 'Error') | Out-Null
        Add-Log "$Action failed: $($_.Exception.Message)"
    }
}

function Refresh-Health {
    $gridHealth.DataSource = @(Get-HealthRows)
    Apply-GridStatusStyle $gridHealth
    Update-GlobalStatus
    Add-Log 'Health scan complete.'
}

function Refresh-Crashes {
    $gridCrashReports.DataSource = @(Get-CrashReportRows)
    $gridCrashEvents.DataSource = @(Get-CrashEventRows)
    Apply-GridStatusStyle $gridCrashReports
    Apply-GridStatusStyle $gridCrashEvents
    Update-GlobalStatus
    Add-Log 'Crash Lab refreshed.'
}

function Refresh-Devices {
    $gridDevices.DataSource = @(Get-DeviceRows)
    Apply-GridStatusStyle $gridDevices
    Update-GlobalStatus
    Add-Log 'Device scan complete.'
}

function Refresh-GuidedWorkflow {
    $rows = @(Get-GuidedWorkflowRows)
    $gridGuidedPlan.DataSource = $rows
    Apply-GridStatusStyle $gridGuidedPlan
    $txtGuidedDetail.Text = Get-GuidedWorkflowSummary
    Add-Log 'Guided Fix workflow refreshed.'
}

function Refresh-CrashScope {
    param([switch]$All)
    $target = if ($All) { '' } else { [string]$txtCrashScopeTarget.Text }
    if (-not $All -and [string]::IsNullOrWhiteSpace($target)) { $target = $script:Config.ExeName; $txtCrashScopeTarget.Text = $target }
    $script:CrashScopeCurrentTarget = $target
    $events = @(Get-UniversalCrashRows -Target $target)
    $fingerprints = @(Get-UniversalCrashFingerprintRows -Target $target)
    $plan = @(Get-UniversalCrashActionRows -Target $target)
    $gridUniversalCrashes.DataSource = $events
    $gridUniversalFingerprints.DataSource = $fingerprints
    $gridUniversalPlan.DataSource = $plan
    Apply-GridStatusStyle $gridUniversalCrashes
    Apply-GridStatusStyle $gridUniversalFingerprints
    Apply-GridStatusStyle $gridUniversalPlan
    $toolText = "Evidence Tool Readiness`r`n=======================`r`n" + ((Get-ExternalEvidenceToolRows | Format-Table -AutoSize | Out-String).Trim())
    $dumpText = "LocalDump Config`r`n================`r`n" + ((Get-LocalDumpConfigRows -Target $(if ($target) { $target } else { $script:Config.ExeName }) | Format-Table -AutoSize | Out-String).Trim())
    $txtCrashScopeDetail.Text = @(
        "Target: $(if ($target) { $target } else { '<all application crashes>' })",
        "Events: $($events.Count)",
        "Fingerprints: $(@($fingerprints | Where-Object { $_.Count -gt 0 }).Count)",
        '',
        $toolText,
        '',
        $dumpText
    ) -join [Environment]::NewLine
    Add-Log "CrashScope refreshed. Target=$(if ($target) { $target } else { '<all>' }) Events=$($events.Count)"
}

function Refresh-CrashIntel {
    param([switch]$All)
    $target = if ($All) { '' } else { [string]$txtCrashIntelTarget.Text }
    if (-not $All -and [string]::IsNullOrWhiteSpace($target)) { $target = $script:Config.ExeName; $txtCrashIntelTarget.Text = $target }
    $script:CrashIntelCurrentTarget = $target
    $scores = @(Get-UniversalRootCauseScoreRows -Target $target)
    $heatmap = @(Get-UniversalCrashHeatmapRows -Target $target)
    $changes = @(Get-CrashIntelChangeCorrelationRows -Target $target)
    $gridRootCauseScores.DataSource = $scores
    $gridCrashHeatmap.DataSource = $heatmap
    $gridChangeCorrelation.DataSource = $changes
    Apply-GridStatusStyle $gridRootCauseScores
    Apply-GridStatusStyle $gridCrashHeatmap
    Apply-GridStatusStyle $gridChangeCorrelation
    $txtCrashIntelDetail.Text = Get-CrashIntelligenceSummary -Target $target
    Add-Log "Crash Intel refreshed. Target=$(if ($target) { $target } else { '<all>' }) Scores=$($scores.Count) Heatmap=$($heatmap.Count)"
}

function Refresh-StabilityWorkbench {
    param([switch]$All)
    $script:StabilityCache.Clear()
    $target = if ($All) { '' } else { [string]$txtStabilityTarget.Text }
    if (-not $All -and [string]::IsNullOrWhiteSpace($target)) { $target = $script:Config.ExeName; $txtStabilityTarget.Text = $target }
    $script:StabilityCurrentTarget = $target
    $timeline = @(Get-CrashEvidenceTimelineRows -Target $target)
    $insights = @(Get-CrashEvidenceInsightRows -Target $target)
    $runbook = @(Get-CrashStabilityRunbookRows -Target $target)
    $gridStabilityTimeline.DataSource = $timeline
    $gridStabilityInsights.DataSource = $insights
    $gridStabilityRunbook.DataSource = $runbook
    Apply-GridStatusStyle $gridStabilityTimeline
    Apply-GridStatusStyle $gridStabilityInsights
    Apply-GridStatusStyle $gridStabilityRunbook
    $txtStabilityDetail.Text = Get-CrashStabilityRunbookText -Target $target
    Add-Log "Stability workbench refreshed. Target=$(if ($target) { $target } else { '<all>' }) Timeline=$($timeline.Count) Insights=$($insights.Count) Runbook=$($runbook.Count)"
}

function Update-Dashboard {
    try {
        $health = @(Get-HealthRows)
        $healthWarnings = @($health | Where-Object { $_.Status -match 'Warn|Fail|Error|Missing|Denied|Unavailable' })
        $inventory = @(Get-FH6Inventory)
        $existingCleanable = @($inventory | Where-Object { $_.Exists -and $_.Cleanable })
        $saveItems = @($inventory | Where-Object { $_.Exists -and $_.Category -eq 'Save' })
        $cacheItems = @($inventory | Where-Object { $_.Exists -and $_.Category -eq 'Cache/Settings' })
        $latestCrash = @(Get-CrashEventRows | Select-Object -First 1)
        $recommendations = @(Get-ExpertRecommendationRows | Select-Object -First 8)
        $timeline = @(Get-EventTimelineRows | Select-Object -First 12)
        $running = @(Get-FH6Process).Count -gt 0
        $telemetryState = if ($script:UdpClient) { "Listening, $script:TelemetryPacketCount packets" } else { "Idle, UDP $([int]$numPort.Value)" }

        Set-StatusTile $tileGame 'Game' ($(if ($running) { 'Running' } else { 'Not running' })) ($(if ($running) { 'Busy' } else { 'Info' }))
        Set-StatusTile $tileHealth 'Health' ($(if ($healthWarnings.Count) { "$($healthWarnings.Count) warning(s)" } else { 'No urgent warnings' })) ($(if ($healthWarnings.Count) { 'Warn' } else { 'OK' }))
        Set-StatusTile $tileCrash 'Crash Pattern' ($(if ($latestCrash.Count) { "$($latestCrash[0].Code) at $($latestCrash[0].Time)" } else { 'No recent crash event' })) ($(if ($latestCrash.Count) { 'Warn' } else { 'OK' }))
        Set-StatusTile $tileSaves 'Saves/Cache' "$($saveItems.Count) save, $($cacheItems.Count) cache roots" ($(if ($existingCleanable.Count) { 'Info' } else { 'OK' }))
        Set-StatusTile $tileTelemetry 'Telemetry' $telemetryState ($(if ($script:UdpClient) { 'Busy' } else { 'Info' }))

        $gridDashboardRecommendations.DataSource = $recommendations
        $gridDashboardTimeline.DataSource = $timeline
        Apply-GridStatusStyle $gridDashboardRecommendations
        Apply-GridStatusStyle $gridDashboardTimeline

        $topAction = if ($recommendations.Count) { "[P$($recommendations[0].Priority)] $($recommendations[0].Area): $($recommendations[0].Action)" } else { 'No recommendation rows generated yet.' }
        $latestText = if ($latestCrash.Count) { "$($latestCrash[0].Time) $($latestCrash[0].EventName) $($latestCrash[0].Code) module=$($latestCrash[0].Module)" } else { 'No FH6 crash event found in the recent Event Viewer scan.' }
        $txtDashboardSummary.Text = @(
            "Top action: $topAction",
            "Latest crash: $latestText",
            "Crash Watch: $script:CrashWatchLastAction",
            "User-data roots found: $($existingCleanable.Count) cleanable item(s). Backups stay in $($script:Config.BackupRoot)",
            "Steam Cloud reminder: turn it off before delete-based fresh-start tests. Safety boundary: no game install, EXE, memory, or gameplay automation."
        ) -join [Environment]::NewLine
        Update-GlobalStatus
    }
    catch {
        $txtDashboardSummary.Text = "Dashboard refresh failed: $($_.Exception.Message)"
        Add-Log "Dashboard refresh failed: $($_.Exception.Message)"
    }
}

function Refresh-AllViews {
    Refresh-Health
    Refresh-SaveInventory
    Refresh-Crashes
    Refresh-Devices
    Refresh-GuidedWorkflow
    Refresh-CrashScope
    Refresh-CrashIntel
    Refresh-StabilityWorkbench
    $txtPreflight.Text = Get-PreflightText
    Update-Dashboard
    Add-Log 'All dashboard views refreshed.'
}

function Get-PreflightText {
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('== Preflight ==')
    [void]$lines.Add((Get-StatusSummary))
    [void]$lines.Add('')
    [void]$lines.Add('== Health Checks ==')
    foreach ($h in Get-HealthRows) { [void]$lines.Add("[$($h.Status)] $($h.Area) / $($h.Check): $($h.Detail)") }
    [void]$lines.Add('')
    [void]$lines.Add('== Conflict Processes ==')
    [void]$lines.Add((Get-ConflictSummary))
    [void]$lines.Add('')
    [void]$lines.Add('== Latest Crashes ==')
    [void]$lines.Add((Get-CrashSummary))
    return ($lines -join [Environment]::NewLine)
}

function Start-FH6LaunchSession {
    if ($script:SessionActive) {
        throw "A session is already active: $script:SessionId"
    }
    New-ToolDirectory
    $script:SessionId = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:SessionStart = Get-Date
    $script:SessionSeenProcess = $false
    $script:SessionActive = $true
    $sessionDir = Join-Path $script:Config.SessionRoot "FH6_Session_$script:SessionId"
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    $script:SessionBeforeSnapshot = New-StateSnapshot -Label "session_${script:SessionId}_before"
    Copy-Item -LiteralPath $script:SessionBeforeSnapshot.Json -Destination (Join-Path $sessionDir 'before.json') -Force
    Copy-Item -LiteralPath $script:SessionBeforeSnapshot.Text -Destination (Join-Path $sessionDir 'before.txt') -Force
    (Get-PreflightText) | Set-Content -LiteralPath (Join-Path $sessionDir 'preflight.txt') -Encoding UTF8
    Start-Process "steam://run/$($script:Config.AppId)"
    Add-Log "Session $script:SessionId started and FH6 launch requested."
    return $sessionDir
}

function Complete-FH6LaunchSession {
    param([string]$Reason = 'manual')
    if (-not $script:SessionActive -or -not $script:SessionId) {
        throw 'No active FH6 launch session.'
    }
    $sessionDir = Join-Path $script:Config.SessionRoot "FH6_Session_$script:SessionId"
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    $after = New-StateSnapshot -Label "session_${script:SessionId}_after_$Reason"
    Copy-Item -LiteralPath $after.Json -Destination (Join-Path $sessionDir 'after.json') -Force
    Copy-Item -LiteralPath $after.Text -Destination (Join-Path $sessionDir 'after.txt') -Force
    (Compare-LatestStateSnapshots) | Set-Content -LiteralPath (Join-Path $sessionDir 'snapshot-diff.txt') -Encoding UTF8
    (Get-CrashCorrelationSummary -Minutes 10) | Set-Content -LiteralPath (Join-Path $sessionDir 'latest-crash-correlation.txt') -Encoding UTF8
    (Get-ExpertRecommendationSummary) | Set-Content -LiteralPath (Join-Path $sessionDir 'expert-recommendations.txt') -Encoding UTF8
    (Get-EventTimelineSummary) | Set-Content -LiteralPath (Join-Path $sessionDir 'event-timeline.txt') -Encoding UTF8
    [pscustomobject]@{
        SessionId   = $script:SessionId
        StartedAt   = $script:SessionStart
        FinishedAt  = Get-Date
        Reason      = $Reason
        SawProcess  = $script:SessionSeenProcess
        SessionPath = $sessionDir
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $sessionDir 'session.json') -Encoding UTF8
    Add-Log "Session $script:SessionId finished. Reason=$Reason Path=$sessionDir"
    $script:SessionActive = $false
    $script:SessionId = $null
    $script:SessionStart = $null
    $script:SessionBeforeSnapshot = $null
    $script:SessionSeenProcess = $false
    return $sessionDir
}

function Invoke-CrashWatchTick {
    try {
        $latest = @(Get-LatestCrashEvidenceItem | Select-Object -First 1)
        if ($latest.Count -eq 0) {
            $script:CrashWatchLastAction = "No crash evidence found at $(Get-Date -Format 'HH:mm:ss')"
            $lblCrashWatchStatus.Text = $script:CrashWatchLastAction
            Update-GlobalStatus
            return
        }
        $latestTime = [datetime]$latest[0].Time
        if (-not $script:CrashWatchLastTime) {
            $script:CrashWatchLastTime = $latestTime
            $script:CrashWatchLastAction = "Anchored at $latestTime ($($latest[0].Signal))"
            $lblCrashWatchStatus.Text = $script:CrashWatchLastAction
            Update-GlobalStatus
            return
        }
        if ($latestTime -le [datetime]$script:CrashWatchLastTime) {
            $script:CrashWatchLastAction = "Watching. Latest still $latestTime. Checked $(Get-Date -Format 'HH:mm:ss')"
            $lblCrashWatchStatus.Text = $script:CrashWatchLastAction
            Update-GlobalStatus
            return
        }

        $script:CrashWatchLastTime = $latestTime
        $script:CrashWatchDetectedCount++
        Add-Log "Crash Watch detected new evidence: $($latest[0].Source) $($latest[0].Signal) at $latestTime"
        $snapshot = New-StateSnapshot -Label 'crash-watch-new-evidence'
        $artifactLines = New-Object System.Collections.Generic.List[string]
        [void]$artifactLines.Add("New crash evidence detected: $latestTime")
        [void]$artifactLines.Add("Source: $($latest[0].Source)")
        [void]$artifactLines.Add("Signal: $($latest[0].Signal)")
        [void]$artifactLines.Add("Detail: $($latest[0].Detail)")
        [void]$artifactLines.Add("Snapshot: $($snapshot.Text)")
        $packagePath = ''
        if ($chkCrashWatchPackage.Checked) {
            $packagePath = New-SupportPackage -Log ${function:Add-Log}
            [void]$artifactLines.Add("Support package: $packagePath")
        }
        [void]$artifactLines.Add('')
        [void]$artifactLines.Add((Get-CrashCorrelationSummary -Minutes 10))
        $watchReport = Join-Path $script:Config.ReportRoot ("FH6_CrashWatch_Detection_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        ($artifactLines -join [Environment]::NewLine) | Set-Content -LiteralPath $watchReport -Encoding UTF8
        $script:CrashWatchLastAction = if ($packagePath) { "Detected new crash; package written. $watchReport" } else { "Detected new crash; snapshot/report written. $watchReport" }
        $lblCrashWatchStatus.Text = $script:CrashWatchLastAction
        Refresh-Crashes
        Refresh-GuidedWorkflow
        Update-Dashboard
        [System.Windows.Forms.MessageBox]::Show("Crash Watch detected new FH6 crash evidence.`n`n$watchReport", 'Crash Watch', 'OK', 'Information') | Out-Null
    }
    catch {
        $script:CrashWatchLastAction = "Crash Watch warning: $($_.Exception.Message)"
        $lblCrashWatchStatus.Text = $script:CrashWatchLastAction
        Add-Log $script:CrashWatchLastAction
    }
}

function Invoke-MonitorCleanup {
    try {
        $script:MonitorRunCount++
        $categories = if ($cmbMonitorMode.SelectedItem -eq 'Saves + cache') { @('Save','Cache/Settings') } else { @('Save') }
        $records = @(Get-FH6Inventory | Where-Object { $_.Exists -and $_.Cleanable -and ($categories -contains $_.Category) })
        if (@(Get-FH6Process).Count -gt 0 -and -not $chkStopGame.Checked) {
            $script:MonitorLastAction = 'Skipped: FH6 running'
            Add-Log "Monitor tick #$($script:MonitorRunCount): skipped because FH6 is running."
            return
        }
        if ($records.Count -eq 0) {
            $script:MonitorLastAction = 'Nothing found'
            Add-Log "Monitor tick #$($script:MonitorRunCount): nothing found."
            return
        }
        Add-Log "Monitor tick #$($script:MonitorRunCount): cleaning $($records.Count) item(s)."
        Invoke-Preflight -StopGame $chkStopGame.Checked -Log ${function:Add-Log} | Out-Null
        if ($chkBackup.Checked -and -not $chkDryRun.Checked) { Backup-FH6Targets -Records $records -Log ${function:Add-Log} | Out-Null }
        Remove-FH6Targets -Records $records -DryRun $chkDryRun.Checked -Log ${function:Add-Log}
        $script:MonitorLastAction = "Cleaned $($records.Count)"
        Refresh-SaveInventory
    }
    catch {
        $script:MonitorLastAction = "Error: $($_.Exception.Message)"
        Add-Log "Monitor error: $($_.Exception.Message)"
    }
    finally {
        $lblMonitorStatus.Text = "Ticks: $($script:MonitorRunCount). Last: $script:MonitorLastAction"
    }
}

$monitorTimer = New-Object System.Windows.Forms.Timer
$monitorTimer.Interval = [int]$numMonitorSec.Value * 1000
$monitorTimer.Add_Tick({
    if (-not $script:MonitorActive) { return }
    $monitorTimer.Stop()
    try { Invoke-MonitorCleanup } finally {
        $monitorTimer.Interval = [int]$numMonitorSec.Value * 1000
        if ($script:MonitorActive) { $monitorTimer.Start() }
    }
})

$crashWatchTimer = New-Object System.Windows.Forms.Timer
$crashWatchTimer.Interval = [int]$numCrashWatchSec.Value * 1000
$crashWatchTimer.Add_Tick({
    if (-not $script:CrashWatchActive) { return }
    $crashWatchTimer.Stop()
    try { Invoke-CrashWatchTick } finally {
        $crashWatchTimer.Interval = [int]$numCrashWatchSec.Value * 1000
        if ($script:CrashWatchActive) { $crashWatchTimer.Start() }
    }
})

$sessionTimer = New-Object System.Windows.Forms.Timer
$sessionTimer.Interval = 5000
$sessionTimer.Add_Tick({
    if (-not $script:SessionActive) { return }
    try {
        $running = @(Get-FH6Process).Count -gt 0
        if ($running) {
            $script:SessionSeenProcess = $true
            return
        }
        $elapsed = if ($script:SessionStart) { ((Get-Date) - $script:SessionStart).TotalSeconds } else { 0 }
        if ($script:SessionSeenProcess -and -not $running) {
            $sessionDir = Complete-FH6LaunchSession -Reason 'process-ended'
            $txtPreflight.Text = "Session auto-finished after FH6 process ended.`r`n$sessionDir`r`n`r`n" + (Get-PreflightText)
        }
        elseif ($elapsed -gt 900) {
            $sessionDir = Complete-FH6LaunchSession -Reason 'timeout'
            $txtPreflight.Text = "Session auto-finished after 15 minute timeout.`r`n$sessionDir`r`n`r`n" + (Get-PreflightText)
        }
    }
    catch {
        Add-Log "Session timer warning: $($_.Exception.Message)"
    }
})

$telemetryTimer = New-Object System.Windows.Forms.Timer
$telemetryTimer.Interval = 100
$telemetryTimer.Add_Tick({
    if (-not $script:UdpClient) { return }
    try {
        while ($script:UdpClient -and $script:UdpClient.Available -gt 0) {
            $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $bytes = $script:UdpClient.Receive([ref]$remote)
            $packet = Convert-BytesToTelemetryPacket -Bytes $bytes
            if (-not $packet) { continue }
            $script:TelemetryPacketCount++
            $script:TelemetryLastPacket = $packet
            if ($chkTelemCsv.Checked) { Write-TelemetryCsv -Packet $packet }
            $txtTelemetry.Text = @"
Packets: $script:TelemetryPacketCount
Last packet: $($packet.ReceivedAt)
Race on: $($packet.IsRaceOn)   Timestamp: $($packet.TimestampMS)

Speed: {0:N1} mph     RPM: {1:N0} / {2:N0}     Gear: {3}
Inputs: Accel={4} Brake={5} Clutch={6} HandBrake={7} Steer={8}

CarOrdinal: {9}   Class: {10}   PI: {11}   Drivetrain: {12}   Cylinders: {13}
Boost: {14:N2} psi   Fuel: {15:P1}

Lap: {16}   Position: {17}   Best: {18:N3}s   Last: {19:N3}s   Current: {20:N3}s   RaceTime: {21:N3}s

Tire slip ratio FL/FR/RL/RR: {22:N3} / {23:N3} / {24:N3} / {25:N3}
Tire temp FL/FR/RL/RR: {26:N1} / {27:N1} / {28:N1} / {29:N1}

World position: X={30:N2} Y={31:N2} Z={32:N2}
Velocity vector: X={33:N2} Y={34:N2} Z={35:N2}
Yaw/Pitch/Roll: {36:N3} / {37:N3} / {38:N3}
"@ -f $packet.SpeedMph, $packet.CurrentEngineRpm, $packet.EngineMaxRpm, $packet.Gear,
    $packet.Accel, $packet.Brake, $packet.Clutch, $packet.HandBrake, $packet.Steer,
    $packet.CarOrdinal, $packet.CarClass, $packet.PI, $packet.DrivetrainType, $packet.NumCylinders,
    $packet.BoostPsi, $packet.Fuel, $packet.LapNumber, $packet.RacePosition, $packet.BestLap, $packet.LastLap, $packet.CurrentLap, $packet.RaceTime,
    $packet.TireSlipFL, $packet.TireSlipFR, $packet.TireSlipRL, $packet.TireSlipRR,
    $packet.TireTempFL, $packet.TireTempFR, $packet.TireTempRL, $packet.TireTempRR,
    $packet.PositionX, $packet.PositionY, $packet.PositionZ,
    $packet.VelocityX, $packet.VelocityY, $packet.VelocityZ,
    $packet.Yaw, $packet.Pitch, $packet.Roll
        }
    }
    catch {
        Add-Log "Telemetry read error: $($_.Exception.Message)"
    }
})

$uiStatusTimer = New-Object System.Windows.Forms.Timer
$uiStatusTimer.Interval = 2500
$uiStatusTimer.Add_Tick({ Update-GlobalStatus })

function Initialize-UiGuidance {
    foreach ($grid in @($gridDashboardRecommendations,$gridDashboardTimeline,$gridGuidedPlan,$gridUniversalCrashes,$gridUniversalFingerprints,$gridUniversalPlan,$gridRootCauseScores,$gridCrashHeatmap,$gridChangeCorrelation,$gridStabilityTimeline,$gridStabilityInsights,$gridStabilityRunbook,$gridHealth,$gridCrashReports,$gridCrashEvents,$gridDevices)) {
        $grid.Add_DataBindingComplete({ param($sender, $eventArgs) Apply-GridStatusStyle $sender })
    }

    foreach ($button in @($btnHealthScan,$btnSaveScan,$btnCrashRefresh,$btnDevicesRefresh,$btnPreflight,$btnExportReport,$btnStateSnapshot,$btnSnapshotDiff,$btnOpenReports,$btnOpenPackages,$btnOpenSnapshots,$btnOpenSessions,$btnOpenLogs,$btnOpenTelemetry,$btnOpenBundles,$btnDashActionPlan,$btnGuidedRefresh,$btnGuidedExport,$btnGuidedCopy,$btnFingerprints,$btnCrashScopeScanAll,$btnCrashScopeExport,$btnCrashScopeCommands,$btnCrashScopeTools,$btnCrashScopeOpen,$btnCrashIntelAll,$btnCrashIntelExport,$btnCrashIntelPlaybook,$btnCrashIntelOpen,$btnStabilityAll,$btnStabilityExport,$btnStabilityRunbook,$btnStabilityOpen)) {
        Set-ButtonRole $button 'Quiet'
    }
    foreach ($button in @($btnHealthReport,$btnHealthSupport,$btnSupportPackage,$btnSessionLaunch,$btnPreflightLaunch,$btnDashRefreshAll,$btnDashSession,$btnDashSupport,$btnDashCrashWatch,$btnGuidedSupport,$btnGuidedSession,$btnCrashScopeScanTarget,$btnCrashIntelAnalyze,$btnStabilityAnalyze,$btnStabilitySupport)) {
        Set-ButtonRole $button 'Primary'
    }
    foreach ($button in @($btnDelete,$btnFresh,$btnDeepFresh,$btnClearCrashReports,$btnDashDeepFresh,$btnGuidedDeepFresh)) {
        Set-ButtonRole $button 'Danger'
    }

    Set-Tip $btnDashRefreshAll 'Runs the major scans and updates every dashboard tile, grid, and preflight view.'
    Set-Tip $btnDashRunbook 'Shows the ranked expert action sequence generated from current local evidence.'
    Set-Tip $btnDashDeepFresh 'Selects save plus cache/settings user-data roots, then asks for confirmation before deleting. Backup remains on by default.'
    Set-Tip $btnDashSession 'Starts a tracked launch: before snapshot, Steam launch request, exit watch, after snapshot, and crash correlation.'
    Set-Tip $btnDashSupport 'Builds a support zip with health, crash, device, install, safety, manifest, and self-test artifacts.'
    Set-Tip $btnDashTelemetry 'Checks whether the selected official FH6 Data Out UDP port is available.'
    Set-Tip $btnDashSteamCloud 'Shows the Steam Cloud disable steps needed before local save delete tests.'
    Set-Tip $btnDashReports 'Opens the reports folder in Downloads.'
    Set-Tip $btnDashCrashWatch 'Starts or stops Crash Watch. It monitors for new FH6 crash events/reports and can capture evidence when one appears.'
    Set-Tip $btnDashActionPlan 'Opens the Guided Fix workflow summary generated from current crash, save, runtime, capture, and conflict evidence.'
    Set-Tip $chkCrashWatchPackage 'When enabled, Crash Watch builds a support package automatically after detecting new crash evidence.'
    Set-Tip $numCrashWatchSec 'How often Crash Watch checks for newer FH6 crash evidence.'
    Set-Tip $btnGuidedRefresh 'Rebuilds the Guided Fix workflow from current evidence.'
    Set-Tip $btnGuidedExport 'Writes the current Guided Fix workflow to a report file.'
    Set-Tip $btnGuidedCopy 'Copies the highest-priority action to the clipboard.'
    Set-Tip $btnGuidedSupport 'Builds a support package with the latest diagnostics and evidence.'
    Set-Tip $btnGuidedSession 'Starts a tracked FH6 launch session from the Launch tab workflow.'
    Set-Tip $btnGuidedDeepFresh 'Runs the same confirmed save/cache user-data cleanup as Dashboard Deep Fresh.'
    Set-Tip $txtCrashScopeTarget 'Enter a game/app executable name such as forzahorizon6.exe, game.exe, eldenring.exe, or leave blank when using Scan All.'
    Set-Tip $btnCrashScopeScanTarget 'Scans Windows crash evidence, WER folders, fingerprints, taxonomy, and action plan for the target executable.'
    Set-Tip $btnCrashScopeScanAll 'Scans recent Application Error, Windows Error Reporting, and Application Hang events across all apps.'
    Set-Tip $btnCrashScopeExport 'Exports a universal CrashScope report for the current target into the project data folder.'
    Set-Tip $btnCrashScopeCommands 'Shows LocalDumps, ProcDump, WPR, DISM, and SFC command playbook for deeper evidence.'
    Set-Tip $btnCrashScopeTools 'Shows whether DxDiag, ProcDump, WPR, SFC, DISM, and WinDbg are available.'
    Set-Tip $btnCrashScopeOpen 'Opens the CrashScope universal output folder.'
    Set-Tip $gridUniversalCrashes 'Recent Windows crash/hang/WER events parsed into app, code, module, and kind.'
    Set-Tip $gridUniversalFingerprints 'Grouped crash signatures help you see whether fixes change the crash pattern.'
    Set-Tip $gridUniversalPlan 'Prioritized next steps for generic game/app crashes based on local evidence.'
    Set-Tip $txtCrashIntelTarget 'Enter a target executable for scoring, or use All Apps for a system-wide view.'
    Set-Tip $btnCrashIntelAnalyze 'Scores likely root-cause families for the selected target from fingerprints, system changes, GPU/TDR events, overlays, and runtime evidence.'
    Set-Tip $btnCrashIntelAll 'Runs root-cause scoring and heatmap across all recent Windows app crash evidence.'
    Set-Tip $btnCrashIntelExport 'Exports the Crash Intelligence summary into CrashScope_Universal.'
    Set-Tip $btnCrashIntelPlaybook 'Shows a command playbook for stronger evidence collection around the target.'
    Set-Tip $btnCrashIntelOpen 'Opens the CrashScope universal output folder.'
    Set-Tip $gridRootCauseScores 'Scores are heuristic, evidence-weighted indicators, not certainty. Use them to choose the next clean test.'
    Set-Tip $gridCrashHeatmap 'Shows the most repeated app/code/module crash signatures and their frequency.'
    Set-Tip $gridChangeCorrelation 'Shows recent updates, drivers, installs, and GPU/System events near the crash anchor.'
    Set-Tip $txtStabilityTarget 'Enter a target executable for the unified evidence timeline, or use All Apps for system-wide crash triage.'
    Set-Tip $btnStabilityAnalyze 'Builds a unified timeline from crash, WER, Reliability, GPU/TDR, Defender/security, recent-change, FH6 report, and user-data evidence.'
    Set-Tip $btnStabilityAll 'Runs the Stability workbench across all recent app crash evidence.'
    Set-Tip $btnStabilityExport 'Exports Stability timeline, insight, runbook, CSV, JSON, and text artifacts into CrashScope_Universal.'
    Set-Tip $btnStabilityRunbook 'Shows the generated stability runbook for the current target.'
    Set-Tip $btnStabilitySupport 'Builds a full support package including Stability artifacts.'
    Set-Tip $btnStabilityOpen 'Opens the CrashScope universal output folder.'
    Set-Tip $gridStabilityTimeline 'Unified chronological evidence across application crashes, WER, Reliability Monitor, GPU/TDR, Defender/security, changes, reports, and user data.'
    Set-Tip $gridStabilityInsights 'Aggregated interpretation of each evidence lane plus root-cause score signals.'
    Set-Tip $gridStabilityRunbook 'Step-by-step plan generated from current evidence, with risk and success checks.'
    Set-Tip $btnDeepFresh 'Deletes selected FH6 save/cache/settings user-data only after confirmation; it never touches the Steam install folder.'
    Set-Tip $btnFresh 'Deletes save roots only after confirmation; use with Steam Cloud off for a clean local repro.'
    Set-Tip $btnBackup 'Creates a zip backup of selected FH6 user-data roots before any risky operation.'
    Set-Tip $btnRestore 'Restores a backup zip created by this tool. Dry Run lets you preview.'
    Set-Tip $btnMonitor 'Repeats the selected save/cache cleanup mode on a timer for stubborn crash-loop testing.'
    Set-Tip $btnSessionLaunch 'Captures before/after state and crash correlation around an FH6 launch attempt.'
    Set-Tip $btnSessionFinish 'Manually closes the active tracked launch session and writes after/diff reports.'
    Set-Tip $btnTelemStart 'Starts a receive-only listener for FH6 official Data Out UDP telemetry.'
    Set-Tip $btnTelemPreflight 'Checks whether the selected UDP port is currently available.'
    Set-Tip $btnFingerprints 'Groups Windows FH6 crash events by event name, exception code, and module.'
    Set-Tip $btnSafetyAudit 'Scans this script for forbidden memory, injection, input automation, and game-install modification patterns.'
    Set-Tip $btnPortableBundle 'Creates a portable zip containing the tool, launcher, README, manifest, self-test, safety audit, and references.'
    Set-Tip $gridDashboardRecommendations 'Ranked actions are evidence-based; lower priority numbers are more urgent.'
    Set-Tip $gridDashboardTimeline 'Recent local crash, WER, Steam-log, save/cache, and report timestamps are shown together for correlation.'
}

$tabs.Add_SelectedIndexChanged({
    Update-GlobalStatus
    if ($tabs.SelectedTab -eq $tabDashboard) { Update-Dashboard }
    if ($tabs.SelectedTab -eq $tabCrashScope) { Refresh-CrashScope }
    if ($tabs.SelectedTab -eq $tabCrashIntel) { Refresh-CrashIntel }
    if ($tabs.SelectedTab -eq $tabStability) { Refresh-StabilityWorkbench }
})

$btnDashRefreshAll.Add_Click({ Refresh-AllViews })
$btnDashRunbook.Add_Click({ Show-TextWindow -Title 'Expert Recommendation Runbook' -Text (Get-ExpertRecommendationSummary) })
$btnDashDeepFresh.Add_Click({
    $tabs.SelectedTab = $tabSaves
    Select-SaveCategories -Categories @('Save','Cache/Settings')
    Invoke-SaveAction -Action 'Delete' -Records @(Get-SelectedSaveRecords)
    Update-Dashboard
})
$btnDashSession.Add_Click({
    $tabs.SelectedTab = $tabLaunch
    $btnSessionLaunch.PerformClick()
    Update-Dashboard
})
$btnDashSupport.Add_Click({
    $zip = New-SupportPackage -Log ${function:Add-Log}
    $txtReports.Text = "Support package written:`r`n$zip"
    [System.Windows.Forms.MessageBox]::Show("Support package written:`n$zip", 'Support package', 'OK', 'Information') | Out-Null
    Update-Dashboard
})
$btnDashTelemetry.Add_Click({ Show-TextWindow -Title 'Telemetry Port Preflight' -Text (Get-TelemetryPreflightSummary -Port ([int]$numPort.Value)) })
$btnDashSteamCloud.Add_Click({ $btnSteamCloudSteps.PerformClick() })
$btnDashReports.Add_Click({ Start-Process -FilePath $script:Config.ReportRoot })
$btnDashCrashWatch.Add_Click({
    if (-not $script:CrashWatchActive) {
        $latest = @(Get-LatestCrashEvidenceItem | Select-Object -First 1)
        $script:CrashWatchLastTime = if ($latest.Count) { [datetime]$latest[0].Time } else { $null }
        $script:CrashWatchDetectedCount = 0
        $script:CrashWatchActive = $true
        $script:CrashWatchLastAction = if ($script:CrashWatchLastTime) { "Started. Anchor=$script:CrashWatchLastTime" } else { 'Started. No crash anchor yet.' }
        $lblCrashWatchStatus.Text = $script:CrashWatchLastAction
        $btnDashCrashWatch.Text = 'Stop Watch'
        $crashWatchTimer.Interval = [int]$numCrashWatchSec.Value * 1000
        $crashWatchTimer.Start()
        Add-Log "Crash Watch started. Interval=$([int]$numCrashWatchSec.Value)s AutoPackage=$($chkCrashWatchPackage.Checked)"
    }
    else {
        $script:CrashWatchActive = $false
        $crashWatchTimer.Stop()
        $btnDashCrashWatch.Text = 'Start Watch'
        $script:CrashWatchLastAction = "Stopped. Detections=$script:CrashWatchDetectedCount"
        $lblCrashWatchStatus.Text = $script:CrashWatchLastAction
        Add-Log 'Crash Watch stopped.'
    }
    Update-Dashboard
    Update-GlobalStatus
})
$btnDashActionPlan.Add_Click({
    Refresh-GuidedWorkflow
    $tabs.SelectedTab = $tabGuided
})

$btnGuidedRefresh.Add_Click({ Refresh-GuidedWorkflow })
$btnGuidedExport.Add_Click({
    $path = Join-Path $script:Config.ReportRoot ("FH6_GuidedFix_Workflow_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Get-GuidedWorkflowSummary | Set-Content -LiteralPath $path -Encoding UTF8
    $txtGuidedDetail.Text = "Guided workflow exported:`r`n$path`r`n`r`n" + (Get-GuidedWorkflowSummary)
    Add-Log "Guided workflow exported: $path"
})
$btnGuidedCopy.Add_Click({
    $rows = @(Get-GuidedWorkflowRows | Sort-Object Priority, Phase)
    if ($rows.Count -gt 0) {
        $text = "[P$($rows[0].Priority)] $($rows[0].Phase): $($rows[0].Action) Evidence: $($rows[0].Evidence)"
        [System.Windows.Forms.Clipboard]::SetText($text)
        Add-Log 'Top guided action copied to clipboard.'
    }
})
$btnGuidedSupport.Add_Click({
    $zip = New-SupportPackage -Log ${function:Add-Log}
    $txtGuidedDetail.Text = "Support package written:`r`n$zip`r`n`r`n" + (Get-GuidedWorkflowSummary)
    [System.Windows.Forms.MessageBox]::Show("Support package written:`n$zip", 'Support package', 'OK', 'Information') | Out-Null
})
$btnGuidedSession.Add_Click({
    $tabs.SelectedTab = $tabLaunch
    $btnSessionLaunch.PerformClick()
})
$btnGuidedDeepFresh.Add_Click({
    $tabs.SelectedTab = $tabSaves
    Select-SaveCategories -Categories @('Save','Cache/Settings')
    Invoke-SaveAction -Action 'Delete' -Records @(Get-SelectedSaveRecords)
    Refresh-GuidedWorkflow
})
$gridGuidedPlan.Add_SelectionChanged({
    try {
        if ($gridGuidedPlan.SelectedRows.Count -eq 0) { return }
        $item = $gridGuidedPlan.SelectedRows[0].DataBoundItem
        if (-not $item) { return }
        $txtGuidedDetail.Text = @(
            "Selected step",
            "=============",
            "Priority: P$($item.Priority)",
            "Phase: $($item.Phase)",
            "State: $($item.State)",
            "Action: $($item.Action)",
            "Evidence: $($item.Evidence)",
            "Suggested button: $($item.Button)",
            '',
            (Get-GuidedWorkflowSummary)
        ) -join [Environment]::NewLine
    }
    catch {}
})

$btnCrashScopeScanTarget.Add_Click({ Refresh-CrashScope })
$btnCrashScopeScanAll.Add_Click({ Refresh-CrashScope -All })
$btnCrashScopeExport.Add_Click({
    $target = [string]$script:CrashScopeCurrentTarget
    if ([string]::IsNullOrWhiteSpace($target)) { $target = [string]$txtCrashScopeTarget.Text }
    $path = Export-UniversalCrashReport -Target $target
    $txtCrashScopeDetail.Text = "CrashScope report exported:`r`n$path`r`n`r`n" + (Get-CrashScopeCommandText -Target $(if ($target) { $target } else { 'game.exe' }))
    Add-Log "CrashScope report exported: $path"
})
$btnCrashScopeCommands.Add_Click({
    $target = [string]$txtCrashScopeTarget.Text
    if ([string]::IsNullOrWhiteSpace($target)) { $target = $script:Config.ExeName }
    $text = Get-CrashScopeCommandText -Target $target
    $txtCrashScopeDetail.Text = $text
    Show-TextWindow -Title 'CrashScope Command Playbook' -Text $text
})
$btnCrashScopeTools.Add_Click({
    $target = [string]$txtCrashScopeTarget.Text
    if ([string]::IsNullOrWhiteSpace($target)) { $target = $script:Config.ExeName }
    $text = @(
        'External Evidence Tools',
        '=======================',
        ((Get-ExternalEvidenceToolRows | Format-Table -AutoSize | Out-String).Trim()),
        '',
        'LocalDump Configuration',
        '=======================',
        ((Get-LocalDumpConfigRows -Target $target | Format-Table -AutoSize | Out-String).Trim())
    ) -join [Environment]::NewLine
    $txtCrashScopeDetail.Text = $text
    Show-TextWindow -Title 'CrashScope Evidence Tools' -Text $text
})
$btnCrashScopeOpen.Add_Click({ Start-Process -FilePath $script:Config.UniversalRoot })
$gridUniversalCrashes.Add_SelectionChanged({
    try {
        if ($gridUniversalCrashes.SelectedRows.Count -eq 0) { return }
        $item = $gridUniversalCrashes.SelectedRows[0].DataBoundItem
        if (-not $item) { return }
        $tax = Get-CrashCodeTaxonomy -Code $item.Code -EventName $item.EventName -Module $item.Module
        $txtCrashScopeDetail.Text = @(
            'Selected Crash Event',
            '====================',
            "Time: $($item.Time)",
            "App: $($item.App)",
            "Provider: $($item.Provider) EventId=$($item.EventId)",
            "Event: $($item.EventName)",
            "Code: $($item.Code)",
            "Module: $($item.Module)",
            "Class: $($tax.Class) Severity=$($tax.Severity)",
            "Meaning: $($tax.Meaning)",
            "Next action: $($tax.NextAction)",
            '',
            'Raw message:',
            $item.Message
        ) -join [Environment]::NewLine
    }
    catch {}
})
$gridUniversalFingerprints.Add_SelectionChanged({
    try {
        if ($gridUniversalFingerprints.SelectedRows.Count -eq 0) { return }
        $item = $gridUniversalFingerprints.SelectedRows[0].DataBoundItem
        if (-not $item) { return }
        $txtCrashScopeDetail.Text = @(
            'Selected Fingerprint',
            '====================',
            "Count: $($item.Count)",
            "App: $($item.App)",
            "First seen: $($item.FirstSeen)",
            "Last seen: $($item.LastSeen)",
            "Event: $($item.EventName)",
            "Code: $($item.Code)",
            "Module: $($item.Module)",
            "Class: $($item.Class)",
            "Severity: $($item.Severity)",
            "Next action: $($item.NextAction)"
        ) -join [Environment]::NewLine
    }
    catch {}
})
$gridUniversalPlan.Add_SelectionChanged({
    try {
        if ($gridUniversalPlan.SelectedRows.Count -eq 0) { return }
        $item = $gridUniversalPlan.SelectedRows[0].DataBoundItem
        if (-not $item) { return }
        $txtCrashScopeDetail.Text = @(
            'Selected Action',
            '===============',
            "Priority: P$($item.Priority)",
            "Area: $($item.Area)",
            "State: $($item.State)",
            "Action: $($item.Action)",
            "Evidence: $($item.Evidence)",
            '',
            (Get-CrashScopeCommandText -Target $(if ($txtCrashScopeTarget.Text) { $txtCrashScopeTarget.Text } else { $script:Config.ExeName }))
        ) -join [Environment]::NewLine
    }
    catch {}
})

$btnCrashIntelAnalyze.Add_Click({ Refresh-CrashIntel })
$btnCrashIntelAll.Add_Click({ Refresh-CrashIntel -All })
$btnCrashIntelExport.Add_Click({
    $target = [string]$script:CrashIntelCurrentTarget
    if ([string]::IsNullOrWhiteSpace($target)) { $target = [string]$txtCrashIntelTarget.Text }
    $safeTarget = if ([string]::IsNullOrWhiteSpace($target)) { 'all-apps' } else { ConvertTo-SafeName -Text $target }
    $path = Join-Path $script:Config.UniversalRoot ("CrashIntel_{0}_{1}.txt" -f $safeTarget, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Get-CrashIntelligenceSummary -Target $target | Set-Content -LiteralPath $path -Encoding UTF8
    $txtCrashIntelDetail.Text = "Crash Intelligence exported:`r`n$path`r`n`r`n" + (Get-CrashIntelligenceSummary -Target $target)
    Add-Log "Crash Intelligence exported: $path"
})
$btnCrashIntelPlaybook.Add_Click({
    $target = [string]$txtCrashIntelTarget.Text
    if ([string]::IsNullOrWhiteSpace($target)) { $target = $script:Config.ExeName }
    $text = Get-CrashScopeCommandText -Target $target
    $txtCrashIntelDetail.Text = $text
    Show-TextWindow -Title 'Crash Intelligence Evidence Playbook' -Text $text
})
$btnCrashIntelOpen.Add_Click({ Start-Process -FilePath $script:Config.UniversalRoot })
$gridRootCauseScores.Add_SelectionChanged({
    try {
        if ($gridRootCauseScores.SelectedRows.Count -eq 0) { return }
        $item = $gridRootCauseScores.SelectedRows[0].DataBoundItem
        if (-not $item) { return }
        $txtCrashIntelDetail.Text = @(
            'Likely Cause Detail',
            '===================',
            "Cause: $($item.Cause)",
            "Score: $($item.Score)",
            "Confidence: $($item.Confidence)",
            "Evidence: $($item.Evidence)",
            '',
            "Next action: $($item.NextAction)",
            '',
            (Get-CrashIntelligenceSummary -Target $(if ($script:CrashIntelCurrentTarget) { $script:CrashIntelCurrentTarget } else { $txtCrashIntelTarget.Text }))
        ) -join [Environment]::NewLine
    }
    catch {}
})
$gridCrashHeatmap.Add_SelectionChanged({
    try {
        if ($gridCrashHeatmap.SelectedRows.Count -eq 0) { return }
        $item = $gridCrashHeatmap.SelectedRows[0].DataBoundItem
        if (-not $item) { return }
        $txtCrashIntelDetail.Text = @(
            'Heatmap Signature Detail',
            '========================',
            "Count: $($item.Count)",
            "App: $($item.App)",
            "Code: $($item.Code)",
            "Module: $($item.Module)",
            "Class: $($item.Class)",
            "First seen: $($item.FirstSeen)",
            "Last seen: $($item.LastSeen)",
            "Events/day: $($item.EventsPerDay)",
            '',
            "Suggested focus: $($item.SuggestedFocus)"
        ) -join [Environment]::NewLine
    }
    catch {}
})
$gridChangeCorrelation.Add_SelectionChanged({
    try {
        if ($gridChangeCorrelation.SelectedRows.Count -eq 0) { return }
        $item = $gridChangeCorrelation.SelectedRows[0].DataBoundItem
        if (-not $item) { return }
        $txtCrashIntelDetail.Text = @(
            'Change Correlation Detail',
            '=========================',
            "Time: $($item.Time)",
            "Type: $($item.Type)",
            "Name: $($item.Name)",
            "Days before crash: $($item.DaysBeforeCrash)",
            "Weight: $($item.Weight)",
            "Detail: $($item.Detail)",
            '',
            "Relevance: $($item.Relevance)"
        ) -join [Environment]::NewLine
    }
    catch {}
})

$btnStabilityAnalyze.Add_Click({ Refresh-StabilityWorkbench })
$btnStabilityAll.Add_Click({ Refresh-StabilityWorkbench -All })
$btnStabilityExport.Add_Click({
    $target = [string]$script:StabilityCurrentTarget
    if ([string]::IsNullOrWhiteSpace($target)) { $target = [string]$txtStabilityTarget.Text }
    $path = Export-CrashStabilityWorkbench -Target $target
    $txtStabilityDetail.Text = "Stability workbench exported:`r`n$path`r`n`r`n" + (Get-CrashStabilityRunbookText -Target $target)
    Add-Log "Stability workbench exported: $path"
})
$btnStabilityRunbook.Add_Click({
    $target = [string]$txtStabilityTarget.Text
    if ([string]::IsNullOrWhiteSpace($target)) { $target = $script:Config.ExeName }
    $text = Get-CrashStabilityRunbookText -Target $target
    $txtStabilityDetail.Text = $text
    Show-TextWindow -Title 'Crash Stability Runbook' -Text $text
})
$btnStabilitySupport.Add_Click({
    $zip = New-SupportPackage -Log ${function:Add-Log}
    $txtStabilityDetail.Text = "Support package written:`r`n$zip`r`n`r`n" + (Get-CrashStabilityRunbookText -Target $(if ($script:StabilityCurrentTarget) { $script:StabilityCurrentTarget } else { $txtStabilityTarget.Text }))
    [System.Windows.Forms.MessageBox]::Show("Support package written:`n$zip", 'Support package', 'OK', 'Information') | Out-Null
})
$btnStabilityOpen.Add_Click({ Start-Process -FilePath $script:Config.UniversalRoot })
$gridStabilityTimeline.Add_SelectionChanged({
    try {
        if ($gridStabilityTimeline.SelectedRows.Count -eq 0) { return }
        $item = $gridStabilityTimeline.SelectedRows[0].DataBoundItem
        if (-not $item) { return }
        $txtStabilityDetail.Text = @(
            'Timeline Evidence Detail',
            '========================',
            "Time: $($item.Time)",
            "Lane: $($item.Lane)",
            "Severity: $($item.Severity)",
            "Subject: $($item.Subject)",
            "Signal: $($item.Signal)",
            "Confidence: $($item.Confidence)",
            '',
            "Detail: $($item.Detail)",
            '',
            "Path: $($item.Path)",
            '',
            (Get-CrashStabilityRunbookText -Target $(if ($script:StabilityCurrentTarget) { $script:StabilityCurrentTarget } else { $txtStabilityTarget.Text }))
        ) -join [Environment]::NewLine
    }
    catch {}
})
$gridStabilityInsights.Add_SelectionChanged({
    try {
        if ($gridStabilityInsights.SelectedRows.Count -eq 0) { return }
        $item = $gridStabilityInsights.SelectedRows[0].DataBoundItem
        if (-not $item) { return }
        $txtStabilityDetail.Text = @(
            'Evidence Insight Detail',
            '=======================',
            "Rank: $($item.Rank)",
            "Lane: $($item.Lane)",
            "Status: $($item.Status)",
            "Count/Score: $($item.Count)",
            "Latest: $($item.Latest)",
            "Signal: $($item.Signal)",
            '',
            "Interpretation: $($item.Interpretation)",
            '',
            "Next action: $($item.NextAction)"
        ) -join [Environment]::NewLine
    }
    catch {}
})
$gridStabilityRunbook.Add_SelectionChanged({
    try {
        if ($gridStabilityRunbook.SelectedRows.Count -eq 0) { return }
        $item = $gridStabilityRunbook.SelectedRows[0].DataBoundItem
        if (-not $item) { return }
        $txtStabilityDetail.Text = @(
            'Runbook Step Detail',
            '===================',
            "Step: $($item.Step)",
            "Phase: $($item.Phase)",
            "Mode: $($item.Mode)",
            "Risk: $($item.Risk)",
            '',
            "Action: $($item.Action)",
            '',
            "Why: $($item.Why)",
            '',
            "Success check: $($item.SuccessCheck)"
        ) -join [Environment]::NewLine
    }
    catch {}
})

$btnHealthScan.Add_Click({ Refresh-Health })
$btnHealthReport.Add_Click({
    $path = Export-FH6Report -Records @(Get-FH6Inventory)
    Add-Log "Report exported: $path"
    [System.Windows.Forms.MessageBox]::Show("Report exported:`n$path", 'Report exported', 'OK', 'Information') | Out-Null
})
$btnHealthSupport.Add_Click({
    $zip = New-SupportPackage -Log ${function:Add-Log}
    [System.Windows.Forms.MessageBox]::Show("Support package written:`n$zip", 'Support package', 'OK', 'Information') | Out-Null
})
$btnOpenLogs.Add_Click({ Start-Process -FilePath $script:Config.LogRoot })
$btnShowConflicts.Add_Click({ Show-TextWindow -Title 'Conflict Process Scan' -Text (Get-ConflictSummary) })
$btnSteamLogs.Add_Click({ Show-TextWindow -Title 'Steam FH6 Log Matches' -Text (Get-SteamLogSummary) })
$btnServiceDetails.Add_Click({
    $text = "Xbox/Gaming Services`r`n====================`r`n" + ((Get-XboxServiceRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'Xbox and Gaming Services' -Text $text
})
$btnRuntimeDetails.Add_Click({
    $mf = Get-MediaFoundationStatus
    $text = @(
        'Runtime Details',
        '===============',
        '',
        'Media Foundation:',
        "$($mf.Status): $($mf.Detail)",
        '',
        'Visual C++ Redistributables:',
        ((Get-VisualCRedistRows | Format-Table -AutoSize | Out-String).Trim())
    ) -join [Environment]::NewLine
    Show-TextWindow -Title 'Runtime Details' -Text $text
})
$btnRunbook.Add_Click({ Show-TextWindow -Title 'Expert Recommendation Runbook' -Text (Get-ExpertRecommendationSummary) })
$btnStartup.Add_Click({
    $text = "Startup and Logon Inventory`r`n===========================`r`n" + ((Get-StartupProgramRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'Startup Inventory' -Text $text
})
$btnPlatformAudit.Add_Click({
    $text = @(
        'Platform Audit',
        '==============',
        '',
        'Windows Gaming Settings:',
        ((Get-WindowsGamingSettingRows | Format-Table -AutoSize | Out-String).Trim()),
        '',
        'Power and Thermal:',
        ((Get-PowerThermalRows | Format-Table -AutoSize | Out-String).Trim()),
        '',
        'Xbox App Packages:',
        ((Get-XboxAppPackageRows | Format-Table -AutoSize | Out-String).Trim())
    ) -join [Environment]::NewLine
    Show-TextWindow -Title 'Platform Audit' -Text $text
})
$btnPermissionAudit.Add_Click({
    $text = "Path Permission Audit`r`n=====================`r`n" + ((Get-PathPermissionRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'Path Permission Audit' -Text $text
})
$btnBackupAudit.Add_Click({
    $text = "Backup Integrity Audit`r`n======================`r`n" + ((Get-BackupIntegrityRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'Backup Integrity Audit' -Text $text
})
$btnReliability.Add_Click({
    $text = "Reliability Monitor Records`r`n===========================`r`n" + ((Get-ReliabilityRecordRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'Reliability Monitor Records' -Text $text
})
$btnDisplayAudit.Add_Click({
    $text = "Display and GPU Topology`r`n========================`r`n" + ((Get-DisplayTopologyRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'Display and GPU Topology' -Text $text
})
$btnCompatAudit.Add_Click({
    $text = @(
        'Compatibility and GPU Preference Audit',
        '======================================',
        '',
        'Compatibility Layers:',
        ((Get-AppCompatLayerRows | Format-Table -AutoSize | Out-String).Trim()),
        '',
        'Graphics Preferences:',
        ((Get-GraphicsPreferenceRows | Format-Table -AutoSize | Out-String).Trim())
    ) -join [Environment]::NewLine
    Show-TextWindow -Title 'Compatibility and GPU Preferences' -Text $text
})
$btnSecurityAudit.Add_Click({
    $text = "Security Product Inventory`r`n==========================`r`n" + ((Get-SecurityProductRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'Security Product Inventory' -Text $text
})

$btnSaveScan.Add_Click({ Refresh-SaveInventory })
$btnSelectSaves.Add_Click({ Select-SaveCategories -Categories @('Save') })
$btnSelectDeep.Add_Click({ Select-SaveCategories -Categories @('Save','Cache/Settings') })
$btnClearSel.Add_Click({ foreach ($row in $listSaves.Items) { $row.Checked = $false } })
$btnBackup.Add_Click({ Backup-FH6Targets -Records @(Get-SelectedSaveRecords) -Log ${function:Add-Log} | Out-Null })
$btnRename.Add_Click({ Invoke-SaveAction -Action 'Rename' -Records @(Get-SelectedSaveRecords) })
$btnDelete.Add_Click({ Invoke-SaveAction -Action 'Delete' -Records @(Get-SelectedSaveRecords) })
$btnFresh.Add_Click({ Select-SaveCategories -Categories @('Save'); Invoke-SaveAction -Action 'Delete' -Records @(Get-SelectedSaveRecords) })
$btnDeepFresh.Add_Click({ Select-SaveCategories -Categories @('Save','Cache/Settings'); Invoke-SaveAction -Action 'Delete' -Records @(Get-SelectedSaveRecords) })
$btnRestore.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Choose FH6 Companion Doctor backup zip'
    $dialog.InitialDirectory = $script:Config.BackupRoot
    $dialog.Filter = 'FH6 backups (*.zip)|*.zip|All files (*.*)|*.*'
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        Invoke-Preflight -StopGame $chkStopGame.Checked -Log ${function:Add-Log} | Out-Null
        Restore-FH6Backup -ZipPath $dialog.FileName -DryRun $chkDryRun.Checked -Log ${function:Add-Log}
        Refresh-SaveInventory
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Restore failed', 'OK', 'Error') | Out-Null
        Add-Log "Restore failed: $($_.Exception.Message)"
    }
})
$btnMonitor.Add_Click({
    if (-not $script:MonitorActive) {
        $script:MonitorActive = $true
        $script:MonitorRunCount = 0
        $script:MonitorLastAction = 'Started'
        $btnMonitor.Text = 'Stop Monitor'
        $lblMonitorStatus.Text = "Running every $([int]$numMonitorSec.Value)s"
        Add-Log "Monitor started: $($cmbMonitorMode.SelectedItem), interval=$([int]$numMonitorSec.Value)s"
        $monitorTimer.Interval = [int]$numMonitorSec.Value * 1000
        $monitorTimer.Start()
    }
    else {
        $script:MonitorActive = $false
        $monitorTimer.Stop()
        $btnMonitor.Text = 'Start Monitor'
        $lblMonitorStatus.Text = "Stopped. Ticks=$($script:MonitorRunCount). Last=$script:MonitorLastAction"
        Add-Log "Monitor stopped."
    }
})

$btnCrashRefresh.Add_Click({ Refresh-Crashes })
$btnCrashSummary.Add_Click({ Show-TextWindow -Title 'Crash Summary' -Text (Get-CrashSummary) })
$btnCrashAnalysis.Add_Click({ Show-TextWindow -Title 'Crash Signature Analysis' -Text (Get-CrashSignatureAnalysis) })
$btnWerReports.Add_Click({
    $text = "WER Reports`r`n===========`r`n" + ((Get-WERReportRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'FH6 WER Reports' -Text $text
})
$btnTimeline.Add_Click({ Show-TextWindow -Title 'FH6 Event Timeline' -Text (Get-EventTimelineSummary) })
$btnCorrelation.Add_Click({ Show-TextWindow -Title 'Latest Crash Correlation' -Text (Get-CrashCorrelationSummary -Minutes 10) })
$btnFingerprints.Add_Click({
    $text = "Crash Fingerprints`r`n==================`r`n" + ((Get-CrashFingerprintRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'Crash Fingerprints' -Text $text
})
$btnClearCrashReports.Add_Click({
    Refresh-SaveInventory
    $records = @(Get-FH6Inventory | Where-Object { $_.Category -eq 'Crash Report' })
    Invoke-SaveAction -Action 'Delete' -Records $records
    Refresh-Crashes
})

$btnTelemStart.Add_Click({
    try {
        if ($script:UdpClient) { $script:UdpClient.Close(); $script:UdpClient = $null }
        $port = [int]$numPort.Value
        $script:UdpClient = New-Object System.Net.Sockets.UdpClient($port)
        $script:TelemetryPacketCount = 0
        $script:TelemetryCsvPath = if ($chkTelemCsv.Checked) { Join-Path $script:Config.TelemetryRoot ("FH6_DataOut_{0}_port{1}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $port) } else { $null }
        $txtTelemetry.Text = "Listening for FH6 Data Out UDP on 127.0.0.1:$port...`r`nEnable Data Out in-game and start driving."
        $telemetryTimer.Start()
        Add-Log "Telemetry listener started on UDP port $port. CSV=$script:TelemetryCsvPath"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Telemetry start failed', 'OK', 'Error') | Out-Null
        Add-Log "Telemetry start failed: $($_.Exception.Message)"
    }
})
$btnTelemStop.Add_Click({
    $telemetryTimer.Stop()
    if ($script:UdpClient) { $script:UdpClient.Close(); $script:UdpClient = $null }
    Add-Log 'Telemetry listener stopped.'
})
$btnOpenTelemetry.Add_Click({ Start-Process -FilePath $script:Config.TelemetryRoot })
$btnTelemPreflight.Add_Click({ Show-TextWindow -Title 'Telemetry Port Preflight' -Text (Get-TelemetryPreflightSummary -Port ([int]$numPort.Value)) })

$btnDevicesRefresh.Add_Click({ Refresh-Devices })
$btnDeviceAdvice.Add_Click({
    $text = @"
FH6 wheel/device reminders:

- Update wheel drivers and firmware before testing.
- Avoid USB hubs for wheels; use a direct USB 3.0 port where possible.
- If force feedback is missing, the wheelbase may not be Device 1 in-game.
- Temporarily unplug extra controllers, shifters, pedals, or adapters to test.
- Steam Controller is listed in FH6 known issues as potentially crash-prone in some circumstances.
- For multiple USB devices, create/check a custom wheel profile in-game.
"@
    Show-TextWindow -Title 'Wheel and Device Advice' -Text $text
})
$btnDriverInventory.Add_Click({
    $text = "Driver Inventory`r`n================`r`n" + ((Get-DriverInventoryRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'Driver Inventory' -Text $text
})

$btnPreflight.Add_Click({ $txtPreflight.Text = Get-PreflightText; Add-Log 'Preflight scan complete.' })
$btnLaunchSteam.Add_Click({ Start-Process "steam://run/$($script:Config.AppId)"; Add-Log 'Launch requested through Steam URI.' })
$btnPreflightLaunch.Add_Click({
    $txtPreflight.Text = Get-PreflightText
    $snap = New-StateSnapshot -Label 'preflight-launch'
    Add-Log "Preflight snapshot: $($snap.Text)"
    Start-Process "steam://run/$($script:Config.AppId)"
    Add-Log 'Preflight complete, launch requested through Steam URI.'
})
$btnSnapshotBefore.Add_Click({
    $snap = New-StateSnapshot -Label 'manual-launch-tab'
    $txtPreflight.Text = "Snapshot written:`r`n$($snap.Text)`r`n$($snap.Json)`r`n`r`n" + (Get-PreflightText)
    Add-Log "State snapshot written: $($snap.Text)"
})
$btnSteamCloudSteps.Add_Click({
    $msg = @"
Steam Cloud must be off before a clean local-save test:

1. Open Steam Library.
2. Right-click Forza Horizon 6.
3. Choose Properties.
4. Open General.
5. Turn off Steam Cloud sync for Forza Horizon 6.

Launch once with Steam Cloud off. If FH6 creates clean local data and loads, exit normally before deciding whether to re-enable cloud sync.
"@
    [System.Windows.Forms.MessageBox]::Show($msg, 'Steam Cloud steps', 'OK', 'Information') | Out-Null
})
$btnOpenSteamInstall.Add_Click({
    $install = @(Get-SteamInstallInfo | Where-Object { $_.ExeExists } | Select-Object -First 1)
    if ($install.Count -gt 0) { Start-Process -FilePath $install[0].InstallDir }
    else { [System.Windows.Forms.MessageBox]::Show('Steam FH6 install was not detected.', 'Install folder', 'OK', 'Information') | Out-Null }
})
$btnInstallAudit.Add_Click({
    $text = "Read-only Install Audit`r`n=======================`r`n" + ((Get-InstallAuditRows | Format-Table -AutoSize | Out-String).Trim())
    Show-TextWindow -Title 'Read-only Install Audit' -Text $text
})
$btnSessionLaunch.Add_Click({
    try {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Start a tracked FH6 launch session?`n`nThe tool will create a before snapshot, request Steam launch, then watch for FH6 to exit and capture an after snapshot/session report.",
            'Start tracked session',
            'OKCancel',
            'Information'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $dir = Start-FH6LaunchSession
        $txtPreflight.Text = "Tracked session started:`r`n$dir`r`n`r`n" + (Get-PreflightText)
        $sessionTimer.Start()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Session failed', 'OK', 'Error') | Out-Null
        Add-Log "Session launch failed: $($_.Exception.Message)"
    }
})
$btnSessionFinish.Add_Click({
    try {
        $dir = Complete-FH6LaunchSession -Reason 'manual'
        $txtPreflight.Text = "Tracked session finished:`r`n$dir`r`n`r`n" + (Get-PreflightText)
        $sessionTimer.Stop()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Finish session failed', 'OK', 'Error') | Out-Null
        Add-Log "Finish session failed: $($_.Exception.Message)"
    }
})

$btnExportReport.Add_Click({
    $path = Export-FH6Report -Records @(Get-FH6Inventory)
    $txtReports.Text = "Report exported:`r`n$path"
    Add-Log "Report exported: $path"
})
$btnSupportPackage.Add_Click({
    $zip = New-SupportPackage -Log ${function:Add-Log}
    $txtReports.Text = "Support package written:`r`n$zip"
})
$btnStateSnapshot.Add_Click({
    $snap = New-StateSnapshot -Label 'manual'
    $txtReports.Text = "State snapshot written:`r`n$($snap.Text)`r`n$($snap.Json)"
    Add-Log "State snapshot written: $($snap.Text)"
})
$btnSnapshotDiff.Add_Click({
    $diff = Compare-LatestStateSnapshots
    $txtReports.Text = $diff
    Show-TextWindow -Title 'Latest State Snapshot Diff' -Text $diff
})
$btnRedactedReport.Add_Click({
    $raw = @(
        'FH6 Companion Doctor Redacted Summary',
        '=====================================',
        '',
        '== Status ==',
        (Get-StatusSummary),
        '',
        '== Expert Recommendations ==',
        (Get-ExpertRecommendationSummary),
        '',
        '== Guided Fix Workflow ==',
        (Get-GuidedWorkflowSummary),
        '',
        '== Crash Fingerprints ==',
        ((Get-CrashFingerprintRows | Format-Table -AutoSize | Out-String).Trim()),
        '',
        '== Crash Analysis ==',
        (Get-CrashSignatureAnalysis),
        '',
        '== Event Timeline ==',
        (Get-EventTimelineSummary)
    ) -join [Environment]::NewLine
    $redacted = ConvertTo-RedactedText -Text $raw
    $path = Join-Path $script:Config.ReportRoot ("FH6_CompanionDoctor_RedactedSummary_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $redacted | Set-Content -LiteralPath $path -Encoding UTF8
    $txtReports.Text = "Redacted summary written:`r`n$path"
    Add-Log "Redacted summary written: $path"
    Show-TextWindow -Title 'Redacted Summary' -Text $redacted
})
$btnOpenReports.Add_Click({ Start-Process -FilePath $script:Config.ReportRoot })
$btnOpenPackages.Add_Click({ Start-Process -FilePath $script:Config.PackageRoot })
$btnOpenSnapshots.Add_Click({ Start-Process -FilePath $script:Config.SnapshotRoot })
$btnOpenSessions.Add_Click({ Start-Process -FilePath $script:Config.SessionRoot })
$btnSelfTest.Add_Click({
    $rows = @(Invoke-CompanionSelfTest)
    $text = "FH6 Companion Doctor Self-Test`r`n=============================`r`n" + (($rows | Format-Table -AutoSize | Out-String).Trim())
    $txtReports.Text = $text
    Show-TextWindow -Title 'Self-Test' -Text $text
})
$btnSafetyAudit.Add_Click({
    $rows = @(Get-ToolSafetyAuditRows)
    $text = "FH6 Companion Doctor Safety Audit`r`n=================================`r`n" + (($rows | Format-Table -AutoSize | Out-String).Trim())
    $txtReports.Text = $text
    Show-TextWindow -Title 'Safety Audit' -Text $text
})
$btnManifest.Add_Click({
    $path = Write-ToolManifest
    $txtReports.Text = "Manifest written:`r`n$path"
    Add-Log "Manifest written: $path"
    Start-Process -FilePath (Split-Path -Path $path -Parent)
})
$btnOfficialRefs.Add_Click({
    $text = "Official References`r`n===================`r`n" + ((Get-OfficialReferenceRows | Format-Table -AutoSize | Out-String).Trim())
    $txtReports.Text = $text
    Show-TextWindow -Title 'Official References' -Text $text
})
$btnPortableBundle.Add_Click({
    try {
        $zip = New-PortableToolBundle -Log ${function:Add-Log}
        $txtReports.Text = "Portable bundle written:`r`n$zip"
        [System.Windows.Forms.MessageBox]::Show("Portable bundle written:`n$zip", 'Portable Bundle', 'OK', 'Information') | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Portable bundle failed', 'OK', 'Error') | Out-Null
        Add-Log "Portable bundle failed: $($_.Exception.Message)"
    }
})
$btnOpenBundles.Add_Click({ Start-Process -FilePath $script:Config.BundleRoot })

$form.Add_FormClosing({
    $script:MonitorActive = $false
    $script:CrashWatchActive = $false
    $monitorTimer.Stop()
    $crashWatchTimer.Stop()
    $sessionTimer.Stop()
    $telemetryTimer.Stop()
    $uiStatusTimer.Stop()
    if ($script:UdpClient) { $script:UdpClient.Close(); $script:UdpClient = $null }
    try { Save-CompanionSettingsFromUi } catch { Add-Log "Settings save warning: $($_.Exception.Message)" }
    Add-Log 'FH6 Companion Doctor closing.'
})

Initialize-UiGuidance
Apply-CompanionSettingsToUi
Refresh-AllViews
$txtReports.Text = "Reports: $($script:Config.ReportRoot)`r`nSupport packages: $($script:Config.PackageRoot)`r`nBackups: $($script:Config.BackupRoot)"
$uiStatusTimer.Start()
Add-Log "FH6 Companion Doctor v$script:ToolVersion ready."

[void][System.Windows.Forms.Application]::Run($form)
