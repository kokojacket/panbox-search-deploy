#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INSTALL_DIR="$TMP_DIR/install"
STATE_DIR="$TMP_DIR/state"
BIN_DIR="$TMP_DIR/bin"
SCRIPT_UNDER_TEST="$TMP_DIR/panbox-search.sh"
mkdir -p "$INSTALL_DIR/mysql" "$STATE_DIR" "$BIN_DIR"
touch "$INSTALL_DIR/mysql/ibdata1"
printf '%s\n' true > "$STATE_DIR/panbox-search-mysql.running"
printf '%s\n' true > "$STATE_DIR/panbox-search-app.running"
printf '%s\n' true > "$STATE_DIR/panbox-openilink-poller.running"
printf '%s\n' 5.7.44 > "$STATE_DIR/mysql.version"

cat > "$INSTALL_DIR/docker-compose.yml" <<'YAML'
services:
  mysql:
    image: mysql:5.7
    volumes:
      - /opt/panbox-search/mysql:/var/lib/mysql
YAML

cat > "$INSTALL_DIR/.env" <<'ENV'
APP_PORT=8888
CACHE_DRIVER=redis
REDIS_PASSWORD=
REDIS_SELECT=0
REDIS_PREFIX=panbox:
APACHE_SERVER_LIMIT=32
APACHE_MAX_REQUEST_WORKERS=32
APACHE_START_SERVERS=4
APACHE_MIN_SPARE_SERVERS=4
APACHE_MAX_SPARE_SERVERS=8
PANBOX_INTERNAL_TOKEN=test-token
OPENILINK_MAX_CONCURRENCY=300
OPENILINK_CLAIM_LIMIT=300
OPENILINK_LEASE_TTL=45
OPENILINK_POLL_TIMEOUT_MS=30000
OPENILINK_HTTP_TIMEOUT=45
OPENILINK_IDLE_SLEEP=3
OPENILINK_BACKEND_TIMEOUT=120
ENV

cat > "$BIN_DIR/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

output=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        output="${2:?}"
        shift 2
    else
        shift
    fi
done

if [ -n "$output" ]; then
    cp "$FAKE_COMPOSE_SOURCE" "$output"
    exit 0
fi
exit 1
SH

cat > "$BIN_DIR/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

state_file() {
    printf '%s/%s.running\n' "$FAKE_DOCKER_STATE" "$1"
}

