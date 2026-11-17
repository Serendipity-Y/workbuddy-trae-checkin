# Daily check-in summary email (HTML card). Local cache only; no platform requests.
$ErrorActionPreference = 'Stop'
$root = 'C:\workbuddy-trae-checkin'
$logPath = Join-Path $root 'notify.log'
$configPath = Join-Path $root 'mail.config.json'

function Write-Log([string]$text) {
  $line = '[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '] ' + $text + [Environment]::NewLine
  # Add-Content crashes the PowerShell host in this environment; append through .NET instead.
  [IO.File]::AppendAllText($logPath, $line, (New-Object Text.UTF8Encoding($false)))
}

function Read-AdminToken {
  $vars = [IO.File]::ReadAllText((Join-Path $root '.dev.vars'))
  $match = [regex]::Match($vars, '(?m)^\s*ADMIN_TOKEN\s*=\s*([^\r\n]+)')
  if (-not $match.Success) { throw 'ADMIN_TOKEN missing in .dev.vars' }
  return $match.Groups[1].Value.Trim().Trim([char[]]'"''')
}

$template = @'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f3f4f6;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px 12px;">
<tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'PingFang SC','Microsoft YaHei',Arial,sans-serif;">
<tr><td style="padding:26px 28px;background:#0f172a;">
<div style="font-size:12px;letter-spacing:2px;color:#94a3b8;font-weight:600;">DAILY CHECK-IN</div>
<div style="margin-top:8px;font-size:22px;font-weight:600;color:#ffffff;">{{TITLE}}</div>
<div style="margin-top:8px;font-size:13px;color:#cbd5e1;">{{DATE}} · 12:30 汇总</div>
</td></tr>
<tr><td style="padding:22px 28px 4px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
<td width="50%" style="padding-right:8px;">
<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:12px;padding:16px;">
<div style="font-size:12px;color:#64748b;">平台完成</div>
<div style="margin-top:6px;font-size:26px;font-weight:700;color:#0f172a;">{{COMPLETED}}<span style="font-size:14px;color:#94a3b8;font-weight:500;"> / {{TOTAL}}</span></div>
</div>
</td>
<td width="50%" style="padding-left:8px;">
<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:12px;padding:16px;">
<div style="font-size:12px;color:#64748b;">账户完成</div>
<div style="margin-top:6px;font-size:26px;font-weight:700;color:#0f172a;">{{ACOMP}}<span style="font-size:14px;color:#94a3b8;font-weight:500;"> / {{ATOTAL}}</span></div>
</div>
</td>
</tr></table>
</td></tr>
{{BANNER}}
<tr><td style="padding:2px 28px 20px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0">{{ROWS}}</table>
</td></tr>
<tr><td style="padding:16px 28px;background:#f8fafc;border-top:1px solid #e5e7eb;">
<div style="font-size:12px;line-height:1.7;color:#94a3b8;">本邮件由本地策略脚本生成，只读取本机缓存，未触发任何平台请求。<br>生成时间：{{TIME}}</div>
</td></tr>
</table>
<div style="margin-top:14px;font-size:12px;color:#9ca3af;">WorkBuddy Check-in · 保守模式</div>
</td></tr>
</table>
</body></html>
'@

