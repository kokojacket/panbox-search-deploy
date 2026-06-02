#!/bin/bash

# ============================================
# Panbox-Search Beta - 一键部署脚本
# ============================================

set -e

SCRIPT_VERSION="2026.06.02.1"
PANBOX_DIR="/opt/panbox-search-beta"
COMPOSE_FILE="docker-compose.yml"
DEFAULT_IMAGE="kokojacket/panbox-search:beta"
COMPOSE_CMD=""
NEED_SUDO=false

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

create_directories() {
    if [ ! -d "/opt" ]; then
        sudo mkdir -p /opt
    fi

    if [ -w "/opt" ]; then
        mkdir -p "$PANBOX_DIR"
    else
        sudo mkdir -p "$PANBOX_DIR"
        sudo chown "$(whoami):$(whoami)" "$PANBOX_DIR"
    fi

    mkdir -p "$PANBOX_DIR/app/runtime"
    mkdir -p "$PANBOX_DIR/app/data"
    mkdir -p "$PANBOX_DIR/app/uploads"
    mkdir -p "$PANBOX_DIR/app/install"
    mkdir -p "$PANBOX_DIR/mysql"
    mkdir -p "$PANBOX_DIR/redis"
    chmod -R 777 "$PANBOX_DIR"
}

write_env_file() {
    cd "$PANBOX_DIR"

    if [ -f ".env" ]; then
        info ".env 已存在，保留现有配置。"
        return 0
    fi

    local app_port
    app_port="${APP_PORT:-$(find_available_port)}"

    cat > .env <<EOF
APP_PORT=${app_port}
PANBOX_IMAGE=${PANBOX_IMAGE:-$DEFAULT_IMAGE}
CACHE_DRIVER=${CACHE_DRIVER:-redis}
REDIS_PASSWORD=${REDIS_PASSWORD:-}
REDIS_SELECT=${REDIS_SELECT:-0}
REDIS_PREFIX=${REDIS_PREFIX:-panbox-beta:}
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
    image: mysql:5.7
    container_name: panbox-search-beta-mysql
    environment:
      - MYSQL_ROOT_PASSWORD=panbox-search
      - MYSQL_DATABASE=panbox-search
      - MYSQL_USER=panbox-search
      - MYSQL_PASSWORD=panbox-search
      - TZ=Asia/Shanghai
    volumes:
      - /opt/panbox-search-beta/mysql:/var/lib/mysql
    networks:
      - panbox-search-beta-network
    restart: unless-stopped
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --default-authentication-plugin=mysql_native_password
      - --max_connections=1000
      - --max_allowed_packet=128M

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
    write_compose_file
    run_compose "pull"
    run_compose "down --remove-orphans -t 60"
    run_compose "up -d --remove-orphans"
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

case "${1:-install}" in
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
