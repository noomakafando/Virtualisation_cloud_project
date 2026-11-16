
#!/usr/bin/env bash
set -euo pipefail

# Supprimer les retours chariot ajoutés par le terminal SSH.
nettoyer_sortie() {
    tr -d '\r'
}

# RESULTATS-BF — Bascule contrôlée PostgreSQL R6
# À lancer sur l'hôte, depuis la racine du projet.

cd "$(dirname "$0")/.."

export NB_APP=2

PRIMARY_FILE="config/primary_db_ip"
OLD_PRIMARY="192.168.56.31"
NEW_PRIMARY="192.168.56.32"
URL="http://127.0.0.1:8081/sante"

echo "=== BASCULE POSTGRESQL R6 ==="

# 1. Vérifier le point de départ.
if [[ "$(cat "$PRIMARY_FILE")" != "$OLD_PRIMARY" ]]; then
    echo "ERREUR : primaire déclaré différent de bdd1."
    exit 1
fi

OLD_ROLE=$(
    vagrant ssh bdd1 -c \
        "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();'" |
        nettoyer_sortie
)

NEW_ROLE=$(
    vagrant ssh bdd2 -c \
        "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();'" |
        nettoyer_sortie
)

if [[ "$OLD_ROLE" != "f" || "$NEW_ROLE" != "t" ]]; then
    echo "ERREUR : rôles PostgreSQL inattendus."
    exit 1
fi

# 2. Vérifier la connexion de réplication.
STREAMING=$(
    vagrant ssh bdd1 -c \
        "sudo -u postgres psql -tAc \
        \"SELECT count(*) FROM pg_stat_replication
          WHERE application_name='bdd2'
          AND state='streaming';\"" |
        nettoyer_sortie
)

if [[ "$STREAMING" != "1" ]]; then
    echo "ERREUR : réplication streaming non active."
    exit 1
fi

echo "Préconditions vérifiées."
echo "Début de la bascule..."

DEBUT=$(date +%s%3N)

# 3. Isoler l'ancien primaire.
# Dans ce laboratoire, on arrête sa VM.
vagrant halt bdd1

# Vérifier explicitement que la VM est arrêtée.
ETAT=$(vagrant status bdd1 --machine-readable |
    awk -F, '$2=="bdd1" && $3=="state" {print $4; exit}')

if [[ "$ETAT" != "poweroff" ]]; then
    echo "ERREUR CRITIQUE : bdd1 n'est pas confirmée arrêtée."
    echo "Promotion interdite pour éviter un split-brain."
    exit 1
fi

echo "Ancien primaire arrêté."

# 4. Promouvoir la réplique.
PROMOTION=$(
    vagrant ssh bdd2 -c \
        "sudo -u postgres psql -tAc \
        'SELECT pg_promote(true, 30);'" |
        nettoyer_sortie
)

if [[ "$PROMOTION" != "t" ]]; then
    echo "ERREUR : promotion PostgreSQL non confirmée."
    exit 1
fi

echo "bdd2 promue en primaire."

# 5. Enregistrer la nouvelle adresse primaire.
printf '%s\n' "$NEW_PRIMARY" > "$PRIMARY_FILE"

# 6. Rediriger les deux serveurs applicatifs.
for APP in app1 app2; do
    echo "Redirection de ${APP} vers bdd2..."

    vagrant ssh "$APP" -c \
        "sudo sed -i \
        's/^DB_HOST=.*/DB_HOST=192.168.56.32/' \
        /etc/resultats-bf/app.env && \
        sudo systemctl restart resultats-bf.service"
done

# 7. Vérifier le retour du service HTTP.
RETABLI=0

for tentative in {1..30}; do
    CODE=$(curl -s -o /dev/null \
        -w '%{http_code}' \
        --max-time 2 "$URL" || true)

    if [[ "$CODE" == "200" ]]; then
        RETABLI=1
        break
    fi

    sleep 1
done

FIN=$(date +%s%3N)
DUREE=$((FIN - DEBUT))

echo "Durée totale : ${DUREE} ms"

if [[ "$RETABLI" -ne 1 ]]; then
    echo "ECHEC : service HTTP non rétabli."
    echo "Intervention nécessaire, ne pas rallumer bdd1."
    exit 1
fi

echo "SUCCES : service HTTP opérationnel via bdd2."
echo "ATTENTION : bdd1 doit rester arrêtée."
