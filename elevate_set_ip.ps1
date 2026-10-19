Start-Transcript -Path "$env:USERPROFILE\claude\dga4130-root\elevate_log16.txt" -Force | Out-Null
try {
    New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 10.0.0.99 -PrefixLength 24 -ErrorAction Stop | Out-Null
    Write-Output "IP: OK -> aggiunto 10.0.0.99/24"
} catch {
    Write-Output ("IP ERROR: " + $_.Exception.Message)
}
Stop-Transcript | Out-Null
