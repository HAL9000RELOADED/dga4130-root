# Root automatico DGA4130 (e simili)

Automazione della guida pubblicata su fibra.click:
https://forum.fibra.click/d/13118-root-dga-4130-e-simili/9

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

## Al termine

- SSH `root`/`root` resta permanentemente attivo su LAN porta 22 (regola
  firewall aperta da `rc.local` durante il primo boot del firmware nuovo).
- GUI Ansuel installata e attiva (`/etc/init.d/rootdevice force`).
- Ricollega il cavo VDSL quando vuoi.

## Riferimenti (dalla guida originale)

- https://forum.fibra.click/d/13118-root-dga-4130-e-simili/9 (guida sorgente)
- https://www.ilpuntotecnico.com/forum/index.php/topic,78162.0.html
- https://www.ilpuntotecnico.com/forum/index.php/topic,81461.0.html
- https://hack-technicolor.readthedocs.io/en/stable/ (progetto Ansuel:
  firmware repository, GUI, documentazione generale sui Technicolor gateway)
