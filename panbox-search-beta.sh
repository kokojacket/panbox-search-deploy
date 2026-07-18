#!/bin/bash

# ============================================
# Panbox-Search Beta - 一键部署脚本
# ============================================

set -eo pipefail

SCRIPT_VERSION="2026.07.18.1"
SELF_UPDATE_RESTARTED_ENV="PANBOX_SEARCH_BETA_SCRIPT_SELF_UPDATED"
SCRIPT_URLS=(
    "https://gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search-beta.sh"
    "https://hk.gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search-beta.sh"
    "https://cdn.gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search-beta.sh"
    "https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search-beta.sh"
    "https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search-beta.sh"
)
PANBOX_DIR="/opt/panbox-search-beta"
BACKUP_DIR="$PANBOX_DIR/backups"
MYSQL_CONTAINER="panbox-search-beta-mysql"
MYSQL_LEGACY_DIR="$PANBOX_DIR/mysql"
MYSQL_DATA_DIR="$PANBOX_DIR/mysql-8.4"
COMPOSE_FILE="docker-compose.yml"
DEFAULT_IMAGE="kokojacket/panbox-search:beta"
DEFAULT_POLLER_IMAGE="kokojacket/panbox-openilink-poller:beta"
COMPOSE_CMD=""
NEED_SUDO=false
MYSQL_MIGRATION_REQUIRED=false
MYSQL_SOURCE_MANIFEST=""
MYSQL_MIGRATION_BACKUP=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

    info "检查 Beta 部署脚本更新..."
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
        success "Beta 部署脚本已是最新版本：$SCRIPT_VERSION"
        return 0
    fi

    warning "检测到 Beta 部署脚本更新：当前 $SCRIPT_VERSION → 最新 $remote_version"
    if ! self_update_script "$script_path" "$tmp_file" "$@"; then
        rm -f "$tmp_file"
        error "脚本自更新失败，已停止执行以避免使用过期脚本"
        exit 1
    fi
}

generate_internal_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
        return
    fi
    date +%s%N | sha256sum | awk '{print $1}'
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        error "未检测到 Docker，请先安装 Docker。"
        exit 1
    fi
}

check_docker_permissions() {
    if docker info >/dev/null 2>&1; then
        NEED_SUDO=false
        return 0
    fi

    if sudo docker info >/dev/null 2>&1; then
        NEED_SUDO=true
        return 0
    fi

    error "无法执行 Docker 命令，请确认当前用户具备 Docker 权限。"
    exit 1
}

check_docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
        return 0
    fi

    error "未检测到 docker compose 或 docker-compose。"
    exit 1
}

check_port() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -q ":${port} "
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep -q ":${port} "
        return $?
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -i ":${port}" >/dev/null 2>&1
        return $?
    fi

    return 1
}

find_available_port() {
    local port=8088
    while [ "$port" -le 8188 ]; do
        if ! check_port "$port"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done

    error "未找到可用端口，请手动设置 APP_PORT。"
    exit 1
}

run_compose() {
    local cmd="$1"
    cd "$PANBOX_DIR"
    if [ "$NEED_SUDO" = true ]; then
        sudo $COMPOSE_CMD $cmd
    else
        $COMPOSE_CMD $cmd
    fi
}

