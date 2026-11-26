#!/usr/bin/env bash
set -euo pipefail

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# 默认变量
GITHUB_USER=""
TARGET_USER="${SUDO_USER:-$(whoami)}"
CLI_MODE=""

usage() {
    cat <<EOF
用法:
  交互模式:
    $0

  快捷非交互模式（适合新开 VPS 一键执行）:
    $0 -u <GitHub用户名> [--append | --replace] [-t <目标系统用户>]

参数:
  -u, --github-user   GitHub 用户名
  -t, --target-user   要写入公钥的 Linux 用户名（默认: 当前用户 ${TARGET_USER}）
  --append            追加并去重模式（默认）
  --replace           覆盖模式（与 GitHub 保持完全一致，清理旧公钥）
  -h, --help          显示帮助
EOF
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--github-user)
            GITHUB_USER="${2:-}"
            shift 2
            ;;
        -t|--target-user)
            TARGET_USER="${2:-}"
            shift 2
            ;;
        --append)
            CLI_MODE="append"
            shift
            ;;
        --replace)
            CLI_MODE="replace"
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

# 获取目标用户家目录
get_user_home() {
    local user="$1"
    local home_dir
    home_dir=$(getent passwd "$user" | cut -d: -f6 || true)
    if [[ -z "$home_dir" ]]; then
        echo -e "${RED}错误：系统用户 '${user}' 不存在。${NC}" >&2
        return 1
    fi
    echo "$home_dir"
}

# 检查 curl / wget
fetch_github_keys() {
    local gh_user="$1"
    local url="https://github.com/${gh_user}.keys"
    local keys=""

    if command -v curl &>/dev/null; then
        keys=$(curl -fsSL --connect-timeout 10 --max-time 20 "$url" 2>/dev/null || true)
    elif command -v wget &>/dev/null; then
        keys=$(wget -qO- --timeout=15 "$url" 2>/dev/null || true)
    else
        echo -e "${RED}错误：未找到 curl 或 wget，请先安装其一。${NC}" >&2
        return 1
    fi

    # 过滤空行与回车符
    keys=$(printf '%s\n' "$keys" | tr -d '\r' | sed '/^[[:space:]]*$/d')

    # 严格校验公钥格式，防止拉到 404/HTML 页面把文件写坏
    if [[ -z "$keys" ]] || ! grep -qE '^(ssh-(ed25519|rsa|ecdsa)|sk-ssh-)' <<< "$keys"; then
        echo -e "${RED}错误：未能从 ${url} 获取到有效的 SSH 公钥，请检查用户名或网络连通性。${NC}" >&2
        return 1
    fi

    printf '%s\n' "$keys"
}

# 核心函数：应用公钥（mode: append | replace）
apply_keys() {
    local mode="$1"
    local gh_user="${2:-}"
    local target_user="${3:-$TARGET_USER}"

    if [[ -z "$gh_user" ]]; then
        read -rp "请输入 GitHub 用户名: " gh_user
    fi
    if [[ -z "$gh_user" ]]; then
        echo -e "${RED}GitHub 用户名不能为空。${NC}"
        return 1
    fi
    GITHUB_USER="$gh_user"

    # 若当前是 root，允许修改目标用户
    if [[ -z "$CLI_MODE" && "$(id -u)" -eq 0 ]]; then
        read -rp "目标 Linux 用户名 [默认: ${target_user}]: " input_user
        target_user="${input_user:-$target_user}"
        TARGET_USER="$target_user"
    fi

    local home_dir
    home_dir=$(get_user_home "$target_user") || return 1
    local ssh_dir="${home_dir}/.ssh"
    local auth_file="${ssh_dir}/authorized_keys"

    echo -e "\n${CYAN}>>> 正在从 GitHub 拉取 ${gh_user} 的公钥...${NC}"
    local keys
    keys=$(fetch_github_keys "$gh_user") || return 1

    local key_count
    key_count=$(wc -l <<< "$keys" | tr -d ' ')
    echo -e "${GREEN}成功获取 ${key_count} 条有效公钥。${NC}"

    if [[ "$mode" == "replace" && -z "$CLI_MODE" ]]; then
        echo -e "${YELLOW}警告：覆盖模式将清空 ${auth_file} 中不在 GitHub 列表里的旧公钥！${NC}"
        read -rp "确认继续覆盖？[y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "已取消操作。"
            return 0
        fi
    fi

    # 创建目录并备份旧文件
    mkdir -p "$ssh_dir"
    touch "$auth_file"

    if [[ -s "$auth_file" ]]; then
        local backup_file="${auth_file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -p "$auth_file" "$backup_file"
        echo -e "已备份原文件至: ${CYAN}${backup_file}${NC}"
    fi

    # 写入公钥（先写临时文件再原子替换，防止中途异常）
    local tmp_file
    tmp_file=$(mktemp)
    if [[ "$mode" == "replace" ]]; then
        printf '%s\n' "$keys" | sort -u > "$tmp_file"
    else
        {
            cat "$auth_file"
            printf '%s\n' "$keys"
        } | sed '/^[[:space:]]*$/d' | sort -u > "$tmp_file"
    fi

    mv "$tmp_file" "$auth_file"

    # 修正权限与属主
    chmod 700 "$ssh_dir"
    chmod 600 "$auth_file"
    if [[ "$(id -u)" -eq 0 ]]; then
        local target_group
        target_group=$(id -gn "$target_user")
        chown -R "${target_user}:${target_group}" "$ssh_dir"
    fi

    local final_count
    final_count=$(wc -l < "$auth_file" | tr -d ' ')
    echo -e "${GREEN}公钥应用成功！${NC}当前 ${auth_file} 共包含 ${GREEN}${final_count}${NC} 条公钥。"
}

