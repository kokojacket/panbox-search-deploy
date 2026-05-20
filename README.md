# Panbox Search - 一键部署

> 多网盘资源管理与聚合搜索系统

## 🚀 快速部署

```bash
curl -fsSL https://raw.githubusercontent.com/kokojacket/panbox-search-deploy/main/panbox-search.sh -o panbox-search.sh
chmod +x panbox-search.sh
./panbox-search.sh
```

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
