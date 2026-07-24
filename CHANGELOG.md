# Changelog

本文件记录 `deploy` 子仓库的主要变更（含未提交代码）。

## [Unreleased] - 2026-07-25

### Fixed
- 修复正式版交互菜单忽略数据库备份或迁移失败、仍继续启动应用的问题；正式版与 Beta 更新流程现在显式传播所有关键步骤的失败状态。
- 修复旧 MySQL 5.7 与部分 MySQL 8.4 数据同时存在且缺少迁移标记时，后续更新可能把半成品库视为正常数据库的问题。

### Changed
- 正式版与 Beta 更新新增中断迁移自动恢复：先校验磁盘空间并为旧库生成物理保护副本和 SHA-256，再用隔离的 MySQL 5.7 容器重做逻辑备份；失败的 8.4 目录只归档不删除。
- 迁移完成前核对核心表及源、目标数据清单，原子写入包含备份与归档路径的迁移标记；应用、MySQL 与 Poller 启动后执行数据库迁移、API、核心表和 30 秒重启计数复查。
- 只用历史基础表识别空库，允许旧库由迁移命令补建迁移记录与 OpenIlink 表；若现有 8.4 基础表完整但标记缺失则拒绝自动回退，并收紧迁移标记与备份产物权限。
- 正式版与 Beta 部署脚本版本升级到 `2026.07.25.1`。

## [Unreleased] - 2026-07-18

### Added
- 正式版更新脚本新增 MySQL 5.7 到 8.4 的一次性逻辑迁移：停写后生成时间戳备份，使用独立数据目录导入并复核关键数据量；旧 5.7 数据目录保留用于回退。
- Beta 更新脚本新增 MySQL 5.7 到 8.4 的一次性逻辑迁移：停写后生成时间戳备份，使用独立数据目录导入，并按表数及配置、资源、链接、标签关系、转存日志、机器人绑定和 SAAS 用户等关键数据量复核结果；旧 5.7 数据目录保留用于回退。

### Changed
- 正式版 Compose 与一键部署脚本改用 `mysql:8.4` 和 `/opt/panbox-search/mysql-8.4`，移除旧认证参数，并在更新完成后校验数据库版本、应用 API 与 Poller 运行状态。
- Beta Compose 与一键部署脚本改用 `mysql:8.4` 和 `/opt/panbox-search-beta/mysql-8.4`，并移除 MySQL 8.4 已废弃的默认认证插件参数。

## [Unreleased] - 2026-06-29

### Changed
- Beta 部署说明同步为 PHP 8.4 运行基线，`php-8.4` 标签保留为独立验证通道。
- `panbox-search-beta.sh` 更新前自动备份数据库到 `backups/panbox-search-latest.sql.gz`，只保留最新一份；备份失败会中止更新。

### Added
- 新增 `panbox-search-php84.sh` PHP 8.4 迁移验证一键部署脚本，默认安装到 `/opt/panbox-search-php84`，使用 `kokojacket/panbox-search:php-8.4` 镜像。
- 新增 `docker-compose-php84.yml` PHP 8.4 Compose 模板，使用独立容器名、网络、数据目录与默认端口，避免覆盖正式版和 Beta 部署。
- `README.md` 补充 PHP 8.4 迁移验证部署命令与默认配置说明。
- 正式版 `docker-compose.yml` 新增 OpenIlink 独立 Poller 服务，并补齐 app 与 poller 共享的内部接口密钥配置。
- 正式版 `.env.example` 与 `panbox-search.sh` 新增 OpenIlink Poller、Apache Worker 环境变量，旧 `.env` 缺失时自动补齐。

### Changed
- 正式版 OpenIlink Poller 默认长轮询参数对齐当前主仓库推荐配置，提升微信机器人消息轮询稳定性。

## [Unreleased] - 2026-06-02

### Added
- 新增 `panbox-search-beta.sh` Beta 一键部署脚本，默认安装到 `/opt/panbox-search-beta`，使用 `kokojacket/panbox-search:beta` 镜像，并支持 `install/update/start/stop/restart`。
- 新增 `docker-compose-beta.yml` Beta Compose 模板，使用独立容器名、网络、数据目录与默认端口，避免覆盖正式版部署。
- `README.md` 补充 Beta 测试版部署命令与默认配置说明。

## [Unreleased] - 2026-05-30

