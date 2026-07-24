#!/bin/bash

# ============================================
# Panbox-Search - 网盘资源管理系统
# 一键部署脚本
# ============================================

VERSION="2.0.0"
SCRIPT_VERSION="2026.07.25.1"
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
BACKUP_DIR="$PANBOX_DIR/backups"
MYSQL_CONTAINER="panbox-search-mysql"
MYSQL_LEGACY_DIR="$PANBOX_DIR/mysql"
MYSQL_DATA_DIR="$PANBOX_DIR/mysql-8.4"
COMPOSE_FILE="docker-compose.yml"
NEED_SUDO=false
COMPOSE_CMD=""
JUST_INSTALLED=false
MYSQL_MIGRATION_REQUIRED=false
MYSQL_RECOVERY_REQUIRED=false
MYSQL_SOURCE_MANIFEST=""
MYSQL_MIGRATION_BACKUP=""
MYSQL_PHYSICAL_BACKUP=""
MYSQL_FAILED_TARGET_ARCHIVE=""
MYSQL_RECOVERY_CONTAINER="panbox-search-mysql57-recovery"
MYSQL_MIGRATION_MARKER="$PANBOX_DIR/mysql-8.4-migration.info"

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

wait_for_mysql_container() {
    local container="$1"
    local attempt=0
    while [ "$attempt" -lt 60 ]; do
        if is_container_running "$container" \
            && run_docker exec "$container" sh -c 'mysqladmin ping -h127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    error "MySQL 在 120 秒内未就绪"
    run_docker logs --tail 80 "$container" 2>/dev/null || true
    return 1
}

wait_for_mysql() {
    wait_for_mysql_container "$MYSQL_CONTAINER"
}

mysql_query() {
    local sql="$1"
    local container="${2:-$MYSQL_CONTAINER}"
    run_docker exec "$container" sh -c \
        'exec mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" -e "$1"' sh "$sql"
}

table_row_count() {
    local table="$1"
    local container="${2:-$MYSQL_CONTAINER}"
    local exists
    exists="$(mysql_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '$table'" "$container")" || return 1
    if [ "$exists" -gt 0 ]; then
        mysql_query "SELECT COUNT(*) FROM $table" "$container" || return 1
    else
        echo 0
    fi
}

database_manifest() {
    local container="${1:-$MYSQL_CONTAINER}"
    local table_count conf source source_link tag_relation source_log openilink_bind saas_user
    table_count="$(mysql_query 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()' "$container")" || return 1
    conf="$(table_row_count qf_conf "$container")" || return 1
    source="$(table_row_count qf_source "$container")" || return 1
    source_link="$(table_row_count qf_source_link "$container")" || return 1
    tag_relation="$(table_row_count qf_source_tag_relation "$container")" || return 1
    source_log="$(table_row_count qf_source_log "$container")" || return 1
    openilink_bind="$(table_row_count qf_openilink_bind "$container")" || return 1
    saas_user="$(table_row_count qf_saas_user "$container")" || return 1
    printf '%s:%s:%s:%s:%s:%s:%s:%s\n' "$table_count" "$conf" "$source" "$source_link" "$tag_relation" "$source_log" "$openilink_bind" "$saas_user"
}

core_tables_exist() {
    local container="${1:-$MYSQL_CONTAINER}"
    local table
    for table in qf_conf qf_node qf_auth qf_source; do
        if [ "$(mysql_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '$table'" "$container")" != "1" ]; then
            error "数据库缺少核心表：$table"
            return 1
        fi
    done
}

directory_has_data() {
    [ -d "$1" ] && [ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

database_directories_are_unused() {
    local containers container mounts
    containers="$(run_docker ps -q)" || {
        error "无法确认 MySQL 数据目录是否仍被容器占用"
        return 1
    }
    for container in $containers; do
        mounts="$(run_docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$container")" || {
            error "无法读取容器 $container 的挂载信息"
            return 1
        }
        if printf '%s\n' "$mounts" | grep -Fxq "$MYSQL_LEGACY_DIR" \
            || printf '%s\n' "$mounts" | grep -Fxq "$MYSQL_DATA_DIR"; then
            error "容器 $container 仍占用 MySQL 数据目录，已停止迁移"
            return 1
        fi
    done
}