case "${1:-}" in
    --version)
        echo 'Docker version 27.test'
        ;;
    info)
        exit 0
        ;;
    ps)
        ;;
    compose)
        shift
        case "${1:-}" in
            version)
                echo 'Docker Compose version v2.test'
                ;;
            pull)
                ;;
            down)
                printf '%s\n' false > "$(state_file panbox-search-mysql)"
                printf '%s\n' false > "$(state_file panbox-search-app)"
                printf '%s\n' false > "$(state_file panbox-openilink-poller)"
                ;;
            up)
                printf '%s\n' true > "$(state_file panbox-search-mysql)"
                if grep -q 'image: mysql:8.4' docker-compose.yml; then
                    printf '%s\n' 8.4.10 > "$FAKE_DOCKER_STATE/mysql.version"
                else
                    printf '%s\n' 5.7.44 > "$FAKE_DOCKER_STATE/mysql.version"
                fi
                last=""
                for arg in "$@"; do last="$arg"; done
                if [ "$last" != "mysql" ]; then
                    printf '%s\n' true > "$(state_file panbox-search-app)"
                    printf '%s\n' true > "$(state_file panbox-openilink-poller)"
                fi
                ;;
        esac
        ;;
    inspect)
        container=""
        for arg in "$@"; do container="$arg"; done
        file="$(state_file "$container")"
        test -f "$file"
        if [ "${2:-}" = "-f" ]; then
            if [[ "${3:-}" == *RestartCount* ]]; then echo 0; else cat "$file"; fi
        fi
        ;;
    run)
        container=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --name ]; then container="${2:?}"; shift 2; else shift; fi
        done
        printf '%s\n' true > "$(state_file "$container")"
        echo fake-container-id
        ;;
    rm)
        container=""
        for arg in "$@"; do container="$arg"; done
        rm -f "$(state_file "$container")"
        ;;
    stop)
        container=""
        for arg in "$@"; do container="$arg"; done
        printf '%s\n' false > "$(state_file "$container")"
        ;;
    start)
        container="${2:?}"
        printf '%s\n' true > "$(state_file "$container")"
        ;;
    logs)
        ;;
    exec)
        shift
        joined="$*"
        if [[ "$joined" == *mysqladmin* ]]; then
            exit 0
        fi
        if [[ "$joined" == *'curl -fsS http://127.0.0.1/api'* ]]; then
            echo 'Hello World'
            exit 0
        fi
        if [[ "$joined" == *mysqldump* ]]; then
            if grep -q '^5\.7\.' "$FAKE_DOCKER_STATE/mysql.version"; then
                test "$(cat "$(state_file panbox-search-app)")" = false
                test "$(cat "$(state_file panbox-openilink-poller)")" = false
            fi
            for table in qf_conf qf_node qf_auth qf_source qf_schema_migrations qf_source_link qf_source_tag_relation qf_source_log qf_openilink_bind qf_saas_user; do
                printf 'CREATE TABLE `%s` (`id` int);\n' "$table"
            done
            exit 0
        fi
        if [[ "$joined" == *'php /var/www/html/think db:migrate'* ]]; then
            exit 0
        fi
        if [[ "$joined" == *'mysql -N '* ]]; then
            last=""
            for arg in "$@"; do last="$arg"; done
            case "$last" in
                *'SELECT VERSION()'*) cat "$FAKE_DOCKER_STATE/mysql.version" ;;
                *'table_name ='*) echo 1 ;;
                *'information_schema.tables'*) echo 33 ;;
                *'COUNT(*) FROM qf_conf'*) echo 171 ;;
                *'COUNT(*) FROM qf_source_link'*) echo 12 ;;
                *'COUNT(*) FROM qf_source_tag_relation'*) echo 15 ;;
                *'COUNT(*) FROM qf_source_log'*) echo 4 ;;
                *'COUNT(*) FROM qf_source'*) echo 9 ;;
                *'COUNT(*) FROM qf_openilink_bind'*) echo 2 ;;
                *'COUNT(*) FROM qf_saas_user'*) echo 1 ;;
                *) exit 1 ;;
            esac
            exit 0
        fi
        if [[ "$joined" == *'mysql -uroot '* ]]; then
            cat >/dev/null
            exit 0
        fi
        ;;
    *)
        exit 1
        ;;
esac
SH
chmod +x "$BIN_DIR/curl" "$BIN_DIR/docker"

sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$INSTALL_DIR\"|" "$ROOT_DIR/panbox-search.sh" > "$SCRIPT_UNDER_TEST"
chmod +x "$SCRIPT_UNDER_TEST"

for run in 1 2; do
    PATH="$BIN_DIR:$PATH" \
    FAKE_DOCKER_STATE="$STATE_DIR" \
    FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1 \
    bash "$SCRIPT_UNDER_TEST" update
done

grep -q 'image: mysql:8.4' "$INSTALL_DIR/docker-compose.yml"
grep -q '/opt/panbox-search/mysql-8.4:/var/lib/mysql' "$INSTALL_DIR/docker-compose.yml"
if grep -q 'default-authentication-plugin' "$INSTALL_DIR/docker-compose.yml"; then exit 1; fi
test -f "$INSTALL_DIR/mysql/ibdata1"
grep -q '^mysql_version=8.4.10$' "$INSTALL_DIR/mysql-8.4-migration.info"
grep -q '^manifest=33:171:9:12:15:4:2:1$' "$INSTALL_DIR/mysql-8.4-migration.info"
backup_file="$(find "$INSTALL_DIR/backups" -name 'mysql-5.7-before-8.4-*.sql.gz' -print -quit)"
test -n "$backup_file"
gzip -t "$backup_file"
physical_backup="$(find "$INSTALL_DIR/backups" -name 'mysql-5.7-physical-*.tar.gz' -print -quit)"
test -n "$physical_backup"
tar -tzf "$physical_backup" >/dev/null
test -f "$physical_backup.sha256"
gzip -t "$INSTALL_DIR/backups/panbox-search-latest.sql.gz"

echo 'PASS panbox-search MySQL 5.7 -> 8.4 migration and repeat update flow'
