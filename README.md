
cat > README.md <<'EOF'
# RÉSULTATS-BF

**Projet de groupe — Master Informatique**
**Module : DevOps et infrastructures reproductibles**

Infrastructure virtualisée, résiliente et scalable pour la consultation de résultats fictifs au Burkina Faso.

## 1. Présentation

RÉSULTATS-BF est un projet DevOps permettant de déployer automatiquement une infrastructure comprenant des applications Python, des bases PostgreSQL répliquées, un répartiteur de charge HAProxy et une supervision Prometheus.

L'infrastructure est orchestrée avec Vagrant et VirtualBox.

## 2. Objectifs

- Automatiser la création des machines virtuelles.
- Garantir l'idempotence du provisionnement.
- Permettre la scalabilité horizontale des applications.
- Assurer la continuité du service en cas de panne applicative.
- Mettre en œuvre la réplication PostgreSQL.
- Tester la bascule du primaire PostgreSQL.
- Protéger les informations sensibles.
- Limiter l'exposition réseau.
- Superviser les services.
- Effectuer des déploiements progressifs.

## 3. Architecture

L'infrastructure comporte cinq VM par défaut.

| VM | Adresse IP privée | Fonction |
|---|---|---|
| lb1 | 192.168.56.11 | HAProxy et Prometheus |
| app1 | 192.168.56.21 | Application Python |
| app2 | 192.168.56.22 | Application Python |
| bdd1 | 192.168.56.31 | PostgreSQL |
| bdd2 | 192.168.56.32 | PostgreSQL |

Architecture logique :

```text
             Utilisateur
                 |
        127.0.0.1:8081
                 |
                 v
          HAProxy (lb1)
                 |
          +------+------+
          |             |
          v             v
        app1          app2
          |             |
          +------+------+
                 |
                 v
       PostgreSQL primaire
                 |
          Streaming WAL
                 |
                 v
       PostgreSQL réplique

Supervision : Prometheus + Blackbox
                  sur lb1
```

Les rôles PostgreSQL sont dynamiques. Le fichier `config/primary_db_ip` indique le primaire actuel.

Configuration validée :

- bdd2 : primaire.
- bdd1 : réplique.

## 4. Technologies

- Ubuntu Server 24.04
- Vagrant et VirtualBox
- Python 3 et psycopg2
- PostgreSQL 16
- HAProxy
- Prometheus
- Blackbox Exporter
- Bash
- Git et GitHub

## 5. Installation

### Prérequis

Installer Git, Vagrant et VirtualBox.

L'image Vagrant utilisée est `bento/ubuntu-24.04`, version `202510.26.0`.

### Clonage

```bash
git clone git@github.com:noomakafando/Virtualisation_cloud_project.git
cd Virtualisation_cloud_project
```

### Secrets

```bash
cp .env.exemple .env
```

Remplacer les valeurs fictives dans `.env` par des mots de passe forts.

Le fichier `.env` est ignoré par Git.

### Démarrage

Avec bdd2 comme primaire :

```bash
NB_APP=2 vagrant up bdd2
NB_APP=2 vagrant up bdd1
NB_APP=2 vagrant up app1 app2
NB_APP=2 vagrant up lb1
```

Si bdd1 est défini comme primaire, inverser les deux premières commandes.

Vérification :

```bash
NB_APP=2 vagrant status
```

## 6. API

Point d'entrée :

`http://127.0.0.1:8081`

### Santé

```bash
curl http://127.0.0.1:8081/sante
```

Résultat attendu :

```json
{"statut":"OK"}
```

### Serveur applicatif

```bash
curl http://127.0.0.1:8081/info
```

Renvoie `app1` ou `app2`.

### Consultation de résultat

```bash
curl "http://127.0.0.1:8081/resultat?matricule=MAT000001"
```

La base contient 50 000 candidats fictifs.

## 7. Scalabilité R3

Le nombre d'applications est contrôlé par `NB_APP`.

Exemple :

```bash
NB_APP=4 vagrant up
NB_APP=4 vagrant provision lb1
```

Pour revenir à deux applications :

```bash
NB_APP=2 vagrant provision lb1
```

Arrêter séparément les VM applicatives supplémentaires devenues inutiles.

## 8. Réplication PostgreSQL R5

La réplication PostgreSQL utilise le streaming physique WAL et un slot de réplication.

Vérification du primaire :

```bash
vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();'"
```

Résultat attendu : `f`.

Vérification de la réplique :

