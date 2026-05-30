#!/bin/bash

# ============================================
# Panbox-Search - 网盘资源管理系统
# 一键部署脚本
# ============================================

VERSION="2.0.0"
SCRIPT_VERSION="2026.05.30.1"
AUTHOR="Kokojacket"
SELF_UPDATE_RESTARTED_ENV="PANBOX_SEARCH_SCRIPT_SELF_UPDATED"
SCRIPT_URLS=(
    "https://gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search.sh"
    "https://hk.gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search.sh"
    "https://cdn.gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search.sh"
    "https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search.sh"
    "https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search.sh"
)

# 设置错误处理
set -e

# 清理函数
cleanup() {
    local exit_code=$?
    exit $exit_code
}

trap cleanup EXIT
trap 'error "发生错误，脚本退出" >&2' ERR

# 主目录
PANBOX_DIR="/opt/panbox-search"
NEED_SUDO=false
COMPOSE_CMD=""
JUST_INSTALLED=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# 格式化函数
print_line() {
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_title() {
    local title="$1"
    print_line
    echo -e "${GREEN}                            ${title}${NC}"
    print_line
}

get_script_path() {
    if [ ! -f "$0" ]; then
        return 1
    fi

    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)" || return 1
    printf "%s/%s\n" "$script_dir" "$(basename "$0")"
}

extract_script_version() {
    local script_file="$1"
    grep -m1 '^SCRIPT_VERSION=' "$script_file" | sed -E 's/^SCRIPT_VERSION="?([^"[:space:]]+)"?.*/\1/'
}

download_with_retry() {
    local output_file="$1"
    shift

    local max_retries=3
    local retry_delay=1
    local source_index=1
    local total_sources=$#

    for url in "$@"; do
        local source_name="GitHub 原始地址"
        if [[ "$url" == *"hk.gh-proxy.org"* ]]; then
            source_name="香港代理"
        elif [[ "$url" == *"cdn.gh-proxy.org"* ]]; then
            source_name="CDN 代理"
        elif [[ "$url" == *"edgeone.gh-proxy.org"* ]]; then
            source_name="EdgeOne 代理"
        elif [[ "$url" == *"gh-proxy.org"* ]]; then
            source_name="gh-proxy.org 代理"
        fi

        local attempt=1
        while [ $attempt -le $max_retries ]; do
            info "[$source_index/$total_sources] 下载尝试 (${attempt}/${max_retries}): ${source_name}"
            if curl -4 -fSsL --connect-timeout 3 --max-time 8 "$url" -o "$output_file"; then
                return 0
            fi

            if [ $attempt -lt $max_retries ]; then
                warning "下载超时或失败，${retry_delay} 秒后重试..."
                sleep $retry_delay
            fi
            attempt=$((attempt + 1))
        done

        warning "当前地址连续失败，切换下一个下载源..."
        source_index=$((source_index + 1))
    done

    return 1
}

self_update_script() {
    local script_path="$1"
    local new_script="$2"
    local backup_path="${script_path}.bak"
    shift 2

    if ! bash -n "$new_script"; then
        error "远端脚本语法检查失败，已取消自更新"
        return 1
    fi

    cp "$script_path" "$backup_path" || {
        error "备份当前脚本失败，无法继续自更新"
        return 1
    }

    chmod +x "$new_script"
    if ! mv "$new_script" "$script_path"; then
        error "替换当前脚本失败，可能没有写入权限"
        return 1
    fi

    success "脚本已更新，旧版本备份为：$backup_path"
    info "正在使用最新脚本重新启动..."
    export "$SELF_UPDATE_RESTARTED_ENV=1"
    exec "$script_path" "$@"
}

