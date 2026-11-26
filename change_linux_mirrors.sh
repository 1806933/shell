#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Linux 主流发行版一键切换国内软件源脚本
# 支持: Debian (含 12/13 DEB822), Ubuntu (含 24.04+ DEB822 & ARM64),
#       Alpine, Rocky Linux, AlmaLinux, CentOS 7/Stream, Fedora, Arch Linux
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# 默认配置
MIRROR_KEY=""
PROTOCOL="https"
AUTO_YES=false
DO_RESTORE=false
BACKUP_BASE="/var/backups/mirror_switcher"

# 镜像源映射
get_mirror_host() {
    case "$1" in
        tuna)    echo "mirrors.tuna.tsinghua.edu.cn" ;;
        aliyun)  echo "mirrors.aliyun.com" ;;
        ustc)    echo "mirrors.ustc.edu.cn" ;;
        tencent) echo "mirrors.cloud.tencent.com" ;;
        huawei)  echo "mirrors.huaweicloud.com" ;;
        *)       return 1 ;;
    esac
}

get_mirror_name() {
    case "$1" in
        tuna)    echo "清华大学 TUNA" ;;
        aliyun)  echo "阿里云 Aliyun" ;;
        ustc)    echo "中国科学技术大学 USTC" ;;
        tencent) echo "腾讯云 Tencent" ;;
        huawei)  echo "华为云 Huawei" ;;
        *)       echo "$1" ;;
    esac
}

usage() {
    cat <<EOF
用法:
  交互模式:
    sudo $0

  快捷非交互模式:
    sudo $0 -m <tuna|aliyun|ustc|tencent|huawei> [--http] [-y]
    sudo $0 --restore

参数:
  -m, --mirror <key>   指定镜像源: tuna | aliyun | ustc | tencent | huawei
  --http               使用 HTTP 协议（适用于极简系统未装 ca-certificates 时）
  --https              使用 HTTPS 协议（默认）
  -y, --yes            跳过确认直接执行
  --restore            从最近一次备份恢复软件源配置
  -h, --help           显示此帮助信息
EOF
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mirror)
            MIRROR_KEY="${2:-}"
            shift 2
            ;;
        --http)
            PROTOCOL="http"
            shift
            ;;
        --https)
            PROTOCOL="https"
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        --restore)
            DO_RESTORE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

# 权限检查
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}错误：请使用 root 权限或 sudo 运行此脚本。${NC}"
    exit 1
fi

# 识别发行版与架构
detect_os() {
    ARCH=$(uname -m)
    if [[ ! -f /etc/os-release ]]; then
        echo -e "${RED}错误：无法读取 /etc/os-release，暂不支持该系统。${NC}"
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"

    # 兼容部分 Debian 精简镜像缺少 VERSION_CODENAME 的情况
    if [[ "$OS_ID" == "debian" && -z "$OS_CODENAME" ]]; then
        case "${OS_VERSION_ID%%.*}" in
            10) OS_CODENAME="buster" ;;
            11) OS_CODENAME="bullseye" ;;
            12) OS_CODENAME="bookworm" ;;
            13) OS_CODENAME="trixie" ;;
            14) OS_CODENAME="forky" ;;
        esac
    fi
}

# 创建备份目录
create_backup() {
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    CURRENT_BACKUP="${BACKUP_BASE}/${ts}"
    mkdir -p "$CURRENT_BACKUP"

    for path in "$@"; do
        if [[ -e "$path" ]]; then
            local parent_dir
            parent_dir=$(dirname "$path")
            mkdir -p "${CURRENT_BACKUP}${parent_dir}"
            cp -a "$path" "${CURRENT_BACKUP}${path}"
        fi
    done
    echo -e "${GREEN}已备份原配置至: ${CYAN}${CURRENT_BACKUP}${NC}"
}

