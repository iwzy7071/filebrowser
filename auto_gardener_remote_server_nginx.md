# auto_gardener 远程服务器 / Nginx / Relay 流程说明

生成时间：2026-06-19（Asia/Shanghai）  
项目目录：`/Users/wangzy/Desktop/auto_gardener`  
当前 Git HEAD：`8d65acd`  
主要依据：`DEPLOY_MULTI_INSTANCE_RELAY.md`、`deploy/gardener-relay.py`、`config/gardener-relay.env.example`、`packaging/windows/install-gardener.ps1`、`packaging/macos/install-gardener.sh`

> 安全说明：本仓库当前没有 `config/gardener-relay.env.local`，也没有可提交的真实服务器 IP、域名、frp token、Basic Auth 密码或 SetupKey。本文件只整理流程、路径、端口和模板；真实密钥请只保存在 VPS 或管理员本机，不要写入 Git 或公开文档。

---

## 1. 当前推荐架构

当前项目的远程访问是“本地优先 + VPS 中转”模式：

```text
用户浏览器 / 手机 / 钉钉
        ↓ HTTP/HTTPS，访问每个用户独立公网端口或域名
公网 VPS：Nginx + frps + 下载目录 + gardener-relay 管理脚本
        ↓ Nginx 反代到 127.0.0.1:<remotePort>
VPS 本机 frps TCP 端口
        ↓ frp TCP 隧道
用户电脑：frpc -> 127.0.0.1:8080 -> 本地 Gardener -> Codex/Claude/本地文件
```

核心边界：

1. Gardener 真正执行任务的位置仍是用户电脑本地。
2. VPS 只负责公网入口、Nginx Basic Auth、frp 中转、安装包/配置分发。
3. 用户电脑上的 Gardener 默认只监听 `127.0.0.1:8080`，避免直接暴露到局域网/公网。
4. 每个用户一套独立公网端口、独立 frp remotePort、独立 Nginx Basic Auth、独立 SetupKey。

---

## 2. 端口规划

来自 `config/gardener-relay.env.example` 和 `deploy/gardener-relay.py` 的默认值：

| 类型 | 默认值 / 范围 | 说明 |
|---|---:|---|
| frps control port | `27000` | 用户电脑 `frpc` 连接 VPS 的 frp 控制端口。 |
| publicPort | `28081-28100` | 浏览器访问的公网端口，每个用户一个。 |
| remotePort | `18081-18100` | frps 在 VPS 本机监听的 TCP 端口，Nginx 反代到这里。 |
| 本地 Gardener | `127.0.0.1:8080` | 用户电脑本地服务地址。 |
| 下载入口 | 通常 `80` 或域名 HTTPS | 用于 `/downloads/` 安装包和 provision 文件。 |

旧文档中也提到过“frp HTTP vhost + 子域名”的方案；但当前 `deploy/gardener-relay.py` 生成的是 `type = "tcp"` 的 frpc 配置，并由 Nginx 将每个 `publicPort` 反代到对应 `127.0.0.1:<remotePort>`。

---

## 3. VPS 上的关键路径

`deploy/gardener-relay.py` 使用的路径如下：

| 路径 | 用途 |
|---|---|
| `/usr/local/bin/gardener-relay` | 建议安装位置，即 `deploy/gardener-relay.py`。 |
| `/etc/gardener-relay/instances.json` | 用户实例状态表。权限应为 `0600`。 |
| `/etc/gardener-relay/users/<user>/htpasswd` | 该用户公网入口的 Nginx Basic Auth 文件。 |
| `/etc/gardener-relay/users/<user>/frpc.toml` | 分发给该用户电脑的 frpc 配置，内含 frp token，必须保密。 |
| `/etc/frp/frps.toml` | VPS 上 frps 配置；`gardener-relay` 会读取其中 `auth.token`。 |
| `/etc/nginx/conf.d/gardener-user-<user>.conf` | 每个用户一份 Nginx 反代配置，由脚本生成。 |
| `/srv/gardener-downloads/public` | 公开下载根目录。 |
| `/srv/gardener-downloads/public/provision/<setupKey>/gardener.provision.json` | 一键安装时读取的临时配置 JSON，含密码与 frpc 配置，必须视为密钥。 |

---

## 4. VPS 环境变量配置

先从示例复制本地配置：

```bash
cp config/gardener-relay.env.example config/gardener-relay.env.local
$EDITOR config/gardener-relay.env.local
```