detect_database_state() {
    MYSQL_MIGRATION_REQUIRED=false
    MYSQL_RECOVERY_REQUIRED=false
    if [ ! -f "$PANBOX_DIR/$COMPOSE_FILE" ]; then
        error "未找到现有 docker-compose.yml，无法安全识别数据库版本"
        return 1
    fi

    if directory_has_data "$MYSQL_LEGACY_DIR" \
        && [ ! -f "$MYSQL_MIGRATION_MARKER" ] \
        && { directory_has_data "$MYSQL_DATA_DIR" || grep -q 'image:[[:space:]]*mysql:8\.4' "$PANBOX_DIR/$COMPOSE_FILE"; }; then
        if is_container_running "$MYSQL_CONTAINER" \
            || grep -q 'image:[[:space:]]*mysql:8\.4' "$PANBOX_DIR/$COMPOSE_FILE"; then
            if ! is_container_running "$MYSQL_CONTAINER"; then
                execute_compose "up -d mysql" "false" || return 1
            fi
            wait_for_mysql || return 1
            local current_version
            current_version="$(mysql_query 'SELECT VERSION()')" || return 1
            if [[ "$current_version" == 8.4.* ]] && core_tables_exist; then
                error "MySQL 8.4 核心表完整但迁移标记缺失，无法安全判断 5.7 是否仍是最新数据"
                error "已拒绝自动恢复；请保留两个数据目录并人工核对后再处理"
                return 1
            fi
        fi
        MYSQL_RECOVERY_REQUIRED=true
        warning "检测到中断的 MySQL 8.4 迁移，本次更新将从保留的 5.7 数据自动恢复"
        return 0
    fi

    if ! is_container_running "$MYSQL_CONTAINER"; then
        info "启动当前 MySQL 以检查版本..."
        execute_compose "up -d mysql" "false" || return 1
    fi
    wait_for_mysql || return 1

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
    for container in panbox-search-app panbox-openilink-poller; do
        if is_container_running "$container"; then
            run_docker stop -t 60 "$container" >/dev/null || return 1
        fi
    done
}

start_database_writers() {
    local container
    for container in panbox-search-app panbox-openilink-poller; do
        if run_docker inspect "$container" >/dev/null 2>&1 && ! is_container_running "$container"; then
            run_docker start "$container" >/dev/null
        fi
    done
}