check_and_force_self_update() {
    if [ "${!SELF_UPDATE_RESTARTED_ENV:-0}" = "1" ]; then
        return 0
    fi

    local script_path
    script_path="$(get_script_path)" || {
        error "当前脚本不是从本地文件运行，无法执行强制自更新"
        exit 1
    }

    local tmp_file
    tmp_file="$(mktemp)"

    info "检查部署脚本更新..."
    if ! download_with_retry "$tmp_file" "${SCRIPT_URLS[@]}"; then
        rm -f "$tmp_file"
        error "脚本更新检查失败，已停止执行以避免使用过期脚本"
        exit 1
    fi

    local remote_version
    remote_version="$(extract_script_version "$tmp_file")"
    if [ -z "$remote_version" ]; then
        rm -f "$tmp_file"
        error "无法识别远端脚本版本，已停止执行以避免使用过期脚本"
        exit 1
    fi

    if [ "$remote_version" = "$SCRIPT_VERSION" ]; then
        rm -f "$tmp_file"
        success "部署脚本已是最新版本：$SCRIPT_VERSION"
        return 0
    fi

    warning "检测到部署脚本更新：当前 $SCRIPT_VERSION → 最新 $remote_version"
    if ! self_update_script "$script_path" "$tmp_file" "$@"; then
        rm -f "$tmp_file"
        error "脚本自更新失败，已停止执行以避免使用过期脚本"
        exit 1
    fi
}

# Docker 权限检查
check_docker_permissions() {
    local current_user=$(whoami)
    log "当前用户: $current_user"

    if groups | grep -q docker; then
        log "用户已在 docker 组中，可直接执行 docker 命令"
        NEED_SUDO=false
        return 0
    fi

    if docker info >/dev/null 2>&1; then
        log "可直接执行 docker 命令"
        NEED_SUDO=false
        return 0
    fi

    if sudo docker info >/dev/null 2>&1; then
        log "使用 sudo 执行 docker 命令"
        NEED_SUDO=true
        return 0
    fi

    error "无法执行 docker 命令，请确保用户有适当的权限"
    error "可以尝试执行: sudo usermod -aG docker $current_user"
    return 1
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if command -v netstat &> /dev/null; then
        netstat -tuln | grep -q ":${port} "
        return $?
    elif command -v ss &> /dev/null; then
        ss -tuln | grep -q ":${port} "
        return $?
    elif command -v lsof &> /dev/null; then
        lsof -i ":${port}" &> /dev/null
        return $?
    else
        if command -v nc &> /dev/null; then
            nc -z localhost ${port} &> /dev/null
            return $?
        fi
        (echo >/dev/tcp/localhost/${port}) &> /dev/null
        return $?
    fi
}

# 自动分配可用端口
find_available_port() {
    local start_port=8888
    local max_attempts=100
    local current_port=$start_port

    for ((i=0; i<$max_attempts; i++)); do
        if ! check_port $current_port; then
            echo $current_port
            return 0
        fi
        current_port=$((current_port + 1))
    done

    error "无法找到可用端口 (已尝试 ${start_port}-$((start_port + max_attempts - 1)))" >&2
    exit 1
}

# 检查 Docker 是否安装
check_docker() {
    info "检查 Docker 是否安装..."
    if ! command -v docker &> /dev/null; then
        error "Docker 未安装，请先安装 Docker"
        info "安装命令: curl -fsSL https://get.docker.com | sh"
        exit 1
    fi
    success "Docker 已安装: $(docker --version)"
}

# 检查 Docker Compose 是否安装
check_docker_compose() {
    info "检查 Docker Compose 是否安装..."
    if command -v docker-compose &> /dev/null; then
        success "Docker Compose 已安装: $(docker-compose --version)"
        COMPOSE_CMD="docker-compose"
    elif docker compose version &> /dev/null; then
        success "Docker Compose 已安装: $(docker compose version)"
        COMPOSE_CMD="docker compose"
    elif [ -f "/usr/local/bin/docker-compose" ]; then
        success "Docker Compose 已安装: /usr/local/bin/docker-compose"
        COMPOSE_CMD="/usr/local/bin/docker-compose"
    else
        error "Docker Compose 未安装"
        info "安装命令: "
        info "  方式1: apt-get install docker-compose-plugin"
        info "  方式2: curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose"
        exit 1
    fi
}

