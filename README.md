# Root automatico DGA4130 (e simili)

Automazione della guida pubblicata su fibra.click:
https://forum.fibra.click/d/13118-root-dga-4130-e-simili

Vale per Technicolor DGA4130 ("TIM Smart Modem Plus"), e con gli stessi
accorgimenti della guida originale anche per DGA4132 e Fastgate (il Fastgate
richiede in più il TCH exploit iniziale, non incluso qui).

**Usa solo su un modem di tua proprietà.** Modificare il firmware del CPE
fornito dall'operatore può violare le condizioni contrattuali e c'è rischio
concreto di brick se il processo viene interrotto a metà (es. per un blackout
durante il passaggio `mtd write`).

## Cosa fa lo script e cosa NON fa

La guida originale prevede 4 passaggi manuali (scaricare i tool, scollegare
il VDSL, tenere premuto reset 8s, lanciare AutoFlashGUI) seguiti da una lunga
sequenza di comandi da digitare a mano via WinSCP + PuTTY.

`Root-DGA4130.ps1` **automatizza tutta la sequenza SSH/SCP** (swap bank,
upload firmware, parsing bli_parser/bli_unseal, scrittura rc.local
persistente, flash, riavvio, upload ed esecuzione della GUI Ansuel),
usando il modulo PowerShell `Posh-SSH` invece di WinSCP/PuTTY manuali.

**Non automatizza** (perché non è tecnicamente possibile da qui):
- lo scollegamento fisico del cavo VDSL;
- la pressione del tasto reset per 8 secondi;
- il lancio di AutoFlashGUI (tool GUI di terze parti con protocollo proprio
  non documentato pubblicamente — va lanciato a mano una volta, poi lo
  script prende il controllo appena il modem risponde su root/root).

## Bank planning: quando saltare lo swap-then-erase (variante più sicura)

La **Fase 1** dello script (swap-then-erase) parte dal presupposto peggiore:
non sai in che stato sono i due bank, quindi sposti l'overlay del bank
attivo su `bank_2`, attivi `bank_1` e **cancelli** il contenuto precedente
di `bank_1` prima ancora di scrivere il nuovo firmware. È la scelta giusta
quando non hai modo di verificare lo stato reale dei bank in anticipo.

**Verificato in una sessione reale (2026-09-09)**: se il bank *non* attivo
è già completamente vuoto (cancellato, tutti byte `0xFF`), lo swap-then-erase
è superfluo e più rischioso del necessario — per una finestra di tempo hai
comunque un solo bank scrivibile/utilizzabile. La variante più sicura in
questo caso specifico:

1. Verifica lo stato reale **prima** di toccare qualunque cosa:
   ```sh
   cat /proc/banktable/booted /proc/banktable/active /proc/banktable/inactive
   # il bank booted è quello che stai attualmente usando via SSH — non toccarlo
   dd if=/dev/mtd<N-del-bank-inactive> bs=1 count=64 2>/dev/null | hexdump -C
   # se sono tutti "ff", il bank è vuoto: sicuro da scrivere direttamente
   ```
2. Se il bank inattivo è vuoto: **non** fare lo swap-then-erase. Carica e
   sigilla il firmware come al solito (`bli_parser`/`bli_unseal` — vedi Fase
   2 dello script), poi scrivi il risultato **direttamente** nel bank vuoto
   e imposta quello come attivo:
   ```sh
   mtd write "/tmp/new.bin" bank_1   # o bank_2, quello risultato vuoto
   echo bank_1 > /proc/banktable/active
   ```
3. Il bank attualmente booted (con la sua root già ottenuta) resta
   **intatto e intoccato** per tutta la procedura — è un fallback
   automatico se il nuovo bank non si avvia, invece di passare per una
   finestra in cui nessun bank è garantito funzionante.
4. Prima del reboot, replica lo stesso `rc.local` di persistenza root
   (vedi `$rcLocalContent` nello script) dentro
   `/overlay/<bank-appena-scritto>/etc/rc.local` — si autoelimina al primo
   boot, esattamente come nella Fase 3 originale.

**Quando NON usare questa variante**: se non sei sicuro che il bank
"inattivo" sia davvero vuoto (es. contiene un firmware precedente valido
che vuoi comunque sostituire), torna alla Fase 1 standard dello script —
scrivere direttamente sopra un bank non vuoto senza lo swap dell'overlay
lascia un overlay orfano/incoerente.

