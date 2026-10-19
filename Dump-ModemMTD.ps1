<#
.SYNOPSIS
    Dump di TUTTE le partizioni flash MTD del modem Technicolor DGA4130 (=VBNT-K)
    via SSH, una volta che il modem espone root/root su 192.168.1.1:22 (vedi
    Root-DGA4130.ps1 per come arrivarci).

.DESCRIZIONE
    Legge /proc/mtd sul modem per enumerare le partizioni presenti (bank_1,
    bank_2, rootfs_data, cferom, eripv2, rawstorage, ecc. - i nomi esatti
    dipendono dal device reale, non sono hardcoded), poi per ciascuna esegue
    "dd if=/dev/mtdXro | base64" via canale SSH exec e decodifica il risultato
    localmente. Non usa scp per il trasferimento: gli scp "classici" si basano
    sulla dimensione riportata da stat(), che sui char device /dev/mtdX è
    spesso 0, quindi scp fallisce o tronca - lo stesso motivo per cui la
    sessione del 2026-09-09 ha estratto /proc/rip/0108 con "cat | base64"
    invece che con Set-SCPItem/Get-SCPItem.

    Usa il modulo Posh-SSH, stesso pattern di Root-DGA4130.ps1 (New-SSHSession
    con -AcceptKey -Force, perché la host key del dropbear cambia ad ogni
    riflash/reboot).

    Progresso: due barre Write-Progress annidate - una per "partizione N di
    totale" e una per il singolo dump in corso (spinner + secondi trascorsi +
    % stimata sul timeout previsto, dato che dd|base64 su SSH exec non
    riporta byte trasferiti in tempo reale). Se un dump supera il tempo
    stimato viene stampato un avviso; se il comando fallisce o va in timeout
    SSH, l'errore/exit-code viene stampato subito (niente output "silenzioso"
    in caso di problemi).

.PARAMETER ModemIp
    IP/hostname del modem (default 192.168.1.1).

.PARAMETER SshPort
    Porta SSH (default 22 - alcuni device espongono dropbear su una porta
    WAN non standard, es. per un accesso da remoto via DDNS).

.PARAMETER Username
.PARAMETER Password
    Credenziali SSH (default root/root).

.PARAMETER OutDir
    Cartella locale di destinazione (default Desktop\Modem\mtd-dump-<timestamp>).
    Deliberatamente FUORI da questo repo git: il dump può contenere segreti
    reali (chiavi crypto in eripv2, credenziali in rootfs_data/overlay) e non
    va mai committato/pushato.

.PARAMETER Partitions
    Filtro opzionale per nome o numero mtd (es. "mtd0","bank_1"). Se omesso,
    dump di TUTTE le partizioni elencate in /proc/mtd, inclusa eripv2/
    rawstorage (su richiesta esplicita dell'utente, nonostante l'annotazione
    "DO NOT TOUCH" in memoria di progetto - qui è comunque solo LETTURA da
    /dev/mtdXro, nessuna scrittura sul dispositivo).

.PARAMETER BlockSize
    bs= passato a dd sul modem (default 65536).

.PARAMETER NoPostProcessing
    Se presente, salta il passaggio di post-processing (vedi sotto) e lascia
    solo i .bin grezzi.

.PARAMETER IncludeRawMaster
    Nel dump completo (senza -Partitions), include anche il/i device MTD
    "master" (l'intero chip NAND/NOR fisico, nome tipo "brcmnand.0" - pattern
    "driver.N", non una sotto-partizione con nome descrittivo) - escluso di
    default perche' ridondante rispetto alle sotto-partizioni vere. Se incluso
    (o selezionato esplicitamente via -Partitions insieme ad altro), viene
    comunque messo in coda: un suo eventuale fallimento arriva per ultimo,
    dopo che le partizioni vere sono gia' salve.

    Per il device master lo script rileva a runtime se sul modem e' presente
    "nanddump" (mtd-utils) e lo usa al posto di "dd": un dd semplice su NAND
    grezza si ferma con I/O error sui bad block di fabbrica (ogni chip ne ha),
    mentre nanddump e' pensato apposta per saltarli/paddarli. Se nanddump non
    c'e', fallback a "dd ... conv=noerror,sync" (best-effort, non garantito
    equivalente).