run_docker() {
    if [ "$NEED_SUDO" = true ]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

is_container_running() {
    [ "$(run_docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

wait_for_mysql() {
    local attempt=0
    while [ "$attempt" -lt 60 ]; do
        if is_container_running "$MYSQL_CONTAINER" \
            && run_docker exec "$MYSQL_CONTAINER" sh -c 'mysqladmin ping -h127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    error "MySQL 在 120 秒内未就绪"
    run_docker logs --tail 80 "$MYSQL_CONTAINER" 2>/dev/null || true
    return 1
}

verify_beta_runtime() {
    local attempt=0
    while [ "$attempt" -lt 90 ]; do
        if is_container_running panbox-search-beta-app \
            && run_docker exec panbox-search-beta-app curl -fsS http://127.0.0.1/api >/dev/null 2>&1; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    if [ "$attempt" -ge 90 ]; then
        error "Beta 应用在 180 秒内未就绪"
        run_docker logs --tail 120 panbox-search-beta-app 2>/dev/null || true
        return 1
    fi

    local version
    version="$(mysql_query 'SELECT VERSION()')"
    case "$version" in
        8.4.*) ;;
        *) error "Beta 实际连接的 MySQL 版本异常：${version}"; return 1 ;;
    esac

    attempt=0
    while [ "$attempt" -lt 30 ] && ! is_container_running panbox-search-beta-openilink-poller; do
        attempt=$((attempt + 1))
        sleep 2
    done
    if ! is_container_running panbox-search-beta-openilink-poller; then
        error "OpenIlink Poller 未运行"
        run_docker logs --tail 120 panbox-search-beta-openilink-poller 2>/dev/null || true
        return 1
    fi

    success "Beta 运行链验证通过：MySQL ${version}、应用 API、OpenIlink Poller"
}

mysql_query() {
    local sql="$1"
    run_docker exec "$MYSQL_CONTAINER" sh -c \
        'exec mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" -e "$1"' sh "$sql"
}

table_row_count() {
    local table="$1"
    if [ "$(mysql_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '$table'")" -gt 0 ]; then
        mysql_query "SELECT COUNT(*) FROM $table"
    else
        echo 0
    fi
}

database_manifest() {
    local table_count
    table_count="$(mysql_query 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()')"
    echo "$table_count:$(table_row_count qf_conf):$(table_row_count qf_source):$(table_row_count qf_source_link):$(table_row_count qf_source_tag_relation):$(table_row_count qf_source_log):$(table_row_count qf_openilink_bind):$(table_row_count qf_saas_user)"
}

detect_database_state() {
    if [ ! -f "$PANBOX_DIR/$COMPOSE_FILE" ]; then
        return 0
    fi

    if ! is_container_running "$MYSQL_CONTAINER"; then
        info "启动当前 MySQL 以检查版本..."
        run_compose "up -d mysql"
    fi
    wait_for_mysql

    local version
    version="$(mysql_query 'SELECT VERSION()')"
    case "$version" in
        5.7.*)
            MYSQL_MIGRATION_REQUIRED=true
            info "检测到 MySQL ${version}，本次更新将迁移到 8.4"
            ;;
        8.4.*)
            info "当前已使用 MySQL ${version}"
            ;;
        *)
            error "不支持从 MySQL ${version} 自动迁移到 8.4"
            return 1
            ;;
    esac
}

stop_database_writers() {
    local container
    for container in panbox-search-beta-app panbox-search-beta-openilink-poller; do
        if is_container_running "$container"; then
            run_docker stop -t 60 "$container" >/dev/null
        fi
    done
}

start_database_writers() {
    local container
    for container in panbox-search-beta-app panbox-search-beta-openilink-poller; do
        if run_docker inspect "$container" >/dev/null 2>&1 && ! is_container_running "$container"; then
            run_docker start "$container" >/dev/null
        fi
    done
}

backup_database() {
    local backup_file="${1:-$BACKUP_DIR/panbox-search-latest.sql.gz}"
    local tmp_file="$backup_file.tmp"
    local backup_status=0

    mkdir -p "$BACKUP_DIR"
    info "更新前备份数据库..."
    rm -f "$tmp_file"
    cd "$PANBOX_DIR"
    run_docker exec "$MYSQL_CONTAINER" sh -c \
        'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --routines --triggers --events --hex-blob --default-character-set=utf8mb4 "$MYSQL_DATABASE"' \
        | gzip > "$tmp_file" || backup_status=$?
    if [ "$backup_status" -eq 0 ] && [ -s "$tmp_file" ] && gzip -t "$tmp_file"; then
        mv -f "$tmp_file" "$backup_file"
        success "数据库已备份：$backup_file"
    else
        rm -f "$tmp_file"
        error "数据库备份失败，已取消更新"
        return 1
    fi
}

migrate_mysql_57_to_84() {
    if [ -d "$MYSQL_DATA_DIR" ] && [ -n "$(find "$MYSQL_DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        error "MySQL 8.4 数据目录不为空，拒绝覆盖：$MYSQL_DATA_DIR"
        return 1
    fi

    stop_database_writers
    if ! MYSQL_SOURCE_MANIFEST="$(database_manifest)"; then
        error "读取迁移前数据库清单失败"
        start_database_writers
        return 1
    fi
    MYSQL_MIGRATION_BACKUP="$BACKUP_DIR/mysql-5.7-before-8.4-$(date +'%Y%m%d%H%M%S').sql.gz"
    if ! backup_database "$MYSQL_MIGRATION_BACKUP"; then
        start_database_writers
        return 1
    fi

    run_compose "down --remove-orphans -t 60"
    mkdir -p "$MYSQL_DATA_DIR"
    run_compose "up -d mysql"
    wait_for_mysql

    local version
    version="$(mysql_query 'SELECT VERSION()')"
    case "$version" in
        8.4.*) ;;
        *)
            error "新数据库版本异常：${version}"
            return 1
            ;;
    esac

    gzip -dc "$MYSQL_MIGRATION_BACKUP" \
        | run_docker exec -i "$MYSQL_CONTAINER" sh -c \
            'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'

    local target_manifest
    target_manifest="$(database_manifest)"
    if [ "$target_manifest" != "$MYSQL_SOURCE_MANIFEST" ]; then
        error "迁移后数据校验失败：迁移前 $MYSQL_SOURCE_MANIFEST，迁移后 $target_manifest"
        return 1
    fi

    {
        echo "migrated_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "mysql_version=$version"
        echo "backup=$MYSQL_MIGRATION_BACKUP"
        echo "manifest=$target_manifest"
        echo "legacy_data=$MYSQL_LEGACY_DIR"
    } > "$PANBOX_DIR/mysql-8.4-migration.info"
    success "MySQL 5.7 数据已迁移到 ${version}，旧目录保留在 $MYSQL_LEGACY_DIR"
}