backup_database() {
    local backup_file="${1:-$BACKUP_DIR/panbox-search-latest.sql.gz}"
    local tmp_file="$backup_file.tmp"

    mkdir -p "$BACKUP_DIR" || return 1
    chmod 700 "$BACKUP_DIR" || return 1
    info "更新前备份数据库..."
    rm -f "$tmp_file"
    cd "$PANBOX_DIR"
    if (umask 077; set -o pipefail; run_docker exec "$MYSQL_CONTAINER" sh -c \
        'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --routines --triggers --events --hex-blob --default-character-set=utf8mb4 "$MYSQL_DATABASE"' \
        | gzip > "$tmp_file") \
        && [ -s "$tmp_file" ] \
        && gzip -t "$tmp_file"; then
        mv -f "$tmp_file" "$backup_file"
        chmod 600 "$backup_file" || return 1
        success "数据库已备份：$backup_file"
    else
        rm -f "$tmp_file"
        error "数据库备份失败，已取消更新"
        return 1
    fi
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

create_legacy_physical_backup() {
    mkdir -p "$BACKUP_DIR" || return 1
    chmod 700 "$BACKUP_DIR" || return 1

    local source_kb available_kb
    source_kb="$(du -sk "$MYSQL_LEGACY_DIR" 2>/dev/null | awk '{print $1}')" || {
        error "无法读取旧 MySQL 5.7 数据目录大小，已停止恢复"
        return 1
    }
    available_kb="$(df -Pk "$BACKUP_DIR" | awk 'END {print $4}')" || return 1
    if ! [[ "$source_kb" =~ ^[0-9]+$ && "$available_kb" =~ ^[0-9]+$ ]] \
        || [ "$available_kb" -le $((source_kb * 2 + 102400)) ]; then
        error "备份空间不足：旧库约 ${source_kb:-未知} KB，可用 ${available_kb:-未知} KB"
        return 1
    fi

    local timestamp tmp_file checksum
    timestamp="$(date +'%Y%m%d%H%M%S')"
    MYSQL_PHYSICAL_BACKUP="$BACKUP_DIR/mysql-5.7-physical-${timestamp}.tar.gz"
    while [ -e "$MYSQL_PHYSICAL_BACKUP" ] || [ -e "$MYSQL_PHYSICAL_BACKUP.tmp" ]; do
        sleep 1
        timestamp="$(date +'%Y%m%d%H%M%S')"
        MYSQL_PHYSICAL_BACKUP="$BACKUP_DIR/mysql-5.7-physical-${timestamp}.tar.gz"
    done
    tmp_file="$MYSQL_PHYSICAL_BACKUP.tmp"

    info "为旧 MySQL 5.7 物理目录创建保护副本..."
    if ! (umask 077; tar -C "$(dirname "$MYSQL_LEGACY_DIR")" -czpf "$tmp_file" "$(basename "$MYSQL_LEGACY_DIR")") \
        || ! tar -tzf "$tmp_file" >/dev/null; then
        error "旧库物理保护副本失败，已停止恢复；临时文件保留在 $tmp_file"
        return 1
    fi
    mv "$tmp_file" "$MYSQL_PHYSICAL_BACKUP" || return 1
    chmod 600 "$MYSQL_PHYSICAL_BACKUP" || return 1
    checksum="$(sha256_file "$MYSQL_PHYSICAL_BACKUP")" || return 1
    (umask 077; printf '%s  %s\n' "$checksum" "$(basename "$MYSQL_PHYSICAL_BACKUP")" > "$MYSQL_PHYSICAL_BACKUP.sha256.tmp") || return 1
    mv "$MYSQL_PHYSICAL_BACKUP.sha256.tmp" "$MYSQL_PHYSICAL_BACKUP.sha256" || return 1
    chmod 600 "$MYSQL_PHYSICAL_BACKUP.sha256" || return 1
    success "旧库物理保护副本已生成：$MYSQL_PHYSICAL_BACKUP"
}

start_mysql57_recovery_container() {
    run_docker rm -f "$MYSQL_RECOVERY_CONTAINER" >/dev/null 2>&1 || true
    if ! run_docker run -d --name "$MYSQL_RECOVERY_CONTAINER" --network none \
        -e MYSQL_ROOT_PASSWORD=panbox-search \
        -e MYSQL_DATABASE=panbox-search \
        -v "$MYSQL_LEGACY_DIR:/var/lib/mysql" \
        mysql:5.7 \
        --character-set-server=utf8mb4 \
        --collation-server=utf8mb4_unicode_ci >/dev/null; then
        error "临时 MySQL 5.7 恢复容器启动失败"
        return 1
    fi
    if ! wait_for_mysql_container "$MYSQL_RECOVERY_CONTAINER"; then
        run_docker rm -f "$MYSQL_RECOVERY_CONTAINER" >/dev/null 2>&1 || true
        return 1
    fi
}

stop_mysql57_recovery_container() {
    if is_container_running "$MYSQL_RECOVERY_CONTAINER"; then
        run_docker exec "$MYSQL_RECOVERY_CONTAINER" sh -c \
            'mysqladmin shutdown -uroot -p"$MYSQL_ROOT_PASSWORD"' >/dev/null 2>&1 \
            || run_docker stop -t 60 "$MYSQL_RECOVERY_CONTAINER" >/dev/null \
            || return 1
    fi
    run_docker rm -f "$MYSQL_RECOVERY_CONTAINER" >/dev/null 2>&1 || return 1
}

create_legacy_logical_backup() {
    local timestamp tmp_file dump_log table
    timestamp="$(date +'%Y%m%d%H%M%S')"
    MYSQL_MIGRATION_BACKUP="$BACKUP_DIR/mysql-5.7-before-8.4-${timestamp}.sql.gz"
    while [ -e "$MYSQL_MIGRATION_BACKUP" ] || [ -e "$MYSQL_MIGRATION_BACKUP.tmp" ]; do
        sleep 1
        timestamp="$(date +'%Y%m%d%H%M%S')"
        MYSQL_MIGRATION_BACKUP="$BACKUP_DIR/mysql-5.7-before-8.4-${timestamp}.sql.gz"
    done
    tmp_file="$MYSQL_MIGRATION_BACKUP.tmp"
    dump_log="$MYSQL_MIGRATION_BACKUP.log"
    rm -f "$dump_log"

    info "从受保护的 MySQL 5.7 数据重新生成逻辑备份..."
    if ! (umask 077; set -o pipefail; run_docker exec "$MYSQL_RECOVERY_CONTAINER" sh -c \
        'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --routines --triggers --events --hex-blob --default-character-set=utf8mb4 "$MYSQL_DATABASE"' \
        2> "$dump_log" | gzip > "$tmp_file") \
        || [ ! -s "$tmp_file" ] \
        || ! gzip -t "$tmp_file"; then
        error "MySQL 5.7 逻辑备份失败，已停止恢复；错误日志：$dump_log"
        error "未完成备份保留在：$tmp_file"
        return 1
    fi

    for table in qf_conf qf_node qf_auth qf_source; do
        if ! (set +o pipefail; gzip -dc "$tmp_file" | grep -Fq "CREATE TABLE \`$table\`"); then
            error "逻辑备份缺少核心表 ${table}，已停止恢复；备份保留在 $tmp_file"
            return 1
        fi
    done
    mv "$tmp_file" "$MYSQL_MIGRATION_BACKUP" || return 1
    chmod 600 "$MYSQL_MIGRATION_BACKUP" "$dump_log" || return 1
    success "MySQL 5.7 逻辑备份已生成：$MYSQL_MIGRATION_BACKUP"
}

archive_failed_mysql84_target() {
    MYSQL_FAILED_TARGET_ARCHIVE=""
    if directory_has_data "$MYSQL_DATA_DIR"; then
        local timestamp
        timestamp="$(date +'%Y%m%d%H%M%S')"
        MYSQL_FAILED_TARGET_ARCHIVE="$MYSQL_DATA_DIR.failed-$timestamp"
        while [ -e "$MYSQL_FAILED_TARGET_ARCHIVE" ]; do
            sleep 1
            timestamp="$(date +'%Y%m%d%H%M%S')"
            MYSQL_FAILED_TARGET_ARCHIVE="$MYSQL_DATA_DIR.failed-$timestamp"
        done
        mv "$MYSQL_DATA_DIR" "$MYSQL_FAILED_TARGET_ARCHIVE" || return 1
        warning "失败的 MySQL 8.4 数据已归档：$MYSQL_FAILED_TARGET_ARCHIVE"
    elif [ -d "$MYSQL_DATA_DIR" ]; then
        rmdir "$MYSQL_DATA_DIR" || return 1
    fi
    mkdir -p "$MYSQL_DATA_DIR" || return 1
}

write_migration_marker() {
    local source_version="$1"
    local target_version="$2"
    local target_manifest="$3"
    local backup_sha256 marker_tmp
    backup_sha256="$(sha256_file "$MYSQL_MIGRATION_BACKUP")" || return 1
    marker_tmp="$MYSQL_MIGRATION_MARKER.tmp"
    rm -f "$marker_tmp"

    (umask 077; {
        echo "migrated_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "source_version=$source_version"
        echo "target_version=$target_version"
        echo "physical_backup=$MYSQL_PHYSICAL_BACKUP"
        echo "logical_backup=$MYSQL_MIGRATION_BACKUP"
        echo "backup_sha256=$backup_sha256"
        echo "source_manifest=$MYSQL_SOURCE_MANIFEST"
        echo "target_manifest=$target_manifest"
        echo "legacy_data=$MYSQL_LEGACY_DIR"
        echo "failed_target_archive=$MYSQL_FAILED_TARGET_ARCHIVE"
        echo "mysql_version=$target_version"
        echo "backup=$MYSQL_MIGRATION_BACKUP"
        echo "manifest=$target_manifest"
    } > "$marker_tmp") || return 1
    mv "$marker_tmp" "$MYSQL_MIGRATION_MARKER" || return 1
    chmod 600 "$MYSQL_MIGRATION_MARKER" || return 1
}

migrate_mysql_57_to_84() {
    info "正在准备可恢复的 MySQL 5.7 → 8.4 迁移..."
    if ! execute_compose "down --remove-orphans -t 60" "false"; then
        error "停止现有容器失败，未触碰数据库目录"
        return 1
    fi
    if run_docker inspect "$MYSQL_RECOVERY_CONTAINER" >/dev/null 2>&1; then
        stop_mysql57_recovery_container || return 1
    fi
    if is_container_running "$MYSQL_CONTAINER" \
        || is_container_running panbox-search-app \
        || is_container_running panbox-openilink-poller; then
        error "仍有容器占用数据库，已停止迁移"
        return 1
    fi
    database_directories_are_unused || return 1

    create_legacy_physical_backup || return 1
    start_mysql57_recovery_container || return 1

    local source_version target_version target_manifest
    source_version="$(mysql_query 'SELECT VERSION()' "$MYSQL_RECOVERY_CONTAINER")" || {
        stop_mysql57_recovery_container || true
        error "读取旧数据库版本失败"
        return 1
    }
    case "$source_version" in
        5.7.*) ;;
        *)
            stop_mysql57_recovery_container || true
            error "旧数据目录版本异常：$source_version"
            return 1
            ;;
    esac
    if ! MYSQL_SOURCE_MANIFEST="$(database_manifest "$MYSQL_RECOVERY_CONTAINER")" \
        || ! core_tables_exist "$MYSQL_RECOVERY_CONTAINER"; then
        stop_mysql57_recovery_container || true
        error "读取 MySQL 5.7 源数据库清单失败"
        return 1
    fi
    if ! create_legacy_logical_backup; then
        stop_mysql57_recovery_container || true
        return 1
    fi
    stop_mysql57_recovery_container || {
        error "临时 MySQL 5.7 容器无法安全停止，已停止迁移"
        return 1
    }

    archive_failed_mysql84_target || return 1
    execute_compose "up -d mysql" "false" || return 1
    wait_for_mysql || return 1

    target_version="$(mysql_query 'SELECT VERSION()')" || return 1
    case "$target_version" in
        8.4.*) ;;
        *)
            error "新数据库版本异常：${target_version}"
            return 1
            ;;
    esac

    if ! (set -o pipefail; gzip -dc "$MYSQL_MIGRATION_BACKUP" \
        | run_docker exec -i "$MYSQL_CONTAINER" sh -c \
            'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'); then
        error "MySQL 8.4 数据导入失败，旧 5.7 数据和迁移备份均已保留"
        return 1
    fi

    target_manifest="$(database_manifest)" || return 1
    core_tables_exist || return 1
    if [ "$target_manifest" != "$MYSQL_SOURCE_MANIFEST" ]; then
        error "迁移后数据校验失败：迁移前 $MYSQL_SOURCE_MANIFEST，迁移后 $target_manifest"
        return 1
    fi
    write_migration_marker "$source_version" "$target_version" "$target_manifest" || {
        error "迁移标记写入失败，应用与 Poller 不会启动"
        return 1
    }
    success "MySQL 5.7 数据已迁移到 ${target_version}，旧目录和恢复备份均已保留"
}

