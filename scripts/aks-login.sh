#!/usr/bin/env bash
# Genere un acces kubectl non interactif (kubelogin en mode azurecli) hors de tout worktree.
# Usage : bash scripts/aks-login.sh puis export KUBECONFIG=$HOME/lab/tp-de-steve-le-art-ce-l-heure/.kube/config
set -euo pipefail

RG="${RG:-msaidiRG}"
CLUSTER="${CLUSTER:-tp-steve-aks-02}"
export KUBECONFIG="${KUBECONFIG_PATH:-$HOME/lab/tp-de-steve-le-art-ce-l-heure/.kube/config}"

mkdir -p "$(dirname "$KUBECONFIG")"

az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing --file "$KUBECONFIG"
kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG"

# La propagation d'une affectation de role Azure prend parfois quelques minutes
deadline=$((SECONDS + 300))
until kubectl get nodes; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "kubectl get nodes toujours en echec apres 5 minutes" >&2
    exit 1
  fi
  sleep 15
done
