<#
.SYNOPSIS
    Estrazione READ-ONLY di binari da /usr/bin sul modem DGA4130 via SSH
    (cat file | base64), stesso pattern di Dump-ModemMTD.ps1 / sessione
    2026-09-09 per /proc/rip/0108. Nessuna scrittura sul device.
#>

[CmdletBinding()]
param(
    [string]$ModemIp = "192.168.1.1",
    [string]$Username = "root",
    [string]$Password = "root",
    [string]$OutDir = $PSScriptRoot,
    [string[]]$RemoteFiles = @(
        "/usr/bin/signature_checker",
        "/usr/bin/bli_unseal_rsa_helper",
        "/usr/bin/bli_parser",
        "/usr/bin/bli_unseal",
        "/usr/bin/bli_unseal_rsa"
    )
)

$ErrorActionPreference = "Stop"
Import-Module Posh-SSH -ErrorAction Stop

$securePw = ConvertTo-SecureString $Password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($Username, $securePw)
$session = New-SSHSession -ComputerName $ModemIp -Credential $cred -AcceptKey -Force -ErrorAction Stop

try {
    foreach ($remote in $RemoteFiles) {
        $localName = Split-Path $remote -Leaf
        $localPath = Join-Path $OutDir $localName
        Write-Host "==> Estrazione $remote -> $localPath" -ForegroundColor Cyan

        $cmd = "cat $remote 2>/dev/null | base64; echo EXITCODE:`$?"
        $result = Invoke-SSHCommand -SSHSession $session -Command $cmd -TimeOut 60

        $outLines = $result.Output
        $lastLine = $outLines[-1]
        if ($lastLine -notmatch '^EXITCODE:0$') {
            Write-Warning "  Comando remoto non ha riportato EXITCODE:0 per $remote (ultima riga: '$lastLine') - controllare manualmente."
        }
        $b64Lines = $outLines[0..($outLines.Count - 2)]
        $b64 = ($b64Lines -join "")
        if ([string]::IsNullOrWhiteSpace($b64)) {
            Write-Warning "  Nessun contenuto base64 ricevuto per $remote - file assente o non leggibile? Skip."
            continue
        }
        $bytes = [Convert]::FromBase64String($b64)
        [System.IO.File]::WriteAllBytes($localPath, $bytes)

        $md5 = (Get-FileHash -Path $localPath -Algorithm MD5).Hash
        Write-Host ("  OK: {0} bytes, MD5={1}" -f $bytes.Length, $md5) -ForegroundColor Green
    }
} finally {
    Remove-SSHSession -SSHSession $session | Out-Null
}

Write-Host ""
Write-Host "Confronto MD5 remoto (via md5sum sul device) per verifica integrita':" -ForegroundColor Cyan
$session2 = New-SSHSession -ComputerName $ModemIp -Credential $cred -AcceptKey -Force -ErrorAction Stop
try {
    foreach ($remote in $RemoteFiles) {
        $r = Invoke-SSHCommand -SSHSession $session2 -Command "md5sum $remote 2>/dev/null" -TimeOut 30
        Write-Host "  remote: $($r.Output -join ' ')"
    }
} finally {
    Remove-SSHSession -SSHSession $session2 | Out-Null
}
