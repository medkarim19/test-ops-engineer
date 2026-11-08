Ce repo contient deux parties :

1. **Partie 1 - PyInfra** : déployer un service de health check sur 2 serveurs avec systemd.
2. **Partie 2 - Kubernetes** : déployer ClickHouse sur Minikube et y insérer des métriques simulées.

```
.
├── part1_pyinfra/
│   ├── metrics_collector.py        # serveur HTTP avec /health sur le port 8080
│   ├── metrics-collector.service   # unit systemd
│   ├── deploy.py                   # déploiement PyInfra
│   └── hosts.py                    # serveurs cibles (à modifier)
└── part2_k8s_clickhouse/
    ├── clickhouse-deployment.yaml  # StatefulSet + volumeClaimTemplates
    ├── clickhouse-service.yaml     # Service NodePort
    ├── configmap.yaml              # user, password et database ClickHouse
    ├── send_metrics.py             # insère 10 lignes aléatoires en HTTP
    └── deploy.sh                   # déploiement automatisé de la partie 2
```

---

## Partie 1 - PyInfra

### Environnement de test

J'ai utilisé **deux VMs Debian 13**. J'ai choisi une image légère entre Alpine et Debian, mais Alpine n'utilise pas systemd comme système d'initialisation (elle utilise OpenRC), alors que l'énoncé demande un service systemd. Debian reste légère et utilise systemd.

### Prérequis

**1. Sur les deux machines cibles**

- Configurer l'authentification par **clés SSH** plutôt que par mot de passe : c'est plus sécurisé et c'est la bonne pratique.
  ```bash
  ssh-keygen -t ed25519                 # sur ta machine, si tu n'as pas encore de clé
  ssh-copy-id root@<ip-de-la-machine>   # copie la clé publique sur la cible
  ```
- Autoriser la connexion SSH avec `root` dans `/etc/ssh/sshd_config` :
  ```
  PermitRootLogin prohibit-password
  systemctl restart ssh
  ```

**2. Sur ta machine**

- Mettre les adresses IP des machines dans `part1_pyinfra/hosts.py` :
  ```python
  hosts = [
      ("server1", {"ssh_hostname": "<ip du serveur 1>", "ssh_user": "<utilisateur>"}),
      ("server2", {"ssh_hostname": "<ip du serveur 2>", "ssh_user": "<utilisateur>"}),
  ]
  ```
- Créer et activer un environnement virtuel, puis installer PyInfra :
  ```bash
  python3 -m venv pyinfra
  source pyinfra/bin/activate
  pip install pyinfra
  ```

### Lancement

```bash
cd part1_pyinfra
pyinfra hosts.py deploy.py
```

### Ce que fait le déploiement

- `metrics_collector.py` répond à `GET /health` avec `{"status": "ok"}` sur le port 8080.
- `metrics-collector.service` démarre au boot et redémarre en cas de crash (`Restart=always`). Les logs sont dans `journalctl` grâce à `python3 -u`.
- `deploy.py` copie le script et l'unit, puis fait un `enable` et un `start`. Il est **idempotent** : un 2e lancement ne modifie rien, car le `daemon-reload` et le `restart` n'ont lieu que si un fichier a changé.

### Vérification

```bash
pyinfra hosts.py deploy.py                      # 2e lancement : "No Change" partout
curl http://<ip-serveur>:8080/health            # {"status": "ok"}
ssh root@<ip-serveur> journalctl -u metrics-collector
```

---

## Partie 2 - ClickHouse sur Kubernetes

### Prérequis

- **WSL** installé
- **Docker Desktop**, utilisé comme container runtime 
- **Minikube** et **kubectl**
- Python 3 et `requests` 
- Le port `30123` libre sur la machine

### Lancement

```bash
cd part2_k8s_clickhouse
./deploy.sh
```

Le script doit être lancé depuis le dossier `part2_k8s_clickhouse`. Si besoin : `chmod +x deploy.sh`.

Le script :

1. démarre Minikube et publie le port `30123`
2. applique le ConfigMap, le StatefulSet et le Service
3. attend que ClickHouse réponde
4. crée la database `metrics` et la table `metrics.job_metrics`
5. lance `send_metrics.py` (10 lignes aléatoires)
6. affiche le nombre de lignes et les 10 dernières lignes

