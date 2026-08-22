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