典型内容如下（真实值不要提交）：

```bash
GARDENER_RELAY_SERVER_ADDR=YOUR_RELAY_SERVER
GARDENER_RELAY_PUBLIC_BASE_URL=http://YOUR_RELAY_SERVER

GARDENER_RELAY_FRPS_PORT=27000
GARDENER_RELAY_PUBLIC_START=28081
GARDENER_RELAY_PUBLIC_END=28100
GARDENER_RELAY_REMOTE_START=18081
GARDENER_RELAY_REMOTE_END=18100

# 默认开启；只有可信私有环境才考虑设为 0
GARDENER_RELAY_REQUIRE_BASIC_AUTH=1
```

执行管理命令前加载：

```bash
set -a
source config/gardener-relay.env.local
set +a
```

---

## 5. frps / frpc 关系

### 5.1 VPS：frps

VPS 的 `/etc/frp/frps.toml` 至少需要包含控制端口和 token，例如：

```toml
bindPort = 27000

auth.method = "token"
auth.token = "<强随机 token，仅保存在 VPS>"
```

`gardener-relay` 创建用户时会读取 `/etc/frp/frps.toml` 里的 `auth.token`，再写入该用户的 `frpc.toml` 和 provision 文件。

### 5.2 用户电脑：frpc

当前脚本生成的 frpc 配置形态：

```toml
serverAddr = "YOUR_RELAY_SERVER"
serverPort = 27000

auth.method = "token"
auth.token = "<由 VPS /etc/frp/frps.toml 读取>"

[[proxies]]
name = "gardener-<user>"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = <该用户 remotePort，例如 18081>
```

效果：VPS 的 `127.0.0.1:<remotePort>` 会穿透到用户电脑的 `127.0.0.1:8080`。

---

## 6. Nginx 信息

### 6.1 每个用户的公网入口反代配置

`deploy/gardener-relay.py` 为每个用户生成 `/etc/nginx/conf.d/gardener-user-<user>.conf`，模板如下：

```nginx
server {
    listen <publicPort>;
    server_name _;

    client_max_body_size 200m;
    client_header_timeout 10s;
    client_body_timeout 30s;
    send_timeout 30s;
    add_header Cache-Control "no-store" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Frame-Options "DENY" always;

    auth_basic "Gardener";
    auth_basic_user_file /etc/gardener-relay/users/<user>/htpasswd;

    location / {
        proxy_pass http://127.0.0.1:<remotePort>;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Authorization "";
        proxy_set_header Cookie "";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

要点：

- `listen <publicPort>`：用户访问的公网端口，例如 `28081`。
- `proxy_pass http://127.0.0.1:<remotePort>`：转发到 frps 在 VPS 本机暴露的 TCP remotePort。
- 默认开启 Basic Auth；账号是用户 ID，密码由脚本生成或由管理员传入。
- 代理到 Gardener 前会清空 `Authorization` 和 `Cookie`，避免 Basic Auth/Cookie 继续传到后端应用。
- `proxy_read_timeout 3600s` 支持长任务、SSE/长连接场景。

如果某个可信/私有部署必须关闭 Basic Auth：

```bash
gardener-relay add alice --no-basic-auth
# 或
GARDENER_RELAY_REQUIRE_BASIC_AUTH=0 gardener-relay add alice
```

不建议公网关闭；关闭后相当于直接把 Gardener Web/API 暴露给知道端口的人。

### 6.2 下载入口 `/downloads/`

安装脚本依赖如下 URL：

```text
http://YOUR_RELAY_SERVER/downloads/install-gardener.ps1
http://YOUR_RELAY_SERVER/downloads/update-gardener.ps1
http://YOUR_RELAY_SERVER/downloads/Gardener-Windows.zip
http://YOUR_RELAY_SERVER/downloads/frpc.exe
http://YOUR_RELAY_SERVER/downloads/install-gardener-macos.sh
http://YOUR_RELAY_SERVER/downloads/Gardener-macOS-arm64.tar.gz
http://YOUR_RELAY_SERVER/downloads/Gardener-macOS-amd64.tar.gz
http://YOUR_RELAY_SERVER/downloads/provision/<setupKey>/gardener.provision.json
```

因此 VPS 需要一个公开静态下载 Nginx 入口，将 `/downloads/` 映射到 `/srv/gardener-downloads/public/`。示例：

