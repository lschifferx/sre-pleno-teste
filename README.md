# sre-pleno-teste

> Ecossistema de **Reliability Engineering** em Go + Kubernetes + ELK + Grafana + ArgoCD.  
> Cada decisão técnica está documentada. Nada foi feito por acidente.

---

## Índice

1. [Visão Geral](#visão-geral)
2. [Arquitetura do Sistema](#arquitetura-do-sistema)
3. [Estrutura do Repositório](#estrutura-do-repositório)
4. [Decisões de Arquitetura (ADRs)](#decisões-de-arquitetura-adrs)
   - [ADR-001 — Go como linguagem da aplicação](#adr-001--go-como-linguagem-da-aplicação)
   - [ADR-002 — Kubernetes (minikube) como plataforma de deploy](#adr-002--kubernetes-minikube-como-plataforma-de-deploy)
   - [ADR-003 — Separação de namespaces](#adr-003--separação-de-namespaces)
5. [Decisões de Aplicação](#decisões-de-aplicação)
   - [ADR-004 — Graceful shutdown com os.Signal](#adr-004--graceful-shutdown-com-ossignal)
   - [ADR-005 — Endpoints de simulação de falha](#adr-005--endpoints-de-simulação-de-falha)
   - [ADR-006 — Logs estruturados em JSON para stdout](#adr-006--logs-estruturados-em-json-para-stdout)
6. [Decisões de Container](#decisões-de-container)
   - [ADR-007 — Multi-stage build](#adr-007--multi-stage-build)
   - [ADR-008 — distroless como imagem base de runtime](#adr-008--distroless-como-imagem-base-de-runtime)
   - [ADR-009 — Build flags de segurança e tamanho](#adr-009--build-flags-de-segurança-e-tamanho)
7. [Decisões de Kubernetes](#decisões-de-kubernetes)
   - [ADR-010 — 3 probes distintas (liveness, readiness, startup)](#adr-010--3-probes-distintas-liveness-readiness-startup)
   - [ADR-011 — HPA com dupla métrica (CPU + Memória)](#adr-011--hpa-com-dupla-métrica-cpu--memória)
   - [ADR-012 — PodDisruptionBudget com minAvailable: 1](#adr-012--poddisruptionbudget-com-minavailable-1)
   - [ADR-013 — topologySpreadConstraints por hostname](#adr-013--topologyspreadconstraints-por-hostname)
   - [ADR-014 — seccompProfile: RuntimeDefault](#adr-014--seccompprofile-runtimedefault)
   - [ADR-015 — RollingUpdate com maxUnavailable: 0](#adr-015--rollingupdate-com-maxunavailable-0)
   - [ADR-016 — Recursos e limites explícitos no container](#adr-016--recursos-e-limites-explícitos-no-container)
   - [ADR-017 — ConfigMap para variáveis de ambiente](#adr-017--configmap-para-variáveis-de-ambiente)
8. [Decisões de CI/CD](#decisões-de-cicd)
   - [ADR-018 — GitHub Actions como plataforma de CI/CD](#adr-018--github-actions-como-plataforma-de-cicd)
   - [ADR-019 — 4 estágios separados: Lint / Build / Push / Deploy](#adr-019--4-estágios-separados-lint--build--push--deploy)
   - [ADR-020 — GitHub Container Registry (GHCR) como registry](#adr-020--github-container-registry-ghcr-como-registry)
   - [ADR-021 — Smoke test no container antes do push](#adr-021--smoke-test-no-container-antes-do-push)
   - [ADR-022 — Rollback automático em falha de deploy](#adr-022--rollback-automático-em-falha-de-deploy)
   - [ADR-023 — Imutabilidade de tags via SHA curto](#adr-023--imutabilidade-de-tags-via-sha-curto)
   - [ADR-024 — Build multi-arch (amd64 + arm64)](#adr-024--build-multi-arch-amd64--arm64)
   - [ADR-025 — SBOM e provenance no push](#adr-025--sbom-e-provenance-no-push)
9. [Decisões de Observabilidade](#decisões-de-observabilidade)
   - [ADR-026 — Golden Signals como base do dashboard Grafana](#adr-026--golden-signals-como-base-do-dashboard-grafana)
   - [ADR-027 — Alert Kibana com throttle de 15 minutos](#adr-027--alert-kibana-com-throttle-de-15-minutos)
   - [ADR-028 — Filebeat como DaemonSet (não Sidecar)](#adr-028--filebeat-como-daemonset-não-sidecar)
   - [ADR-029 — Stack ELK gerenciada 100% via Helm](#adr-029--stack-elk-gerenciada-100-via-helm)
   - [ADR-030 — Taskfile como orquestrador local](#adr-030--taskfile-como-orquestrador-local)
   - [ADR-031 — ArgoCD como operador de GitOps](#adr-031--argocd-como-operador-de-gitops)
10. [Quick Start](#quick-start)
11. [Referência de Endpoints](#referência-de-endpoints)
12. [Referência de Métricas](#referência-de-métricas)
13. [Secrets Necessários](#secrets-necessários)
14. [Importando Dashboards](#importando-dashboards)

---

## Visão Geral

```
┌──────────────────────────────────────────────────────────────────────┐
│                          minikube cluster                            │
│                                                                      │
│  namespace: sre-demo           namespace: monitoring                 │
│  ┌──────────────────┐          ┌──────────────────────────────────┐  │
│  │  sre-demo-app    │◄─scrape──│  Prometheus + Grafana            │  │
│  │  (2–6 réplicas)  │          │  kube-prometheus-stack           │  │
│  │  /metrics        │          └──────────────────────────────────┘  │
│  └────────┬─────────┘                                                │
│           │ stdout logs        namespace: logging                    │
│  ┌────────▼─────────┐          ┌──────────────────────────────────┐  │
│  │    Filebeat       │──beats──►│ Elasticsearch → Kibana           │  │
│  │   (DaemonSet)     │          │                                  │  │
│  └───────────────────┘          └──────────────────────────────────┘  │
│                                                                      │
│  namespace: argocd                                                   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  ArgoCD — GitOps operator                                    │   │
│  │  Observa: github.com/…/sre-pleno-teste (branch main, k8s/)  │   │
│  │  Sincroniza automaticamente → namespace sre-demo             │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

A aplicação expõe métricas Prometheus em `/metrics` e emite logs JSON para stdout. O Prometheus faz scrape por anotações no pod. O Filebeat coleta os logs do nó e os encaminha ao Elasticsearch. Kibana e Grafana cobrem, respectivamente, a visão de logs e a visão de métricas. O ArgoCD monitora o repositório Git e sincroniza automaticamente qualquer mudança nos manifests de `k8s/` com o cluster.

---

## Arquitetura do Sistema

| Camada          | Tecnologia                        | Responsabilidade                           |
| --------------- | --------------------------------- | ------------------------------------------ |
| Aplicação       | Go 1.22 + `net/http`              | Servidor HTTP, métricas, graceful shutdown |
| Container       | Docker multi-stage + distroless   | Imagem mínima, sem shell, non-root         |
| Orquestração    | Kubernetes (minikube)             | Deploy, scaling, self-healing              |
| Autoscaling     | HPA v2 (CPU + Mem)                | Escala horizontal reativa                  |
| Disponibilidade | PDB + topologySpread              | Zero downtime em manutenções               |
| Métricas        | Prometheus + Grafana              | Golden Signals em tempo real               |
| Logs            | Filebeat + Elasticsearch + Kibana | Busca e alertas sobre logs                 |
| CI/CD           | GitHub Actions + GHCR             | Build, push, deploy automatizados          |
| GitOps          | ArgoCD                            | Sincronização contínua Git → cluster       |
| Automação local | Taskfile                          | Um comando para tudo                       |

---

## Estrutura do Repositório

```
sre-pleno-teste/
├── .github/
│   └── workflows/
│       └── ci-cd.yml           # Pipeline: Lint → Build → Push → Deploy
├── Dockerfile                  # Multi-stage, distroless, non-root, CGO_ENABLED=0
├── Taskfile.yaml               # Automação local (setup, build, deploy, stress, etc.)
├── app/
│   ├── go.mod                  # Go 1.22, dep: prometheus/client_golang
│   ├── go.sum
│   ├── cmd/
│   │   └── server/
│   │       └── main.go         # Entry point, graceful shutdown (SIGTERM/SIGINT)
│   └── internal/
│       ├── handlers/           # HTTP handlers: /health, /ready, /ping, /status, /simulate/*
│       ├── metrics/            # Contadores, histogramas e gauges Prometheus
│       └── middleware/         # Logging JSON estruturado + recovery de panic
├── k8s/
│   ├── deployment.yaml         # 2 réplicas, 3 probes, ConfigMap, securityContext completo
│   ├── service.yaml            # ClusterIP (porta 80 → 8080)
│   ├── hpa.yaml                # HPA v2: CPU >70% / Mem >75%, 2–6 réplicas
│   ├── pdb.yaml                # PodDisruptionBudget: minAvailable=1
│   └── argocd-app.yaml         # Application ArgoCD: aponta para k8s/ no branch main
├── helmcharts/
│   ├── prometheus/             # Wrapper chart: kube-prometheus-stack
│   ├── elasticsearch/          # Wrapper chart: elastic/elasticsearch
│   ├── kibana/                 # Wrapper chart: elastic/kibana
│   ├── filebeat/               # Wrapper chart: elastic/filebeat
│   └── argocd/                 # Wrapper chart: argo-cd (argoproj/argo-helm)
├── monitoring/
│   └── grafana-dashboard.json  # Dashboard Golden Signals (Latency/Traffic/Errors/Saturation)
└── elk/
    ├── filebeat.yaml           # DaemonSet de referência (substituído pelo Helm)
    └── kibana-dashboard.json   # Dashboard + Alert rule (≥20 erros/5min)
```

---

## Decisões de Arquitetura (ADRs)

### ADR-001 — Go como linguagem da aplicação

**Contexto:**  
Precisávamos de uma linguagem que gerasse binários estáticos, tivesse suporte nativo a concorrência e um ecossistema maduro para HTTP e métricas Prometheus.

**Decisão:**  
Go 1.22. Binário compilado com `CGO_ENABLED=0`, resultando em um artefato sem dependências externas de runtime. Única dependência direta: `prometheus/client_golang v1.19.1`.

**Consequências:**

- Imagem final < 10 MB (binário estático + distroless).
- Goroutines baratas permitem simular carga real sem threads de OS.
- `prometheus/client_golang` é a biblioteca de referência do ecossistema.
- `go mod verify` no Dockerfile garante integridade das dependências no build.

**Alternativas descartadas:**

- **Python/FastAPI:** dependências de runtime pesadas; imagem final ~200 MB.
- **Node.js:** event loop single-thread dificulta testes de concorrência reais.
- **Rust:** overhead de compilação e curva de aprendizado incompatíveis com o prazo.

---

### ADR-002 — Kubernetes (minikube) como plataforma de deploy

**Contexto:**  
O teste exige demonstrar práticas de SRE em produção: HPA, PDB, probes, rolling update. Precisávamos de um ambiente local que se comportasse como produção sem custo de infraestrutura.

**Decisão:**  
minikube com driver Docker, iniciado com `--cpus=4 --memory=6144`. Addon `metrics-server` habilitado para que o HPA funcione localmente.

**Consequências:**

- Todos os manifests K8s funcionam sem modificação em clusters gerenciados (EKS, GKE, AKS).
- `minikube docker-env` permite buildar imagens diretamente no daemon interno, eliminando a necessidade de push/pull para registry em desenvolvimento local.
- `--nodes=2` necessário se `topologySpreadConstraints` com `DoNotSchedule` estiver ativo (ver ADR-013).

**Alternativas descartadas:**

- **Docker Compose:** não tem HPA, PDB, namespaces, RBAC, probes nativas.
- **kind:** viável, mas minikube tem melhor suporte a addons e tooling (`service URLs`, `docker-env`).

---

### ADR-003 — Separação de namespaces

**Contexto:**  
Aplicação, observabilidade e logging têm ciclos de vida, permissões e perfis de recursos distintos. Colocar tudo em `default` cria acoplamento desnecessário.

**Decisão:**  
Três namespaces: `sre-demo` (app), `monitoring` (Prometheus + Grafana), `logging` (ELK). Criados com `--dry-run=client -o yaml | kubectl apply -f -` para idempotência.

**Consequências:**

- NetworkPolicies podem ser aplicadas por namespace sem regras cruzadas complexas.
- Helm releases isolados por namespace: rollback de Grafana não afeta a app.
- Namespaces criados de forma idempotente: `task setup` pode ser re-executado sem erro.

---

## Decisões de Aplicação

### ADR-004 — Graceful shutdown com os.Signal

**Contexto:**  
Kubernetes envia `SIGTERM` antes de matar o pod. Sem tratamento, requests em voo são abortados — violação direta do SLO de disponibilidade.

**Decisão:**  
`main.go` escuta `SIGTERM` e `SIGINT` via `os/signal`. Ao receber o sinal, chama `http.Server.Shutdown(ctx)` com timeout de 30s, alinhado ao `terminationGracePeriodSeconds: 30` do Deployment.

**Consequências:**

- Zero requisições perdidas em rolling updates normais.
- O contrato `terminationGracePeriodSeconds: 30` é o limite: se o app demorar mais, o kubelet executa `SIGKILL`.
- Graceful shutdown funciona tanto em deploys via CI quanto em `task rollback` local.

---

### ADR-005 — Endpoints de simulação de falha

**Contexto:**  
Dashboards e alertas sem carga real são teatro. Precisávamos de endpoints que gerassem sinais observáveis reais para validar toda a cadeia de observabilidade.

**Decisão:**

- `/api/v1/simulate/error` → força HTTP 500, incrementa contador de erros Prometheus.
- `/api/v1/simulate/latency` → dorme 0–2s aleatórios, registra latência no histograma.

**Consequências:**

- `task stress` envia 600 requisições (200× cada endpoint de `/ping`, `/simulate/error`, `/simulate/latency`) e popula Grafana e Kibana com dados reais.
- O alerta do Kibana (≥20 erros/5min) pode ser disparado manualmente e inspecionado sem necessitar de falha real na aplicação.
- Endpoints excluídos explicitamente das regras de alerta para evitar falsos positivos.

---

### ADR-006 — Logs estruturados em JSON para stdout

**Contexto:**  
Filebeat lê stdout dos containers e envia direto ao Elasticsearch. Logs em texto livre exigem parsing frágil na ingestão; logs JSON são indexados diretamente sem transformação.

**Decisão:**  
Middleware de logging emite JSON com campos fixos: `timestamp`, `method`, `path`, `status`, `latency_ms`, `environment`. Campo `log_level` derivado do status HTTP: `2xx=INFO`, `4xx=WARN`, `5xx=ERROR`.

**Consequências:**

- Filebeat indexa os logs diretamente no Elasticsearch sem camada de transformação intermediária.
- Campos consistentes permitem filtros e dashboards Kibana sem transformações adicionais.
- `environment` no log permite distinguir staging de produção na mesma pilha de logs.

---

## Decisões de Container

### ADR-007 — Multi-stage build

**Contexto:**  
Imagens com toolchain Go pesam ~1 GB. Isso aumenta superfície de ataque, tempo de pull e custo de armazenamento no registry.

**Decisão:**  
Dois stages no Dockerfile:

- **Stage 1 (`golang:1.22-alpine` / builder):** instala dependências de build (`ca-certificates`, `git`, `tzdata`), faz download e verificação de módulos (`go mod download && go mod verify`), compila o binário estático.
- **Stage 2 (`distroless/static-debian12:nonroot` / runtime):** recebe apenas o binário, `zoneinfo` e `ca-certificates` do stage anterior.

**Consequências:**

- Imagem final ~8 MB vs ~1 GB com toolchain.
- Layer de `go mod download` é cacheada separadamente: mudanças no código-fonte não invalidam o cache de dependências.
- `go mod verify` no build garante que os módulos baixados correspondem ao checksum em `go.sum` — defesa contra supply chain attacks.

---

### ADR-008 — distroless como imagem base de runtime

**Contexto:**  
Imagens Alpine têm shell (`ash`) e package manager (`apk`) — vetores de ataque em caso de container escape ou comprometimento do processo.

**Decisão:**  
`gcr.io/distroless/static-debian12:nonroot`. Zero shell, zero APK, zero package manager. UID 65532 (`nonroot`) por padrão da imagem.

**Consequências:**

- CVEs de sistema praticamente inexistentes (sem libc dinâmica, sem utilitários de sistema).
- Binário precisa ser 100% estático (`CGO_ENABLED=0`). Qualquer dependência de biblioteca C causa panic em runtime.
- Debug requer ferramentas externas: `kubectl debug` com ephemeral containers ou `kubectl cp` para copiar binários de diagnóstico.
- `ca-certificates` e `tzdata` copiados explicitamente do builder — sem esses arquivos, chamadas HTTPS e parsing de timestamps de timezone falhariam silenciosamente.

**Alternativas descartadas:**

- **scratch:** não inclui CA certs e tzdata; HTTPS e timestamps de timezone falham.
- **alpine:** tem shell (`ash`) — superfície de ataque desnecessária para runtime.

---

### ADR-009 — Build flags de segurança e tamanho

**Contexto:**  
Binários Go incluem debug symbols e tabelas DWARF por padrão — inúteis em produção, aumentam tamanho e expõem nomes de funções e caminhos do filesystem de build.

**Decisão:**

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build \
  -ldflags="-w -s -extldflags '-static'" \
  -trimpath \
  -o /build/server \
  ./cmd/server
```

| Flag                    | Efeito                                  |
| ----------------------- | --------------------------------------- |
| `-w`                    | Remove tabela DWARF (debug info)        |
| `-s`                    | Remove symbol table                     |
| `-extldflags '-static'` | Força linkagem estática total           |
| `-trimpath`             | Remove caminhos absolutos do binário    |
| `CGO_ENABLED=0`         | Desabilita CGo, garante binário puro Go |

**Consequências:**

- Binário ~30% menor do que sem as flags.
- Strings do binário não revelam caminhos do servidor de CI (segurança de supply chain).
- `-trimpath` também melhora reprodutibilidade de builds (builds determinísticos).

---

## Decisões de Kubernetes

### ADR-010 — 3 probes distintas (liveness, readiness, startup)

**Contexto:**  
Uma única probe não cobre os três estados distintos de um container: inicialização, disponibilidade para tráfego e saúde contínua.

**Decisão:**

| Probe            | Endpoint  | `initialDelay` | `period` | Ação em falha                      |
| ---------------- | --------- | -------------- | -------- | ---------------------------------- |
| `startupProbe`   | `/health` | 3s             | 5s (×10) | Reinicia antes que liveness assuma |
| `livenessProbe`  | `/health` | 10s            | 15s      | Reinicia o container               |
| `readinessProbe` | `/ready`  | 5s             | 10s      | Remove do Service (sem restart)    |

`/health` e `/ready` são endpoints separados na aplicação, permitindo que o app sinalize "estou vivo mas não pronto para tráfego" — útil durante aquecimento de cache ou conexões com dependências externas.

**Consequências:**

- `startupProbe` evita que `livenessProbe` mate o container durante inicialização lenta (janela de até 50s: 10 tentativas × 5s).
- `readinessProbe` separada permite drenagem de tráfego sem reiniciar pod durante sobrecarga temporária.
- Endpoints de probe excluídos das métricas de negócio para não distorcer latência média e taxa de erros.

---

### ADR-011 — HPA com dupla métrica (CPU + Memória)

**Contexto:**  
Aplicações Go com alto throughput podem saturar CPU mantendo memória estável, ou vice-versa em workloads com muitos objetos em heap. Monitorar apenas CPU causaria sub-scaling em workloads intensivos em memória.

**Decisão:**  
HPA v2 com scale-up em CPU >70% **ou** Memória >75%. Escala de 2 a 6 réplicas.

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 60 # scale-up rápido
    policies:
      - type: Pods
        value: 1
        periodSeconds: 60
  scaleDown:
    stabilizationWindowSeconds: 120 # scale-down conservador
    policies:
      - type: Pods
        value: 1
        periodSeconds: 90
```

**Consequências:**

- Scale-up pode adicionar 1 pod a cada 60s para absorver picos graduais.
- Scale-down conservador (janela de 120s + 1 pod a cada 90s) evita flapping em oscilações de carga.
- Custo: pode manter réplicas extras por até ~5 min após queda de carga. Trade-off aceitável versus instabilidade.
- `metrics-server` precisa estar habilitado no cluster (feito via `minikube addons enable metrics-server`).

---

### ADR-012 — PodDisruptionBudget com minAvailable: 1

**Contexto:**  
Node drain durante upgrades de cluster pode matar todos os pods do Deployment simultaneamente se não houver restrição explícita.

**Decisão:**  
`PodDisruptionBudget` com `minAvailable: 1`. Com 2 réplicas base, garante que ao menos 1 está sempre disponível durante operações voluntárias de disrupção (node drain, cluster upgrade, reschedule manual).

**Consequências:**

- `kubectl drain` nunca remove o segundo pod antes do primeiro estar `Running` em outro nó.
- Upgrades de cluster ficam sequencialmente mais lentos, porém com zero downtime observável.
- **Limitação:** se o HPA escalar para 6 réplicas e o PDB permanecer `minAvailable: 1`, até 5 pods podem ser removidos simultaneamente. Rever o PDB para `minAvailable: 50%` caso a carga máxima seja crítica.
- PDB protege apenas contra disrupções _voluntárias_. Falha de nó (disrupção involuntária) não é coberta.

---

### ADR-013 — topologySpreadConstraints por hostname

**Contexto:**  
Com 2 réplicas no mesmo nó, a falha desse nó derruba 100% da capacidade. Isso viola qualquer SLO de disponibilidade acima de `1 - MTTR/período`.

**Decisão:**

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: sre-demo-app
```

**Consequências:**

- Força distribuição de no máximo 1 pod de diferença entre nós.
- **Trade-off local:** em minikube com 1 nó, o scheduler não satisfaz `DoNotSchedule` — o segundo pod fica `Pending`. Solução: `minikube start --nodes=2` ou alterar para `ScheduleAnyway` em desenvolvimento.
- Em produção com ≥2 nós, comportamento correto sem intervenção adicional.

---

### ADR-014 — seccompProfile: RuntimeDefault

**Contexto:**  
Sem seccomp, o container pode executar qualquer syscall do kernel Linux — superfície de ataque desnecessária para uma aplicação HTTP simples.

**Decisão:**  
`seccompProfile.type: RuntimeDefault` no `securityContext` do pod. Usa o perfil padrão do runtime (containerd/runc), que bloqueia ~50 syscalls perigosas sem necessidade de perfil customizado.

**Consequências:**

- Proteção imediata: syscalls como `ptrace`, `mount`, `reboot`, `kexec_load` são bloqueadas por padrão.
- Zero custo de implementação — sem necessidade de criar ou manter um perfil seccomp customizado.
- Combinado com `capabilities.drop: ALL` e `allowPrivilegeEscalation: false`, forma um conjunto sólido de hardening de container.

---

### ADR-015 — RollingUpdate com maxUnavailable: 0

**Contexto:**  
Com apenas 2 réplicas, `maxUnavailable: 1` (padrão) permitiria zero pods disponíveis durante o rolling update — downtime total.

**Decisão:**

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1 # até 3 pods simultâneos durante deploy
    maxUnavailable: 0 # nunca reduz abaixo de 2 pods disponíveis
```

**Consequências:**

- Deploy zero-downtime garantido: novo pod sobe e passa em `readinessProbe` antes de o antigo ser terminado.
- `maxSurge: 1` significa uso temporário de 50% a mais de recursos durante o deploy (3 pods vs 2).
- Requer que o cluster tenha capacidade para o pod extra durante o rollout.

---

### ADR-016 — Recursos e limites explícitos no container

**Contexto:**  
Sem `resources.requests`, o scheduler não tem informação para posicionar o pod adequadamente. Sem `resources.limits`, um pod bugado pode esgotar recursos do nó e derrubar outros workloads.

**Decisão:**

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "200m"
    memory: "256Mi"
```

**Consequências:**

- `requests` garante que o pod seja agendado em nó com capacidade real.
- `limits` previne memory leaks ou CPU spinning de impactar outros pods no nó.
- Ratio `limits/requests = 2×` para CPU e memória dá margem para picos sem over-provisioning excessivo.
- HPA usa `requests` como base de cálculo de percentual de utilização — valores coerentes são essenciais para o autoscaling funcionar corretamente.

---

### ADR-017 — ConfigMap para variáveis de ambiente

**Contexto:**  
Hardcodar variáveis de ambiente no Deployment dificulta mudanças de configuração sem rebuild da imagem.

**Decisão:**  
`ConfigMap` (`sre-app-config`) no mesmo namespace, injetado via `envFrom.configMapRef`. Contém `APP_ENV=staging` e `PORT=8080`.

**Consequências:**

- Configuração mutável sem rebuild de imagem ou redeploy completo.
- Separação clara entre código (imagem) e configuração (ConfigMap).
- `--dry-run=client -o yaml | kubectl apply -f -` no Taskfile garante idempotência na criação do namespace e dos recursos.
- **Limitação:** ConfigMap não é adequado para secrets. Credenciais devem usar `Secret` com referência via `secretKeyRef`.

---

## Decisões de CI/CD

### ADR-018 — GitHub Actions como plataforma de CI/CD

**Contexto:**  
O repositório está no GitHub. Usar ferramenta externa (Jenkins, GitLab CI) adiciona infraestrutura a provisionar e manter sem ganho real para este escopo.

**Decisão:**  
GitHub Actions com workflow em `.github/workflows/ci-cd.yml`. `concurrency.cancel-in-progress: true` evita runs duplicados em pushes rápidos para a mesma branch.

**Consequências:**

- Zero infraestrutura de CI a provisionar.
- `GITHUB_TOKEN` automático para autenticação no GHCR.
- Cache de layers Docker entre runs via `actions/cache`.
- Runs gratuitos em repositórios públicos; para privados, consumem minutos do plano.

**Alternativas descartadas:**

- **Jenkins:** requer servidor dedicado, manutenção de plugins, JVM, storage para artefatos.
- **GitLab CI:** requer migração de repositório ou configuração de mirror.
- **CircleCI:** custo em créditos; secret management externo ao GitHub.

---

### ADR-019 — 4 estágios separados: Lint / Build / Push / Deploy

**Contexto:**  
Um único job gigante mistura responsabilidades, dificulta debug, aumenta custo de re-execução e oculta qual etapa falhou.

**Decisão:**  
4 jobs encadeados via `needs`:

```
lint → build → push → deploy
```

Cada job tem responsabilidade única e falha isolada.

**Consequências:**

- `lint` (hadolint no Dockerfile) falha em < 2 min sem gastar créditos de build e push.
- `push` só ocorre se build + testes passaram — imagens quebradas nunca chegam ao registry.
- `deploy` só ocorre em push para `main` — branches de feature nunca afetam produção.
- Re-execução parcial: é possível re-rodar apenas o stage `deploy` após corrigir credenciais do cluster sem rebuildar a imagem.

---

### ADR-020 — GitHub Container Registry (GHCR) como registry

**Contexto:**  
Docker Hub tem limite de pulls em contas gratuitas (100 pulls/6h para IPs anônimos), causando falhas intermitentes em CI com runners compartilhados.

**Decisão:**  
`ghcr.io` com autenticação via `GITHUB_TOKEN` automático. Imagens publicadas em `ghcr.io/<owner>/sre-demo-app`.

**Consequências:**

- Sem limite de pull em repositórios públicos.
- Autenticação nativa — sem secrets extras para o registry.
- Imagens privadas protegidas pela autenticação do GitHub.
- Integração nativa com GitHub Packages para visualização de imagens e vulnerabilidades.

**Alternativas descartadas:**

- **Docker Hub:** limite de pulls; secret management mais complexo (`DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN`).
- **AWS ECR / GCR:** requer credenciais de cloud provider mesmo para desenvolvimento local.

---

### ADR-021 — Smoke test no container antes do push

**Contexto:**  
Uma imagem que builda mas não inicializa é mais perigosa do que uma que não builda — ela passa por Lint e Build, chega ao registry e derruba o Deployment em produção.

**Decisão:**  
No stage `build`, após construir a imagem localmente (`load: true`), o workflow sobe o container e executa `curl /health`. Status diferente de 200 aborta o pipeline antes do push.

**Consequências:**

- Falhas de inicialização (porta errada, env var faltando, panic no boot) são capturadas antes do push.
- Adiciona ~10s ao job de build — custo aceitável vs risco de imagem quebrada no registry.
- Complementa o `go build` — valida não só compilação mas comportamento em runtime.

---

### ADR-022 — Rollback automático em falha de deploy

**Contexto:**  
Se `kubectl rollout status` sofrer timeout, o Deployment fica em estado degradado. Sem rollback automático, a intervenção manual aumenta o MTTR.

**Decisão:**  
Step com `if: failure()` no job `deploy` executa `kubectl rollout undo` automaticamente caso qualquer step anterior do job falhe. Disponível também localmente via `task rollback`.

**Consequências:**

- MTTR reduzido: rollback automático em ~60s vs intervenção humana.
- **Limitação:** rollback reverte apenas o `Deployment`. `ConfigMaps`, `Secrets` e outros recursos não são revertidos automaticamente. Para mudanças de schema ou configuração, rollback manual é necessário.
- `kubectl rollout history` preserva o histórico de revisões para auditoria.

---

### ADR-023 — Imutabilidade de tags via SHA curto

**Contexto:**  
Tags mutáveis como `latest` não garantem que o pod em produção é o mesmo que foi testado. Dois deploys com a mesma tag podem ter imagens completamente diferentes.

**Decisão:**  
Tag primária de deploy: `sha-<7 chars do commit SHA>`. Ex.: `sha-a1b2c3d`. Tags adicionais (`branch-name`, `semver`) existem para conveniência humana, mas o deploy usa sempre a SHA.

**Consequências:**

- Rastreabilidade total: dado um pod em produção, o comando `kubectl get pod -o jsonpath='{.spec.containers[0].image}'` retorna a SHA exata do commit que gerou aquela imagem.
- `kubectl rollout history` + tag SHA = audit trail completo de deploys.
- Facilita incident response: identificar regressão por commit é trivial.

---

### ADR-024 — Build multi-arch (amd64 + arm64)

**Contexto:**  
Apple Silicon (M1/M2/M3/M4) usa arm64. Runners de CI são amd64. Desenvolvedores em Mac veriam emulação lenta (Rosetta) sem suporte nativo arm64.

**Decisão:**  
`platforms: linux/amd64,linux/arm64` no `docker/build-push-action`. Docker Buildx usa QEMU para cross-compilation no runner amd64.

**Consequências:**

- Build ~2× mais lento (dois targets compilados sequencialmente via QEMU).
- Desenvolvedores em Apple Silicon rodam a imagem nativamente sem emulação — pull automático da camada arm64.
- Infraestrutura baseada em ARM (AWS Graviton, Ampere Altra) pode usar a mesma imagem sem reconfiguração.

---

### ADR-025 — SBOM e provenance no push

**Contexto:**  
Supply chain security (SLSA) é requisito crescente em ambientes regulados e enterprise. Saber o que está dentro de uma imagem e provar sua origem é fundamental para resposta a incidentes e CVEs.

**Decisão:**  
`sbom: true` e `provenance: true` no `docker/build-push-action`. Gera automaticamente um SBOM no formato SPDX e um attestation de provenance SLSA Level 3.

**Consequências:**

- `docker buildx imagetools inspect <image>` exibe o SBOM completo.
- Em caso de CVE (ex.: `log4j`, `openssl`), é possível identificar em segundos se a imagem é afetada via varredura do SBOM.
- Zero mudança no processo de build — custo de implementação nulo.
- Attestations armazenados no GHCR junto com a imagem, sem storage externo.

---

## Decisões de Observabilidade

### ADR-026 — Golden Signals como base do dashboard Grafana

**Contexto:**  
Métricas de infraestrutura (CPU, memória) não mostram se o usuário final está sendo impactado. Um alto CPU pode ser normal; um p99 alto não pode.

**Decisão:**  
Dashboard centrado nos 4 Golden Signals (Google SRE Book):

| Sinal          | Métrica                              | Painel                           |
| -------------- | ------------------------------------ | -------------------------------- |
| **Latency**    | `http_request_duration_seconds`      | p50 / p95 / p99 por endpoint     |
| **Traffic**    | `http_requests_total`                | req/s total e por endpoint       |
| **Errors**     | `http_requests_total{status=~"5.."}` | Rate de 5xx                      |
| **Saturation** | CPU usage + `app_cpu_goroutines`     | % utilização + goroutines ativas |

**Consequências:**

- On-call identifica impacto ao usuário em < 30s olhando um único dashboard.
- Métricas de saturação (goroutines) ajudam a antecipar problemas antes que virem erros visíveis.
- Dashboard exportado em `monitoring/grafana-dashboard.json` — importável via UI ou Helm values.

---

### ADR-027 — Alert Kibana com throttle de 15 minutos

**Contexto:**  
Alertas sem throttle em picos de erro geram dezenas de notificações por minuto — alert fatigue que leva on-calls a ignorar alertas reais.

**Decisão:**

- **Trigger:** ≥20 erros em 5 min, excluindo `/health`, `/ready`, `/metrics`.
- **Throttle:** 15 minutos.
- **Action:** escreve evento no índice `sre-alerts`.

**Consequências:**

- Janela de 5 min detecta degradação antes que SLO de disponibilidade seja violado.
- Exclusão de endpoints de probe evita falsos positivos durante node drain e rolling updates.
- Throttle de 15 min = no máximo 4 alertas/hora durante incidente longo — sinal, não ruído.
- Índice `sre-alerts` permite correlação de alertas com logs de aplicação na mesma stack Kibana.

---

### ADR-028 — Filebeat como DaemonSet (não Sidecar)

**Contexto:**  
Sidecar de log coleta apenas os logs de um pod e duplica recursos (CPU/memória) por pod. DaemonSet coleta de todos os pods no nó com um único processo.

**Decisão:**  
Filebeat como DaemonSet no namespace `logging`. Monta `/var/log/containers` do nó host via `hostPath`. Kubernetes metadata (pod name, namespace, labels) enriquecido automaticamente via autodiscover.

**Consequências:**

- N pods → 1 Filebeat por nó. Escala linearmente com nós, não com pods.
- Kubernetes metadata enriquecido automaticamente sem instrumentação na aplicação.
- **Risco:** Filebeat tem acesso a logs de **todos** os containers no nó. Mitigar com filtros de namespace no `filebeat.yml` e NetworkPolicies restritivas no namespace `logging`.

---

### ADR-029 — Stack ELK gerenciada 100% via Helm

**Contexto:**  
O README original referenciava scripts shell (`install-kibana.sh`, `kubectl apply elk/filebeat.yaml`) como mecanismo de instalação. Scripts shell são difíceis de versionar, não são idempotentes e não suportam rollback.

**Decisão:**  
Todos os componentes ELK gerenciados via Helm wrapper charts em `helmcharts/`:

- `helmcharts/elasticsearch/` → wrapper do chart `elastic/elasticsearch`
- `helmcharts/kibana/` → wrapper do chart `elastic/kibana`
- `helmcharts/filebeat/` → wrapper do chart `elastic/filebeat`

Instalados sequencialmente por `task install-elk` (que chama `install-elasticsearch` → `install-kibana` → `install-filebeat`).

**Consequências:**

- Idempotência nativa: `helm upgrade --install` não falha se o release já existe.
- Rollback com um comando: `helm rollback <release> <revision>`.
- `values.yaml` por componente documenta todas as customizações em formato declarativo.
- `helm dependency update` antes de cada install garante dependências atualizadas.
- Arquivos em `elk/` (filebeat.yaml, kibana-dashboard.json) mantidos como referência histórica — o deploy não os utiliza diretamente.

---

### ADR-030 — Taskfile como orquestrador local

**Contexto:**  
`Makefile` tem sintaxe arcana, execução implícita de alvos e portabilidade frágil. Shell scripts avulsos não têm discovery (`--list`), dependências declaradas ou documentação integrada.

**Decisão:**  
`Taskfile.yaml` (go-task) como orquestrador de todas as operações locais: setup, build, deploy, instalação de stacks, port-forwards, validação e teardown.

**Consequências:**

- `task --list` mostra todos os comandos disponíveis com descrição.
- Variáveis centralizadas (`APP_NAME`, `NAMESPACE`, `MONITORING_NS`, `LOGGING_NS`) evitam hardcode espalhado.
- `task all` executa o ciclo completo de setup em um único comando.
- Tarefas compostas (`task install-elk` chamando sub-tarefas) permitem granularidade sem duplicação.
- Instável em: sistemas sem `task` instalado. Instruções de instalação documentadas no Quick Start.

---

### ADR-031 — ArgoCD como operador de GitOps

**Contexto:**  
O pipeline GitHub Actions faz o deploy via `kubectl apply` direto do runner de CI. Isso cria um acoplamento entre o estado do cluster e a execução do pipeline: se o runner falha, o cluster fica desatualizado sem nenhum mecanismo de reconciliação contínua. Além disso, não há visibilidade centralizada do estado real dos recursos no cluster em relação ao que está no repositório.

**Decisão:**  
ArgoCD instalado no namespace `argocd` via wrapper chart `helmcharts/argocd/` (upstream: `argoproj/argo-helm v7.3.11`). Uma `Application` (`k8s/argocd-app.yaml`) aponta para o diretório `k8s/` no branch `main` do repositório, com `syncPolicy.automated` habilitado.

```yaml
syncPolicy:
  automated:
    prune: true      # remove recursos deletados do Git
    selfHeal: true   # reverte mudanças manuais no cluster
```

**Consequências:**

- **Reconciliação contínua:** qualquer drift entre o cluster e o Git é corrigido automaticamente, sem intervenção humana.
- **`selfHeal: true`:** mudanças manuais via `kubectl apply` fora do Git são revertidas — o repositório é a única fonte de verdade.
- **`prune: true`:** recursos removidos do Git são deletados do cluster automaticamente, evitando acúmulo de recursos órfãos.
- **Visibilidade:** a UI do ArgoCD exibe o estado de sincronização de cada recurso em tempo real (`Synced`, `OutOfSync`, `Degraded`).
- **Complementa o CI:** o GitHub Actions continua responsável por build, testes e push da imagem. O ArgoCD assume a responsabilidade de garantir que o cluster reflita o estado do Git — separação clara de responsabilidades.
- **Credenciais:** repositório público não requer credenciais adicionais. Para repositórios privados, configurar em **Settings → Repositories** na UI do ArgoCD.
- **Acesso local:** `task port-forward-argocd` expõe a UI em `http://localhost:8888` (admin / sre-admin-2024).

**Alternativas descartadas:**

- **Flux:** igualmente válido, mas ArgoCD tem UI nativa que facilita a visualização do estado de sincronização — relevante para demonstração e troubleshooting.
- **Apenas GitHub Actions:** sem reconciliação contínua; drift manual no cluster não é detectado nem corrigido.

---

## Quick Start

### Pré-requisitos

| Ferramenta | Versão mínima | Instalação                                                       |
| ---------- | ------------- | ---------------------------------------------------------------- |
| Docker     | 24+           | [docs.docker.com](https://docs.docker.com/get-docker/)           |
| minikube   | 1.32+         | [minikube.sigs.k8s.io](https://minikube.sigs.k8s.io/docs/start/) |
| kubectl    | 1.29+         | [kubernetes.io/docs](https://kubernetes.io/docs/tasks/tools/)    |
| Helm       | 3.14+         | [helm.sh/docs](https://helm.sh/docs/intro/install/)              |
| Task       | 3.35+         | ver abaixo                                                       |
| Go         | 1.22+         | [go.dev/dl](https://go.dev/dl/)                                  |

```bash
# Task — macOS
brew install go-task

# Task — Linux
sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b ~/.local/bin
```

### Deploy completo (um comando)

```bash
task all
```

### Deploy passo a passo

```bash
task setup               # minikube (2 nodes recomendado) + namespaces + helm repos
task build               # imagem Docker buildada dentro do daemon minikube
task deploy              # aplica manifests K8s e aguarda rollout
task install-prometheus  # Prometheus + Grafana via Helm
task install-elk         # Elasticsearch → Kibana → Filebeat via Helm
task install-argocd      # ArgoCD via Helm + registra Application sre-demo-app
```

> **Nota:** Para `topologySpreadConstraints` com `DoNotSchedule` funcionar localmente, use:
>
> ```bash
> minikube start --nodes=2 --cpus=4 --memory=6144 --driver=docker
> ```

### Acessando as UIs

```bash
task port-forward-app        # http://localhost:8080
task port-forward-grafana    # http://localhost:3000  (admin / sre-admin-2024)
task port-forward-kibana     # http://localhost:5601
task port-forward-prometheus # http://localhost:9090
task port-forward-elasticsearch # https://localhost:9200
task port-forward-argocd     # http://localhost:8888  (admin / sre-admin-2024)
```

### Gerando carga e validando

```bash
task validate   # smoke test em todos os endpoints (espera resposta 200 em cada)
task stress     # 600 requisições para popular dashboards (200× ping + error + latency)
```

### Verificações de saúde

```bash
task check-prometheus  # verifica se sre-demo-app aparece nos targets do Prometheus
task check-filebeat    # verifica logs do pod Filebeat e índices no Elasticsearch
```

### Teardown

```bash
task clean     # remove manifests da aplicação (mantém cluster e stacks)
task destroy   # destrói o cluster minikube por completo
```

---

## Referência de Endpoints

| Endpoint                   | Método | Descrição                                                       | Probe                           |
| -------------------------- | ------ | --------------------------------------------------------------- | ------------------------------- |
| `/health`                  | GET    | Liveness check — retorna `200` se o processo está vivo          | `livenessProbe`, `startupProbe` |
| `/ready`                   | GET    | Readiness check — retorna `200` se pronto para receber tráfego  | `readinessProbe`                |
| `/metrics`                 | GET    | Prometheus scrape endpoint (formato text/openmetrics)           | —                               |
| `/api/v1/ping`             | GET    | Ping/pong — verifica conectividade básica                       | —                               |
| `/api/v1/status`           | GET    | Info da instância: `APP_ENV`, goroutines, memória heap          | —                               |
| `/api/v1/simulate/error`   | GET    | Força HTTP 500 + incrementa `http_requests_total{status="500"}` | —                               |
| `/api/v1/simulate/latency` | GET    | Latência aleatória 0–2s + registra no histograma de duração     | —                               |

---

## Referência de Métricas

| Métrica                         | Tipo      | Labels                         | Descrição                                              |
| ------------------------------- | --------- | ------------------------------ | ------------------------------------------------------ |
| `http_requests_total`           | Counter   | `endpoint`, `method`, `status` | Total de requisições por endpoint e status HTTP        |
| `http_request_duration_seconds` | Histogram | `endpoint`                     | Latência por endpoint — buckets para p50/p95/p99       |
| `http_error_rate`               | Gauge     | `endpoint`                     | Taxa de erros (5xx) por endpoint                       |
| `app_memory_alloc_bytes`        | Gauge     | —                              | Heap alocado em bytes (`runtime.MemStats.Alloc`)       |
| `app_cpu_goroutines`            | Gauge     | —                              | Número de goroutines ativas (`runtime.NumGoroutine()`) |

Todas as métricas expostas em `/metrics` no formato Prometheus text. Scrape configurado via anotações no pod:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```

---

## Secrets Necessários

Configure os secrets no repositório GitHub em `Settings → Secrets and variables → Actions`:

| Secret         | Descrição                          | Como obter                     | Quando é usado     |
| -------------- | ---------------------------------- | ------------------------------ | ------------------ |
| `KUBECONFIG`   | kubeconfig do cluster em base64    | `cat ~/.kube/config \| base64` | Stage: Deploy      |
| `GITHUB_TOKEN` | Token automático do GitHub Actions | Gerado automaticamente         | Stage: Push (GHCR) |

`GITHUB_TOKEN` **não precisa ser criado manualmente** — o GitHub injeta automaticamente em cada run. Docker Hub não é utilizado.

---

## Importando Dashboards

### Grafana (Golden Signals)

```bash
task port-forward-grafana   # abre em http://localhost:3000
```

1. Login: `admin` / `sre-admin-2024`
2. **Dashboards → Import → Upload JSON file**
3. Selecione `monitoring/grafana-dashboard.json`
4. Datasource: **Prometheus**
5. Click **Import**

### Kibana (Log Analytics + Alert)

```bash
task port-forward-kibana   # abre em http://localhost:5601
```

1. **Stack Management → Saved Objects → Import**
2. Selecione `elk/kibana-dashboard.json`
3. Confirme overwrite se solicitado
4. **Analytics → Dashboards → SRE Demo — Log Analytics**

> **Dica:** Execute `task stress` após importar os dashboards para visualizar dados reais. O alerta de erros (≥20 erros/5min) será disparado durante a execução do stress test.
