#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export NB_APP=2

LOG="$(mktemp)"
PID=""

cleanup() {
    if [[ -n "$PID" ]]; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -f "$LOG"
}
trap cleanup EXIT

echo "=== TEST E4 : DISPONIBILITE PENDANT DEPLOIEMENT ==="

# Surveiller le point d'entrée pendant le déploiement.
(
    while true; do
        code="$(curl -s -o /dev/null \
            -w '%{http_code}' \
            --connect-timeout 1 \
            --max-time 2 \
            http://127.0.0.1:8081/sante || true)"

        printf '%s\n' "$code" >> "$LOG"
        sleep 0.2
    done
) &
PID=$!

sleep 1

RESULT=0
./tests/rolling_deploy.sh || RESULT=$?

kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""

TOTAL="$(wc -l < "$LOG")"
SUCCESS="$(grep -cx '200' "$LOG" || true)"
FAILURES=$((TOTAL - SUCCESS))

echo
echo "======================================"
echo " RESULTATS DU TEST E4"
echo "======================================"
echo "Requêtes totales : $TOTAL"
echo "HTTP 200         : $SUCCESS"
echo "Échecs           : $FAILURES"

if [[ "$RESULT" -ne 0 ]]; then
    echo "ECHEC : rolling deployment interrompu."
    exit 1
fi

if (( TOTAL == 0 || FAILURES > 0 )); then
    echo "ECHEC : disponibilité non continue."
    exit 1
fi

echo "SUCCES : aucune interruption HTTP observée."
