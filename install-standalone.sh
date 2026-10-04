#!/usr/bin/env bash
#
# 雷电面板（ui3344）/ 3x-ui 独立安装脚本 —— standalone installer
#
# 与原作者 MHSanaei/3x-ui 的 install.sh 的关系：
#   本脚本参考其结构重写（系统探测、依赖、服务单元、ACME、fail2ban、结果落盘），
#   但**不依赖发行包内的 install.sh**，也不从任何 @main 之类的可变引用拉脚本执行。
#
# 与"薄封装式"在线安装脚本（下载制品 -> 跑包内 install.sh）的区别：
#   1. 完全自包含：服务单元、目录、环境文件全部由本脚本自己生成；
#   2. 制品 sha256 校验失败即中止（校验文件为空、缺校验工具、不匹配都算失败）；
#   3. 自动适配 systemd / OpenRC / sysvinit，覆盖 deb / rpm / arch / suse / alpine；
#   4. 随机强密码 + 安装结果落盘（0600）+ 可选 ACME 证书 / fail2ban / 预设入站。
#
# 用法：
#   bash install-standalone.sh                                  # 默认装 ui3344
#   bash install-standalone.sh --tag v1.7 --port 33441
#   bash install-standalone.sh --pkg ./ui3344-linux-amd64.tar.gz \
#                              --sha256 ./ui3344-linux-amd64.tar.gz.sha256
#   bash install-standalone.sh --ssl-domain panel.example.com --ssl-mode cf
#   bash install-standalone.sh --dry-run                        # 只检测并打印计划
#   bash install-standalone.sh --check                          # 只做安装前预检
#
# 非交互：所有交互项都有对应环境变量（见 usage 末尾），无 TTY 时自动走默认值。
#
set -Eeuo pipefail

SCRIPT_NAME='install-standalone.sh'
SCRIPT_VERSION='1.0.1'

# ────────────────────────────── 默认参数 ──────────────────────────────
PRODUCT='ui3344'                 # ui3344 | x-ui
REPO=''                          # owner/repo，留空按 PRODUCT 取默认
TAG=''                           # 发布标签，留空按 PRODUCT 取默认
PKG_SRC=''                       # 本地包路径或 URL；留空则从 Release 下载
SHA_SRC=''                       # 校验文件路径/URL/裸摘要；留空用 <PKG>.sha256
ARCH_OVERRIDE=''
PORT=''
USERNAME=''
PASSWORD=''
WEB_BASE_PATH=''
SSL_DOMAIN=''
SSL_MODE='off'                   # off | standalone | cf
SSL_EMAIL=''
FAIL2BAN='auto'                  # auto | on | off
PRESET='auto'                    # auto | on | off
DEPS='auto'                      # auto | skip
DRY_RUN=0
CHECK_ONLY=0

TMP_DIR=''
STEP=0
STEPS_TOTAL=9

# ────────────────────────────── 输出与日志 ──────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_BLU=$'\033[0;34m'
    C_YEL=$'\033[0;33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_BLU=''; C_YEL=''; C_DIM=''; C_OFF=''
fi

info() { printf '%s\n' "${C_BLU}[信息]${C_OFF} $*"; }
ok()   { printf '%s\n' "${C_GRN}[完成]${C_OFF} $*"; }
warn() { printf '%s\n' "${C_YEL}[注意]${C_OFF} $*" >&2; }
err()  { printf '%s\n' "${C_RED}[错误]${C_OFF} $*" >&2; }
die()  { err "$*"; exit 1; }

step() {
    STEP=$((STEP + 1))
    printf '\n%s\n' "${C_BLU}==> [${STEP}/${STEPS_TOTAL}] $*${C_OFF}"
}

