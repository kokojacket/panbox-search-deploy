#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'if [ "${KEEP_TMP:-0}" = 1 ]; then echo "fixture: $TMP_DIR"; else rm -rf "$TMP_DIR"; fi' EXIT

file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

assert_private() {
    local mode
    mode="$(file_mode "$1")"
    if [ $((8#$mode & 077)) -ne 0 ]; then
        echo "FAIL recovery artifact is accessible by group/other: $1 ($mode)" >&2
        exit 1
    fi
}

make_fixture() {
    local name="$1"
    local variant="${2:-main}"
    local fixture="$TMP_DIR/$name"
    local prefix="panbox-search"
    local poller="panbox-openilink-poller"
    if [ "$variant" = beta ]; then
        prefix="panbox-search-beta"
        poller="panbox-search-beta-openilink-poller"
    fi

    mkdir -p "$fixture/install/mysql" "$fixture/state" "$fixture/bin"
    touch "$fixture/install/mysql/ibdata1"
    printf '%s\n' true > "$fixture/state/$prefix-mysql.running"
    printf '%s\n' true > "$fixture/state/$prefix-app.running"
    printf '%s\n' true > "$fixture/state/$poller.running"
    printf '%s\n' 5.7.44 > "$fixture/state/$prefix-mysql.version"
    : > "$fixture/state/docker.log"

    cat > "$fixture/install/docker-compose.yml" <<YAML
services:
  mysql:
    image: mysql:5.7
    volumes:
      - /opt/$prefix/mysql:/var/lib/mysql
YAML
    printf 'APP_PORT=8888\n' > "$fixture/install/.env"

cat > "$fixture/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url=""
output=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        output="$2"
        shift 2
    else
        url="$1"
        shift
    fi
done
if [ -n "$output" ] && [[ "$url" == *docker-compose.yml ]]; then
    cp "$FAKE_COMPOSE_SOURCE" "$output"
    exit 0
fi
if [ -n "$output" ] && [[ "$url" == *panbox-search*.sh ]] && [ -n "${FAKE_SCRIPT_SOURCE:-}" ]; then
    cp "$FAKE_SCRIPT_SOURCE" "$output"
    exit 0
fi
exit 1
SH
    cat > "$fixture/bin/clear" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$fixture/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$fixture/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

state_file() { printf '%s/%s.running\n' "$FAKE_DOCKER_STATE" "$1"; }
printf '%s\n' "$*" >> "$FAKE_DOCKER_STATE/docker.log"

case "${1:-}" in
    --version) echo 'Docker version 27.test' ;;
    info) exit 0 ;;
    ps) ;;
    compose)
        shift
        case "${1:-}" in
            version) echo 'Docker Compose version v2.test' ;;
            pull)
                if [ "${FAKE_PULL_FAIL:-0}" = 1 ]; then exit 25; fi
                ;;
            down)
                printf '%s\n' false > "$(state_file "$FAKE_MYSQL")"
                printf '%s\n' false > "$(state_file "$FAKE_APP")"
                printf '%s\n' false > "$(state_file "$FAKE_POLLER")"
                ;;
            up)
                printf '%s\n' true > "$(state_file "$FAKE_MYSQL")"
                if grep -q 'image: mysql:8.4' docker-compose.yml; then
                    printf '%s\n' 8.4.10 > "$FAKE_DOCKER_STATE/$FAKE_MYSQL.version"
                    mkdir -p "$FAKE_INSTALL/mysql-8.4"
                    touch "$FAKE_INSTALL/mysql-8.4/ibdata1"
                fi
                last=""
                for arg in "$@"; do last="$arg"; done
                if [ "$last" != mysql ]; then
                    printf '%s\n' true > "$(state_file "$FAKE_APP")"
                    printf '%s\n' true > "$(state_file "$FAKE_POLLER")"
                fi
                ;;
        esac
        ;;
    run)
        container=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --name ]; then container="${2:?}"; shift 2; else shift; fi
        done
        test -n "$container"
        printf '%s\n' true > "$(state_file "$container")"
        printf '%s\n' 5.7.44 > "$FAKE_DOCKER_STATE/$container.version"
        echo fake-container-id
        ;;
    rm)
        container=""
        for arg in "$@"; do container="$arg"; done
        rm -f "$(state_file "$container")" "$FAKE_DOCKER_STATE/$container.version"
        ;;
    inspect)
        container=""
        for arg in "$@"; do container="$arg"; done
        file="$(state_file "$container")"
        test -f "$file"
        if [ "${2:-}" = -f ]; then
            if [[ "${3:-}" == *RestartCount* ]]; then echo 0; else cat "$file"; fi
        fi
        ;;
    stop)
        container=""
        for arg in "$@"; do container="$arg"; done
        printf '%s\n' false > "$(state_file "$container")"
        ;;
    start) printf '%s\n' true > "$(state_file "${2:?}")" ;;
    logs) ;;
    exec)
        shift
        container="${1:?}"
        joined="$*"
        if [[ "$joined" == *mysqladmin* ]]; then
            if [ "${FAKE_RECOVERY_NOT_READY:-0}" = 1 ] && [[ "$container" == *mysql57-recovery ]]; then exit 1; fi
            exit 0
        fi
        if [[ "$joined" == *mysqldump* ]]; then
            if [ "${FAKE_FAIL_DUMP:-0}" = 1 ]; then exit 23; fi
            for table in qf_conf qf_node qf_auth qf_source qf_schema_migrations qf_source_link qf_source_tag_relation qf_source_log qf_openilink_bind qf_saas_user; do
                if [ "${FAKE_OMIT_MIGRATION_TABLES:-0}" = 1 ] \
                    && { [ "$table" = qf_schema_migrations ] || [ "$table" = qf_openilink_bind ]; }; then
                    continue
                fi
                if [ "$table" != "${FAKE_MISSING_DUMP_TABLE:-}" ]; then
                    printf 'CREATE TABLE `%s` (`id` int);\n' "$table"
                fi
            done
            exit 0
        fi
        if [[ "$joined" == *'curl -fsS http://127.0.0.1/api'* ]]; then exit 0; fi
        if [[ "$joined" == *'php /var/www/html/think db:migrate'* ]]; then exit 0; fi
        if [[ "$joined" == *'mysql -N '* ]]; then
            last=""
            for arg in "$@"; do last="$arg"; done
            case "$last" in
                *'SELECT VERSION()'*) cat "$FAKE_DOCKER_STATE/$container.version" ;;
                *'table_name ='*)
                    if [ "$container" = "$FAKE_MYSQL" ] \
                        && [ "${FAKE_EXISTING_84_COMPLETE:-0}" != 1 ] \
                        && [ ! -f "$FAKE_DOCKER_STATE/imported" ]; then
                        echo 0
                    else
                        echo 1
                    fi
                    ;;
                *'information_schema.tables'*) echo 33 ;;
                *'COUNT(*) FROM qf_conf'*) echo 171 ;;
                *'COUNT(*) FROM qf_source_link'*) echo 12 ;;
                *'COUNT(*) FROM qf_source_tag_relation'*) echo 15 ;;
                *'COUNT(*) FROM qf_source_log'*) echo 4 ;;
                *'COUNT(*) FROM qf_source'*)
                    if [ "${FAKE_MANIFEST_MISMATCH:-0}" = 1 ] && [ "$container" = "$FAKE_MYSQL" ]; then echo 10; else echo 9; fi
                    ;;
                *'COUNT(*) FROM qf_openilink_bind'*) echo 2 ;;
                *'COUNT(*) FROM qf_saas_user'*) echo 1 ;;
                *) exit 1 ;;
            esac
        fi
        if [[ "$joined" == *'mysql -uroot '* ]]; then
            cat >/dev/null
            if [ "${FAKE_IMPORT_FAIL:-0}" = 1 ]; then exit 24; fi
            touch "$FAKE_DOCKER_STATE/imported"
            exit 0
        fi
        ;;
    *) exit 1 ;;
