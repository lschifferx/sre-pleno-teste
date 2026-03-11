# SRE Pleno Teste

> Ecossistema completo de **Reliability Engineering** em Go + Kubernetes + ELK + Grafana

---

## 🏗 Arquitetura

```
┌─────────────────────────────────────────────────────────────────┐
│                        minikube cluster                         │
│                                                                 │
│  namespace: sre-demo          namespace: monitoring             │
│  ┌─────────────────┐          ┌────────────────────────────┐   │
│  │  sre-demo-app   │◄──scrape─│  Prometheus + Grafana      │   │
│  │  (2 réplicas)   │          │  kube-prometheus-stack     │   │
│  │  /metrics       │          └────────────────────────────┘   │
│  └────────┬────────┘                                            │
│           │stdout logs        namespace: logging                │
│  ┌────────▼────────┐          ┌────────────────────────────┐   │
│  │    Filebeat     │─beats───►│ Logstash → Elasticsearch   │   │
│  │   (DaemonSet)   │          │           → Kibana         │   │
│  └─────────────────┘          └────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## 📦 Estrutura

```
sre-pleno-teste/
├── Dockerfile                  # Multi-stage, distroless, non-root
├── Taskfile.yaml               # Automação completa (setup → deploy → validate)
├── app/
│   ├── go.mod
│   ├── cmd/server/main.go      # Entry point, graceful shutdown
│   └── internal/
│       ├── handlers/           # HTTP handlers (health, metrics, simulators)
│       ├── metrics/            # Prometheus counters/histograms/gauges
│       └── middleware/         # Logging + Recovery (structured logs)
├── k8s/
│   ├── deployment.yaml         # 2 réplicas, probes, ConfigMap, securityContext, topologySpread
│   ├── service.yaml            # ClusterIP + Namespace
│   ├── hpa.yaml                # HPA v2: CPU >70% / Memory >75%
│   └── pdb.yaml                # PodDisruptionBudget: minAvailable=1
├── monitoring/
│   └── grafana-dashboard.json  # Golden Signals dashboard
├── ci/
│   └── pipeline.yaml           # GitHub Actions: lint → test → build → deploy
└── elk/
    ├── filebeat.yaml           # DaemonSet coleta logs dos containers
    ├── logstash.conf           # Grok parse + enrich + output ES
    └── kibana-dashboard.json   # Pie/Table/Line/Histogram + Alert rule
```

---

## 🚀 Quick Start

### Pré-requisitos

| Ferramenta | Versão mínima |
|-----------|--------------|
| Docker    | 24+          |
| minikube  | 1.32+        |
| kubectl   | 1.29+        |
| Helm      | 3.14+        |
| Task      | 3.35+        |
| Go        | 1.22+        |

### Instalando Task
```bash
# macOS
brew install go-task

# Linux
sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b ~/.local/bin
```

### Deploy completo (one-shot)
```bash
task all
```

Ou passo a passo:

```bash
# 1. Iniciar minikube + helm repos + namespaces
task setup

# 2. Build da imagem dentro do daemon do minikube
task build

# 3. Deploy da aplicação
task deploy

# 4. Instalar Prometheus + Grafana
task install-prometheus

# 5. Instalar ELK + Filebeat
task install-elk
```

---

## 📊 Acessando as UIs

```bash
# Aplicação (http://localhost:8080)
task port-forward-app

# Grafana (http://localhost:3000) — admin/prom-operator
task port-forward-grafana

# Kibana (http://localhost:5601)
task port-forward-kibana