create_directories() {
    if [ ! -d "$PANBOX_DIR" ] || [ ! -w "$PANBOX_DIR" ]; then
        if [ ! -d "/opt" ]; then
            sudo mkdir -p /opt
        fi
        if [ -w "/opt" ]; then
            mkdir -p "$PANBOX_DIR"
        else
            sudo mkdir -p "$PANBOX_DIR"
            sudo chown "$(whoami):$(whoami)" "$PANBOX_DIR"
        fi
    fi

    mkdir -p "$PANBOX_DIR/app/runtime"
    mkdir -p "$PANBOX_DIR/app/data"
    mkdir -p "$PANBOX_DIR/app/uploads"
    mkdir -p "$PANBOX_DIR/app/install"
    mkdir -p "$MYSQL_DATA_DIR"
    mkdir -p "$PANBOX_DIR/redis"
    chmod -R 777 "$PANBOX_DIR"
}

write_env_file() {
    cd "$PANBOX_DIR"

    if [ -f ".env" ]; then
        info ".env 已存在，保留现有配置。"
        local env_updated=false

        if ! grep -q "^PANBOX_POLLER_IMAGE=" .env; then
            echo "PANBOX_POLLER_IMAGE=${PANBOX_POLLER_IMAGE:-$DEFAULT_POLLER_IMAGE}" >> .env
            env_updated=true
        fi

        if ! grep -q "^PANBOX_INTERNAL_TOKEN=" .env; then
            echo "PANBOX_INTERNAL_TOKEN=${PANBOX_INTERNAL_TOKEN:-$(generate_internal_token)}" >> .env
            env_updated=true
        fi
        if ! grep -q "^OPENILINK_MAX_CONCURRENCY=" .env; then
            echo "OPENILINK_MAX_CONCURRENCY=${OPENILINK_MAX_CONCURRENCY:-300}" >> .env
            env_updated=true
        fi
        if ! grep -q "^OPENILINK_CLAIM_LIMIT=" .env; then
            echo "OPENILINK_CLAIM_LIMIT=${OPENILINK_CLAIM_LIMIT:-300}" >> .env
            env_updated=true
        fi
        if ! grep -q "^OPENILINK_LEASE_TTL=" .env; then
            echo "OPENILINK_LEASE_TTL=${OPENILINK_LEASE_TTL:-45}" >> .env
            env_updated=true
        fi
        if ! grep -q "^OPENILINK_POLL_TIMEOUT_MS=" .env; then
            echo "OPENILINK_POLL_TIMEOUT_MS=${OPENILINK_POLL_TIMEOUT_MS:-30000}" >> .env
            env_updated=true
        fi
        if ! grep -q "^OPENILINK_IDLE_SLEEP=" .env; then
            echo "OPENILINK_IDLE_SLEEP=${OPENILINK_IDLE_SLEEP:-3}" >> .env
            env_updated=true
        fi
        if ! grep -q "^OPENILINK_BACKEND_TIMEOUT=" .env; then
            echo "OPENILINK_BACKEND_TIMEOUT=${OPENILINK_BACKEND_TIMEOUT:-120}" >> .env
            env_updated=true
        fi

        if [ "$env_updated" = true ]; then
            success ".env 已补充 OpenIlink Poller 配置。"
        fi
        return 0
    fi

    local app_port
    app_port="${APP_PORT:-$(find_available_port)}"

    cat > .env <<EOF
APP_PORT=${app_port}
PANBOX_IMAGE=${PANBOX_IMAGE:-$DEFAULT_IMAGE}
PANBOX_POLLER_IMAGE=${PANBOX_POLLER_IMAGE:-$DEFAULT_POLLER_IMAGE}
PANBOX_INTERNAL_TOKEN=${PANBOX_INTERNAL_TOKEN:-$(generate_internal_token)}
CACHE_DRIVER=${CACHE_DRIVER:-redis}
REDIS_PASSWORD=${REDIS_PASSWORD:-}
REDIS_SELECT=${REDIS_SELECT:-0}
REDIS_PREFIX=${REDIS_PREFIX:-panbox-beta:}
APACHE_SERVER_LIMIT=${APACHE_SERVER_LIMIT:-32}
APACHE_MAX_REQUEST_WORKERS=${APACHE_MAX_REQUEST_WORKERS:-32}
APACHE_START_SERVERS=${APACHE_START_SERVERS:-4}
APACHE_MIN_SPARE_SERVERS=${APACHE_MIN_SPARE_SERVERS:-4}
APACHE_MAX_SPARE_SERVERS=${APACHE_MAX_SPARE_SERVERS:-8}
OPENILINK_MAX_CONCURRENCY=${OPENILINK_MAX_CONCURRENCY:-300}
OPENILINK_CLAIM_LIMIT=${OPENILINK_CLAIM_LIMIT:-300}
OPENILINK_LEASE_TTL=${OPENILINK_LEASE_TTL:-45}
OPENILINK_POLL_TIMEOUT_MS=${OPENILINK_POLL_TIMEOUT_MS:-30000}
OPENILINK_IDLE_SLEEP=${OPENILINK_IDLE_SLEEP:-3}
OPENILINK_BACKEND_TIMEOUT=${OPENILINK_BACKEND_TIMEOUT:-120}
EOF

    success "已生成 .env，应用端口：${app_port}"
}