# 检查是否已经安装
check_installed() {
    if [ ! -d "${PANBOX_DIR}" ] || [ ! -f "${PANBOX_DIR}/docker-compose.yml" ]; then
        return 1
    fi

    if [ -f "${PANBOX_DIR}/.env" ]; then
        return 0  # 已安装（配置文件存在）
    fi

    if ! command -v docker &> /dev/null; then
        return 1
    fi

    if ! check_docker_permissions > /dev/null 2>&1; then
        return 1
    fi

    if [ -z "$COMPOSE_CMD" ] && ! check_docker_compose > /dev/null 2>&1; then
        return 1
    fi

    cd "${PANBOX_DIR}"
    if [ "$NEED_SUDO" = true ]; then
        sudo $COMPOSE_CMD ps -q 2>/dev/null | grep -q .
    else
        $COMPOSE_CMD ps -q 2>/dev/null | grep -q .
    fi
}

# 检测当前服务已使用的端口（用于补全旧 .env 配置）
detect_existing_app_port() {
    local current_port=""

    if [ ! -f "${PANBOX_DIR}/docker-compose.yml" ]; then
        return 1
    fi

    if [ -z "$COMPOSE_CMD" ] && ! check_docker_compose > /dev/null 2>&1; then
        return 1
    fi

    cd "${PANBOX_DIR}"
    if [ "$NEED_SUDO" = true ]; then
        current_port=$(sudo $COMPOSE_CMD port app 80 2>/dev/null | head -n 1 | awk -F: '{print $NF}')
    else
        current_port=$($COMPOSE_CMD port app 80 2>/dev/null | head -n 1 | awk -F: '{print $NF}')
    fi

    if [[ "$current_port" =~ ^[0-9]+$ ]]; then
        echo "$current_port"
        return 0
    fi

    return 1
}

# 创建必要的目录
create_directories() {
    info "创建数据目录..."

    # 检查并设置 /opt 目录权限
    if [ ! -d "/opt" ]; then
        log "创建 /opt 目录..."
        sudo mkdir -p /opt
    fi

    # 确保 /opt 目录有足够权限
    if [ ! -w "/opt" ]; then
        log "设置 /opt 目录权限..."
        sudo chmod 755 /opt
    fi

    # 创建项目目录
    if [ -w "/opt" ]; then
        mkdir -p "${PANBOX_DIR}"
    else
        log "使用 sudo 创建项目目录..."
        sudo mkdir -p "${PANBOX_DIR}"
        sudo chown $(whoami):$(whoami) "${PANBOX_DIR}"
    fi

    mkdir -p "${PANBOX_DIR}/app/runtime"
    mkdir -p "${PANBOX_DIR}/app/data"
    mkdir -p "${PANBOX_DIR}/app/uploads"
    mkdir -p "${PANBOX_DIR}/app/install"
    mkdir -p "${PANBOX_DIR}/mysql"
    mkdir -p "${PANBOX_DIR}/redis"

    chmod -R 777 "${PANBOX_DIR}"

    success "数据目录创建完成"
    info "  - 工作目录: ${PANBOX_DIR}/"
    info "  - 应用数据: ${PANBOX_DIR}/app/"
    info "  - License 数据: ${PANBOX_DIR}/app/data/"
    info "  - 数据库数据: ${PANBOX_DIR}/mysql/"
    info "  - Redis 数据: ${PANBOX_DIR}/redis/"
}