esac
SH
    chmod +x "$fixture/bin/curl" "$fixture/bin/clear" "$fixture/bin/docker" "$fixture/bin/sleep"
}

make_fixture stable main
fixture="$TMP_DIR/stable"
sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/panbox-search.sh" > "$fixture/panbox-search.sh"
chmod +x "$fixture/panbox-search.sh"

set +e
printf '2\n\n' | PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-mysql \
    FAKE_APP=panbox-search-app \
    FAKE_POLLER=panbox-openilink-poller \
    FAKE_FAIL_DUMP=1 \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1 \
    bash "$fixture/panbox-search.sh" > "$fixture/output.log" 2>&1
status=$?
set -e

test "$status" -ne 0
if grep -q '^compose up -d --remove-orphans$' "$fixture/state/docker.log"; then
    echo 'FAIL main menu continued to full compose up after backup failure' >&2
    exit 1
fi
if grep -q '系统更新完成' "$fixture/output.log"; then
    echo 'FAIL main menu reported success after backup failure' >&2
    exit 1
fi

echo 'PASS main menu stops when database backup fails'

make_fixture cli-failure main
fixture="$TMP_DIR/cli-failure"
sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/panbox-search.sh" > "$fixture/panbox-search.sh"
chmod +x "$fixture/panbox-search.sh"

