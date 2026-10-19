import concurrent.futures
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.error

TARGET = "192.168.1.1"
PORTS = list(range(1, 1025)) + [7547, 8080, 8443, 49152]
SCAN_WORKERS = 20
SCAN_TIMEOUT = 1.5
CYCLE_SECONDS = 60
HTTP_PATHS = {
    80: "http://{}/",
    443: "https://{}/",
    8080: "http://{}:8080/",
}

# Pagine .lp reali (routabili via URL, non frammenti template interni),
# ricavate dal dump firmware decompilato: github.com/Ansuel/tch-nginx-gui
# (decompressed/gui_file/www/docroot/**.lp)
LP_PAGES = [
    "/cards.lp", "/error.lp", "/gateway.lp", "/login.lp",
    "/modals/applications-modal.lp", "/modals/assistance-modal.lp",
    "/modals/bridge-grouping-modal.lp", "/modals/broadband-modal.lp",
    "/modals/changelog.lp", "/modals/command-log-read-modal.lp",
    "/modals/contentsharing-modal.lp", "/modals/customdns-modal.lp",
    "/modals/cwmpconf-modal.lp", "/modals/device-modal.lp",
    "/modals/diagnostics-connection-modal.lp", "/modals/diagnostics-leds-modal.lp",
    "/modals/diagnostics-network-modal.lp", "/modals/diagnostics-ping-modal.lp",
    "/modals/diagnostics-tcpdump-modal.lp", "/modals/diagnostics-xdsl-graphics-modal.lp",
    "/modals/diagnostics-xdsl-modal.lp", "/modals/dmz-modal.lp",
    "/modals/dosprotect-modal.lp", "/modals/dyndns-modal.lp",
    "/modals/eco-modal.lp", "/modals/ethernet-modal.lp",
    "/modals/fast-cache-option-modal.lp", "/modals/firewall-modal.lp",
    "/modals/gateway-modal.lp", "/modals/hostmap-modal.lp",
    "/modals/internet-modal.lp", "/modals/iproutes-modal.lp",
    "/modals/ipv6devices-modal.lp", "/modals/log-connections-modal.lp",
    "/modals/log-routingtable-modal.lp", "/modals/logviewer-modal.lp",
    "/modals/lte-doctor.lp", "/modals/lte-modal.lp",
    "/modals/lte-profiles.lp", "/modals/lte-sim.lp", "/modals/lte-sms.lp",
    "/modals/mmpbx-codec-modal.lp", "/modals/mmpbx-contacts-modal.lp",
    "/modals/mmpbx-dect-modal.lp", "/modals/mmpbx-global-modal.lp",
    "/modals/mmpbx-inoutgoingmap-modal.lp", "/modals/mmpbx-log-modal.lp",
    "/modals/mmpbx-profile-modal.lp", "/modals/mmpbx-service-modal.lp",
    "/modals/mmpbx-sipdevice-modal.lp", "/modals/mmpbx-statistics-modal.lp",
    "/modals/modem-stats-modal.lp", "/modals/modgui-modal.lp",
    "/modals/mwan-modal.lp", "/modals/nat-alg-helper-modal.lp",
    "/modals/nfc-modal.lp", "/modals/parental-modal.lp",
    "/modals/port-mirror-modal.lp", "/modals/printersharing-modal.lp",
    "/modals/qos-classify-modal.lp", "/modals/qos-queue-modal.lp",
    "/modals/relay-modal.lp", "/modals/speedservice-modal.lp",
    "/modals/system-cron-modal.lp", "/modals/system-init-modal.lp",
    "/modals/system-modal.lp", "/modals/tod-modal.lp",
    "/modals/tod_dnd-modal.lp", "/modals/tod_wireless-modal.lp",
    "/modals/traffic-monitor.lp", "/modals/upnp-modal.lp",
    "/modals/usermgr-modal.lp", "/modals/wanservices-modal.lp",
    "/modals/wifi-nurse-modal.lp", "/modals/wireless-client-modal.lp",
    "/modals/wireless-modal.lp", "/modals/wireless-qrcode-modal.lp",
    "/modals/wizard-modal.lp", "/modals/wol-modal.lp",
    "/modals/xdsl-low-modal.lp", "/parental-block.lp",
    "/password-reset.lp", "/password.lp", "/stats.lp",
]
LP_SCAN_WORKERS = 15


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def ping_ok():
    try:
        r = subprocess.run(
            ["ping", "-c", "2", "-W", "2", TARGET],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return r.returncode == 0
    except Exception:
        return False


def check_port(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(SCAN_TIMEOUT)
    try:
        return port if s.connect_ex((TARGET, port)) == 0 else None
    except Exception:
        return None
    finally:
        s.close()


def scan_ports():
    with concurrent.futures.ThreadPoolExecutor(max_workers=SCAN_WORKERS) as ex:
        return sorted(p for p in ex.map(check_port, PORTS) if p)


def classify_http(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "dga4130-monitor"})
        ctx = None
        if url.startswith("https"):
            import ssl
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(req, timeout=5, context=ctx) as resp:
            body = resp.read(2000).decode(errors="ignore")
            status = resp.status
    except urllib.error.HTTPError as e:
        try:
            body = e.read(2000).decode(errors="ignore")
        except Exception:
            body = ""
        status = e.code
    except Exception as e:
        return f"ERRORE({type(e).__name__})"

    if "ngx.print" in body:
        kind = "lua_grezzo"
    elif "503 Service Temporarily Unavailable" in body:
        kind = "503_nginx"
    elif "INTERCEPT" in body:
        kind = "captive_intercept"
    else:
        kind = f"altro(status={status})"
    return f"{kind} len={len(body)}"


def classify_kind(url):
    """Come classify_http ma ritorna solo l'etichetta (senza lunghezza), per il riepilogo pagine .lp."""
    full = classify_http(url)
    return full.split(" len=")[0].split("(")[0]


def scan_lp_pages():
    urls = [f"http://{TARGET}{path}" for path in LP_PAGES]
    with concurrent.futures.ThreadPoolExecutor(max_workers=LP_SCAN_WORKERS) as ex:
        results = dict(zip(LP_PAGES, ex.map(classify_kind, urls)))

    # Riepilogo per non floodare i log: conteggio per categoria + elenco
    # delle pagine che si discostano dalla categoria maggioritaria (le vere
    # anomalie interessanti), non il dettaglio di tutte le 84 pagine.
    counts = {}
    for kind in results.values():
        counts[kind] = counts.get(kind, 0) + 1
    majority = max(counts, key=counts.get) if counts else None
    outliers = {p: k for p, k in results.items() if k != majority}
    return {"riepilogo": counts, "maggioranza": majority, "anomalie": outliers}


def snapshot():
    reachable = ping_ok()
    open_ports = scan_ports() if reachable else []
    http_states = {}
    for port, tmpl in HTTP_PATHS.items():
        if port in open_ports:
            http_states[port] = classify_http(tmpl.format(TARGET))
        else:
            http_states[port] = "porta chiusa"
    lp_pages = scan_lp_pages() if 80 in open_ports else None
    return {
        "ping": reachable,
        "porte_aperte": open_ports,
        "http": http_states,
        "pagine_lp": lp_pages,
    }


def main():
    log(f"Avvio monitor per {TARGET}, ciclo ogni {CYCLE_SECONDS}s")
    last = None
    while True:
        cur = snapshot()
        if cur != last:
            log(f"CAMBIO: {cur}")
            last = cur
        else:
            log(f"invariato: ping={cur['ping']} porte={cur['porte_aperte']}")
        time.sleep(CYCLE_SECONDS)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
