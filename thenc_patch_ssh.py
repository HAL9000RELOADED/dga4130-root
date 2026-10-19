#!/usr/bin/env python3
"""
Patch di un backup THENC (Technicolor DGA4130) per aggiungere una seconda
istanza dropbear (sezione [dropbear], entry "afg") con accesso SSH root
via password sull'interfaccia lan.

Operazione puramente locale su file: nessuna comunicazione di rete, nessun
upload verso il modem.
"""
import difflib
import hashlib
import hmac
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import thenc_tool as tt

_HOME = os.path.expanduser("~")
IN_PATH = os.path.join(_HOME, r"Desktop\Modem\configHAL9000_26_12_2025.bin")
KEY_PATH = os.path.join(_HOME, r".claude\jobs\2817990c\tmp\rip0108_LIVE_64.bin")
OUT_PATH = os.path.join(_HOME, r"Desktop\Modem\configHAL9000_26_12_2025 ssh open.bin")

NEW_LINES = [
    "dropbear.afg=dropbear",
    "dropbear.afg.RootPasswordAuth='on'",
    "dropbear.afg.enable='1'",
    "dropbear.afg.PasswordAuth='on'",
    "dropbear.afg.Port='22'",
    "dropbear.afg.RootLogin='1'",
    "dropbear.afg.Interface='lan'",
]


def aes_cbc_encrypt(key32, iv, plaintext_padded):
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        cipher = Cipher(algorithms.AES(key32), modes.CBC(iv))
        encryptor = cipher.encryptor()
        return encryptor.update(plaintext_padded) + encryptor.finalize()
    except ImportError:
        pass
    try:
        from Crypto.Cipher import AES
        cipher = AES.new(key32, AES.MODE_CBC, iv)
        return cipher.encrypt(plaintext_padded)
    except ImportError:
        pass
    raise RuntimeError("Nessuna libreria crittografica disponibile (cryptography o pycryptodome)")


def pkcs7_pad(data, block_size=16):
    pad_len = block_size - (len(data) % block_size)
    if pad_len == 0:
        pad_len = block_size
    return data + bytes([pad_len]) * pad_len


def insert_dropbear_afg_lines(plaintext_bytes):
    text = plaintext_bytes.decode("utf-8")
    # split preservando i separatori di riga esatti
    lines = text.split("\n")

    # trova ultima riga che comincia con "dropbear.wan." dentro la sezione [dropbear]
    last_wan_idx = None
    in_dropbear_section = False
    for i, raw_line in enumerate(lines):
        stripped = raw_line.strip("\r")
        s = stripped.strip()
        if s.startswith("[") and s.endswith("]"):
            in_dropbear_section = (s == "[dropbear]")
            continue
        if in_dropbear_section and s.startswith("dropbear.wan."):
            last_wan_idx = i

    if last_wan_idx is None:
        raise ValueError("Non ho trovato nessuna riga 'dropbear.wan.' dentro la sezione [dropbear]")

    # determina se le righe usano \r\n
    uses_crlf = "\r" in [ln[-1:] if ln.endswith("\r") else "" for ln in lines[:last_wan_idx + 1]]
    # più robusto: controlla se la riga originale del match termina con \r
    line_has_cr = lines[last_wan_idx].endswith("\r")
    new_entries = [(ln + "\r") if line_has_cr else ln for ln in NEW_LINES]

    new_lines = lines[:last_wan_idx + 1] + new_entries + lines[last_wan_idx + 1:]
    new_text = "\n".join(new_lines)
    return new_text.encode("utf-8"), last_wan_idx