on_error() {
    local code=$?
    err "脚本在第 ${1:-?} 行失败（退出码 ${code}）。"
    [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && err "临时目录保留在：${TMP_DIR}"
    exit "$code"
}
trap 'on_error $LINENO' ERR

usage() {
    cat <<'USAGE'
雷电面板 独立安装脚本

用法：
  bash install-standalone.sh [选项]

选项：
  --product <ui3344|x-ui>   产品形态，决定目录/服务名/端口默认值（默认 ui3344）
  --repo <owner/repo>       Release 所属仓库（默认随产品）
  --tag <tag>               发布标签，如 v1.7；latest 表示取最新（默认随产品）
  --pkg <path|url>          指定安装包（本地文件或 URL），跳过 GitHub 下载
  --sha256 <path|url|hex>   指定校验来源；缺省用 <包>.sha256
  --arch <amd64|arm64|...>  覆盖架构探测结果
  --port <n>                面板端口（默认随产品；ui3344 为 33441）
  --username <u>            面板用户名（默认随机）
  --password <p>            面板密码（默认随机 18 位）
  --web-base-path <p>       面板路径（默认随机 18 位，与原作者一致）
  --ssl-domain <domain>     用 acme.sh 申请证书并挂到面板
  --ssl-mode <standalone|cf> 证书验证方式：standalone(80 端口) 或 cf(Cloudflare DNS)
  --ssl-email <mail>        ACME 注册邮箱（可选）
  --fail2ban <auto|on|off>  是否配置 fail2ban（默认 auto：已装则配置）
  --preset <auto|on|off>    是否创建预设协议入站（默认 auto：包内有脚本则创建）
  --deps <auto|skip>        是否自动补装依赖（默认 auto）
  --dry-run                 只做探测并打印安装计划，不改动系统
  --check                   只做安装前预检（校验制品可下载/可解密/摘要匹配）
  -h, --help                显示本帮助
  -V, --version             显示脚本版本

环境变量（等价选项，非交互时使用）：
  UI3344_PRODUCT UI3344_REPO UI3344_TAG UI3344_PKG UI3344_SHA256
  UI3344_PORT UI3344_USERNAME UI3344_PASSWORD UI3344_WEB_BASE_PATH
  UI3344_SSL_DOMAIN UI3344_SSL_MODE UI3344_SSL_EMAIL
  UI3344_FAIL2BAN UI3344_PRESET UI3344_DEPS
  CF_Token / CF_Account_ID     使用 --ssl-mode cf 时提供

示例：
  bash install-standalone.sh --dry-run
  bash install-standalone.sh --pkg ./ui3344-linux-amd64.tar.gz --sha256 3f2a...c9
  UI3344_PORT=33441 UI3344_PASSWORD='强密码' bash install-standalone.sh
USAGE
}

# ────────────────────────────── 参数解析 ──────────────────────────────
env_or() { local name=$1 def=${2:-}; local v=${!name:-}; printf '%s' "${v:-$def}"; }

parse_args() {
    PRODUCT="$(env_or UI3344_PRODUCT ui3344)"
    REPO="$(env_or UI3344_REPO '')"
    TAG="$(env_or UI3344_TAG '')"
    PKG_SRC="$(env_or UI3344_PKG '')"
    SHA_SRC="$(env_or UI3344_SHA256 '')"
    PORT="$(env_or UI3344_PORT '')"
    USERNAME="$(env_or UI3344_USERNAME '')"
    PASSWORD="$(env_or UI3344_PASSWORD '')"
    WEB_BASE_PATH="$(env_or UI3344_WEB_BASE_PATH '')"
    SSL_DOMAIN="$(env_or UI3344_SSL_DOMAIN '')"
    SSL_MODE="$(env_or UI3344_SSL_MODE off)"
    SSL_EMAIL="$(env_or UI3344_SSL_EMAIL '')"
    FAIL2BAN="$(env_or UI3344_FAIL2BAN auto)"
    PRESET="$(env_or UI3344_PRESET auto)"
    DEPS="$(env_or UI3344_DEPS auto)"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --product)        PRODUCT="${2:?}"; shift 2 ;;
            --repo)           REPO="${2:?}"; shift 2 ;;
            --tag)            TAG="${2:?}"; shift 2 ;;
            --pkg)            PKG_SRC="${2:?}"; shift 2 ;;
            --sha256)         SHA_SRC="${2:?}"; shift 2 ;;
            --arch)           ARCH_OVERRIDE="${2:?}"; shift 2 ;;
            --port)           PORT="${2:?}"; shift 2 ;;
            --username)       USERNAME="${2:?}"; shift 2 ;;
            --password)       PASSWORD="${2:?}"; shift 2 ;;
            --web-base-path)  WEB_BASE_PATH="${2:?}"; shift 2 ;;
            --ssl-domain)     SSL_DOMAIN="${2:?}"; shift 2 ;;
            --ssl-mode)       SSL_MODE="${2:?}"; shift 2 ;;
            --ssl-email)      SSL_EMAIL="${2:?}"; shift 2 ;;
            --fail2ban)       FAIL2BAN="${2:?}"; shift 2 ;;
            --preset)         PRESET="${2:?}"; shift 2 ;;
            --deps)           DEPS="${2:?}"; shift 2 ;;
            --dry-run)        DRY_RUN=1; shift ;;
            --check)          CHECK_ONLY=1; shift ;;
            -h|--help)        usage; exit 0 ;;
            -V|--version)     printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
            *)                err "未知参数：$1"; printf '\n'; usage; exit 2 ;;
        esac
    done

    case "$PRODUCT" in
        ui3344|leidian|雷电面板) PRODUCT='ui3344' ;;
        x-ui|3x-ui|xui)          PRODUCT='x-ui' ;;
        *) die "--product 只支持 ui3344 或 x-ui（收到：$PRODUCT）" ;;
    esac

    # 产品预设：目录 / 服务名 / 默认端口 / 默认仓库与标签
    case "$PRODUCT" in
        ui3344)
            # 安装包发布在**公开**仓库 leidian-installer 的 Release 里；
            # 源码仓库 leidian-panel 是私有的，未登录用户拿不到它的 Release（会 404）。
            DEF_REPO='scaryburial/leidian-installer'; DEF_TAG='v2.2'
            DEF_PORT='33441'; INSTALL_DIR='/usr/local/ui3344'
            DATA_DIR='/etc/ui3344'; LOG_DIR='/var/log/ui3344'
            ENV_FILE='/etc/default/ui3344'; SERVICE_NAME='ui3344'
            ALT_ENV_FILE='/etc/conf.d/ui3344'
            ;;
        x-ui)
            DEF_REPO='MHSanaei/3x-ui'; DEF_TAG='v3.7.0'
            DEF_PORT='2053'; INSTALL_DIR='/usr/local/x-ui'
            DATA_DIR='/etc/x-ui'; LOG_DIR='/var/log/x-ui'
            ENV_FILE='/etc/default/x-ui'; SERVICE_NAME='x-ui'
            ALT_ENV_FILE='/etc/conf.d/x-ui'
            ;;
    esac
    INSTALL_DIR="${UI3344_INSTALL_DIR:-$INSTALL_DIR}"

    : "${REPO:=$DEF_REPO}"
    : "${TAG:=$DEF_TAG}"
    : "${PORT:=$DEF_PORT}"

    [[ "$PORT" =~ ^[0-9]+$ ]] || die "--port 必须是数字（收到：$PORT）"

    case "$SSL_MODE" in off|standalone|cf) ;; *) die "--ssl-mode 只支持 off/standalone/cf" ;; esac
    case "$FAIL2BAN" in auto|on|off) ;; *) die "--fail2ban 只支持 auto/on/off" ;; esac
    case "$PRESET"   in auto|on|off) ;; *) die "--preset 只支持 auto/on/off" ;; esac
    case "$DEPS"     in auto|skip)   ;; *) die "--deps 只支持 auto/skip" ;; esac
    if [[ -n "$SSL_DOMAIN" && "$SSL_MODE" == 'off' ]]; then
        SSL_MODE='standalone'
    fi
}

