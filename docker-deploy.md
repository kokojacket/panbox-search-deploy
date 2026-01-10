# Docker部署说明

## 准备工作

确保您的服务器已安装以下软件：

- Docker (20.10.x或更高版本)
- Docker Compose (2.x或更高版本)

## 部署步骤

### 方式一：使用预构建镜像（推荐）

1. 创建项目目录并准备必要文件

```bash
mkdir -p panbox-search/storage/logs
cd panbox-search
```

2. 下载数据库初始化SQL文件

将项目仓库中的`data.sql`文件下载到当前目录。

3. 创建docker-compose.yml文件

```yaml
version: '3'

services:
  app:
    image: ghcr.io/用户名/panbox-search:latest
    ports:
      - "80:80"
    volumes:
      - ./storage/logs:/var/www/html/storage/logs
    environment:
      APP_DEBUG: 'false'
      SYSTEM_SALT: 'YAdmin'
      APP_DEFAULT_TIMEZONE: 'Asia/Chongqing'
      DATABASE_TYPE: 'mysql'
      DATABASE_HOSTNAME: 'mysql'
      DATABASE_DATABASE: 'www_dj_com'
      DATABASE_USERNAME: 'root'
      DATABASE_PASSWORD: 'root'
      DATABASE_HOSTPORT: '3306'
      DATABASE_CHARSET: 'utf8mb4'
      DATABASE_DEBUG: 'false'
      DATABASE_PREFIX: 'qf_'
      LANG_DEFAULT_LANG: 'zh-cn'
    depends_on:
      - mysql
    networks:
      - panbox-network
    restart: always

  mysql:
    image: mysql:5.7
    ports:
      - "3306:3306"
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: www_dj_com
      MYSQL_USER: user
      MYSQL_PASSWORD: password
    volumes:
      - mysql-data:/var/lib/mysql
      - ./data.sql:/docker-entrypoint-initdb.d/data.sql
    networks:
      - panbox-network
    restart: always

networks:
  panbox-network:
    driver: bridge

volumes:
  mysql-data:
```

> 注意：请将`ghcr.io/用户名/panbox-search:latest`中的"用户名"替换为实际的GitHub用户名。

4. 登录到GitHub Container Registry

```bash
# 使用GitHub个人访问令牌登录
echo $GITHUB_TOKEN | docker login ghcr.io -u 你的GitHub用户名 --password-stdin
```

> 如果是公开仓库的镜像，可以跳过此步骤。

5. 启动服务

```bash
docker-compose up -d
```

6. 访问网站

- 前台: http://服务器IP
- 后台: http://服务器IP/qfadmin (账号: admin, 密码: 123456)

### 方式二：从源码构建（开发环境）

1. 克隆代码到服务器

```bash
git clone <项目Git地址> panbox-search
cd panbox-search
```

2. 修改docker-compose.yml文件

将docker-compose.yml中的`image: ghcr.io/用户名/panbox-search:latest`改为：

```yaml
build:
  context: .
  dockerfile: Dockerfile
```

3. 配置环境变量

根据需要修改项目根目录下的`.env`文件，特别是数据库连接信息：

```
[DATABASE]
TYPE = mysql
HOSTNAME = mysql  # 改为mysql服务名
DATABASE = www_dj_com
USERNAME = root  # 与docker-compose.yml中的MYSQL_ROOT_PASSWORD一致
PASSWORD = root  # 与docker-compose.yml中的MYSQL_ROOT_PASSWORD一致
HOSTPORT = 3306
```

4. 启动Docker容器

```bash
docker-compose up -d
```

首次启动会构建Docker镜像，这可能需要几分钟时间。

5. 访问网站

- 前台: http://服务器IP
- 后台: http://服务器IP/qfadmin (账号: admin, 密码: 123456)

## 常见问题

1. 如果遇到权限问题，可以执行以下命令：