## Prerequisiti

1. **Firmware "di tipo 2"** corretto per il tuo modem — link nella guida
   originale (vedi Riferimenti sotto), sezione firmware repository di
   hack-technicolor.
2. **GUI Ansuel** (`GUI.tar.bz2`) — stesso riferimento.
3. **AutoFlashGUI** — tool per il trigger iniziale via DDNS generic.
4. PowerShell 5.1+ su Windows con accesso a Internet la prima volta (per
   installare `Posh-SSH` da PSGallery se non già presente).

## Uso

```powershell
# 0) Non sai in che stato è il modem? Controllalo prima (non tocca nulla):
.\Root-DGA4130.ps1 -DiagnoseOnly

# 1) Segui a mano i prerequisiti manuali (vedi sopra e commento in testa allo script)
# 2) Lancia lo script passando i due file scaricati:
.\Root-DGA4130.ps1 -FirmwarePath "C:\percorso\firmware_tipo2.bin" -GuiTarPath "C:\percorso\GUI.tar.bz2"
```

Parametri opzionali: `-ModemIp` (default `192.168.1.1`), `-RebootTimeoutSec`
(default 300), `-PollIntervalSec` (default 5).

Lo script chiede conferma esplicita di proprietà/prerequisiti prima di
procedere, poi esegue in sequenza le 5 fasi mostrando l'output di ogni
comando remoto. Se qualcosa fallisce a metà, **non staccare l'alimentazione
del modem**: lo script stampa dove si è fermato e rimanda al thread
originale per il recovery manuale.

## Troubleshooting: il modem non risponde dopo un crash

Se il modem era già rootato (root/root attivo su :22) e ha smesso di
rispondere in seguito a un crash (es. durante l'installazione di un modulo
kernel), `-DiagnoseOnly` controlla ping + porte 22/80/443 + TFTP 69/udp e dà
un verdetto. In particolare:

- **Solo ping risponde, nessuna porta aperta** (nemmeno TFTP): il modem è
  bloccato sotto il livello dei servizi (probabile crash del kernel/flow
  accelerator hardware BCM63xx, o boot bloccato prima che parta lo
  userspace). **AutoFlashGUI non funzionerà in questo stato** — si
  autentica sull'interfaccia web (porta 80), che qui non è su. Serve un
  intervento fisico: tieni premuto il tasto reset posteriore per 8 secondi
  (come nel prerequisito manuale) per forzare la modalità DDNS/bootp che
  AutoFlashGUI si aspetta. Un LED "i"/power arancione **lampeggiante** che
  resta così per più di qualche minuto conferma che il modem è fermo in
  attesa e non si riprenderà da solo.
- **Solo TFTP risponde**: il modem è nel bootloader CFE in attesa di
  un'immagine via TFTP — percorso di recovery diverso da AutoFlashGUI, non
  coperto da questo script.
- **Porta 22 aperta**: root è già attivo, si può operare da SSH normalmente
  (anche con lo script stesso, se serve rifare lo swap bank).

## Al termine

- SSH `root`/`root` resta permanentemente attivo su LAN porta 22 (regola
  firewall aperta da `rc.local` durante il primo boot del firmware nuovo).
- GUI Ansuel installata e attiva (`/etc/init.d/rootdevice force`).
- Ricollega il cavo VDSL quando vuoi.

## Analisi tecnica del firmware stock

[`FIRMWARE-ANALYSIS.md`](FIRMWARE-ANALYSIS.md) spiega, con i file di
configurazione reali estratti da un `.rbi` ufficiale decifrato (dropbear,
inittab, nginx, firewall), *perché* ogni passaggio dello script serve
davvero — inclusa la console seriale/UART (`askconsole` in `/etc/inittab`),
che questo README non documentava esplicitamente pur essendo già abilitata
dallo script: utile da sapere per un eventuale recovery via USB-TTL quando
sia SSH che la GUI web non rispondono.

## Riferimenti (dalla guida originale)

- https://forum.fibra.click/d/13118-root-dga-4130-e-simili (guida sorgente)
- https://www.ilpuntotecnico.com/forum/index.php/topic,78162.0.html
- https://www.ilpuntotecnico.com/forum/index.php/topic,81461.0.html
- https://hack-technicolor.readthedocs.io/en/stable/ (progetto Ansuel:
  firmware repository, GUI, documentazione generale sui Technicolor gateway)