.DESCRIZIONE (post-processing)
    Dopo ogni dump, il file locale viene ispezionato SOLO tramite i magic
    byte noti (nessuna euristica inventata, nessun tentativo di decrittare
    materiale crypto senza chiave/algoritmo documentato per questo progetto):
    - SquashFS (magic "hsqs"/"sqsh", anche embedded più avanti nel file, es.
      immagini combinate kernel+rootfs): se e' installato "unsquashfs" in WSL
      (richiesto - su Windows l'estrazione e' nota per essere incompleta,
      vedi memoria di progetto "sempre ri-estrarre in WSL"), lo estrae
      automaticamente in "<file>.extracted\"; altrimenti segnala solo
      formato+offset trovato, nessuna azione.
    - gzip: decompresso automaticamente in "<file>.decompressed" (nessuna
      dipendenza esterna, usa System.IO.Compression).
    - JFFS2 (nodo 0x1985 trovato), UBI ("UBI#"), ELF, U-Boot uImage: solo
      identificazione/offset nel manifest, nessuna estrazione automatica
      (nessun tool del genere presente in questo repo).
    - eripv2/rawstorage e qualunque partizione senza magic riconosciuto:
      nessun decoder noto per questo progetto (diverso dal formato THENC dei
      config.bin, che usa thenc_tool.py) - restano solo .bin grezzi.

.EXAMPLE
    .\Dump-ModemMTD.ps1
    Dump di tutte le partizioni in Desktop\Modem\mtd-dump-<data-ora>\, con
    identificazione formato ed estrazione best-effort di squashfs/gzip.

.EXAMPLE
    .\Dump-ModemMTD.ps1 -Partitions bank_1,bank_2 -OutDir C:\tmp\dump

.NOTA LEGALE
    Esegui questo script SOLO su un modem di tua proprietà.
#>

[CmdletBinding()]
param(
    [string]$ModemIp = "192.168.1.1",
    [int]$SshPort = 22,
    [string]$Username = "root",
    [string]$Password = "root",

    [string]$OutDir = (Join-Path $env:USERPROFILE "Desktop\Modem\mtd-dump-$(Get-Date -Format 'yyyyMMdd-HHmmss')"),

    [string[]]$Partitions = @(),

    [int]$BlockSize = 65536,

    [switch]$NoPostProcessing,

    [switch]$IncludeRawMaster
)

$ErrorActionPreference = "Stop"

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

function New-ModemSession {
    # AcceptKey: la host key del dropbear del modem cambia ad ogni reflash/reboot,
    # va accettata automaticamente ogni volta, non fissata una volta sola.
    $securePw = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($Username, $securePw)
    return New-SSHSession -ComputerName $ModemIp -Port $SshPort -Credential $cred -AcceptKey -Force -ErrorAction Stop
}

function Invoke-ModemCommand {
    param($Session, [string]$Command, [int]$TimeoutSec = 120)
    $result = Invoke-SSHCommand -SSHSession $Session -Command $Command -TimeOut $TimeoutSec
    return $result
}

function Get-ModemMtdList {
    param($Session)
    # formato /proc/mtd:
    # dev:    size   erasesize  name
    # mtd0: 00040000 00020000 "cferom"
    $result = Invoke-ModemCommand -Session $Session -Command "cat /proc/mtd" -TimeoutSec 30
    if ($result.ExitStatus -ne 0) {
        throw "cat /proc/mtd fallito (exit $($result.ExitStatus)): $($result.Error -join "`n")"
    }

    $partitions = @()
    foreach ($line in $result.Output) {
        if ($line -match '^(mtd\d+):\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+"(.+)"\s*$') {
            $devName = $Matches[1]
            $sizeBytes = [Convert]::ToInt64($Matches[2], 16)
            $eraseSize = [Convert]::ToInt64($Matches[3], 16)
            $name = $Matches[4]
            $index = [int]($devName -replace 'mtd', '')
            $partitions += [PSCustomObject]@{
                Index     = $index
                DevName   = $devName
                SizeBytes = $sizeBytes
                EraseSize = $eraseSize
                Name      = $name
            }
        }
    }
    if ($partitions.Count -eq 0) {
        throw "Nessuna partizione MTD trovata - output inatteso di /proc/mtd:`n$($result.Output -join "`n")"
    }
    return $partitions
}

