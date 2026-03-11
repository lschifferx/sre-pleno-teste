# sre-pleno-teste

> Ecossistema de **Reliability Engineering** em Go + Kubernetes + ELK + Grafana.
> Cada decisão técnica está documentada. Nada foi feito por acidente.

---

## Índice

1. [Visão Geral](#visão-geral)
2. [Decisões de Arquitetura](#decisões-de-arquitetura)
3. [Decisões de Aplicação](#decisões-de-aplicação)
4. [Decisões de Container](#decisões-de-container)
5. [Decisões de Kubernetes](#decisões-de-kubernetes)
6. [Decisões de CI/CD](#decisões-de-cicd)
7. [Decisões de Observabilidade](#decisões-de-observabilidade)
8. [Quick Start](#quick-start)
9. [Referência de Endpoints](#referência-de-endpoints)
10. [Referência de Métricas](#referência-de-métricas)
11. [Secrets Necessários](#secrets-necessários)

---

## Visão Geral

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

```
sre-pleno-teste/
├── .github/workflows/ci-cd.yml  # Pipeline: Lint → Build → Push → Deploy
├── Dockerfile                   # Multi-stage, distroless, non-root
├── Taskfile.yaml                # Automação local
├── app/
│   ├── go.mod
│   ├── cmd/server/main.go       # Entry point, graceful shutdown
│   └── internal/
│       ├── handlers/            # HTTP handlers
│       ├── metrics/             # Prometheus counters/histograms/gauges
│       └── middleware/          # Logging + Recovery estruturado
├── k8s/
│   ├── deployment.yaml          # 2 réplicas, probes, ConfigMap, securityContext
│   ├── service.yaml             # ClusterIP + Namespace
│   ├── hpa.yaml                 # HPA v2: CPU >70% / Mem >75%
│   └── pdb.yaml                 # PodDisruptionBudget: minAvailable=1
├── monitoring/
│   └── grafana-dashboard.json   # Golden Signals dashboard
└── elk/
    ├── filebeat.yaml            # DaemonSet — coleta logs
    ├── logstash.conf            # Grok parse + enrich + output ES
    └── kibana-dashboard.json    # Dashboard + Alert rule
```

---

## Decisões de Arquitetura

### ADR-001 — Go como linguagem da aplicação

**Status:** aceito

**Contexto:**
Precisávamos de uma linguagem que gerasse binários estáticos, tivesse suporte nativo a concorrência e um ecossistema maduro para HTTP e métricas.

**Decisão:**
Go 1.22. Binário compilado com `CGO_ENABLED=0`, resultando em um artefato sem dependências externas de runtime.

**Consequências:**
- Imagem final < 10 MB (binário estático + distroless).
- Goroutines baratas permitem simular carga real sem threads de OS.
- Biblioteca `prometheus/client_golang` é a referência do mercado.

**Alternativas descartadas:**
- **Python/FastAPI**: dependências de runtime pesadas; imagem final ~200 MB.
- **Node.js**: event loop single-thread dificulta testes de concorrência reais.
- **Rust**: overhead de compilação e curva de aprendizado incompatíveis com o prazo.

---

### ADR-002 — Kubernetes (minikube) como plataforma de deploy

**Status:** aceito

**Contexto:**
O teste exige demonstrar práticas de SRE em produção: HPA, PDB, probes, rolling update. Precisávamos de um ambiente local que se comportasse como produção.

**Decisão:**
minikube com driver Docker. Reproduz exatamente o comportamento de um cluster EKS/GKE sem custo de infraestrutura.

**Consequências:**
- Todos os manifests K8s funcionam sem modificação em clusters gerenciados.
- metrics-server habilitado como addon para que o HPA funcione localmente.

**Alternativas descartadas:**
- **Docker Compose**: não tem HPA, PDB, namespaces, RBAC.
- **kind**: viável, mas minikube tem melhor suporte a addons e tooling (service URLs, docker-env).

---

### ADR-003 — Separação de namespaces

**Status:** aceito

**Contexto:**
Aplicação, observabilidade e logging têm ciclos de vida, permissões e recursos distintos.

**Decisão:**
Três namespaces: `sre-demo` (app), `monitoring` (Prometheus + Grafana), `logging` (ELK).

**Consequências:**
- NetworkPolicies podem ser aplicadas por namespace sem regras cruzadas complexas.
- Helm releases isolados por namespace; rollback de Grafana não afeta app.
- Custo: 3 `kubectl create namespace` no bootstrap.

---

## Decisões de Aplicação

### ADR-004 — Graceful shutdown com os.Signal

**Status:** aceito

**Contexto:**
Kubernetes envia `SIGTERM` antes de matar o pod. Sem tratamento, requests em voo são abortados — violação de SLO de disponibilidade.

**Decisão:**
`main.go` escuta `SIGTERM` / `SIGINT`, chama `http.Server.Shutdown(ctx)` com timeout de 30s (alinhado ao `terminationGracePeriodSeconds` do Deployment).

**Consequências:**
- Zero requisições perdidas em rolling updates normais.
- `terminationGracePeriodSeconds: 30` no Deployment é o contrato: se o app demorar mais, o kubelet mata forçado.

---

### ADR-005 — Endpoints de simulação de falha

**Status:** aceito

**Contexto:**
Dashboards e alertas sem carga real são teatro. Precisávamos de endpoints que gerassem sinais observáveis.

**Decisão:**
- `/api/v1/simulate/error` → força HTTP 500 e incrementa contador de erros.
- `/api/v1/simulate/latency` → dorme 0–2s aleatórios e registra no histograma.

**Consequências:**
- `task stress` envia 600 requisições e popula Grafana + Kibana com dados reais.
- Alerta do Kibana (≥20 erros/5min) pode ser disparado manualmente e inspecionado.

---

### ADR-006 — Logs estruturados em JSON para stdout

**Status:** aceito

**Contexto:**
Filebeat lê stdout dos containers. Logs em texto livre exigem regex frágil no Logstash; logs JSON são parseados diretamente.

**Decisão:**
Middleware de logging emite JSON com campos fixos: `timestamp`, `method`, `path`, `status`, `latency_ms`, `environment`.

**Consequências:**
- Logstash usa `json` codec, sem Grok. Mais simples, mais performático.
- Campos `log_level` derivados do status HTTP: 2xx=INFO, 4xx=WARN, 5xx=ERROR.

---

## Decisões de Container

### ADR-007 — Multi-stage build

**Status:** aceito

**Contexto:**
Imagens com toolchain Go pesam ~1 GB. Isso aumenta superfície de ataque, tempo de pull e custo de armazenamento.

**Decisão:**
Stage 1 (`golang:1.22-alpine`): compila o binário. Stage 2 (`distroless/static-debian12:nonroot`): apenas o binário e os arquivos de suporte necessários.

**Consequências:**
- Imagem final ~8 MB (vs ~1 GB com toolchain).
- Zero shell no runtime: `kubectl exec` não funciona — comportamento intencional, força uso de ferramentas de debug dedicadas.
- CA certificates e tzdata copiados explicitamente do builder.

---

### ADR-008 — distroless como imagem base de runtime

**Status:** aceito

**Contexto:**
Imagens Alpine têm shell e package manager — vetores de ataque em caso de container escape.

**Decisão:**
`gcr.io/distroless/static-debian12:nonroot`. Zero shell, zero APK, UID 65532 por padrão.

**Consequências:**
- CVEs reportados são virtualmente zero (sem libc dinâmica, sem utilitários).
- Binário precisa ser 100% estático (`CGO_ENABLED=0`). Qualquer biblioteca C causa pânico em runtime.
- Debug requer ferramentas externas (kubectl debug, ephemeral containers).

**Alternativas descartadas:**
- **scratch**: não inclui CA certs e tzdata; HTTPS e timestamps de timezone quebram.
- **alpine**: tem shell (ash) — superfície de ataque desnecessária.

---

### ADR-009 — Build flags de segurança e tamanho

**Status:** aceito

**Contexto:**
Binários Go incluem debug symbols e tabelas DWARF por padrão — inúteis em produção, aumentam tamanho e expõem nomes de funções.

**Decisão:**
```
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build \
  -ldflags="-w -s -extldflags '-static'" \
  -trimpath \
  -o /build/server \
  ./cmd/server
```

- `-w`: remove tabela DWARF (debug).
- `-s`: remove symbol table.
- `-trimpath`: remove caminhos absolutos do binário (não vaza estrutura do filesystem de CI).
- `-extldflags '-static'`: força linkagem estática total.

**Consequências:**
- Binário ~30% menor.
- Strings do binário não revelam caminhos do servidor de build.

---

## Decisões de Kubernetes

### ADR-010 — 3 probes distintas (liveness, readiness, startup)

**Status:** aceito

**Contexto:**
Uma única probe não cobre os três estados distintos de um container: inicialização, disponibilidade para tráfego e saúde contínua.

**Decisão:**
| Probe | Endpoint | Ação em falha |
|-------|----------|---------------|
| `startupProbe` | `/health` | Reinicia antes que liveness assuma |
| `livenessProbe` | `/health` | Reinicia o container |
| `readinessProbe` | `/ready` | Remove do Service (sem restart) |

**Consequências:**
- `startupProbe` evita que `livenessProbe` mate o container durante inicialização lenta.
- `readinessProbe` separada permite drenagem de tráfego sem reiniciar pod durante sobrecarga temporária.

---

### ADR-011 — HPA com dupla métrica (CPU + Memória)

**Status:** aceito

**Contexto:**
Aplicações Go com alto throughput podem saturar CPU mas manter memória estável, ou vice-versa em workloads com muitos objetos em heap.

**Decisão:**
HPA v2 com `scaleUp` em CPU >70% **ou** Memória >75%. Escala de 2 a 6 réplicas. `stabilizationWindowSeconds: 300` em scale-down para evitar flapping.

**Consequências:**
- Scale-up rápido (sem janela de estabilização) para absorver picos.
- Scale-down conservador (5 min) para não matar pods durante oscilações de carga.
- Custo: pode manter réplicas extras por até 5 min após queda de carga.

---

### ADR-012 — PodDisruptionBudget com minAvailable: 1

**Status:** aceito

**Contexto:**
Node drain durante upgrades de cluster pode matar todos os pods do Deployment simultaneamente se não houver restrição.

**Decisão:**
`PodDisruptionBudget` com `minAvailable: 1`. Com 2 réplicas configuradas, garante que ao menos 1 está sempre disponível durante operações voluntárias de disrupção.

**Consequências:**
- `kubectl drain` nunca remove o segundo pod antes do primeiro estar Running em outro nó.
- Upgrades de cluster ficam mais lentos, mas com zero downtime observável.
- **Limitação:** com exatamente 2 réplicas e `minAvailable: 1`, apenas 1 pod pode ser disrompido por vez. Se o HPA escalar para 6, revisar o PDB.

---

### ADR-013 — topologySpreadConstraints por hostname

**Status:** aceito

**Contexto:**
Com 2 réplicas no mesmo nó, a falha desse nó derruba 100% da capacidade.

**Decisão:**
`topologySpreadConstraints` com `maxSkew: 1` e `topologyKey: kubernetes.io/hostname`. Força distribuição máxima de 1 pod de diferença entre nós.

**Consequências:**
- Em clusters com 1 nó (minikube padrão), o scheduler não consegue satisfazer a constraint com `DoNotSchedule` — o segundo pod fica `Pending`.
- **Solução local:** `minikube start --nodes=2` ou alterar para `ScheduleAnyway` em desenvolvimento.
- Em produção (≥2 nós), comportamento correto sem intervenção.

---

### ADR-014 — seccompProfile: RuntimeDefault

**Status:** aceito

**Contexto:**
Sem seccomp, o container pode fazer qualquer syscall do kernel Linux — superfície de ataque desnecessária.

**Decisão:**
`seccompProfile.type: RuntimeDefault` no `securityContext` do pod. Usa o perfil padrão do runtime (containerd/runc), que bloqueia ~50 syscalls perigosas sem configuração custom.

**Consequências:**
- Proteção imediata sem curar um perfil seccomp custom.
- Syscalls como `ptrace`, `mount`, `reboot` são bloqueadas por padrão.

---

## Decisões de CI/CD

### ADR-015 — GitHub Actions como plataforma de CI/CD

**Status:** aceito

**Contexto:**
O repositório está no GitHub. Usar uma ferramenta externa adiciona infraestrutura a manter sem ganho real para este contexto.

**Decisão:**
GitHub Actions com workflow em `.github/workflows/ci-cd.yml`.

**Consequências:**
- Zero infraestrutura de CI a provisionar.
- `GITHUB_TOKEN` automático para push no GHCR.
- `concurrency.cancel-in-progress: true` evita runs duplicados em pushes rápidos.

**Alternativas descartadas:**
- **Jenkins**: requer servidor dedicado, manutenção de plugins, JVM.
- **GitLab CI**: requeriria migrar o repositório ou configurar mirror.
- **CircleCI**: custo em créditos; secret management externo ao GitHub.

---

### ADR-016 — 4 estágios separados: Lint / Build / Push / Deploy

**Status:** aceito

**Contexto:**
Um único job gigante mistura responsabilidades, dificulta debug e reexecução parcial.

**Decisão:**
4 jobs encadeados via `needs`:
```
lint → build → push → deploy
```

Cada job tem responsabilidade única e pode ser reexecutado isoladamente.

**Consequências:**
- Lint falha em < 2 min sem gastar créditos de build e push.
- Push só ocorre se build + testes passaram.
- Deploy só ocorre em `main` — branches de feature nunca afetam produção.

---

### ADR-017 — GitHub Container Registry (GHCR) como registry

**Status:** aceito

**Contexto:**
Docker Hub tem limite de pulls em contas gratuitas (100 pulls/6h para IPs anônimos), causando falhas intermitentes em CI com runners compartilhados.

**Decisão:**
`ghcr.io` com autenticação via `GITHUB_TOKEN` automático.

**Consequências:**
- Sem limite de pull em repositórios públicos.
- Autenticação automática — sem secrets extras para registry.
- Imagens privadas protegidas pela autenticação GitHub.

**Alternativas descartadas:**
- **Docker Hub**: limite de pulls; secret management mais complexo.
- **AWS ECR / GCR**: requer credentials de cloud provider mesmo para desenvolvimento local.

---

### ADR-018 — Smoke test no container antes do push

**Status:** aceito

**Contexto:**
Uma imagem que builda mas não inicia é pior do que uma que não builda — passa pelo Lint e Build, vai para produção e derruba o Deployment.

**Decisão:**
No stage `build`, após construir a imagem localmente (`load: true`), o workflow sobe o container e faz `curl /health`. Qualquer status diferente de 200 aborta o pipeline.

**Consequências:**
- Falhas de inicialização (porta errada, env var faltando, panic no boot) são capturadas antes do push.
- Adiciona ~10s ao job de build — custo aceitável.

---

### ADR-019 — Rollback automático em falha de deploy

**Status:** aceito

**Contexto:**
Se o `kubectl rollout status` sofrer timeout, o Deployment fica em estado degradado. Sem rollback automático, a intervenção manual aumenta o MTTR.

**Decisão:**
Step com `if: failure()` executa `kubectl rollout undo` automaticamente se qualquer step do job `deploy` falhar.

**Consequências:**
- MTTR reduzido: rollback automático em ~60s vs intervenção humana.
- **Limitação:** rollback reverte apenas o Deployment. ConfigMaps e outros recursos não são revertidos. Para mudanças de schema/config, rollback manual é necessário.

---

### ADR-020 — Imutabilidade de tags via SHA curto

**Status:** aceito

**Contexto:**
Tags mutáveis como `latest` não garantem que o pod em produção é o mesmo que foi testado. Dois deploys com a mesma tag podem ter imagens diferentes.

**Decisão:**
Tag primária de deploy: `sha-<7 chars do commit>`. Ex.: `sha-a1b2c3d`. Tags adicionais (`branch-name`, `semver`) existem para conveniência, mas o deploy usa sempre a SHA.

**Consequências:**
- Rastreabilidade total: dado um pod em produção, é possível identificar exatamente o commit que gerou aquela imagem.
- `kubectl rollout history` + tag SHA = audit trail completo.

---

### ADR-021 — Build multi-arch (amd64 + arm64)

**Status:** aceito

**Contexto:**
Apple Silicon (M1/M2/M3) usa arm64. Runners de CI são amd64. Desenvolvedores em Mac veriam emulação lenta sem suporte arm64.

**Decisão:**
`platforms: linux/amd64,linux/arm64` no `docker/build-push-action`. Docker Buildx usa QEMU para cross-compilation no runner amd64.

**Consequências:**
- Build ~2x mais lento (dois targets).
- Desenvolvedores em Apple Silicon rodam a imagem nativa sem emulação.
- Infraestrutura baseada em ARM (Graviton, Ampere) pode usar a mesma imagem.

---

### ADR-022 — SBOM e provenance no push

**Status:** aceito

**Contexto:**
Supply chain security (SLSA) é requisito crescente. Saber o que está dentro de uma imagem e provar sua origem é fundamental para resposta a incidentes e CVEs.

**Decisão:**
`sbom: true` e `provenance: true` no `docker/build-push-action`. Gera automaticamente um SBOM no formato SPDX e um attestation de provenance SLSA Level 3.

**Consequências:**
- `docker buildx imagetools inspect <image>` mostra o SBOM completo.
- Em caso de CVE, é possível identificar em segundos se a imagem é afetada.
- Nenhuma mudança no processo de build — custo zero de implementação.

---

## Decisões de Observabilidade

### ADR-023 — Golden Signals como base do dashboard Grafana

**Status:** aceito

**Contexto:**
Métricas de infraestrutura (CPU, memória) não mostram se o usuário está sendo impactado. Golden Signals mostram.

**Decisão:**
Dashboard centrado em 4 painéis: **Latency** (p50/p95/p99), **Traffic** (req/s), **Errors** (rate de 5xx), **Saturation** (CPU + goroutines).

**Consequências:**
- On-call sabe em < 30s se há impacto ao usuário olhando um único dashboard.
- Métricas de saturação ajudam a antecipar problemas antes de virarem erros.

---

### ADR-024 — Alert Kibana com throttle de 15 minutos

**Status:** aceito

**Contexto:**
Alertas sem throttle em picos de erro geram dezenas de notificações por minuto — alert fatigue que leva on-calls a ignorar alertas.

**Decisão:**
Trigger: ≥20 erros em 5 min, excluindo `/health`, `/ready`, `/metrics`. Throttle: 15 min. Action: escreve no índice `sre-alerts`.

**Consequências:**
- Janela de 5 min detecta degradação antes que SLO de disponibilidade seja violado.
- Exclusão de endpoints de probe evita falsos positivos durante node drain.
- Throttle de 15 min significa no máximo 4 alertas/hora em incidente longo.

---

### ADR-025 — Filebeat como DaemonSet (não Sidecar)

**Status:** aceito

**Contexto:**
Sidecar de log coleta apenas os logs de um pod. DaemonSet coleta de todos os pods no nó com um único processo.

**Decisão:**
Filebeat como DaemonSet no namespace `logging`. Monta `/var/log/containers` do nó host.

**Consequências:**
- N pods, 1 Filebeat por nó — escala linearmente com nós, não com pods.
- Kubernetes metadata (pod name, namespace, labels) enriquecido automaticamente.
- **Custo:** Filebeat tem acesso a logs de todos os containers no nó — risco de exposição de logs sensíveis de outros serviços. Mitigar com NetworkPolicies e filtros de namespace no Filebeat.

---

## Quick Start

### Pré-requisitos

| Ferramenta | Versão mínima |
|-----------|--------------|
| Docker    | 24+          |
| minikube  | 1.32+        |
| kubectl   | 1.29+        |
| Helm      | 3.14+        |
| Task      | 3.35+        |
| Go        | 1.22+        |

```bash
# macOS
brew install go-task

# Linux
sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b ~/.local/bin
```

### Deploy completo

```bash
task all
```

Ou passo a passo:

```bash
task setup               # minikube + namespaces + helm repos
task build               # imagem Docker dentro do daemon minikube
task deploy              # aplica manifests K8s
task install-prometheus  # Prometheus + Grafana
task install-elk         # Elasticsearch + Kibana + Filebeat
```

### Acessando as UIs

```bash
task port-forward-app        # http://localhost:8080
task port-forward-grafana    # http://localhost:3000  (admin/prom-operator)
task port-forward-kibana     # http://localhost:5601
task port-forward-prometheus # http://localhost:9090
```

### Gerando carga

```bash
task validate   # smoke test em todos os endpoints
task stress     # 600 requisições para popular dashboards
```

---

## Referência de Endpoints

| Endpoint | Método | Descrição |
|---------|--------|-----------|
| `/health` | GET | Liveness probe |
| `/ready` | GET | Readiness probe |
| `/metrics` | GET | Prometheus scrape endpoint |
| `/api/v1/ping` | GET | Ping/pong |
| `/api/v1/status` | GET | Info: env, goroutines, memória |
| `/api/v1/simulate/error` | GET | Força HTTP 500 |
| `/api/v1/simulate/latency` | GET | Latência aleatória 0–2s |

---

## Referência de Métricas

| Métrica | Tipo | Descrição |
|---------|------|-----------|
| `http_requests_total` | Counter | Total de requisições por endpoint e status |
| `http_request_duration_seconds` | Histogram | Latência por endpoint (p50/p95/p99) |
| `http_error_rate` | Gauge | Taxa de erros por endpoint |
| `app_memory_alloc_bytes` | Gauge | Heap alocado em bytes |
| `app_cpu_goroutines` | Gauge | Número de goroutines ativas |

---

## Secrets Necessários

Configure os secrets no repositório GitHub (`Settings → Secrets and variables → Actions`):

| Secret | Descrição | Quando é usado |
|--------|-----------|----------------|
| `KUBECONFIG` | kubeconfig do cluster em base64 (`cat ~/.kube/config \| base64`) | Stage: Deploy |
| `GITHUB_TOKEN` | Gerado automaticamente pelo GitHub Actions | Stage: Push (GHCR) |

`GITHUB_TOKEN` não precisa ser criado manualmente. Docker Hub não é usado.

---

## Importando Dashboards

### Grafana
1. `task port-forward-grafana`
2. **Dashboards → Import → Upload JSON**
3. Selecione `monitoring/grafana-dashboard.json`
4. Datasource: **Prometheus**

### Kibana
1. `task port-forward-kibana`
2. **Stack Management → Saved Objects → Import**
3. Selecione `elk/kibana-dashboard.json`
4. **Analytics → Dashboards → SRE Demo — Log Analytics**
