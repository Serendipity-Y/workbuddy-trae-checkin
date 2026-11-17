# Windows PowerShell 5.1. Preserves account configuration and secrets; replaces four files and adjusts only the two daily trigger times.
param(
  [string]$AgentRoot = 'C:\agentrouter-checkin',
  [string]$WorkerRoot = 'C:\workbuddy-trae-checkin',
  [switch]$VerifyRefresh,
  [string]$Rollback = ''
)
$ErrorActionPreference = 'Stop'
$payload = Join-Path $PSScriptRoot 'windows\agentrouter'
$reportPath = Join-Path $PSScriptRoot 'agentrouter-repair.log'
$backupRoot = Join-Path $AgentRoot 'repair-backups'
$python = Join-Path $AgentRoot '.venv\Scripts\python.exe'
$helperPath = Join-Path $AgentRoot 'helper.mjs'
$version = '2026-11-17.3'
$changed = @()
$taskBackups = @()
$reportSaved = $false
$backup = $null
$stage = Join-Path $env:TEMP ('AgentRouter repair ' + [guid]::NewGuid().ToString('N'))

function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function NormalizedHash([string]$Path) {
  $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").TrimEnd([char[]]"`r`n")
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}
function CopyChecked([string]$From, [string]$To) {
  Copy-Item -LiteralPath $From -Destination $To -Force
  if ((Hash $From) -ne (Hash $To)) { throw ('File verification failed: ' + $To) }
}
function StopHelper {
  foreach ($owner in @(Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)) {
    $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $owner)
    if ($process.Name -ne 'node.exe' -or $process.CommandLine.IndexOf($helperPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
      throw 'Port 8788 belongs to an unexpected process; nothing was stopped.'
    }
    Stop-Process -Id $owner -Force
    Wait-Process -Id $owner -Timeout 10 -ErrorAction SilentlyContinue
  }
}
function StartHelper {
  Start-ScheduledTask -TaskName 'AgentRouter-Helper'
  for ($i=0; $i -lt 30; $i++) {
    try { return Invoke-RestMethod 'http://127.0.0.1:8788/health' -TimeoutSec 2 }
    catch { Start-Sleep -Milliseconds 500 }
  }
  throw 'Helper did not start; inspect helper.log.'
}
function RestoreFiles($Entries) {
  foreach ($entry in @($Entries)) {
    if ((Hash $entry.Backup) -ne $entry.OriginalHash) { throw ('Backup validation failed: ' + $entry.Backup) }
  }
  foreach ($entry in @($Entries)) { CopyChecked $entry.Backup $entry.Target }
}
function SaveReport($Data) {
  $json = $Data | ConvertTo-Json -Depth 8
  Set-Content -LiteralPath $reportPath -Value $json -Encoding UTF8
  $archive = Join-Path $PSScriptRoot ('agentrouter-repair-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
  Set-Content -LiteralPath $archive -Value $json -Encoding UTF8
  $script:reportSaved=$true
}
function Update-Baseline([string]$ManifestPath, [hashtable]$Current) {
  # Record what was actually installed so the next run accepts this version.
  $data = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($key in @('Worker','Helper','Run')) {
    $value = $Current[$key]
    if (-not $value) { continue }
    $existing = @($data.Baseline.$key)
    if ($value -notin $existing) { $data.Baseline.$key = @($existing + $value) }
  }
  $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
}
function DailyTimes([string]$TaskName) {
  @((Get-ScheduledTask -TaskName $TaskName).Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' } | ForEach-Object {
    ([datetime]$_.StartBoundary).ToString('HH:mm')
  } | Sort-Object)
}
function Test-DailyTimes([string]$TaskName, [string[]]$Times) {
  $actual = @(DailyTimes $TaskName)
  $expected = @($Times | Sort-Object)
  return (($actual -join ',') -eq ($expected -join ','))
}
function Set-DailyTimes([string]$TaskName, [string[]]$Times) {
  $triggers = @($Times | ForEach-Object { New-ScheduledTaskTrigger -Daily -At $_ })
  Set-ScheduledTask -TaskName $TaskName -Trigger $triggers | Out-Null
}
function Apply-Tasks($Items) {
  foreach ($item in @($Items)) {
    Set-DailyTimes $item.Name $item.Times
    if (-not (Test-DailyTimes $item.Name $item.Times)) { throw ('Task trigger verification failed: ' + $item.Name) }
  }
}
function Backup-Tasks($Items, [string]$Dir) {
  $out = @()
  foreach ($item in @($Items)) {
    $file = Join-Path $Dir ($item.Name + '.xml')
    Export-ScheduledTask -TaskName $item.Name | Set-Content -LiteralPath $file -Encoding UTF8
    $out += [pscustomobject]@{ Name=$item.Name; Backup=$file; OriginalHash=(Hash $file); Times=@($item.Times) }
  }
  return $out
}
function Restore-Tasks($Items) {
  foreach ($entry in @($Items)) {
    if (-not $entry) { continue }
    if ((Hash $entry.Backup) -ne $entry.OriginalHash) { throw ('Task backup validation failed: ' + $entry.Backup) }
    $xml = Get-Content -LiteralPath $entry.Backup -Raw
    Register-ScheduledTask -TaskName $entry.Name -Xml $xml -Force | Out-Null
  }
}
function ReadBalance {
  $vars = [IO.File]::ReadAllText((Join-Path $WorkerRoot '.dev.vars'))
  $match = [regex]::Match($vars, '(?m)^\s*ADMIN_TOKEN\s*=\s*([^\r\n]+)')
  if (-not $match.Success) { throw 'Worker ADMIN_TOKEN is not configured.' }
  $tokenValue = $match.Groups[1].Value.Trim().Trim([char[]]'"''')
  $headers = @{ 'X-Admin-Token' = $tokenValue }
  $data = Invoke-RestMethod 'http://127.0.0.1:8787/agentrouter/api/list' -Headers $headers -TimeoutSec 10
  $summary = Invoke-RestMethod 'http://127.0.0.1:8787/api/summary' -Headers $headers -TimeoutSec 10
  return [pscustomobject]@{ Count=$data.count; Accounts=@($data.accounts); Summary=$summary }
}
function TestFileOperations {
  # Native backup/restore and integrity checks, including paths with spaces.
  $test = Join-Path $stage ('file operations ' + [char]0x4e2d); New-Item -ItemType Directory -Path $test -Force | Out-Null
  $original = Join-Path $test 'original.txt'; $copy = Join-Path $test 'backup.txt'; $replacement = Join-Path $test 'new.txt'
  [IO.File]::WriteAllText($original, 'original'); [IO.File]::WriteAllText($replacement, 'replacement')
  CopyChecked $original $copy
  $entry = [pscustomobject]@{ Target=$original; Backup=$copy; OriginalHash=(Hash $copy) }
  CopyChecked $replacement $original; RestoreFiles @($entry)
  if ([IO.File]::ReadAllText($original) -ne 'original') { throw 'Restore self-test failed.' }
  [IO.File]::WriteAllText($copy, 'corrupt')
  $rejected = $false
  try { RestoreFiles @($entry) } catch { $rejected = $true }
  if (-not $rejected) { throw 'Corrupt backup was accepted.' }
}

