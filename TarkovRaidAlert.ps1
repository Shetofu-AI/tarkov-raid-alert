#Requires -Version 7

[CmdletBinding()]
param(
    [string] $LogsRoot,
    [string] $SoundFile = "$env:WINDIR\Media\Windows Notify System Generic.wav",
    [switch] $Test,
    [switch] $Hidden,
    [switch] $Install,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$SHORTCUT_NAME = 'TarkovRaidAlert.lnk'
$MUTEX_NAME = 'Local\TarkovRaidAlert'
$LOG_FILE = Join-Path $env:LOCALAPPDATA 'TarkovRaidAlert\watch.log'
$POLL_INTERVAL_MS = 500
$RESCAN_INTERVAL_MS = 3000
$READ_BUFFER_SIZE = 65536
$RAID_MARKERS = @(
    '|application|MatchingCompleted:'
    '|application|GameStarted:'
)
$ALERT_COOLDOWN_SECONDS = 120
$GAME_PROCESS_NAME = 'EscapeFromTarkov'

$script:PLAYER = $null
$script:LAST_ALERT = [datetime]::MinValue

function Write-Log
{
    param([string] $Message)

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$stamp] $Message"
    Write-Host $line

    $folder = Split-Path -Parent $LOG_FILE
    if (-not (Test-Path -LiteralPath $folder))
    {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    Add-Content -LiteralPath $LOG_FILE -Value $line -Encoding utf8
}

function Initialize-NativeInterop
{
    if ('Native.WindowState' -as [type])
    {
        return
    }

    Add-Type -Namespace 'Native' -Name 'WindowState' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
'@
}

function Hide-ConsoleWindow
{
    Initialize-NativeInterop

    $window = [Native.WindowState]::GetConsoleWindow()
    if ($window -ne [IntPtr]::Zero)
    {
        [Native.WindowState]::ShowWindow($window, 0) | Out-Null
    }
}

function Get-ForegroundProcessName
{
    Initialize-NativeInterop

    $window = [Native.WindowState]::GetForegroundWindow()
    if ($window -eq [IntPtr]::Zero)
    {
        return '<нет окна>'
    }

    $processId = [uint32] 0
    [Native.WindowState]::GetWindowThreadProcessId($window, [ref] $processId) | Out-Null
    if ($processId -eq 0)
    {
        return '<нет процесса>'
    }

    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process)
    {
        return "<pid $processId>"
    }

    return $process.ProcessName
}

