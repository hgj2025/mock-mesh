#!/bin/bash
# install.sh — mock-mesh 一键安装
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/hgj2025/mock-mesh/main/install.sh | \
#       bash -s -- --artifact <prefix> --version <ver>
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
#   NPM_REGISTRY    — npm 镜像源（安装 bytedcli 时使用）

set -euo pipefail
IFS=$'\n\t'

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[·]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
step()  { echo -e "\n${BOLD}${CYAN}━━ $* ━━${NC}"; }
die()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── 参数解析 ──────────────────────────────────────────────────────────────────
ARTIFACT_PREFIX=""
VERSION=""

usage() {
    cat <<'USAGE'
用法: bash install.sh --artifact <prefix> --version <ver>

参数:
  --artifact   SCM 产物前缀（仓库路径 / 换 .）
  --version    产物版本号

环境变量:
  SCM_JWT_TOKEN   JWT token（跳过 bytedcli）
  SCM_USERNAME    下载用户名
  SCM_BASE_URL    SCM 产物仓库地址
  NPM_REGISTRY    npm 镜像源（安装 bytedcli 用）

示例:
  # bytedcli 自动获取 token
  bytedcli auth login
  bash install.sh --artifact douyin.admin.admin_platform --version 1.0.1.852

  # 手动传 token
  SCM_JWT_TOKEN="eyJ..." bash install.sh --artifact douyin.admin.admin_platform --version 1.0.1.852
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --artifact)   ARTIFACT_PREFIX="$2";  shift 2 ;;
        --version)    VERSION="$2";          shift 2 ;;
        --help|-h)    usage ;;
        *) die "未知参数: $1" ;;
    esac
done

[[ -n "$ARTIFACT_PREFIX" ]] || die "缺少 --artifact 参数\n\n$(usage)"
[[ -n "$VERSION"         ]] || die "缺少 --version 参数\n\n$(usage)"

# ── 常量 ──────────────────────────────────────────────────────────────────────
SCM_BASE_URL="${SCM_BASE_URL:-}"
TOKEN_CACHE="${HOME}/.mock-mesh/scm-token"
DOWNLOAD_DIR="${HOME}/.mock-mesh/downloads"

# ══════════════════════════════════════════════════════════════════════════════
# JWT 认证（自包含）
# ══════════════════════════════════════════════════════════════════════════════