write_compose_file() {
    cd "$PANBOX_DIR"
    cat > "$COMPOSE_FILE" <<'YAML'
version: '3.8'

services:
  app:
    image: ${PANBOX_IMAGE:-kokojacket/panbox-search:beta}
    container_name: panbox-search-beta-app
    ports:
      - "${APP_PORT:-8088}:80"
    environment:
      - DB_HOST=mysql
      - DB_PORT=3306
      - DB_NAME=panbox-search
      - DB_USER=panbox-search
      - DB_PASSWORD=panbox-search
      - DB_PREFIX=qf_
      - APP_DEBUG=false
      - APP_TIMEZONE=Asia/Shanghai
      - SYSTEM_SALT=Panbox Search Beta
      - SITE_NAME=Panbox Search Beta
      - CACHE_DRIVER=${CACHE_DRIVER:-redis}
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${REDIS_PASSWORD:-}
      - REDIS_SELECT=${REDIS_SELECT:-0}
      - REDIS_PREFIX=${REDIS_PREFIX:-panbox-beta:}
      - PANBOX_INTERNAL_TOKEN=${PANBOX_INTERNAL_TOKEN:-change-me}
      - OPENILINK_MONITOR_ENABLED=false
      - APACHE_SERVER_LIMIT=${APACHE_SERVER_LIMIT:-32}
      - APACHE_MAX_REQUEST_WORKERS=${APACHE_MAX_REQUEST_WORKERS:-32}
      - APACHE_START_SERVERS=${APACHE_START_SERVERS:-4}
      - APACHE_MIN_SPARE_SERVERS=${APACHE_MIN_SPARE_SERVERS:-4}
      - APACHE_MAX_SPARE_SERVERS=${APACHE_MAX_SPARE_SERVERS:-8}
    volumes:
      - /opt/panbox-search-beta/app/runtime:/var/www/html/runtime
      - /opt/panbox-search-beta/app/data:/var/www/html/data
      - /opt/panbox-search-beta/app/uploads:/var/www/html/public/uploads
      - /opt/panbox-search-beta/app/install:/var/www/html/public/install
    depends_on:
      - mysql
      - redis
    networks:
      - panbox-search-beta-network
    restart: unless-stopped

  mysql:
    image: mysql:8.4
    container_name: panbox-search-beta-mysql
    environment:
      - MYSQL_ROOT_PASSWORD=panbox-search
      - MYSQL_DATABASE=panbox-search
      - MYSQL_USER=panbox-search
      - MYSQL_PASSWORD=panbox-search
      - TZ=Asia/Shanghai
    volumes:
      - /opt/panbox-search-beta/mysql-8.4:/var/lib/mysql
    networks:
      - panbox-search-beta-network
    restart: unless-stopped
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --max_connections=1000
      - --max_allowed_packet=128M

  openilink-poller:
    image: ${PANBOX_POLLER_IMAGE:-kokojacket/panbox-openilink-poller:beta}
    container_name: panbox-search-beta-openilink-poller
    environment:
      - MYSQL_HOST=mysql
      - MYSQL_PORT=3306
      - MYSQL_DATABASE=panbox-search
      - MYSQL_USER=panbox-search
      - MYSQL_PASSWORD=panbox-search
      - MYSQL_PREFIX=qf_
      - PANBOX_INTERNAL_BASE_URL=http://app
      - PANBOX_INTERNAL_TOKEN=${PANBOX_INTERNAL_TOKEN:-change-me}
      - OPENILINK_MAX_CONCURRENCY=${OPENILINK_MAX_CONCURRENCY:-300}
      - OPENILINK_CLAIM_LIMIT=${OPENILINK_CLAIM_LIMIT:-300}
      - OPENILINK_LEASE_TTL=${OPENILINK_LEASE_TTL:-45}
      - OPENILINK_POLL_TIMEOUT_MS=${OPENILINK_POLL_TIMEOUT_MS:-30000}
      - OPENILINK_IDLE_SLEEP=${OPENILINK_IDLE_SLEEP:-3}
      - OPENILINK_HTTP_TIMEOUT=${OPENILINK_HTTP_TIMEOUT:-45}
      - OPENILINK_BACKEND_TIMEOUT=${OPENILINK_BACKEND_TIMEOUT:-120}
    depends_on:
      - app
      - mysql
    networks:
      - panbox-search-beta-network
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    container_name: panbox-search-beta-redis
    command: >
      sh -c "if [ -n \"$${REDIS_PASSWORD}\" ]; then
      redis-server --appendonly yes --requirepass \"$${REDIS_PASSWORD}\";
      else
      redis-server --appendonly yes;
      fi"
    environment:
      - REDIS_PASSWORD=${REDIS_PASSWORD:-}
    volumes:
      - /opt/panbox-search-beta/redis:/data
    networks:
      - panbox-search-beta-network
    restart: unless-stopped

networks:
  panbox-search-beta-network:
    driver: bridge
YAML
}