# ────────────────────────────── 基础探测 ──────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

detect_arch() {
    if [[ -n "$ARCH_OVERRIDE" ]]; then
        ARCH="$ARCH_OVERRIDE"
        info "使用指定架构：${ARCH}"
        return 0
    fi
    case "$(uname -m)" in
        x86_64|x64|amd64)             ARCH='amd64' ;;
        i*86|x86)                     ARCH='386' ;;
        armv8*|arm64|aarch64)         ARCH='arm64' ;;
        armv7*)                       ARCH='armv7' ;;
        armv6*)                       ARCH='armv6' ;;
        armv5*)                       ARCH='armv5' ;;
        s390x)                        ARCH='s390x' ;;
        *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
    info "系统架构：${ARCH}"
}

detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
        OS_VER="${VERSION_ID:-}"
    elif [[ -r /usr/lib/os-release ]]; then
        # shellcheck disable=SC1091
        . /usr/lib/os-release
        OS_ID="${ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
        OS_VER="${VERSION_ID:-}"
    else
        die '无法识别系统：缺少 /etc/os-release'
    fi
    OS_FAMILY="$(os_family)"
    info "系统：${OS_ID} ${OS_VER}（家族：${OS_FAMILY}）"
}

os_family() {
    case "${OS_ID}" in
        ubuntu|debian|armbian|raspbian|linuxmint|pop|kali|deepin) echo deb ;;
        fedora|amzn|virtuozzo|rhel|almalinux|rocky|ol|centos|openEuler|anolis) echo rpm ;;
        arch|manjaro|parch|endeavouros) echo arch ;;
        opensuse*|sles) echo suse ;;
        alpine) echo alpine ;;
        *)
            case " ${OS_LIKE} " in
                *' debian '*|*' ubuntu '*) echo deb ;;
                *' rhel '*|*' fedora '*|*' centos '*) echo rpm ;;
                *' arch '*) echo arch ;;
                *' suse '*) echo suse ;;
                *) echo unknown ;;
            esac
            ;;
    esac
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die '请用 root 运行本脚本（sudo -i 后重试）。'
}

require_tools() {
    have tar || die '缺少 tar，无法解包。'
    if ! have curl && ! have wget; then
        die '缺少 curl/wget，请先安装其中之一。'
    fi
    if ! have sha256sum && ! have openssl; then
        die '缺少 sha256sum 和 openssl，无法校验安装包（拒绝继续）。'
    fi
}

install_dependencies() {
    if [[ "$DEPS" == 'skip' ]]; then
        info '按参数要求跳过依赖安装。'
        return 0
    fi
    local -a pkgs
    case "$OS_FAMILY" in
        deb)    pkgs=(ca-certificates curl tar tzdata openssl socat cron) ;;
        rpm)    pkgs=(ca-certificates curl tar tzdata openssl socat cronie) ;;
        arch)   pkgs=(ca-certificates curl tar tzdata openssl socat cronie) ;;
        suse)   pkgs=(ca-certificates curl tar timezone openssl socat cron) ;;
        alpine) pkgs=(ca-certificates curl tar tzdata openssl socat dcron) ;;
        *)
            warn "未识别的发行版家族，跳过依赖安装；若后续缺命令请手动安装。"
            return 0
            ;;
    esac
    info "补装依赖：${pkgs[*]}"
    case "$OS_FAMILY" in
        deb)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn 'apt-get update 返回非 0，继续尝试安装。'
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" || warn 'apt-get install 返回非 0，继续。'
            ;;
        rpm)
            if have dnf; then
                dnf makecache -y -q >/dev/null 2>&1 || true
                dnf install -y -q "${pkgs[@]}" || warn 'dnf install 返回非 0，继续。'
            else
                yum makecache -y -q >/dev/null 2>&1 || true
                yum install -y -q "${pkgs[@]}" || warn 'yum install 返回非 0，继续。'
            fi
            ;;
        arch)
            pacman -Sy --noconfirm --needed "${pkgs[@]}" || warn 'pacman 返回非 0，继续。'
            ;;
        suse)
            zypper -q --non-interactive install -y --no-recommends "${pkgs[@]}" || warn 'zypper 返回非 0，继续。'
            ;;
        alpine)
            apk update -q || warn 'apk update 返回非 0，继续。'
            apk add -q --no-cache "${pkgs[@]}" || warn 'apk add 返回非 0，继续。'
            ;;
    esac
    return 0
}

