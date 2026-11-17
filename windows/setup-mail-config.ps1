# One-time mail configuration. The SMTP authorization code is entered interactively
# and stored with Windows DPAPI (current user). No secret is passed on a command line.
$ErrorActionPreference = 'Stop'
$configPath = 'C:\workbuddy-trae-checkin\mail.config.json'
$logPath = 'C:\workbuddy-trae-checkin\mail-setup.log'
try { $Host.UI.RawUI.WindowTitle = 'Checkin Mail Setup - TYPE AUTHORIZATION CODE HERE' } catch { }

function Write-SetupLog([string]$text) {
  $line = '[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '] ' + $text + [Environment]::NewLine
  [IO.File]::AppendAllText($logPath, $line, (New-Object Text.UTF8Encoding($false)))
}

Write-Host ''
Write-Host '=============================================================='
Write-Host ' Daily check-in email setup (QQ Mail, smtp.qq.com:587 STARTTLS)'
Write-Host ' Enter the mailbox address once; it is used as sender and recipient.'
Write-Host ' Input of the authorization code is hidden.'
Write-Host '=============================================================='
Write-Host ''

$address = (Read-Host 'QQ mail address').Trim()
if ($address -notmatch '^[^@\s]+@[^@\s]+$') {
  Write-SetupLog 'not saved: invalid mail address'
  Write-Host 'Invalid address. Nothing was saved.' -ForegroundColor Red
  Start-Sleep -Seconds 5
  exit 1
}

$secure = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
  $secure = Read-Host -AsSecureString ("Authorization code, attempt " + $attempt + " of 3")
  if ($null -ne $secure -and $secure.Length -eq 16) { break }
  Write-Host ('  Length was ' + $(if ($null -eq $secure) { 0 } else { $secure.Length }) + '; expected 16.') -ForegroundColor Yellow
  $secure = $null
}

if ($null -eq $secure) {
  Write-SetupLog 'not saved: no valid 16-character input'
  Write-Host ''
  Write-Host 'Nothing was saved. Closing in 10 seconds.' -ForegroundColor Red
  Start-Sleep -Seconds 10
  exit 1
}

$encrypted = ConvertFrom-SecureString $secure
$config = [ordered]@{
  host     = 'smtp.qq.com'
  port     = 587
  ssl      = $true
  from     = $address
  user     = $address
  to       = $address
  password = $encrypted
}
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
Write-SetupLog 'saved encrypted config'
Write-Host ''
Write-Host ('Saved: ' + $configPath) -ForegroundColor Green
Write-Host 'Closing in 5 seconds.'
Start-Sleep -Seconds 5