function Test-IsRawMasterPartition {
    # Le partizioni "vere" hanno nomi descrittivi assegnati dal bootloader/
    # dts (rootfs, rootfs_data, bank_1, eripv2, ...). Il device MTD "master"
    # (l'intero chip NAND/NOR fisico) viene invece registrato da Linux con il
    # nome del driver+istanza, pattern "driver.N" (es. "brcmnand.0",
    # "gpmi-nand.0", "spi0.0") - euristica generica sul pattern del nome, non
    # hardcoded su "brcmnand.0" (che e' specifico di QUESTO modem/sessione).
    param($Partition)
    return $Partition.Name -match '^[a-z][a-z0-9_-]*\.\d+$'
}

function Test-ModemHasNanddump {
    # dd su un device MTD "master" (NAND grezza) fallisce/si ferma sui bad
    # block di fabbrica (ogni chip NAND ne ha) - EIO su dd, che aborta la
    # lettura li'. nanddump (da mtd-utils, di solito presente sulle build
    # OpenWrt-derivate come questa) e' lo strumento pensato apposta: salta/
    # pada i bad block invece di fermarsi. Va rilevato a runtime, non
    # assunto presente.
    param($Session)
    $result = Invoke-ModemCommand -Session $Session -Command "command -v nanddump" -TimeoutSec 15
    return ($result.ExitStatus -eq 0 -and $result.Output)
}

function Get-PartitionDumpCommand {
    param($Session, $Partition, [int]$BlockSize)
    if (Test-IsRawMasterPartition $Partition) {
        if (Test-ModemHasNanddump -Session $Session) {
            Write-Host "    [dump] device master: uso nanddump (gestisce i bad block della NAND grezza)" -ForegroundColor DarkCyan
            return "nanddump -f - /dev/$($Partition.DevName)ro 2>/dev/null | base64"
        }
        Write-Host "    [dump] device master: nanddump non trovato sul modem - fallback a dd con conv=noerror,sync (le regioni con errori di lettura verranno azzerate/paddate invece di far abortire il comando, ma NON e' garantito equivalente a un vero dump NAND-aware)" -ForegroundColor DarkYellow
        return "dd if=/dev/$($Partition.DevName)ro bs=$BlockSize conv=noerror,sync 2>/dev/null | base64"
    }
    return "dd if=/dev/$($Partition.DevName)ro bs=$BlockSize 2>/dev/null | base64"
}

function Get-PartitionTimeoutSec {
    param([long]$SizeBytes)
    $sizeMB = [math]::Ceiling($SizeBytes / 1MB)
    # base64-over-SSH e' piu' lento di uno scp binario diretto: margine largo.
    return [math]::Max(120, $sizeMB * 3)
}

function Invoke-ModemCommandAsync {
    # Esegue Invoke-SSHCommand su un runspace separato (stesso processo, non un job)
    # cosi' il thread principale resta libero di aggiornare una barra di progresso
    # mentre il comando remoto (dd|base64, potenzialmente minuti su partizioni grandi)
    # e' ancora in corso.
    param($Session, [string]$Command, [int]$TimeoutSec)

    $ps = [PowerShell]::Create()
    $ps.AddScript({
        param($Session, $Command, $TimeoutSec)
        Import-Module Posh-SSH -ErrorAction Stop
        Invoke-SSHCommand -SSHSession $Session -Command $Command -TimeOut $TimeoutSec
    }).AddArgument($Session).AddArgument($Command).AddArgument($TimeoutSec) | Out-Null

    return [PSCustomObject]@{
        PowerShell = $ps
        Async      = $ps.BeginInvoke()
    }
}