# 查看当前已授权公钥
action_list_keys() {
    local target_user="$TARGET_USER"
    if [[ "$(id -u)" -eq 0 ]]; then
        read -rp "要查看哪个 Linux 用户的公钥 [默认: ${target_user}]: " input_user
        target_user="${input_user:-$target_user}"
    fi

    local home_dir
    home_dir=$(get_user_home "$target_user") || return 1
    local auth_file="${home_dir}/.ssh/authorized_keys"

    echo -e "\n${CYAN}=== ${auth_file} ===${NC}"
    if [[ ! -s "$auth_file" ]]; then
        echo -e "${YELLOW}（空或文件不存在）${NC}"
        return 0
    fi

    local i=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local key_type key_comment
        key_type=$(awk '{print $1}' <<< "$line")
        key_comment=$(awk '{print $3}' <<< "$line")
        echo -e "  ${i}) [${GREEN}${key_type}${NC}] ${key_comment:-（无备注）}  (${line:0:42}...)"
        ((i++))
    done < "$auth_file"
}

# 安全加固 SSH（关闭密码登录，开启公钥登录）
action_harden_ssh() {
    echo -e "\n${CYAN}=== SSH 登录安全加固（禁用密码，仅保留密钥登录） ===${NC}"

    if [[ "$(id -u)" -ne 0 ]]; then
        echo -e "${RED}此操作需要 root 权限，请使用 sudo 运行本脚本。${NC}"
        return 1
    fi

    local home_dir
    home_dir=$(get_user_home "$TARGET_USER") || return 1
    local auth_file="${home_dir}/.ssh/authorized_keys"

    # 防锁死检查
    if [[ ! -s "$auth_file" ]] || ! grep -qE '^(ssh-(ed25519|rsa|ecdsa)|sk-ssh-)' "$auth_file"; then
        echo -e "${RED}拦截：未在 ${auth_file} 中检测到有效公钥！${NC}"
        echo -e "${YELLOW}为防止把自己锁在服务器外面，请先通过菜单 1 或 2 导入公钥。${NC}"
        return 1
    fi

    echo -e "${YELLOW}准备执行以下配置：${NC}"
    echo "  - PubkeyAuthentication yes"
    echo "  - PasswordAuthentication no"
    echo "  - KbdInteractiveAuthentication no"
    echo "  - ChallengeResponseAuthentication no"
    read -rp "确认应用以上 SSH 加固配置？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        return 0
    fi

    local sshd_main="/etc/ssh/sshd_config"
    local dropin_dir="/etc/ssh/sshd_config.d"
    local dropin_file="${dropin_dir}/99-github-ssh-hardening.conf"

    cp -p "$sshd_main" "${sshd_main}.bak.$(date +%Y%m%d_%H%M%S)"

    # 优先使用 sshd_config.d（Ubuntu 22.04+/Debian 12+/RHEL 9+ 默认支持）
    if [[ -d "$dropin_dir" ]] && grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$sshd_main"; then
        cat > "$dropin_file" <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
        echo -e "已写入配置片段: ${CYAN}${dropin_file}${NC}"
    else
        # 回退到直接修改主配置文件
        for kv in \
            "PubkeyAuthentication yes" \
            "PasswordAuthentication no" \
            "ChallengeResponseAuthentication no" \
            "KbdInteractiveAuthentication no"; do
            local key="${kv%% *}"
            if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "$sshd_main"; then
                sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${kv}|" "$sshd_main"
            else
                echo "$kv" >> "$sshd_main"
            fi
        done
        echo -e "已更新主配置: ${CYAN}${sshd_main}${NC}"
    fi

    # 校验 sshd 语法
    echo -e "${CYAN}>>> 正在校验 sshd 配置语法...${NC}"
    if ! sshd -t; then
        echo -e "${RED}sshd 配置语法校验失败！正在回滚...${NC}"
        rm -f "$dropin_file"
        return 1
    fi

    # 平滑重载 sshd（不会踢掉当前会话）
    if command -v systemctl &>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd
    else
        service ssh reload 2>/dev/null || service sshd reload
    fi

    echo -e "${GREEN}SSH 配置已平滑重载！${NC}"
    echo -e "${YELLOW}重要提示：请先不要关闭当前终端！新开一个终端测试密钥登录成功后再断开。${NC}"
}