```bash
docker-compose exec app chown -R www-data:www-data /var/www/html
```

2. 如需查看应用日志：

```bash
docker-compose logs app
```

3. 如需查看数据库日志：

```bash
docker-compose logs mysql
```

4. 如需进入容器内部：

```bash
# 进入PHP应用容器
docker-compose exec app bash

# 进入MySQL容器
docker-compose exec mysql bash
```

5. 如需重新构建镜像：

```bash
docker-compose build --no-cache
docker-compose up -d
```

## 更新应用

当有新版本发布时，更新应用的步骤如下：

1. 拉取最新代码

```bash
git pull
```

2. 重新构建并启动容器

```bash
docker-compose down
docker-compose build
docker-compose up -d
```

## GitHub Actions自动构建

本项目已配置GitHub Actions工作流，可以自动构建Docker镜像并推送到GitHub Container Registry (ghcr.io)。

### 自动构建触发条件

工作流会在以下情况下自动触发：

1. 向main或master分支推送代码
2. 创建新的版本标签（格式为`v*`，例如`v1.0.0`）
3. 创建针对main或master分支的Pull Request
4. 通过GitHub界面手动触发

### 使用自动构建的镜像

1. 确保你有权限访问GitHub仓库的包

2. 登录到GitHub Container Registry：

```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
```

3. 拉取镜像：

```bash
# 拉取最新版本
docker pull ghcr.io/用户名/panbox-search:latest

# 拉取特定版本
docker pull ghcr.io/用户名/panbox-search:v1.0.0
```

4. 创建docker-compose.yml文件（使用预构建镜像而非本地构建）：

```yaml
version: '3'

services:
  app:
    image: ghcr.io/用户名/panbox-search:latest
    ports:
      - "80:80"
    volumes:
      - ./storage/logs:/var/www/html/storage/logs
    depends_on:
      - mysql
    networks:
      - panbox-network
    restart: always

  mysql:
    image: mysql:5.7
    ports:
      - "3306:3306"
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: www_dj_com
      MYSQL_USER: user
      MYSQL_PASSWORD: password
    volumes:
      - mysql-data:/var/lib/mysql
      - ./data.sql:/docker-entrypoint-initdb.d/data.sql
    networks:
      - panbox-network
    restart: always

networks:
  panbox-network:
    driver: bridge

volumes:
  mysql-data:
```

5. 启动容器：

```bash
docker-compose up -d
```

### 镜像标签说明

GitHub Actions工作流会自动为镜像生成以下标签：

- `latest`: 默认分支的最新提交
- `main` 或 `master`: 对应分支的最新提交
- `v1.0.0`: 对应特定版本标签
- `1.0`: 对应主要和次要版本
- `sha-abc123`: 提交的短SHA值

### 多架构支持

自动构建的镜像支持以下架构：

- linux/amd64 (x86_64)
- linux/arm64 (aarch64)

这意味着镜像可以在各种环境中运行，包括AWS ARM实例和Apple M系列芯片的Mac电脑。

### 手动触发构建

除了自动触发外，您还可以手动触发构建并指定特定版本：

1. 前往GitHub仓库页面，点击"Actions"标签
2. 在左侧选择"构建并推送Docker镜像"工作流
3. 点击"Run workflow"按钮
4. 填写以下参数：
   - **指定版本号**：输入不带"v"前缀的版本号（例如：2.1.0）
   - **同时更新latest标签**：勾选此选项，构建的镜像将同时更新latest标签

![手动触发构建](https://i.imgur.com/example-image.png)

手动触发构建时将生成以下标签：
- `v版本号`（例如：v2.1.0）
- `版本号`（例如：2.1.0）
- 如果勾选了"同时更新latest标签"选项，则还会生成`latest`标签

这一功能特别适用于：
- 需要发布特定版本但不想创建Git标签时
- 想将特定提交标记为latest版本时
- 需要重新构建特定版本时 