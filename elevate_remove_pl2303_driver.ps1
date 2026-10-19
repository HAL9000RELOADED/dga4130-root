Start-Transcript -Path "$env:USERPROFILE\claude\dga4130-root\elevate_pl2303_log.txt" -Force | Out-Null
try {
    pnputil /delete-driver oem306.inf /uninstall /force
    Write-Output "Rimozione oem306.inf (ser2pl.inf, driver anti-clone): OK"
} catch {
    Write-Output ("ERRORE: " + $_.Exception.Message)
}
Stop-Transcript | Out-Null