set +e
PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-mysql \
    FAKE_APP=panbox-search-app \
    FAKE_POLLER=panbox-openilink-poller \
    FAKE_FAIL_DUMP=1 \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1 \
    bash "$fixture/panbox-search.sh" update > "$fixture/output.log" 2>&1
status=$?
set -e
test "$status" -ne 0
if grep -q '^compose up -d --remove-orphans$' "$fixture/state/docker.log"; then
    echo 'FAIL main CLI continued to full compose up after backup failure' >&2
    exit 1
fi

echo 'PASS main CLI stops when database backup fails'

for variant in main beta; do
    make_fixture "$variant-pull-failure" "$variant"
    fixture="$TMP_DIR/$variant-pull-failure"
    script="panbox-search.sh"
    self_updated="PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1"
    mysql="panbox-search-mysql"
    app="panbox-search-app"
    poller="panbox-openilink-poller"
    if [ "$variant" = beta ]; then
        script="panbox-search-beta.sh"
        self_updated="PANBOX_SEARCH_BETA_SCRIPT_SELF_UPDATED=1"
        mysql="panbox-search-beta-mysql"
        app="panbox-search-beta-app"
        poller="panbox-search-beta-openilink-poller"
    fi
    mkdir -p "$fixture/install/mysql-8.4"
    touch "$fixture/install/mysql-8.4/partial.ibd"
    printf '%s\n' 8.4.10 > "$fixture/state/$mysql.version"
    sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/$script" > "$fixture/$script"
    chmod +x "$fixture/$script"

    set +e
    env PATH="$fixture/bin:$PATH" \
        FAKE_DOCKER_STATE="$fixture/state" \
        FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
        FAKE_INSTALL="$fixture/install" \
        FAKE_MYSQL="$mysql" \
        FAKE_APP="$app" \
        FAKE_POLLER="$poller" \
        FAKE_PULL_FAIL=1 \
        VERIFY_STABILITY_DELAY=0 \
        "$self_updated" \
        bash "$fixture/$script" update > "$fixture/output.log" 2>&1
    status=$?
    set -e

    test "$status" -ne 0
    test "$(cat "$fixture/state/$mysql.running")" = false
    test "$(cat "$fixture/state/$app.running")" = false
    test "$(cat "$fixture/state/$poller.running")" = false
    test -f "$fixture/install/mysql/ibdata1"
    test -f "$fixture/install/mysql-8.4/partial.ibd"
    test ! -d "$fixture/install/backups"
    test -z "$(find "$fixture/install" -maxdepth 1 -type d -name 'mysql-8.4.failed-*' -print -quit)"
    if grep -q '^run -d --name .*mysql57-recovery ' "$fixture/state/docker.log" \
        || grep -q '^compose up ' "$fixture/state/docker.log"; then
        echo "FAIL $variant mutated recovery data or restarted services after pull failure" >&2
        exit 1
    fi
done

echo 'PASS recovery state stops all services before a failed image pull'

