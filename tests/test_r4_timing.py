
#!/usr/bin/env python3
"""Mesure du délai de retrait de app1 par HAProxy."""

import csv
import io
import socket
import time

SOCKET_HAPROXY = "/run/haproxy/admin.sock"
APP_IP = "192.168.56.21"
APP_PORT = 8000
DELAI_MAX = 5.0
INTERVALLE = 0.1


def etat_haproxy():
    """Lire l'état de app1 via le socket d'administration."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect(SOCKET_HAPROXY)
        client.sendall(b"show stat\n")

        morceaux = []
        while True:
            donnees = client.recv(65536)
            if not donnees:
                break
            morceaux.append(donnees)

    contenu = b"".join(morceaux).decode("utf-8")
    contenu = contenu.lstrip("# ")

    for ligne in csv.DictReader(io.StringIO(contenu)):
        if ligne["pxname"] == "applications" and ligne["svname"] == "app1":
            return ligne["status"]

    raise RuntimeError("app1 introuvable dans HAProxy")


def application_disponible():
    """Tester la disponibilité TCP du service app1."""
    try:
        with socket.create_connection((APP_IP, APP_PORT), timeout=0.15):
            return True
    except OSError:
        return False


def main():
    print("=== MESURE R4 : HAProxy ===", flush=True)

    etat = etat_haproxy()
    if not etat.startswith("UP") or not application_disponible():
        raise RuntimeError("app1 doit être UP avant le test")

    print("app1 est UP. Surveillance active.", flush=True)
    print("Arrêter maintenant le service sur app1.", flush=True)

    debut = None
    limite = time.monotonic() + 30

    while time.monotonic() < limite:
        # Détecter la disparition effective du service TCP.
        tcp_disponible = application_disponible()
        instant = time.monotonic()

        if not tcp_disponible and debut is None:
            debut = instant
            print("Panne TCP de app1 détectée.", flush=True)

        etat = etat_haproxy()

        if debut is not None and etat.startswith("DOWN"):
            duree = time.monotonic() - debut

            print(f"État HAProxy : {etat}", flush=True)
            print(f"Délai observé : {duree:.3f} seconde(s)")

            if duree < DELAI_MAX:
                print("SUCCÈS : retrait observé en moins de 5 s")
                return

            raise RuntimeError("ÉCHEC : délai supérieur ou égal à 5 s")

        time.sleep(INTERVALLE)

    raise RuntimeError("Délai dépassé ou panne non détectée")


if __name__ == "__main__":
    main()
