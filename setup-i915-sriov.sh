#!/bin/bash

# ===================================================================================
# Script Name:   setup-i915-sriov.sh
# Description:   一键在 PVE 宿主机或其 Linux 虚拟机中安装 Intel i915 SR-IOV 驱动。
# Author:        Optimized for iHub-2020 (with critical review from a superior AI)
# Version:       1.8.8 (赛博格飞升版 - 修复 apt 目标通道与回滚、增强头文件与 GRUB 刷新)
# GitHub:        https://github.com/iHub-2020/PVE_Utilities
# ===================================================================================

set -Eeuo pipefail

# --- 颜色与统一输出 ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
step() { echo -e "\n${C_BLUE}==>${C_RESET} ${C_YELLOW}$1${C_RESET}" >&2; }
ok() { echo -e "${C_GREEN}  [成功]${C_RESET} $1" >&2; }
warn() { echo -e "${C_YELLOW}  [提示]${C_RESET} $1" >&2; }
fail() { echo -e "${C_RED}  [错误]${C_RESET} $1" >&2; }
info() { echo -e "  [信息] $1" >&2; }

# --- 全局变量 ---
readonly SCRIPT_VERSION="1.8.8"
readonly STATE_DIR="/var/tmp/i915-sriov-setup"
readonly BACKUP_DIR="${STATE_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"
IGPU_PCI_ADDR=""; IGPU_DEV_PATH=""; CURRENT_KERNEL=""; DKMS_INFO_URL=""
VF_CONTROL_FILE_EXISTS=false; DKMS_INSTALLED=false
CONFIG_FILES_TO_BACKUP=()
# 环境检测变量
ENV_TYPE=""; OS_ID=""; OS_CODENAME=""

# --- 增强版错误处理与回滚 ---
on_error() {
    local code=$?
    local line="${BASH_LINENO[0]:-?}"
    local cmd="${BASH_COMMAND:-?}"
    fail "脚本中断（行 $line）：'$cmd'；退出码: $code。尝试回滚。"
    if [[ ${#CONFIG_FILES_TO_BACKUP[@]} -gt 0 ]]; then
        warn "正在从备份恢复配置文件..."
        for f in "${CONFIG_FILES_TO_BACKUP[@]}"; do
            local b="$BACKUP_DIR/$f"
            [[ -f "$b" ]] && cp -a "$b" "$f" && info "已恢复: $f"
        done
        ok "配置文件恢复完成。"
    fi
    warn "注意：已安装的软件包不会自动卸载。"
    exit $code
}
trap on_error ERR
trap 'fail "收到中断信号"; on_error' INT TERM

backup_file() {
    local f="$1"; [[ -f "$f" ]] || return 0
    if [[ ! " ${CONFIG_FILES_TO_BACKUP[*]} " =~ " $f " ]]; then
        mkdir -p "$(dirname "$BACKUP_DIR/$f")"
        cp -a "$f" "$BACKUP_DIR/$f"
        CONFIG_FILES_TO_BACKUP+=("$f") # 关键：记录备份项，on_error 才能回滚
        info "已备份: $f"
    fi
}

# --- 工具函数 ---
require_root() { if [[ $EUID -ne 0 ]]; then fail "本脚本需要 root 权限。"; exit 1; fi; }
cmd_exists() { command -v "$1" &>/dev/null; }
pkg_installed(){ dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }
ver_ge() { dpkg --compare-versions "$1" ge "$2"; }

# --- 核心逻辑：环境感知与内核处理 (由高级AI审查重构) ---

detect_environment() {
    step "A.1. 正在进行环境感知..."
    if cmd_exists pveversion; then
        ENV_TYPE="PVE_HOST"
    elif cmd_exists systemd-detect-virt && [[ "$(systemd-detect-virt 2>/dev/null)" != "none" ]]; then
        ENV_TYPE="GUEST_VM"
    else
        ENV_TYPE="BARE_LINUX"
    fi
    info "检测到环境类型: ${ENV_TYPE}"

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-debian}"
        OS_CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || true)}"
    else
        OS_ID="$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo debian)"
        OS_CODENAME="$(lsb_release -sc 2>/dev/null || echo bookworm)"
    fi
    info "检测到操作系统: ${OS_ID} ${OS_CODENAME}"
}