for variant in main beta; do
    make_fixture "$variant-complete-markerless" "$variant"
    fixture="$TMP_DIR/$variant-complete-markerless"
    script="panbox-search.sh"
    self_updated="PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1"
    mysql="panbox-search-mysql"
    app="panbox-search-app"
    poller="panbox-openilink-poller"
    if [ "$variant" = beta ]; then
        script="panbox-search-beta.sh"
        self_updated="PANBOX_SEARCH_BETA_SCRIPT_SELF_UPDATED=1"
        mysql="panbox-search-beta-mysql"
        app="panbox-search-beta-app"
        poller="panbox-search-beta-openilink-poller"
    fi
    mkdir -p "$fixture/install/mysql-8.4"
    touch "$fixture/install/mysql-8.4/current-data.ibd"
    printf '%s\n' 8.4.10 > "$fixture/state/$mysql.version"
    sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/$script" > "$fixture/$script"
    chmod +x "$fixture/$script"

    set +e
    env PATH="$fixture/bin:$PATH" \
        FAKE_DOCKER_STATE="$fixture/state" \
        FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
        FAKE_INSTALL="$fixture/install" \
        FAKE_MYSQL="$mysql" \
        FAKE_APP="$app" \
        FAKE_POLLER="$poller" \
        FAKE_EXISTING_84_COMPLETE=1 \
        VERIFY_STABILITY_DELAY=0 \
        "$self_updated" \
        bash "$fixture/$script" update > "$fixture/output.log" 2>&1
    status=$?
    set -e

    test "$status" -ne 0
    test "$(cat "$fixture/state/$mysql.running")" = true
    test "$(cat "$fixture/state/$app.running")" = true
    test "$(cat "$fixture/state/$poller.running")" = true
    test -f "$fixture/install/mysql-8.4/current-data.ibd"
    test -z "$(find "$fixture/install" -maxdepth 1 -type d -name 'mysql-8.4.failed-*' -print -quit)"
    test ! -d "$fixture/install/backups"
    grep -q 'MySQL 8.4 核心表完整但迁移标记缺失' "$fixture/output.log"
    if grep -q '^compose down ' "$fixture/state/docker.log" \
        || grep -q '^compose pull$' "$fixture/state/docker.log" \
        || grep -q '^run -d --name .*mysql57-recovery ' "$fixture/state/docker.log"; then
        echo "FAIL $variant rewound a complete markerless MySQL 8.4 database" >&2
        exit 1
    fi
done

echo 'PASS complete markerless MySQL 8.4 databases are preserved for manual inspection'

for variant in main beta; do
    make_fixture "$variant-recovery-readiness" "$variant"
    fixture="$TMP_DIR/$variant-recovery-readiness"
    script="panbox-search.sh"
    self_updated="PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1"
    mysql="panbox-search-mysql"
    app="panbox-search-app"
    poller="panbox-openilink-poller"
    recovery="panbox-search-mysql57-recovery"
    if [ "$variant" = beta ]; then
        script="panbox-search-beta.sh"
        self_updated="PANBOX_SEARCH_BETA_SCRIPT_SELF_UPDATED=1"
        mysql="panbox-search-beta-mysql"
        app="panbox-search-beta-app"
        poller="panbox-search-beta-openilink-poller"
        recovery="panbox-search-beta-mysql57-recovery"
    fi
    mkdir -p "$fixture/install/mysql-8.4"
    touch "$fixture/install/mysql-8.4/partial.ibd"
    printf '%s\n' 8.4.10 > "$fixture/state/$mysql.version"
    sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/$script" > "$fixture/$script"
    chmod +x "$fixture/$script"

    set +e
    env PATH="$fixture/bin:$PATH" \
        FAKE_DOCKER_STATE="$fixture/state" \
        FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
        FAKE_INSTALL="$fixture/install" \
        FAKE_MYSQL="$mysql" \
        FAKE_APP="$app" \
        FAKE_POLLER="$poller" \
        FAKE_RECOVERY_NOT_READY=1 \
        VERIFY_STABILITY_DELAY=0 \
        "$self_updated" \
        bash "$fixture/$script" update > "$fixture/output.log" 2>&1
    status=$?
    set -e

    test "$status" -ne 0
    test ! -f "$fixture/state/$recovery.running"
    test "$(cat "$fixture/state/$app.running")" = false
    test "$(cat "$fixture/state/$poller.running")" = false
done

echo 'PASS failed MySQL 5.7 recovery readiness removes the isolated container'

