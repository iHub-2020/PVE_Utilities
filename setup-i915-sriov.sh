#!/bin/bash

# ===================================================================================
# Script Name:   setup-i915-sriov.sh
# Description:   一键在 PVE 宿主机或其 Linux 虚拟机中安装 Intel i915 SR-IOV 驱动。
# Author:        Optimized for iHub-2020
# Version:       1.5.6 (再次重写内核清理逻辑，严格限定范围，杜绝误删)
# GitHub:        https://github.com/iHub-2020/PVE_Utilities
# ===================================================================================

set -Eeuo pipefail

# --- 颜色与统一输出 ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
step() { echo -e "\n${C_BLUE}==>${C_RESET} ${C_YELLOW}$1${C_RESET}"; }
ok() { echo -e "${C_GREEN}  [成功]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}  [提示]${C_RESET} $1"; }
fail() { echo -e "${C_RED}  [错误]${C_RESET} $1"; }

# --- 全局变量与常量 ---
readonly SCRIPT_VERSION="1.5.6"
readonly STATE_DIR="/var/tmp/i915-sriov-setup"
readonly BACKUP_DIR="${STATE_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"

# --- 全局变量（动态填充） ---
ENV_TYPE=""            # PVE_HOST / GUEST_VM
OS_ID=""               # debian / ubuntu
OS_CODENAME=""         # bookworm / jammy / noble ...
CURRENT_KERNEL=""      # uname -r
CURRENT_KMM=""         # 主次版本 X.Y
SUPPORTED_KERNEL_MIN=""
SUPPORTED_KERNEL_MAX=""
DKMS_PACKAGE_URL=""
DKMS_PACKAGE_NAME=""

# --- 回滚相关 ---
CONFIG_FILES_TO_BACKUP=()

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    if [[ ! " ${CONFIG_FILES_TO_BACKUP[*]} " =~ " $f " ]]; then
        mkdir -p "$(dirname "$BACKUP_DIR/$f")"
        cp -a "$f" "$BACKUP_DIR/$f"
        CONFIG_FILES_TO_BACKUP+=("$f")
        warn "已备份: $f -> $BACKUP_DIR/$f"
    fi
}