### Fixed
- `panbox-search.sh`：修复更新时 MySQL 报 `InnoDB: Unable to lock ./ibdata1 error: 11` 且宿主机残留多个 mysqld 进程的问题。更新流程由原先的 `up -d --force-recreate` 改为「先 `down --remove-orphans -t 60` 彻底停止旧容器、等待 MySQL 释放数据目录锁，再 `up -d --remove-orphans` 启动」，消除新旧 mysqld 同时打开同一份数据目录的抢锁窗口。

### Changed
- `panbox-search.sh`：安装、启动、停止、重启流程统一加 `--remove-orphans` 清理孤儿容器；停止/重启使用 `-t 60` 给 MySQL 足够的优雅关闭时间，避免被默认 10 秒超时强杀后触发下次启动的 crash recovery。
- `panbox-search.sh`：`SCRIPT_VERSION` 升级到 `2026.05.30.1`，触发用户端强制自更新拉取上述修复。

## [Unreleased] - 2026-05-21

### Changed
- `docker-compose.yml`：新增 `/var/www/html/data` 持久化挂载（`/opt/panbox-search/app/data`），用于保存设备 UUID 等关键标识。
- `panbox-search.sh`：安装流程新增 `mkdir -p "${PANBOX_DIR}/app/data"`，与 compose 挂载目录保持一致。
- `panbox-search.sh`：安装流程新增 `mkdir -p "${PANBOX_DIR}/mysql"`，确保 MySQL 数据目录与提示信息一致。
- `panbox-search.sh`：部署完成信息改为仅展示最终访问路径（内网/外网），并在未检测到 IP 时给出明确提示。
- `panbox-search.sh`：移除部署完成后的本地地址、数据库配置、目录结构与常用命令展示，减少无关输出。
- `panbox-search.sh`：菜单选项 `2`（更新系统）默认走非交互覆盖流程，不再询问是否覆盖 `docker-compose.yml`。
- `panbox-search.sh`：下载 `docker-compose.yml` 增加重试机制（最多 3 次），并将单次总超时调整为 8 秒，减少首次网络抖动导致的卡住问题。
- `panbox-search.sh`：下载 `docker-compose.yml` 新增多下载源自动切换（gh-proxy/hk/cdn/edgeone/raw），单源失败后自动切换下一个源提升成功率。
- `panbox-search.sh`：外网地址探测改为仅获取 IPv4（`curl -4` + IPv4 格式校验），避免误显示 IPv6 地址。
- `panbox-search.sh`：修复部署完成阶段公网 IP 获取失败导致脚本提前退出的问题（在 `set -e` 下改为非致命并限制 3 秒超时）。
- `panbox-search.sh`：精简部署完成区域的分割线与冗余提示，保留关键状态和最终访问路径，提升终端可读性。
- `docker-compose.yml`：新增 Redis 服务与 `/opt/panbox-search/redis` 持久化目录，Docker 部署默认使用 Redis 缓存。
- `.env.example`：新增 `CACHE_DRIVER` 与 `REDIS_*` 配置，支持回退到文件缓存。
- `panbox-search.sh`：安装与更新流程补齐 Redis 数据目录和缓存环境变量，避免旧 `.env` 缺少缓存配置。
- `panbox-search.sh`：新增 `SCRIPT_VERSION` 脚本版本号与启动前强制自更新检查，自动从多下载源获取最新脚本、语法校验后替换并重启，避免用户使用过期脚本更新。
- `README.md` / `docker-deploy.md`：补充 Redis 默认缓存、持久化路径与文件缓存回退说明。

## [bab1c83] - 2026-02-12

### Changed
- 更新 `.gitignore`。

## [b60eb8e] - 2026-01-11

### Refactor
- 移除无用的管理员账号环境变量（涉及 `.env.example`、`docker-compose.yml`）。

## [77a15f5] - 2026-01-10

### Docs
- 简化 `README.md` 部署步骤。

## [4fe556e] - 2026-01-10

### Docs
- 新增 `README.md` 快速部署指南。

## [081a4d8] - 2026-01-10

### Fixed
- 修复一键部署脚本中 `docker-compose.yml` 下载地址。

## [b242559] - 2026-01-10

### Added
- 新增一键部署脚本 `panbox-search.sh`。

## [e865597] - 2026-01-10

### Added
- 初始化部署仓库基础文件：`.env.example`、`.gitignore`、`docker-compose.yml`、`docker-deploy.md`。