```nginx
server {
    listen 80;
    server_name YOUR_RELAY_SERVER;

    location /downloads/ {
        alias /srv/gardener-downloads/public/;
        autoindex off;
        add_header X-Content-Type-Options "nosniff" always;
    }

    location = /health {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}
```

如果使用 HTTPS/域名，可把 `GARDENER_RELAY_PUBLIC_BASE_URL` 改为 `https://...`，并让证书终止在 Nginx/Caddy。

---

## 7. 管理员常用流程

### 7.1 初始化 VPS

1. 安装 `nginx`、`frps`、Python 3。
2. 配置并启动 `/etc/frp/frps.toml`，确保 `bindPort = 27000` 和强随机 `auth.token`。
3. 将本项目的 `deploy/gardener-relay.py` 安装为：

```bash
install -m 0755 deploy/gardener-relay.py /usr/local/bin/gardener-relay
```

4. 创建下载目录：

```bash
mkdir -p /srv/gardener-downloads/public/provision
```

5. 配置 Nginx 下载入口 `/downloads/`，并保证安全组放行：

```text
80/tcp 或 443/tcp
27000/tcp
28081-28100/tcp
```

6. 检查 Nginx：

```bash
nginx -t
systemctl reload nginx
```

### 7.2 构建并上传安装包

在开发机：

```bash
# Windows
VERSION=0.1.0 ./scripts/build-windows-package.sh

# macOS 双架构
VERSION=0.1.0 ./scripts/build-macos-package.sh
```

上传到 VPS：

```bash
scp dist/Gardener-Windows.zip <relay-host>:/srv/gardener-downloads/public/
scp packaging/windows/install-gardener.ps1 <relay-host>:/srv/gardener-downloads/public/
scp packaging/windows/update-gardener.ps1 <relay-host>:/srv/gardener-downloads/public/
scp packaging/windows/frpc.exe <relay-host>:/srv/gardener-downloads/public/
scp dist/Gardener-macOS-arm64.tar.gz <relay-host>:/srv/gardener-downloads/public/
scp dist/Gardener-macOS-amd64.tar.gz <relay-host>:/srv/gardener-downloads/public/
scp packaging/macos/install-gardener.sh <relay-host>:/srv/gardener-downloads/public/install-gardener-macos.sh
```

> 注意：以上路径假定 Nginx `location /downloads/ { alias /srv/gardener-downloads/public/; }`。如果你改用 `root` 或额外的 `downloads/` 子目录，请同步调整 `GARDENER_RELAY_PUBLIC_BASE_URL` 或 Nginx 映射，保持 URL 与真实目录一一对应。

### 7.3 新增用户

```bash
ssh <relay-host> 'set -a; source /path/to/config/gardener-relay.env.local; set +a; gardener-relay add alice --show-secrets'
```

脚本会完成：

1. 分配 `publicPort` 和 `remotePort`。
2. 创建 `/etc/gardener-relay/users/alice/htpasswd`。
3. 创建 `/etc/gardener-relay/users/alice/frpc.toml`。
4. 写入 `/etc/nginx/conf.d/gardener-user-alice.conf`。
5. 写入 `/etc/gardener-relay/instances.json`。
6. 生成 `/srv/gardener-downloads/public/provision/<setupKey>/gardener.provision.json`。
7. 执行 `nginx -t`，成功后 `systemctl reload nginx`。
8. 输出用户 URL、Basic Auth、SetupKey、Windows/macOS 一键安装命令。

### 7.4 查看 / 补发用户信息

```bash
# 不显示密钥，只看状态
gardener-relay list

gardener-relay list --json

gardener-relay show alice

# 查看 frpc 配置；包含 token，谨慎使用
gardener-relay show alice --with-frpc

# 输出安装命令；会包含 setupKey，谨慎转发
gardener-relay show alice --with-setup-key

# 输出完整 provision；包含网页登录密码和 frp token，必须显式确认
gardener-relay show alice --with-provision --show-secrets
```

### 7.5 删除用户

```bash
gardener-relay remove alice
```

会删除：

- `/etc/nginx/conf.d/gardener-user-alice.conf`
- `/etc/gardener-relay/users/alice/`
- 该用户 setupKey 对应的 provision 目录
- `instances.json` 中的用户记录

并重新加载 Nginx。

---

## 8. 普通用户安装流程

### 8.1 Windows

管理员给用户一条命令，形态如下：

