<#
.SYNOPSIS
    Automatizza il root del modem Technicolor DGA4130 (TIM Smart Modem Plus,
    e simili: DGA4132, TG789 ecc.) seguendo la procedura pubblicata su:
    https://forum.fibra.click/d/13118-root-dga-4130-e-simili

.DESCRIZIONE
    La guida originale richiede di usare AutoFlashGUI + WinSCP + PuTTY a mano.
    Questo script automatizza TUTTO ciò che è raggiungibile via SSH/SCP una
    volta che il modem espone root/root su 192.168.1.1:22 (i due passaggi
    davvero manuali - AutoFlashGUI e la pressione del tasto reset - restano
    tali perché AutoFlashGUI è un tool GUI di terze parti e il reset è
    fisico: non sono automatizzabili da qui).

    Usa il modulo PowerShell Posh-SSH (SSH/SCP puro, nessuna dipendenza da
    PuTTY/WinSCP) cosi' da poter accettare automaticamente la host key che
    cambia ad ogni riavvio/riflash, cosa che plink.exe in modalita' batch non
    permette di fare in modo pulito.

.PREREQUISITI (da fare TU, a mano, prima di lanciare lo script)
    1. Scaricare: AutoFlashGUI e il firmware "di tipo 2" corretto per il tuo
       modem (link nella guida: vedi README.md accanto a questo script).
    2. Scollegare il cavo VDSL (o accettare il rischio di profilo SNR).
    3. Tenere premuto il tasto reset posteriore per 8 secondi.
    4. Aprire AutoFlashGUI: host 192.168.1.1, user/pass admin/admin,
       protocollo "Advanced DDNS (Generic)", SENZA la spunta "flash
       firmware", e avviare. Aspettare che finisca.
    A questo punto il modem risponde su 192.168.1.1:22 con root/root: da qui
    in poi lo script fa tutto da solo.

.PARAMETER FirmwarePath
    Percorso locale del firmware "di tipo 2" da caricare sul modem.

.PARAMETER GuiTarPath
    Percorso locale del tar.bz2 della GUI Ansuel da installare a fine root.

.PARAMETER ModemIp
    IP del modem in modalita' di setup (default 192.168.1.1).

.PARAMETER DiagnoseOnly
    Non roota nulla: controlla solo se il modem e' raggiungibile (ping, porte
    22/80/443, TFTP 69/udp) e stampa un verdetto su cosa provare. Utile per
    capire in che stato e' il modem PRIMA di lanciare il resto - es. dopo un
    crash, se risponde solo al ping e nessuna porta e' aperta, AutoFlashGUI
    non funzionera' (si autentica sull'interfaccia web, serve la 80 su) e
    serve un intervento fisico (tasto reset) prima di tutto il resto. Non
    richiede FirmwarePath/GuiTarPath ne' Posh-SSH.

.EXAMPLE
    .\Root-DGA4130.ps1 -DiagnoseOnly

.EXAMPLE
    .\Root-DGA4130.ps1 -FirmwarePath C:\fw\dga4130_type2.bin -GuiTarPath C:\fw\GUI.tar.bz2

.NOTA LEGALE
    Esegui questo script SOLO su un modem di tua proprieta'. Modificare il
    firmware del CPE fornito dall'operatore puo' violare le condizioni
    contrattuali e invalidare la garanzia/assistenza; puo' inoltre bloccare
    (brick) il dispositivo se interrotto a meta'. Procedi consapevole del
    rischio.
#>

[CmdletBinding()]
param(
    [switch]$DiagnoseOnly,

    [string]$FirmwarePath,
    [string]$GuiTarPath,

    [string]$ModemIp = "192.168.1.1",
    [string]$Username = "root",
    [string]$Password = "root",

    [int]$RebootTimeoutSec = 300,
    [int]$PollIntervalSec = 5
)

$ErrorActionPreference = "Stop"

