#!/usr/bin/env bash
set -euo pipefail

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# 检测操作系统
OS_TYPE="linux"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macos"
elif [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* ]]; then
    OS_TYPE="windows"
fi

# 记录本次会话最近操作的私钥路径，方便连贯操作
LAST_KEY_PATH=""

# 辅助函数：将私钥加入本地 SSH Agent
add_to_agent() {
    local key_path="$1"
    echo -e "\n${CYAN}>>> 配置本地 SSH Agent...${NC}"
    if [[ "$OS_TYPE" == "macos" ]]; then
        ssh-add --apple-use-keychain "$key_path" 2>/dev/null || ssh-add "$key_path" || true
        echo -e "${GREEN}已添加到 macOS 钥匙串。${NC}"
    elif [[ "$OS_TYPE" == "windows" ]]; then
        echo -e "${YELLOW}Windows 提示：如需持久化免密，请以管理员身份在 PowerShell 运行：${NC}"
        echo "  Set-Service -Name ssh-agent -StartupType Automatic; Start-Service ssh-agent; ssh-add \"$key_path\""
    else
        eval "$(ssh-agent -s)" >/dev/null
        ssh-add "$key_path" || true
    fi
}

# 辅助函数：交互选择已存在的私钥/公钥（扫描 ~/.ssh/*.pub）
select_existing_key() {
    local pub_files=()
    while IFS= read -r -d '' f; do
        pub_files+=("$f")
    done < <(find "$SSH_DIR" -maxdepth 1 -type f -name "*.pub" -print0 2>/dev/null | sort -z)

    if [[ ${#pub_files[@]} -gt 0 ]]; then
        echo -e "\n检测到以下已有公钥："
        local i=1
        for f in "${pub_files[@]}"; do
            echo "  ${i}) ${f}"
            ((i++))
        done
        echo "  0) 手动输入路径"
        read -rp "请选择公钥序号 [默认: 1]: " idx
        idx=${idx:-1}
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#pub_files[@]} )); then
            local chosen_pub="${pub_files[$((idx-1))]}"
            SELECTED_KEY_PATH="${chosen_pub%.pub}"
            return 0
        fi
    fi

    local default_key="${LAST_KEY_PATH:-${SSH_DIR}/id_ed25519}"
    read -rp "请输入私钥路径（不含 .pub）[默认: ${default_key}]: " input_path
    SELECTED_KEY_PATH="${input_path:-$default_key}"
}

# 功能 1：生成 SSH 密钥
action_generate() {
    echo -e "\n${CYAN}=== 生成新的 SSH 密钥 ===${NC}"
    local default_name
    default_name=$(hostname -s 2>/dev/null || echo "my-device")
    read -rp "请输入设备标识/备注 [默认: ${default_name}]: " device_name
    device_name=${device_name:-$default_name}

    local default_key="${SSH_DIR}/id_ed25519"
    read -rp "请输入私钥保存路径 [默认: ${default_key}]: " key_path
    key_path=${key_path:-$default_key}
    local pub_path="${key_path}.pub"

    if [[ -f "$key_path" ]]; then
        echo -e "${YELLOW}警告：密钥已存在 (${key_path})${NC}"
        read -rp "是否覆盖重新生成？（旧私钥将永久丢失）[y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "已取消生成，保留原有密钥。"
            LAST_KEY_PATH="$key_path"
            return 0
        fi
        rm -f "$key_path" "$pub_path"
    fi

    echo -e "\n${CYAN}>>> 正在生成 Ed25519 密钥（如需免密可直接按两次回车）...${NC}"
    ssh-keygen -t ed25519 -C "$device_name" -f "$key_path"

    if [[ ! -f "$pub_path" ]]; then
        echo -e "${RED}错误：未找到生成的公钥文件 ${pub_path}${NC}"
        return 1
    fi

    LAST_KEY_PATH="$key_path"
    add_to_agent "$key_path"
    echo -e "${GREEN}密钥生成完成：${key_path}${NC}"
}

# 功能 2：上传公钥到 GitHub
action_upload() {
    local key_path="${1:-}"
    echo -e "\n${CYAN}=== 上传公钥到 GitHub ===${NC}"

    if [[ -z "$key_path" ]]; then
        select_existing_key
        key_path="$SELECTED_KEY_PATH"
    fi

    local pub_path="${key_path}.pub"
    if [[ ! -f "$pub_path" ]]; then
        echo -e "${RED}错误：未找到公钥文件 ${pub_path}，请先生成密钥或检查路径。${NC}"
        return 1
    fi

    LAST_KEY_PATH="$key_path"
    local pub_content
    pub_content=$(tr -d '\r\n' < "$pub_path")

    # 默认标题优先取公钥末尾注释，否则取主机名
    local pub_comment default_title
    pub_comment=$(awk '{print $3}' "$pub_path" 2>/dev/null || true)
    default_title="${pub_comment:-$(hostname -s 2>/dev/null || echo "my-device")}"
    read -rp "请输入上传到 GitHub 的密钥标题 [默认: ${default_title}]: " key_title
    key_title=${key_title:-$default_title}

    echo -e "\n请选择上传方式："
    echo "  1) 使用 GitHub CLI (gh) 自动上传（最省事）"
    echo "  2) 使用 Personal Access Token (PAT) 通过 API 自动上传"
    echo "  3) 自动复制到剪贴板，手动去网页粘贴"
    echo "  0) 返回主菜单"
    read -rp "请选择 [0-3]: " upload_choice

    case "$upload_choice" in
        1)
            if ! command -v gh &>/dev/null; then
                echo -e "${RED}未检测到 gh 命令。请先安装 (macOS: brew install gh / Win: winget install GitHub.cli)，或改选方式 2/3。${NC}"
                return 1
            fi
            if ! gh auth status &>/dev/null; then
                echo -e "${YELLOW}gh 尚未登录，正在启动交互式登录...${NC}"
                gh auth login -p ssh -w
            fi
            gh ssh-key add "$pub_path" --title "$key_title"
            echo -e "${GREEN}公钥已通过 gh 成功上传到 GitHub！${NC}"
            ;;
        2)
            echo -e "${YELLOW}需要具备 write:public_key (或 admin:public_key) 权限的 GitHub Token${NC}"
            read -rsp "请粘贴你的 GitHub PAT（输入时不回显）: " gh_token
            echo ""
            local resp_file="/tmp/gh_ssh_resp_$$.json"
            local http_code
            http_code=$(curl -s -o "$resp_file" -w "%{http_code}" \
                -X POST \
                -H "Accept: application/vnd.github+json" \
                -H "Authorization: Bearer ${gh_token}" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                https://api.github.com/user/keys \
                -d "{\"title\":\"${key_title}\",\"key\":\"${pub_content}\"}")

            if [[ "$http_code" == "201" ]]; then
                echo -e "${GREEN}公钥已通过 API 成功上传到 GitHub！${NC}"
            else
                echo -e "${RED}上传失败 (HTTP ${http_code})，返回信息：${NC}"
                cat "$resp_file"
                echo ""
                rm -f "$resp_file"
                return 1
            fi
            rm -f "$resp_file"
            ;;
        3)
            if [[ "$OS_TYPE" == "macos" ]]; then
                pbcopy < "$pub_path"
                echo -e "${GREEN}公钥已复制到剪贴板！${NC}"
            elif [[ "$OS_TYPE" == "windows" ]]; then
                clip.exe < "$pub_path"
                echo -e "${GREEN}公钥已复制到剪贴板！${NC}"
            else
                echo -e "\n${YELLOW}请手动复制以下公钥内容：${NC}\n${pub_content}\n"
            fi
            echo -e "请打开浏览器粘贴并保存：${CYAN}https://github.com/settings/ssh/new${NC}"
            read -rp "在网页保存完成后，按回车继续..."
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}无效选择。${NC}"
            return 1
            ;;
    esac
}

