# Analisi del firmware stock: da dove vengono i passaggi di root

Questo documento spiega, con riferimenti diretti al firmware, *perché* i
passaggi in `Root-DGA4130.ps1` / nella guida originale servono davvero — non
solo *cosa* fanno. L'analisi è stata fatta decifrando ed estraendo un
firmware ufficiale Technicolor "di tipo 2" (`AGTEF_1.0.3_CLOSED.rbi`,
board `VBNT-K` / `DGA0130TCH`, quindi lo stesso hardware del DGA4130) e
ispezionando i file di configurazione stock al suo interno.

## Come si decifra un `.rbi` fuori dal device

Il device stesso sa farlo con un tool di bordo (usato anche dallo script,
vedi `bli_parser`/`bli_unseal` sotto). Per farlo *offline*, su PC, il
formato è documentato (in modo indipendente) dal progetto
[`Ansuel/Decrypt_RBI_Firmware_Utility`](https://github.com/Ansuel/Decrypt_RBI_Firmware_Utility):
gli `.rbi` Technicolor sono un contenitore con una catena di payload,
ciascuno introdotto da un byte "magic":

| Magic  | Significato                        | Header da saltare (dopo il magic byte) |
|--------|-------------------------------------|------------------------------------------|
| `0xB7` | Payload cifrato AES-256-CBC         | 5 + 4 (size) + 16 (IV1) + 48 (chiave cifrata) + 16 (IV2), poi cifrato con chiave/IV di secondo livello |
| `0xB8` | Firma (verifica opzionale, saltabile)| 4+1+4+32                                  |
| `0xB4` | Payload compresso zlib              | 4+1+4, poi `zlib inflate`                 |
| `0xB0` | Payload finale in chiaro            | 4+1, il resto è il dato vero              |

La chiave AES-256 di primo livello ("OSCK") è specifica per board ed è
elencata in chiaro nel sorgente del tool linkato sopra
(`src/main/board.java`, board `VBNT-K` = DGA4130). Decifrando con quella
chiave si ottiene un'immagine flash da 80 MiB in chiaro, dentro la quale
`binwalk` trova un kernel LZMA e un filesystem **SquashFS v4.0 xz**
(estraibile con `unsquashfs`) — è lì dentro che stanno tutti i file
analizzati sotto.

Sul device stesso, la via più semplice resta quella già usata dalla guida:
```sh
cat "/tmp/new.rbi" | (bli_parser && bli_unseal | dd bs=4 skip=1 seek=1 of="/tmp/new.bin")
```
`bli_parser`/`bli_unseal` sono i tool ufficiali Technicolor già presenti sul
device: fanno la stessa decifratura, ma con la chiave già nota al firmware
stesso — non serve conoscerla dall'esterno per questo passaggio.

## Header esterno del contenitore `.rbi` (wrapper `BLI2`) e tre bug `data_size`-simili

La tabella sopra descrive la catena di payload *interna* (magic `0xB7`/`0xB8`/
`0xB4`/`0xB0`). C'è però anche un header *esterno* del contenitore, separato
dalla cifratura/firma del payload interno: è quello che il bootloader CFE
legge per sapere quanti byte aspettarsi durante un caricamento via TFTP
(recovery BOOTP+TFTP, procedura descritta nel repo
[`technicolor-vbntk-recovery`](https://github.com/HAL9000RELOADED/technicolor-vbntk-recovery)).

Layout (byte offset dall'inizio del file; ricostruito da
`rbi-decrypt/header_parser.java` e verificato leggendo header reali — non
dalla doc Ansuel citata sopra, che copre solo il payload interno):

| Offset | Dimensione | Campo | Note |
|--------|-----------|-------|------|
| `0x00` | 4 | magic | ASCII `BLI2` |
| `0x04` | 2 | fim | osservato costante |
| `0x06` | 2 | fia | osservato costante |
| `0x08` | 12 | prodid | product id, stringa |
| `0x14` | 12 | varid | variant id, stringa |
| `0x20` | 4 | version | osservato `0x00000000` sui file analizzati |
| `0x24` | 4 | (sconosciuto) | osservato `0x00000000` |
| `0x28` | 4 | data_offset | big-endian; inizio payload (osservato `369`/`0x171` costante) |
| `0x2C` | 4 | data_size | big-endian; lunghezza dichiarata del payload che segue |

### Bug 1: `data_size` errato in un'immagine patchata (2026-08-23)

Durante un tentativo di recovery via netboot BOOTP+TFTP (stessa procedura del
repo di recovery, ma con un'immagine `AGTEF_2.4.5` modificata/"patchata"
invece dell'originale `CLOSED`), il CFE rifiutava il trasferimento subito
dopo l'avvio del TFTP:

```
TFTP started
Loading failed.: CFE error -21
Resetting the gateway
```

Confronto diretto degli header — `AGTEF_2.4.5_CLOSED.rbi` (noto funzionante,
già flashato con successo il 2026-08-01, vedi repo di recovery) contro
`AGTEF_2.4.5_PATCHED.rbi` (il file modificato):

| File | data_offset (`0x28`) | data_size (`0x2C`) dichiarato | payload reale (filesize − data_offset) | scarto |
|------|----------------------|--------------------------------|-------------------------------------------|--------|
| CLOSED | 369 | 32.875.754 | 32.875.754 | 0 |
| PATCHED (originale) | 369 | 33.043.994 | 33.044.074 | **-80 byte** |

Il processo che ha prodotto la variante "patchata" (~168 KB più grande della
CLOSED) ha modificato il payload senza ricalcolare `data_size`: il campo
dichiarava 80 byte in meno del payload realmente presente nel file. Il CFE
usa questo campo per sapere quanti byte aspettarsi/validare durante il
caricamento via TFTP e rigetta l'immagine quando non torna — da cui l'errore
-21 (il nome esatto della costante `CFE_ERR_*` per -21 non è stato
identificato in fonti pubbliche, ma il comportamento osservato — rigetto
immediato subito dopo l'avvio TFTP, poi reset pulito del gateway, non un
crash — è coerente con un controllo di validazione lunghezza/checksum lato
CFE, non un errore di trasporto di rete).

Fix: ricalcolare e riscrivere `data_size` a offset `0x2C` (big-endian, 4
byte) = `filesize - data_offset`, lasciando invariato il resto dell'header:

```python
import struct
with open(path, "r+b") as f:
    f.seek(0x28); data_offset = struct.unpack(">I", f.read(4))[0]
    f.seek(0, 2); filesize = f.tell()
    f.seek(0x2C); f.write(struct.pack(">I", filesize - data_offset))
```

### Bug 2 e 3: altri due campi di lunghezza con lo stesso identico difetto

Dopo aver corretto `data_size`, un nuovo tentativo di flash falliva ancora
con lo stesso rigetto CFE. Analizzando la catena *interna* (payload dopo
`data_offset`, magic `0xB7` → `0xB8` → `0xB4` → `0xB0`, vedi tabella dei
magic byte più sopra) sono emersi altri due campi con lo stesso identico
bug — il tool di patching che ha prodotto `PATCHED` ricalcola le dimensioni
esterne ma non quelle annidate più in profondità:

1. **`payload_size` del blocco `0xB7`** (offset assoluto `data_offset + 6`,
   4 byte big-endian, subito dopo magic+5 byte sconosciuti): deve valere
   esattamente `filesize - (data_offset + 6 + 4)` — cioè tutti i byte
   rimanenti da subito dopo questo campo fino a fine file (include
   IV1+chiave cifrata AES-256+IV2+ciphertext). Verificato a scarto zero su
   due firmware ufficiali diversi (`AGTEF_2.4.1_CLOSED`, `AGTEF_2.4.5_CLOSED`).
   Nell'immagine patchata era **80 byte in meno** del corretto — stessa
   entità del bug 1, quasi certamente stesso tool/stesso calcolo errato
   applicato due volte.

2. **`lenfield` del blocco `0xB8`** (firma/hash — dentro il payload già
   decifrato con la chiave AES-256 derivata dal blocco `0xB7`, subito dopo
   magic+4 byte sconosciuti+1 byte, prima dell'hash SHA-256 di 32 byte che
   segue): deve valere esattamente `32 + (byte del blocco 0xB4 compresso
   che seguono l'hash)` — cioè conta anche la dimensione dell'hash stesso,
   non solo il contenuto dopo. Verificato a scarto zero su due firmware
   ufficiali (`2.4.1`, `2.4.5` CLOSED). Nell'immagine patchata era **32
   byte in meno** — stessa classe di bug, offset diverso. L'hash SHA-256 in
   sé era invece corretto (verificato ricalcolandolo sui byte reali del
   blocco `0xB4` seguente): il problema è solo il campo di lunghezza
   accanto all'hash, non l'hash stesso.

Fix per il campo 2 (richiede decifrare, correggere il campo, e ricifrare
con la stessa chiave/IV già derivati — la lunghezza del contenuto non
cambia, quindi il padding PKCS5 resta identico):

```python
# dopo aver decifrato il blocco 0xB7 (vedi decrypt_rbi.py per la derivazione
# di key2/iv2) e ottenuto il plaintext decompresso del blocco 0xB8:
p = 1 + 4 + 1  # magic(1) + 4 byte sconosciuti + 1 byte
rest_after_hash = len(plain) - (p + 4 + 32)
plain[p:p+4] = struct.pack(">I", 32 + rest_after_hash)
# poi: ripadda con gli stessi byte di padding originali (lunghezza invariata)
# e ricifra con AES-CBC usando la stessa key2/iv2 derivata in decrypt_rbi.py
```

Qualunque tool che modifichi il payload di un `.rbi` "di tipo 2" (patch,
iniezione, decompressione+ricompressione) deve ricalcolare tutti e tre
questi campi, altrimenti l'immagine risultante fallisce la validazione del
CFE — sia in un netboot di recovery sia, presumibilmente, in un flash
locale via `bli_parser`/`bli_unseal` sul device stesso, trattandosi di
controlli a livello di contenitore/wrapper e non del contenuto payload vero
e proprio.

### Ipotesi scartata: offset di inserimento squashfs sbagliato

Prima di trovare i bug 2 e 3 si era sospettato un offset di inserimento
sbagliato per lo squashfs interno (vedi
[`confronto-firmware/CONFRONTO-VERSIONI.md`](confronto-firmware/CONFRONTO-VERSIONI.md)
per gli offset per famiglia). Verificato **escluso** per questo caso: il
magic squashfs (`hsqs`) sta esattamente a `0x600000` nel payload decifrato
da 80 MiB sia nell'immagine ufficiale che in quella patchata (offset
corretto per la famiglia 2.4.x), e tutto ciò che precede quell'offset
(kernel + padding, 6.291.456 byte) è byte-per-byte identico tra le due
immagini — nessuna sovrascrittura del kernel, nessun disallineamento.

## Perché SSH è chiuso di default

`etc/config/dropbear` (UCI), valori di fabbrica su AGTEF 1.0.3:

```
config dropbear
	option enable '0'
	option PasswordAuth 'on'
	option RootPasswordAuth 'off'
	option Port '22'
```

`etc/init.d/dropbear`, funzione che processa ogni sezione UCI `dropbear`:

```sh
dropbear_instance()
{
	...
	[ "${enable}" = "0" ] && return 1
	...
	[ "${PasswordAuth}" -eq 0 ]     && procd_append_param command -s
	[ "${RootPasswordAuth}" -eq 0 ] && procd_append_param command -g
	[ "${RootLogin}" -eq 0 ]        && procd_append_param command -w
	...
}

start_service()
{
	...
	config_load "${NAME}"
	config_foreach dropbear_instance dropbear
}
```

Con `enable '0'` l'istanza non viene nemmeno aperta: dropbear non parte.
`config_foreach` gira su **tutte** le sezioni `dropbear` presenti — per
questo la guida (e lo script) non tocca la sezione di default ma ne
**aggiunge una seconda** (`dropbear.afg`, con `enable='1'`): bastano una
sola sezione abilitata perché il demone parta, e l'originale resta intatto
per un eventuale rollback.

In alternativa, altrettanto valido, si può abilitare direttamente la
sezione di default invece di aggiungerne una nuova:

```sh
uci set dropbear.@dropbear[0].enable='1'
uci set dropbear.@dropbear[0].RootPasswordAuth='on'
uci set dropbear.@dropbear[0].RootLogin='1'
uci commit dropbear
/etc/init.d/dropbear enable && /etc/init.d/dropbear restart
```

Nota su `etc/passwd`: su AGTEF 1.0.3 la shell di root è già `/bin/ash`
(`root:x:0:0:root:/root:/bin/ash`), non `/bin/false`. Il `sed` sulla shell
di root nella guida è quindi difensivo/ridondante su questa versione — ma
non è detto lo sia su tutte le varianti di firmware, meglio lasciarlo.

## Perché la console seriale (UART) non risponde di default

`etc/inittab` di fabbrica:

```
::sysinit:/etc/init.d/rcS S boot
::shutdown:/etc/init.d/rcS K shutdown
#::askconsole:/bin/login
```

La riga `askconsole` è commentata: nessun prompt sulla UART. Il `sed`
della guida la scommenta E sostituisce `/bin/login` con `/bin/ash`
diretto, ottenendo una shell di root senza password sulla porta seriale:

```sh
sed -i -e 's/#//' -e 's#askconsole:.*$#askconsole:/bin/ash#' /etc/inittab
```

risultato:

```
::askconsole:/bin/ash
```

Questo passaggio **non è mai stato documentato esplicitamente nel README**
di questo repo pur essendo già dentro `Root-DGA4130.ps1` — vale la pena
saperlo: è quello che, in caso di bootloop o overlay corrotto (SSH e GUI
web irraggiungibili), permette comunque l'accesso via adattatore USB-TTL
(3.3V) sui pin UART della scheda, bypassando completamente rete/SSH/nginx.

## nginx: nessun interruttore, parte sempre

`etc/init.d/nginx`:

```sh
start_service() {
	[ -d /var/log/nginx ] || mkdir -p /var/log/nginx
	[ -d /var/lib/nginx ] || mkdir -p /var/lib/nginx
	procd_open_instance
	procd_set_param command /usr/sbin/nginx -c /etc/nginx/nginx.conf -g 'daemon off;'
	procd_set_param file /etc/nginx/nginx.conf
	procd_set_param respawn
	procd_close_instance
}
```

Nessun controllo `enable`/UCI: nginx parte sempre tramite
`etc/rc.d/S80nginx -> ../init.d/nginx` nella sequenza di boot standard, e
`respawn` lo fa ripartire da solo se crasha. L'unica dipendenza è
`/etc/nginx/nginx.conf`, che include `ui_server.conf` — generato **una
sola volta al primo boot** da `etc/uci-defaults/tch_0080-nginx`:

```sh
get_banksize() {
	hexsize=$(grep bank_1 /proc/mtd | cut -d ' ' -f 2)
	echo $((0x$hexsize))
}
echo "client_max_body_size $(($(get_banksize) + 524288));" > /etc/nginx/ui_server.conf
```

Se questo file mancasse sull'overlay (es. dopo una corruzione), nginx
fallirebbe l'avvio per un `include` non risolvibile. Utile da controllare
se dopo un recovery incompleto la GUI web risulta irraggiungibile del
tutto (diverso dal caso "risponde ma serve codice Lua grezzo", che invece
punta a `nginx.conf` stesso troncato/diverso da questo, o a moduli Lua
mancanti sotto `/www/cards` — vedi sotto).

## Nota verificata (non presunta) sulla regola firewall della porta 22

Lo script cerca ed "apre" dinamicamente una regola firewall per la 22 via
`fw3 -q print | egrep ...`. Analizzando `etc/config/firewall` di fabbrica:

```
config zone
	option name  lan
	...
	option input ACCEPT
	...

config rule 'rule6'
	option name 'access_2_LAN_IP'
	option src 'lan'
	option proto 'tcp'
	option family 'ipv4'
	option extra '-m multiport --dports 80,22,8080,443,8443 -m addrtype --limit-iface-in ! --dst-type LOCAL'
	option target 'REJECT'
```

La zona `lan` accetta già tutto in ingresso di default (`input ACCEPT`).
L'unica regola che cita la porta 22 (`rule6`) usa `--dst-type LOCAL`
**negato** (`!`): si applica solo al traffico che l'host LAN vuole
*inoltrare verso altri host* su quelle porte, non all'accesso diretto
al router stesso (il cui indirizzo *è* `LOCAL`). Sul firmware statico
analizzato, quindi, **non risulta nessuna regola che blocchi SSH diretto
dal LAN al modem**.

Questo non contraddice necessariamente il passaggio nello script: la
regola specifica cercata da `fw3 -q print` potrebbe comparire solo a
runtime su varianti/versioni diverse del firmware, o essere frutto di
configurazioni provider-specific non presenti in questa immagine. **Non è
stato verificato contro l'output di un device reale** — resta quindi un
passaggio difensivo ragionevole da mantenere nello script così com'è,
non qualcosa da rimuovere sulla sola base di questa analisi statica.

## Riferimenti

- Formato `.rbi` / chiavi OSCK per board: https://github.com/Ansuel/Decrypt_RBI_Firmware_Utility
- Documentazione generale Technicolor gateway: https://hack-technicolor.readthedocs.io/en/stable/