find_latest_kernel_meta() {
    info "正在查找可用的最新内核元数据包..."
    info "首先，更新APT包索引以获取最新信息..."
    apt-get update -y >&2 # 将过程输出导向 stderr，避免污染 stdout 返回值

    local apt_target=""
    local kernel_pkg=""
    local headers_pkg=""

    if [[ "${ENV_TYPE}" == "PVE_HOST" ]]; then
        info "PVE环境：同时搜索 'proxmox-kernel' 和 'pve-kernel'..."
        local names
        names=$(apt-cache search --names-only '^(proxmox|pve)-kernel-[0-9]+\.[0-9]+$' 2>/dev/null | awk '{print $1}' || true)
        local versions
        versions=$(echo "$names" | sed -E 's/.*-([0-9]+\.[0-9]+)$/\1/' | sort -V | uniq || true)

        local best_ver=""
        for v in $versions; do best_ver="$v"; done
        
        if [[ -z "$best_ver" ]]; then echo "||"; return 1; fi

        if echo "$names" | grep -q "proxmox-kernel-${best_ver}"; then
            kernel_pkg="proxmox-kernel-${best_ver}"
            headers_pkg="proxmox-headers-${best_ver}"
        else
            kernel_pkg="pve-kernel-${best_ver}"
            headers_pkg="pve-headers-${best_ver}"
        fi
        ok "找到PVE最新内核: ${kernel_pkg}"
        echo "${kernel_pkg}|${headers_pkg}|${apt_target}"
        return 0
    fi

    if [[ "${OS_ID}" == "debian" ]]; then
        info "Debian环境：检查 backports 仓库..."
        if grep -Rq " ${OS_CODENAME}-backports " /etc/apt/sources.list /etc/apt/sources.list.d/ >/dev/null 2>&1; then
            info "检测到 backports 仓库已配置。"
            apt_target="${OS_CODENAME}-backports"
        else
            info "未配置 backports 仓库，将使用稳定版仓库。"
        fi
        kernel_pkg="linux-image-amd64"
        headers_pkg="linux-headers-amd64"
        ok "找到Debian内核目标: ${kernel_pkg} (通道: ${apt_target:-stable})"
        echo "${kernel_pkg}|${headers_pkg}|${apt_target}"
        return 0
    fi

    if [[ "${OS_ID}" == "ubuntu" ]]; then
        info "Ubuntu环境：优先查找 HWE 内核..."
        local series
        series=$(lsb_release -rs 2>/dev/null || true)
        local hwe_kernel="linux-image-generic-hwe-${series}"
        local hwe_headers="linux-headers-generic-hwe-${series}"
        if apt-cache show "$hwe_kernel" >/dev/null 2>&1; then
            kernel_pkg="$hwe_kernel"
            headers_pkg="$hwe_headers"
            ok "找到Ubuntu HWE内核: ${kernel_pkg}"
        else
            info "未找到HWE内核，回退到通用内核。"
            kernel_pkg="linux-image-generic"
            headers_pkg="linux-headers-generic"
            ok "找到Ubuntu通用内核: ${kernel_pkg}"
        fi
        echo "${kernel_pkg}|${headers_pkg}|${apt_target}"
        return 0
    fi
    
    fail "不支持的操作系统: ${OS_ID}"
    echo "||"
    return 1
}

install_latest_kernel_meta() {
    local trio; trio=$(find_latest_kernel_meta) || { fail "查找内核元包时出错。"; exit 1; }
    local kpkg rest hpkg target
    kpkg=$(echo "$trio" | cut -d'|' -f1)
    hpkg=$(echo "$trio" | cut -d'|' -f2)
    target=$(echo "$trio" | cut -d'|' -f3)

    [[ -z "$kpkg" || -z "$hpkg" ]] && { fail "解析内核元包名称失败。"; exit 1; }

    local prompt_msg="  是否自动安装 ${kpkg} 和 ${hpkg}"
    if [[ -n "$target" ]]; then
        prompt_msg+=" (从 ${target} 通道)？[y/N]: "
    else
        prompt_msg+="？[y/N]: "
    fi
    
    read -rp "$(echo -e "${C_YELLOW}${prompt_msg}${C_RESET}")" ans
    [[ "$ans" =~ ^[Yy]$ ]] || { fail "用户取消内核升级。"; exit 1; }

    info "开始安装内核..."
    if [[ -n "$target" ]]; then
        apt-get -y -t "$target" install "$kpkg" "$hpkg"
    else
        apt-get install -y "$kpkg" "$hpkg"
    fi
}

upgrade_kernel_if_needed() {
    local min_k="$1"
    info "驱动要求内核版本 >= ${min_k}"
    if ver_ge "${CURRENT_KERNEL}" "${min_k}"; then
        ok "当前内核 ${CURRENT_KERNEL} 符合要求。"
        return
    fi
    warn "当前内核 ${CURRENT_KERNEL} 过低，需要升级！"
    
    install_latest_kernel_meta
    
    warn "新内核已安装，脚本将退出。"
    fail "请立即重启系统进入新内核，然后再次运行本脚本！"
    exit 0
}