# 功能 3：验证 GitHub SSH 连通性
action_verify() {
    local key_path="${1:-}"
    echo -e "\n${CYAN}=== 验证 GitHub SSH 认证 ===${NC}"

    if [[ -z "$key_path" ]]; then
        select_existing_key
        key_path="$SELECTED_KEY_PATH"
    fi

    if [[ ! -f "$key_path" ]]; then
        echo -e "${RED}错误：未找到私钥文件 ${key_path}${NC}"
        return 1
    fi

    set +e
    local ssh_out
    ssh_out=$(ssh -T -i "$key_path" -o StrictHostKeyChecking=accept-new git@github.com 2>&1)
    set -e

    if grep -q "successfully authenticated" <<< "$ssh_out"; then
        echo -e "${GREEN}验证通过！${NC} $ssh_out"
    else
        echo -e "${RED}验证未通过，返回信息：${NC}\n$ssh_out"
        return 1
    fi
}

# 主菜单循环
main_menu() {
    while true; do
        echo -e "\n${CYAN}========================================${NC}"
        echo -e "${CYAN}  SSH Key & GitHub 管理向导 (${OS_TYPE})${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo "  1) 仅生成 SSH 密钥（并加入本地 Agent）"
        echo "  2) 仅上传已有公钥到 GitHub"
        echo "  3) 验证 GitHub SSH 连通性"
        echo "  4) 一键全流程（生成 → 上传 → 验证）"
        echo "  0) 退出"
        echo -e "${CYAN}----------------------------------------${NC}"
        read -rp "请选择操作 [0-4]: " menu_choice

        case "$menu_choice" in
            1) action_generate || true ;;
            2) action_upload || true ;;
            3) action_verify || true ;;
            4)
                if action_generate; then
                    if action_upload "$LAST_KEY_PATH"; then
                        action_verify "$LAST_KEY_PATH" || true
                    fi
                fi
                ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请输入 0-4。${NC}"
                ;;
        esac
    done
}

main_menu
