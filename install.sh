#!/bin/bash
# install.sh — mock-mesh 一键安装
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/hgj2025/mock-mesh/main/install.sh | \
#       bash -s -- --psm <psm> --artifact <scm_repo_path> [--version <ver>]
#
# 认证方式（优先级从高到低）：
#   1. 环境变量 SCM_JWT_TOKEN（直接使用）
#   2. bytedcli auth login → 自动获取 JWT
#   3. 交互式手动粘贴 JWT token
#
# 环境变量（可选）：
#   SCM_JWT_TOKEN   — 手动指定 JWT token，跳过 bytedcli
#   SCM_USERNAME    — 下载用户名（默认从 bytedcli/git 自动获取）
#   SCM_BASE_URL    — SCM 产物仓库地址
#   GIT_REPO_URL    — mock-mesh Git 仓库 SSH 地址
#   NPM_REGISTRY    — npm 镜像源（安装 bytedcli 时使用）
#   MOCK_MESH_DIR   — mock-mesh 安装目录（默认 /opt/mock-mesh）

set -euo pipefail
IFS=$'\n\t'

# ── 颜色 & 日志（全部输出到 stderr，避免污染函数返回值）─────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[·]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[✓]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[!]${NC} $*" >&2; }
step()  { echo -e "\n${BOLD}${CYAN}━━ $* ━━${NC}" >&2; }
die()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── 参数解析 ──────────────────────────────────────────────────────────────────
PSM=""
ARTIFACT_REPO=""
VERSION=""

usage() {
    cat >&2 <<'USAGE'
用法: bash install.sh --psm <psm> --artifact <scm_repo_path> [--version <ver>]

参数:
  --psm        服务 PSM（如 toutiao.douyin.admin_platform）
  --artifact   SCM 仓库路径（如 douyin/admin/admin_platform）
  --version    产物版本号（可选，不填自动查询最新）

环境变量:
  SCM_JWT_TOKEN   JWT token（跳过 bytedcli）
  SCM_USERNAME    下载用户名
  SCM_BASE_URL    SCM 产物仓库地址
  GIT_REPO_URL    mock-mesh Git SSH 地址
  NPM_REGISTRY    npm 镜像源（安装 bytedcli 用）
  MOCK_MESH_DIR   安装目录（默认 /opt/mock-mesh）
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --psm)        PSM="$2";              shift 2 ;;
        --artifact)   ARTIFACT_REPO="$2";    shift 2 ;;
        --version)    VERSION="$2";          shift 2 ;;
        --help|-h)    usage ;;
        *) die "未知参数: $1" ;;
    esac
done

[[ -n "$PSM"           ]] || die "缺少 --psm 参数"
[[ -n "$ARTIFACT_REPO" ]] || die "缺少 --artifact 参数（SCM 仓库路径，如 douyin/admin/admin_platform）"

# SCM 仓库路径（直接使用，支持 / 或 . 分隔）
ARTIFACT_REPO_PATH=$(echo "$ARTIFACT_REPO" | tr '.' '/')

# ── 常量（均可通过环境变量覆盖）──────────────────────────────────────────────────
SCM_BASE_URL="${SCM_BASE_URL:-}"
GIT_REPO_URL="${GIT_REPO_URL:-}"
MOCK_MESH_DIR="${MOCK_MESH_DIR:-/opt/mock-mesh}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
DOCKER_VER="27.3.1"
GOPROXY="https://goproxy.cn,direct"
TOKEN_CACHE="${HOME}/.mock-mesh/scm-token"

PSM_SLUG=$(echo "$PSM" | tr '.' '-')
SANDBOX_DIR="${MOCK_MESH_DIR}/deploy/ecs/sandbox/${PSM_SLUG}"
STATE_FILE="${SANDBOX_DIR}/.build-state"
COMPOSE_FILE="${SANDBOX_DIR}/docker-compose.yaml"

# ══════════════════════════════════════════════════════════════════════════════
# JWT 认证（自包含）
# ══════════════════════════════════════════════════════════════════════════════

