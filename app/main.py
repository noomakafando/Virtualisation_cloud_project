#!/usr/bin/env python3
"""API HTTP légère du projet RÉSULTATS-BF."""

import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import psycopg2


def connexion_db():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        dbname="resultats_bf",
        user="resultats_app",
        password=os.environ["DB_APP_PASSWORD"],
        connect_timeout=2,
    )


class API(BaseHTTPRequestHandler):

    def repondre(self, statut, donnees):
        contenu = json.dumps(donnees, ensure_ascii=False).encode("utf-8")
        self.send_response(statut)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(contenu)))
        self.end_headers()
        self.wfile.write(contenu)

    def do_GET(self):
        url = urlsplit(self.path)

        if url.path == "/info":
            return self.repondre(200, {"serveur": socket.gethostname()})

        if url.path == "/sante":
            try:
                with connexion_db() as db:
                    with db.cursor() as curseur:
                        curseur.execute("SELECT 1")
                        curseur.fetchone()
                return self.repondre(200, {"statut": "OK"})
            except psycopg2.Error:
                return self.repondre(503, {"statut": "INDISPONIBLE"})

        if url.path == "/resultat":
            parametres = parse_qs(url.query)
            matricule = parametres.get("matricule", [""])[0].strip()

            if not matricule or len(matricule) > 20:
                return self.repondre(400, {"erreur": "Matricule invalide"})

            try:
                with connexion_db() as db:
                    with db.cursor() as curseur:
                        curseur.execute(
                            """
                            SELECT matricule, nom, serie, moyenne, admis
                            FROM public.resultats
                            WHERE matricule = %s
                            """,
                            (matricule,),
                        )
                        resultat = curseur.fetchone()
            except psycopg2.Error:
                return self.repondre(503, {"erreur": "Base indisponible"})

            if resultat is None:
                return self.repondre(404, {"erreur": "Matricule inconnu"})

            return self.repondre(200, {
                "matricule": resultat[0],
                "nom": resultat[1],
                "serie": resultat[2],
                "moyenne": float(resultat[3]),
                "admis": resultat[4],
            })

        return self.repondre(404, {"erreur": "Route inconnue"})


if __name__ == "__main__":
    adresse = os.environ["APP_IP"]
    ThreadingHTTPServer((adresse, 8000), API).serve_forever()
