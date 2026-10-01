# TP observabilité et cert-manager sur AKS

L'équipe s'appelle les super termites. Ce TP déploie une pile d'observabilité complète sur un cluster AKS en région francecentral. Elle comprend Prometheus, Alertmanager, Grafana et des exporters, le tout protégé par une chaîne de certificats gérée par cert-manager. Grafana est publié en HTTPS derrière un reverse proxy nginx sur https://steveleharceleur.francecentral.cloudapp.azure.com

## État exact

Les phases 0 à 10 sont faites et vérifiées. Les phases 11 à 13 sont écrites et versionnées, mais pas encore appliquées sur le cluster, car celui-ci n'a plus de nœuds depuis son redémarrage (voir les écarts). Les phases 14 et 15 se terminent après cette application.

## Architecture

Terraform crée le cluster AKS, deux groupes Entra ID (administrateurs et lecteurs), l'adresse IP publique et les rôles associés. Tout est créé dans le resource group partagé msaidiRG, avec le préfixe tp-steve.

Dans le cluster, deux namespaces portent la solution.

- cert-manager contient le contrôleur et la chaîne PKI. Un ClusterIssuer auto-signé produit la racine root-ca, qui signe l'intermédiaire intermediate-ca, qui à son tour signe les certificats applicatifs comme grafana-tls.
- monitoring contient l'opérateur Prometheus, l'instance Prometheus, Alertmanager, node-exporter, kube-state-metrics, l'opérateur Grafana avec son instance, et nginx.

nginx est exposé par un Service de type LoadBalancer qui reprend l'IP publique créée par Terraform. Il termine le TLS avec le certificat grafana-tls et relaie vers Grafana. Il n'y a ni Ingress ni Gateway.

Les volumes utilisent la StorageClass monitoring-premium-retain (Premium_ZRS, reclaimPolicy Retain). Prometheus a 20Gi, Alertmanager 5Gi et Grafana 10Gi.

## Prérequis et outils

- Azure CLI connecté à la souscription, avec les droits sur msaidiRG
- Terraform
- kubectl et kubelogin
- Helm
- jq (utilisé par le script Vault)
- Un quota suffisant de la famille DSv3 (6 vCPU pour les trois nœuds)

## Ordre de déploiement

Terraform d'abord, puis le script de kubeconfig, puis les manifestes dans l'ordre des préfixes numériques. Les manifestes sont appliqués depuis la branche main.

```
terraform -chdir=terraform init
terraform -chdir=terraform plan -out=tfplan
terraform -chdir=terraform apply tfplan
bash scripts/aks-login.sh
export KUBECONFIG=$HOME/lab/tp-de-steve-le-art-ce-l-heure/.kube/config
kubectl apply -f manifests/00-namespaces -f manifests/05-storage
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --version 1.21.2 --set crds.enabled=true
kubectl apply -f manifests/10-cert-manager/pki.yaml
kubectl apply --server-side -k manifests/20-prometheus-operator
helm upgrade cert-manager jetstack/cert-manager -n cert-manager --version 1.21.2 --reuse-values --set prometheus.servicemonitor.enabled=true
kubectl apply -f manifests/30-prometheus -f manifests/40-alertmanager
kubectl apply -f manifests/50-exporters/node-exporter.yaml -f manifests/50-exporters/kube-state-metrics-servicemonitor.yaml
kubectl apply -k manifests/50-exporters/kube-state-metrics
helm upgrade --install grafana-operator oci://ghcr.io/grafana/helm-charts/grafana-operator --version 5.25.0 -n monitoring
kubectl apply -f manifests/60-grafana
kubectl apply -f manifests/70-nginx
kubectl apply -f manifests/80-alerting-rules
kubectl apply -f manifests/90-backup
```

La phase 13 s'applique en dernier, une fois les phases 11 et 12 validées.

```
kubectl apply -f manifests/95-vault/namespace.yaml
helm repo add hashicorp https://helm.releases.hashicorp.com
helm upgrade --install vault hashicorp/vault -n vault -f manifests/95-vault/values.yaml
kubectl -n vault wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=300s
bash scripts/vault-setup.sh
kubectl apply -f manifests/95-vault/rbac.yaml -f manifests/95-vault/clusterissuer.yaml -f manifests/95-vault/certificate-demo.yaml
```

Les clés d'initialisation de Vault sont écrites par le script dans secrets/vault-init.json. Ce chemin est couvert par le .gitignore et ne doit jamais être committé.

## Vérifications par phase

```
kubectl get nodes
kubectl get ns
kubectl get storageclass monitoring-premium-retain
kubectl get certificate -A
kubectl -n monitoring get pods
kubectl -n monitoring get prometheusrule
kubectl get volumesnapshotclass tp-steve-disk-retain
kubectl -n monitoring get volumesnapshot
kubectl get clusterissuer vault-issuer
kubectl -n monitoring get certificate vault-demo
curl -sI --cacert root-ca.pem https://steveleharceleur.francecentral.cloudapp.azure.com
```

Les cinq jobs Prometheus (node-exporter, kube-state-metrics, cert-manager, cainjector, webhook) doivent être en état up dans l'interface Prometheus. Les règles d'alerte de la phase 11 apparaissent dans l'onglet Rules. La data source Alertmanager de Grafana affiche les alertes actives.

