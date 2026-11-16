# RÉSULTATS-BF — Matrice de validation

## 1. Contexte

Les validations ont été effectuées le 16 novembre 2026
dans un environnement Vagrant / VirtualBox sous Ubuntu 24.04.

Les résultats indiqués ci-dessous sont ceux des essais réellement
observés. Ils ne constituent pas des garanties de production.

## 2. Synthèse

| ID | Exigence | Preuve observée | Verdict |
|---|---|---|---|
| R1 | Reconstruction | 5 VM recréées depuis zéro | Réussi |
| R2 | Idempotence | Reprovisionnement des 5 VM sans erreur | Réussi |
| R3 | Scalabilité | Passage de 2 à 4 applications puis retour à 2 | Réussi |
| R4 | Résilience | Bascule des requêtes vers l'application disponible | Réussi |
| R5 | Réplication | PostgreSQL streaming, 50 000 candidats | Réussi |
| R6 | Bascule DB | Promotion et réintégration de la réplique | Réussi |
| R7 | Secrets | .env ignoré, permissions 600 vérifiées | Contrôles réussis |
| R8 | Réseau | HTTP local, réseau privé, ports contrôlés | Contrôles réussis |
| E2 | Supervision | 5 sondes probe_success=1 | Réussi |
| E4 | Rolling Deployment | 199 réponses HTTP 200 sur 199 | Réussi |

## 3. Mesures

### R1 — Reconstruction

- Destruction des cinq VM.
- Reconstruction séquentielle.
- 50 000 candidats initialisés.
- bdd2 primaire, bdd1 réplique.
- Réplication streaming active.
- API /sante opérationnelle.
- API /resultat opérationnelle.
- Répartition entre app1 et app2.
- Cinq sondes Prometheus disponibles.

### R2 — Idempotence

Commande exécutée :

    NB_APP=2 vagrant provision

Résultat : reprovisionnement réussi des cinq VM sans
réinitialiser les 50 000 candidats ni modifier les rôles.

### R3 — Scalabilité

Scénario testé : deux applications, puis quatre applications,
puis retour à deux.

Sur 20 requêtes /info avec quatre applications :
chaque application a répondu cinq fois.

### R4 — Résilience

Arrêt du service applicatif sur app1.

HAProxy a redirigé les requêtes vers app2.

Temps mesuré pour détecter un backend indisponible :
0,408 seconde à partir de l'indisponibilité TCP observée.

### R5 — Réplication

Sur bdd2 :

    SELECT pg_is_in_recovery();

Résultat : false.

Sur bdd1 :

    SELECT pg_is_in_recovery();

Résultat : true.

Sur le primaire :

    SELECT application_name, state FROM pg_stat_replication;

Résultat : bdd1 en streaming.

### R6 — Bascule PostgreSQL

Une bascule contrôlée du primaire bdd1 vers bdd2 a été
exécutée et mesurée à 72,673 secondes.

L'ancien primaire a ensuite été reconstruit comme réplique.

Cette mesure inclut la procédure d'arrêt de l'ancien primaire.

### R7 — Secrets

Contrôles effectués :

    git check-ignore -v .env
    git ls-files .env

Résultats :
- .env ignoré.
- .env non suivi dans Git.
- app.env : 600 root:root.
- .pgpass : 600 postgres:postgres.

### R8 — Isolation réseau

Adresses :

    lb1  : 192.168.56.11
    app1 : 192.168.56.21
    app2 : 192.168.56.22
    bdd1 : 192.168.56.31
    bdd2 : 192.168.56.32

Port HTTP hôte :

    127.0.0.1:8081

Aucune redirection Vagrant des ports PostgreSQL 5432
ou applicatifs 8000 n'a été constatée.

Les redirections SSH restent disponibles.

### E2 — Supervision

Prometheus surveille cinq cibles :

- lb1 : HTTP.
- app1 : HTTP.
- app2 : HTTP.
- bdd1 : TCP.
- bdd2 : TCP.

Pendant l'arrêt de app1 :

    probe_success{service="app1"} = 0

Après redémarrage :

    probe_success{service="app1"} = 1

Après reconstruction R1, les cinq sondes sont revenues à 1.

### E4 — Rolling Deployment

Un déploiement progressif a été réalisé en retirant
successivement les applications de HAProxy.

Résultat observé :

    199 requêtes HTTP
    199 réponses HTTP 200
    0 erreur observée

Ce test vérifie la disponibilité échantillonnée pendant le
reprovisionnement, sans prouver un changement de version applicative.

## 4. Limites

- Les tests sont réalisés sur une seule machine physique.
- La bascule PostgreSQL reste orchestrée par script.
- HAProxy est un point de défaillance unique.
- Les sondes TCP ne garantissent pas l'intégrité PostgreSQL.
- Les mesures de performance sont propres à l'environnement testé.
- Les contrôles R7/R8 ne remplacent pas un audit de sécurité complet.

## 5. Conclusion

Les scénarios R1 à R8 et les extensions E2/E4 ont produit
les résultats attendus dans l'environnement de laboratoire.

Les preuves principales reposent sur les sorties Vagrant,
les requêtes HTTP, les commandes PostgreSQL et les métriques
Prometheus observées pendant les tests.