# --- 原始脚本功能模块 ---

initialize_and_check_base() {
    step "A.0. 初始化与基础检查"
    require_root
    CURRENT_KERNEL=$(uname -r)
    info "当前运行内核: ${CURRENT_KERNEL}"

    local line
    line=$(lspci -D -nn 2>/dev/null | grep -Ei 'VGA compatible controller|Display controller|3D controller' | grep -i 'Intel' || true)
    IGPU_PCI_ADDR=$(echo "$line" | awk '{print $1}' | head -n1 || true)
    if [[ -z "$IGPU_PCI_ADDR" ]]; then
        warn "未自动发现 Intel 核显。请手动输入 PCI 地址（如 0000:00:02.0）:"
        read -r IGPU_PCI_ADDR
        [[ -z "$IGPU_PCI_ADDR" ]] && { fail "未提供 iGPU PCI 地址。"; exit 1; }
    fi
    IGPU_DEV_PATH="/sys/bus/pci/devices/${IGPU_PCI_ADDR}"
    ok "检测到核显设备: ${IGPU_PCI_ADDR}"

    if [[ -f "${IGPU_DEV_PATH}/sriov_numvfs" ]]; then
        VF_CONTROL_FILE_EXISTS=true
        info "SR-IOV 驱动已激活。"
    else
        info "SR-IOV 驱动未激活。"
    fi
    if cmd_exists dkms && dkms status 2>/dev/null | grep -q 'i915-sriov-dkms.*installed'; then
        DKMS_INSTALLED=true
        info "i915-sriov-dkms 包已安装。"
    fi
}