_find_cli() {
    command -v bytedcli &>/dev/null && { command -v bytedcli; return; }
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    for d in "$nvm_dir"/versions/node/*/bin/bytedcli; do
        [[ -x "$d" ]] && { echo "$d"; return; }
    done
    return 1
}

_get_username() {
    [[ -n "${SCM_USERNAME:-}" ]] && { echo "$SCM_USERNAME"; return; }
    if [[ -f "$TOKEN_CACHE" ]]; then
        local u; u=$(grep "^USERNAME=" "$TOKEN_CACHE" 2>/dev/null | cut -d= -f2-)
        [[ -n "$u" ]] && { echo "$u"; return; }
    fi
    local cli; cli=$(_find_cli 2>/dev/null) || true
    if [[ -n "$cli" ]]; then
        local uname; uname=$("$cli" -j auth userinfo 2>/dev/null | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        [[ -n "$uname" ]] && { echo "$uname"; return; }
    fi
    local ge; ge=$(git config user.email 2>/dev/null || true)
    if [[ -n "$ge" ]]; then
        echo "${ge%%@*}"; return
    fi
    echo "unknown"
}

_get_token() {
    [[ -n "${SCM_JWT_TOKEN:-}" ]] && { echo "$SCM_JWT_TOKEN"; return; }
    if [[ -f "$TOKEN_CACHE" ]]; then
        local ct cs now
        ct=$(grep "^TOKEN=" "$TOKEN_CACHE" 2>/dev/null | cut -d= -f2-)
        cs=$(grep "^TIMESTAMP=" "$TOKEN_CACHE" 2>/dev/null | cut -d= -f2-)
        now=$(date +%s)
        if [[ -n "$ct" && -n "$cs" && $(( now - cs )) -lt 72000 ]]; then
            info "使用缓存 token ($(( (now - cs) / 3600 ))h ago)"
            echo "$ct"
            return
        fi
        [[ -n "$ct" ]] && warn "缓存 token 已过期，重新获取..."
    fi
    local cli; cli=$(_find_cli 2>/dev/null) || true
    if [[ -n "$cli" ]]; then
        local t; t=$("$cli" auth get-bytecloud-jwt-token 2>/dev/null || true)
        if [[ -n "$t" && ${#t} -gt 20 ]]; then
            ok "JWT token 获取成功 (via bytedcli, ${#t} chars)"
            echo "$t"
            return
        fi
        info "需要 SSO 登录..."
        "$cli" auth login >&2
        t=$("$cli" auth get-bytecloud-jwt-token 2>/dev/null || true)
        if [[ -n "$t" && ${#t} -gt 20 ]]; then
            ok "JWT token 获取成功 (via bytedcli, ${#t} chars)"
            echo "$t"
            return
        fi
        warn "bytedcli get-bytecloud-jwt-token 返回为空"
    fi
    echo "" >&2
    echo -e "  ${BOLD}需要 JWT Token 认证${NC}" >&2
    echo -e "  获取: 安装 bytedcli 后执行 ${BOLD}bytedcli auth login${NC}" >&2
    echo "" >&2
    read -rsp "  请粘贴 JWT Token (输入不可见): " t; echo "" >&2
    [[ -n "$t" ]] || die "Token 不能为空"
    echo "$t"
}

_save_cache() {
    mkdir -p "$(dirname "$TOKEN_CACHE")"
    cat > "$TOKEN_CACHE" <<CACHE
USERNAME=$1
TOKEN=$2
TIMESTAMP=$(date +%s)
CACHE
    chmod 600 "$TOKEN_CACHE"
}

_authed_curl() {
    local url="$1" output="$2" token="$3"
    curl --location --request GET \
        -H "x-jwt-token: ${token}" \
        -o "$output" -w "%{http_code}" \
        -s "$url" 2>/dev/null
}

scm_download() {
    local url="$1" output="$2"
    local username token http_code
    username=$(_get_username) || return 1
    token=$(_get_token) || return 1
    info "下载: $(basename "$url")"

    http_code=$(_authed_curl "$url" "$output" "$token")

    if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        warn "Token 无效 (HTTP ${http_code})，重新获取..."
        rm -f "$TOKEN_CACHE"
        unset SCM_JWT_TOKEN 2>/dev/null || true
        token=$(_get_token) || return 1
        http_code=$(_authed_curl "$url" "$output" "$token")
    fi

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]] && [[ -f "$output" && -s "$output" ]]; then
        _save_cache "$username" "$token"
        ok "下载成功: $(du -sh "$output" | cut -f1)"
        return 0
    else
        if [[ -f "$output" ]]; then
            warn "响应内容（前 500 字节）:"
            head -c 500 "$output" >&2
            echo "" >&2
        fi
        rm -f "$output"
        die "下载失败 (HTTP ${http_code})"
    fi
}

compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — 预检
# ══════════════════════════════════════════════════════════════════════════════
step "预检"

[[ "$(uname -m)" == "x86_64" ]] || die "仅支持 x86_64，当前: $(uname -m)"

[[ -n "$SCM_BASE_URL" ]] || die "请设置 SCM_BASE_URL 环境变量"
[[ -n "$GIT_REPO_URL" ]] || die "请设置 GIT_REPO_URL 环境变量"

ok "PSM:      ${PSM}"
ok "SCM 仓库: ${ARTIFACT_REPO_PATH}"
ok "SCM:      ${SCM_BASE_URL}"
ok "Git:      ${GIT_REPO_URL}"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — 安装依赖
# ══════════════════════════════════════════════════════════════════════════════
step "环境检查与安装"

info "安装基础依赖..."
apt-get update -qq 2>/dev/null
apt-get install -y --no-install-recommends \
    git curl ca-certificates iptables ip6tables \
    iproute2 kmod gosu python3 2>/dev/null | grep -E 'newly installed|already' || true
ok "基础依赖 OK"

# ── Docker ────────────────────────────────────────────────────────────────────
install_docker() {
    info "安装 Docker ${DOCKER_VER}..."
    if apt-get install -y --no-install-recommends docker.io 2>/dev/null; then
        ok "docker.io 从 apt 安装"; return
    fi
    info "下载静态二进制..."
    local url="https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VER}.tgz"
    curl -fsSL "$url" -o /tmp/docker.tgz || die "Docker 下载失败"
    tar -xzf /tmp/docker.tgz -C /tmp && cp /tmp/docker/* /usr/local/bin/
    chmod +x /usr/local/bin/docker* && rm -f /tmp/docker.tgz
    [[ -f /usr/bin/dockerd ]] || ln -sf /usr/local/bin/dockerd /usr/bin/dockerd
    [[ -f /usr/bin/docker  ]] || ln -sf /usr/local/bin/docker  /usr/bin/docker
    ok "Docker 静态二进制安装"
}

if docker version &>/dev/null 2>&1; then
    ok "Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
else
    install_docker
fi

groupadd docker 2>/dev/null || true

if ! systemctl is-active containerd &>/dev/null; then
    if [[ ! -f /etc/systemd/system/containerd.service ]]; then
        cat > /etc/systemd/system/containerd.service << 'UNIT'
[Unit]
Description=containerd container runtime
After=network.target
[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
[Install]
WantedBy=multi-user.target
UNIT
    fi
    systemctl daemon-reload
    systemctl enable --now containerd
fi

if ! docker version &>/dev/null 2>&1; then
    info "启动 Docker daemon..."
    systemctl daemon-reload
    systemctl enable --now docker 2>/dev/null || nohup dockerd > /var/log/dockerd.log 2>&1 &
    for i in $(seq 1 20); do docker version &>/dev/null && break; sleep 1; done
fi
docker version &>/dev/null || die "Docker daemon 启动失败"
ok "Docker daemon 运行中"

if ! grep -q "registry-mirrors" /etc/docker/daemon.json 2>/dev/null; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'JSON'
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com"
  ],
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m", "max-file": "3"}
}
JSON
    systemctl reload docker 2>/dev/null || kill -HUP "$(pgrep dockerd)" 2>/dev/null || true
    sleep 2
    ok "镜像加速配置完成"
fi

if ! (docker compose version &>/dev/null 2>&1 || command -v docker-compose &>/dev/null); then
    info "安装 Docker Compose..."
    apt-get install -y --no-install-recommends docker-compose 2>/dev/null || \
    pip3 install docker-compose --break-system-packages 2>/dev/null || \
    die "Docker Compose 安装失败"
fi
ok "Docker Compose: $(docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null)"

# ── xt_owner & 内核参数 ────────────────────────────────────────────────────────
modprobe xt_owner 2>/dev/null || true
grep -qx xt_owner /etc/modules 2>/dev/null || echo "xt_owner" >> /etc/modules
if iptables -t nat -A OUTPUT -m owner --uid-owner 65534 -p tcp -j RETURN 2>/dev/null; then
    iptables -t nat -D OUTPUT -m owner --uid-owner 65534 -p tcp -j RETURN 2>/dev/null || true
    ok "xt_owner 可用"
else
    warn "xt_owner 不可用"
fi
sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-mock-mesh.conf
ok "内核参数 OK"

# ── bytedcli ──────────────────────────────────────────────────────────────────
install_bytedcli() {
    if ! command -v node &>/dev/null; then
        info "安装 Node.js..."
        apt-get install -y --no-install-recommends nodejs npm 2>/dev/null || {
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
            apt-get install -y nodejs
        }
        command -v node &>/dev/null || die "Node.js 安装失败"
        ok "Node.js: $(node --version)"
    fi
    info "安装 bytedcli..."
    NPM_CONFIG_REGISTRY="$NPM_REGISTRY" \
        npm install -g bytedcli@latest 2>/dev/null || \
        die "bytedcli 安装失败"
}

if _find_cli &>/dev/null; then
    ok "bytedcli: $(_find_cli)"
else
    install_bytedcli
    _find_cli &>/dev/null || die "bytedcli 安装后仍无法找到"
    ok "bytedcli: $(_find_cli)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — 确定版本 & 下载 SCM 产物
# ══════════════════════════════════════════════════════════════════════════════
step "下载 SCM 产物"

mkdir -p "$SANDBOX_DIR"

LAST_VERSION=""
[[ -f "$STATE_FILE" ]] && LAST_VERSION=$(grep "^VERSION=" "$STATE_FILE" | cut -d= -f2 || true)

# 自动查询最新版本
if [[ -z "$VERSION" ]]; then
    info "查询最新成功构建版本 (${ARTIFACT_REPO_PATH})..."
    CLI=$(_find_cli)
    info "bytedcli 路径: ${CLI}"
    info "执行: ${CLI} -j scm list-repo-version ${ARTIFACT_REPO_PATH} --status build_ok --page-size 1"

    SCM_RAW=$("$CLI" -j scm list-repo-version "$ARTIFACT_REPO_PATH" \
        --status build_ok --page-size 1 2>&1 || true)

    # 从 SCM 响应同时取版本号和 tar_url
    eval "$(echo "$SCM_RAW" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    v = d['data']['versions'][0]
    print('VERSION=' + v['version'])
    print('SCM_TAR_URL=' + v.get('tar_url', ''))
    print('SCM_BIN_PATH=' + v.get('bin_path', ''))
except Exception as e:
    print('# PARSE_ERROR: ' + str(e), file=sys.stderr)
" 2>&2 || true)"
    info "解析版本: ${VERSION}, tar_url: ${SCM_TAR_URL:-无}, bin_path: ${SCM_BIN_PATH:-无}"
    [[ -n "$VERSION" ]] || die "未能自动获取版本号，请通过 --version 指定"
fi

# 产物文件名：优先用 SCM 返回的 bin_path，否则从仓库路径推导（/ 换 .）
if [[ -n "${SCM_BIN_PATH:-}" ]]; then
    ARTIFACT_FILE="$SCM_BIN_PATH"
else
    ARTIFACT_DOT_PREFIX=$(echo "$ARTIFACT_REPO_PATH" | tr '/' '.')
    ARTIFACT_FILE="${ARTIFACT_DOT_PREFIX}_${VERSION}.tar.gz"
fi
ARTIFACT_URL="${SCM_BASE_URL}/${ARTIFACT_FILE}"
ARTIFACT_PATH="${SANDBOX_DIR}/${ARTIFACT_FILE}"

ok "版本: ${VERSION}  产物: ${ARTIFACT_FILE}"

# 幂等：版本未变且服务在跑
if [[ "$VERSION" == "$LAST_VERSION" ]]; then
    if compose_cmd -f "$COMPOSE_FILE" ps --services --filter status=running 2>/dev/null | grep -q biz-service; then
        ok "版本未变 (${VERSION})，服务运行中"
        compose_cmd -f "$COMPOSE_FILE" ps
        exit 0
    fi
fi

if [[ -f "$ARTIFACT_PATH" && -s "$ARTIFACT_PATH" ]] && tar -tzf "$ARTIFACT_PATH" &>/dev/null; then
    ok "产物已缓存: ${ARTIFACT_FILE} ($(du -sh "$ARTIFACT_PATH" | cut -f1))，跳过下载"
else
    [[ -f "$ARTIFACT_PATH" ]] && { warn "已有文件损坏，重新下载"; rm -f "$ARTIFACT_PATH"; }
    scm_download "$ARTIFACT_URL" "$ARTIFACT_PATH"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — 解压 & 分析
# ══════════════════════════════════════════════════════════════════════════════
step "分析业务服务"

EXTRACT_DIR="${SANDBOX_DIR}/extracted"
rm -rf "$EXTRACT_DIR" && mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARTIFACT_PATH" -C "$EXTRACT_DIR"
ok "解压完成"

BIN_NAME=$(find "$EXTRACT_DIR/bin" -maxdepth 1 -type f -executable 2>/dev/null | head -1 | xargs -r basename || true)
[[ -n "$BIN_NAME" ]] || BIN_NAME=$(echo "$PSM" | awk -F. '{print $NF}')
ok "二进制: $BIN_NAME"

[[ -f "$EXTRACT_DIR/bootstrap.sh" ]] && ok "bootstrap.sh 存在" || warn "未找到 bootstrap.sh"

# 扫描下游依赖
DOWNSTREAM_PSMS=()
CONFIG_FILE=$(find "$EXTRACT_DIR/conf" -name "*.yaml" 2>/dev/null | head -1 || true)
if [[ -n "$CONFIG_FILE" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && DOWNSTREAM_PSMS+=("$line")
    done < <(grep -oE 'psm: ["\x27]?[a-z0-9._*]+' "$CONFIG_FILE" 2>/dev/null | \
             awk '{print $2}' | tr -d "\"'" | sort -u || true)
fi

NEED_MYSQL=false; NEED_ES=false; NEED_REDIS=false
for psm in "${DOWNSTREAM_PSMS[@]:-}"; do
    [[ "$psm" == toutiao.mysql.* ]] && NEED_MYSQL=true
    [[ "$psm" == byte.es.*       ]] && NEED_ES=true
    [[ "$psm" == toutiao.redis.* ]] && NEED_REDIS=true
done
ok "依赖: MySQL=${NEED_MYSQL} ES=${NEED_ES} Redis=${NEED_REDIS}, 下游PSM: ${#DOWNSTREAM_PSMS[@]} 个"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — 构建 & 启动业务服务
# ══════════════════════════════════════════════════════════════════════════════
step "启动业务服务"

# entrypoint-biz.sh
cat > "${SANDBOX_DIR}/entrypoint-biz.sh" << 'ENTRY'
#!/bin/sh
set -e
echo "[entrypoint-biz] starting: $@"
exec "$@"
ENTRY
chmod +x "${SANDBOX_DIR}/entrypoint-biz.sh"

CMD_LINE="./bootstrap.sh"
[[ ! -f "$EXTRACT_DIR/bootstrap.sh" ]] && CMD_LINE="./bin/${BIN_NAME}"

BIZ_BASE_IMAGE="${BIZ_BASE_IMAGE:-hub.byted.org/x86_64/base/ubuntu.jammy.tce_service:dbb61d79c899a3d415dd9b6a887fbfcb}"

# 预拉基础镜像（避免每次 build 都拉）
if docker image inspect "$BIZ_BASE_IMAGE" &>/dev/null; then
    ok "基础镜像已存在: ${BIZ_BASE_IMAGE##*/}"
