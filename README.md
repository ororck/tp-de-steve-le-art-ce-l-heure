# TP observabilité et cert-manager sur AKS

Équipe les super termites. Région francecentral. Grafana est publié en HTTPS sur https://steveleharceleur.francecentral.cloudapp.azure.com

## État exact

Phases faites, de 0 à 10 incluse.

0. Prérequis et dépôt
1. Terraform AKS, groupes Entra ID, IP publique, rôles
2. Accès kubectl non interactif
3. Namespaces et StorageClass
4. cert-manager et chaîne PKI
5. Opérateur Prometheus
6. Instance Prometheus
7. Alertmanager
8. Exporters (node-exporter, kube-state-metrics)
9. Grafana
10. Reverse proxy nginx derrière un Service LoadBalancer

Phases restantes, non lancées.

1. Phase 11 règles d'alerte
2. Phase 12 sauvegarde des volumes
3. Phase 13 PKI HashiCorp Vault
4. Phase 14 version finale de ce README, avec la procédure de restauration
5. Phase 15 contrôle final avant livraison

## Écarts au brief

- **Taille des nœuds**. Une policy Azure de la souscription n'autorise qu'une courte liste de tailles. Standard_D2s_v6 a donc été refusée. Standard_D2s_v3 est la seule taille autorisée qui ait du quota (famille DSv3, limite 10 vCPU, 4 utilisés par d'autres au départ). Trois nœuds de 2 vCPU consomment les 6 restants.
- **Zones**. Les zones 1 et 2 seulement. La zone 3 est restreinte pour cette souscription sur toutes les tailles testées. Le pool est donc réparti sur deux zones.
- **Stockage**. Premium_ZRS provisionne bien sur deux zones. Les quatre disques sont liés (Prometheus 20Gi, Alertmanager 5Gi, Grafana 10Gi).
- **Resource group**. Le resource group msaidiRG est partagé et préexistant. Terraform le lit par une data source et n'y crée que les ressources du projet. Le node resource group est fixé à MC-tp-steve-aks-02.
- **Nom du cluster**. Le premier essai tp-steve-aks a échoué sur la policy de taille de VM et est resté en état Failed. Il a été supprimé ensuite, avec son node resource group. Le cluster actif s'appelle tp-steve-aks-02.
- **Prometheus**. Le CR porte un securityContext (fsGroup 2000), sinon le pod ne peut pas écrire sur le disque et boucle en CrashLoopBackOff.
- **Grafana**. Le champ persistentVolumeClaim crée bien le PVC mais ne le monte pas, le volume restait un emptyDir. Le montage sur /var/lib/grafana est donc déclaré explicitement. Une modification faite dans l'interface a survécu à la suppression du pod.
- **Dashboards**. Ils sont posés par ConfigMap et référencent la datasource Prometheus par son uid fixé à Prometheus.

## Déploiement

Les manifestes sont appliqués depuis la branche main.

```
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
```

## Identifiants admin Grafana

```
kubectl -n monitoring get secret grafana-admin-credentials -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' | base64 -d
kubectl -n monitoring get secret grafana-admin-credentials -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d
```

## Vérifications faites

- Les cinq jobs Prometheus (node-exporter, kube-state-metrics, cert-manager, cainjector, webhook) sont en état up.
- Les certificats root-ca, intermediate-ca et grafana-tls sont Ready.
- Le Service nginx a été supprimé puis réappliqué et l'IP publique 40.89.175.103 et le FQDN sont restés identiques.
- Les dashboards Nodes et Certificates remontent des données.
