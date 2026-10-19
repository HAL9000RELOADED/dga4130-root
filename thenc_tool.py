#!/usr/bin/env python3
import argparse
import difflib
import hashlib
import hmac
import sys
from pathlib import Path

HMAC_SIZE = 20
IV_SIZE = 16
AES_KEY_SIZE = 32
HMAC_KEY_SIZE = 64


def load_key(key_file, key_hex):
    if key_file:
        key = Path(key_file).read_bytes()
    elif key_hex:
        key = bytes.fromhex(key_hex.strip())
    else:
        return None
    if len(key) != HMAC_KEY_SIZE:
        raise ValueError(f"chiave hardware attesa {HMAC_KEY_SIZE} byte, ricevuti {len(key)}")
    return key


def split_file(data):
    header_end = data.find(b"\n\n")
    if header_end == -1:
        raise ValueError("delimitatore header '\\n\\n' non trovato")
    header_end += 2
    header_raw = data[:header_end]
    iv = data[header_end:header_end + IV_SIZE]
    if len(iv) != IV_SIZE:
        raise ValueError("file troppo corto per contenere l'IV")
    signature = data[-HMAC_SIZE:]
    encrypted_data = data[header_end + IV_SIZE:-HMAC_SIZE]
    return header_raw, iv, encrypted_data, signature


def parse_header(header_raw):
    fields = {}
    text = header_raw.decode("ascii", errors="replace")
    for line in text.split("\n"):
        line = line.strip("\r")
        if not line:
            continue
        if "=" in line:
            k, _, v = line.partition("=")
            fields[k] = v
    return fields


def parse_file(path):
    data = Path(path).read_bytes()
    header_raw, iv, encrypted_data, signature = split_file(data)
    fields = parse_header(header_raw)
    return {
        "path": path,
        "data": data,
        "header_raw": header_raw,
        "fields": fields,
        "iv": iv,
        "encrypted_data": encrypted_data,
        "signature": signature,
        "file_size": len(data),
        "header_size": len(header_raw),
    }


def print_parsed(info):
    print(f"File: {info['path']}")
    print(f"Dimensione totale file: {info['file_size']} byte")
    print(f"Dimensione header: {info['header_size']} byte")
    print("Campi header:")
    for k, v in info["fields"].items():
        print(f"  {k}={v}")
    print(f"IV (hex): {info['iv'].hex()}")
    print(f"Dimensione blocco dati cifrati: {len(info['encrypted_data'])} byte")
    print(f"Firma HMAC-SHA1 (hex): {info['signature'].hex()}")
    print(f"SHA256 file completo: {hashlib.sha256(info['data']).hexdigest()}")


def aes_cbc_decrypt(key32, iv, ciphertext):
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        cipher = Cipher(algorithms.AES(key32), modes.CBC(iv))
        decryptor = cipher.decryptor()
        return decryptor.update(ciphertext) + decryptor.finalize()
    except ImportError:
        pass
    try:
        from Crypto.Cipher import AES
        cipher = AES.new(key32, AES.MODE_CBC, iv)
        return cipher.decrypt(ciphertext)
    except ImportError:
        pass
    raise RuntimeError(
        "Nessuna libreria crittografica disponibile. Installa una delle due con:\n"
        "  pip install cryptography\n"
        "oppure\n"
        "  pip install pycryptodome"
    )


def strip_pkcs7(data):
    if not data:
        return data
    pad_len = data[-1]
    if pad_len < 1 or pad_len > 16 or pad_len > len(data):
        return data
    if data[-pad_len:] != bytes([pad_len]) * pad_len:
        return data
    return data[:-pad_len]


def decrypt_and_verify(info, key64):
    aes_key = key64[:AES_KEY_SIZE]
    hmac_key = key64
    signed_region = info["header_raw"] + info["iv"] + info["encrypted_data"]
    computed_hmac = hmac.new(hmac_key, signed_region, hashlib.sha1).digest()
    valid = hmac.compare_digest(computed_hmac, info["signature"])
    plaintext_padded = aes_cbc_decrypt(aes_key, info["iv"], info["encrypted_data"])
    plaintext = strip_pkcs7(plaintext_padded)
    return valid, computed_hmac, plaintext


def cmd_parse(args):
    info = parse_file(args.file)
    print_parsed(info)
    key = load_key(args.key_file, args.key_hex)
    if key:
        do_decrypt(info, key, args.file)


def do_decrypt(info, key64, in_path):
    valid, computed_hmac, plaintext = decrypt_and_verify(info, key64)
    print(f"HMAC calcolato (hex): {computed_hmac.hex()}")
    if valid:
        print("HMAC valido")
    else:
        print("HMAC NON valido")
    out_path = str(in_path) + ".decrypted"
    Path(out_path).write_bytes(plaintext)
    print(f"Contenuto decifrato scritto in: {out_path} ({len(plaintext)} byte)")
    try:
        text = plaintext.decode("utf-8")
        printable = sum(c.isprintable() or c in "\r\n\t" for c in text) / max(len(text), 1)
        if printable > 0.9:
            lines = text.splitlines()[:20]
            print("Prime righe del contenuto decifrato (sembra testo):")
            for line in lines:
                print(f"  {line}")
    except UnicodeDecodeError:
        pass
    return valid, plaintext