function Test-ModemReachability {
    param([string]$Target)

    Write-Host "=== Diagnostica raggiungibilita' $Target ===" -ForegroundColor Yellow

    $pingOk = Test-Connection -ComputerName $Target -Count 2 -Quiet -ErrorAction SilentlyContinue
    Write-Host ("Ping: {0}" -f $(if ($pingOk) { "OK" } else { "NESSUNA RISPOSTA" }))

    $tcpPorts = @{ 22 = "SSH (root gia' attivo / recovery via script)"; 80 = "Web admin (serve ad AutoFlashGUI)"; 443 = "Web admin HTTPS" }
    $openPorts = @()
    foreach ($p in $tcpPorts.Keys) {
        $t = Test-NetConnection -ComputerName $Target -Port $p -WarningAction SilentlyContinue
        $open = $t.TcpTestSucceeded
        Write-Host ("Porta {0} ({1}): {2}" -f $p, $tcpPorts[$p], $(if ($open) { "APERTA" } else { "chiusa" }))
        if ($open) { $openPorts += $p }
    }

    $tftpOk = $false
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 2000
        $probe = [byte[]](0,1) + [System.Text.Encoding]::ASCII.GetBytes("probe") + [byte[]](0) + [System.Text.Encoding]::ASCII.GetBytes("octet") + [byte[]](0)
        $udp.Connect($Target, 69)
        $udp.Send($probe, $probe.Length) | Out-Null
        $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $udp.Receive([ref]$remoteEP) | Out-Null
        $tftpOk = $true
    } catch { $tftpOk = $false } finally { if ($udp) { $udp.Close() } }
    Write-Host ("Porta 69/udp (TFTP, recovery bootloader CFE): {0}" -f $(if ($tftpOk) { "risponde" } else { "nessuna risposta" }))

    Write-Host ""
    if (22 -in $openPorts) {
        Write-Host "VERDETTO: root gia' attivo, si puo' lanciare lo script normale (senza -DiagnoseOnly)." -ForegroundColor Green
    } elseif (80 -in $openPorts -or 443 -in $openPorts) {
        Write-Host "VERDETTO: interfaccia web raggiungibile, non ancora rootato -> segui i prerequisiti manuali (reset 8s + AutoFlashGUI) poi rilancia lo script." -ForegroundColor Green
    } elseif ($tftpOk) {
        Write-Host "VERDETTO: solo TFTP risponde -> il modem e' nel bootloader CFE in attesa di un'immagine via TFTP, non con AutoFlashGUI." -ForegroundColor Yellow
    } elseif ($pingOk) {
        Write-Host "VERDETTO: solo ping risponde, nessun servizio (ne' web ne' TFTP) -> AutoFlashGUI NON funzionera' cosi' (si autentica sulla 80). Probabile crash/blocco sotto il livello dei servizi. Prova: tieni premuto il tasto reset posteriore per 8 secondi (rientra nella modalita' DDNS/bootp attesa da AutoFlashGUI); se dopo il reset ancora nulla, valuta piu' cicli di power-cycle per l'eventuale fallback automatico tra bank, o recovery seriale/UART." -ForegroundColor Red
    } else {
        Write-Host "VERDETTO: il modem non risponde nemmeno al ping. Controlla alimentazione/cablaggio LAN prima di tutto il resto." -ForegroundColor Red
    }
}

if ($DiagnoseOnly) {
    Test-ModemReachability -Target $ModemIp
    exit 0
}

if (-not $FirmwarePath -or -not (Test-Path $FirmwarePath -PathType Leaf)) {
    throw "FirmwarePath mancante o non trovato. Passa -FirmwarePath, oppure usa -DiagnoseOnly per solo controllare lo stato del modem."
}
if (-not $GuiTarPath -or -not (Test-Path $GuiTarPath -PathType Leaf)) {
    throw "GuiTarPath mancante o non trovato. Passa -GuiTarPath, oppure usa -DiagnoseOnly per solo controllare lo stato del modem."
}

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Ensure-PoshSSH {
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        Write-Step "Modulo Posh-SSH non trovato: lo installo (CurrentUser scope)"
        Install-Module -Name Posh-SSH -Scope CurrentUser -Force -Repository PSGallery
    }
    Import-Module Posh-SSH -ErrorAction Stop
}

function Wait-ForModemPort22 {
    param([int]$TimeoutSec, [int]$IntervalSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $test = Test-NetConnection -ComputerName $ModemIp -Port 22 -WarningAction SilentlyContinue
        if ($test.TcpTestSucceeded) { return $true }
        Start-Sleep -Seconds $IntervalSec
    }
    return $false
}