# 下载 docker-compose.yml
download_compose_file() {
    info "检查 docker-compose.yml 文件..."

    cd "${PANBOX_DIR}"

    if [ -f "docker-compose.yml" ]; then
        warning "docker-compose.yml 文件已存在"
        if [ ! -t 0 ] || [ "${AUTO_INSTALL}" = "true" ]; then
            info "非交互模式，强制更新 docker-compose.yml..."
        else
            read -p "是否覆盖现有文件？(Y/n) [默认: y]: " -n 1 -r OVERWRITE </dev/tty
            echo
            if [[ $OVERWRITE =~ ^[Nn]$ ]]; then
                info "使用现有的 docker-compose.yml 文件"
                return 0
            fi
        fi
    fi

    info "下载 docker-compose.yml 文件..."

    # 多个备用下载源（国内加速镜像 + GitHub 原始地址）
    local compose_urls=(
        "https://gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/docker-compose.yml"
        "https://hk.gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/docker-compose.yml"
        "https://cdn.gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/docker-compose.yml"
        "https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/docker-compose.yml"
        "https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/docker-compose.yml"
    )

    local max_retries=3
    local retry_delay=1
    local source_index=1
    local total_sources=${#compose_urls[@]}

    for compose_url in "${compose_urls[@]}"; do
        local source_name="GitHub 原始地址"
        if [[ "$compose_url" == *"hk.gh-proxy.org"* ]]; then
            source_name="香港代理"
        elif [[ "$compose_url" == *"cdn.gh-proxy.org"* ]]; then
            source_name="CDN 代理"
        elif [[ "$compose_url" == *"edgeone.gh-proxy.org"* ]]; then
            source_name="EdgeOne 代理"
        elif [[ "$compose_url" == *"gh-proxy.org"* ]]; then
            source_name="gh-proxy.org 代理"
        fi

        local attempt=1
        while [ $attempt -le $max_retries ]; do
            info "[$source_index/$total_sources] 下载尝试 (${attempt}/${max_retries}): ${source_name}"
            if curl -4 -fSsL --connect-timeout 3 --max-time 8 "$compose_url" -o docker-compose.yml; then
                success "docker-compose.yml 下载完成"
                return 0
            fi

            if [ $attempt -lt $max_retries ]; then
                warning "下载超时或失败，${retry_delay} 秒后重试..."
                sleep $retry_delay
            fi
            attempt=$((attempt + 1))
        done

        warning "当前地址连续失败，切换下一个下载源..."
        source_index=$((source_index + 1))
    done

    error "docker-compose.yml 下载失败（已尝试 ${total_sources} 个下载源，每源重试 ${max_retries} 次）"
    exit 1
}

# 配置环境变量
configure_env() {
    info "配置环境变量..."
    cd "${PANBOX_DIR}"

    # 检查 .env 文件是否已存在
    if [ -f ".env" ]; then
        warning ".env 配置文件已存在"
        local env_updated=false

        # 检查是否缺少 APP_PORT 配置
        if ! grep -q "^APP_PORT" .env; then
            warning "检测到 .env 缺少 APP_PORT 配置，正在补全..."
            APP_PORT=$(detect_existing_app_port || true)
            if [ -n "$APP_PORT" ]; then
                info "检测到当前服务正在使用端口: ${APP_PORT}"
            else
                info "未检测到当前服务端口，正在查找可用端口..."
                APP_PORT=$(find_available_port)
                success "找到可用端口: ${APP_PORT}"
            fi

            echo "APP_PORT=${APP_PORT}" > .env.tmp
            echo "" >> .env.tmp
            cat .env >> .env.tmp
            mv .env.tmp .env
            success "已补全 APP_PORT=${APP_PORT}"
            env_updated=true
        fi

        # 检查是否缺少缓存配置
        if ! grep -q "^CACHE_DRIVER" .env; then
            warning "检测到 .env 缺少缓存配置，正在补全 Redis 默认配置..."
            cat >> .env <<EOF

# ==================== 缓存配置 ====================
# Docker 部署默认使用 Redis；如需回退文件缓存，可改为 file
CACHE_DRIVER=redis
REDIS_PASSWORD=
REDIS_SELECT=0
REDIS_PREFIX=panbox:
EOF
            success "已补全 Redis 缓存配置"
            env_updated=true
        fi

        if [ "$env_updated" = true ]; then
            info ".env 配置已更新"
        else
            info ".env 配置完整，跳过配置"
        fi
        return 0
    fi

    info "正在检测可用端口..."
    APP_PORT=$(find_available_port)
    success "找到可用端口: ${APP_PORT}"

    # 创建 .env 文件 - 在 PANBOX_DIR 根目录
    cat > .env <<EOF
# ==========================================
# Panbox-Search - Docker Compose 配置
# ==========================================
# 应用端口（宿主机端口）
APP_PORT=${APP_PORT}

# ==================== 缓存配置 ====================
# Docker 部署默认使用 Redis；如需回退文件缓存，可改为 file
CACHE_DRIVER=redis
REDIS_PASSWORD=
REDIS_SELECT=0
REDIS_PREFIX=panbox:

# ==========================================
# 说明：
# - 其他配置（数据库、应用配置）已在 docker-compose.yml 中预设
# - 容器启动后会自动生成应用内部的配置文件
# ==========================================
EOF

    success "环境变量配置完成"
    info "应用端口: ${APP_PORT}"
    info "其他配置将在容器启动时自动生成"
}

# 更新系统
update_system() {
    AUTO_INSTALL=true
    log "🔄 开始更新 Panbox-Search 系统..."

    if [ ! -d "${PANBOX_DIR}" ]; then
        error "未找到 Panbox-Search 安装目录: ${PANBOX_DIR}"
        return 1
    fi

    check_docker
    check_docker_permissions
    check_docker_compose

    cd "${PANBOX_DIR}"
    download_compose_file
    configure_env  # 检查并补全 .env 配置
    log "📦 正在拉取最新 Docker 镜像..."
    execute_compose "pull" "false"
    # 先彻底停止旧容器再启动，避免新旧 MySQL 同时打开同一份数据目录抢锁：
    # - --remove-orphans 清理遗留/孤儿容器，杜绝双实例 mysqld 抢 ibdata1
    # - -t 60 给 MySQL 足够的优雅关闭时间，确保 InnoDB 完成 flush 并释放数据目录锁
    log "🛑 正在停止旧容器（确保 MySQL 完全退出并释放数据目录锁）..."
    execute_compose "down --remove-orphans -t 60" "false"
    log "🚀 正在启动容器服务..."
    execute_compose "up -d --remove-orphans" "false"
}

# 安装系统
install_system() {
    AUTO_INSTALL=true
    log "✨ 开始安装 Panbox-Search 系统..."
    check_docker
    check_docker_permissions
    check_docker_compose
    create_directories
    download_compose_file
    configure_env
    cd "${PANBOX_DIR}"
    log "📦 正在拉取 Docker 镜像..."
    execute_compose "pull" "false"
    log "🚀 正在启动容器服务..."
    execute_compose "up -d --remove-orphans" "false"
}

# 未安装时提示是否立即安装（仅交互模式）
ensure_installed_for_menu() {
    local action_label="$1"
    JUST_INSTALLED=false

    if check_installed; then
        return 0
    fi

    warning "⚠️  当前尚未安装 Panbox-Search 系统，无法执行${action_label}操作。"
    read -p "是否现在开始安装？(Y/n) [默认: y]: " -n 1 -r INSTALL_CHOICE </dev/tty
    echo
    INSTALL_CHOICE=${INSTALL_CHOICE:-y}

    if [[ $INSTALL_CHOICE =~ ^[Yy]$ ]]; then
        install_system
        JUST_INSTALLED=true
        return 0
    fi

    info "已取消${action_label}操作，返回主菜单..."
    return 1
}

# 执行 Docker Compose 命令
execute_compose() {
    local cmd="$1"
    local confirm="${2:-true}"
    local quiet="${3:-false}"

    if [ "$confirm" = "true" ] && [ -t 0 ]; then
        echo -e "\n${GREEN}确定要执行 $cmd 操作吗？${NC}"
        read -p "请输入 (y/n): " confirm_input
        case $confirm_input in
            [yY] | [yY][eE][sS]) ;;
            *) return 1 ;;
        esac
    fi

    if [ "$NEED_SUDO" = true ]; then
        log "使用 sudo 执行: sudo $COMPOSE_CMD $cmd"
        if [ "$quiet" = "true" ]; then
            if ! sudo $COMPOSE_CMD $cmd > /dev/null 2>&1; then
                error "执行失败: sudo $COMPOSE_CMD $cmd"
                return 1
            fi
        else
            if ! sudo $COMPOSE_CMD $cmd; then
                error "执行失败: sudo $COMPOSE_CMD $cmd"
                return 1
            fi
        fi
    else
        log "直接执行: $COMPOSE_CMD $cmd"
        if [ "$quiet" = "true" ]; then
            if ! $COMPOSE_CMD $cmd > /dev/null 2>&1; then
                error "执行失败: $COMPOSE_CMD $cmd"
                return 1
            fi
        else
            if ! $COMPOSE_CMD $cmd; then
                error "执行失败: $COMPOSE_CMD $cmd"
                return 1
            fi
        fi
    fi

    log "执行成功: $COMPOSE_CMD $cmd"
    return 0
}

