# 雷电面板（ui3344）安装器

**一键安装 / 升级雷电面板**：脚本自包含（只依赖 curl/wget、tar、systemd 或 openrc），
安装包从本仓库的 Release 下载并做 sha256 校验，校验不过就中止。

> 本仓库**只放安装器与安装包**。面板源码在私有仓库里维护，不公开分发；
> 依 GPL-3.0（上游为 [3x-ui](https://github.com/MHSanaei/3x-ui)）：
> **任何拿到安装包的人都有权索取完整对应源码**，需要请在本仓库开 Issue，我们会提供。

---

## 一、安装（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/scaryburial/leidian-installer/main/install-standalone.sh)
```

装完会打印面板地址、账号密码与安全入口，并自动创建 9 个预设协议入站。

### 常用参数

| 参数 | 说明 |
|---|---|
| `--port 33441` | 面板端口 |
| `--username` / `--password` | 面板账号密码（不给则随机生成并打印） |
| `--ssl-mode standalone` `--ssl-domain example.com` `--ssl-email you@example.com` | 面板启用 HTTPS（Let's Encrypt 自签申请） |
| `--ssl-mode cf --ssl-domain example.com` | 面板走 Cloudflare Origin CA 证书 |
| `--preset off` | 不创建预设入站 |
| `--pkg /root/xxx.tar.gz` | 用本地安装包安装（离线场景；仍会校验 sha256） |
| `--dry-run` | 只打印安装计划，不动系统 |

### 域名功能凭据（可选）

面板的「一键启用域名」需要 Cloudflare API Token 与 TOTP 密钥。**公开安装包里不含任何凭据**，
装的时候注入即可（不传也能装，只是域名功能要先补配置）：

```bash
UI3344_CF_TOKEN='cfat_...' UI3344_OTP_SECRET='<base32密钥>' \
  bash install-standalone.sh
```

事后补写（不用重装）：

```bash
UI3344_CF_TOKEN='cfat_...' UI3344_OTP_SECRET='<base32密钥>' \
  python3 /usr/local/ui3344/set-credentials.py
python3 /usr/local/ui3344/set-credentials.py --check   # 只看状态
```

---

## 二、手工安装（离线 / 不跑脚本）

```bash
# 1) 从本仓库 Release 下载对应架构的包（amd64 / arm64）与 .sha256
# 2) 校验
sha256sum -c ui3344-linux-amd64.tar.gz.sha256
# 3) 解包安装（顶层目录就是 ui3344）
tar xzf ui3344-linux-amd64.tar.gz && cd ui3344 && bash install.sh
```

---

## 三、发布前的自检（维护者）

```bash
tar xzf ui3344-linux-amd64.tar.gz
strings -a ui3344/ui3344 | grep -c 'cfat_'    # 必须输出 0：公开制品不能含凭据
```

---

## 四、版本

| 标签 | 说明 |
|---|---|
| `v2.2` | 安装期注入域名凭据（公开包不再内嵌任何凭据）；安装器支持 HTTPS 面板探测；卡密体系 |
| `v2.1` | 卡密系统（批量发卡 / 导出 CSV / `/c/<卡密>` 订阅端点） |
| `v2.0` | 预设协议修复（速度档 Reality、SS2022 统一 aes-256）+ 安卓/桌面客户端支持 |

> 升级不会动数据库与已有入站配置：直接重跑安装器即可（幂等）。