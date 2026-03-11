#!/usr/bin/env bash
# wait-for-es.sh — aguarda o Elasticsearch responder com status yellow ou green
# Usa port-forward para acessar o Service a partir do host, sem depender de
# curl/wget dentro do container (imagem do ES pode não tê-los).
set -uo pipefail

NAMESPACE="${1:-logging}"
MAX_ATTEMPTS=30
SLEEP_SECONDS=10
LOCAL_PORT=19200
RELEASE_NAME="${2:-elasticsearch}"
SECRET_NAME="${RELEASE_NAME}-master-credentials"
PF_PID=""
ES_USERNAME="elastic"
ES_PASSWORD=""

cleanup() {
  if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  SECRET_USER=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
  SECRET_PASS=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

  if [ -n "$SECRET_USER" ]; then
    ES_USERNAME="$SECRET_USER"
  fi

  if [ -n "$SECRET_PASS" ]; then
    ES_PASSWORD="$SECRET_PASS"
    echo ">>> Credenciais detectadas no secret ${SECRET_NAME}; health check com autenticação habilitado."
  fi
fi

echo ">>> Aguardando Elasticsearch ficar Ready (statefulset)..."
kubectl rollout status statefulset/${RELEASE_NAME}-master \
  --namespace "$NAMESPACE" \
  --timeout=300s

echo ">>> Abrindo port-forward svc/${RELEASE_NAME}-master -> localhost:${LOCAL_PORT}..."
kubectl port-forward \
  --namespace "$NAMESPACE" \
  svc/${RELEASE_NAME}-master \
  ${LOCAL_PORT}:9200 &>/dev/null &
PF_PID=$!

# Dá tempo ao port-forward estabelecer a conexão
sleep 3

echo ">>> Verificando health do cluster Elasticsearch..."
for i in $(seq 1 $MAX_ATTEMPTS); do
  BODY=""
  HTTP_CODE="000"

  if [ -n "$ES_PASSWORD" ]; then
    BODY=$(curl -ksS --max-time 5 -u "${ES_USERNAME}:${ES_PASSWORD}" -w '\n%{http_code}' "https://localhost:${LOCAL_PORT}/_cluster/health" 2>/dev/null \
      || curl -sS --max-time 5 -u "${ES_USERNAME}:${ES_PASSWORD}" -w '\n%{http_code}' "http://localhost:${LOCAL_PORT}/_cluster/health" 2>/dev/null)
  else
    BODY=$(curl -ksS --max-time 5 -w '\n%{http_code}' "https://localhost:${LOCAL_PORT}/_cluster/health" 2>/dev/null \
      || curl -sS --max-time 5 -w '\n%{http_code}' "http://localhost:${LOCAL_PORT}/_cluster/health" 2>/dev/null)
  fi

  HTTP_CODE=$(printf '%s' "$BODY" | tail -n1)
  RESPONSE=$(printf '%s' "$BODY" | sed '$d')

  if [ "$HTTP_CODE" = "200" ]; then
    STATUS=$(printf '%s' "$RESPONSE" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null \
      || echo "unavailable")
  elif [ "$HTTP_CODE" = "401" ]; then
    STATUS="unauthorized"
  else
    STATUS="unavailable"
  fi

  echo "  tentativa $i/$MAX_ATTEMPTS — status: $STATUS"

  if [ "$STATUS" = "green" ] || [ "$STATUS" = "yellow" ]; then
    echo ">>> Elasticsearch pronto! (status=$STATUS)"
    exit 0
  fi

  if [ "$STATUS" = "unauthorized" ]; then
    echo ">>> Elasticsearch respondeu 401 (segurança ativa), seguindo para instalação do Kibana."
    exit 0
  fi

  sleep $SLEEP_SECONDS
done

echo ">>> WARN: Elasticsearch nao respondeu apos $MAX_ATTEMPTS tentativas, prosseguindo mesmo assim..."
exit 0