# ────────────────────────────── 下载与校验 ──────────────────────────────
fetch() {
    local url="$1" out="$2"
    info "下载：${url}"
    if have curl; then
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 1800 -o "$out" "$url"
    else
        wget -q --tries=3 --timeout=20 -O "$out" "$url"
    fi
    [[ -s "$out" ]] || die "下载内容为空：${url}"
}

sha256_of() {
    local f="$1"
    if have sha256sum; then
        sha256sum "$f" | awk '{print $1}'
    elif have openssl; then
        openssl dgst -sha256 "$f" | awk '{print $NF}'
    else
        return 1
    fi
}

resolve_latest_tag() {
    local repo="$1" api tag
    api="https://api.github.com/repos/${repo}/releases/latest"
    if have curl; then
        tag="$(curl -fsSL --connect-timeout 20 "$api" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)" || tag=''
    else
        tag="$(wget -qO- --timeout=20 "$api" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)" || tag=''
    fi
    [[ -n "$tag" ]] || die "无法解析 ${repo} 的最新版本标签，请用 --tag 显式指定。"
    printf '%s' "$tag"
}

# 解析安装包与校验来源；PKG_FILE / EXPECTED_SHA 为输出。
resolve_package() {
    PKG_FILE="${TMP_DIR}/${PRODUCT}-linux-${ARCH}.tar.gz"
    if [[ -n "$PKG_SRC" ]]; then
        if [[ -f "$PKG_SRC" ]]; then
            info "使用本地安装包：${PKG_SRC}"
            cp -f "$PKG_SRC" "$PKG_FILE"
        else
            fetch "$PKG_SRC" "$PKG_FILE"
        fi
    else
        [[ "$TAG" == 'latest' ]] && TAG="$(resolve_latest_tag "$REPO")"
        info "目标版本：${REPO} ${TAG}"
        local base="https://github.com/${REPO}/releases/download/${TAG}"
        local name="${PRODUCT}-linux-${ARCH}.tar.gz"
        fetch "${base}/${name}" "$PKG_FILE" || die "下载安装包失败（${base}/${name}）；可用 --pkg 指定本地包。"
        if [[ -z "$SHA_SRC" ]]; then
            SHA_SRC="${base}/${name}.sha256"
        fi
    fi
}

verify_package() {
    local expected='' actual
    if [[ -n "$SHA_SRC" ]]; then
        if [[ "$SHA_SRC" =~ ^[0-9a-fA-F]{64}$ ]]; then
            expected="$SHA_SRC"
        elif [[ -f "$SHA_SRC" ]]; then
            expected="$(awk '{print $1}' "$SHA_SRC" 2>/dev/null | head -n1)"
        else
            local out="${TMP_DIR}/expected.sha256"
            fetch "$SHA_SRC" "$out" || die '下载校验文件失败；拒绝在无校验的情况下安装。'
            expected="$(awk '{print $1}' "$out" | head -n1)"
        fi
    elif [[ -f "${PKG_FILE}.sha256" ]]; then
        expected="$(awk '{print $1}' "${PKG_FILE}.sha256" | head -n1)"
    fi

    if [[ -z "$expected" ]]; then
        die '未取得期望的 sha256（校验文件为空或缺失）。拒绝继续安装。'
    fi
    actual="$(sha256_of "$PKG_FILE")" || die '本机既无 sha256sum 也无 openssl，无法校验。拒绝继续安装。'
    if [[ "${expected,,}" != "${actual,,}" ]]; then
        err "sha256 校验失败：期望 ${expected}，实际 ${actual}"
        die '安装包可能损坏或被篡改，已中止。'
    fi
    ok "sha256 校验通过（${actual}）"
    EXPECTED_SHA="$actual"
}