try {
  $token = Read-AdminToken
  $summary = $null
  $apiError = ''
  try {
    $summary = Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/summary' -Headers @{ 'X-Admin-Token' = $token } -TimeoutSec 15
  } catch {
    $apiError = $_.Exception.Message
  }

  $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $secure = ConvertTo-SecureString $config.password
  $today = if ($summary) { [string]$summary.today } else { (Get-Date).ToString('yyyy-MM-dd') }
  $rows = New-Object System.Collections.Generic.List[string]
  $textLines = New-Object System.Collections.Generic.List[string]

  if ($summary) {
    $completed = [int]$summary.completed
    $total = [int]$summary.total
    $accountCompleted = [int]$summary.accountCompleted
    $accountTotal = [int]$summary.accountTotal
    $allDone = ($completed -eq $total) -and ($accountCompleted -eq $accountTotal)
    $title = if ($allDone) { '今日签到已完成' } else { '今日签到未完成' }
    $subject = if ($allDone) {
      '[签到完成] ' + $today + ' ' + $completed + '/' + $total
    } else {
      '[签到异常] ' + $today + ' ' + $completed + '/' + $total
    }

    foreach ($platform in @($summary.platforms)) {
      $name = [System.Net.WebUtility]::HtmlEncode([string]$platform.name)
      if ($platform.completed) {
        $state = '完成'; $pillBg = '#dcfce7'; $pillFg = '#166534'
      } else {
        $state = '未完成'; $pillBg = '#fee2e2'; $pillFg = '#991b1b'
      }
      $rows.Add('<tr><td style="padding:12px 0;border-bottom:1px solid #f3f4f6;font-size:14px;color:#111827;">' + $name + '<div style="font-size:12px;color:#6b7280;margin-top:4px;">账户 ' + $platform.accounts + ' · 已确认 ' + $platform.confirmedAccounts + '</div></td><td align="right" style="padding:12px 0;border-bottom:1px solid #f3f4f6;"><span style="display:inline-block;padding:4px 10px;border-radius:999px;font-size:12px;font-weight:600;background:' + $pillBg + ';color:' + $pillFg + ';">' + $state + '</span></td></tr>')
      $textLines.Add('  ' + $platform.name + '：' + $state + '（账户 ' + $platform.accounts + '，已确认 ' + $platform.confirmedAccounts + '）')
    }

    $missing = @($summary.platforms | Where-Object { -not $_.completed } | ForEach-Object { $_.name })
    if ($missing.Count) {
      $banner = '<tr><td style="padding:16px 28px 0;"><div style="background:#fef2f2;border:1px solid #fecaca;border-radius:10px;padding:12px 14px;font-size:13px;color:#991b1b;">未完成平台：' + [System.Net.WebUtility]::HtmlEncode(($missing -join '、')) + '</div></td></tr>'
    } else {
      $banner = ''
    }
    $textLines.Insert(0, '日期：' + $today)
    $textLines.Insert(1, '平台完成：' + $completed + ' / ' + $total)
    $textLines.Insert(2, '账户完成：' + $accountCompleted + ' / ' + $accountTotal)
    $textLines.Insert(3, '')
    $textLines.Add('')
    $textLines.Add('未完成平台：' + $(if ($missing.Count) { $missing -join '、' } else { '无' }))
  } else {
    $completed = '—'; $total = '—'; $accountCompleted = '—'; $accountTotal = '—'
    $title = '无法读取本地签到状态'
    $subject = '[签到异常] ' + $today + ' 本地服务不可达'
    $banner = '<tr><td style="padding:16px 28px 0;"><div style="background:#fef2f2;border:1px solid #fecaca;border-radius:10px;padding:12px 14px;font-size:13px;color:#991b1b;">本地服务 8787 不可达：' + [System.Net.WebUtility]::HtmlEncode($apiError) + '</div></td></tr>'
    $textLines.Add('日期：' + $today)
    $textLines.Add('无法读取本机 /api/summary')
    $textLines.Add('错误：' + $apiError)
  }

  $textLines.Add('')
  $textLines.Add('说明：本邮件由本地策略脚本生成，只读取本机缓存，未触发任何平台请求。')
  $textLines.Add('时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
  $text = $textLines -join "`r`n"

  $html = $template.Replace('{{TITLE}}', $title)
  $html = $html.Replace('{{DATE}}', $today)
  $html = $html.Replace('{{COMPLETED}}', [string]$completed)
  $html = $html.Replace('{{TOTAL}}', [string]$total)
  $html = $html.Replace('{{ACOMP}}', [string]$accountCompleted)
  $html = $html.Replace('{{ATOTAL}}', [string]$accountTotal)
  $html = $html.Replace('{{BANNER}}', $banner)
  $html = $html.Replace('{{ROWS}}', ($rows -join ''))
  $html = $html.Replace('{{TIME}}', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

  $mail = New-Object System.Net.Mail.MailMessage
  $mail.From = New-Object System.Net.Mail.MailAddress([string]$config.from)
  foreach ($to in ([string]$config.to -split ',')) {
    if ($to.Trim()) { $mail.To.Add($to.Trim()) }
  }
  $mail.Subject = $subject
  $mail.SubjectEncoding = [Text.Encoding]::UTF8
  $mail.Body = $text
  $mail.BodyEncoding = [Text.Encoding]::UTF8
  $mail.IsBodyHtml = $false
  $htmlView = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString($html, [Text.Encoding]::UTF8, 'text/html')
  $mail.AlternateViews.Add($htmlView)

  $smtp = New-Object System.Net.Mail.SmtpClient([string]$config.host, [int]$config.port)
  $smtp.EnableSsl = [bool]$config.ssl
  $smtp.Credentials = New-Object System.Net.NetworkCredential([string]$config.user, $secure)
  $smtp.Timeout = 30000
  $smtp.Send($mail)
  $smtp.Dispose()
  $mail.Dispose()

  Write-Log ('sent html | subject=' + $subject + ' | platforms=' + $completed + '/' + $total + ' | accounts=' + $accountCompleted + '/' + $accountTotal)
  exit 0
} catch {
  try { Write-Log ('failed | ' + $_.Exception.Message) } catch { }
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