verify_runtime() {
    local attempt=0
    while [ "$attempt" -lt 90 ]; do
        if is_container_running panbox-search-app \
            && run_docker exec panbox-search-app curl -fsS http://127.0.0.1/api >/dev/null 2>&1; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    if [ "$attempt" -ge 90 ]; then
        error "正式版应用在 180 秒内未就绪"
        run_docker logs --tail 120 panbox-search-app 2>/dev/null || true
        return 1
    fi

    local version
    version="$(mysql_query 'SELECT VERSION()')"
    case "$version" in
        8.4.*) ;;
        *) error "正式版实际连接的 MySQL 版本异常：${version}"; return 1 ;;
    esac

    if ! run_docker exec panbox-search-app php /var/www/html/think db:migrate; then
        error "正式版数据库迁移命令失败"
        return 1
    fi
    if ! mysql_query 'SELECT COUNT(*) FROM qf_openilink_bind' >/dev/null; then
        error "正式版数据库缺少可查询的 qf_openilink_bind"
        return 1
    fi

    attempt=0
    while [ "$attempt" -lt 30 ] && ! is_container_running panbox-openilink-poller; do
        attempt=$((attempt + 1))
        sleep 2
    done
    if ! is_container_running panbox-openilink-poller; then
        error "OpenIlink Poller 未运行"
        run_docker logs --tail 120 panbox-openilink-poller 2>/dev/null || true
        return 1
    fi

    local app_restarts mysql_restarts poller_restarts delay
    app_restarts="$(run_docker inspect -f '{{.RestartCount}}' panbox-search-app)" || return 1
    mysql_restarts="$(run_docker inspect -f '{{.RestartCount}}' "$MYSQL_CONTAINER")" || return 1
    poller_restarts="$(run_docker inspect -f '{{.RestartCount}}' panbox-openilink-poller)" || return 1
    delay="${VERIFY_STABILITY_DELAY:-30}"
    sleep "$delay"
    if ! is_container_running panbox-search-app \
        || ! is_container_running "$MYSQL_CONTAINER" \
        || ! is_container_running panbox-openilink-poller \
        || ! run_docker exec panbox-search-app curl -fsS http://127.0.0.1/api >/dev/null 2>&1 \
        || [ "$(run_docker inspect -f '{{.RestartCount}}' panbox-search-app)" != "$app_restarts" ] \
        || [ "$(run_docker inspect -f '{{.RestartCount}}' "$MYSQL_CONTAINER")" != "$mysql_restarts" ] \
        || [ "$(run_docker inspect -f '{{.RestartCount}}' panbox-openilink-poller)" != "$poller_restarts" ]; then
        error "正式版运行链在 ${delay} 秒稳定性复查中失败"
        return 1
    fi

    success "正式版运行链验证通过：MySQL ${version}、数据库迁移、应用 API、OpenIlink Poller 与重启计数"
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
    mkdir -p "${MYSQL_DATA_DIR}"
    mkdir -p "${PANBOX_DIR}/redis"

    chmod 755 "${PANBOX_DIR}"
    chmod -R 777 "${PANBOX_DIR}/app/runtime" "${PANBOX_DIR}/app/data" \
        "${PANBOX_DIR}/app/uploads" "${PANBOX_DIR}/app/install" \
        "${MYSQL_DATA_DIR}" "${PANBOX_DIR}/redis"

    success "数据目录创建完成"
    info "  - 工作目录: ${PANBOX_DIR}/"
    info "  - 应用数据: ${PANBOX_DIR}/app/"
    info "  - License 数据: ${PANBOX_DIR}/app/data/"
    info "  - 数据库数据: ${MYSQL_DATA_DIR}/"
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
generate_internal_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
        return
    fi
    date +%s%N | sha256sum | awk '{print $1}'
}

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

        if ! grep -q "^APACHE_MAX_REQUEST_WORKERS" .env; then
            warning "检测到 .env 缺少 Apache Worker 配置，正在补全..."
            cat >> .env <<EOF