extract_package() {
    EXTRACT_DIR="${TMP_DIR}/pkg"
    mkdir -p "$EXTRACT_DIR"
    info '解压安装包…'
    tar -xzf "$PKG_FILE" -C "$EXTRACT_DIR" || die '解压失败：安装包可能不完整。'

    local d
    PKG_ROOT=''
    for d in "$EXTRACT_DIR"/*/; do
        [[ -d "$d" ]] || continue
        if [[ -f "${d}${PRODUCT}" ]]; then
            PKG_ROOT="${d%/}"
            break
        fi
    done
    if [[ -z "$PKG_ROOT" && -f "${EXTRACT_DIR}/${PRODUCT}" ]]; then
        PKG_ROOT="$EXTRACT_DIR"
    fi
    if [[ -z "$PKG_ROOT" ]]; then
        PKG_ROOT="$(find "$EXTRACT_DIR" -maxdepth 3 -type f -name "$PRODUCT" -print -quit 2>/dev/null || true)"
        [[ -n "$PKG_ROOT" ]] && PKG_ROOT="$(dirname "$PKG_ROOT")"
    fi
    [[ -n "$PKG_ROOT" ]] || die "安装包里找不到二进制 ${PRODUCT}，拒绝继续。"
    info "包内根目录：${PKG_ROOT#"${EXTRACT_DIR}"/}"
}

# ────────────────────────────── 服务单元与开关 ──────────────────────────────
init_system() {
    if have systemctl && [[ -d /run/systemd/system ]]; then
        echo systemd
    elif have rc-service && have rc-update; then
        echo openrc
    elif [[ -d /etc/init.d ]]; then
        echo sysvinit
    else
        echo none
    fi
}

unit_dir() {
    case "$(init_system)" in
        systemd) echo '/etc/systemd/system' ;;
        openrc)  echo '/etc/init.d' ;;
        *)       echo '/etc/init.d' ;;
    esac
}

# 原子落盘：先写临时文件，校验非空后再 mv（参考原作者的 _install_xui_service_unit）
atomic_write() {
    local dest="$1"
    local src="$2"
    local tmp="${dest}.tmp.$$"
    rm -f "$tmp"
    cp -f "$src" "$tmp" || { rm -f "$tmp"; return 1; }
    [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    chown root:root "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    return 0
}

install_service_unit() {
    local sys unit_file tmp
    sys="$(init_system)"
    unit_file="$(unit_dir)/${SERVICE_NAME}.service"
    [[ "$sys" == 'openrc' ]] && unit_file="/etc/init.d/${SERVICE_NAME}"
    [[ "$sys" == 'none' ]] && { warn '未识别到 init 系统，跳过服务安装（可手动运行二进制）。'; return 0; }

    tmp="${TMP_DIR}/${SERVICE_NAME}.unit"
    case "$sys" in
        systemd)
            cat > "$tmp" <<UNIT
[Unit]
Description=${PRODUCT} Service
After=network.target
Wants=network.target
StartLimitIntervalSec=180
StartLimitBurst=10

[Service]
EnvironmentFile=-${ENV_FILE}
Environment="XRAY_VMESS_AEAD_FORCED=false"
Environment="XUI_DB_FOLDER=${DATA_DIR}"
Environment="XUI_MAIN_FOLDER=${INSTALL_DIR}"
Type=simple
WorkingDirectory=${INSTALL_DIR}/
ExecStart=${INSTALL_DIR}/${PRODUCT}
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
            ;;
        openrc)
            cat > "$tmp" <<UNIT
#!/sbin/openrc-run

command="${INSTALL_DIR}/${PRODUCT}"
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"
description="${PRODUCT} Service"
procname="${PRODUCT}"
export XUI_DB_FOLDER="${DATA_DIR}"

depend() {
    need net
}

start_pre() {
    cd ${INSTALL_DIR}
}

reload() {
    ebegin "Reloading \${RC_SVCNAME}"
    kill -USR1 "\$(cat \$pidfile)"
    eend \$?
}
UNIT
            chmod 0755 "$tmp"
            ;;
        sysvinit)
            cat > "$tmp" <<UNIT
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ${SERVICE_NAME}
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ${PRODUCT} panel
### END INIT INFO

NAME=${SERVICE_NAME}
DAEMON=${INSTALL_DIR}/${PRODUCT}
PIDFILE=/run/\${NAME}.pid
export XUI_DB_FOLDER=${DATA_DIR}

case "\$1" in
    start)
        cd ${INSTALL_DIR} || exit 1
        start-stop-daemon --start --background --make-pidfile --pidfile "\$PIDFILE" --exec "\$DAEMON" || exit 1
        ;;
    stop)
        start-stop-daemon --stop --pidfile "\$PIDFILE" --retry 10 || exit 1
        rm -f "\$PIDFILE"
        ;;
    restart|reload)
        "\$0" stop; "\$0" start
        ;;
    status)
        if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
            echo "\${NAME} running"
        else
            echo "\${NAME} stopped"; exit 3
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"; exit 2
        ;;
esac
exit 0
UNIT
            chmod 0755 "$tmp"
            ;;
    esac

    atomic_write "$unit_file" "$tmp" || die "写入服务单元失败：${unit_file}"
    info "服务单元已安装：${unit_file}"
}

svc_stop() {
    case "$(init_system)" in
        systemd) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
        openrc)  rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
        sysvinit) /etc/init.d/"$SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
    esac
    # 等进程真正退出，否则替换二进制会遇到 Text file busy
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! have pgrep || ! pgrep -x "$PRODUCT" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    have pkill && pkill -x "$PRODUCT" >/dev/null 2>&1 || true
    sleep 1
    return 0
}

svc_enable_start() {
    case "$(init_system)" in
        systemd)
            systemctl daemon-reload
            systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || warn 'systemctl enable 失败。'
            systemctl restart "$SERVICE_NAME" || die 'systemctl start 失败，请查看：journalctl -u '"$SERVICE_NAME"' -n 50'
            ;;
        openrc)
            rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || warn 'rc-update add 失败。'
            rc-service "$SERVICE_NAME" restart || die 'rc-service start 失败。'
            ;;
        sysvinit)
            /etc/init.d/"$SERVICE_NAME" restart || die 'init.d start 失败。'
            ;;
        none)
            warn '无 init 系统，未启动服务。'
            ;;
    esac
}

# ────────────────────────────── 安装文件 ──────────────────────────────
install_files() {
    install -d -m 0755 "$INSTALL_DIR"
    install -d -m 0755 "${INSTALL_DIR}/bin"
    install -d -m 0755 "$DATA_DIR"
    install -d -m 0755 "$LOG_DIR"

    info "安装二进制：${INSTALL_DIR}/${PRODUCT}"
    install -m 0755 "${PKG_ROOT}/${PRODUCT}" "${INSTALL_DIR}/${PRODUCT}"

    # Xray 内核与 geo 文件（包内 bin/）
    if [[ -d "${PKG_ROOT}/bin" ]]; then
        local f
        for f in "${PKG_ROOT}/bin/"*; do
            [[ -e "$f" ]] || continue
            install -m 0755 "$f" "${INSTALL_DIR}/bin/$(basename "$f")"
        done
        info "已安装 bin/ 内核与 geo 文件。"
    else
        warn '安装包内没有 bin/（Xray 内核），面板启动后需自行放置内核。'
    fi

    # 管理脚本（ui3344.sh / x-ui.sh）与配套脚本
    local s
    for s in "${PRODUCT}.sh" "${PRODUCT}.rc" "${PRODUCT}.service.debian" \
             "${PRODUCT}.service.arch" "${PRODUCT}.service.rhel" \
             'create-inbounds.py' 'configure-subscription.py' 'domain-setup.py' 'README.md'; do
        if [[ -f "${PKG_ROOT}/${s}" ]]; then
            install -m 0755 "${PKG_ROOT}/${s}" "${INSTALL_DIR}/${s}"
        fi
    done
    if [[ -f "${INSTALL_DIR}/${PRODUCT}.sh" ]]; then
        ln -sf "${INSTALL_DIR}/${PRODUCT}.sh" "/usr/bin/${PRODUCT}"
        info "管理命令：${PRODUCT}（软链到 ${INSTALL_DIR}/${PRODUCT}.sh）"
    fi
}

write_env_file() {
    local tmp="${TMP_DIR}/${SERVICE_NAME}.env"
    cat > "$tmp" <<ENV
# ${PRODUCT} 面板环境变量（由 ${SCRIPT_NAME} 生成）
XUI_DB_FOLDER=${DATA_DIR}
XUI_MAIN_FOLDER=${INSTALL_DIR}
ENV
    local target="$ENV_FILE"
    [[ "$OS_FAMILY" == 'arch' || "$OS_FAMILY" == 'alpine' ]] && target="$ALT_ENV_FILE"
    install -d -m 0755 "$(dirname "$target")"
    atomic_write "$target" "$tmp" || die "写入环境文件失败：${target}"
    info "环境文件：${target}"
}

# ────────────────────────────── 面板配置 ──────────────────────────────
gen_random_string() {
    local n="${1:-18}" s=''
    if have openssl; then
        s="$(openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$n")"
    fi
    if [[ -z "$s" ]]; then
        s="$(head -c 256 /dev/urandom 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$n")"
    fi
    [[ -n "$s" ]] || die '无法生成随机字符串。'
    printf '%s' "$s"
}

panel_cli() {
    XUI_DB_FOLDER="$DATA_DIR" XUI_MAIN_FOLDER="$INSTALL_DIR" \
        "${INSTALL_DIR}/${PRODUCT}" "$@"
}

configure_panel() {
    local final_user="${USERNAME:-$(gen_random_string 10)}"
    local final_pass="${PASSWORD:-$(gen_random_string 18)}"
    local final_base="${WEB_BASE_PATH:-$(gen_random_string 18)}"
    final_base="${final_base#/}"
    # 与原作者的 config_after_install 一致：路径短于 4 位视为无效，重新生成
    if [[ ${#final_base} -lt 4 ]]; then
        warn "面板路径过短（${final_base}），已自动改为随机 18 位。"
        final_base="$(gen_random_string 18)"
    fi

    info '写入面板设置（端口 / 账号 / 密码 / 路径）…'
    panel_cli setting -username "$final_user" -password "$final_pass" \
        -port "$PORT" -webBasePath "$final_base" >/dev/null

    PANEL_USER="$final_user"
    PANEL_PASS="$final_pass"
    PANEL_BASE="$final_base"
    ok '面板设置已写入。'
}

# 面板可能是 HTTP（默认），也可能是 HTTPS（--ssl-mode standalone/cf 会把面板切成 TLS）。
# 回环上的自签证书 / Cloudflare Origin CA 证书都不在系统信任库，探测必须跳过校验，
# 否则「等待就绪」会白等到超时、`create-inbounds.py` 拿不到 csrf-token（实测过
# http 打 TLS 端口会得到非 HTTP 字节 → python 抛 UnknownProtocol: HTTP/0.0）。
panel_probe() {
    local path="$1"
    have curl || return 1
    curl -fsS -k -o /dev/null --max-time 3 "http://127.0.0.1:${PORT}/${path}"  && return 0
    curl -fsS -k -o /dev/null --max-time 3 "https://127.0.0.1:${PORT}/${path}" && return 0
    return 1
}

wait_for_panel() {
    local rc=1
    info "等待面板监听 ${PORT} 端口…"
    for _ in $(seq 1 45); do
        if have curl; then
            if panel_probe "${PANEL_BASE}"; then rc=0; break; fi
            if panel_probe ""; then rc=0; break; fi
        else
            (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") >/dev/null 2>&1 && { rc=0; break; }
        fi
        sleep 1
    done
    if [[ $rc -eq 0 ]]; then
        ok '面板已在监听。'
    else
        warn "等待 ${PORT} 端口超时，请检查：journalctl -u ${SERVICE_NAME} -n 80"
    fi
    return 0
}

write_result() {
    local host token
    host="$(detect_public_host)"
    token="$(panel_cli setting -getApiToken 2>/dev/null | sed -n 's/^[[:space:]]*apiToken:[[:space:]]*//p' | head -n1)"
    local result="${DATA_DIR}/install-result.env"
    local prev_umask
    prev_umask="$(umask)"
    umask 077
    {
        printf 'XUI_USERNAME=%s\n' "$PANEL_USER"
        printf 'XUI_PASSWORD=%s\n' "$PANEL_PASS"
        printf 'XUI_PANEL_PORT=%s\n' "$PORT"
        printf 'XUI_WEB_BASE_PATH=%s\n' "$PANEL_BASE"
        printf 'XUI_ACCESS_URL=%s\n' "http://${host}:${PORT}/${PANEL_BASE}"
        printf 'XUI_API_TOKEN=%s\n' "${token:-}"
        printf 'XUI_VID=%s\n' "${TAG}"
        printf 'XUI_SHA256=%s\n' "${EXPECTED_SHA:-}"
    } > "$result"
    umask "$prev_umask"
    chmod 0600 "$result" 2>/dev/null || true
    chown root:root "$result" 2>/dev/null || true
    RESULT_FILE="$result"
    ok "安装结果已写入：${result}（0600）"
}