```bash
vagrant ssh bdd1 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();'"
```

Résultat attendu : `t`.

Vérification du streaming :

```bash
vagrant ssh bdd2 -c "sudo -u postgres psql -c 'SELECT application_name, state FROM pg_stat_replication;'"
```

Résultat attendu : `bdd1 | streaming`.

## 9. Résilience et bascule

### Résilience applicative R4

HAProxy surveille `/sante` et retire de la rotation les applications indisponibles.

Scripts :

```bash
bash tests/test_resilience.sh
bash tests/run_r4_timing.sh
```

Une détection de panne applicative a été observée en 0,408 seconde après l'indisponibilité TCP dans le test de temporisation.

### Bascule PostgreSQL R6

Script :

```text
tests/failover_bdd.sh
```

Une bascule PostgreSQL a été mesurée à 72,673 secondes lors du scénario testé.

La bascule change le rôle des bases et nécessite une gestion prudente de l'ancien primaire.

## 10. Supervision E2

Prometheus et Blackbox Exporter sont installés sur `lb1`, sans VM supplémentaire.

Sondes configurées :

- lb1 : HTTP.
- app1 : HTTP.
- app2 : HTTP.
- bdd1 : TCP PostgreSQL.
- bdd2 : TCP PostgreSQL.

Commande :

```bash
vagrant ssh lb1 -c "curl -fsSG --data-urlencode 'query=probe_success' http://127.0.0.1:9090/api/v1/query"
```

`probe_success=1` indique que la sonde a réussi.

La supervision ne mesure pas directement le retard de réplication.

## 11. Rolling Deployment E4

Le déploiement progressif repose sur HAProxy.

Scripts :

```text
tests/haproxy_admin.py
tests/rolling_deploy.sh
tests/test_rolling_availability.sh
```

Le scénario testé a maintenu 199 réponses HTTP 200 sur 199 requêtes pendant un reprovisionnement progressif.

Ce test ne constitue pas une preuve d'absence d'interruption pour toutes les requêtes possibles.

## 12. Sécurité R7 et R8

### Protection des secrets

Le fichier `.env` n'est pas suivi par Git.

Permissions vérifiées :

```text
/etc/resultats-bf/app.env     600 root:root
/var/lib/postgresql/.pgpass   600 postgres:postgres
```

### Réseau

Les communications internes utilisent le réseau privé `192.168.56.0/24`.

La redirection HTTP est limitée à :

```text
127.0.0.1:8081
```

Aucune redirection Vagrant des ports 5432 et 8000 n'a été constatée.

Les redirections SSH Vagrant restent disponibles.

## 13. Validation des exigences

| Exigence | Résultat |
|---|---|
| R1 — Reconstruction complète | Validée |
| R2 — Idempotence | Validée |
| R3 — Scalabilité horizontale | Validée |
| R4 — Résilience HAProxy | Validée |
| R5 — Réplication PostgreSQL | Validée |
| R6 — Bascule PostgreSQL | Validée |
| R7 — Gestion des secrets | Contrôles réalisés |
| R8 — Isolation réseau | Contrôles réalisés |
| E2 — Supervision | Validée |
| E4 — Rolling Deployment | Validée |

## 14. Reconstruction intégrale R1

Une reconstruction complète depuis zéro a été exécutée avec succès.

Résultats :

- Cinq machines virtuelles recréées.
- 50 000 candidats générés.
- Réplication PostgreSQL opérationnelle.
- Applications Python accessibles.
- HAProxy répartissant les requêtes.
- Cinq sondes Prometheus avec `probe_success=1`.

Attention : `vagrant destroy -f` supprime les disques des VM. Sauvegarder les données importantes avant utilisation.

## 15. Limites

Le projet constitue une infrastructure pédagogique et non un système de production.

Limites principales :

- Pas de bascule PostgreSQL entièrement automatisée.
- Pas de haute disponibilité du répartiteur lb1.
- Pas de Grafana ni d'alerting automatisé.
- Une seule machine physique héberge toutes les VM.
- Les données sont fictives.
- Les contrôles de sécurité ne remplacent pas un audit complet.

## 16. Conclusion

RÉSULTATS-BF démontre la reproductibilité, l'idempotence, la scalabilité, la résilience applicative et la réplication de données à l'aide de Vagrant.

Les extensions de supervision et de déploiement progressif complètent l'infrastructure sans ajouter de machine virtuelle.
EOF

echo "README.md remplacé."
wc -l README.md