# 服务管理函数
manage_service() {
    local action=$1

    if ! check_installed; then
        error "未找到 Panbox-Search 安装目录或配置，请先安装系统"
        return 1
    fi

    cd "${PANBOX_DIR}"

    # 检查 Docker 权限
    check_docker_permissions

    # 检查并设置 Docker Compose 命令
    if [ -z "$COMPOSE_CMD" ]; then
        check_docker_compose
    fi

    case $action in
        "start")
            log "启动 Panbox-Search 服务..."
            execute_compose "up -d --remove-orphans" "false"
            ;;
        "stop")
            log "停止 Panbox-Search 服务..."
            # -t 60 给 MySQL 足够的优雅关闭时间，避免被强杀触发下次启动的 crash recovery
            execute_compose "down --remove-orphans -t 60" "false"
            ;;
        "restart")
            log "重启 Panbox-Search 服务..."
            # 先彻底停止再启动，-t 60 确保 MySQL 完成 InnoDB flush 并释放数据目录锁
            execute_compose "down --remove-orphans -t 60" "false"
            execute_compose "up -d --remove-orphans" "false"
            ;;
        *)
            error "无效的操作: $action"
            return 1
            ;;
    esac
}

# 显示部署信息
show_deployment_info() {
    echo ""
    print_title "🎉 部署完成！"

    # 获取公网 IPv4（仅使用 IPv4，避免输出 IPv6）
    PUBLIC_IP=$(curl -4 -s --connect-timeout 3 --max-time 3 https://api.ipify.org 2>/dev/null || true)
    if [[ ! "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        PUBLIC_IP=""
    fi
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP=$(curl -4 -s --connect-timeout 3 --max-time 3 https://ifconfig.me 2>/dev/null || true)
        if [[ ! "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            PUBLIC_IP=""
        fi
    fi
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP=$(curl -4 -s --connect-timeout 3 --max-time 3 https://icanhazip.com 2>/dev/null || true)
        if [[ ! "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            PUBLIC_IP=""
        fi
    fi

    # 获取内网 IP（作为备用）
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP=$(ip addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' | cut -d/ -f1)
    fi
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP=$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')
    fi

    # 读取 .env 配置文件中的 APP_PORT
    if [ -f "${PANBOX_DIR}/.env" ]; then
        APP_PORT=$(grep "^APP_PORT=" "${PANBOX_DIR}/.env" | cut -d'=' -f2)
    else
        APP_PORT="80"
    fi

    echo ""
    success "✅ 应用已成功启动！"
    info "📍 最终访问路径"

    if [ -n "$LOCAL_IP" ]; then
        echo "   内网地址：http://${LOCAL_IP}:${APP_PORT}"
    else
        echo "   内网地址：未检测到内网 IP"
    fi

    if [ -n "$PUBLIC_IP" ]; then
        echo "   外网地址：http://${PUBLIC_IP}:${APP_PORT}"
    else
        echo "   外网地址：未检测到公网 IP"
    fi

    echo ""
    warning "💾 请保存以上访问地址"
    echo ""
}

# 菜单系统
show_menu() {
    clear
    print_title "Panbox-Search 网盘资源管理系统 v${VERSION}"

    local docker_version="未检测到"
    local compose_version="未检测到"

    if command -v docker &> /dev/null; then
        docker_version=$(docker --version | cut -d',' -f1)
        if [ -z "$COMPOSE_CMD" ]; then
            check_docker_compose > /dev/null 2>&1 || true
        fi
        if [ -n "$COMPOSE_CMD" ]; then
            compose_version="$COMPOSE_CMD"
        fi
    fi

    echo -e "\n💻 系统环境："
    echo -e "    📌 System   $(uname -s) $(uname -r)"
    echo -e "    📌 Docker   ${docker_version}"
    echo -e "    📌 Compose  ${compose_version}"
    echo -e "    📌 Script   ${SCRIPT_VERSION}"

    echo -e "\n📋 请选择操作："
    echo -e "\n    1️⃣  安装 Panbox-Search 系统"
    echo -e "    2️⃣  更新 Panbox-Search 系统"
    echo -e "    3️⃣  启动服务"
    echo -e "    4️⃣  停止服务"
    echo -e "    5️⃣  重启服务"
    echo -e "    6️⃣  退出\n"

    print_line
    echo ""

    read -p "请输入选择 (1-6): " choice
    echo ""
}

# 主菜单处理
handle_menu_choice() {
    case $choice in
        1)
            log "✨ 开始安装 Panbox-Search 系统..."

            # 检查是否已安装
            if check_installed; then
                warning "⚠️  检测到 Panbox-Search 系统已经安装！"
                echo ""
                info "📋 当前安装状态："
                info "   - 安装目录: ${PANBOX_DIR}/"
                info "   - 配置文件: ${PANBOX_DIR}/docker-compose.yml"
                info "   - 环境配置: ${PANBOX_DIR}/.env"
                echo ""

                read -p "是否要更新到最新版本？(Y/n) [默认: y]: " -n 1 -r UPDATE_CHOICE </dev/tty
                echo ""
                UPDATE_CHOICE=${UPDATE_CHOICE:-y}
                if [[ $UPDATE_CHOICE =~ ^[Yy]$ ]]; then
                    update_system
                    echo ""
                    show_deployment_info
                else
                    info "取消更新，返回主菜单..."
                fi
            else
                install_system
                echo ""
                show_deployment_info
            fi
            ;;
        2)
            if ensure_installed_for_menu "更新"; then
                if [ "$JUST_INSTALLED" = true ]; then
                    echo ""
                    show_deployment_info
                elif update_system; then
                    success "系统更新完成"
                fi
            fi
            ;;
        3)
            if ensure_installed_for_menu "启动"; then
                if [ "$JUST_INSTALLED" = true ]; then
                    echo ""
                    show_deployment_info
                else
                    manage_service "start"
                fi
            fi
            ;;
        4)
            if ensure_installed_for_menu "停止"; then
                if [ "$JUST_INSTALLED" = true ]; then
                    echo ""
                    show_deployment_info
                else
                    manage_service "stop"
                fi
            fi
            ;;
        5)
            if ensure_installed_for_menu "重启"; then
                if [ "$JUST_INSTALLED" = true ]; then
                    echo ""
                    show_deployment_info
                else
                    manage_service "restart"
                fi
            fi
            ;;
        6)
            log "👋 感谢使用 Panbox-Search 系统，再见！"
            exit 0
            ;;
        *)
            error "无效的选择: $choice"
            ;;
    esac

    if [ $choice -ge 1 ] && [ $choice -le 5 ]; then
        echo ""
        if [ $choice -eq 1 ]; then
            read -p "安装完成！按回车键返回主菜单..." -r
        elif [ $choice -eq 2 ]; then
            read -p "更新完成！按回车键返回主菜单..." -r
        else
            read -p "操作完成！按回车键返回主菜单..." -r
        fi
    fi
}

# 输入验证函数
validate_input() {
    local input=$1
    local pattern=$2
    local message=$3

    if [[ ! "$input" =~ $pattern ]]; then
        error "$message"
        return 1
    fi
    return 0
}

check_and_force_self_update "$@"

# 检查是否传入了命令行参数
if [ $# -eq 0 ]; then
    # 菜单模式
    while true; do
        show_menu
        if validate_input "$choice" "^[1-6]$" "请输入 1-6 之间的数字"; then
            handle_menu_choice
        fi
    done
else
    # 命令行模式
    case "$1" in
        "install")
            install_system
            echo ""
            show_deployment_info
            ;;
        "update")
            update_system
            echo ""
            show_deployment_info
            ;;
        "start"|"stop"|"restart")
            if [ -d "${PANBOX_DIR}" ]; then
                check_docker_permissions
                manage_service "$1"
            else
                error "未找到 Panbox-Search 安装目录: ${PANBOX_DIR}"
            fi
            ;;
        *)
            echo "用法: $0 {install|update|start|stop|restart}"
            echo "或者直接运行 $0 进入交互式菜单"
            exit 1
            ;;
    esac
fi