# 回滚最近一次备份
restore_latest_backup() {
    if [[ ! -d "$BACKUP_BASE" ]]; then
        echo -e "${YELLOW}未找到任何历史备份目录 (${BACKUP_BASE})。${NC}"
        exit 1
    fi

    local latest
    latest=$(ls -1t "$BACKUP_BASE" 2>/dev/null | head -n 1 || true)
    if [[ -z "$latest" ]]; then
        echo -e "${YELLOW}备份目录为空，无可恢复内容。${NC}"
        exit 1
    fi

    local backup_path="${BACKUP_BASE}/${latest}"
    echo -e "找到最近一次备份: ${CYAN}${backup_path}${NC}"
    if [[ "$AUTO_YES" != true ]]; then
        read -rp "确认使用该备份覆盖当前软件源配置？[y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "已取消恢复。"
            exit 0
        fi
    fi

    cp -a "${backup_path}/." /
    echo -e "${GREEN}已恢复备份！请手动执行对应的软件包缓存更新命令（如 apt update / dnf makecache）。${NC}"
}

# 检测极简系统是否缺少 HTTPS 证书支持
check_https_support() {
    if [[ "$PROTOCOL" == "https" && ( "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" ) ]]; then
        if [[ ! -f /etc/ssl/certs/ca-certificates.crt ]]; then
            echo -e "${YELLOW}警告：未检测到 /etc/ssl/certs/ca-certificates.crt，HTTPS 源可能报错。${NC}"
            if [[ "$AUTO_YES" != true ]]; then
                read -rp "是否自动改用 HTTP 协议？[Y/n]: " use_http
                if [[ ! "$use_http" =~ ^[Nn]$ ]]; then
                    PROTOCOL="http"
                fi
            else
                echo -e "${YELLOW}自动降级为 HTTP 协议。${NC}"
                PROTOCOL="http"
            fi
        fi
    fi
}

# -------------------- 各发行版换源实现 --------------------