function New-ModemSession {
    # AcceptKey: la host key del dropbear del modem cambia ad ogni reflash/reboot,
    # va accettata automaticamente ogni volta, non fissata una volta sola.
    $securePw = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($Username, $securePw)
    return New-SSHSession -ComputerName $ModemIp -Credential $cred -AcceptKey -Force -ErrorAction Stop
}

function Invoke-ModemCommand {
    param($Session, [string]$Command)
    $result = Invoke-SSHCommand -SSHSession $Session -Command $Command -TimeOut 120
    if ($result.Output) { $result.Output | ForEach-Object { Write-Host "    $_" } }
    return $result
}

function Wait-ModemBackUp {
    param([string]$Label)
    Write-Step "Attendo che il modem torni raggiungibile ($Label, timeout ${RebootTimeoutSec}s)..."
    Start-Sleep -Seconds 10   # tempo minimo perché il modem spenga la porta prima del riavvio
    if (-not (Wait-ForModemPort22 -TimeoutSec $RebootTimeoutSec -IntervalSec $PollIntervalSec)) {
        throw "Il modem non e' tornato raggiungibile su $ModemIp:22 entro $RebootTimeoutSec secondi."
    }
    Start-Sleep -Seconds 5    # margine per dropbear che si alza poco dopo la porta TCP
    return New-ModemSession
}

# --- rc.local che verra' scritto sull'overlay del firmware appena flashato:
# imposta root:root, abilita dropbear persistente su LAN:22 con password auth,
# apre la regola firewall per la 22, poi si autoelimina (esegue una sola volta).
$rcLocalContent = @'
echo root:root | chpasswd
sed -i 's#/root:.*$#/root:/bin/ash#' /etc/passwd
sed -i -e 's/#//' -e 's#askconsole:.*$#askconsole:/bin/ash#' /etc/inittab
uci -q set $(uci show firewall | grep -m 1 $(fw3 -q print | egrep 'iptables -t filter -A zone_lan_input -p tcp -m tcp --dport 22 -m comment --comment "!fw3: .+" -j DROP' | sed -n -e 's/^iptables.\+fw3: \(.\+\)\".\+/\1/p') | sed -n -e "s/\(.\+\).name='.\+'$/\1/p").target='ACCEPT'
uci add dropbear dropbear
uci rename dropbear.@dropbear[-1]=afg
uci set dropbear.afg.enable='1'
uci set dropbear.afg.Interface='lan'
uci set dropbear.afg.Port='22'
uci set dropbear.afg.IdleTimeout='600'
uci set dropbear.afg.PasswordAuth='on'
uci set dropbear.afg.RootPasswordAuth='on'
uci set dropbear.afg.RootLogin='1'
uci commit dropbear
/etc/init.d/dropbear enable
/etc/init.d/dropbear restart
rm /overlay/$(cat /proc/banktable/booted)/etc/rc.local
'@ -replace "`r`n", "`n"

# ============================================================================
Write-Host "=== Root automatico DGA4130 (e simili) - da forum.fibra.click ===" -ForegroundColor Yellow
Write-Host "Dispositivo target: $ModemIp"
Write-Host ""
Write-Host "Prerequisiti da aver GIA' fatto a mano:" -ForegroundColor Yellow
Write-Host "  1. Cavo VDSL scollegato (o rischio accettato)"
Write-Host "  2. Reset posteriore tenuto premuto 8 secondi"
Write-Host "  3. AutoFlashGUI lanciato con successo (admin/admin, Advanced DDNS Generic, NO flash firmware)"
Write-Host ""
$confirm = Read-Host "Confermi di essere il proprietario del modem e di aver completato i punti sopra? [s/N]"
if ($confirm -notmatch '^[sSyY]') {
    Write-Host "Interrotto: completa i prerequisiti prima di rilanciare lo script." -ForegroundColor Red
    exit 1
}

Ensure-PoshSSH