install_system() {
    log "开始安装 Panbox Search Beta..."
    check_docker
    check_docker_permissions
    check_docker_compose
    create_directories
    write_env_file
    write_compose_file
    run_compose "pull"
    run_compose "up -d --remove-orphans"
    show_info
}

update_system() {
    log "开始更新 Panbox Search Beta..."
    check_docker
    check_docker_permissions
    check_docker_compose
    create_directories
    write_env_file
    detect_database_state
    write_compose_file
    run_compose "pull"
    if [ "$MYSQL_MIGRATION_REQUIRED" = true ]; then
        migrate_mysql_57_to_84
    else
        backup_database
        run_compose "down --remove-orphans -t 60"
    fi
    run_compose "up -d --remove-orphans"
    verify_beta_runtime
    show_info
}

manage_service() {
    local action="$1"
    check_docker_permissions
    check_docker_compose
    if [ ! -f "$PANBOX_DIR/$COMPOSE_FILE" ]; then
        error "未找到 Beta 安装目录：$PANBOX_DIR"
        exit 1
    fi

    case "$action" in
        start)
            run_compose "up -d --remove-orphans"
            ;;
        stop)
            run_compose "down --remove-orphans -t 60"
            ;;
        restart)
            run_compose "down --remove-orphans -t 60"
            run_compose "up -d --remove-orphans"
            ;;
    esac
}

show_info() {
    local app_port="8088"
    if [ -f "$PANBOX_DIR/.env" ]; then
        app_port="$(grep '^APP_PORT=' "$PANBOX_DIR/.env" | cut -d= -f2)"
    fi

    success "Panbox Search Beta 已启动"
    info "安装目录：$PANBOX_DIR"
    info "镜像：${PANBOX_IMAGE:-$DEFAULT_IMAGE}"
    info "访问地址：http://127.0.0.1:${app_port}"
    info "查看日志：cd $PANBOX_DIR && $COMPOSE_CMD logs -f app"
}

check_and_force_self_update "$@"

if [ $# -eq 0 ]; then
    echo "1) 安装"
    echo "2) 更新"
    echo "3) 启动"
    echo "4) 停止"
    echo "5) 重启"
    echo "0) 退出"
    read -r -p "请选择操作 [0-5]: " choice
    case "$choice" in
        1) set -- install ;;
        2) set -- update ;;
        3) set -- start ;;
        4) set -- stop ;;
        5) set -- restart ;;
        0) exit 0 ;;
        *) error "无效选择"; exit 1 ;;
    esac
fi

case "$1" in
    install)
        install_system
        ;;
    update)
        update_system
        ;;
    start|stop|restart)
        manage_service "$1"
        ;;
    *)
        echo "用法: $0 {install|update|start|stop|restart}"
        exit 1
        ;;
esac
