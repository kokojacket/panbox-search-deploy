# Panbox Search - 一键部署

> 多网盘资源管理与聚合搜索系统

## 🚀 快速部署

```bash
curl -fsSL https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search.sh -o panbox-search.sh
chmod +x panbox-search.sh
./panbox-search.sh
```

正式版默认使用 `mysql:8.4`，数据目录为 `/opt/panbox-search/mysql-8.4`。更新既有 MySQL 5.7 部署时，脚本会先停止应用与 Poller 写入，生成并校验迁移备份，再导入新的 8.4 数据目录；旧 `/opt/panbox-search/mysql` 目录不会自动删除。

## 🧪 Beta 测试版部署

Beta 版本已使用 PHP 8.4，并使用独立安装目录、容器名、网络与默认端口，不会覆盖正式版部署。直接运行脚本会显示交互菜单，更新时可自行选择是否备份数据库。

```bash
curl -fsSL https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search-beta.sh -o panbox-search-beta.sh
chmod +x panbox-search-beta.sh
./panbox-search-beta.sh
```

默认配置：

- 镜像：`kokojacket/panbox-search:beta`
- 数据库：`mysql:8.4`
- 安装目录：`/opt/panbox-search-beta`
- MySQL 8.4 数据目录：`/opt/panbox-search-beta/mysql-8.4`
- 默认端口：从 `8088` 开始自动查找可用端口

更新既有 MySQL 5.7 Beta 部署时，脚本会停止应用与 Poller 写入，生成并校验迁移备份，再导入新的 MySQL 8.4 数据目录。旧 `/opt/panbox-search-beta/mysql` 目录不会自动删除。

## 🧪 PHP 8.4 独立验证部署

`php-8.4` 标签保留为独立验证通道，使用独立安装目录、容器名、网络与默认端口，不会覆盖正式版或 Beta 部署。

```bash
curl -fsSL https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search-php84.sh -o panbox-search-php84.sh
chmod +x panbox-search-php84.sh
./panbox-search-php84.sh
```

默认配置：

- 镜像：`kokojacket/panbox-search:php-8.4`
- 安装目录：`/opt/panbox-search-php84`
- 默认端口：从 `8094` 开始自动查找可用端口

---

## 📋 系统要求

- **操作系统**: Linux（推荐 Ubuntu/Debian/CentOS）
- **Docker**: >= 20.10
- **Docker Compose**: >= 2.0

---

## 🎯 功能特性

- ✅ 自动检测环境
- ✅ 自动分配端口
- ✅ 交互式菜单
- ✅ 一键安装/更新/重启
- 默认启用 Redis 支撑搜索缓存、限流计数和自动封禁状态

---

## 缓存配置

Docker 部署默认使用 Redis，仅在容器内部网络访问，不暴露 Redis 端口。Redis 数据保存在 `/opt/panbox-search/redis/`。

如需回退到文件缓存，可在 `/opt/panbox-search/.env` 中设置：

```env
CACHE_DRIVER=file
```

修改后执行 `./panbox-search.sh restart` 重启服务。

---

## 📖 更多帮助

安装完成后，可使用以下命令：

```bash
./panbox-search.sh         # 交互式菜单
./panbox-search.sh start   # 启动服务
./panbox-search.sh stop    # 停止服务
./panbox-search.sh restart # 重启服务
```

---

## 📄 License

MIT License