# ==================== Apache Worker 配置 ====================
APACHE_SERVER_LIMIT=32
APACHE_MAX_REQUEST_WORKERS=32
APACHE_START_SERVERS=4
APACHE_MIN_SPARE_SERVERS=4
APACHE_MAX_SPARE_SERVERS=8
EOF
            success "已补全 Apache Worker 配置"
            env_updated=true
        fi

        if ! grep -q "^PANBOX_INTERNAL_TOKEN" .env; then
            warning "检测到 .env 缺少内部接口密钥，正在生成..."
            PANBOX_INTERNAL_TOKEN=$(generate_internal_token)
            cat >> .env <<EOF

# ==================== OpenIlink Poller 配置 ====================
PANBOX_INTERNAL_TOKEN=${PANBOX_INTERNAL_TOKEN}
OPENILINK_MAX_CONCURRENCY=300
OPENILINK_CLAIM_LIMIT=300
OPENILINK_LEASE_TTL=45
OPENILINK_POLL_TIMEOUT_MS=30000
OPENILINK_HTTP_TIMEOUT=45
OPENILINK_IDLE_SLEEP=3
OPENILINK_BACKEND_TIMEOUT=120
EOF
            success "已生成 PANBOX_INTERNAL_TOKEN"
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

# ==================== Apache Worker 配置 ====================
APACHE_SERVER_LIMIT=32
APACHE_MAX_REQUEST_WORKERS=32
APACHE_START_SERVERS=4
APACHE_MIN_SPARE_SERVERS=4
APACHE_MAX_SPARE_SERVERS=8

