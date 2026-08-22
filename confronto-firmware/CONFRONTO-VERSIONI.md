# Confronto tra le versioni firmware ufficiali AGTEF (Technicolor DGA0130TCH / VBNT-K)

Confronto strutturale tra 5 immagini firmware ufficiali Technicolor per il
board `VBNT-K` (lo stesso hardware del DGA4130/DGA0130TCH), ottenuto
decifrando ed estraendo ciascun `.rbi` con il metodo descritto in
[`FIRMWARE-ANALYSIS.md`](../FIRMWARE-ANALYSIS.md) e confrontando i rootfs
risultanti file per file.

Versioni analizzate: **1.0.3, 2.2.0, 2.2.1, 2.4.1, 2.4.5**.

## Tabella riassuntiva

| Versione | libc              | Kernel  | Board supportate (`/etc/boards/`)            | File nel rootfs |
|----------|--------------------|---------|-----------------------------------------------|------------------|
| 1.0.3    | uClibc 0.9.33.2    | 3.4.11  | nessuna (immagine single-board)                | 4238             |
| 2.2.0    | glibc 2.24         | 4.1.38  | 5 (VANT-W, VBNT-F/H/K/S)                       | 6114             |
| 2.2.1    | glibc 2.24         | 4.1.38  | 5 (VANT-W, VBNT-F/H/K/S)                       | 6178             |
| 2.4.1    | glibc 2.27         | 4.1.52  | 18 (VANT-W, VBNT-6/7/9/H/J/K/O/S/V/Y, VCNT-A/C/E/H/I/X/Z) | 8011  |
| 2.4.5    | glibc 2.27         | 4.1.52  | 18 (VANT-W, VBNT-6/7/9/H/J/K/O/S/V/Y, VCNT-A/C/E/H/I/X/Z) | 8015  |

Ogni immagine, indipendentemente dal target OpenWrt interno riportato in
`/etc/openwrt_release`, dichiara nell'header `.rbi` lo stesso board
(`VBNT-K`) e lo stesso prodname (`Technicolor DGA0130TCH`) — dalla 2.2.0 in
poi il firmware è semplicemente diventato multi-board, con un profilo per
ciascun modello TIM/Technicolor incluso in `/etc/boards/`.

## Sottosistemi aggiunti dalla 2.2.0 in poi (assenti in 1.0.3)

- Container **LXC** (`/srv/lxc/lxc_ee`)
- **Mosquitto** (broker MQTT)
- Demoni VoIP: `mmpbxd_lite`, `mmpbxfwctl`
- `dosprotect`, `mud`, `nqe`, `opticald`, `wifi-conductor`
- `xl2tpd` (L2TP), `iperf`, `socat`

## Servizi rimossi rispetto alla 1.0.3 (hardening / riduzione superficie d'attacco)

| Servizio rimosso | Motivo probabile |
|---|---|
| `telnet` | protocollo in chiaro (credenziali in plaintext), sostituito da SSH |
| `samba` / `samba-nmbd` | server SMB/CIFS per condivisione USB in LAN, storico bersaglio di exploit gravi (es. classe EternalBlue) |
| `minidlna` / `minidlna-procd` | server media DLNA/UPnP |
| `dhcprelay` | relay DHCP — più un cambio architetturale che una misura di sicurezza pura |
| `mmdbd` | demone di gestione config/database interno TIM, poco documentato pubblicamente |

In sintesi: dalla 2.2.0 in poi TIM ha rimosso i demoni di condivisione
file/media esposti in LAN che non servivano più al prodotto, mantenendo
solo i servizi essenziali — riduzione della superficie d'attacco via
rimozione feature, non patch mirate a CVE specifiche.

## Nota su WireGuard

Nessuna delle 5 immagini ufficiali analizzate include moduli o binari
WireGuard: va aggiunto via cross-compilazione per il target ARM
Cortex-A9/BCM63138, non è presente in nessuna versione stock TIM.

## Metodologia

1. Decifratura di ogni `.rbi` con la catena documentata in
   [`FIRMWARE-ANALYSIS.md`](../FIRMWARE-ANALYSIS.md) (`0xB7` AES-256-CBC →
   `0xB8` firma, verifica saltata → `0xB4` zlib inflate → `0xB0` payload
   in chiaro), ottenendo un'immagine flash da 80 MiB per versione.
2. Individuazione dell'offset del filesystem SquashFS con `binwalk` (varia
   tra famiglie: `0x0` per il kernel, poi `0x210000` per le 2.2.x e
   `0x600000` per le 2.4.x) ed estrazione con `unsquashfs`.
3. Confronto ricorsivo dei rootfs risultanti (liste file, `/etc/config/*`,
   moduli kernel in `/lib/modules/`, contenuto `/etc/openwrt_release`) tra
   tutte le coppie di versioni.