Il peut être relancé plusieurs fois : la table est créée avec `IF NOT EXISTS`, et chaque lancement ajoute 10 lignes.

### Étapes manuelles (sans le script)

```bash
minikube start --driver=docker --ports=30123:30123
kubectl apply -f configmap.yaml -f clickhouse-deployment.yaml -f clickhouse-service.yaml
kubectl rollout status statefulset/clickhouse

kubectl exec clickhouse-0 -- clickhouse-client --user root --password root \
  --query "CREATE DATABASE IF NOT EXISTS metrics"

kubectl exec clickhouse-0 -- clickhouse-client --user root --password root \
  --query "CREATE TABLE IF NOT EXISTS metrics.job_metrics (job_id String, timestamp DateTime, duration_sec UInt32, success Bool) ENGINE = MergeTree ORDER BY (job_id, timestamp)"

python3 send_metrics.py
```

### Vérification

```bash
curl http://127.0.0.1:30123/ping
kubectl exec clickhouse-0 -- clickhouse-client --user root --password root \
  --query "SELECT count() FROM metrics.job_metrics"

# Persistance : supprimer le pod, attendre qu'il revienne, recompter (les données doivent toujours être là)
kubectl delete pod clickhouse-0
kubectl rollout status statefulset/clickhouse
kubectl exec clickhouse-0 -- clickhouse-client --user root --password root \
  --query "SELECT count() FROM metrics.job_metrics"
```

### Choix techniques

- **StatefulSet** : ClickHouse est une base de données. Un StatefulSet donne une identité stable au pod (`clickhouse-0`, le nom reste le même après un redémarrage) et un stockage qui lui reste attaché, ce qui convient mieux à ce type de workload qu'un Deployment.
- **`volumeClaimTemplates`** dans le StatefulSet : le PVC est créé automatiquement pour le pod, pour le stockage et la **persistance** des données. Les données survivent à la suppression du pod.
- **Service** : le StatefulSet est exposé via un Service.
- **NodePort (30123)** : la base doit être accessible depuis l'extérieur du cluster, alors que `ClusterIP` n'est accessible que depuis l'intérieur du cluster.
- **ConfigMap** : définit `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` et `CLICKHOUSE_DB` pour l'image officielle.
- **`send_metrics.py`** : envoie les lignes en HTTP au format `TabSeparated`.
- **`deploy.sh`** : automatise tout le déploiement de la partie 2.

### Notes

- Sous WSL2 avec Docker Desktop, l'IP de Minikube n'est pas joignable depuis la machine hôte. C'est pourquoi le port `30123` est publié avec `--ports`, et les scripts utilisent `127.0.0.1:30123`. Sous Linux natif, on peut aussi utiliser `http://$(minikube ip):30123`.
- `--ports` n'est appliqué qu'à la création du conteneur Minikube. Si un cluster existe déjà sans cette option, lancer `minikube delete` d'abord.
- Le user et la database ne sont créés qu'au premier démarrage sur un volume vide. Si tu les modifies dans le ConfigMap, supprime le volume (`kubectl delete pvc data-clickhouse-0`) et redéploie.

### Nettoyage

```bash
minikube delete
```

---

## Perspectives d'amélioration

**Partie 1**

- Utiliser un **utilisateur dédié avec le principe de least privilege** plutôt que `root` pour se connecter en SSH, avec `sudo` limité à ce qui est nécessaire, et désactiver la connexion SSH de `root`.
- Durcir l'unit systemd : exécuter le service avec un utilisateur non privilégié (`User=`) et interdire l'élévation de privilèges avec `NoNewPrivileges=true`.

**Partie 2**

- Mettre le mot de passe de la database dans un **Secret** Kubernetes au lieu du ConfigMap et des scripts.
- Activer l'**encryption at rest** pour les Secrets : un Secret est seulement encodé en base64, donc il est facile à décoder.
- Augmenter le nombre de **replicas** pour la haute disponibilité.
- Utiliser **HTTPS** (TLS) pour s'authentifier auprès de la database.
- Ajouter des `Probes Kubernetes` pour surveiller l’état de ClickHouse, ainsi que des `resources` (requests/limits) au StatefulSet.