def cmd_decrypt(args):
    key = load_key(args.key_file, args.key_hex)
    if not key:
        print("Errore: 'decrypt' richiede --key-file o --key-hex", file=sys.stderr)
        sys.exit(1)
    info = parse_file(args.file)
    print_parsed(info)
    do_decrypt(info, key, args.file)


def cmd_diff(args):
    info_a = parse_file(args.file_a)
    info_b = parse_file(args.file_b)

    print(f"File A: {info_a['path']}")
    print(f"File B: {info_b['path']}")
    print()
    print(f"Dimensione totale: A={info_a['file_size']} byte, B={info_b['file_size']} byte"
          f" ({'uguale' if info_a['file_size'] == info_b['file_size'] else 'diversa'})")
    print(f"Dimensione header: A={info_a['header_size']} byte, B={info_b['header_size']} byte")
    print(f"Dimensione dati cifrati: A={len(info_a['encrypted_data'])} byte, B={len(info_b['encrypted_data'])} byte")
    print()

    keys = sorted(set(info_a["fields"]) | set(info_b["fields"]))
    print("Confronto campi header:")
    for k in keys:
        va = info_a["fields"].get(k, "<assente>")
        vb = info_b["fields"].get(k, "<assente>")
        status = "UGUALE" if va == vb else "DIVERSO"
        print(f"  {k}: A={va!r} B={vb!r} [{status}]")

    print()
    print(f"IV: A={info_a['iv'].hex()} B={info_b['iv'].hex()}"
          f" ({'uguale' if info_a['iv'] == info_b['iv'] else 'diverso'})")
    print(f"Firma HMAC: A={info_a['signature'].hex()} B={info_b['signature'].hex()}"
          f" ({'uguale' if info_a['signature'] == info_b['signature'] else 'diversa'})")

    key = load_key(args.key_file, args.key_hex)
    if key:
        print()
        print("Decifratura e confronto contenuto in chiaro:")
        valid_a, _hmac_a, plaintext_a = decrypt_and_verify(info_a, key)
        valid_b, _hmac_b, plaintext_b = decrypt_and_verify(info_b, key)
        print(f"  A: HMAC {'valido' if valid_a else 'NON valido'}")
        print(f"  B: HMAC {'valido' if valid_b else 'NON valido'}")
        if valid_a and valid_b:
            try:
                text_a = plaintext_a.decode("utf-8").splitlines()
                text_b = plaintext_b.decode("utf-8").splitlines()
                diff = difflib.unified_diff(text_a, text_b, fromfile=str(args.file_a), tofile=str(args.file_b), lineterm="")
                print("\nDiff testuale del contenuto decifrato:")
                for line in diff:
                    print(line)
            except UnicodeDecodeError:
                print("  Il contenuto decifrato non e' testo UTF-8, diff binario non mostrato")
        else:
            print("  Diff del contenuto saltato: HMAC non valido su almeno uno dei due file")
    else:
        print()
        print("Nessuna chiave fornita: confronto del contenuto decifrato saltato")


def build_parser():
    parser = argparse.ArgumentParser(description="Tool per parsing/decrypt/diff di backup THENC Technicolor DGA4130")
    sub = parser.add_subparsers(dest="command")

    p_parse = sub.add_parser("parse", help="Analizza un file .bin e stampa header/IV/HMAC/SHA256")
    p_parse.add_argument("file", help="Percorso del file .bin")
    p_parse.add_argument("--key-file", help="File binario di 64 byte con la chiave hardware")
    p_parse.add_argument("--key-hex", help="Chiave hardware come stringa hex di 128 caratteri")
    p_parse.set_defaults(func=cmd_parse)

    p_decrypt = sub.add_parser("decrypt", help="Decifra il blocco dati e verifica l'HMAC")
    p_decrypt.add_argument("file", help="Percorso del file .bin")
    p_decrypt.add_argument("--key-file", help="File binario di 64 byte con la chiave hardware")
    p_decrypt.add_argument("--key-hex", help="Chiave hardware come stringa hex di 128 caratteri")
    p_decrypt.set_defaults(func=cmd_decrypt)

    p_diff = sub.add_parser("diff", help="Confronta due file .bin (header, dimensioni, opzionalmente contenuto decifrato)")
    p_diff.add_argument("file_a", help="Primo file .bin")
    p_diff.add_argument("file_b", help="Secondo file .bin")
    p_diff.add_argument("--key-file", help="File binario di 64 byte con la chiave hardware")
    p_diff.add_argument("--key-hex", help="Chiave hardware come stringa hex di 128 caratteri")
    p_diff.set_defaults(func=cmd_diff)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)
    try:
        args.func(args)
    except (FileNotFoundError, ValueError, RuntimeError) as exc:
        print(f"Errore: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
