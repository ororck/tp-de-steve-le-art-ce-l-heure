#!/usr/bin/env bash
set -euo pipefail

NS=vault
POD=vault-0
KEYS_FILE="secrets/vault-init.json"
DOMAIN="steveleharceleur.francecentral.cloudapp.azure.com"

v() {
  kubectl -n "$NS" exec -i "$POD" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN:-}" vault "$@"
}

status_field() {
  v status -format=json 2>/dev/null | jq -r ".$1" || true
}

init_vault() {
  if [ "$(status_field initialized)" != "true" ]; then
    mkdir -p "$(dirname "$KEYS_FILE")"
    chmod 700 "$(dirname "$KEYS_FILE")"
    (umask 077; v operator init -key-shares=5 -key-threshold=3 -format=json > "$KEYS_FILE")
    chmod 600 "$KEYS_FILE"
  fi
}

unseal_vault() {
  if [ "$(status_field sealed)" = "true" ]; then
    for i in 0 1 2; do
      v operator unseal "$(jq -r ".unseal_keys_b64[$i]" "$KEYS_FILE")" > /dev/null
    done
  fi
}

load_root() {
  VAULT_TOKEN="$(jq -r .root_token "$KEYS_FILE")"
  export VAULT_TOKEN
}

setup_pki() {
  if ! v secrets list -format=json | jq -e '."pki/"' > /dev/null; then
    v secrets enable pki > /dev/null
  fi
  v secrets tune -max-lease-ttl=87600h pki > /dev/null
  if ! v read pki/cert/ca > /dev/null 2>&1; then
    v write pki/root/generate/internal common_name="tp-steve root ca" ttl=87600h > /dev/null
  fi
  v write pki/config/urls issuing_certificates="http://vault.vault.svc:8200/v1/pki/ca" > /dev/null
  v write pki/roles/tp-steve allowed_domains="$DOMAIN" allow_subdomains=true allow_bare_domains=true max_ttl=720h > /dev/null
}

setup_policy() {
  printf 'path "pki/sign/tp-steve" {\n capabilities = ["create","update"]\n}\n' | v policy write pki-sign - > /dev/null
}

setup_kubernetes_auth() {
  if ! v auth list -format=json | jq -e '."kubernetes/"' > /dev/null; then
    v auth enable kubernetes > /dev/null
  fi
  v write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443" > /dev/null
  v write auth/kubernetes/role/cert-manager bound_service_account_names=vault-issuer bound_service_account_namespaces=cert-manager policies=pki-sign ttl=10m > /dev/null
}

init_vault
unseal_vault
load_root
setup_pki
setup_policy
setup_kubernetes_auth
echo "Configuration Vault terminée, les clés sont dans $KEYS_FILE"