else
    info "拉取基础镜像: ${BIZ_BASE_IMAGE}..."
    docker pull "$BIZ_BASE_IMAGE" || die "基础镜像拉取失败"
fi

# .dockerignore 减小 build context（排除解压目录和其他产物）
cat > "${SANDBOX_DIR}/.dockerignore" << 'DIGNORE'
extracted/
*.yaml
.build-state
.dockerignore
DIGNORE

cat > "${SANDBOX_DIR}/Dockerfile.biz" << DOCKERFILE
FROM ${BIZ_BASE_IMAGE}
WORKDIR /app
ADD ${ARTIFACT_FILE} ./
RUN find bin -type f -exec chmod +x {} \\; \\
    && (chmod +x bootstrap.sh 2>/dev/null || true)
COPY entrypoint-biz.sh /entrypoint-biz.sh
RUN chmod +x /entrypoint-biz.sh
EXPOSE 8888 18888
ENTRYPOINT ["/entrypoint-biz.sh"]
CMD ["${CMD_LINE}"]
DOCKERFILE

# 业务服务 compose（独立，不依赖 mock-mesh）
BIZ_COMPOSE="${SANDBOX_DIR}/docker-compose-biz.yaml"
DEPENDS_BIZ="["
[[ "$NEED_MYSQL" == "true" ]] && DEPENDS_BIZ="${DEPENDS_BIZ}mysql, "
[[ "$NEED_ES"    == "true" ]] && DEPENDS_BIZ="${DEPENDS_BIZ}elasticsearch, "
[[ "$NEED_REDIS" == "true" ]] && DEPENDS_BIZ="${DEPENDS_BIZ}redis, "
DEPENDS_BIZ="${DEPENDS_BIZ%%, }]"
[[ "$DEPENDS_BIZ" == "[]" ]] && DEPENDS_BIZ=""

