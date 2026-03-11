#!/usr/bin/env bash
# =============================================================================
# setup-env.sh — Playbook de instalação das ferramentas CLI do ambiente SRE
#
# Ferramentas instaladas:
#   - Go 1.22
#   - Docker
#   - kubectl
#   - Helm 3
#   - minikube
#   - Task (Taskfile runner)
#
# Suporte: Ubuntu/Debian (apt) · macOS (brew)
# Idempotente: seguro para rodar múltiplas vezes.
#
# Uso:
#   chmod +x setup-env.sh && ./setup-env.sh
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Versões pinadas
# =============================================================================
GO_VERSION="1.22.3"
KUBECTL_VERSION="v1.29.4"
HELM_VERSION="v3.14.4"
MINIKUBE_VERSION="v1.33.0"
TASK_VERSION="v3.37.0"

# =============================================================================
# Helpers de output
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[✔]${NC} $*"; }
step()    { echo -e "\n${BLUE}${BOLD}━━━ $* ${NC}"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
already() { echo -e "${GREEN}[✔]${NC} $1 já instalado — $(${2} 2>/dev/null || echo 'ok')"; }

# =============================================================================
# Detecção de SO e arquitetura
# =============================================================================
detect_platform() {
  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "${OS}" in
    Linux)
      PLATFORM="linux"
      if [ ! -f /etc/debian_version ] && [ ! -f /etc/ubuntu_version ]; then
        # Tenta identificar via /etc/os-release para ser mais abrangente
        . /etc/os-release 2>/dev/null || true
        if [[ "${ID_LIKE:-}" != *"debian"* && "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" ]]; then
          error "Distro não suportada. Este script suporta Ubuntu/Debian e macOS."
        fi
      fi
      PKG_MANAGER="apt"
      ;;
    Darwin)
      PLATFORM="darwin"
      PKG_MANAGER="brew"
      if ! command -v brew &>/dev/null; then
        error "Homebrew não encontrado. Instale em https://brew.sh antes de continuar."
      fi
      ;;
    *)
      error "SO '${OS}' não suportado. Suporte: Linux (Ubuntu/Debian) e macOS."
      ;;
  esac

  case "${ARCH}" in
    x86_64 | amd64) ARCH_GO="amd64"; ARCH_KUBE="amd64" ;;
    arm64 | aarch64) ARCH_GO="arm64"; ARCH_KUBE="arm64" ;;
    *) error "Arquitetura '${ARCH}' não suportada." ;;
  esac

  info "Plataforma detectada: ${OS} / ${ARCH}"
}

# =============================================================================
# apt helpers
# =============================================================================
apt_update_once() {
  if [ "${APT_UPDATED:-0}" = "0" ]; then
    step "Atualizando índice apt"
    sudo apt-get update -qq
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  sudo apt-get install -y -qq "$@"
}

# =============================================================================
# Go
# =============================================================================
install_go() {
  step "Go ${GO_VERSION}"

  if command -v go &>/dev/null; then
    INSTALLED_GO=$(go version | awk '{print $3}' | sed 's/go//')
    if [ "${INSTALLED_GO}" = "${GO_VERSION}" ]; then
      already "Go ${GO_VERSION}" "go version"
      return
    fi
    warn "Go ${INSTALLED_GO} encontrado, substituindo por ${GO_VERSION}..."
    sudo rm -rf /usr/local/go
  fi

  local tarball="go${GO_VERSION}.${PLATFORM}-${ARCH_GO}.tar.gz"
  local url="https://go.dev/dl/${tarball}"

  info "Baixando ${url}..."
  curl -fsSL "${url}" -o "/tmp/${tarball}"
  sudo tar -C /usr/local -xzf "/tmp/${tarball}"
  rm -f "/tmp/${tarball}"

  # Garante que /usr/local/go/bin esteja no PATH desta sessão
  export PATH="/usr/local/go/bin:${PATH}"

  # Persiste no perfil do shell se ainda não estiver
  local profile
  profile="${HOME}/.bashrc"
  [ -f "${HOME}/.zshrc" ] && profile="${HOME}/.zshrc"

  if ! grep -q '/usr/local/go/bin' "${profile}" 2>/dev/null; then
    echo 'export PATH="/usr/local/go/bin:${PATH}"' >> "${profile}"
    info "PATH atualizado em ${profile}"
  fi

  info "Go $(go version) instalado."
}