def main():
    key64 = Path(KEY_PATH).read_bytes()
    if len(key64) != tt.HMAC_KEY_SIZE:
        raise ValueError(f"chiave hardware attesa {tt.HMAC_KEY_SIZE} byte, ricevuti {len(key64)}")
    aes_key = key64[:tt.AES_KEY_SIZE]

    info = tt.parse_file(IN_PATH)
    valid, computed_hmac, plaintext = tt.decrypt_and_verify(info, key64)
    if not valid:
        raise RuntimeError("HMAC del file originale NON valido: chiave o file errati, abortisco")
    print(f"[input] HMAC originale valido. Plaintext: {len(plaintext)} byte (dopo rimozione padding)")

    # estratto sezione dropbear originale (solo per verifica, nessun dato sensibile)
    orig_lines = plaintext.decode("utf-8").split("\n")
    print("[input] Righe 'dropbear.' trovate nella sezione [dropbear] (originale):")
    in_sec = False
    for ln in orig_lines:
        s = ln.strip("\r").strip()
        if s.startswith("[") and s.endswith("]"):
            in_sec = (s == "[dropbear]")
            continue
        if in_sec and s.startswith("dropbear."):
            print(f"  {s}")

    new_plaintext, insert_idx = insert_dropbear_afg_lines(plaintext)
    print(f"[patch] Inserite {len(NEW_LINES)} righe dopo la riga indice {insert_idx} (ultima dropbear.wan.*)")

    new_plaintext_padded = pkcs7_pad(new_plaintext, 16)
    if len(new_plaintext_padded) % 16 != 0:
        raise RuntimeError("Padding errato: lunghezza non multipla di 16")

    new_iv = os.urandom(16)
    if new_iv == info["iv"]:
        # praticamente impossibile, ma per sicurezza rigenera
        new_iv = os.urandom(16)

    new_ciphertext = aes_cbc_encrypt(aes_key, new_iv, new_plaintext_padded)

    header_raw = info["header_raw"]  # invariato, byte per byte
    signed_region = header_raw + new_iv + new_ciphertext
    new_signature = hmac.new(key64, signed_region, hashlib.sha1).digest()

    final_data = header_raw + new_iv + new_ciphertext + new_signature
    Path(OUT_PATH).write_bytes(final_data)
    print(f"[output] Scritto: {OUT_PATH} ({len(final_data)} byte)")

    # ---------------- VERIFICA ----------------
    verify_info = tt.parse_file(OUT_PATH)
    if verify_info["header_raw"] != header_raw:
        raise RuntimeError("VERIFICA FALLITA: header modificato rispetto all'originale")
    v_valid, v_hmac, v_plaintext = tt.decrypt_and_verify(verify_info, key64)
    print(f"[verify] HMAC ricalcolato sul file scritto: {'VALIDO' if v_valid else 'NON VALIDO'}")
    if not v_valid:
        raise RuntimeError("VERIFICA FALLITA: HMAC del file patchato non valido")

    if v_plaintext != new_plaintext:
        raise RuntimeError("VERIFICA FALLITA: plaintext riletto diverso da quello scritto")

    # diff testuale tra plaintext originale e nuovo, senza stampare contenuto sensibile
    orig_text_lines = plaintext.decode("utf-8").split("\n")
    new_text_lines = v_plaintext.decode("utf-8").split("\n")
    sm = difflib.SequenceMatcher(a=orig_text_lines, b=new_text_lines)
    added = 0
    removed = 0
    modified_blocks = 0
    added_lines_content = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        modified_blocks += 1
        removed += (i2 - i1)
        added += (j2 - j1)
        if tag == "insert":
            added_lines_content.extend(new_text_lines[j1:j2])

    print(f"[verify] Diff plaintext originale vs patchato: blocchi non-'equal'={modified_blocks}, "
          f"righe rimosse/sostituite={removed}, righe aggiunte={added}")

    expected_added = [ln.rstrip("\r") for ln in NEW_LINES]
    actual_added_stripped = [ln.rstrip("\r") for ln in added_lines_content]
    only_expected_added = (removed == 0 and actual_added_stripped == expected_added)

    print(f"[verify] Nessuna riga esistente modificata/rimossa: {'SI' if removed == 0 else 'NO'}")
    print(f"[verify] Le righe aggiunte corrispondono esattamente alle 7 attese, nell'ordine: "
          f"{'SI' if only_expected_added else 'NO'}")

    if not only_expected_added:
        raise RuntimeError("VERIFICA FALLITA: il diff non corrisponde esattamente alle 7 righe attese")

    print("[verify] Righe dropbear.afg presenti nel plaintext patchato (conferma testuale):")
    for ln in NEW_LINES:
        present = ln in v_plaintext.decode("utf-8")
        print(f"  {'OK ' if present else 'MANCA '} {ln}")
        if not present:
            raise RuntimeError(f"VERIFICA FALLITA: riga mancante nel plaintext finale: {ln}")

    final_size = Path(OUT_PATH).stat().st_size
    print()
    print("=== RISULTATO FINALE ===")
    print(f"File scritto: {OUT_PATH}")
    print(f"Dimensione finale: {final_size} byte")
    print(f"HMAC file patchato: VALIDO")
    print(f"Diff contenuto: 0 righe modificate/rimosse, {len(NEW_LINES)} righe aggiunte (sezione [dropbear], entry 'afg')")


if __name__ == "__main__":
    main()