switch_debian() {
    local host="$1"
    local ver_major="${OS_VERSION_ID%%.*}"
    local components="main contrib non-free"
    # Debian 12 (bookworm) 及以上拆分了 non-free-firmware
    if [[ "$ver_major" =~ ^[0-9]+$ && "$ver_major" -ge 12 ]] || [[ "$OS_CODENAME" == "bookworm" || "$OS_CODENAME" == "trixie" || "$OS_CODENAME" == "forky" || "$OS_CODENAME" == "sid" ]]; then
        components="main contrib non-free non-free-firmware"
    fi

    local sec_suite="${OS_CODENAME}-security"
    [[ "$OS_CODENAME" == "buster" ]] && sec_suite="${OS_CODENAME}/updates"

    create_backup /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources

    # 判断是否使用 DEB822 格式（Debian 12/13 现代镜像常用）
    if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
        cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: ${PROTOCOL}://${host}/debian
Suites: ${OS_CODENAME} ${OS_CODENAME}-updates ${OS_CODENAME}-backports
Components: ${components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${PROTOCOL}://${host}/debian-security
Suites: ${sec_suite}
Components: ${components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        # 避免与传统 sources.list 重复冲突
        if [[ -s /etc/apt/sources.list ]]; then
            sed -i 's/^[[:space:]]*deb/# deb/g' /etc/apt/sources.list
        fi
        echo -e "${GREEN}已更新 DEB822 源: /etc/apt/sources.list.d/debian.sources${NC}"
    else
        cat > /etc/apt/sources.list <<EOF
deb ${PROTOCOL}://${host}/debian/ ${OS_CODENAME} ${components}
deb ${PROTOCOL}://${host}/debian/ ${OS_CODENAME}-updates ${components}
deb ${PROTOCOL}://${host}/debian/ ${OS_CODENAME}-backports ${components}
deb ${PROTOCOL}://${host}/debian-security ${sec_suite} ${components}
EOF
        echo -e "${GREEN}已更新传统源: /etc/apt/sources.list${NC}"
    fi

    echo -e "\n${CYAN}>>> 正在刷新 apt 缓存...${NC}"
    apt-get update
}

switch_ubuntu() {
    local host="$1"
    local repo_path="ubuntu"
    # ARM64 / 非 x86 架构使用 ubuntu-ports
    if [[ "$ARCH" != "x86_64" && "$ARCH" != "i686" && "$ARCH" != "i386" ]]; then
        repo_path="ubuntu-ports"
        echo -e "${CYAN}检测到架构为 ${ARCH}，自动切换至 ${repo_path} 仓库。${NC}"
    fi

    create_backup /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources

    # Ubuntu 24.04+ 默认使用 DEB822 格式
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: ${PROTOCOL}://${host}/${repo_path}
Suites: ${OS_CODENAME} ${OS_CODENAME}-updates ${OS_CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${PROTOCOL}://${host}/${repo_path}
Suites: ${OS_CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        if [[ -s /etc/apt/sources.list ]]; then
            sed -i 's/^[[:space:]]*deb/# deb/g' /etc/apt/sources.list
        fi
        echo -e "${GREEN}已更新 DEB822 源: /etc/apt/sources.list.d/ubuntu.sources${NC}"
    else
        cat > /etc/apt/sources.list <<EOF
deb ${PROTOCOL}://${host}/${repo_path}/ ${OS_CODENAME} main restricted universe multiverse
deb ${PROTOCOL}://${host}/${repo_path}/ ${OS_CODENAME}-updates main restricted universe multiverse
deb ${PROTOCOL}://${host}/${repo_path}/ ${OS_CODENAME}-backports main restricted universe multiverse
deb ${PROTOCOL}://${host}/${repo_path}/ ${OS_CODENAME}-security main restricted universe multiverse
EOF
        echo -e "${GREEN}已更新传统源: /etc/apt/sources.list${NC}"
    fi

    echo -e "\n${CYAN}>>> 正在刷新 apt 缓存...${NC}"
    apt-get update
}

switch_alpine() {
    local host="$1"
    create_backup /etc/apk/repositories
    sed -i -E "s|https?://[^/]+/alpine|${PROTOCOL}://${host}/alpine|g" /etc/apk/repositories
    echo -e "${GREEN}已更新: /etc/apk/repositories${NC}"
    echo -e "\n${CYAN}>>> 正在刷新 apk 缓存...${NC}"
    apk update
}

switch_rhel_family() {
    local host="$1"
    create_backup /etc/yum.repos.d

    case "$OS_ID" in
        rocky)
            sed -i -E \
                -e 's|^mirrorlist=|#mirrorlist=|g' \
                -e "s|^#?baseurl=https?://dl\.rockylinux\.org/\\\$contentdir|baseurl=${PROTOCOL}://${host}/rocky|g" \
                -e "s|^baseurl=https?://[^/]+/rocky|baseurl=${PROTOCOL}://${host}/rocky|g" \
                /etc/yum.repos.d/rocky*.repo 2>/dev/null || true
            ;;
        almalinux)
            sed -i -E \
                -e 's|^mirrorlist=|#mirrorlist=|g' \
                -e "s|^#?baseurl=https?://repo\.almalinux\.org|baseurl=${PROTOCOL}://${host}|g" \
                -e "s|^baseurl=https?://[^/]+/almalinux|baseurl=${PROTOCOL}://${host}/almalinux|g" \
                /etc/yum.repos.d/almalinux*.repo 2>/dev/null || true
            ;;
        centos)
            local ver_major="${OS_VERSION_ID%%.*}"
            if [[ "$ver_major" == "7" ]]; then
                # CentOS 7 已 EOL，指向 centos-vault
                sed -i -E \
                    -e 's|^mirrorlist=|#mirrorlist=|g' \
                    -e "s|^#?baseurl=https?://mirror\.centos\.org/centos/\\\$releasever|baseurl=${PROTOCOL}://${host}/centos-vault/7.9.2009|g" \
                    -e "s|^baseurl=https?://[^/]+/centos-vault|baseurl=${PROTOCOL}://${host}/centos-vault|g" \
                    /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
            else
                # CentOS Stream 8 / 9 / 10
                sed -i -E \
                    -e 's|^metalink=|#metalink=|g' \
                    -e 's|^mirrorlist=|#mirrorlist=|g' \
                    -e "s|^#?baseurl=https?://mirror\.stream\.centos\.org|baseurl=${PROTOCOL}://${host}/centos-stream|g" \
                    -e "s|^baseurl=https?://[^/]+/centos-stream|baseurl=${PROTOCOL}://${host}/centos-stream|g" \
                    /etc/yum.repos.d/centos*.repo 2>/dev/null || true
            fi
            ;;
        fedora)
            sed -i -E \
                -e 's|^metalink=|#metalink=|g' \
                -e "s|^#?baseurl=https?://download\.example/pub/fedora/linux|baseurl=${PROTOCOL}://${host}/fedora|g" \
                -e "s|^baseurl=https?://[^/]+/fedora|baseurl=${PROTOCOL}://${host}/fedora|g" \
                /etc/yum.repos.d/fedora.repo /etc/yum.repos.d/fedora-updates.repo 2>/dev/null || true
            ;;
    esac

    echo -e "${GREEN}已更新 /etc/yum.repos.d/ 仓库配置。${NC}"
    echo -e "\n${CYAN}>>> 正在重建缓存...${NC}"
    if command -v dnf &>/dev/null; then
        dnf clean all && dnf makecache
    else
        yum clean all && yum makecache
    fi
}