detect_public_host() {
    local ip=''
    if have curl; then
        ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    fi
    if [[ -z "$ip" ]]; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n1 || true)"
    fi
    printf '%s' "${ip:-SERVER_IP}"
}

# ────────────────────────────── 可选组件 ──────────────────────────────
setup_ssl() {
    [[ -n "$SSL_DOMAIN" ]] || return 0
    [[ "$SSL_MODE" != 'off' ]] || return 0

    info "申请证书：${SSL_DOMAIN}（模式 ${SSL_MODE}）"
    if [[ ! -x "${HOME}/.acme.sh/acme.sh" ]]; then
        if have curl; then
            curl -fsS https://get.acme.sh | sh >/dev/null 2>&1 || { warn 'acme.sh 安装失败，跳过证书步骤。'; return 0; }
        else
            warn '缺少 curl，无法安装 acme.sh，跳过证书步骤。'; return 0
        fi
    fi
    local acme="${HOME}/.acme.sh/acme.sh"
    [[ -x "$acme" ]] || { warn '未找到 acme.sh，跳过证书步骤。'; return 0; }

    local -a args=(--issue -d "$SSL_DOMAIN")
    [[ -n "$SSL_EMAIL" ]] && args+=(--accountemail "$SSL_EMAIL")
    case "$SSL_MODE" in
        standalone) args+=(--standalone) ;;
        cf)
            if [[ -z "${CF_Token:-}" ]]; then
                warn '使用 --ssl-mode cf 需要 CF_Token 环境变量，跳过证书步骤。'
                return 0
            fi
            args+=(--dns dns_cf)
            ;;
    esac

    if ! "$acme" "${args[@]}"; then
        warn 'acme.sh 签发失败（域名解析/80 端口/CF 权限常见）。面板仍可用 HTTP，稍后可手动执行 cert 步骤。'
        return 0
    fi

    local certdir="${HOME}/.acme.sh/${SSL_DOMAIN}_ecc"
    [[ -s "${certdir}/fullchain.cer" ]] || certdir="${HOME}/.acme.sh/${SSL_DOMAIN}"
    if [[ -s "${certdir}/fullchain.cer" && -s "${certdir}/${SSL_DOMAIN}.key" ]]; then
        panel_cli setting -webCertFile "${certdir}/fullchain.cer" -webKeyFile "${certdir}/${SSL_DOMAIN}.key" >/dev/null || {
            warn '证书已签发，但写入面板失败。'
            return 0
        }
        svc_enable_start >/dev/null 2>&1 || true
        SSL_ACTIVE=1
        ok "证书已挂载，访问：https://${SSL_DOMAIN}:${PORT}/${PANEL_BASE}"
    else
        warn 'acme.sh 未产出可用证书文件，跳过挂载。'
    fi
    return 0
}

