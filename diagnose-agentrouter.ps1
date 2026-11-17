# Read-only Windows diagnostics. Does not sign in, trigger refresh, or change tasks.
$ErrorActionPreference = 'Continue'

function Get-ScriptPaths([string]$CommandLine) {
  $pattern = '"([^"\r\n]+\.(?:py|js|mjs|ps1|cmd|bat))"|([A-Za-z]:\\[^\s"\r\n]+\.(?:py|js|mjs|ps1|cmd|bat))'
  foreach ($match in [regex]::Matches($CommandLine, $pattern, 'IgnoreCase')) {
    if ($match.Groups[1].Success) { $match.Groups[1].Value }
    else { $match.Groups[2].Value }
  }
}

$listeners = foreach ($port in @(8787, 8788)) {
  foreach ($connection in @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
    $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $connection.OwningProcess)
    [pscustomobject]@{
      Port = $port
      Address = $connection.LocalAddress
      ProcessId = $connection.OwningProcess
      Executable = $process.ExecutablePath
      Scripts = @(Get-ScriptPaths $process.CommandLine)
    }
  }
}

$tasks = foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like '*AgentRouter*' })) {
  $info = $task | Get-ScheduledTaskInfo
  [pscustomobject]@{
    Name = $task.TaskName
    State = [string]$task.State
    LastRun = [string]$info.LastRunTime
    LastResult = $info.LastTaskResult
    NextRun = [string]$info.NextRunTime
    Actions = @(foreach ($action in $task.Actions) {
      [pscustomobject]@{
        Executable = $action.Execute
        WorkingDirectory = $action.WorkingDirectory
        Scripts = @(Get-ScriptPaths $action.Arguments)
      }
    })
  }
}

function Protect-DiagnosticLine([string]$Line) {
  if ($Line -match '(?i)password|passwd|cookie|authorization|bearer|token|secret|credential|session|api.?key|user.?name|login.?name|email') {
    return '[credential-related line omitted]'
  }
  return [regex]::Replace($Line, '[A-Za-z0-9_+/=-]{32,}', '[long value omitted]')
}

$root = 'C:\agentrouter-checkin'
$files = @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)
$sources = foreach ($file in $files) {
  if ($file.Extension -notin @('.mjs', '.js', '.py', '.cmd', '.bat', '.ps1', '.vbs')) { continue }
  if ($file.Name -match '(?i)config|secret|credential' -or $file.Length -gt 1048576) { continue }
  $lineNumber = 0
  [pscustomobject]@{
    File = $file.FullName
    Lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 | ForEach-Object {
      $lineNumber++
      ('{0}: {1}' -f $lineNumber, (Protect-DiagnosticLine $_))
    })
  }
}
$logFiles = @($files | Where-Object { $_.Extension -eq '.log' })
$logFiles += @(Get-ChildItem -LiteralPath (Join-Path $root 'logs') -Filter '*.log' -File -ErrorAction SilentlyContinue)
$logs = foreach ($file in @($logFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 6)) {
  [pscustomobject]@{
    File = $file.FullName
    LastWrite = $file.LastWriteTime.ToString('o')
    Tail = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Tail 100 | ForEach-Object { Protect-DiagnosticLine $_ })
  }
}

$report = [pscustomobject]@{
  At = (Get-Date).ToString('o')
  Listeners = @($listeners)
  Tasks = @($tasks)
  Files = @($files | Select-Object Name, Length, LastWriteTime)
  Sources = @($sources)
  Logs = @($logs)
}
$output = $report | ConvertTo-Json -Depth 6
$reportPath = Join-Path $PSScriptRoot 'agentrouter-diagnostics.log'
$output | Set-Content -Path $reportPath -Encoding UTF8
Write-Host ('Collected {0} source files and {1} log tails.' -f @($sources).Count, @($logs).Count)
Write-Host ('Report saved: ' + $reportPath)
