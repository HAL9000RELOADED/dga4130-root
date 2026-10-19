#!/usr/bin/env python3
"""SSH helper for modem1 (DGA4130, 192.168.1.1, root/root). Usage:
    python modem_ssh.py "<remote command>"
Prints stdout/stderr of the remote command. Read-only or write, caller's responsibility.
"""
import paramiko
import sys

HOST = "192.168.1.1"
USER = "root"
PASS = "root"


def main():
    if len(sys.argv) < 2:
        print("usage: modem_ssh.py \"<remote command>\"", file=sys.stderr)
        sys.exit(2)
    remote_cmd = sys.argv[1]

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(HOST, username=USER, password=PASS, timeout=8, look_for_keys=False, allow_agent=False)
    except Exception as e:
        print(f"CONNECT_FAILED: {e}", file=sys.stderr)
        sys.exit(1)

    stdin, stdout, stderr = client.exec_command(remote_cmd, timeout=30)
    out = stdout.read().decode(errors="replace")
    err = stderr.read().decode(errors="replace")
    exit_code = stdout.channel.recv_exit_status()
    client.close()

    if out:
        print(out, end="")
    if err:
        print(err, end="", file=sys.stderr)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