# Prometheus (http://localhost:9090)
task port-forward-prometheus
```

---

## 🔍 Endpoints da Aplicação

| Endpoint                        | Descrição                              |
|-------------------------------|----------------------------------------|
| `GET /health`                  | Liveness probe                         |
| `GET /ready`                   | Readiness probe                        |
| `GET /metrics`                 | Prometheus scrape endpoint             |
| `GET /api/v1/ping`             | Ping/pong                              |
| `GET /api/v1/status`           | Info: env, goroutines, memória         |
| `GET /api/v1/simulate/error`   | Força HTTP 500 (teste de alertas)      |
| `GET /api/v1/simulate/latency` | Latência aleatória 0–2s (teste histograma) |

---

## 📈 Métricas Prometheus

| Métrica                              | Tipo      | Descrição                     |
|-------------------------------------|-----------|-------------------------------|
| `http_requests_total`               | Counter   | Total de requisições          |
| `http_request_duration_seconds`     | Histogram | Latência por endpoint         |
| `http_error_rate`                   | Gauge     | Taxa de erros por endpoint    |
| `app_memory_alloc_bytes`            | Gauge     | Heap alocado em bytes         |
| `app_cpu_goroutines`                | Gauge     | Número de goroutines          |

---

## 🐳 Dockerfile — Decisões Técnicas

| Decisão | Justificativa |
|---------|--------------|
| `golang:1.22-alpine` como builder | Imagem oficial leve; Alpine reduz ataque superficial |
| `gcr.io/distroless/static-debian12:nonroot` como runtime | Zero shell, zero pacotes desnecessários; UID 65532 |
| Multi-stage build | Binário final ~8MB; sem toolchain no runtime |
| `CGO_ENABLED=0 -ldflags="-w -s"` | Binário estático, stripped de debug symbols |
| `readOnlyRootFilesystem: true` | Impede escrita em disco em runtime |
| `capabilities.drop: ALL` | Princípio do menor privilégio |

---

## ☸️ Kubernetes — Decisões Técnicas

- **2 réplicas** com `maxUnavailable: 0` — zero-downtime rolling updates
- **3 probes**: startup (warm-up), liveness (restart), readiness (LB)
- **Resources requests/limits** — garante QoS Burstable e evita OOMKill
- **HPA v2** escala de 2→6 pods (CPU>70% ou Mem>75%), com janela de estabilização para evitar flapping
- **PodDisruptionBudget** (`minAvailable: 1`) — garante disponibilidade mínima durante node drain e upgrades
- **topologySpreadConstraints** — distribui pods em nós diferentes, evitando SPOF em um único nó
- **seccompProfile: RuntimeDefault** — syscall filtering por padrão
- **Annotations Prometheus** presentes apenas no `spec.template.metadata` (pod), não no Deployment — o Prometheus faz scrape nos pods, não no recurso Deployment

---

## 📋 ELK — Fluxo de Logs

```
App (stdout) → Filebeat (DaemonSet) → Logstash:5044
  → Grok parse → Enrich k8s metadata → Elasticsearch
  → Index: app-logs-{namespace}-{YYYY.MM.dd}
  → Kibana Dashboard + Alert (≥20 erros/5min, throttle 15min)
```

Campos extraídos pelo Logstash:
- `log_level` — INFO / WARN / ERROR (diferenciado por status HTTP: 2xx=INFO, 4xx=WARN, 5xx=ERROR)
- `endpoint` — path acessado
- `http_status` — código HTTP
- `latency_ms` — latência em milissegundos
- `@timestamp` — ISO8601 normalizado
- `environment`, `pod_name`, `app` — enriquecidos via metadata K8s (com fallback `"unknown"` se ausentes)

### Alert Kibana
- **Trigger**: ≥ 20 erros nos últimos 5 minutos (exclui `/health`, `/ready`, `/metrics`)
- **Throttle**: 15 minutos (evita spam)
- **Action**: escreve no índice `sre-alerts` com contexto completo

---

## 🔄 CI/CD Pipeline

```
push/PR
  └─► lint (hadolint + go vet + staticcheck)
        └─► test (go test -race + coverage)
              └─► build & push (docker buildx + cache)
                    └─► deploy (kubectl apply + rollout wait)  ← main only
```

**Secrets necessários no GitHub:**
- `DOCKER_USERNAME` / `DOCKER_PASSWORD`
- `KUBECONFIG` (base64 do kubeconfig do cluster)

---

## 🧪 Gerando carga para testes

```bash
# Valida todos os endpoints
task validate

# Envia 600 requisições (ping + error + latency)
task stress
```

---

## 🎯 Importando Dashboards

### Grafana
1. Acesse `http://localhost:3000`
2. **Dashboards → Import → Upload JSON file**
3. Selecione `monitoring/grafana-dashboard.json`
4. Selecione datasource **Prometheus**

### Kibana
1. Acesse `http://localhost:5601`
2. **Stack Management → Saved Objects → Import**
3. Selecione `elk/kibana-dashboard.json`
4. Acesse **Analytics → Dashboards → SRE Demo — Log Analytics**
