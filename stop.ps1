# Stop only this project's node / workerd processes (matched by project path).
$root = $PSScriptRoot
Get-CimInstance Win32_Process |
  Where-Object { ($_.Name -eq 'node.exe' -or $_.Name -eq 'workerd.exe') -and $_.CommandLine -and $_.CommandLine.Contains($root) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host 'check-in service stopped.'