setup_fail2ban() {
    [[ "$FAIL2BAN" != 'off' ]] || { info '按参数跳过 fail2ban。'; return 0; }
    if [[ "$FAIL2BAN" == 'auto' ]] && ! have fail2ban-client; then
        info '未安装 fail2ban，跳过（需要时用 --fail2ban on）。'
        return 0
    fi
    local cli="/usr/bin/${PRODUCT}"
    if [[ ! -f "$cli" ]]; then
        warn "未找到管理脚本 ${cli}，跳过 fail2ban 配置。"
        return 0
    fi
    # 旧版管理脚本没有该子命令，直接调用会落到 usage 分支并返回成功，不能当配置成功
    if ! grep -q 'setup-fail2ban' "$cli" 2>/dev/null; then
        warn '当前管理脚本不支持 setup-fail2ban，跳过。'
        return 0
    fi
    if "$cli" setup-fail2ban >/dev/null 2>&1; then
        ok 'fail2ban 已按面板内置流程配置。'
    else
        warn 'setup-fail2ban 执行失败，跳过（不影响面板运行）。'
    fi
    return 0
}

create_presets() {
    [[ "$PRESET" != 'off' ]] || { info '按参数跳过预设入站。'; return 0; }
    local py="${INSTALL_DIR}/create-inbounds.py"
    if [[ ! -f "$py" ]]; then
        [[ "$PRESET" == 'on' ]] && warn '包内没有 create-inbounds.py，无法创建预设入站。'
        return 0
    fi
    if ! have python3; then
        warn '缺少 python3，跳过预设入站创建（可稍后手动运行 create-inbounds.py）。'
        return 0
    fi
    info '创建预设协议入站…'
    for _ in $(seq 1 30); do
        if have curl; then
            panel_probe "${PANEL_BASE}/csrf-token" && break
            panel_probe "csrf-token" && break
        else
            (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") >/dev/null 2>&1 && break
        fi
        sleep 1
    done
    if python3 "$py"; then
        ok '预设入站已创建。'
    else
        warn '预设入站创建失败（可稍后手动运行 create-inbounds.py）。'
    fi
    return 0
}

# ────────────────────────────── 展示 ──────────────────────────────
print_plan() {
    cat <<PLAN
${C_DIM}-------------------------------- 安装计划 ---------------------------------${C_OFF}
  产品            : ${PRODUCT}
  仓库 / 版本     : ${REPO} / ${TAG}
  安装包          : ${PKG_SRC:-${REPO} Release（${PRODUCT}-linux-${ARCH}.tar.gz）}
  校验来源        : ${SHA_SRC:-安装包同目录的 .sha256（校验失败即中止）}
  安装目录        : ${INSTALL_DIR}
  数据目录        : ${DATA_DIR}（数据库 ${DATA_DIR}/${PRODUCT}.db，保留不动）
  日志目录        : ${LOG_DIR}
  环境文件        : ${ENV_FILE}
  服务名          : ${SERVICE_NAME}（init: $(init_system)）
  面板端口        : ${PORT}
  面板路径        : ${WEB_BASE_PATH:-随机 18 位}
  证书            : ${SSL_DOMAIN:-不使用}（模式 ${SSL_MODE}）
  fail2ban        : ${FAIL2BAN}
  预设入站        : ${PRESET}
  依赖安装        : ${DEPS}
${C_DIM}--------------------------------------------------------------------------${C_OFF}
PLAN
}

print_summary() {
    local host scheme='http'
    host="$(detect_public_host)"
    [[ "${SSL_ACTIVE:-0}" == '1' ]] && { scheme='https'; host="$SSL_DOMAIN"; }
    cat <<SUMMARY

${C_GRN}安装完成${C_OFF}

  访问地址 : ${C_BLU}${scheme}://${host}:${PORT}/${PANEL_BASE}${C_OFF}
  用户名   : ${PANEL_USER}
  密码     : ${PANEL_PASS}
  凭据文件 : ${RESULT_FILE}（0600，仅 root 可读）

  常用命令 : ${PRODUCT} status | ${PRODUCT} restart | ${PRODUCT} log
             ${PRODUCT} settings | ${PRODUCT} uninstall
  服务管理 : journalctl -u ${SERVICE_NAME} -n 80 --no-pager

  安全提示 : 面板默认监听所有网卡，请尽快在云安全组只放行必要端口，
             并考虑启用证书与「安全入口」。本次安装已随机生成密码与路径。
SUMMARY
}

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

# ────────────────────────────── 主流程 ──────────────────────────────
main() {
    parse_args "$@"

    if [[ "$DRY_RUN" == '1' ]]; then
        detect_arch
        if [[ -r /etc/os-release ]]; then
            detect_os
        else
            warn '未检测到 /etc/os-release（非 Linux？），dry-run 继续打印计划。'
            OS_FAMILY='unknown'
        fi
        print_plan
        ok '这是 --dry-run：未改动系统。去掉该参数即可执行安装。'
        exit 0
    fi

    require_root
    detect_os
    detect_arch

    TMP_DIR="$(mktemp -d)"
    trap 'cleanup; on_error $LINENO' ERR
    trap cleanup EXIT

    print_plan

    step '安装系统依赖'; install_dependencies
    step '检查必备命令'; require_tools
    step '解析安装包';   resolve_package
    step '校验安装包';   verify_package

    if [[ "$CHECK_ONLY" == '1' ]]; then
        ok '预检通过（--check）：安装包可用且摘要匹配。'
        exit 0
    fi

    step '解压安装包';   extract_package
    step '停止旧服务';   svc_stop
    step '安装文件';     install_files; write_env_file; install_service_unit
    step '启动并配置';   svc_enable_start; configure_panel; wait_for_panel; write_result
    step '可选项收尾';   setup_ssl; setup_fail2ban; create_presets

    print_summary
}

main "$@"