make_fixture recovery main
fixture="$TMP_DIR/recovery"
chmod 777 "$fixture/install"
mkdir -p "$fixture/install/mysql-8.4"
touch "$fixture/install/mysql-8.4/partial.ibd"
printf '%s\n' 8.4.10 > "$fixture/state/panbox-search-mysql.version"
sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/panbox-search.sh" > "$fixture/panbox-search.sh"
chmod +x "$fixture/panbox-search.sh"

set +e
PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-mysql \
    FAKE_APP=panbox-search-app \
    FAKE_POLLER=panbox-openilink-poller \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1 \
    bash "$fixture/panbox-search.sh" update > "$fixture/output.log" 2>&1
status=$?
set -e

if [ "$status" -ne 0 ]; then
    echo 'FAIL interrupted migration was not recovered' >&2
    sed -n '1,220p' "$fixture/output.log" >&2
    exit 1
fi
failed_target="$(find "$fixture/install" -maxdepth 1 -type d -name 'mysql-8.4.failed-*' -print -quit)"
physical_backup="$(find "$fixture/install/backups" -name 'mysql-5.7-physical-*.tar.gz' -print -quit)"
logical_backup="$(find "$fixture/install/backups" -name 'mysql-5.7-before-8.4-*.sql.gz' -print -quit)"
test -n "$failed_target"
test -f "$failed_target/partial.ibd"
test -n "$physical_backup"
tar -tzf "$physical_backup" >/dev/null
test -f "$physical_backup.sha256"
test -n "$logical_backup"
gzip -t "$logical_backup"
marker="$fixture/install/mysql-8.4-migration.info"
grep -q '^source_version=5.7.44$' "$marker"
grep -q '^target_version=8.4.10$' "$marker"
grep -q '^source_manifest=33:171:9:12:15:4:2:1$' "$marker"
grep -q '^target_manifest=33:171:9:12:15:4:2:1$' "$marker"
grep -q "^failed_target_archive=$failed_target$" "$marker"
grep -q '^run -d --name panbox-search-mysql57-recovery ' "$fixture/state/docker.log"
test "$(file_mode "$fixture/install/backups")" = 700
test "$(file_mode "$fixture/install")" = 755
for artifact in "$physical_backup" "$physical_backup.sha256" "$logical_backup" "$logical_backup.log" "$marker"; do
    assert_private "$artifact"
done

echo 'PASS interrupted migration is rebuilt from protected MySQL 5.7 data'

recovery_runs_before="$(grep -c '^run -d --name panbox-search-mysql57-recovery ' "$fixture/state/docker.log")"
PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-mysql \
    FAKE_APP=panbox-search-app \
    FAKE_POLLER=panbox-openilink-poller \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1 \
    bash "$fixture/panbox-search.sh" update > "$fixture/repeat-output.log" 2>&1
recovery_runs_after="$(grep -c '^run -d --name panbox-search-mysql57-recovery ' "$fixture/state/docker.log")"
test "$recovery_runs_after" = "$recovery_runs_before"
assert_private "$fixture/install/backups/panbox-search-latest.sql.gz"

echo 'PASS successful recovery is not repeated by the next update'

make_fixture import-failure main
fixture="$TMP_DIR/import-failure"
mkdir -p "$fixture/install/mysql-8.4"
touch "$fixture/install/mysql-8.4/partial.ibd"
printf '%s\n' 8.4.10 > "$fixture/state/panbox-search-mysql.version"
sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/panbox-search.sh" > "$fixture/panbox-search.sh"
chmod +x "$fixture/panbox-search.sh"

set +e
PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-mysql \
    FAKE_APP=panbox-search-app \
    FAKE_POLLER=panbox-openilink-poller \
    FAKE_IMPORT_FAIL=1 \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1 \
    bash "$fixture/panbox-search.sh" update > "$fixture/output.log" 2>&1
status=$?
set -e
test "$status" -ne 0
test -d "$fixture/install/mysql"
test -n "$(find "$fixture/install/backups" -name 'mysql-5.7-physical-*.tar.gz' -print -quit)"
test -n "$(find "$fixture/install/backups" -name 'mysql-5.7-before-8.4-*.sql.gz' -print -quit)"
test -n "$(find "$fixture/install" -maxdepth 1 -type d -name 'mysql-8.4.failed-*' -print -quit)"
test ! -f "$fixture/install/mysql-8.4-migration.info"
test "$(cat "$fixture/state/panbox-search-app.running")" = false
test "$(cat "$fixture/state/panbox-openilink-poller.running")" = false