# ==================== OpenIlink Poller 配置 ====================
PANBOX_INTERNAL_TOKEN=$(generate_internal_token)
OPENILINK_MAX_CONCURRENCY=300
OPENILINK_CLAIM_LIMIT=300
OPENILINK_LEASE_TTL=45
OPENILINK_POLL_TIMEOUT_MS=30000
OPENILINK_HTTP_TIMEOUT=45
OPENILINK_IDLE_SLEEP=3
OPENILINK_BACKEND_TIMEOUT=120

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

    check_docker || return 1
    check_docker_permissions || return 1
    check_docker_compose || return 1

    cd "${PANBOX_DIR}" || return 1
    chmod 755 "$PANBOX_DIR" || return 1
    detect_database_state || return 1
    if [ "$MYSQL_RECOVERY_REQUIRED" = true ]; then
        log "🛑 检测到中断迁移，先停止全部数据库写入服务..."
        execute_compose "down --remove-orphans -t 60" "false" || return 1
    fi
    download_compose_file || return 1
    configure_env || return 1  # 检查并补全 .env 配置
    log "📦 正在拉取最新 Docker 镜像..."
    execute_compose "pull" "false" || return 1
    if [ "$MYSQL_MIGRATION_REQUIRED" = true ] || [ "$MYSQL_RECOVERY_REQUIRED" = true ]; then
        if ! migrate_mysql_57_to_84; then
            error "数据库迁移/恢复未完成；请保留现有目录和备份，排除上方错误后重新执行 update"
            return 1
        fi
    else
        backup_database || return 1
        log "🛑 正在停止旧容器（确保 MySQL 完全退出并释放数据目录锁）..."
        execute_compose "down --remove-orphans -t 60" "false" || return 1
    fi
    log "🚀 正在启动容器服务..."
    if ! execute_compose "up -d --remove-orphans" "false"; then
        stop_database_writers || true
        return 1
    fi
    if ! verify_runtime; then
        stop_database_writers || true
        return 1
    fi
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
                else
                    update_system || return 1
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