Deux déclenchements sont à provoquer puis à supprimer pour valider les alertes. Le premier est un pod jetable en CrashLoopBackOff. Le second est un Certificate jetable nommé demo-expiry, émis par intermediate-issuer avec une durée de 1h et un renewBefore de 5m. Sans lui, l'alerte d'expiration ne se déclenche jamais, car grafana-tls est valide 90 jours.

## Accès à Grafana

L'identifiant et le mot de passe administrateur sont dans le Secret grafana-admin-credentials.

```
kubectl -n monitoring get secret grafana-admin-credentials -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' | base64 -d
kubectl -n monitoring get secret grafana-admin-credentials -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d
```

Le navigateur affiche un avertissement de certificat. C'est normal, car la chaîne est auto-signée et sa racine n'est pas dans le magasin de confiance du poste. Pour vérifier la chaîne en ligne de commande, on extrait la racine puis on la passe à curl.

```
kubectl -n cert-manager get secret root-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > root-ca.pem
curl --cacert root-ca.pem https://steveleharceleur.francecentral.cloudapp.azure.com
```

## Restauration d'un snapshot

La phase 12 crée une VolumeSnapshotClass nommée tp-steve-disk-retain, avec la politique Retain, et un VolumeSnapshot par volume de la pile (prometheus-main-snap, alertmanager-main-snap et grafana-snap). AKS fournit déjà la classe csi-azuredisk-vsc, la nôtre est explicite et versionnée.

Restaurer consiste à créer un nouveau PVC dont le champ dataSource pointe le VolumeSnapshot, puis à rattacher la charge à ce PVC. Exemple pour Grafana.

```
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc-restore
  namespace: monitoring
spec:
  storageClassName: monitoring-premium-retain
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
  dataSource:
    apiGroup: snapshot.storage.k8s.io
    kind: VolumeSnapshot
    name: grafana-snap
```

1. Appliquer ce PVC et vérifier qu'il passe en Bound au premier démarrage d'un pod qui le monte, car la StorageClass attend le consommateur.
2. Dans manifests/60-grafana/grafana.yaml, remplacer claimName grafana-pvc par grafana-pvc-restore dans le volume grafana-data.
3. Appliquer le manifeste, puis vérifier que Grafana retrouve ses données.

Pour Prometheus et Alertmanager, le PVC est créé par un volumeClaimTemplate. On restaure en supprimant le StatefulSet concerné après avoir recréé un PVC du même nom que celui attendu, avec le champ dataSource ci-dessus.

## Points bonus et écarts au brief

Points bonus traités. Une chaîne PKI à trois niveaux, des dashboards Nodes et Certificates provisionnés par ConfigMap, des règles d'alerte sur les pods et les certificats, des snapshots de volumes, et une PKI Vault en parallèle de la chaîne auto-signée qui reste celle de nginx.

- **Taille des nœuds**. Une policy Azure de la souscription n'autorise qu'une courte liste de tailles. Standard_D2s_v6 a donc été refusée. Standard_D2s_v3 est la seule taille autorisée qui ait du quota (famille DSv3, limite 10 vCPU, 4 utilisés par d'autres au départ). Trois nœuds de 2 vCPU consomment les 6 restants.
- **Zones**. Les zones 1 et 2 seulement. La zone 3 est restreinte pour cette souscription sur toutes les tailles testées. Le pool est donc réparti sur deux zones.
- **Stockage**. Premium_ZRS provisionne bien sur deux zones. Les trois volumes de la pile sont liés.
- **Resource group**. Le resource group msaidiRG est partagé et préexistant. Terraform le lit par une data source et n'y crée que les ressources du projet. Le node resource group est fixé à MC-tp-steve-aks-02.
- **Nom du cluster**. Le premier essai tp-steve-aks a échoué sur la policy de taille de VM et est resté en état Failed. Il a été supprimé ensuite, avec son node resource group. Le cluster actif s'appelle tp-steve-aks-02.
- **Prometheus**. Le CR porte un securityContext (fsGroup 2000), sinon le pod ne peut pas écrire sur le disque et boucle en CrashLoopBackOff.
- **Grafana**. Le champ persistentVolumeClaim crée bien le PVC mais ne le monte pas, le volume restait un emptyDir. Le montage sur /var/lib/grafana est donc déclaré explicitement. Une modification faite dans l'interface a survécu à la suppression du pod.
- **Dashboards**. Ils sont posés par ConfigMap et référencent la datasource Prometheus par son uid fixé à Prometheus.
- **Redémarrage du cluster**. Après un az aks stop, le redémarrage de tp-steve-aks-02 échoue car le quota DSv3 a été consommé entre-temps par d'autres ressources de la souscription. Le pool reste à zéro nœud tant que 6 vCPU ne sont pas libérés. Aucune ressource tierce n'a été touchée.
- **Délégation**. Les manifestes des phases 11 à 13 ont été écrits directement, car l'outil de délégation refuse de travailler quand le dépôt suivi contient un fichier terraform.tfvars.example.