# =============================================================================
# Docker
# =============================================================================
install_docker() {
  step "Docker"

  if command -v docker &>/dev/null; then
    already "Docker" "docker --version"
    return
  fi

  if [ "${PLATFORM}" = "darwin" ]; then
    warn "No macOS, instale o Docker Desktop manualmente: https://www.docker.com/products/docker-desktop/"
    warn "Pulando instalação automática do Docker no macOS."
    return
  fi

  info "Instalando Docker via script oficial..."
  curl -fsSL https://get.docker.com | sudo sh

  # Adiciona o usuário atual ao grupo docker para não precisar de sudo
  if id -nG "${USER}" | grep -qw docker; then
    info "Usuário '${USER}' já está no grupo docker."
  else
    sudo usermod -aG docker "${USER}"
    warn "Usuário '${USER}' adicionado ao grupo docker."
    warn "Para aplicar sem reiniciar, execute: newgrp docker"
  fi

  sudo systemctl enable docker --now
  info "Docker $(docker --version) instalado."
}

# =============================================================================
# kubectl
# =============================================================================
install_kubectl() {
  step "kubectl ${KUBECTL_VERSION}"

  if command -v kubectl &>/dev/null; then
    INSTALLED_KUBE=$(kubectl version --client -o json 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['clientVersion']['gitVersion'])" 2>/dev/null \
      || kubectl version --client --short 2>/dev/null | awk '{print $3}')
    if [ "${INSTALLED_KUBE}" = "${KUBECTL_VERSION}" ]; then
      already "kubectl ${KUBECTL_VERSION}" "kubectl version --client --short 2>/dev/null || kubectl version --client"
      return
    fi
    warn "kubectl ${INSTALLED_KUBE} encontrado, substituindo por ${KUBECTL_VERSION}..."
  fi

  if [ "${PLATFORM}" = "darwin" ]; then
    brew install kubectl
  else
    local url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_KUBE}/kubectl"
    info "Baixando ${url}..."
    curl -fsSLo /tmp/kubectl "${url}"
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
  fi

  info "kubectl $(kubectl version --client --short 2>/dev/null || kubectl version --client) instalado."
}

# =============================================================================
# Helm
# =============================================================================
install_helm() {
  step "Helm ${HELM_VERSION}"

  if command -v helm &>/dev/null; then
    INSTALLED_HELM=$(helm version --short 2>/dev/null | cut -d'+' -f1)
    if [ "${INSTALLED_HELM}" = "${HELM_VERSION}" ]; then
      already "Helm ${HELM_VERSION}" "helm version --short"
      return
    fi
    warn "Helm ${INSTALLED_HELM} encontrado, substituindo por ${HELM_VERSION}..."
  fi

  if [ "${PLATFORM}" = "darwin" ]; then
    brew install helm
  else
    info "Instalando Helm ${HELM_VERSION}..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
      | DESIRED_VERSION="${HELM_VERSION}" bash
  fi

  info "Helm $(helm version --short) instalado."
}

# =============================================================================
# minikube
# =============================================================================
install_minikube() {
  step "minikube ${MINIKUBE_VERSION}"

  if command -v minikube &>/dev/null; then
    INSTALLED_MINIKUBE=$(minikube version --short 2>/dev/null)
    if [ "${INSTALLED_MINIKUBE}" = "${MINIKUBE_VERSION}" ]; then
      already "minikube ${MINIKUBE_VERSION}" "minikube version --short"
      return
    fi
    warn "minikube ${INSTALLED_MINIKUBE} encontrado, substituindo por ${MINIKUBE_VERSION}..."
  fi

  if [ "${PLATFORM}" = "darwin" ]; then
    brew install minikube
  else
    local url="https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/minikube-linux-${ARCH_KUBE}"
    info "Baixando ${url}..."
    curl -fsSLo /tmp/minikube "${url}"
    chmod +x /tmp/minikube
    sudo mv /tmp/minikube /usr/local/bin/minikube
  fi

  info "minikube $(minikube version --short) instalado."
}