cat > "$BIZ_COMPOSE" << BIZYAML
version: "3.9"
services:
  biz-service:
    build:
      context: ${SANDBOX_DIR}
      dockerfile: ${SANDBOX_DIR}/Dockerfile.biz
    ports:
      - "8888:8888"
      - "18888:18888"
    environment:
      - PSM=${PSM}
      - KITEX_LOG_DIR=/tmp/logs
      - RUNTIME_LOGDIR=/tmp/logs
    restart: unless-stopped
BIZYAML

ok "业务服务配置生成完成"

info "构建业务服务镜像..."
compose_cmd -f "$BIZ_COMPOSE" build biz-service

info "启动业务服务..."
compose_cmd -f "$BIZ_COMPOSE" up -d

sleep 5
compose_cmd -f "$BIZ_COMPOSE" ps

ok "业务服务已启动"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — 拉取 mock-mesh & 启动 mock 组件
# ══════════════════════════════════════════════════════════════════════════════
step "拉取 mock-mesh"

if [[ -d "${MOCK_MESH_DIR}/.git" ]]; then
    info "更新 mock-mesh..."
    git -C "$MOCK_MESH_DIR" pull --quiet
else
    info "克隆 mock-mesh..."
    git clone --depth=50 "$GIT_REPO_URL" "$MOCK_MESH_DIR"
