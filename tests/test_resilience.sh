
#!/usr/bin/env bash
set -euo pipefail

URL="http://127.0.0.1:8081/info"

# Restaurer app1, même si le test échoue.
restaurer() {
    echo "Rétablissement de app1..."
    vagrant ssh app1 -c \
        "sudo systemctl start resultats-bf.service"
}

trap restaurer EXIT

echo "=== TEST R4 : RESILIENCE APPLICATIVE ==="

# Vérifier que les deux applications répondent.
for i in {1..6}; do
    curl -fsS --max-time 2 "$URL"
    echo
done

echo "=== Arrêt de app1 ==="

DEBUT=$(date +%s%3N)

vagrant ssh app1 -c \
    "sudo systemctl stop resultats-bf.service"

echo "=== Vérification de la continuité ==="

ECHECS=0

for i in {1..20}; do
    REPONSE=$(curl -fsS --max-time 2 "$URL") || {
        ECHECS=$((ECHECS + 1))
        continue
    }

    echo "$REPONSE"

    if [[ "$REPONSE" != '{"serveur": "app2"}' ]]; then
        ECHECS=$((ECHECS + 1))
    fi
done

FIN=$(date +%s%3N)
DUREE=$((FIN - DEBUT))

echo "Durée totale du scénario : ${DUREE} ms"
echo "Réponses incorrectes : $ECHECS"

if [[ "$ECHECS" -ne 0 ]]; then
    echo "ECHEC : certaines requêtes n'ont pas abouti à app2."
    exit 1
fi

echo "SUCCES : app2 a assuré toutes les requêtes vérifiées."