# =============================================================================
# Task (Taskfile runner)
# =============================================================================
install_task() {
  step "Task ${TASK_VERSION}"

  if command -v task &>/dev/null; then
    INSTALLED_TASK=$(task --version 2>/dev/null | awk '{print $3}')
    if [ "${INSTALLED_TASK}" = "${TASK_VERSION}" ]; then
      already "Task ${TASK_VERSION}" "task --version"
      return
    fi
    warn "Task ${INSTALLED_TASK} encontrado, substituindo por ${TASK_VERSION}..."
  fi

  if [ "${PLATFORM}" = "darwin" ]; then
    brew install go-task
  else
    local install_dir="${HOME}/.local/bin"
    mkdir -p "${install_dir}"
    info "Instalando Task ${TASK_VERSION} em ${install_dir}..."
    sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -d -b "${install_dir}" "${TASK_VERSION}"

    # Persiste no PATH se necessário
    local profile
    profile="${HOME}/.bashrc"
    [ -f "${HOME}/.zshrc" ] && profile="${HOME}/.zshrc"

    if ! grep -q "${install_dir}" "${profile}" 2>/dev/null; then
      echo "export PATH=\"${install_dir}:\${PATH}\"" >> "${profile}"
      info "PATH atualizado em ${profile}"
    fi

    export PATH="${install_dir}:${PATH}"
  fi

  info "Task $(task --version) instalado."
}

# =============================================================================
# Dependências de sistema (Linux apenas)
# =============================================================================
install_system_deps() {
  [ "${PLATFORM}" = "darwin" ] && return

  step "Dependências de sistema (curl, git, jq, python3)"

  local missing=()
  for pkg in curl git jq python3; do
    command -v "${pkg}" &>/dev/null || missing+=("${pkg}")
  done

  if [ ${#missing[@]} -eq 0 ]; then
    info "Todas as dependências de sistema já estão presentes."
    return
  fi

  info "Instalando: ${missing[*]}"
  apt_install "${missing[@]}"
}

# =============================================================================
# Resumo final
# =============================================================================
print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${GREEN}  ✅  Ambiente SRE instalado com sucesso!${NC}"
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Versões instaladas:${NC}"
  echo -e "    go        $(go version 2>/dev/null | awk '{print $3, $4}' || echo 'ver PATH')"
  echo -e "    docker    $(docker --version 2>/dev/null || echo 'ver instalação manual')"
  echo -e "    kubectl   $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
  echo -e "    helm      $(helm version --short 2>/dev/null)"
  echo -e "    minikube  $(minikube version --short 2>/dev/null)"
  echo -e "    task      $(task --version 2>/dev/null)"
  echo ""
  echo -e "  ${BOLD}Próximo passo — subir o ambiente do desafio:${NC}"
  echo ""
  echo -e "    ${YELLOW}task setup${NC}     → inicia minikube + namespaces + repos Helm"
  echo -e "    ${YELLOW}task build${NC}     → build da imagem Docker"
  echo -e "    ${YELLOW}task deploy${NC}    → aplica manifests K8s"
  echo -e "    ${YELLOW}task install-prometheus${NC}  → Prometheus + Grafana"
  echo -e "    ${YELLOW}task install-elk${NC}         → Elasticsearch + Kibana + Filebeat"
  echo ""

  if [ "${PLATFORM}" = "linux" ]; then
    warn "Se acabou de ser adicionado ao grupo docker, recarregue o shell:"
    echo -e "    ${YELLOW}newgrp docker${NC}  ou abra um novo terminal"
    echo ""
  fi

  if [ "${PLATFORM}" = "darwin" ]; then
    warn "Docker Desktop precisa estar em execução antes de rodar 'task setup'."
    echo ""
  fi
}

# =============================================================================
# Main
# =============================================================================
main() {
  echo ""
  echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${BLUE}  SRE Pleno — Playbook de instalação do ambiente${NC}"
  echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  detect_platform
  install_system_deps
  install_go
  install_docker
  install_kubectl
  install_helm
  install_minikube
  install_task
  print_summary
}

main "$@"