fi
CURR_MOCK_HASH=$(git -C "$MOCK_MESH_DIR" rev-parse HEAD)
ok "mock-mesh: ${CURR_MOCK_HASH:0:8}"

# mock-config-extra.yaml
cat > "${SANDBOX_DIR}/mock-config-extra.yaml" << YAML
# 自动生成 — ${PSM} @ ${VERSION}
default_action: passthrough
rules:
YAML
for psm in "${DOWNSTREAM_PSMS[@]:-}"; do
    case "$psm" in
        toutiao.mysql.*|toutiao.redis.*|byte.es.*) ;;
        *)
            cat >> "${SANDBOX_DIR}/mock-config-extra.yaml" << YAML
  - name: "$(echo "$psm" | tr '.' '-')"
    psm: "${psm}"
    action: mock
    protocol: kitex
YAML
            ;;
    esac
done

# 完整 compose（业务 + mock 全套）
cat > "$COMPOSE_FILE" << COMPOSEYAML
version: "3.9"
services:
  mock-proxy:
    build:
      context: ${MOCK_MESH_DIR}
      dockerfile: deploy/Dockerfile.proxy
      args:
        - GOPROXY=${GOPROXY}
    user: "1337:1337"
    ports:
      - "19999:19999"
      - "8600:8600"
      - "28080:28080"
    volumes:
      - ${MOCK_MESH_DIR}/configs:/etc/mock-mesh/configs:ro
      - ${MOCK_MESH_DIR}/idl:/etc/mock-mesh/idl:ro
      - ${SANDBOX_DIR}/mock-config-extra.yaml:/etc/mock-mesh/configs/mock-config-extra.yaml:ro
    environment:
      - MOCK_CONFIG=/etc/mock-mesh/configs/mock-config.yaml
      - MOCK_RULES_DIR=/etc/mock-mesh/configs/mock-rules
      - MOCK_KITEX_ADDR=127.0.0.1:18001
      - MOCK_GRPC_ADDR=127.0.0.1:18002
      - MOCK_HTTP_ADDR=127.0.0.1:18003
    restart: unless-stopped

  kitex-mock:
    build:
      context: ${MOCK_MESH_DIR}
      dockerfile: deploy/Dockerfile.kitex-mock
      args:
        - GOPROXY=${GOPROXY}
    network_mode: "service:mock-proxy"
    volumes:
      - ${MOCK_MESH_DIR}/configs:/etc/mock-mesh/configs:ro
      - ${MOCK_MESH_DIR}/idl:/etc/mock-mesh/idl:ro
    depends_on: [mock-proxy]
    restart: unless-stopped

  http-mock:
    build:
      context: ${MOCK_MESH_DIR}
      dockerfile: deploy/Dockerfile.http-mock
      args:
        - GOPROXY=${GOPROXY}
    network_mode: "service:mock-proxy"
    volumes:
      - ${MOCK_MESH_DIR}/configs:/etc/mock-mesh/configs:ro
    depends_on: [mock-proxy]
    restart: unless-stopped

  biz-service:
    build:
      context: ${SANDBOX_DIR}
      dockerfile: ${SANDBOX_DIR}/Dockerfile.biz
    network_mode: "service:mock-proxy"
    cap_add: [NET_ADMIN]
    depends_on: [mock-proxy, kitex-mock, http-mock]
    environment:
      - PSM=${PSM}
      - CONSUL_HTTP_ADDR=127.0.0.1:8600
      - MESH_NEGOTIATE_ADDR=
      - SERVICE_MESH_EGRESS_ADDR=
      - KITEX_LOG_DIR=/tmp/logs
      - RUNTIME_LOGDIR=/tmp/logs
      - PROXY_PORT=19999
    restart: unless-stopped