# 回滚最近一次 authorized_keys 备份
action_rollback() {
    local home_dir
    home_dir=$(get_user_home "$TARGET_USER") || return 1
    local ssh_dir="${home_dir}/.ssh"
    local auth_file="${ssh_dir}/authorized_keys"

    local latest_bak
    latest_bak=$(ls -1t "${auth_file}".bak.* 2>/dev/null | head -n 1 || true)

    if [[ -z "$latest_bak" ]]; then
        echo -e "${YELLOW}未找到 ${auth_file} 的历史备份文件。${NC}"
        return 0
    fi

    echo -e "找到最近备份: ${CYAN}${latest_bak}${NC}"
    read -rp "确认使用该备份覆盖当前 authorized_keys？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cp -p "$latest_bak" "$auth_file"
        chmod 600 "$auth_file"
        echo -e "${GREEN}已成功恢复备份。${NC}"
    else
        echo "已取消。"
    fi
}

# 如果传入了命令行参数，直接走快捷非交互模式
if [[ -n "$GITHUB_USER" ]]; then
    apply_keys "${CLI_MODE:-append}" "$GITHUB_USER" "$TARGET_USER"
    exit 0
fi

# 交互主菜单
main_menu() {
    while true; do
        echo -e "\n${CYAN}============================================${NC}"
        echo -e "${CYAN}  VPS / 虚拟机 GitHub SSH Key 应用向导${NC}"
        echo -e "${CYAN}  当前目标用户: ${GREEN}${TARGET_USER}${CYAN} (执行身份: $(whoami))${NC}"
        echo -e "${CYAN}============================================${NC}"
        echo "  1) 拉取 GitHub 公钥并追加（保留现有公钥，自动去重）"
        echo "  2) 拉取 GitHub 公钥并覆盖（与 GitHub 保持完全一致）"
        echo "  3) 查看当前已授权公钥列表"
        echo "  4) 安全加固 SSH（关闭密码登录，防锁死检测）"
        echo "  5) 回滚最近一次 authorized_keys 备份"
        echo "  0) 退出"
        echo -e "${CYAN}--------------------------------------------${NC}"
        read -rp "请选择操作 [0-5]: " choice

        case "$choice" in
            1) apply_keys "append" "$GITHUB_USER" "$TARGET_USER" || true ;;
            2) apply_keys "replace" "$GITHUB_USER" "$TARGET_USER" || true ;;
            3) action_list_keys || true ;;
            4) action_harden_ssh || true ;;
            5) action_rollback || true ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo -e "${RED}无效选项，请输入 0-5。${NC}" ;;
        esac
    done
}

main_menu
