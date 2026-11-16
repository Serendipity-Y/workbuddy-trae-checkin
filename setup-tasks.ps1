# Register Windows scheduled tasks: start the service at logon + daily check-in runs.
# Re-runnable (-Force overwrites existing tasks). Windows only.
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$user = $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

# 1) Start the hidden service at logon.
$svcAction = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $dir + '\start-hidden.vbs"') -WorkingDirectory $dir
$svcTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$svcSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'WorkBuddyCheckin-Service' -Action $svcAction -Trigger $svcTrigger -Settings $svcSettings -Principal $principal -Force | Out-Null
Write-Host 'registered: WorkBuddyCheckin-Service (at logon)'

# 2) Daily check-in at 10:00 (Qoder claim window opens ~10:00) + 11:00 backup.
$cronAction = New-ScheduledTaskAction -Execute ($dir + '\run-cron.cmd') -WorkingDirectory $dir
$cronTrigger = @(
  (New-ScheduledTaskTrigger -Daily -At '10:00'),
  (New-ScheduledTaskTrigger -Daily -At '11:00')
)
$cronSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'WorkBuddyCheckin-Daily' -Action $cronAction -Trigger $cronTrigger -Settings $cronSettings -Principal $principal -Force | Out-Null
Write-Host 'registered: WorkBuddyCheckin-Daily (daily 10:00 + 11:00 backup)'

Get-ScheduledTask -TaskName 'WorkBuddyCheckin-*' | Select-Object TaskName, State | Format-Table