# 查找 bytedcli
_find_cli() {
    command -v bytedcli &>/dev/null && { command -v bytedcli; return; }
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    for d in "$nvm_dir"/versions/node/*/bin/bytedcli; do
        [[ -x "$d" ]] && { echo "$d"; return; }
    done
    return 1
}

# 确保 bytedcli 已登录
_ensure_login() {
    local cli="$1"
    if "$cli" auth status --json 2>/dev/null | grep -q '"loggedIn":true'; then
        return 0
    fi
    info "需要 SSO 登录，将打开浏览器..."
    "$cli" auth login >&2
    "$cli" auth status --json 2>/dev/null | grep -q '"loggedIn":true' || {
        die "SSO 登录失败，请先执行: bytedcli auth login"
    }
}

# 获取用户名（邮箱前缀）
_get_username() {
    [[ -n "${SCM_USERNAME:-}" ]] && { echo "$SCM_USERNAME"; return; }

    if [[ -f "$TOKEN_CACHE" ]]; then
        local u; u=$(grep "^USERNAME=" "$TOKEN_CACHE" 2>/dev/null | cut -d= -f2-)
        [[ -n "$u" ]] && { echo "$u"; return; }
    fi

    local cli; cli=$(_find_cli 2>/dev/null) || true
    if [[ -n "$cli" ]]; then
        local email; email=$("$cli" auth userinfo --json 2>/dev/null | grep -o '"email":"[^"]*"' | cut -d'"' -f4 || true)
        [[ -n "$email" ]] && { echo "${email%%@*}"; return; }
    fi

    local ge; ge=$(git config user.email 2>/dev/null || true)
    if [[ -n "$ge" ]]; then
        local guess="${ge%%@*}"
        read -rp "  用户名 (邮箱前缀) [${guess}]: " input
        echo "${input:-$guess}"
        return
    fi

    read -rp "  请输入用户名 (邮箱前缀): " input
    [[ -n "$input" ]] || die "用户名不能为空"
    echo "$input"
}

# 获取 JWT token
_get_token() {
    # 1. 环境变量
    [[ -n "${SCM_JWT_TOKEN:-}" ]] && { echo "$SCM_JWT_TOKEN"; return; }

    # 2. 缓存（20h 有效）
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

    # 3. bytedcli
    local cli; cli=$(_find_cli 2>/dev/null) || true
    if [[ -n "$cli" ]]; then
        _ensure_login "$cli"
        local t; t=$("$cli" auth get-bytecloud-jwt-token 2>/dev/null || true)
        if [[ -n "$t" && ${#t} -gt 20 ]]; then
            ok "JWT token 获取成功 (via bytedcli, ${#t} chars)"
            echo "$t"
            return
        fi
        warn "bytedcli get-bytecloud-jwt-token 返回为空"
    fi

    # 4. 手动输入
    echo "" >&2
    echo -e "  ${BOLD}需要 JWT Token 认证${NC}" >&2
    echo -e "  获取: 安装 bytedcli 后执行 ${BOLD}bytedcli auth login${NC}" >&2
    echo "" >&2
    read -rsp "  请粘贴 JWT Token (输入不可见): " t; echo "" >&2
    [[ -n "$t" ]] || die "Token 不能为空"
    echo "$t"
}

# 保存认证缓存
_save_cache() {
    mkdir -p "$(dirname "$TOKEN_CACHE")"
    cat > "$TOKEN_CACHE" <<CACHE
USERNAME=$1
TOKEN=$2
TIMESTAMP=$(date +%s)
CACHE
    chmod 600 "$TOKEN_CACHE"
}

# 带认证下载
_authed_curl() {
    local url="$1" output="$2" token="$3" username="$4"
    curl -sL \
        -H "x-jwt-token: ${token}" \
        -H "x-platform-proxy-user: ${username}" \
        -o "$output" -w "%{http_code}" \
        "$url" 2>/dev/null
}

# SCM 产物下载（含重试）
scm_download() {
    local url="$1" output="$2"
    local username token http_code

    username=$(_get_username) || return 1
    token=$(_get_token) || return 1

    info "下载: $(basename "$url")"
    info "用户: ${username}"

    http_code=$(_authed_curl "$url" "$output" "$token" "$username")

    # 401/403 → 清缓存重试
    if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        warn "Token 无效 (HTTP ${http_code})，重新获取..."
        rm -f "$TOKEN_CACHE"
        unset SCM_JWT_TOKEN 2>/dev/null || true
        token=$(_get_token) || return 1
        http_code=$(_authed_curl "$url" "$output" "$token" "$username")
    fi

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]] && [[ -f "$output" && -s "$output" ]]; then
        _save_cache "$username" "$token"
        ok "下载成功: $(du -sh "$output" | cut -f1)"
        return 0
    else
        rm -f "$output"
        die "下载失败 (HTTP ${http_code})"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — 预检
# ══════════════════════════════════════════════════════════════════════════════
step "预检"

[[ "$(uname -m)" == "x86_64" ]] || die "仅支持 x86_64，当前: $(uname -m)"

if [[ -z "$SCM_BASE_URL" ]]; then
    die "请设置 SCM_BASE_URL 环境变量\n  示例: export SCM_BASE_URL=https://your-scm-host/repository/scm"
fi

ok "产物前缀: ${ARTIFACT_PREFIX}"
ok "版本:     ${VERSION}"
ok "SCM:      ${SCM_BASE_URL}"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — 安装 bytedcli（前置依赖）
# ══════════════════════════════════════════════════════════════════════════════
step "检查 bytedcli"

NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"

install_bytedcli() {
    if ! command -v node &>/dev/null; then
        info "安装 Node.js..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq 2>/dev/null
            apt-get install -y --no-install-recommends nodejs npm 2>/dev/null || {
                curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
                apt-get install -y nodejs
            }
        elif command -v yum &>/dev/null; then
            curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - 2>/dev/null
            yum install -y nodejs
        else
            die "无法自动安装 Node.js，请手动安装后重试"
        fi
        command -v node &>/dev/null || die "Node.js 安装失败"
        ok "Node.js: $(node --version)"
    fi
    info "安装 bytedcli..."
    NPM_CONFIG_REGISTRY="$NPM_REGISTRY" \
        npm install -g @bytedance-dev/bytedcli@latest 2>/dev/null || \
        die "bytedcli 安装失败\n  请手动安装: NPM_CONFIG_REGISTRY=<your-npm-registry> npm install -g @bytedance-dev/bytedcli@latest"
}

if _find_cli &>/dev/null; then
    ok "bytedcli: $(_find_cli)"
else
    install_bytedcli
    _find_cli &>/dev/null || die "bytedcli 安装后仍无法找到，请检查 PATH"
    ok "bytedcli: $(_find_cli)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — 下载 SCM 产物
# ══════════════════════════════════════════════════════════════════════════════
step "下载 SCM 产物"

mkdir -p "$DOWNLOAD_DIR"

ARTIFACT_FILE="${ARTIFACT_PREFIX}_${VERSION}.tar.gz"
ARTIFACT_URL="${SCM_BASE_URL}/${ARTIFACT_FILE}"
ARTIFACT_PATH="${DOWNLOAD_DIR}/${ARTIFACT_FILE}"

ok "产物: ${ARTIFACT_FILE}"
ok "URL:  ${ARTIFACT_URL}"

if [[ -f "$ARTIFACT_PATH" && -s "$ARTIFACT_PATH" ]]; then
    ok "产物已缓存: $(du -sh "$ARTIFACT_PATH" | cut -f1)"
else
    scm_download "$ARTIFACT_URL" "$ARTIFACT_PATH"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — 验证产物
# ══════════════════════════════════════════════════════════════════════════════
step "验证产物"

# 检查是否为有效 tar.gz
if ! tar -tzf "$ARTIFACT_PATH" &>/dev/null; then
    warn "文件不是有效的 tar.gz，可能下载了错误内容"
    info "文件前 200 字节:"
    head -c 200 "$ARTIFACT_PATH" | cat -v
    echo ""
    die "产物验证失败"
fi

# 列出内容概要
FILE_COUNT=$(tar -tzf "$ARTIFACT_PATH" | wc -l)
ok "有效 tar.gz，包含 ${FILE_COUNT} 个文件"

info "目录结构（前 20 项）:"
tar -tzf "$ARTIFACT_PATH" | head -20

# 检查是否有 bin/ 目录
if tar -tzf "$ARTIFACT_PATH" | grep -q '^bin/'; then
    ok "包含 bin/ 目录"
    info "可执行文件:"
    tar -tzf "$ARTIFACT_PATH" | grep '^bin/' | head -5
else
    warn "未找到 bin/ 目录"
fi

# 检查 bootstrap.sh
if tar -tzf "$ARTIFACT_PATH" | grep -q 'bootstrap.sh'; then
    ok "包含 bootstrap.sh"
else
    warn "未找到 bootstrap.sh"
fi

echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════"
echo " SCM 产物下载验证通过！"
echo " 产物: ${ARTIFACT_FILE}"
echo " 大小: $(du -sh "$ARTIFACT_PATH" | cut -f1)"
echo " 路径: ${ARTIFACT_PATH}"
echo -e "══════════════════════════════════════════════${NC}"
echo ""