```powershell
powershell -ExecutionPolicy Bypass -Command "iwr http://YOUR_RELAY_SERVER/downloads/install-gardener.ps1 -OutFile install-gardener.ps1; .\install-gardener.ps1 -RelayBaseUrl http://YOUR_RELAY_SERVER -SetupKey sk_xxx -DesktopShortcut -StartMenuShortcut -StartAfterInstall"
```

安装脚本会：

1. 下载 provision JSON。
2. 下载并安装 `Gardener-Windows.zip`。
3. 写入 `%LOCALAPPDATA%\Gardener\frpc.toml`。
4. 写入 `%LOCALAPPDATA%\Gardener\gardener.relay.json`，包含公网 URL、网页账号密码。
5. 写入 `gardener.config.ps1`，让 Gardener 只监听 `127.0.0.1:8080`，数据目录默认 `Desktop\forest_data`。
6. 创建桌面/开始菜单快捷方式。
7. 启动 `gardener.exe` 和 `frpc.exe`。

### 8.2 macOS

管理员给用户命令，形态如下：

```bash
curl -fsSL http://YOUR_RELAY_SERVER/downloads/install-gardener-macos.sh -o install-gardener-macos.sh && bash install-gardener-macos.sh --relay-base-url http://YOUR_RELAY_SERVER --setup-key sk_xxx
```

安装脚本会：

1. 根据架构选择 `Gardener-macOS-arm64.tar.gz` 或 `Gardener-macOS-amd64.tar.gz`。
2. 安装到 `~/Applications/Gardener`。
3. 写入 `frpc.toml`、`gardener.relay.json`、`gardener.config.sh`。
4. 捕获当前 shell 的 PATH、`codex`、`claude` 路径，写入 LaunchAgent 环境。
5. 注册并启动：
   - `com.gardener.local`：本地 Gardener，监听 `127.0.0.1:8080`。
   - `com.gardener.relay`：frpc 公网 relay 隧道。

---

## 9. 验证清单

VPS 上：

```bash
systemctl status nginx --no-pager
systemctl status frps --no-pager
nginx -t
gardener-relay list
ss -ltnp | grep -E ':(27000|28081|18081)\b'
```

新增用户后：

```bash
# 未带 Basic Auth 应返回 401
curl -i http://YOUR_RELAY_SERVER:28081/

# 带 Basic Auth 应穿透到用户本地 Gardener
curl -i -u '<user>:<password>' http://YOUR_RELAY_SERVER:28081/
```

用户电脑上：

```bash
# 本地 Gardener
curl -i http://127.0.0.1:8080/

# frpc 是否运行：Windows 看任务管理器 / 日志；macOS：
launchctl print gui/$(id -u)/com.gardener.relay
```

---

## 10. 安全注意事项

1. 不要把真实 VPS IP/域名、SSH 信息、frp token、Basic Auth 密码、SetupKey、`frpc.toml`、`htpasswd`、provision JSON 提交到 Git。
2. SetupKey 等同于客户端配置密钥；拥有它的人可以下载该用户的 provision，拿到网页密码和 frpc 配置。
3. 当前 HTTP 下载模式下，SetupKey 和密码会经过明文链路；生产或不可信网络建议启用 HTTPS。
4. 公网安全组只放行必要端口：`80/443`、`27000`、已分配的 `28081-28100`。
5. Gardener 有修改本地文件和调用 Codex/Claude 的能力，公网入口默认必须保留 Basic Auth。
6. 用户电脑需要保持在线、不断电、不睡眠，否则远程入口会离线。
7. 如使用 Docker/LAN/自定义反代，且浏览器公网 host 与 Gardener 看到的 upstream `Host` 不一致，应在 Gardener 进程设置：

```bash
AUTO_GARDENER_TRUSTED_PROXIES=<受控代理 IP/CIDR>
# 或更严格地：
AUTO_GARDENER_ALLOWED_ORIGINS=https://alice.gardener.example.com
```

不要把公网客户端网段加入 `AUTO_GARDENER_TRUSTED_PROXIES`。

---

## 11. 当前仓库状态备注

生成本文件时，仓库存在未提交修改：

```text
 M AUTO_GARDENER_REQUIREMENTS.md
 M docs/REFERENCE.md
 M internal/codex/runner.go
 M internal/codex/runner_test.go
 M web/static/app.js
 M web/static/index.html
 M web/static/styles.css
```

这些修改不影响本文整理的 relay/Nginx 文件来源，但如果后续部署，请先确认工作区变更是否应纳入构建包。
