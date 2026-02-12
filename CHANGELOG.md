# Changelog

本文件记录 `deploy` 子仓库的主要变更（含未提交代码）。

## [Unreleased] - 2026-02-13

### Changed
- `panbox-search.sh`：安装流程新增 `mkdir -p "${PANBOX_DIR}/mysql"`，确保 MySQL 数据目录与提示信息一致。
- `panbox-search.sh`：部署完成信息改为仅展示最终访问路径（内网/外网），并在未检测到 IP 时给出明确提示。
- `panbox-search.sh`：移除部署完成后的本地地址、数据库配置、目录结构与常用命令展示，减少无关输出。
- `panbox-search.sh`：菜单选项 `2`（更新系统）默认走非交互覆盖流程，不再询问是否覆盖 `docker-compose.yml`。
- `panbox-search.sh`：下载 `docker-compose.yml` 增加重试机制（最多 3 次），并将单次总超时调整为 8 秒，减少首次网络抖动导致的卡住问题。

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