function Wait-ModemCommandWithProgress {
    # Mostra spinner + secondi trascorsi + % stimata (elapsed/timeout) mentre
    # Invoke-ModemCommandAsync gira in background - unico modo per sapere che
    # il dump sta ancora procedendo e non si e' bloccato, dato che Invoke-SSHCommand
    # non riporta progresso reale byte-per-byte.
    param($Handle, [string]$Activity, [int]$TimeoutSec, [int]$ProgressId, [int]$ProgressParentId)

    $spinner = @('|', '/', '-', '\')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $i = 0
    $warnedOverTime = $false
    while (-not $Handle.Async.IsCompleted) {
        $elapsed = [int]$sw.Elapsed.TotalSeconds
        $pct = [math]::Min(97, [int](($elapsed / [double]$TimeoutSec) * 100))
        Write-Progress -Id $ProgressId -ParentId $ProgressParentId -Activity $Activity `
            -Status "$($spinner[$i % 4])  ${elapsed}s trascorsi / ~${TimeoutSec}s stimati" `
            -PercentComplete $pct
        if (-not $warnedOverTime -and $elapsed -gt $TimeoutSec) {
            Write-Host "    ATTENZIONE: superato il tempo stimato (${TimeoutSec}s) - il comando e' ancora in corso, attendo lo scadere del timeout SSH ($TimeoutSec s) prima di segnalare un errore." -ForegroundColor Yellow
            $warnedOverTime = $true
        }
        $i++
        Start-Sleep -Milliseconds 500
    }
    Write-Progress -Id $ProgressId -ParentId $ProgressParentId -Activity $Activity -Completed

    # IMPORTANTE: leggere/materializzare Streams.Error (in stringhe semplici,
    # non solo il riferimento alla collezione) PRIMA di Dispose() - Dispose()
    # sulla PowerShell instance ripulisce anche i suoi stream, quindi leggere
    # $errRecords dopo produceva un messaggio vuoto (bug osservato in pratica:
    # "Comando remoto fallito nel runspace async:" senza alcun dettaglio).
    $endInvokeError = $null
    $result = $null
    try {
        $result = $Handle.PowerShell.EndInvoke($Handle.Async)
    } catch {
        $endInvokeError = $_
    }
    $hadErrors = $Handle.PowerShell.HadErrors
    $errMessages = @($Handle.PowerShell.Streams.Error | ForEach-Object { $_.Exception.Message })
    $Handle.PowerShell.Dispose()

    if ($endInvokeError) {
        $inner = $endInvokeError.Exception.InnerException
        $detail = if ($inner) { "$($endInvokeError.Exception.Message) [inner: $($inner.Message)]" } else { $endInvokeError.Exception.Message }
        throw "Comando remoto fallito (EndInvoke): $detail"
    }
    if ($hadErrors -and $errMessages.Count -gt 0) {
        throw "Comando remoto fallito nel runspace async: $($errMessages -join '; ')"
    }
    if (-not $result -or $result.Count -eq 0) {
        throw "Comando remoto non ha restituito alcun risultato (nessun errore esplicito - possibile timeout SSH silenzioso)."
    }
    return $result[0]
}

function Find-BytePattern {
    # Cerca una sequenza di byte (pattern, tutti valori ASCII-safe come i
    # magic qui sotto) dentro un array di byte grande usando una ricerca su
    # stringa Latin1 (mappatura 1:1 byte<->char, IndexOf ottimizzato) invece
    # di un loop manuale byte-per-byte - molto piu' veloce su file da decine
    # di MB.
    param([byte[]]$Bytes, [byte[]]$Pattern)
    if ($Bytes.Length -eq 0) { return $null }
    $enc = [System.Text.Encoding]::GetEncoding(28591)  # Latin1 / ISO-8859-1
    $text = $enc.GetString($Bytes)
    $patternStr = $enc.GetString($Pattern)
    $idx = $text.IndexOf($patternStr, [StringComparison]::Ordinal)
    if ($idx -ge 0) { return $idx }
    return $null
}

function Get-PartitionFormatInfo {
    # Identificazione SOLO via magic byte noti e pubblicamente documentati -
    # nessuna euristica inventata, nessun tentativo di decrittare eripv2/
    # rawstorage (nessun algoritmo/chiave nota per quel contenuto in questo
    # progetto, e' un formato diverso dal THENC dei config.bin).
    param([byte[]]$Bytes)

    $info = [PSCustomObject]@{ Format = "sconosciuto"; Offset = 0 }
    if ($Bytes.Length -lt 4) { return $info }

    $b0, $b1, $b2, $b3 = $Bytes[0], $Bytes[1], $Bytes[2], $Bytes[3]
    if ($b0 -eq 0x68 -and $b1 -eq 0x73 -and $b2 -eq 0x71 -and $b3 -eq 0x73) {
        $info.Format = "SquashFS (little-endian)"; return $info
    }
    if ($b0 -eq 0x73 -and $b1 -eq 0x71 -and $b2 -eq 0x73 -and $b3 -eq 0x68) {
        $info.Format = "SquashFS (big-endian)"; return $info
    }
    if ($b0 -eq 0x55 -and $b1 -eq 0x42 -and $b2 -eq 0x49 -and $b3 -eq 0x23) {
        $info.Format = "UBI"; return $info
    }
    if ($b0 -eq 0x7f -and $b1 -eq 0x45 -and $b2 -eq 0x4c -and $b3 -eq 0x46) {
        $info.Format = "ELF"; return $info
    }
    if ($b0 -eq 0x27 -and $b1 -eq 0x05 -and $b2 -eq 0x19 -and $b3 -eq 0x56) {
        $info.Format = "U-Boot uImage"; return $info
    }
    if ($b0 -eq 0x1f -and $b1 -eq 0x8b) {
        $info.Format = "gzip"; return $info
    }

    # JFFS2: nodo con magic 0x1985 (byte 0x19 0x85), spesso subito all'inizio
    # su una partizione overlay, cercato solo nei primi 64KB per evitare
    # falsi positivi lontani nel file.
    $head = if ($Bytes.Length -gt 65536) { $Bytes[0..65535] } else { $Bytes }
    $offset = Find-BytePattern -Bytes $head -Pattern @(0x19, 0x85)
    if ($null -ne $offset) {
        $info.Format = "JFFS2 (nodo trovato)"; $info.Offset = $offset; return $info
    }

    # SquashFS non all'inizio del file (es. immagine combinata kernel+rootfs):
    # cerca il magic "hsqs" in tutto il dump.
    $offset = Find-BytePattern -Bytes $Bytes -Pattern @(0x68, 0x73, 0x71, 0x73)
    if ($null -ne $offset) {
        $info.Format = "SquashFS embedded"; $info.Offset = $offset; return $info
    }

    return $info
}

function Test-WslUnsquashfs {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    try {
        & wsl.exe -e which unsquashfs *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Convert-ToWslPath {
    # Causa reale verificata (2026-09-09): passando un path Windows con
    # backslash come argomento a wsl.exe da PowerShell, i backslash spariscono
    # per strada (es. "C:\Users\x" diventa "C:Usersx"), quindi wslpath fallisce
    # (exit 1). Fix: sostituire \ con / prima di invocarlo - Windows accetta
    # entrambi, e wslpath -a li gestisce correttamente. Prima di questo fix la
    # chiamata falliva silenziosamente e ".Trim()" su un risultato vuoto
    # mandava in crash l'intera partizione (bug osservato su mtd1/mtd4: il
    # .bin era gia' scritto correttamente, ma l'eccezione nel post-processing
    # veniva letta come fallimento dell'intera partizione).
    param([string]$WindowsPath)
    $safePath = $WindowsPath.Replace('\', '/')
    $out = & wsl.exe wslpath -a "$safePath" 2>$null
    if (-not $out) { return $null }
    $joined = ($out -join "").Trim()
    if ([string]::IsNullOrWhiteSpace($joined) -or $joined[0] -ne '/') { return $null }
    return $joined
}

function Invoke-SquashfsExtractWsl {
    param([string]$LocalBinPath, [int]$Offset, [string]$DestDir)
    $srcWsl = Convert-ToWslPath -WindowsPath $LocalBinPath
    $destWsl = Convert-ToWslPath -WindowsPath $DestDir
    if (-not $srcWsl -or -not $destWsl) { return $false }
    & wsl.exe unsquashfs -f -o $Offset -d $destWsl $srcWsl *> $null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-PartitionPostProcessing {
    param([string]$LocalBinPath, [byte[]]$Bytes)

    $formatInfo = Get-PartitionFormatInfo -Bytes $Bytes
    $action = "nessuna (nessun decoder noto per questo formato/partizione)"

    switch -Wildcard ($formatInfo.Format) {
        "gzip" {
            $decPath = "$LocalBinPath.decompressed"
            try {
                $inStream = [System.IO.File]::OpenRead($LocalBinPath)
                $gz = New-Object System.IO.Compression.GZipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
                $outStream = [System.IO.File]::Create($decPath)
                $gz.CopyTo($outStream)
                $outStream.Close(); $gz.Close(); $inStream.Close()
                $action = "decompresso -> $decPath"
                Write-Host "    [post] gzip decompresso: $decPath" -ForegroundColor DarkCyan
            } catch {
                $action = "decompressione gzip fallita: $($_.Exception.Message)"
                Write-Host "    [post] ATTENZIONE: decompressione gzip fallita: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        "SquashFS*" {
            $destDir = "$LocalBinPath.extracted"
            try {
                if (Test-WslUnsquashfs) {
                    if (Invoke-SquashfsExtractWsl -LocalBinPath $LocalBinPath -Offset $formatInfo.Offset -DestDir $destDir) {
                        $action = "estratto (WSL unsquashfs, offset $($formatInfo.Offset)) -> $destDir"
                        Write-Host "    [post] SquashFS estratto: $destDir" -ForegroundColor DarkCyan
                    } else {
                        $action = "estrazione unsquashfs fallita/non disponibile (offset $($formatInfo.Offset))"
                        Write-Host "    [post] ATTENZIONE: unsquashfs non ha prodotto un'estrazione valida, vedi il file .bin per estrazione manuale" -ForegroundColor Yellow
                    }
                } else {
                    $action = "unsquashfs non disponibile in WSL - estrazione saltata (offset noto: $($formatInfo.Offset))"
                    Write-Host "    [post] SquashFS rilevato (offset $($formatInfo.Offset)) ma unsquashfs non trovato in WSL - estrazione manuale necessaria" -ForegroundColor DarkYellow
                }
            } catch {
                # Il dump grezzo (.bin) e' GIA' salvo a questo punto - un
                # errore qui deve solo annotare il fallimento dell'estrazione,
                # mai propagare e far perdere il risultato del dump.
                $action = "estrazione squashfs fallita: $($_.Exception.Message)"
                Write-Host "    [post] ATTENZIONE: estrazione squashfs fallita: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        default {
            Write-Host "    [post] formato: $($formatInfo.Format)$(if ($formatInfo.Offset -gt 0) { " (offset $($formatInfo.Offset))" })" -ForegroundColor DarkGray
        }
    }

    return [PSCustomObject]@{
        Format = $formatInfo.Format
        Offset = $formatInfo.Offset
        Action = $action
    }
}

function Dump-ModemPartition {
    param($Session, $Partition, [string]$OutDir, [int]$BlockSize, [int]$Index, [int]$Total, [switch]$NoPostProcessing)

    $timeoutSec = Get-PartitionTimeoutSec -SizeBytes $Partition.SizeBytes
    $sizeMB = [math]::Round($Partition.SizeBytes / 1MB, 2)
    $label = "[$Index/$Total] $($Partition.DevName) `"$($Partition.Name)`""
    Write-Step "Dump $label ($sizeMB MB, timeout stimato ${timeoutSec}s)"

    try {
        $cmd = Get-PartitionDumpCommand -Session $Session -Partition $Partition -BlockSize $BlockSize
        $handle = Invoke-ModemCommandAsync -Session $Session -Command $cmd -TimeoutSec $timeoutSec
        $result = Wait-ModemCommandWithProgress -Handle $handle -Activity "Dump $label" -TimeoutSec $timeoutSec -ProgressId 2 -ProgressParentId 1
    } catch {
        # Un errore su QUESTA partizione non deve abortire l'intero dump delle
        # altre 6 - viene loggato e si passa alla successiva (bug osservato in
        # pratica: mtd0 falliva ed uccideva l'intero script al partizione 1/7).
        Write-Host "    ERRORE: dump fallito: $($_.Exception.Message)" -ForegroundColor Red
        return [PSCustomObject]@{
            DevName = $Partition.DevName; Name = $Partition.Name
            DeclaredBytes = $Partition.SizeBytes; WrittenBytes = 0; Sha256 = ""
            LocalPath = ""; Format = ""; PostAction = "FALLITO: $($_.Exception.Message)"
        }
    }
    if ($result.ExitStatus -ne 0 -or -not $result.Output) {
        $errDetail = if ($result.Error) { $result.Error -join ' ' } else { "(nessun dettaglio - dd/base64 non ha restituito output)" }
        Write-Host "    ERRORE: dump fallito (exit $($result.ExitStatus)): $errDetail" -ForegroundColor Red
        return [PSCustomObject]@{
            DevName = $Partition.DevName; Name = $Partition.Name
            DeclaredBytes = $Partition.SizeBytes; WrittenBytes = 0; Sha256 = ""
            LocalPath = ""; Format = ""; PostAction = "FALLITO: exit $($result.ExitStatus) - $errDetail"
        }
    }

    $b64 = ($result.Output -join "")
    $bytes = [Convert]::FromBase64String($b64)

    $safeName = ($Partition.Name -replace '[\\/:*?"<>|]', '_')
    $outFile = Join-Path $OutDir ("{0}_{1}.bin" -f $Partition.DevName, $safeName)
    [System.IO.File]::WriteAllBytes($outFile, $bytes)

    $hash = (Get-FileHash -Path $outFile -Algorithm SHA256).Hash
    $writtenBytes = $bytes.Length

    if ($writtenBytes -ne $Partition.SizeBytes) {
        Write-Host "    ATTENZIONE: size scritta ($writtenBytes) diversa da /proc/mtd ($($Partition.SizeBytes))" -ForegroundColor Yellow
    }
    Write-Host "    OK: $outFile ($writtenBytes byte, sha256 $hash)" -ForegroundColor Green

    $post = [PSCustomObject]@{ Format = "(post-processing saltato)"; Offset = 0; Action = "-NoPostProcessing" }
    if (-not $NoPostProcessing) {
        try {
            $post = Invoke-PartitionPostProcessing -LocalBinPath $outFile -Bytes $bytes
        } catch {
            # Rete di sicurezza finale: il .bin e' GIA' scritto su disco con
            # hash calcolato a questo punto - qualunque bug nel post-processing
            # (anche uno non ancora previsto) deve solo essere annotato, MAI
            # far sparire il risultato del dump gia' riuscito dal manifest.
            $post = [PSCustomObject]@{ Format = "sconosciuto"; Offset = 0; Action = "post-processing fallito (dump raw comunque salvo): $($_.Exception.Message)" }
            Write-Host "    [post] ATTENZIONE: post-processing fallito, ma il .bin e' gia' salvo: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    return [PSCustomObject]@{
        DevName        = $Partition.DevName
        Name           = $Partition.Name
        DeclaredBytes  = $Partition.SizeBytes
        WrittenBytes   = $writtenBytes
        Sha256         = $hash
        LocalPath      = $outFile
        Format         = $post.Format
        PostAction     = $post.Action
    }
}

try {
    Write-Step "Dump memoria flash (MTD) - modem ${ModemIp}:${SshPort}"
    Ensure-PoshSSH

    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    Write-Host "Output: $OutDir"
    Write-Host "NOTA: puo' contenere segreti reali (chiavi crypto, credenziali) - non committare/pushare questa cartella." -ForegroundColor Yellow

    $session = New-ModemSession
    Write-Step "Enumerazione partizioni (/proc/mtd)"
    $allPartitions = Get-ModemMtdList -Session $session
    $allPartitions | ForEach-Object {
        Write-Host ("    {0,-8} {1,10:N0} byte  {2}" -f $_.DevName, $_.SizeBytes, $_.Name)
    }

    if ($Partitions.Count -gt 0) {
        # Selezione esplicita dell'utente: rispettata sempre, anche se include
        # un device master (mtd0/brcmnand.0 ecc.).
        $targets = $allPartitions | Where-Object {
            $Partitions -contains $_.DevName -or $Partitions -contains $_.Name -or $Partitions -contains "mtd$($_.Index)"
        }
        if ($targets.Count -eq 0) {
            throw "Nessuna partizione corrisponde al filtro -Partitions: $($Partitions -join ', ')"
        }
    } else {
        # Dump completo: il/i device master (chip NAND/NOR intero, ridondante
        # rispetto alle sotto-partizioni ed e' quello con piu' probabilita' di
        # fallire con dd) e' escluso di default - usa -IncludeRawMaster per
        # includerlo comunque, oppure -Partitions per selezionarlo da solo.
        $targets = $allPartitions
        $rawMaster = @($targets | Where-Object { Test-IsRawMasterPartition $_ })
        if ($rawMaster.Count -gt 0 -and -not $IncludeRawMaster) {
            Write-Host "NOTA: escluso automaticamente il device MTD master (ridondante/a rischio): $($rawMaster.Name -join ', ') - usa -IncludeRawMaster per includerlo, oppure -Partitions per selezionarlo esplicitamente." -ForegroundColor DarkYellow
            $targets = @($targets | Where-Object { -not (Test-IsRawMasterPartition $_) })
        }
    }

    # Qualunque device master rimasto nei target (via -IncludeRawMaster o
    # selezione esplicita insieme ad altre partizioni) va messo in coda: se
    # fallisce, le partizioni "vere" sono gia' state salvate prima.
    $targets = @($targets | Where-Object { -not (Test-IsRawMasterPartition $_) }) + @($targets | Where-Object { Test-IsRawMasterPartition $_ })

    $manifest = @()
    $total = $targets.Count
    $n = 0
    foreach ($p in $targets) {
        $n++
        Write-Progress -Id 1 -Activity "Dump MTD $ModemIp" -Status "Partizione $n di $total ($($p.Name))" -PercentComplete ([int]((($n - 1) / $total) * 100))
        try {
            $manifest += Dump-ModemPartition -Session $session -Partition $p -OutDir $OutDir -BlockSize $BlockSize -Index $n -Total $total -NoPostProcessing:$NoPostProcessing
        } catch {
            # Rete di sicurezza aggiuntiva: qualunque errore imprevisto qui
            # (non solo quelli gia' gestiti dentro Dump-ModemPartition) non
            # deve fermare le partizioni restanti.
            Write-Host "    ERRORE IMPREVISTO su $($p.DevName): $($_.Exception.Message)" -ForegroundColor Red
            $manifest += [PSCustomObject]@{
                DevName = $p.DevName; Name = $p.Name; DeclaredBytes = $p.SizeBytes
                WrittenBytes = 0; Sha256 = ""; LocalPath = ""; Format = ""
                PostAction = "FALLITO (imprevisto): $($_.Exception.Message)"
            }
        }
    }
    Write-Progress -Id 1 -Activity "Dump MTD $ModemIp" -Completed

    Remove-SSHSession -SSHSession $session | Out-Null

    $manifestPath = Join-Path $OutDir "manifest.txt"
    $lines = @()
    $lines += "Dump MTD $ModemIp - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ""
    foreach ($m in ($manifest | Where-Object { $_ -ne $null })) {
        $lines += "$($m.DevName)`t$($m.Name)`tdichiarati=$($m.DeclaredBytes)`tscritti=$($m.WrittenBytes)`tsha256=$($m.Sha256)`tformato=$($m.Format)`tpost=$($m.PostAction)`t$($m.LocalPath)"
    }
    $lines | Set-Content -Path $manifestPath -Encoding UTF8

    $ok = @($manifest | Where-Object { $_.WrittenBytes -gt 0 })
    $failed = @($manifest | Where-Object { $_.WrittenBytes -eq 0 })

    Write-Host ""
    Write-Host "=== FATTO ===" -ForegroundColor Green
    Write-Host "Partizioni riuscite: $($ok.Count) / $($targets.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { "Green" } else { "Yellow" })
    if ($failed.Count -gt 0) {
        Write-Host "Partizioni FALLITE: $($failed.Count) -> $($failed.Name -join ', ')" -ForegroundColor Red
        Write-Host "(dettagli nel manifest, colonna 'post')" -ForegroundColor Red
    }
    Write-Host "Manifest: $manifestPath"
}
catch {
    Write-Host ""
    Write-Host "ERRORE: $($_.Exception.Message)" -ForegroundColor Red
    if ($session) { Remove-SSHSession -SSHSession $session -ErrorAction SilentlyContinue | Out-Null }
    exit 1
}