echo 'PASS import failure preserves every recovery artifact and keeps writers stopped'

make_fixture manifest-failure main
fixture="$TMP_DIR/manifest-failure"
mkdir -p "$fixture/install/mysql-8.4"
touch "$fixture/install/mysql-8.4/partial.ibd"
printf '%s\n' 8.4.10 > "$fixture/state/panbox-search-mysql.version"
sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/panbox-search.sh" > "$fixture/panbox-search.sh"
chmod +x "$fixture/panbox-search.sh"

set +e
PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-mysql \
    FAKE_APP=panbox-search-app \
    FAKE_POLLER=panbox-openilink-poller \
    FAKE_MANIFEST_MISMATCH=1 \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1 \
    bash "$fixture/panbox-search.sh" update > "$fixture/output.log" 2>&1
status=$?
set -e
test "$status" -ne 0
test ! -f "$fixture/install/mysql-8.4-migration.info"
test "$(cat "$fixture/state/panbox-search-app.running")" = false
test "$(cat "$fixture/state/panbox-openilink-poller.running")" = false
grep -q '迁移后数据校验失败' "$fixture/output.log"

echo 'PASS manifest mismatch blocks marker creation and application startup'

make_fixture core-table-failure main
fixture="$TMP_DIR/core-table-failure"
mkdir -p "$fixture/install/mysql-8.4"
touch "$fixture/install/mysql-8.4/partial.ibd"
printf '%s\n' 8.4.10 > "$fixture/state/panbox-search-mysql.version"
sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/panbox-search.sh" > "$fixture/panbox-search.sh"
chmod +x "$fixture/panbox-search.sh"

set +e
PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-mysql \
    FAKE_APP=panbox-search-app \
    FAKE_POLLER=panbox-openilink-poller \
    FAKE_MISSING_DUMP_TABLE=qf_node \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1 \
    bash "$fixture/panbox-search.sh" update > "$fixture/output.log" 2>&1
status=$?
set -e
test "$status" -ne 0
test ! -f "$fixture/install/mysql-8.4-migration.info"
test "$(cat "$fixture/state/panbox-search-app.running")" = false
test "$(cat "$fixture/state/panbox-openilink-poller.running")" = false
grep -q '逻辑备份缺少核心表 qf_node' "$fixture/output.log"

echo 'PASS missing application core table blocks migration marker creation'

make_fixture legacy-schema main
fixture="$TMP_DIR/legacy-schema"
mkdir -p "$fixture/install/mysql-8.4"
touch "$fixture/install/mysql-8.4/partial.ibd"
printf '%s\n' 8.4.10 > "$fixture/state/panbox-search-mysql.version"
sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/panbox-search.sh" > "$fixture/panbox-search.sh"
chmod +x "$fixture/panbox-search.sh"

PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-mysql \
    FAKE_APP=panbox-search-app \
    FAKE_POLLER=panbox-openilink-poller \
    FAKE_OMIT_MIGRATION_TABLES=1 \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_SCRIPT_SELF_UPDATED=1 \
    bash "$fixture/panbox-search.sh" update > "$fixture/output.log" 2>&1

test -f "$fixture/install/mysql-8.4-migration.info"

echo 'PASS legacy schemas may omit tables created by db:migrate'

make_fixture beta-failure beta
fixture="$TMP_DIR/beta-failure"
sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/panbox-search-beta.sh" > "$fixture/panbox-search-beta.sh"
chmod +x "$fixture/panbox-search-beta.sh"

set +e
PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-beta-mysql \
    FAKE_APP=panbox-search-beta-app \
    FAKE_POLLER=panbox-search-beta-openilink-poller \
    FAKE_FAIL_DUMP=1 \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_BETA_SCRIPT_SELF_UPDATED=1 \
    bash "$fixture/panbox-search-beta.sh" update > "$fixture/output.log" 2>&1
status=$?
set -e