try {
    Write-Step "Connessione SSH iniziale a $ModemIp (root/root)"
    $session = New-ModemSession

    Write-Step "Fase 1/5: swap bank e primo riavvio"
    $bankSwapCmd = @'
BANK=$(cat /proc/banktable/booted)
if [ "$BANK" = "bank_1" ]; then mtd write /dev/mtd3 bank_2; fi
cp -rf /overlay/$BANK /tmp/bank_overlay_backup
rm -rf /overlay/*
cp -rf /tmp/bank_overlay_backup /overlay/bank_2
echo bank_1 > /proc/banktable/active
mtd erase bank_1
reboot
'@ -replace "`r`n", "`n"
    Invoke-ModemCommand -Session $session -Command $bankSwapCmd | Out-Null
    Remove-SSHSession -SSHSession $session | Out-Null

    $session = Wait-ModemBackUp -Label "dopo swap bank"

    Write-Step "Fase 2/5: verifica bank attivo e upload firmware come /tmp/new.rbi"
    $bootedBank = (Invoke-ModemCommand -Session $session -Command 'cat /proc/banktable/booted').Output
    Write-Host "    Bank attivo ora: $bootedBank"

    $tmpFw = Join-Path $env:TEMP "new.rbi"
    Copy-Item -Path $FirmwarePath -Destination $tmpFw -Force
    $securePw = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($Username, $securePw)
    Set-SCPItem -ComputerName $ModemIp -Credential $cred -AcceptKey -Path $tmpFw -Destination "/tmp" -Force

    Write-Step "Fase 2/5: parsing/unseal firmware (bli_parser / bli_unseal)"
    $unsealCmd = 'cat "/tmp/new.rbi" | (bli_parser && echo "Please wait..." && (bli_unseal | dd bs=4 skip=1 seek=1 of="/tmp/new.bin"))'
    Invoke-ModemCommand -Session $session -Command $unsealCmd | Out-Null

    Write-Step "Fase 3/5: scrittura rc.local persistente (root ssh + firewall) sull'overlay"
    Invoke-ModemCommand -Session $session -Command "mkdir -p /overlay/$bootedBank/etc && chmod 755 /overlay/$bootedBank /overlay/$bootedBank/etc" | Out-Null

    $tmpRcLocal = Join-Path $env:TEMP "rc.local"
    [System.IO.File]::WriteAllText($tmpRcLocal, $rcLocalContent)
    Set-SCPItem -ComputerName $ModemIp -Credential $cred -AcceptKey -Path $tmpRcLocal -Destination "/overlay/$bootedBank/etc" -Force
    Invoke-ModemCommand -Session $session -Command "chmod +x /overlay/$bootedBank/etc/rc.local" | Out-Null

    Write-Step "Fase 4/5: flash firmware su bank $bootedBank e secondo riavvio"
    Invoke-ModemCommand -Session $session -Command "mtd write `"/tmp/new.bin`" $bootedBank" | Out-Null
    Invoke-ModemCommand -Session $session -Command "reboot" | Out-Null
    Remove-SSHSession -SSHSession $session | Out-Null

    $session = Wait-ModemBackUp -Label "dopo flash firmware"

    Write-Step "Fase 5/5: upload ed esecuzione GUI Ansuel"
    $tmpGui = Join-Path $env:TEMP "GUI.tar.bz2"
    Copy-Item -Path $GuiTarPath -Destination $tmpGui -Force
    Set-SCPItem -ComputerName $ModemIp -Credential $cred -AcceptKey -Path $tmpGui -Destination "/tmp" -Force
    Invoke-ModemCommand -Session $session -Command 'bzcat /tmp/GUI.tar.bz2 | tar -C / -xvf - && /etc/init.d/rootdevice force' | Out-Null

    Remove-SSHSession -SSHSession $session | Out-Null

    Write-Host ""
    Write-Host "=== FATTO ===" -ForegroundColor Green
    Write-Host "Il modem e' rootato con GUI Ansuel. SSH root/root resta attivo in permanenza"
    Write-Host "su LAN porta 22 (regola firewall aperta da rc.local)."
    Write-Host "Ricollega il cavo VDSL quando vuoi."
}
catch {
    Write-Host ""
    Write-Host "ERRORE: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Il modem e' rimasto in stato intermedio: NON scollegare l'alimentazione." -ForegroundColor Red
    Write-Host "Consulta il thread https://forum.fibra.click/d/13118-root-dga-4130-e-simili/9 per il recovery manuale da questo punto."
    exit 1
}