function Resolve-LogsRoot
{
    param([string] $Explicit)

    if ($Explicit)
    {
        if (-not (Test-Path -LiteralPath $Explicit))
        {
            throw "Папка логов не найдена: $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($uninstallPath in $uninstallPaths)
    {
        $entries = Get-ItemProperty -Path $uninstallPath -ErrorAction SilentlyContinue
        foreach ($entry in $entries)
        {
            if ($entry.DisplayName -ne 'Escape from Tarkov')
            {
                continue
            }
            if (-not $entry.InstallLocation)
            {
                continue
            }

            $candidate = Join-Path $entry.InstallLocation 'Logs'
            if (Test-Path -LiteralPath $candidate)
            {
                return $candidate
            }
        }
    }

    throw 'Установка Escape from Tarkov не найдена в реестре. Укажи папку явно: -LogsRoot "E:\Games\EscapeFromTarkov\Logs"'
}

function Get-LatestLogFile
{
    param([string] $Root)

    $recentFolders = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 3

    $newest = $null
    foreach ($folder in $recentFolders)
    {
        $candidates = Get-ChildItem -LiteralPath $folder.FullName -Filter '*application_*.log' -File -ErrorAction SilentlyContinue
        foreach ($candidate in $candidates)
        {
            if ($null -eq $newest -or $candidate.LastWriteTimeUtc -gt $newest.LastWriteTimeUtc)
            {
                $newest = $candidate
            }
        }
    }

    return $newest
}

function Invoke-Alert
{
    param([string] $Marker)

    if (((Get-Date) - $script:LAST_ALERT).TotalSeconds -lt $ALERT_COOLDOWN_SECONDS)
    {
        Write-Log "$Marker — в пределах кулдауна, звук пропущен"
        return
    }
    $script:LAST_ALERT = Get-Date

    $foreground = Get-ForegroundProcessName
    if ($foreground -eq $GAME_PROCESS_NAME)
    {
        Write-Log "$Marker — игра в фокусе, звук пропущен"
        return
    }

    Write-Log "$Marker — играю звук (в фокусе: $foreground)"
    $script:PLAYER.Play()
}

function Start-Watch
{
    param([string] $Root)

    Write-Log "Логи: $Root"

    $buffer = [byte[]]::new($READ_BUFFER_SIZE)
    $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
    $characters = [char[]]::new($READ_BUFFER_SIZE)
    $pending = ''
    $activePath = $null
    $stream = $null
    $lastScan = [datetime]::MinValue

    while ($true)
    {
        if (((Get-Date) - $lastScan).TotalMilliseconds -ge $RESCAN_INTERVAL_MS)
        {
            $lastScan = Get-Date
            $latest = Get-LatestLogFile -Root $Root

            if ($null -ne $latest -and $latest.FullName -ne $activePath)
            {
                if ($null -ne $stream)
                {
                    $stream.Dispose()
                }

                $stream = [System.IO.File]::Open($latest.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                $stream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                $activePath = $latest.FullName
                $pending = ''
                $decoder.Reset()
                Write-Log "Слежу за $([System.IO.Path]::GetFileName($activePath))"
            }
        }

        if ($null -ne $stream)
        {
            if ($stream.Length -lt $stream.Position)
            {
                $stream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
                $pending = ''
                $decoder.Reset()
            }

            while ($true)
            {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0)
                {
                    break
                }

                $decoded = $decoder.GetChars($buffer, 0, $read, $characters, 0)
                $pending += [string]::new($characters, 0, $decoded)
            }

            $lastBreak = $pending.LastIndexOf("`n")
            if ($lastBreak -ge 0)
            {
                $completed = $pending.Substring(0, $lastBreak)
                $pending = $pending.Substring($lastBreak + 1)

                foreach ($line in $completed -split "`r?`n")
                {
                    foreach ($marker in $RAID_MARKERS)
                    {
                        if (-not $line.Contains($marker))
                        {
                            continue
                        }

                        Invoke-Alert -Marker $marker.Split('|')[-1].TrimEnd(':')
                        break
                    }
                }
            }
        }

        Start-Sleep -Milliseconds $POLL_INTERVAL_MS
    }
}

function Resolve-PowerShellPath
{
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if (Test-Path -LiteralPath $alias)
    {
        return $alias
    }

    return (Get-Process -Id $PID).Path
}

function Install-AutoStart
{
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) $SHORTCUT_NAME
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Resolve-PowerShellPath
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Hidden"
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.WindowStyle = 7
    $shortcut.Save()

    Write-Log "Автозапуск включён: $shortcutPath"
}

function Uninstall-AutoStart
{
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) $SHORTCUT_NAME
    if (Test-Path -LiteralPath $shortcutPath)
    {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Log "Автозапуск выключен: $shortcutPath"
        return
    }

    Write-Log 'Автозапуск и так не был включён'
}

if ($Install)
{
    Install-AutoStart
    return
}

if ($Uninstall)
{
    Uninstall-AutoStart
    return
}

if ($Hidden)
{
    Hide-ConsoleWindow
}

if (-not (Test-Path -LiteralPath $SoundFile))
{
    throw "Звуковой файл не найден: $SoundFile"
}
$script:PLAYER = New-Object System.Media.SoundPlayer -ArgumentList $SoundFile
$script:PLAYER.Load()

if ($Test)
{
    Invoke-Alert -Marker 'Проверка'
    Start-Sleep -Seconds 3
    return
}

$mutex = New-Object System.Threading.Mutex($false, $MUTEX_NAME)
if (-not $mutex.WaitOne(0))
{
    Write-Log 'Уже запущен другой экземпляр — выхожу'
    return
}

try
{
    Start-Watch -Root (Resolve-LogsRoot -Explicit $LogsRoot)
}
finally
{
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