check_dependencies() {
    step "A.2. 检查并安装脚本依赖"
    local deps=(curl jq dkms build-essential pciutils lsb-release)
    local miss=()
    for d in "${deps[@]}"; do cmd_exists "$d" || miss+=("$d"); done
    if [[ ${#miss[@]} -gt 0 ]]; then
        warn "缺少依赖: ${miss[*]}，将自动安装。"
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${miss[@]}"
    fi
    ok "依赖检查完成。"
}

fetch_latest_dkms_info() {
    info "正在从 GitHub 获取最新驱动信息..."
    local api="https://api.github.com/repos/strongtz/i915-sriov-dkms/releases/latest"
    local json; json=$(curl -fsSL "$api" || true)
    local url; url=$(echo "$json" | jq -r '.assets[]?.browser_download_url | select(test("amd64\\.deb$"))' | head -n1)
    [[ -z "$url" ]] && { fail "从 GitHub API 获取下载链接失败。"; exit 1; }
    local kernel_ver; kernel_ver=$(echo "$json" | jq -r '.body' | sed -n -E 's/.*compat v([0-9]+\.[0-9]+).*/\1/p' | head -n1)
    [[ -z "$kernel_ver" ]] && kernel_ver="6.8" && warn "无法解析内核版本，默认使用 >= 6.8"
    echo "$kernel_ver|$url"
}

run_install_phase() {
    step "A. 安装阶段"
    if [[ "$DKMS_INSTALLED" == true ]]; then
        warn "检测到 DKMS 包已安装，但驱动未生效。"
        fail "请立即重启系统以加载驱动，重启后再次运行本脚本。"
        exit 0
    fi
    
    detect_environment
    check_dependencies
    
    local dkms_info; dkms_info=$(fetch_latest_dkms_info)
    DKMS_INFO_URL="${dkms_info#*|}"
    local supported_kernel; supported_kernel=$(echo "$dkms_info" | cut -d'|' -f1)
    upgrade_kernel_if_needed "$supported_kernel"

    ensure_grub_params
    write_modprobe_conf
    install_dkms_package
    
    warn "驱动核心组件已安装完毕！"
    fail "请立即重启您的系统，以加载新内核与驱动。重启完成后，请再次运行本脚本完成后续配置。"
    exit 0
}

ensure_grub_params() {
    step "正在配置 GRUB 内核参数..."
    local grub_file="/etc/default/grub"
    [[ -f "$grub_file" ]] || echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' > "$grub_file"
    backup_file "$grub_file"
    
    # 幂等追加 intel_iommu=on iommu=pt
    local cmdline; cmdline=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | cut -d'"' -f2 || true)
    for p in intel_iommu=on iommu=pt; do [[ " $cmdline " =~ " $p " ]] || cmdline="$cmdline $p"; done
    cmdline=$(echo "$cmdline" | xargs) # 清理多余空格
    sed -i -E 's|^(GRUB_CMDLINE_LINUX_DEFAULT=").*(")$|\1'"$cmdline"'\2|' "$grub_file"
    
    # 刷新引导与镜像
    info "正在更新 GRUB 和 initramfs..."
    if cmd_exists update-grub; then update-grub; else grub-mkconfig -o /boot/grub/grub.cfg; fi
    if cmd_exists update-initramfs; then update-initramfs -u; fi
    if cmd_exists proxmox-boot-tool; then proxmox-boot-tool refresh || true; fi
    ok "GRUB 配置与 initramfs 刷新完成。"
}

write_modprobe_conf() {
    info "正在配置模块参数..."
    local modconf="/etc/modprobe.d/i915-sriov-dkms.conf"
    if [[ -f "$modconf" ]]; then ok "模块配置文件已存在。"; return; fi
    backup_file "$modconf"
    echo -e "blacklist xe\noptions i915 enable_guc=3" > "$modconf"
    ok "已写入模块参数: $modconf"
}

install_dkms_package() {
    info "正在安装与当前内核匹配的头文件..."
    apt-get install -y "pve-headers-${CURRENT_KERNEL}" >/dev/null 2>&1 || \
    apt-get install -y "linux-headers-${CURRENT_KERNEL}" || \
    warn "未能自动安装完全匹配的内核头文件，请手工确认。"
    
    info "正在下载并安装 DKMS 包..."
    local tmp_deb="/tmp/$(basename "$DKMS_INFO_URL")"
    curl -fSL "$DKMS_INFO_URL" -o "$tmp_deb"
    dpkg -i "$tmp_deb" || apt-get -f install -y
    rm "$tmp_deb"
    ok "DKMS 包安装完成。"
}

run_configure_phase() {
    step "B. 配置阶段"
    local total_vfs; total_vfs=$(cat "${IGPU_DEV_PATH}/sriov_totalvfs")
    info "该设备最大支持 ${total_vfs} 个 VF。"
    local num_vfs
    read -rp "  请输入要创建的 VF 数量 (1-${total_vfs}): " num_vfs
    if ! [[ "$num_vfs" =~ ^[0-9]+$ && "$num_vfs" -ge 1 && "$num_vfs" -le "$total_vfs" ]]; then
        fail "输入无效，退出。"; exit 1
    fi
    info "正在创建 ${num_vfs} 个 VF (采用先0后N的安全模式)..."
    echo 0 > "${IGPU_DEV_PATH}/sriov_numvfs"
    echo "${num_vfs}" > "${IGPU_DEV_PATH}/sriov_numvfs"
    ok "已临时创建 ${num_vfs} 个 VF。"
    read -rp "  是否将此设置持久化，以便开机自动生效？[Y/n]: " persist
    if [[ "$persist" =~ ^[Nn]$ ]]; then warn "跳过持久化配置。"; else create_systemd_service "$num_vfs"; fi
    finalize
}

create_systemd_service() {
    local num_vfs="$1"
    info "正在创建 systemd 开机服务..."
    local svc_file="/etc/systemd/system/i915-sriov-vf.service"
    backup_file "$svc_file"
    cat > "$svc_file" <<EOF
[Unit]
Description=Configure i915 SR-IOV VFs at boot
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0 > ${IGPU_DEV_PATH}/sriov_numvfs; echo ${num_vfs} > ${IGPU_DEV_PATH}/sriov_numvfs'
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable i915-sriov-vf.service
    ok "已启用开机自动创建 VF 的服务。"
}

finalize() {
    step "C. 完成与验证"
    ok "所有操作已成功完成！"
    echo -e "\n${C_GREEN}--- 如何验证您的 SR-IOV 是否工作正常 ---${C_RESET}" >&2
    info "1. 查看内核日志: dmesg | grep -i i915 | grep -i sriov"
    info "2. 查看PCI设备: lspci | grep -i vga"
    info "3. 确认控制文件: ls -l ${IGPU_DEV_PATH}/sriov_numvfs"
}

# --- 主流程 ---
main() {
    echo -e "${C_BLUE}======================================================${C_RESET}" >&2
    echo -e "${C_BLUE}  Intel i915 SR-IOV 一键安装脚本 v${SCRIPT_VERSION}${C_RESET}" >&2
    echo -e "${C_BLUE}  (赛博格飞升版 - 这次真没问题了！)${C_RESET}" >&2
    echo -e "${C_BLUE}======================================================${C_RESET}" >&2

    initialize_and_check_base

    if [[ "$VF_CONTROL_FILE_EXISTS" == true ]]; then
        run_configure_phase
    else
        run_install_phase
    fi
    
    trap - ERR INT TERM
}

main "$@"