COMPOSEYAML

if [[ "$NEED_MYSQL" == "true" ]]; then cat >> "$COMPOSE_FILE" << 'MYSQL'

  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: mock123
    ports: ["3306:3306"]
    volumes: [mysql-data:/var/lib/mysql]
    restart: unless-stopped
MYSQL
fi

if [[ "$NEED_REDIS" == "true" ]]; then cat >> "$COMPOSE_FILE" << 'REDIS'

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
    restart: unless-stopped
REDIS
fi

if [[ "$NEED_ES" == "true" ]]; then cat >> "$COMPOSE_FILE" << 'ES'

  elasticsearch:
    image: elasticsearch:8.11.4
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
    ports: ["9200:9200"]
    volumes: [es-data:/usr/share/elasticsearch/data]
    restart: unless-stopped
ES
fi

if [[ "$NEED_MYSQL" == "true" || "$NEED_ES" == "true" ]]; then
    echo "" >> "$COMPOSE_FILE"
    echo "volumes:" >> "$COMPOSE_FILE"
    [[ "$NEED_MYSQL" == "true" ]] && echo "  mysql-data:" >> "$COMPOSE_FILE"
    [[ "$NEED_ES"    == "true" ]] && echo "  es-data:"    >> "$COMPOSE_FILE"