restore_from_backup() {
    if [[ ${#CONFIG_FILES_TO_BACKUP[@]} -eq 0 ]]; then
        warn "无需恢复（未修改配置文件）。"; return 0
    fi
    warn "正在从备份恢复配置文件..."
    for f in "${CONFIG_FILES_TO_BACKUP[@]}"; do
        local b="$BACKUP_DIR/$f"
        if [[ -f "$b" ]]; then
            mkdir -p "$(dirname "$f")"
            cp -a "$b" "$f"
            warn "已恢复: $f"
        fi
    done
    ok "配置文件恢复完成。"
}

on_error() {
    local code=$?
    fail "脚本执行中断，退出码: $code。将尝试自动回滚配置文件。"
    restore_from_backup
    warn "注意：已安装的软件包不会自动卸载，如需彻底回退请手动卸载相关包。"
    exit $code
}
trap on_error ERR
trap 'fail "收到中断信号"; on_error' INT TERM

# --- 工具函数 ---
require_root() {
    if [[ $EUID -ne 0 ]]; then
        fail "本脚本需要 root 权限，请使用 sudo 运行。"
        exit 1
    fi
}
cmd_exists() { command -v "$1" &>/dev/null; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }
pkg_exists() { apt-cache show "$1" &>/dev/null; }
ver_in_range() { dpkg --compare-versions "$1" ge "$2" && dpkg --compare-versions "$1" le "$3"; }
apt_install() {
    local pkgs=("$@")
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

# --- 依赖检查 ---
check_dependencies() {
    step "检查并安装所需依赖"
    local deps=(curl jq bc dkms build-essential pciutils lsb-release)
    local miss=()
    for d in "${deps[@]}"; do cmd_exists "$d" || miss+=("$d"); done
    if [[ ${#miss[@]} -gt 0 ]]; then
        warn "缺少依赖: ${miss[*]}，将自动安装。"
        apt_install "${miss[@]}"
    fi
    ok "依赖检查完成。"
}

# --- 环境与系统探测 ---
detect_environment() {
    step "检测运行环境"
    if cmd_exists pveversion; then
        ENV_TYPE="PVE_HOST"
    elif cmd_exists systemd-detect-virt && [[ "$(systemd-detect-virt 2>/dev/null)" != "none" ]]; then
        ENV_TYPE="GUEST_VM"
    else
        warn "无法自动判定环境，请选择："
        read -rp "  请输入数字 [0=PVE宿主机, 1=虚拟机]: " ans
        [[ "$ans" == "0" ]] && ENV_TYPE="PVE_HOST" || ENV_TYPE="GUEST_VM"
    fi
    ok "环境类型: ${ENV_TYPE}"

    step "检测操作系统"
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || true)}"
    fi
    if [[ -z "$OS_ID" || -z "$OS_CODENAME" ]]; then
        warn "无法自动判定系统，请选择："
        read -rp "  请输入数字 [0=Debian, 1=Ubuntu]: " ans
        if [[ "$ans" == "0" ]]; then OS_ID="debian"; OS_CODENAME="$(lsb_release -sc 2>/dev/null || echo bookworm)"; else OS_ID="ubuntu"; OS_CODENAME="$(lsb_release -sc 2>/dev/null || echo noble)"; fi
    fi
    ok "操作系统: ${OS_ID} (${OS_CODENAME})"
}

# --- 获取 DKMS 最新发布信息 ---
fetch_latest_dkms_info() {
    step "获取 i915-sriov-dkms 最新发布信息"
    local api="https://api.github.com/repos/strongtz/i915-sriov-dkms/releases/latest"
    local headers=(-H "Accept: application/vnd.github+json")
    [[ -n "${GITHUB_TOKEN:-}" ]] && headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

    local json; json=$(curl -fsSL "${headers[@]}" "$api" || true)
    DKMS_PACKAGE_URL=$(echo "$json" | jq -r '.assets[]?.browser_download_url | select(test("amd64\\.deb$"))' | head -n1)

    if [[ -z "${DKMS_PACKAGE_URL}" ]]; then
        fail "自动获取 .deb 下载地址失败（可能是网络或 API 限制）。"
        read -rp "  请手动粘贴 .deb 文件下载链接: " DKMS_PACKAGE_URL
        [[ -z "${DKMS_PACKAGE_URL}" ]] && { fail "未提供链接，无法继续。"; exit 1; }
    fi
    DKMS_PACKAGE_NAME="$(basename "$DKMS_PACKAGE_URL")"
    ok "将使用 DKMS 包: ${DKMS_PACKAGE_NAME}"
}

# --- 自动解析 README/Release 的内核支持范围 ---
fetch_supported_kernel_range() {
    step "自动检测内核支持范围"
    local range=""
    local readme_url="https://raw.githubusercontent.com/strongtz/i915-sriov-dkms/master/README.md"

    local txt; txt=$(curl -fsSL "$readme_url" || true)
    range=$(echo "$txt" | sed -n -E 's/.*[Ll]inux[[:space:]]+([0-9]+\.[0-9]+)-([0-9]+\.[0-9]+).*/\1-\2/p' | head -n1)

    if [[ -z "$range" ]]; then
        warn "从 README 解析失败，尝试从最新 Release 标题解析..."
        local api="https://api.github.com/repos/strongtz/i915-sriov-dkms/releases/latest"
        local json; json=$(curl -fsSL "$api" || true)
        local title; title=$(echo "$json" | jq -r '.name // .tag_name // empty')
        range=$(echo "$title" | sed -n -E 's/.*([0-9]+\.[0-9]+)-([0-9]+\.[0-9]+).*/\1-\2/p' | head -n1)
    fi

    if [[ -z "$range" ]]; then
        warn "无法自动解析支持的内核范围。"
        read -rp "  请手动输入支持范围（例如 6.8-6.15）: " range
    fi

    SUPPORTED_KERNEL_MIN="${range%%-*}"
    SUPPORTED_KERNEL_MAX="${range##*-}"

    if [[ -z "$SUPPORTED_KERNEL_MIN" || -z "$SUPPORTED_KERNEL_MAX" ]]; then
        fail "解析内核支持范围失败，请检查输入或上游项目页面后重试。"; exit 1
    fi
    ok "解析到内核支持范围: ${SUPPORTED_KERNEL_MIN} - ${SUPPORTED_KERNEL_MAX}"
}

# --- 收集当前内核信息 ---
collect_kernel_info() {
    step "收集当前内核信息"
    CURRENT_KERNEL="$(uname -r)"
    CURRENT_KMM="$(uname -r | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
    ok "当前运行内核: ${CURRENT_KERNEL} (主次版本: ${CURRENT_KMM})"
}

# --- 确保当前内核头文件已安装 ---
ensure_headers_for_running_kernel() {
    step "检查并安装当前内核的头文件"
    local candidates=(
        "linux-headers-${CURRENT_KERNEL}"
        "pve-headers-${CURRENT_KERNEL}"
        "linux-headers-$(echo "${CURRENT_KERNEL}" | sed 's/-pve//')"
        "proxmox-headers-${CURRENT_KMM}"
    )
    if [[ "$OS_ID" == "debian" ]]; then
        candidates+=("linux-headers-amd64")
    else
        candidates+=("linux-headers-generic")
    fi

    for pkg in "${candidates[@]}"; do
        if pkg_installed "$pkg"; then ok "头文件包已安装: $pkg"; return 0; fi
        if pkg_exists "$pkg"; then
            warn "准备安装头文件包: $pkg"
            apt_install "$pkg"
            ok "头文件安装完成: $pkg"
            return 0
        fi
    done
    warn "未能找到与当前内核完全匹配的头文件包，DKMS 构建可能失败。"
}

# --- PVE：在支持范围内选择合适的内核元包 ---
select_pve_kernel_meta_in_range() {
    local min="$1" max="$2"
    step "为 PVE 搜索范围为 [${min}-${max}] 的内核元包"

    local names; names=$(apt-cache search --names-only '^(proxmox|pve)-kernel-[0-9]+\.[0-9]+$' 2>/dev/null | awk '{print $1}' || true)
    local versions; versions=$(echo "$names" | sed -E 's/.*-([0-9]+\.[0-9]+)$/\1/' | sort -V | uniq || true)

    local best=""
    for v in $versions; do
        if ver_in_range "$v" "$min" "$max"; then best="$v"; fi
    done
    if [[ -z "$best" ]]; then
        fail "未找到满足范围的 PVE 内核元包。请检查 PVE 源或手动安装。"
        exit 1
    fi
    
    local best_name="" best_hdr=""
    if echo "$names" | grep -q "proxmox-kernel-$best"; then
        best_name="proxmox-kernel-$best"; best_hdr="proxmox-headers-$best"
    else
        best_name="pve-kernel-$best";     best_hdr="pve-headers-$best"
    fi
    echo "${best_name}|${best_hdr}"
}

# --- 若不在范围则升级内核 ---
upgrade_kernel_if_needed() {
    step "检查当前内核版本是否在支持范围内"
    if ver_in_range "$CURRENT_KMM" "$SUPPORTED_KERNEL_MIN" "$SUPPORTED_KERNEL_MAX"; then
        ok "当前内核 ${CURRENT_KMM} 符合范围 [${SUPPORTED_KERNEL_MIN}-${SUPPORTED_KERNEL_MAX}]"
        return
    fi
    warn "当前内核 ${CURRENT_KMM} 不在支持范围 [${SUPPORTED_KERNEL_MIN}-${SUPPORTED_KERNEL_MAX}]"
    read -rp "  是否自动升级到支持范围内的内核？[y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then fail "用户取消内核升级，安装无法继续。"; exit 1; fi

    if [[ "$ENV_TYPE" == "PVE_HOST" ]]; then
        local pair; pair=$(select_pve_kernel_meta_in_range "$SUPPORTED_KERNEL_MIN" "$SUPPORTED_KERNEL_MAX")
        apt_install "${pair%|*}" "${pair#*|}"
    else # GUEST_VM
        if [[ "$OS_ID" == "debian" ]]; then
            local codename="${OS_CODENAME:-bookworm}"
            local backlist="/etc/apt/sources.list.d/${codename}-backports.list"
            backup_file "$backlist"
            echo "deb http://deb.debian.org/debian ${codename}-backports main contrib non-free-firmware" > "$backlist"
            DEBIAN_FRONTEND=noninteractive apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get -y -t "${codename}-backports" install linux-image-amd64 linux-headers-amd64 firmware-misc-nonfree
        else # ubuntu
            local series; series="$(lsb_release -rs 2>/dev/null || echo 24.04)"
            local hwe="linux-generic-hwe-${series}"
            local to_install=()
            if pkg_exists "$hwe"; then to_install+=("$hwe"); else to_install+=("linux-generic" "linux-headers-generic"); fi
            local extra_pkg="linux-modules-extra-${CURRENT_KERNEL}"
            if pkg_exists "$extra_pkg"; then to_install+=("$extra_pkg"); fi
            apt_install "${to_install[@]}"
        fi
    fi
    warn "内核已升级，必须重启系统后再次运行本脚本才能继续。"
    exit 0
}

# --- 【已重写】可选：清理旧内核 ---
cleanup_old_kernels() {
    step "检查是否需要清理旧内核"
    # 只查找带明确版本号的内核镜像包
    mapfile -t installed_kernel_images < <(dpkg-query -W -f='${Package}\n' 'linux-image-*' 'pve-kernel-*' 'proxmox-kernel-*' 2>/dev/null | grep -E '[0-9]+\.[0-9]+\.[0-9]+' || true)
    if [[ ${#installed_kernel_images[@]} -lt 2 ]]; then
        ok "无需清理（已安装的明确版本内核数量 < 2）。"
        return
    fi

    read -rp "  是否执行“仅保留当前运行内核（可选再保留最近一个）”的清理？[y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { warn "跳过内核清理。"; return 0; }

    read -rp "  是否保留一个最近的旧内核作为回退？[y/N]: " keep_old

    # 确定要保留的内核版本字符串
    local running_version; running_version="$(uname -r)"
    local keep_versions=("$running_version")

    if [[ "$keep_old" =~ ^[Yy]$ ]]; then
        local latest_old_image
        latest_old_image=$(printf "%s\n" "${installed_kernel_images[@]}" | grep -v "$running_version" | sort -V | tail -n 1)
        if [[ -n "$latest_old_image" ]]; then
            local old_version; old_version=$(echo "$latest_old_image" | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*')
            keep_versions+=("$old_version")
        fi
    fi
    
    local to_remove=()
    # 查找所有带明确版本号的内核相关包（包括头文件）
    mapfile -t all_related_packages < <(dpkg-query -W -f='${Package}\n' 'linux-image-*' 'linux-headers-*' 'pve-kernel-*' 'proxmox-kernel-*' 'pve-headers-*' 'proxmox-headers-*' 2>/dev/null | grep -E '[0-9]+\.[0-9]+\.[0-9]+' || true)
    
    for pkg in "${all_related_packages[@]}"; do
        local should_keep=0
        for ver in "${keep_versions[@]}"; do
            if [[ "$pkg" == *"$ver"* ]]; then
                should_keep=1
                break
            fi
        done
        (( should_keep == 0 )) && to_remove+=("$pkg")
    done

    # 单独处理没用的 32位 pae 头文件
    if pkg_installed "linux-headers-686-pae"; then
        to_remove+=("linux-headers-686-pae")
    fi

    if [[ ${#to_remove[@]} -eq 0 ]]; then
        ok "未发现可清理的旧内核包。"
        return
    fi

    warn "将要移除以下内核相关包（不含保留项）:"
    printf '    - %s\n' "${to_remove[@]}"
    read -rp "  确认删除？[y/N]: " go
    if [[ "$go" =~ ^[Yy]$ ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${to_remove[@]}"
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
        ok "旧内核清理完成。"
    else
        warn "取消清理旧内核。"
    fi
}


# --- 配置内核/模块参数 ---
configure_kernel_params() {
    step "配置内核与模块参数"
    local grub_file="/etc/default/grub"
    backup_file "$grub_file"

    if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file"; then
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' >> "$grub_file"
    fi
    local cmdline; cmdline=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | cut -d'"' -f2)

    for param in "intel_iommu=on" "iommu=pt"; do
        [[ " $cmdline " =~ " $param " ]] || cmdline="$cmdline $param"
    done
    cmdline=$(echo "$cmdline" | xargs)

    sed -i -E 's|^(GRUB_CMDLINE_LINUX_DEFAULT=").*"|\1'"$cmdline"'"|' "$grub_file"
    ok "已在 GRUB 设置: $cmdline"

    local modconf="/etc/modprobe.d/i915-sriov-dkms.conf"
    backup_file "$modconf"
    : > "$modconf" # 清空文件

    read -rp "  是否添加 xe 黑名单（推荐）？[Y/n]: " bxe
    if [[ ! "$bxe" =~ ^[Nn]$ ]]; then
        echo "blacklist xe" >> "$modconf"
        ok "已添加 xe 黑名单"
    fi

    read -rp "  是否设置 i915.enable_guc=3（推荐）？[Y/n]: " eg
    if [[ ! "$eg" =~ ^[Nn]$ ]]; then
        echo "options i915 enable_guc=3" >> "$modconf"
        ok "已设置: options i915 enable_guc=3"
    fi

    if [[ "$ENV_TYPE" == "PVE_HOST" ]]; then
        read -rp "  [宿主机] 是否设置 i915.max_vfs 以启用 SR-IOV？[y/N]: " mv
        if [[ "$mv" =~ ^[Yy]$ ]]; then
            read -rp "    请输入要创建的 VF 数量 (1-7，或实际硬件上限): " vf_count
            if [[ "$vf_count" =~ ^[1-9][0-9]*$ ]]; then
                echo "options i915 max_vfs=${vf_count}" >> "$modconf"
                ok "已设置: options i915 max_vfs=${vf_count}"
            else
                warn "输入无效，跳过 max_vfs 设置。"
            fi
        fi
    fi

    if cmd_exists update-grub; then update-grub; else grub-mkconfig -o /boot/grub/grub.cfg; fi
    if cmd_exists update-initramfs; then update-initramfs -u; fi
    if cmd_exists proxmox-boot-tool; then proxmox-boot-tool refresh; fi
    ok "引导与 initramfs 已更新。"
}

# --- 下载并安装 DKMS 包 ---
install_dkms_package() {
    step "安装 DKMS 包"
    ensure_headers_for_running_kernel

    local tmp_pkg="/tmp/${DKMS_PACKAGE_NAME}"
    warn "正在下载 DKMS 包..."
    curl -fSL "$DKMS_PACKAGE_URL" -o "$tmp_pkg"

    warn "正在安装 DKMS 包（若提示依赖问题会自动修复）..."
    dpkg -i "$tmp_pkg" || DEBIAN_FRONTEND=noninteractive apt-get -f install -y

    ok "DKMS 包安装完成。"
    dkms status
}

# --- 宿主机：VF 创建与持久化 ---
configure_vf() {
    [[ "$ENV_TYPE" == "PVE_HOST" ]] || return 0
    step "创建 SR-IOV VF（可选）"

    local devdir="/sys/class/drm/card0/device"
    if [[ ! -d "$devdir" || ! -f "$devdir/sriov_totalvfs" ]]; then
        warn "未在默认路径 ${devdir} 发现 SR-IOV 接口。"
        read -rp "  请手动输入 iGPU 的 PCI 地址（如 0000:00:02.0，留空跳过）: " pci_addr
        [[ -z "$pci_addr" ]] && { warn "跳过 VF 创建。"; return 0; }
        devdir="/sys/bus/pci/devices/$pci_addr"
        if [[ ! -d "$devdir" ]]; then fail "提供的路径无效，跳过 VF 创建。"; return 0; fi
    fi

    local total=0
    [[ -f "$devdir/sriov_totalvfs" ]] && total=$(cat "$devdir/sriov_totalvfs")
    if [[ "$total" -le 0 ]]; then
        warn "该设备报告不支持 SR-IOV（totalvfs=$total），跳过。"
        return 0
    fi
    ok "设备最大 VF 数量：$total"

    read -rp "  请输入要创建的 VF 数量（1-$total，回车跳过）: " n
    [[ -z "$n" ]] && { warn "跳过 VF 创建。"; return 0; }
    if ! [[ "$n" -ge 1 && "$n" -le "$total" ]]; then
        warn "输入无效，跳过 VF 创建。"; return 0
    fi
    
    echo 0 > "$devdir/sriov_numvfs"
    echo "$n" > "$devdir/sriov_numvfs"
    ok "已临时创建 $n 个 VF。"

    read -rp "  是否将 VF 创建持久化，以便开机自动生效？[y/N]: " p
    [[ "$p" =~ ^[Yy]$ ]] || { warn "跳过持久化。"; return 0; }

    echo "  请选择持久化方式："
    echo "    1) sysfsutils (传统，写入 /etc/sysfs.conf)"
    echo "    2) systemd 服务 (推荐，创建 i915-sriov-vf.service)"
    read -rp "  请输入数字 [1/2]（默认 2）： " m
    m="${m:-2}"

    if [[ "$m" == "1" ]]; then
        local sysfs_file="/etc/sysfs.conf"
        backup_file "$sysfs_file"
        apt_install sysfsutils
        local rel_path; rel_path=$(realpath --relative-to=/sys "$devdir")
        sed -i '\|sriov_numvfs|d' "$sysfs_file"
        echo "${rel_path}/sriov_numvfs = ${n}" >> "$sysfs_file"
        ok "已写入 $sysfs_file"
    else
        local svc_file="/etc/systemd/system/i915-sriov-vf.service"
        backup_file "$svc_file"
        cat > "$svc_file" <<EOF
[Unit]
Description=Configure i915 SR-IOV VFs
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0 > ${devdir}/sriov_numvfs; echo ${n} > ${devdir}/sriov_numvfs'

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable i915-sriov-vf.service
        ok "已启用持久化服务 i915-sriov-vf.service"
    fi
}

# --- 主流程 ---
main() {
    echo -e "${C_BLUE}======================================================${C_RESET}"
    echo -e "${C_BLUE}  Intel i915 SR-IOV 驱动一键安装脚本 v${SCRIPT_VERSION}${C_RESET}"
    echo -e "${C_BLUE}  GitHub: https://github.com/iHub-2020/PVE_Utilities${C_RESET}"
    echo -e "${C_BLUE}======================================================${C_RESET}"

    require_root
    
    check_dependencies
    detect_environment
    fetch_latest_dkms_info
    fetch_supported_kernel_range
    collect_kernel_info

    upgrade_kernel_if_needed
    cleanup_old_kernels
    configure_kernel_params
    install_dkms_package
    configure_vf

    ok "所有配置步骤执行完毕。"
    warn "强烈建议现在重启系统，以确保所有更改（内核、参数、模块、VF）完全生效。"
    trap - ERR INT TERM
}

main "$@"
