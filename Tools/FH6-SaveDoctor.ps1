<# 
FH6 Save Doctor

Interactive Windows utility for repeatedly refreshing or removing local Forza Horizon 6
account/save/cache data without touching the installed game files.

Run:
  powershell.exe -ExecutionPolicy Bypass -STA -File "$env:USERPROFILE\Downloads\FH6-SaveDoctor.ps1"

Notes:
  - Turn off Steam Cloud for FH6 before deleting saves, or Steam may restore them.
  - This script backs up selected targets before destructive actions by default.
  - It refuses to delete anything outside known FH6 AppData, Xbox GameSave, or Steam userdata roots.
#>

[CmdletBinding()]
param(
    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'

$script:Config = [ordered]@{
    AppId        = '2483190'
    GameName     = 'Forza Horizon 6'
    LocalRoot    = Join-Path $env:LOCALAPPDATA 'ForzaHorizon6'
    SharedRoot   = Join-Path (Join-Path $env:LOCALAPPDATA 'ForzaHorizon6') 'LocalStorage_Shared'
    XboxPgsRoot  = Join-Path $env:SystemDrive 'XboxGames\GameSave\pgs'
    BackupRoot   = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'FH6_SaveDoctor_Backups'
    ReportRoot   = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'FH6_SaveDoctor_Reports'
    LogRoot      = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'FH6_SaveDoctor_Logs'
}

$script:RunLogPath = $null

function Get-FullPathSafe {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) {
            return (Resolve-Path -LiteralPath $Path).Path
        }
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
        $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        $hash = ([BitConverter]::ToString($hashBytes)).Replace('-', '').Substring(0, 12)
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
        if (Test-Path -LiteralPath $manifest) {
            $raw = Get-Content -LiteralPath $manifest -Raw -ErrorAction SilentlyContinue
            $installDir = 'ForzaHorizon6'
            $name = $script:Config.GameName
            $stateFlags = ''
            if ($raw -match '"installdir"\s+"([^"]+)"') { $installDir = $Matches[1] }
            if ($raw -match '"name"\s+"([^"]+)"') { $name = $Matches[1] }
            if ($raw -match '"StateFlags"\s+"([^"]+)"') { $stateFlags = $Matches[1] }
            $gameDir = Join-Path (Join-Path $library 'steamapps\common') $installDir
            $exe = Join-Path $gameDir 'forzahorizon6.exe'
            [void]$found.Add([pscustomobject]@{
                Library    = $library
                Manifest   = $manifest
                Name       = $name
                InstallDir = $gameDir
                Exe        = $exe
                StateFlags = $stateFlags
                ExeExists  = Test-Path -LiteralPath $exe
            })
        }
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

function Get-FH6Process {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '^(forzahorizon6|ForzaHorizon6)$'
    }
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

function Get-OverlayProcessSummary {
    $patterns = @(
        'Afterburner', 'RTSS', 'Riva', 'Discord', 'obs', 'Logitech', 'lghub',
        'Nahimic', 'Sonic', 'Wallpaper', 'WeMod', 'Windhawk', 'XSplit',
        'EVGAPrecision', 'A-Volute', 'SteelSeries', 'Overwolf', 'GameBar',
        'PresentMon', 'SpecialK', 'ReShade', 'Medal', 'Outplayed'
    )
    $regex = ($patterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $hits = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match $regex -or $_.Path -match $regex
    } | Select-Object ProcessName, Id, Path | Sort-Object ProcessName -Unique)

    if ($hits.Count -eq 0) {
        return 'Overlay/conflict scan: no common overlay or hook processes found.'
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Overlay/conflict scan: $($hits.Count) possible hook/overlay process(es) found:")
    foreach ($hit in $hits) {
        [void]$lines.Add("  $($hit.ProcessName) pid=$($hit.Id) $($hit.Path)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-SteamCloudTargetSummary {
    $lines = New-Object System.Collections.Generic.List[string]
    $targets = @(Get-SteamUserDataTargets)
    if ($targets.Count -eq 0) {
        [void]$lines.Add('Steam userdata/cloud target: none found for app ID 2483190.')
    }
    else {
        [void]$lines.Add("Steam userdata/cloud target(s): $($targets.Count)")
        foreach ($target in $targets) {
            [void]$lines.Add("  $($target.Path) sizeMB=$($target.SizeMB) items=$($target.Items)")
        }
    }

    foreach ($library in Get-SteamLibraries) {
        $manifest = Join-Path (Join-Path $library 'steamapps') "appmanifest_$($script:Config.AppId).acf"
        if (Test-Path -LiteralPath $manifest) {
            try {
                $raw = Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop
                $state = if ($raw -match '"StateFlags"\s+"([^"]+)"') { $Matches[1] } else { 'unknown' }
                [void]$lines.Add("Steam manifest: $manifest StateFlags=$state")
            }
            catch {
                [void]$lines.Add("Steam manifest: $manifest read failed ($($_.Exception.Message))")
            }
        }
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-SystemDiagnosticSummary {
    $lines = New-Object System.Collections.Generic.List[string]
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    [void]$lines.Add("PowerShell: $($PSVersionTable.PSVersion)")
    [void]$lines.Add("Windows user: $env:USERNAME")
    [void]$lines.Add("Is admin: $isAdmin")
    [void]$lines.Add("Execution policy process: $(Get-ExecutionPolicy -Scope Process)")
    [void]$lines.Add("Execution policy current user: $(Get-ExecutionPolicy -Scope CurrentUser)")
    try {
        $gpu = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object Name, DriverVersion, DriverDate)
        foreach ($g in $gpu) {
            [void]$lines.Add("GPU: $($g.Name) driver=$($g.DriverVersion) date=$($g.DriverDate)")
        }
    }
    catch {
        [void]$lines.Add("GPU query unavailable: $($_.Exception.Message)")
    }
    [void]$lines.Add((Get-SteamCloudTargetSummary))
    [void]$lines.Add((Get-OverlayProcessSummary))
    return ($lines -join [Environment]::NewLine)
}

function Get-FH6Inventory {
    $records = New-Object System.Collections.Generic.List[object]

    $shared = $script:Config.SharedRoot
    if (Test-Path -LiteralPath $shared) {
        Get-ChildItem -LiteralPath $shared -Force -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^User_' -or
            $_.Name -eq 'ForzaUserConfigSelections' -or
            $_.Name -match '^InputTranslationManager_'
        } | ForEach-Object {
            [void]$records.Add((New-FH6Record -Category 'Save' -Path $_.FullName -Description 'FH6 AppData account/profile save or user setting container.' -Cleanable $true -DefaultSelected $true -Risk 'Save'))
        }
    }

    $pgs = $script:Config.XboxPgsRoot
    if (Test-Path -LiteralPath $pgs) {
        Get-ChildItem -LiteralPath $pgs -Force -Directory -ErrorAction SilentlyContinue | Where-Object {
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
        [void]$records.Add((New-FH6Record -Category 'Install Info' -Path $install.Exe -Description "Steam install detected. This script will not modify game files. Library: $($install.Library)" -Cleanable $false -DefaultSelected $false -Risk 'Never delete'))
    }

    return $records.ToArray()
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

    if (-not $Record.Cleanable) {
        throw "Refusing to modify non-cleanable item: $($Record.Path)"
    }
    if (-not (Test-Path -LiteralPath $Record.Path)) {
        return
    }

    $full = Get-FullPathSafe -Path $Record.Path
    if ($full -match '\\steamapps\\common\\ForzaHorizon6(\\|$)' -or $full -match '\\forzahorizon6\.exe$') {
        throw "Refusing to modify game install path: $full"
    }
    if ($full -match '^[A-Za-z]:\\?$') {
        throw "Refusing to modify drive root: $full"
    }
    if ($full.Equals((Get-FullPathSafe -Path $env:USERPROFILE), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify user profile root: $full"
    }

    $allowed = $false
    foreach ($root in Get-AllowedRoots) {
        if (Test-PathUnderRoot -Path $full -Root $root) {
            $allowed = $true
            break
        }
    }
    if (-not $allowed) {
        throw "Refusing to modify item outside known FH6 save/cache roots: $full"
    }
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
    $stage = Join-Path $env:TEMP "FH6_SaveDoctor_$stamp"
    $zip = Join-Path $script:Config.BackupRoot "FH6_SaveDoctor_Backup_$stamp.zip"

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
        $manifestPath = Join-Path $stage 'manifest.json'
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

        $content = @(Get-ChildItem -LiteralPath $stage -Force | Select-Object -ExpandProperty FullName)
        Compress-Archive -LiteralPath $content -DestinationPath $zip -Force
        & $Log "Backup written: $zip"
        return $zip
    }
    finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-FH6Backup {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [bool]$DryRun = $false,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )

    if (-not (Test-Path -LiteralPath $ZipPath)) {
        throw "Backup zip does not exist: $ZipPath"
    }
    if (-not (Test-PathUnderRoot -Path $ZipPath -Root $script:Config.BackupRoot)) {
        throw "Refusing to restore a backup outside FH6 Save Doctor backup root: $ZipPath"
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stage = Join-Path $env:TEMP "FH6_SaveDoctor_Restore_$stamp"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $stage -Force
        $manifestPath = Join-Path $stage 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "Backup manifest.json is missing. Cannot restore safely."
        }

        $manifest = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
        if ($manifest.Count -eq 0) {
            throw "Backup manifest is empty."
        }

        foreach ($entry in $manifest) {
            $targetPath = [string]$entry.OriginalPath
            $safeName = ConvertTo-SafeName -Text $targetPath
            $source = Join-Path $stage $safeName
            if (-not (Test-Path -LiteralPath $source)) {
                & $Log "Restore source missing, skipped: $source"
                continue
            }

            $record = [pscustomobject]@{
                Path      = $targetPath
                Cleanable = $true
            }
            Assert-FH6SafeTarget -Record $record
            $parent = Split-Path -Path $targetPath -Parent
            if (-not (Test-Path -LiteralPath $parent)) {
                if ($DryRun) {
                    & $Log "DRY RUN create parent: $parent"
                }
                else {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
            }

            if (Test-Path -LiteralPath $targetPath) {
                $existing = Get-Item -LiteralPath $targetPath -Force
                $existingParent = if ($existing.PSIsContainer) { $existing.Parent.FullName } else { Split-Path -Path $existing.FullName -Parent }
                $existingLeaf = $existing.Name
                $moveLeaf = "$existingLeaf.pre_restore_$stamp"
                $movePath = Join-Path $existingParent $moveLeaf
                $n = 1
                while (Test-Path -LiteralPath $movePath) {
                    $moveLeaf = "$existingLeaf.pre_restore_${stamp}_$n"
                    $movePath = Join-Path $existingParent $moveLeaf
                    $n++
                }
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
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
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
        $leaf = $item.Name
        $newLeaf = "$leaf.fh6doctor_$stamp"
        $newPath = Join-Path $parent $newLeaf
        $n = 1
        while (Test-Path -LiteralPath $newPath) {
            $newLeaf = "$leaf.fh6doctor_${stamp}_$n"
            $newPath = Join-Path $parent $newLeaf
            $n++
        }
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

function Get-CrashSummary {
    $lines = New-Object System.Collections.Generic.List[string]
    $reports = @()
    if (Test-Path -LiteralPath $script:Config.LocalRoot) {
        $reports = @(Get-ChildItem -LiteralPath $script:Config.LocalRoot -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^report_\d{4}_\d{2}_\d{2}_' } |
            Sort-Object LastWriteTime -Descending)
    }
    [void]$lines.Add("Local FH6 crash report folders: $($reports.Count)")
    foreach ($report in $reports | Select-Object -First 5) {
        $xmlPath = Join-Path $report.FullName 'PreCrashReport.xml'
        if (Test-Path -LiteralPath $xmlPath) {
            try {
                [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw
                $build = ($xml.PreCrashReport.BUILD.Value)
                $gpu = ($xml.PreCrashReport.THP_GPU0Description.Value)
                $driver = ($xml.PreCrashReport.THP_GPU0Driver.Value)
                [void]$lines.Add("  $($report.Name): build=$build gpu=$gpu driver=$driver")
            }
            catch {
                [void]$lines.Add("  $($report.Name): unable to parse PreCrashReport.xml")
            }
        }
        else {
            [void]$lines.Add("  $($report.Name): no PreCrashReport.xml")
        }
    }

    try {
        $since = (Get-Date).AddDays(-2)
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } -ErrorAction SilentlyContinue |
            Where-Object { ($_.ProviderName -match 'Application Error|Windows Error Reporting') -and ($_.Message -match 'forzahorizon6|Forza Horizon 6') } |
            Sort-Object TimeCreated -Descending |
            Select-Object -First 5)
        [void]$lines.Add("Recent Windows FH6 crash events: $($events.Count)")
        foreach ($event in $events) {
            $message = ($event.Message -replace "`r?`n", ' ')
            $code = if ($message -match 'Exception code:\s*(0x[0-9a-fA-F]+)') { $Matches[1] } elseif ($message -match 'P8:\s*([a-zA-Z0-9]+)') { $Matches[1] } else { 'unknown' }
            $eventName = if ($message -match 'Event Name:\s*([^\s]+)') { $Matches[1] } else { $event.ProviderName }
            [void]$lines.Add("  $($event.TimeCreated): $eventName $code")
        }
    }
    catch {
        [void]$lines.Add("Recent Windows FH6 crash events: unavailable ($($_.Exception.Message))")
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-StatusSummary {
    $processes = @(Get-FH6Process)
    $steamInstalls = @(Get-SteamInstallInfo)
    $exeText = if ($steamInstalls.Count -gt 0) {
        ($steamInstalls | ForEach-Object { "$($_.Exe) exists=$($_.ExeExists)" }) -join '; '
    }
    else {
        'Steam FH6 install not detected by appmanifest_2483190.acf'
    }
    return @"
Game process running: $($processes.Count -gt 0)
Gaming Services: $(Get-GamingServicesVersion)
Steam install: $exeText
Local FH6 root: $($script:Config.LocalRoot)
Xbox GameSave root: $($script:Config.XboxPgsRoot)
Backups: $($script:Config.BackupRoot)
Logs: $($script:Config.LogRoot)
Steam Cloud: this script cannot safely toggle it. Turn it off in Steam > FH6 > Properties > General before deleting saves.
"@
}

function Export-FH6Report {
    param([Parameter(Mandatory)][object[]]$Records)
    New-Item -ItemType Directory -Path $script:Config.ReportRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path = Join-Path $script:Config.ReportRoot "FH6_SaveDoctor_Report_$stamp.txt"
    $body = New-Object System.Collections.Generic.List[string]
    [void]$body.Add("FH6 Save Doctor Report")
    [void]$body.Add("Generated: $(Get-Date)")
    [void]$body.Add("")
    [void]$body.Add("== Status ==")
    [void]$body.Add((Get-StatusSummary))
    [void]$body.Add("")
    [void]$body.Add("== System Diagnostics ==")
    [void]$body.Add((Get-SystemDiagnosticSummary))
    [void]$body.Add("")
    [void]$body.Add("== Inventory ==")
    foreach ($record in $Records | Sort-Object Category, Path) {
        [void]$body.Add("[$($record.Category)] exists=$($record.Exists) cleanable=$($record.Cleanable) sizeMB=$($record.SizeMB) items=$($record.Items) modified=$($record.LastWriteTime)")
        [void]$body.Add("  $($record.Path)")
        [void]$body.Add("  $($record.Description)")
    }
    [void]$body.Add("")
    [void]$body.Add("== Crash Summary ==")
    [void]$body.Add((Get-CrashSummary))
    $body -join [Environment]::NewLine | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
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

function Start-NoGuiScan {
    $records = @(Get-FH6Inventory)
    Write-Output (Get-StatusSummary)
    Write-Output ''
    Write-Output 'System diagnostics:'
    Write-Output (Get-SystemDiagnosticSummary)
    Write-Output ''
    Write-Output 'Inventory:'
    $records | Sort-Object Category, Path | Format-Table Category, Exists, Cleanable, SizeMB, Items, LastWriteTime, Path -AutoSize
    Write-Output ''
    Write-Output 'Crash summary:'
    Write-Output (Get-CrashSummary)
}

if ($NoGui) {
    Start-NoGuiScan
    return
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and $PSCommandPath) {
    $exe = (Get-Process -Id $PID).Path
    try {
        Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
        return
    }
    catch {
        Write-Warning "Could not relaunch in STA mode. Continuing anyway: $($_.Exception.Message)"
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Items = @()
$script:ItemsById = @{}
$script:MonitorActive = $false
$script:MonitorRunCount = 0
$script:MonitorLastAction = 'Idle'

New-Item -ItemType Directory -Path $script:Config.LogRoot -Force | Out-Null
$script:RunLogPath = Join-Path $script:Config.LogRoot ("FH6_SaveDoctor_Run_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
"FH6 Save Doctor run started: $(Get-Date)" | Set-Content -LiteralPath $script:RunLogPath -Encoding UTF8

$form = New-Object System.Windows.Forms.Form
$form.Text = 'FH6 Save Doctor v2'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1240, 880)
$form.MinimumSize = New-Object System.Drawing.Size(1100, 760)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Forza Horizon 6 Save Doctor v2'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(12, 10)
$form.Controls.Add($lblTitle)

$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.Font = New-Object System.Drawing.Font('Consolas', 8.8)
$lblSummary.Location = New-Object System.Drawing.Point(14, 42)
$lblSummary.Size = New-Object System.Drawing.Size(1200, 78)
$lblSummary.Text = 'Scanning...'
$form.Controls.Add($lblSummary)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object System.Drawing.Point(12, 128)
$list.Size = New-Object System.Drawing.Size(1200, 360)
$list.View = [System.Windows.Forms.View]::Details
$list.CheckBoxes = $true
$list.FullRowSelect = $true
$list.GridLines = $true
[void]$list.Columns.Add('Category', 105)
[void]$list.Columns.Add('Exists', 55)
[void]$list.Columns.Add('Size MB', 70)
[void]$list.Columns.Add('Items', 60)
[void]$list.Columns.Add('Modified', 135)
[void]$list.Columns.Add('Risk', 90)
[void]$list.Columns.Add('Path', 665)
$form.Controls.Add($list)

$chkBackup = New-Object System.Windows.Forms.CheckBox
$chkBackup.Text = 'Back up before delete/rename'
$chkBackup.Checked = $true
$chkBackup.AutoSize = $true
$chkBackup.Location = New-Object System.Drawing.Point(14, 500)
$form.Controls.Add($chkBackup)

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = 'Dry run'
$chkDryRun.Checked = $false
$chkDryRun.AutoSize = $true
$chkDryRun.Location = New-Object System.Drawing.Point(230, 500)
$form.Controls.Add($chkDryRun)

$chkStopGame = New-Object System.Windows.Forms.CheckBox
$chkStopGame.Text = 'Stop FH6 if running'
$chkStopGame.Checked = $false
$chkStopGame.AutoSize = $true
$chkStopGame.Location = New-Object System.Drawing.Point(325, 500)
$form.Controls.Add($chkStopGame)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = 'Scan'
$btnScan.Location = New-Object System.Drawing.Point(14, 528)
$btnScan.Size = New-Object System.Drawing.Size(92, 30)
$form.Controls.Add($btnScan)

$btnSelectSaves = New-Object System.Windows.Forms.Button
$btnSelectSaves.Text = 'Select Saves'
$btnSelectSaves.Location = New-Object System.Drawing.Point(112, 528)
$btnSelectSaves.Size = New-Object System.Drawing.Size(102, 30)
$form.Controls.Add($btnSelectSaves)

$btnSelectDeep = New-Object System.Windows.Forms.Button
$btnSelectDeep.Text = 'Select Saves+Cache'
$btnSelectDeep.Location = New-Object System.Drawing.Point(220, 528)
$btnSelectDeep.Size = New-Object System.Drawing.Size(135, 30)
$form.Controls.Add($btnSelectDeep)

$btnClearSelection = New-Object System.Windows.Forms.Button
$btnClearSelection.Text = 'Clear Selection'
$btnClearSelection.Location = New-Object System.Drawing.Point(361, 528)
$btnClearSelection.Size = New-Object System.Drawing.Size(112, 30)
$form.Controls.Add($btnClearSelection)

$btnBackup = New-Object System.Windows.Forms.Button
$btnBackup.Text = 'Backup Selected'
$btnBackup.Location = New-Object System.Drawing.Point(491, 528)
$btnBackup.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnBackup)

$btnRename = New-Object System.Windows.Forms.Button
$btnRename.Text = 'Rename Selected'
$btnRename.Location = New-Object System.Drawing.Point(622, 528)
$btnRename.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnRename)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = 'Delete Selected'
$btnDelete.Location = New-Object System.Drawing.Point(753, 528)
$btnDelete.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnDelete)

$btnFresh = New-Object System.Windows.Forms.Button
$btnFresh.Text = 'Fresh Start Saves'
$btnFresh.Location = New-Object System.Drawing.Point(884, 528)
$btnFresh.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnFresh)

$btnDeepFresh = New-Object System.Windows.Forms.Button
$btnDeepFresh.Text = 'Deep Fresh Start'
$btnDeepFresh.Location = New-Object System.Drawing.Point(1015, 528)
$btnDeepFresh.Size = New-Object System.Drawing.Size(117, 30)
$form.Controls.Add($btnDeepFresh)

$btnCloud = New-Object System.Windows.Forms.Button
$btnCloud.Text = 'Steam Cloud Steps'
$btnCloud.Location = New-Object System.Drawing.Point(14, 566)
$btnCloud.Size = New-Object System.Drawing.Size(135, 28)
$form.Controls.Add($btnCloud)

$btnClearReports = New-Object System.Windows.Forms.Button
$btnClearReports.Text = 'Clear Crash Reports'
$btnClearReports.Location = New-Object System.Drawing.Point(155, 566)
$btnClearReports.Size = New-Object System.Drawing.Size(135, 28)
$form.Controls.Add($btnClearReports)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'Export Report'
$btnExport.Location = New-Object System.Drawing.Point(296, 566)
$btnExport.Size = New-Object System.Drawing.Size(115, 28)
$form.Controls.Add($btnExport)

$btnOpenBackup = New-Object System.Windows.Forms.Button
$btnOpenBackup.Text = 'Open Backups'
$btnOpenBackup.Location = New-Object System.Drawing.Point(678, 566)
$btnOpenBackup.Size = New-Object System.Drawing.Size(115, 28)
$form.Controls.Add($btnOpenBackup)

$btnOpenLocal = New-Object System.Windows.Forms.Button
$btnOpenLocal.Text = 'Open FH6 AppData'
$btnOpenLocal.Location = New-Object System.Drawing.Point(799, 566)
$btnOpenLocal.Size = New-Object System.Drawing.Size(135, 28)
$form.Controls.Add($btnOpenLocal)

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = 'Restore Backup'
$btnRestore.Location = New-Object System.Drawing.Point(417, 566)
$btnRestore.Size = New-Object System.Drawing.Size(125, 28)
$form.Controls.Add($btnRestore)

$btnDiagnostics = New-Object System.Windows.Forms.Button
$btnDiagnostics.Text = 'Diagnostics'
$btnDiagnostics.Location = New-Object System.Drawing.Point(548, 566)
$btnDiagnostics.Size = New-Object System.Drawing.Size(115, 28)
$form.Controls.Add($btnDiagnostics)

$lblMonitor = New-Object System.Windows.Forms.Label
$lblMonitor.Text = 'Monitor:'
$lblMonitor.Location = New-Object System.Drawing.Point(14, 604)
$lblMonitor.Size = New-Object System.Drawing.Size(60, 24)
$form.Controls.Add($lblMonitor)

$cmbMonitorMode = New-Object System.Windows.Forms.ComboBox
$cmbMonitorMode.DropDownStyle = 'DropDownList'
[void]$cmbMonitorMode.Items.Add('Saves only')
[void]$cmbMonitorMode.Items.Add('Saves + cache')
$cmbMonitorMode.SelectedIndex = 0
$cmbMonitorMode.Location = New-Object System.Drawing.Point(76, 600)
$cmbMonitorMode.Size = New-Object System.Drawing.Size(125, 28)
$form.Controls.Add($cmbMonitorMode)

$lblEvery = New-Object System.Windows.Forms.Label
$lblEvery.Text = 'Every'
$lblEvery.Location = New-Object System.Drawing.Point(214, 604)
$lblEvery.Size = New-Object System.Drawing.Size(42, 24)
$form.Controls.Add($lblEvery)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Minimum = 10
$numInterval.Maximum = 600
$numInterval.Value = 30
$numInterval.Increment = 5
$numInterval.Location = New-Object System.Drawing.Point(255, 600)
$numInterval.Size = New-Object System.Drawing.Size(70, 28)
$form.Controls.Add($numInterval)

$lblSeconds = New-Object System.Windows.Forms.Label
$lblSeconds.Text = 'sec'
$lblSeconds.Location = New-Object System.Drawing.Point(331, 604)
$lblSeconds.Size = New-Object System.Drawing.Size(35, 24)
$form.Controls.Add($lblSeconds)

$btnMonitor = New-Object System.Windows.Forms.Button
$btnMonitor.Text = 'Start Monitor'
$btnMonitor.Location = New-Object System.Drawing.Point(372, 598)
$btnMonitor.Size = New-Object System.Drawing.Size(118, 30)
$form.Controls.Add($btnMonitor)

$lblMonitorStatus = New-Object System.Windows.Forms.Label
$lblMonitorStatus.Text = 'Idle'
$lblMonitorStatus.Location = New-Object System.Drawing.Point(500, 604)
$lblMonitorStatus.Size = New-Object System.Drawing.Size(810, 24)
$form.Controls.Add($lblMonitorStatus)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = 'Exit'
$btnExit.Location = New-Object System.Drawing.Point(1137, 566)
$btnExit.Size = New-Object System.Drawing.Size(75, 28)
$form.Controls.Add($btnExit)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 638)
$txtLog.Size = New-Object System.Drawing.Size(1200, 204)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

function Add-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    $txtLog.AppendText($line + [Environment]::NewLine)
    if ($script:RunLogPath) {
        Add-Content -LiteralPath $script:RunLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Refresh-Scan {
    try {
        $list.Items.Clear()
        $script:ItemsById = @{}
        $script:Items = @(Get-FH6Inventory)
        $lblSummary.Text = (Get-StatusSummary)
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
            if (-not $record.Cleanable) {
                $row.ForeColor = [System.Drawing.Color]::Gray
                $row.Checked = $false
            }
            [void]$list.Items.Add($row)
            $script:ItemsById[$record.Id] = $record
        }
        Add-Log "Scan complete. Found $($script:Items.Count) FH6-related records."
        Add-Log ((Get-CrashSummary) -replace [Environment]::NewLine, ' | ')
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Scan failed', 'OK', 'Error') | Out-Null
        Add-Log "Scan failed: $($_.Exception.Message)"
    }
}

function Get-SelectedRecords {
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($row in $list.Items) {
        if ($row.Checked -and $script:ItemsById.ContainsKey($row.Tag)) {
            $record = $script:ItemsById[$row.Tag]
            if ($record.Cleanable) { [void]$selected.Add($record) }
        }
    }
    return $selected.ToArray()
}

function Set-SelectionByCategory {
    param([string[]]$Categories)
    foreach ($row in $list.Items) {
        if ($script:ItemsById.ContainsKey($row.Tag)) {
            $record = $script:ItemsById[$row.Tag]
            $row.Checked = ($record.Cleanable -and $record.Exists -and ($Categories -contains $record.Category))
        }
    }
}

function Invoke-GuiAction {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][object[]]$Records
    )
    if ($Records.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Nothing selected.', 'FH6 Save Doctor', 'OK', 'Information') | Out-Null
        return
    }

    $preview = ($Records | Select-Object -First 8 | ForEach-Object { " - $($_.Path)" }) -join [Environment]::NewLine
    if ($Records.Count -gt 8) { $preview += [Environment]::NewLine + " - ...and $($Records.Count - 8) more" }
    $message = "$Action $($Records.Count) selected item(s)?`n`n$preview`n`nSteam Cloud should be off before deleting FH6 saves."
    $answer = [System.Windows.Forms.MessageBox]::Show($message, "Confirm $Action", 'OKCancel', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) {
        Add-Log "$Action cancelled."
        return
    }

    try {
        Invoke-Preflight -StopGame $chkStopGame.Checked -Log ${function:Add-Log} | Out-Null
        if ($chkBackup.Checked -and -not $chkDryRun.Checked) {
            Backup-FH6Targets -Records $Records -Log ${function:Add-Log} | Out-Null
        }
        elseif ($chkBackup.Checked -and $chkDryRun.Checked) {
            Add-Log 'DRY RUN backup: would create a zip backup before action.'
        }

        switch ($Action) {
            'Rename' { Rename-FH6Targets -Records $Records -DryRun $chkDryRun.Checked -Log ${function:Add-Log} }
            'Delete' { Remove-FH6Targets -Records $Records -DryRun $chkDryRun.Checked -Log ${function:Add-Log} }
            default { throw "Unknown action: $Action" }
        }
        Refresh-Scan
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "$Action failed", 'OK', 'Error') | Out-Null
        Add-Log "$Action failed: $($_.Exception.Message)"
    }
}

function Get-AutoModeCategories {
    if ($cmbMonitorMode.SelectedItem -eq 'Saves + cache') {
        return @('Save', 'Cache/Settings')
    }
    return @('Save')
}

function Invoke-MonitorCleanup {
    try {
        $script:MonitorRunCount++
        $categories = @(Get-AutoModeCategories)
        $records = @(Get-FH6Inventory | Where-Object {
            $_.Exists -and $_.Cleanable -and ($categories -contains $_.Category)
        })
        $processes = @(Get-FH6Process)
        if ($processes.Count -gt 0 -and -not $chkStopGame.Checked) {
            $script:MonitorLastAction = "Skipped: FH6 running"
            Add-Log "Monitor tick #$($script:MonitorRunCount): FH6 is running, skipped cleanup."
            return
        }
        if ($records.Count -eq 0) {
            $script:MonitorLastAction = "Nothing found"
            Add-Log "Monitor tick #$($script:MonitorRunCount): no matching FH6 $($categories -join '+') data found."
            return
        }

        Add-Log "Monitor tick #$($script:MonitorRunCount): found $($records.Count) matching item(s)."
        Invoke-Preflight -StopGame $chkStopGame.Checked -Log ${function:Add-Log} | Out-Null
        if ($chkBackup.Checked -and -not $chkDryRun.Checked) {
            Backup-FH6Targets -Records $records -Log ${function:Add-Log} | Out-Null
        }
        elseif ($chkBackup.Checked -and $chkDryRun.Checked) {
            Add-Log 'DRY RUN monitor backup: would create a zip backup before cleanup.'
        }
        Remove-FH6Targets -Records $records -DryRun $chkDryRun.Checked -Log ${function:Add-Log}
        $script:MonitorLastAction = "Cleaned $($records.Count) item(s)"
        Refresh-Scan
    }
    catch {
        $script:MonitorLastAction = "Error: $($_.Exception.Message)"
        Add-Log "Monitor cleanup failed: $($_.Exception.Message)"
    }
    finally {
        $lblMonitorStatus.Text = "Ticks: $($script:MonitorRunCount). Last: $script:MonitorLastAction"
    }
}

$monitorTimer = New-Object System.Windows.Forms.Timer
$monitorTimer.Interval = [int]$numInterval.Value * 1000
$monitorTimer.Add_Tick({
    if (-not $script:MonitorActive) { return }
    $monitorTimer.Stop()
    try {
        Invoke-MonitorCleanup
    }
    finally {
        $monitorTimer.Interval = [int]$numInterval.Value * 1000
        if ($script:MonitorActive) { $monitorTimer.Start() }
    }
})

function Show-TextWindow {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Text
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = 'CenterParent'
    $dialog.Size = New-Object System.Drawing.Size(920, 620)
    $dialog.MinimumSize = New-Object System.Drawing.Size(720, 460)

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

$btnScan.Add_Click({ Refresh-Scan })
$btnSelectSaves.Add_Click({ Set-SelectionByCategory -Categories @('Save') })
$btnSelectDeep.Add_Click({ Set-SelectionByCategory -Categories @('Save', 'Cache/Settings') })
$btnClearSelection.Add_Click({ foreach ($row in $list.Items) { $row.Checked = $false } })
$btnBackup.Add_Click({
    $records = @(Get-SelectedRecords)
    if ($records.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Nothing selected.', 'FH6 Save Doctor', 'OK', 'Information') | Out-Null
        return
    }
    try {
        $zip = Backup-FH6Targets -Records $records -Log ${function:Add-Log}
        if ($zip) { [System.Windows.Forms.MessageBox]::Show("Backup written:`n$zip", 'Backup complete', 'OK', 'Information') | Out-Null }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Backup failed', 'OK', 'Error') | Out-Null
        Add-Log "Backup failed: $($_.Exception.Message)"
    }
})
$btnRename.Add_Click({ Invoke-GuiAction -Action 'Rename' -Records @(Get-SelectedRecords) })
$btnDelete.Add_Click({ Invoke-GuiAction -Action 'Delete' -Records @(Get-SelectedRecords) })
$btnFresh.Add_Click({
    Set-SelectionByCategory -Categories @('Save')
    Invoke-GuiAction -Action 'Delete' -Records @(Get-SelectedRecords)
})
$btnDeepFresh.Add_Click({
    Set-SelectionByCategory -Categories @('Save', 'Cache/Settings')
    Invoke-GuiAction -Action 'Delete' -Records @(Get-SelectedRecords)
})
$btnCloud.Add_Click({
    $msg = @"
Steam Cloud must be off before a real fresh-start test:

1. Open Steam Library.
2. Right-click Forza Horizon 6.
3. Choose Properties.
4. Open General.
5. Turn off "Keep games saves in the Steam Cloud for Forza Horizon 6".

Launch FH6 once with Steam Cloud off. If it creates new clean local data and loads, exit normally before deciding whether to re-enable Steam Cloud.
"@
    [System.Windows.Forms.MessageBox]::Show($msg, 'Steam Cloud steps', 'OK', 'Information') | Out-Null
})
$btnClearReports.Add_Click({
    Set-SelectionByCategory -Categories @('Crash Report')
    Invoke-GuiAction -Action 'Delete' -Records @(Get-SelectedRecords)
})
$btnExport.Add_Click({
    try {
        $path = Export-FH6Report -Records $script:Items
        Add-Log "Report exported: $path"
        [System.Windows.Forms.MessageBox]::Show("Report exported:`n$path", 'Report exported', 'OK', 'Information') | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Export failed', 'OK', 'Error') | Out-Null
        Add-Log "Export failed: $($_.Exception.Message)"
    }
})
$btnRestore.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Choose FH6 Save Doctor backup zip'
    $dialog.InitialDirectory = $script:Config.BackupRoot
    $dialog.Filter = 'FH6 Save Doctor backups (*.zip)|*.zip|All files (*.*)|*.*'
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Restore this backup?`n`n$($dialog.FileName)`n`nAny current matching FH6 local save/cache folders will be renamed with a .pre_restore suffix first.",
        'Confirm restore',
        'OKCancel',
        'Warning'
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) {
        Add-Log 'Restore cancelled.'
        return
    }
    try {
        Invoke-Preflight -StopGame $chkStopGame.Checked -Log ${function:Add-Log} | Out-Null
        Restore-FH6Backup -ZipPath $dialog.FileName -DryRun $chkDryRun.Checked -Log ${function:Add-Log}
        Refresh-Scan
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Restore failed', 'OK', 'Error') | Out-Null
        Add-Log "Restore failed: $($_.Exception.Message)"
    }
})
$btnDiagnostics.Add_Click({
    $text = @(
        '== Status ==',
        (Get-StatusSummary),
        '',
        '== System Diagnostics ==',
        (Get-SystemDiagnosticSummary),
        '',
        '== Crash Summary ==',
        (Get-CrashSummary),
        '',
        "Run log: $script:RunLogPath"
    ) -join [Environment]::NewLine
    Show-TextWindow -Title 'FH6 Save Doctor Diagnostics' -Text $text
})
$btnOpenBackup.Add_Click({
    New-Item -ItemType Directory -Path $script:Config.BackupRoot -Force | Out-Null
    Start-Process -FilePath $script:Config.BackupRoot
})
$btnOpenLocal.Add_Click({
    New-Item -ItemType Directory -Path $script:Config.LocalRoot -Force | Out-Null
    Start-Process -FilePath $script:Config.LocalRoot
})
$btnMonitor.Add_Click({
    if (-not $script:MonitorActive) {
        $mode = [string]$cmbMonitorMode.SelectedItem
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Start monitor mode?`n`nMode: $mode`nInterval: $([int]$numInterval.Value) seconds`n`nIt will repeatedly scan and delete matching recreated FH6 local data. It skips while FH6 is running unless 'Stop FH6 if running' is checked.",
            'Start monitor',
            'OKCancel',
            'Warning'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:MonitorActive = $true
        $script:MonitorRunCount = 0
        $script:MonitorLastAction = 'Started'
        $btnMonitor.Text = 'Stop Monitor'
        $lblMonitorStatus.Text = "Running: $mode every $([int]$numInterval.Value)s"
        Add-Log "Monitor started. Mode=$mode Interval=$([int]$numInterval.Value)s DryRun=$($chkDryRun.Checked) Backup=$($chkBackup.Checked)"
        $monitorTimer.Interval = [int]$numInterval.Value * 1000
        $monitorTimer.Start()
    }
    else {
        $script:MonitorActive = $false
        $monitorTimer.Stop()
        $btnMonitor.Text = 'Start Monitor'
        $lblMonitorStatus.Text = "Stopped. Ticks: $($script:MonitorRunCount). Last: $script:MonitorLastAction"
        Add-Log "Monitor stopped after $($script:MonitorRunCount) tick(s). Last=$script:MonitorLastAction"
    }
})
$btnExit.Add_Click({ $form.Close() })
$form.Add_FormClosing({
    $script:MonitorActive = $false
    $monitorTimer.Stop()
    Add-Log 'FH6 Save Doctor closing.'
})

Refresh-Scan
[void][System.Windows.Forms.Application]::Run($form)