try {
  foreach ($required in @($python, $helperPath, (Join-Path $AgentRoot 'login_checkin.py'), (Join-Path $AgentRoot 'run-checkin.cmd'), (Join-Path $WorkerRoot 'worker.js'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw ('Required target missing: ' + $required) }
  }
  $taskPlan = @(
    [pscustomobject]@{ Name='AgentRouter-CheckIn'; Times=@('10:20','12:00'); Required=$true; Action=(Join-Path $AgentRoot 'run-checkin.cmd') },
    [pscustomobject]@{ Name='WorkBuddyCheckin-Daily'; Times=@('10:00','12:00'); Required=$false; Action=(Join-Path $WorkerRoot 'run-cron.cmd') }
  )
  $taskEntries = @()
  foreach ($plan in $taskPlan) {
    $scheduled = Get-ScheduledTask -TaskName $plan.Name -ErrorAction SilentlyContinue
    if (-not $scheduled) {
      if ($plan.Required) { throw ('Required scheduled task missing: ' + $plan.Name) }
      Write-Warning ('Scheduled task missing; trigger unchanged: ' + $plan.Name)
      continue
    }
    if ($scheduled.State -eq 'Running') { throw ('Scheduled task is running; wait: ' + $plan.Name) }
    if ($scheduled.Actions[0].Execute -ne $plan.Action) { throw ('Unexpected scheduled task target: ' + $plan.Name) }
    $taskEntries += $plan
  }
  $helperTask = Get-ScheduledTask -TaskName 'AgentRouter-Helper'
  if ($helperTask.Actions[0].WorkingDirectory -ne $AgentRoot) { throw 'Unexpected helper task directory.' }
  $activeLogin = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^python' -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith($AgentRoot, [StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine -match 'login_checkin\.py'
  })
  if ($activeLogin.Count) { throw 'A login process is still running; wait for completion before repair.' }
  try {
    $health = Invoke-RestMethod 'http://127.0.0.1:8788/health' -TimeoutSec 3
    if ($health.running) { throw 'A helper refresh is running; wait for completion.' }
  } catch { if ($_.Exception.Message -like '*refresh is running*') { throw } }

  if ($Rollback) {
    $resolvedBackup = (Resolve-Path -LiteralPath $Rollback).Path
    if (-not $resolvedBackup.StartsWith($backupRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Rollback must use this installation backup directory.' }
    $saved = Get-Content -LiteralPath (Join-Path $resolvedBackup 'manifest.json') -Raw | ConvertFrom-Json
    $entries = @($saved.Entries)
    $savedTasks = @()
    if ($saved.PSObject.Properties.Name -contains 'Tasks') { $savedTasks = @($saved.Tasks) }
    $allowed = @((Join-Path $WorkerRoot 'worker.js'), $helperPath, (Join-Path $AgentRoot 'login_checkin.py'), (Join-Path $AgentRoot 'run-checkin.cmd'))
    foreach ($entry in $entries) {
      if ($entry.Target -notin $allowed -or -not $entry.Backup.StartsWith($resolvedBackup + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected rollback target.' }
      if ((Hash $entry.Target) -ne $entry.InstalledHash) { throw ('Target changed since repair; not overwriting: ' + $entry.Target) }
      if ((Hash $entry.Backup) -ne $entry.OriginalHash) { throw 'Backup is corrupt; not stopping services.' }
    }
    $allowedTasks = @('AgentRouter-CheckIn', 'WorkBuddyCheckin-Daily')
    foreach ($entry in $savedTasks) {
      if (-not $entry) { continue }
      if ($entry.Name -notin $allowedTasks -or -not $entry.Backup.StartsWith($resolvedBackup + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected task rollback target.' }
      if ((Hash $entry.Backup) -ne $entry.OriginalHash) { throw 'Task backup is corrupt; not stopping services.' }
    }
    StopHelper; RestoreFiles $entries; Restore-Tasks $savedTasks; $restoredHealth = StartHelper
    SaveReport @{ Status='RolledBack'; Backup=$resolvedBackup; Health=$restoredHealth; Tasks=@($savedTasks | ForEach-Object { $_.Name }); At=(Get-Date).ToString('o') }
    Write-Host 'Restored only the files and daily triggers recorded in the backup.'; exit 0
  }

  $manifest = Get-Content -LiteralPath (Join-Path $payload 'manifest.json') -Raw | ConvertFrom-Json
  foreach ($item in $manifest.Files) {
    $file = Join-Path $PSScriptRoot $item.Path
    if ((NormalizedHash $file) -ne $item.SHA256) { throw ('Payload changed or incomplete: ' + $item.Path) }
  }
  foreach ($item in @(@{Path=(Join-Path $WorkerRoot 'worker.js'); Old=$manifest.Baseline.Worker; New=(NormalizedHash (Join-Path $PSScriptRoot 'worker.js'))},
                      @{Path=$helperPath; Old=$manifest.Baseline.Helper; New=(NormalizedHash (Join-Path $payload 'helper.mjs'))},
                      @{Path=(Join-Path $AgentRoot 'run-checkin.cmd'); Old=$manifest.Baseline.Run; New=(NormalizedHash (Join-Path $payload 'run-checkin.cmd'))})) {
    if ((NormalizedHash $item.Path) -notin (@($item.Old) + @($item.New))) { throw ('Target differs from diagnosed version; no files replaced: ' + $item.Path) }
  }
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  TestFileOperations
  $nextPython = Join-Path $stage 'login_checkin.py'
  & $python (Join-Path $payload 'patch_login.py') (Join-Path $AgentRoot 'login_checkin.py') $nextPython
  if ($LASTEXITCODE -ne 0) { throw 'Python patch generation failed; no target files replaced.' }
  & $python (Join-Path $PSScriptRoot 'tests\login_patch.py') --patched $nextPython
  if ($LASTEXITCODE -ne 0) { throw 'Patched Python regression checks failed; no target files replaced.' }
  $node = 'C:\nodejs\node.exe'
  foreach ($test in @('tests\platforms.mjs','tests\worker_policy.mjs','tests\dashboard.mjs','tests\helper.mjs')) {
    & $node (Join-Path $PSScriptRoot $test)
    if ($LASTEXITCODE -ne 0) { throw ('Offline Node check failed: ' + $test) }
  }
  & $python (Join-Path $PSScriptRoot 'tests\manifest.py')
  if ($LASTEXITCODE -ne 0) { throw 'Payload newline compatibility check failed.' }
  $targets = @(
    @{ Target=(Join-Path $WorkerRoot 'worker.js'); Source=(Join-Path $PSScriptRoot 'worker.js') },
    @{ Target=$helperPath; Source=(Join-Path $payload 'helper.mjs') },
    @{ Target=(Join-Path $AgentRoot 'login_checkin.py'); Source=$nextPython },
    @{ Target=(Join-Path $AgentRoot 'run-checkin.cmd'); Source=(Join-Path $payload 'run-checkin.cmd') }
  )
  $alreadyCurrent = @($targets | Where-Object { (Hash $_.Target) -ne (Hash $_.Source) }).Count -eq 0
  if ($alreadyCurrent -and $health.version -eq $version) {
    & $python (Join-Path $AgentRoot 'login_checkin.py') --reconcile-local
    if ($LASTEXITCODE -ne 0) { throw 'Local receipt reconciliation failed; no platform request was made.' }
    $tasksCurrent = $true
    foreach ($item in $taskEntries) { if (-not (Test-DailyTimes $item.Name $item.Times)) { $tasksCurrent = $false } }
    if ($tasksCurrent) {
      SaveReport @{ Status='AlreadyInstalled'; Balance=(ReadBalance); At=(Get-Date).ToString('o'); Tasks='AlreadyCurrent'; Note='No repeat sign-in was triggered.' }
      Write-Host 'Repair already installed; only read existing balance. No repeat sign-in.'; exit 0
    }
    $backup = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-tasks-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $taskBackups = @(Backup-Tasks $taskEntries $backup)
    @{ Version=$version; Entries=@(); Tasks=$taskBackups } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8
    try { Apply-Tasks $taskEntries }
    catch {
      Restore-Tasks $taskBackups
      throw ('Scheduled task adjustment failed and was rolled back: ' + $_.Exception.Message)
    }
    SaveReport @{ Status='TasksAdjusted'; Backup=$backup; Tasks=@($taskEntries | ForEach-Object { $_.Name }); Balance=(ReadBalance); At=(Get-Date).ToString('o'); PlatformRequests=0 }
    Write-Host 'Daily triggers adjusted to the noon compensation window. No sign-in was triggered.'
    Write-Host ('Backup: ' + $backup)
    exit 0
  }
  $backup = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  $entries = @(foreach ($target in $targets) {
    $backupFile = Join-Path $backup ([IO.Path]::GetFileName($target.Target))
    CopyChecked $target.Target $backupFile
    [pscustomobject]@{ Target=$target.Target; Backup=$backupFile; OriginalHash=(Hash $backupFile); InstalledHash=(Hash $target.Source); Source=$target.Source }
  })
  $taskBackups = @(Backup-Tasks $taskEntries $backup)
  @{ Version=$version; Entries=$entries; Tasks=$taskBackups } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8
  try {
    StopHelper
    foreach ($entry in $entries) { $changed += $entry; CopyChecked $entry.Source $entry.Target }
    Apply-Tasks $taskEntries
    $health = StartHelper
    if ($health.version -ne $version) { throw 'Unexpected helper version after restart.' }
    $pageReady = $false
    for ($i=0; $i -lt 30; $i++) {
      try {
        $page = Invoke-WebRequest 'http://127.0.0.1:8787/' -UseBasicParsing -TimeoutSec 2
        if ($page.Content -match 'name="checkin-policy" content="daily-once-with-noon-compensation-2026-11-17.3"') { $pageReady=$true; break }
      } catch { }
      Start-Sleep -Milliseconds 500
    }
    if (-not $pageReady) { throw 'Wrangler did not reload the repaired dashboard.' }
  } catch {
    $failure = $_.Exception.Message
    try { StopHelper; Restore-Tasks $taskBackups; RestoreFiles $changed; $null=StartHelper }
    catch { SaveReport @{ Status='RollbackIncomplete'; Backup=$backup; Failure=$failure; RestoreFailure=$_.Exception.Message }; throw }
    SaveReport @{ Status='RolledBackAfterFailure'; Backup=$backup; Failure=$failure }
    throw ('Repair failed and files were restored: ' + $failure)
  }
  try {
    Update-Baseline (Join-Path $payload 'manifest.json') @{
      Worker = (NormalizedHash (Join-Path $WorkerRoot 'worker.js'))
      Helper = (NormalizedHash $helperPath)
      Run    = (NormalizedHash (Join-Path $AgentRoot 'run-checkin.cmd'))
    }
  } catch { Write-Warning ('Baseline update skipped: ' + $_.Exception.Message) }
  # Conservative acceptance: local history/cache only. Never call /refresh here.
  $reconciliation = @(& $python (Join-Path $AgentRoot 'login_checkin.py') --reconcile-local)
  $reconcileCode = $LASTEXITCODE
  $after = ReadBalance
  $verification = if ($reconcileCode -eq 0) { 'CacheOnlyPassed' } else { 'LocalReconciliationFailed' }
  $report = @{ Status='Applied'; Version=$version; Backup=$backup; At=(Get-Date).ToString('o'); Health=$health; Verification=$verification; Balance=$after; Reconciliation=$reconciliation; Tasks=@($taskEntries | ForEach-Object { $_.Name }); PlatformRequests=0; Policy='One workflow per account per Beijing day; at most one noon compensation for transient failures; no automatic retries; page reads cache only' }
  SaveReport $report
  Write-Host ('Repair applied. Verification: ' + $verification)
  Write-Host ('Platforms completed: ' + $after.Summary.completed + ' / ' + $after.Summary.total)
  Write-Host ('Backup: ' + $backup)
  Write-Host ('Report: ' + $reportPath)
  if ($VerifyRefresh) { Write-Host 'VerifyRefresh is disabled by conservative policy. No platform sign-in was triggered.' }
  if ($reconcileCode -ne 0) { Write-Warning 'Missing or failed historical confirmation stays unconfirmed; do not re-run sign-in for the counter.'; exit 2 }

} catch {
  if (-not $reportSaved) { SaveReport @{ Status=$(if ($Rollback) {'RollbackFailed'} else {'PreflightFailed'}); Error=$_.Exception.Message; At=(Get-Date).ToString('o') } }
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
} finally {
  if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
