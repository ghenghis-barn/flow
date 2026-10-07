[CmdletBinding()]
param(
    [ValidateSet('Status', 'Ensure')]
    [string]$Action = 'Ensure',
    [ValidateRange(1, 65535)]
    [int]$ChromePort = 9344,
    [string]$ProfilePath = "$env:LOCALAPPDATA\Aurora\JiraChromeCDP-9344",
    [string]$JiraOrigin = 'https://auroraenergy.atlassian.net',
    [ValidateRange(1, 60)]
    [int]$StartupTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
function Assert-DedicatedProfilePath {
    $profileFullPath = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    $generalChromeRoot = [IO.Path]::GetFullPath(
        "$env:LOCALAPPDATA\Google\Chrome\User Data"
    ).TrimEnd('\')
    $generalChromePrefix = "$generalChromeRoot\"
    if (
        $profileFullPath.Equals($generalChromeRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $profileFullPath.StartsWith($generalChromePrefix, [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw 'ProfilePath must be a dedicated automation profile outside the general Chrome User Data directory.'
    }
}

Assert-DedicatedProfilePath


function Get-ChromePath {
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $path = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $path) { throw 'Google Chrome was not found.' }
    return $path
}

function Get-ProfileProcesses {
    $portFlag = "--remote-debugging-port=$ChromePort"
    $profileFlags = @(
        "--user-data-dir=$ProfilePath",
        "--user-data-dir=`"$ProfilePath`""
    )
    return @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" | Where-Object {
        $commandLine = $_.CommandLine
        $commandLine -and
        $commandLine.Contains($portFlag) -and
        ($profileFlags | Where-Object { $commandLine.Contains($_) }) -and
        -not $commandLine.Contains('--type=')
    })
}

function Get-CdpHealth {
    try {
        $version = Invoke-RestMethod -Uri "http://127.0.0.1:${ChromePort}/json/version" -TimeoutSec 2
        return $version.Browser -match '^Chrome/' -and $version.'User-Agent' -match 'Windows NT.*Chrome/'
    }
    catch {
        return $false
    }
}

function Test-JiraTab {
    try {
        $origin = ([Uri]$JiraOrigin).GetLeftPart([UriPartial]::Authority).TrimEnd('/')
        $targets = Invoke-RestMethod -Uri "http://127.0.0.1:${ChromePort}/json/list" -TimeoutSec 2
        foreach ($target in $targets) {
            if ($target.type -ne 'page') { continue }
            try {
                $targetOrigin = ([Uri]$target.url).GetLeftPart([UriPartial]::Authority).TrimEnd('/')
                if ($targetOrigin -eq $origin) { return $true }
            }
            catch {
                continue
            }
        }
        return $false
    }
    catch {
        return $false
    }
}

function Get-Status {
    $processes = @(Get-ProfileProcesses)
    $browserHealthy = Get-CdpHealth
    $jiraTabPresent = $browserHealthy -and (Test-JiraTab)
    return [pscustomobject]@{
        Healthy = $processes.Count -eq 1 -and $browserHealthy -and $jiraTabPresent
        BrowserHealthy = $browserHealthy
        JiraTabPresent = $jiraTabPresent
        ProcessCount = $processes.Count
        ProcessId = if ($processes.Count -eq 1) { $processes[0].ProcessId } else { $null }
        ChromePort = $ChromePort
        ProfilePath = $ProfilePath
        JiraOrigin = $JiraOrigin
        SessionIsolation = 'dedicated-profile-and-window'
    }
}

$status = Get-Status
if ($Action -eq 'Status') {
    $status | ConvertTo-Json -Compress
    if (-not $status.Healthy) { exit 1 }
    exit 0
}

if ($status.ProcessCount -gt 1) {
    throw "Multiple dedicated Jira Chrome roots use port $ChromePort; no process was changed."
}
if ($status.ProcessCount -eq 1 -and -not $status.BrowserHealthy) {
    throw "The dedicated Jira Chrome process exists but CDP port $ChromePort is unhealthy; no process was changed."
}
if ($status.Healthy) {
    $status | ConvertTo-Json -Compress
    exit 0
}
if ($status.ProcessCount -eq 0 -and $status.BrowserHealthy) {
    throw "CDP port $ChromePort belongs to an unexpected Chrome process; no process was changed."
}

$chromePath = Get-ChromePath
New-Item -ItemType Directory -Path $ProfilePath -Force | Out-Null
$arguments = @(
    "--remote-debugging-port=$ChromePort",
    '--remote-debugging-address=127.0.0.1',
    "--user-data-dir=`"$ProfilePath`"",
    '--new-window',
    '--no-first-run',
    '--no-default-browser-check',
    $JiraOrigin
)
Start-Process -FilePath $chromePath -ArgumentList $arguments | Out-Null

$deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
do {
    Start-Sleep -Milliseconds 500
    $status = Get-Status
    if ($status.Healthy) {
        $status | ConvertTo-Json -Compress
        exit 0
    }
} while ([DateTime]::UtcNow -lt $deadline)

throw "Dedicated Jira Chrome did not become healthy on port $ChromePort within $StartupTimeoutSeconds seconds."
