#!/usr/bin/env bash
# =============================================================================
# install-kibana.sh
# Instalação idempotente do Kibana via Helm no namespace "logging".
#
# Problema resolvido: o chart do Kibana cria hooks pre-install e post-delete
# que deixam Jobs, ConfigMaps, ServiceAccounts, Roles e RoleBindings órfãos
# quando uma release anterior falhou ou ficou em estado inconsistente
# (pending-upgrade, pending-install, failed, etc.).
# O `helm uninstall` em si também pode falhar se o Job do hook post-delete
# já existir de uma tentativa anterior — gerando o erro:
#   "jobs.batch post-delete-kibana-kibana already exists"
#
# Estratégia:
#   1. Limpar TODOS os recursos órfãos conhecidos ANTES de qualquer operação Helm
#   2. Só então verificar/remover a release Helm (se existir e não estiver "deployed")
#   3. Tentar `helm upgrade --install` com hooks normais
#   4. Se falhar, limpar novamente e tentar com --no-hooks como fallback
# =============================================================================
set -euo pipefail

NAMESPACE="logging"
RELEASE="kibana"

# ── Cores para output legível ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}>>>  $*${NC}"; }
warning() { echo -e "${YELLOW}WARN $*${NC}"; }
error()   { echo -e "${RED}ERR  $*${NC}" >&2; }

# ── Limpeza de todos os recursos órfãos de hooks do Kibana ───────────────────
# Esta função deve ser chamada ANTES de qualquer operação Helm para garantir
# um estado limpo — evita o erro "already exists" nos hooks.
purge_hook_resources() {
  info "Limpando recursos órfãos de hooks do Kibana em '${NAMESPACE}'..."

  local resources=(
    "job/post-delete-${RELEASE}-kibana"
    "job/pre-install-${RELEASE}-kibana"
    "configmap/${RELEASE}-kibana-helm-scripts"
    "serviceaccount/pre-install-${RELEASE}-kibana"
    "role/pre-install-${RELEASE}-kibana"
    "rolebinding/pre-install-${RELEASE}-kibana"
  )

  for resource in "${resources[@]}"; do
    if kubectl get "${resource}" -n "${NAMESPACE}" &>/dev/null; then
      info "  Deletando ${resource}..."
      kubectl delete "${resource}" -n "${NAMESPACE}" --ignore-not-found --wait=false
    fi
  done

  # Aguarda Jobs terminarem para não bloquear o próximo helm install
  kubectl wait --for=delete \
    "job/post-delete-${RELEASE}-kibana" \
    "job/pre-install-${RELEASE}-kibana" \
    -n "${NAMESPACE}" --timeout=30s 2>/dev/null || true
}

# ── Resolve credenciais do Elasticsearch ─────────────────────────────────────
resolve_es_credentials() {
  ES_USER=$(
    kubectl get secret elasticsearch-master-credentials \
      -n "${NAMESPACE}" \
      -o jsonpath='{.data.username}' 2>/dev/null \
    | base64 -d 2>/dev/null \
    || echo "elastic"
  )

  ES_PASS=$(
    kubectl get secret elasticsearch-master-credentials \
      -n "${NAMESPACE}" \
      -o jsonpath='{.data.password}' 2>/dev/null \
    | base64 -d 2>/dev/null \
    || echo ""
  )

  export ES_USER ES_PASS
  info "Credenciais ES resolvidas (user=${ES_USER}, pass=${ES_PASS:+***}${ES_PASS:-<sem senha>})"
}

# ── Executa helm upgrade --install com os args fornecidos ────────────────────
run_helm_install() {
  local extra_args=("$@")

  local base_args=(
    upgrade --install "${RELEASE}" elastic/kibana
    --namespace "${NAMESPACE}"
    --set "elasticsearchHosts=https://elasticsearch-master:9200"
    --set "extraEnvs[0].name=ELASTICSEARCH_SSL_VERIFICATIONMODE"
    --set "extraEnvs[0].value=none"
    --timeout 15m
    --wait
    --cleanup-on-fail
  )

  if [ -n "${ES_PASS}" ]; then
    base_args+=(
      --set "elasticsearchUsername=${ES_USER}"
      --set "elasticsearchPassword=${ES_PASS}"
    )
  fi

  helm "${base_args[@]}" ${extra_args[@]+"${extra_args[@]}"}
}

# ── Remove a release Helm se estiver em estado inconsistente ─────────────────
cleanup_failed_release() {
  if ! helm status "${RELEASE}" -n "${NAMESPACE}" &>/dev/null; then
    info "Nenhuma release '${RELEASE}' encontrada. Prosseguindo com install limpo."
    return
  fi

  local status
  status=$(
    helm status "${RELEASE}" -n "${NAMESPACE}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' \
    2>/dev/null || echo "unknown"
  )

  info "Release '${RELEASE}' encontrada com status: ${status}"

  if [ "${status}" = "deployed" ]; then
    info "Release já está 'deployed'. Prosseguindo com upgrade."
    return
  fi

  warning "Status '${status}' é inconsistente. Removendo release antes de reinstalar..."
  # Purga hooks ANTES do uninstall para evitar o erro "already exists" no post-delete hook
  purge_hook_resources
  helm uninstall "${RELEASE}" -n "${NAMESPACE}" --no-hooks 2>/dev/null || true
  info "Release removida."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  info "=== Iniciando instalação do Kibana ==="

  resolve_es_credentials
  purge_hook_resources      # Limpeza preventiva antes de qualquer operação Helm
  cleanup_failed_release    # Remove release inconsistente se existir

  info "Tentativa 1: helm upgrade --install com hooks normais..."
  if run_helm_install; then
    info "=== Kibana instalado com sucesso ==="
    exit 0
  fi

  warning "Tentativa 1 falhou. Limpando hooks órfãos e tentando novamente sem hooks..."
  purge_hook_resources

  info "Tentativa 2: helm upgrade --install com --no-hooks..."
  if run_helm_install --no-hooks; then
    info "=== Kibana instalado com sucesso (sem hooks) ==="
    exit 0
  fi

  error "=== Falha definitiva na instalação do Kibana. Verifique os logs acima. ==="
  exit 1
}

main "$@"
