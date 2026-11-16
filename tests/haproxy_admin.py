#!/usr/bin/env python3

import csv
import io
import socket
import sys

SOCKET_PATH = "/run/haproxy/admin.sock"
BACKEND = "applications"
SERVERS = {"app1", "app2"}


def commande_haproxy(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(SOCKET_PATH)
        client.sendall((command + "\n").encode())
        client.shutdown(socket.SHUT_WR)

        chunks = []
        while True:
            data = client.recv(65536)
            if not data:
                break
            chunks.append(data)

    return b"".join(chunks).decode(errors="replace").strip()


def statut(serveur):
    response = commande_haproxy("show stat")
    lines = response.splitlines()

    header = next(
        (line[2:] for line in lines if line.startswith("# ")),
        None,
    )

    if not header:
        raise RuntimeError("Statistiques HAProxy indisponibles")

    rows = csv.DictReader(
        io.StringIO("\n".join(
            [header] +
            [line for line in lines if line and not line.startswith("#")]
        ))
    )

    for row in rows:
        if row["pxname"] == BACKEND and row["svname"] == serveur:
            return row["status"], int(row["scur"] or 0)

    raise RuntimeError(f"Serveur {serveur} introuvable dans HAProxy")


def main():
    if len(sys.argv) != 3:
        raise SystemExit(
            "Usage : haproxy_admin.py status|disable|enable app1|app2"
        )

    action, serveur = sys.argv[1:]

    if action not in {"status", "disable", "enable"}:
        raise SystemExit("Action inconnue")

    if serveur not in SERVERS:
        raise SystemExit("Serveur inconnu")

    if action in {"disable", "enable"}:
        response = commande_haproxy(
            f"{action} server {BACKEND}/{serveur}"
        )

        if response and not response.lower().startswith("no error"):
            raise RuntimeError(response)

    state, connections = statut(serveur)
    print(f"{state} {connections}")


if __name__ == "__main__":
    main()