fi

ok "完整沙箱配置生成完成"

info "编译 mock-mesh 镜像..."
compose_cmd -f "$COMPOSE_FILE" build mock-proxy kitex-mock http-mock

info "切换到完整沙箱模式（停止独立业务服务，启动全套）..."
compose_cmd -f "$BIZ_COMPOSE" down 2>/dev/null || true
compose_cmd -f "$COMPOSE_FILE" up -d

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — 验证
# ══════════════════════════════════════════════════════════════════════════════
step "验证服务"

info "等待服务就绪..."
sleep 5
compose_cmd -f "$COMPOSE_FILE" ps

# 保存状态
cat > "$STATE_FILE" << STATE
VERSION=${VERSION}
MOCK_HASH=${CURR_MOCK_HASH}
BUILT_AT=$(date -Iseconds)
PSM=${PSM}
ARTIFACT=${ARTIFACT_FILE}
STATE

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
echo "" >&2
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════" >&2
echo " 沙箱就绪！" >&2
echo " PSM:     ${PSM}" >&2
echo " Version: ${VERSION}" >&2
echo -e "══════════════════════════════════════════════${NC}" >&2
echo "" >&2
echo -e "  Admin UI   → ${CYAN}http://${HOST_IP}:28080${NC}" >&2
echo -e "  Consul     → ${CYAN}http://${HOST_IP}:8600/v1/health/service/<psm>${NC}" >&2
echo "" >&2
echo "  查看日志:  docker compose -f ${COMPOSE_FILE} logs -f biz-service" >&2
echo "  停止沙箱:  docker compose -f ${COMPOSE_FILE} down" >&2
echo "" >&2
