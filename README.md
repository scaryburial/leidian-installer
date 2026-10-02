# 雷电面板（ui3344）独立安装脚本

一个**自包含**的 Linux 安装脚本：从 Release 拉取官方制品，强制 sha256 校验，然后自己生成服务单元、环境文件与随机凭据完成安装。

与产品仓库里的 `install.sh`（薄封装：下载制品后转交包内安装脚本）不同，本脚本**不依赖发行包内的 `install.sh`**，也不从任何可变引用（如 `@main`）拉脚本执行——发行包里带什么，它就装什么。

> 产品本体与发行包在 [scaryburial/leidian-panel](https://github.com/scaryburial/leidian-panel)。本仓库只放安装脚本。

---

## 特性

- **完全自包含**：服务单元、目录、环境文件全部由脚本自己生成，不调用包内安装脚本。
- **校验失败即中止**：制品 sha256 校验不通过就拒绝安装；校验文件为空、缺失、缺校验工具同样中止。
- **init 系统自适应**：systemd / OpenRC / sysvinit 三种形态各自生成服务单元并注册开机自启。
- **发行版覆盖**：deb、rpm、arch、suse、alpine 族系的依赖安装与路径差异均已处理。
- **随机强凭据**：用户名、18 位密码、18 位面板路径默认随机生成，安装结果落盘 `0600`。
- **可选组件**：ACME 证书（standalone / Cloudflare DNS）、fail2ban、预设协议入站。
- **非交互**：所有交互项都有等价环境变量；无 TTY 时走默认值，适合一键脚本与自动化部署。

## 快速开始

```bash
# 默认安装 ui3344（最新固定版本、随机端口路径凭据）
bash install-standalone.sh

# 只做探测并打印安装计划，不改动系统
bash install-standalone.sh --dry-run

# 只做安装前预检：依赖、制品可下载、摘要匹配
bash install-standalone.sh --check
```

安装完成后终端会打印面板地址、账号、密码与面板路径；同样的内容写入结果文件（权限 `0600`）。

## 常用选项

```bash
bash install-standalone.sh --tag v1.7 --port 33441
bash install-standalone.sh --tag latest
bash install-standalone.sh --pkg ./ui3344-linux-amd64.tar.gz \
                           --sha256 ./ui3344-linux-amd64.tar.gz.sha256
bash install-standalone.sh --ssl-domain panel.example.com --ssl-mode cf
bash install-standalone.sh --fail2ban on --preset on
```

| 选项 | 说明 |
| --- | --- |
| `--product <ui3344\|x-ui>` | 产品形态，决定目录/服务名/端口默认值（默认 `ui3344`） |
| `--repo <owner/repo>` | Release 所属仓库（默认随产品） |
| `--tag <tag>` | 发布标签，`latest` 表示取最新（默认随产品） |
| `--pkg <path\|url>` | 指定安装包，跳过 GitHub 下载 |
| `--sha256 <path\|url\|hex>` | 指定校验来源；缺省用 `<包>.sha256` |
| `--arch <amd64\|arm64>` | 覆盖架构探测结果 |
| `--port` / `--username` / `--password` / `--web-base-path` | 面板端口与凭据（默认随机） |
| `--ssl-domain` `--ssl-mode <standalone\|cf>` `--ssl-email` | 用 acme.sh 申请并挂载证书 |
| `--fail2ban <auto\|on\|off>` | 是否配置 fail2ban（默认 auto） |
| `--preset <auto\|on\|off>` | 是否创建预设协议入站（默认 auto） |
| `--deps <auto\|skip>` | 是否自动补装依赖（默认 auto） |
| `--dry-run` / `--check` | 打印计划 / 安装前预检 |

完整列表见 `bash install-standalone.sh --help`。

### 等价环境变量

`UI3344_PRODUCT`、`UI3344_REPO`、`UI3344_TAG`、`UI3344_PKG`、`UI3344_SHA256`、`UI3344_PORT`、`UI3344_USERNAME`、`UI3344_PASSWORD`、`UI3344_WEB_BASE_PATH`

## 安全说明

- 默认从 GitHub Release 下载与安装包**同目录**的 `.sha256`；摘要不匹配立即中止。
- 不接受“无校验继续”：取不到期望摘要时直接退出，不提供跳过参数。
- 不使用管道执行远程脚本（没有 `curl | bash` 形式的间接执行路径）。
- 生成的凭据与面板路径落在权限 `0600` 的结果文件里，日志不打印密码。
- 安装目录、数据目录、日志目录、服务名与产品绑定，卸载/重装互不覆盖无关文件。

## 兼容性

- 目标平台：Linux（x86_64 / arm64），需要 root。
- init：systemd、OpenRC（Alpine 等）、sysvinit。
- 依赖：`curl` 或 `wget`；校验需要 `sha256sum` 或 `openssl`（二者皆无则拒绝安装）。

## 已验证

对着 `leidian-panel` 的 **v1.7** 发布制品做过实测，安装脚本的包契约与真实制品一致：

| 检查项 | 结果 |
| --- | --- |
| `ui3344-linux-amd64.tar.gz` sha256 | `83aed7b4813f518141b86f36931416d5bff168e207c3b6f9d56822fae2526147`，与发布 `.sha256` 一致 |
| 包内根目录 | `ui3344/`（脚本按 `*/ui3344` 探测） |
| 主二进制 | `ui3344/ui3344` |
| 内核与 geo | `ui3344/bin/xray-linux-amd64`、`geoip.dat`、`geosite.dat` |
| 随包脚本 | `ui3344.sh`、`ui3344.service.{debian,arch,rhel}`、`ui3344.rc`、`create-inbounds.py`、`configure-subscription.py`、`domain-setup.py` |

`--dry-run` 与 `--version` 已在脚本层验证；完整安装流程（停旧服务、落盘、启动、写配置）请在目标机上以 `--check` 起步执行。

## 许可与致谢

- 本脚本以 **GPL-3.0** 发布（见 `LICENSE`）。
- 结构与系统适配参考了 [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) 的 `install.sh` 并重写；产品本体（雷电面板 / ui3344）是其定制分支。

## 免责声明

仅供个人学习与自用。请遵守你所在地区的法律法规。