switch_arch() {
    local host="$1"
    create_backup /etc/pacman.d/mirrorlist
    cat > /etc/pacman.d/mirrorlist <<EOF
## Domestic Mirror (${host})
Server = ${PROTOCOL}://${host}/archlinux/\$repo/os/\$arch
EOF
    echo -e "${GREEN}已更新: /etc/pacman.d/mirrorlist${NC}"
    echo -e "\n${CYAN}>>> 正在刷新 pacman 缓存...${NC}"
    pacman -Syy
}

# -------------------- 执行流程 --------------------

detect_os

if [[ "$DO_RESTORE" == true ]]; then
    restore_latest_backup
    exit 0
fi

# 交互选择镜像源
if [[ -z "$MIRROR_KEY" ]]; then
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}  Linux 一键切换国内软件源向导${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "  当前系统: ${GREEN}${OS_PRETTY}${NC}"
    echo -e "  发行代号: ${GREEN}${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME:-N/A})${NC} | 架构: ${GREEN}${ARCH}${NC}"
    echo -e "${CYAN}--------------------------------------------------${NC}"
    echo "  1) 清华大学 TUNA  (mirrors.tuna.tsinghua.edu.cn)"
    echo "  2) 阿里云 Aliyun  (mirrors.aliyun.com)"
    echo "  3) 中科大 USTC    (mirrors.ustc.edu.cn)"
    echo "  4) 腾讯云 Tencent (mirrors.cloud.tencent.com)"
    echo "  5) 华为云 Huawei  (mirrors.huaweicloud.com)"
    echo "  r) 回滚最近一次软件源备份"
    echo "  0) 退出"
    echo -e "${CYAN}--------------------------------------------------${NC}"
    read -rp "请选择国内镜像源 [默认: 1]: " choice
    choice=${choice:-1}

    case "$choice" in
        1) MIRROR_KEY="tuna" ;;
        2) MIRROR_KEY="aliyun" ;;
        3) MIRROR_KEY="ustc" ;;
        4) MIRROR_KEY="tencent" ;;
        5) MIRROR_KEY="huawei" ;;
        r|R) restore_latest_backup; exit 0 ;;
        0) echo "已退出。"; exit 0 ;;
        *) echo -e "${RED}无效选项。${NC}"; exit 1 ;;
    esac
fi

MIRROR_HOST=$(get_mirror_host "$MIRROR_KEY") || {
    echo -e "${RED}错误：不支持的镜像源标识 '${MIRROR_KEY}'（可选: tuna, aliyun, ustc, tencent, huawei）。${NC}"
    exit 1
}
MIRROR_NAME=$(get_mirror_name "$MIRROR_KEY")

check_https_support

echo -e "\n即将把 ${GREEN}${OS_PRETTY}${NC} 切换至: ${CYAN}${MIRROR_NAME} (${PROTOCOL}://${MIRROR_HOST})${NC}"
if [[ "$AUTO_YES" != true ]]; then
    read -rp "确认开始换源？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "已取消。"
        exit 0
    fi
fi

case "$OS_ID" in
    debian)
        switch_debian "$MIRROR_HOST"
        ;;
    ubuntu)
        switch_ubuntu "$MIRROR_HOST"
        ;;
    alpine)
        switch_alpine "$MIRROR_HOST"
        ;;
    rocky|almalinux|centos|fedora)
        switch_rhel_family "$MIRROR_HOST"
        ;;
    arch)
        switch_arch "$MIRROR_HOST"
        ;;
    *)
        echo -e "${RED}暂不支持的发行版: ${OS_ID} (${OS_PRETTY})${NC}"
        exit 1
        ;;
esac

echo -e "\n${GREEN}换源并刷新缓存完成！如需回滚可执行: sudo $0 --restore${NC}"