test "$status" -ne 0
if grep -q '^compose up -d --remove-orphans$' "$fixture/state/docker.log"; then
    echo 'FAIL Beta continued to full compose up after backup failure' >&2
    exit 1
fi
test "$(cat "$fixture/state/panbox-search-beta-app.running")" = false
test "$(cat "$fixture/state/panbox-search-beta-openilink-poller.running")" = false
test -n "$(find "$fixture/install/backups" -name 'mysql-5.7-physical-*.tar.gz' -print -quit)"
test -n "$(find "$fixture/install/backups" -name 'mysql-5.7-before-8.4-*.sql.gz.log' -print -quit)"
test "$(file_mode "$fixture/install/backups")" = 700
while IFS= read -r artifact; do
    assert_private "$artifact"
done < <(find "$fixture/install/backups" -type f)

echo 'PASS Beta stops and preserves recovery artifacts when backup fails'

make_fixture beta-recovery beta
fixture="$TMP_DIR/beta-recovery"
mkdir -p "$fixture/install/mysql-8.4"
touch "$fixture/install/mysql-8.4/partial.ibd"
printf '%s\n' 8.4.10 > "$fixture/state/panbox-search-beta-mysql.version"
sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/panbox-search-beta.sh" > "$fixture/panbox-search-beta.sh"
chmod +x "$fixture/panbox-search-beta.sh"

PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-beta-mysql \
    FAKE_APP=panbox-search-beta-app \
    FAKE_POLLER=panbox-search-beta-openilink-poller \
    VERIFY_STABILITY_DELAY=0 \
    PANBOX_SEARCH_BETA_SCRIPT_SELF_UPDATED=1 \
    bash "$fixture/panbox-search-beta.sh" update > "$fixture/output.log" 2>&1

failed_target="$(find "$fixture/install" -maxdepth 1 -type d -name 'mysql-8.4.failed-*' -print -quit)"
test -n "$failed_target"
test -f "$failed_target/partial.ibd"
marker="$fixture/install/mysql-8.4-migration.info"
grep -q '^source_manifest=33:171:9:12:15:4:2:1$' "$marker"
grep -q '^target_manifest=33:171:9:12:15:4:2:1$' "$marker"
grep -q '^run -d --name panbox-search-beta-mysql57-recovery ' "$fixture/state/docker.log"

echo 'PASS Beta interrupted migration uses the same protected recovery flow'

make_fixture self-update main
fixture="$TMP_DIR/self-update"
mkdir -p "$fixture/install/mysql-8.4"
touch "$fixture/install/mysql-8.4/partial.ibd"
printf '%s\n' 8.4.10 > "$fixture/state/panbox-search-mysql.version"
sed "s|^PANBOX_DIR=.*|PANBOX_DIR=\"$fixture/install\"|" "$ROOT_DIR/panbox-search.sh" > "$fixture/latest.sh"
sed 's/^SCRIPT_VERSION=.*/SCRIPT_VERSION="1900.01.01.1"/' "$fixture/latest.sh" > "$fixture/panbox-search.sh"
chmod +x "$fixture/latest.sh" "$fixture/panbox-search.sh"
latest_version="$(grep -m1 '^SCRIPT_VERSION=' "$fixture/latest.sh" | cut -d'"' -f2)"

PATH="$fixture/bin:$PATH" \
    FAKE_DOCKER_STATE="$fixture/state" \
    FAKE_COMPOSE_SOURCE="$ROOT_DIR/docker-compose.yml" \
    FAKE_SCRIPT_SOURCE="$fixture/latest.sh" \
    FAKE_INSTALL="$fixture/install" \
    FAKE_MYSQL=panbox-search-mysql \
    FAKE_APP=panbox-search-app \
    FAKE_POLLER=panbox-openilink-poller \
    VERIFY_STABILITY_DELAY=0 \
    bash "$fixture/panbox-search.sh" update > "$fixture/output.log" 2>&1

grep -q "^SCRIPT_VERSION=\"$latest_version\"$" "$fixture/panbox-search.sh"
test -f "$fixture/panbox-search.sh.bak"
test -f "$fixture/install/mysql-8.4-migration.info"
grep -q '开始更新 Panbox-Search 系统' "$fixture/output.log"

echo 'PASS self-update preserves the update argument and enters recovery'
