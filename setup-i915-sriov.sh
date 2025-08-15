#!/bin/bash

# ===================================================================================
#
# Script Name: setup-i915-sriov.sh
# Description: 一键在 PVE 宿主机或其 Linux 虚拟机中安装 Intel i915 SR-IOV 驱动。
# Author: Generated for iHub-2020
# Version: 1.0
# GitHub: https://github.com/iHub-2020/PVE_Utilities
#
# ===================================================================================

# --- 全局变量与常量 ---
readonly SCRIPT_VERSION="1.0"
readonly SUPPORTED_KERNEL_MIN="6.8"
readonly SUPPORTED_KERNEL_MAX="6.15"
readonly DKMS_PACKAGE_URL="https://github.com/strongtz/i915-sriov-dkms/releases/download/2025.07.22/i915-sriov-dkms_2025.07.22_amd64.deb"
readonly DKMS_PACKAGE_NAME="i915-sriov-dkms_2025.07.22_amd64.deb"

# --- 颜色定义 ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'

# --- 工具函数 ---
print_msg() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${C_RESET}"
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        print_msg "$C_RED" "错误：本脚本需要以 root 权限运行。请使用 'sudo ./setup-i915-sriov.sh'。正在退出..."
        exit 1
    fi
}

# --- 备份与回滚机制 ---
BACKUP_DIR="/tmp/sriov_setup_backup_$(date +%Y%m%d_%H%M%S)"
CONFIG_FILES_TO_BACKUP=()

setup_backup_and_trap() {
    mkdir -p "$BACKUP_DIR"
    print_msg "$C_BLUE" "配置文件备份目录已创建于: ${BACKUP_DIR}"
    # 设置错误陷阱
    trap 'error_handler $? $LINENO' ERR
}

backup_file() {
    local file_path=$1
    if [[ -f "$file_path" && ! " ${CONFIG_FILES_TO_BACKUP[@]} " =~ " ${file_path} " ]]; then
        print_msg "$C_BLUE" "正在备份 ${file_path} 到 ${BACKUP_DIR}/"
        cp -p "$file_path" "$BACKUP_DIR/"
        CONFIG_FILES_TO_BACKUP+=("$file_path")
    fi
}

restore_from_backup() {
    print_msg "$C_YELLOW" "检测到错误，正在尝试从备份中恢复配置文件..."
    if [[ ${#CONFIG_FILES_TO_BACKUP[@]} -eq 0 ]]; then
        print_msg "$C_YELLOW" "没有配置文件被修改，无需恢复。"
        return
    fi

    for file_path in "${CONFIG_FILES_TO_BACKUP[@]}"; do
        local backup_file_path="${BACKUP_DIR}/$(basename "$file_path")"
        if [[ -f "$backup_file_path" ]]; then
            print_msg "$C_YELLOW" "正在恢复 ${file_path}..."
            cp -p "$backup_file_path" "$file_path"
        fi
    done
    print_msg "$C_GREEN" "配置文件恢复完成。"
}

error_handler() {
    local exit_code=$1
    local line_number=$2
    print_msg "$C_RED" "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    print_msg "$C_RED" "!!  脚本在第 ${line_number} 行发生错误，退出码: ${exit_code}"
    print_msg "$C_RED" "!!  正在执行自动回滚..."
    print_msg "$C_RED" "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    restore_from_backup
    print_msg "$C_RED" "回滚已执行。请检查上述错误信息。"
    print_msg "$C_RED" "注意：已安装的软件包无法自动卸载，可能需要手动清理。"
    exit "$exit_code"
}

# --- 核心逻辑函数 ---

detect_environment() {
    print_msg "$C_BLUE" "正在检测运行环境..."
    # 1. 检测宿主机/虚拟机
    if command -v pveversion &> /dev/null; then
        ENV_TYPE="PVE_HOST"
        print_msg "$C_GREEN" "检测到 PVE 宿主机环境。"
    else
        ENV_TYPE="GUEST_VM"
        print_msg "$C_GREEN" "检测到虚拟机环境。"
    fi

    # 2. 检测发行版
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID=$ID
        print_msg "$C_GREEN" "检测到操作系统: ${OS_ID}"
    else
        print_msg "$C_RED" "无法识别操作系统。正在退出。"
        exit 1
    fi
}

check_and_manage_kernel() {
    print_msg "$C_BLUE" "--- 步骤 1: 内核版本检查与管理 ---"
    CURRENT_KERNEL=$(uname -r)
    KERNEL_MAJOR_MINOR=$(echo "$CURRENT_KERNEL" | awk -F'.' '{print $1"."$2}')

    print_msg "$C_BLUE" "当前运行内核: ${CURRENT_KERNEL}"
    
    # 使用 bc 进行浮点数比较
    if (( $(echo "$KERNEL_MAJOR_MINOR >= $SUPPORTED_KERNEL_MIN" | bc -l) )) && (( $(echo "$KERNEL_MAJOR_MINOR <= $SUPPORTED_KERNEL_MAX" | bc -l) )); then
        print_msg "$C_GREEN" "内核版本 ${KERNEL_MAJOR_MINOR} 符合要求 (${SUPPORTED_KERNEL_MIN} - ${SUPPORTED_KERNEL_MAX})。"
    else
        print_msg "$C_YELLOW" "内核版本 ${KERNEL_MAJOR_MINOR} 不在支持范围，需要升级。"
        read -p "是否要自动升级内核? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            upgrade_kernel
        else
            print_msg "$C_RED" "用户取消内核升级。脚本无法继续。正在退出。"
            exit 1
        fi
    fi
    
    cleanup_old_kernels
}

upgrade_kernel() {
    print_msg "$C_BLUE" "正在升级内核..."
    apt update
    if [[ "$ENV_TYPE" == "PVE_HOST" ]]; then
        print_msg "$C_BLUE" "为 PVE 宿主机安装 6.8 系列内核..."
        apt install -y proxmox-kernel-6.8 proxmox-headers-6.8
    elif [[ "$OS_ID" == "debian" ]]; then
        print_msg "$C_BLUE" "为 Debian 客户机从 backports 安装新内核..."
        backup_file "/etc/apt/sources.list"
        # 使用独立的 backports.list 文件，更规范
        echo "deb http://deb.debian.org/debian bookworm-backports main contrib non-free-firmware" > /etc/apt/sources.list.d/backports.list
        apt update
        apt -t bookworm-backports install -y linux-image-amd64 linux-headers-amd64 firmware-misc-nonfree
    elif [[ "$OS_ID" == "ubuntu" ]]; then
        print_msg "$C_BLUE" "为 Ubuntu 客户机安装 HWE 内核..."
        apt install -y linux-generic-hwe-24.04 # 假定为 24.04 HWE
    fi
    print_msg "$C_YELLOW" "内核已升级。需要重启系统以应用新内核。请在重启后重新运行此脚本。"
    exit 0
}

cleanup_old_kernels() {
    mapfile -t INSTALLED_KERNELS < <(dpkg -l | grep -E 'pve-kernel|proxmox-kernel|linux-image' | grep -v 'tools\|common' | awk '{print $2}')
    
    # 至少保留2个内核，更安全
    if [[ ${#INSTALLED_KERNELS[@]} -le 2 ]]; then
        print_msg "$C_GREEN" "已安装内核数量不多于2个，跳过清理。"
        return
    fi

    print_msg "$C_YELLOW" "检测到多个内核版本。清理旧内核可以减少维护成本。"
    read -p "是否要检查并清理旧内核? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_msg "$C_BLUE" "用户跳过内核清理。"
        return
    fi
    
    print_msg "$C_BLUE" "正在查找可清理的旧内核..."
    KERNELS_TO_PURGE=()
    for kernel in "${INSTALLED_KERNELS[@]}"; do
        if [[ "$kernel" != *"$CURRENT_KERNEL"* ]]; then
            # 简单逻辑：只要不是当前运行的，就加入待清理列表
            # 更复杂的逻辑可以保留最新的一个非当前内核
            KERNELS_TO_PURGE+=("$kernel")
            # 也要清理对应的头文件
            HEADERS_PKG=$(echo "$kernel" | sed 's/image/headers/' | sed 's/pve-kernel/pve-headers/' | sed 's/proxmox-kernel/proxmox-headers/')
            if dpkg -l | grep -q "$HEADERS_PKG"; then
               KERNELS_TO_PURGE+=("$HEADERS_PKG")
            fi
        fi
    done
    
    # 移除当前内核，确保不会被删除
    KERNELS_TO_PURGE=( "${KERNELS_TO_PURGE[@]/$CURRENT_KERNEL/}" )

    if [[ ${#KERNELS_TO_PURGE[@]} -eq 0 ]]; then
        print_msg "$C_GREEN" "没有找到可安全清理的旧内核。"
        return
    fi

    print_msg "$C_YELLOW" "以下软件包将被清理:"
    for pkg in "${KERNELS_TO_PURGE[@]}"; do
        echo " - $pkg"
    done
    
    read -p "确认要清理这些软件包吗? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        apt purge -y "${KERNELS_TO_PURGE[@]}"
        apt autoremove --purge -y
        print_msg "$C_GREEN" "旧内核清理完成。"
        # 刷新引导
        if command -v proxmox-boot-tool &> /dev/null; then
            proxmox-boot-tool refresh
        else
            update-grub
        fi
    else
        print_msg "$C_BLUE" "用户取消清理操作。"
    fi
}


configure_kernel_params() {
    print_msg "$C_BLUE" "--- 步骤 2: 配置内核参数 ---"
    
    local params="intel_iommu=on i915.enable_guc=3 module_blacklist=xe"
    if [[ "$ENV_TYPE" == "PVE_HOST" ]]; then
        params+=" i915.max_vfs=7" # 主机需要额外设置VF数量
    fi

    print_msg "$C_BLUE" "将要添加的参数: ${params}"

    if command -v proxmox-boot-tool &> /dev/null; then
        # PVE 8+ with systemd-boot
        local cmdline_file="/etc/kernel/cmdline"
        print_msg "$C_BLUE" "检测到 systemd-boot，正在配置 ${cmdline_file}..."
        backup_file "$cmdline_file"
        
        local current_cmdline
        current_cmdline=$(cat "$cmdline_file")
        # 移除旧参数，再添加新参数，避免重复
        current_cmdline=$(echo "$current_cmdline" | sed -e 's/intel_iommu=[^ ]*//g' -e 's/i915.enable_guc=[^ ]*//g' -e 's/i915.max_vfs=[^ ]*//g' -e 's/module_blacklist=[^ ]*//g')
        echo "${current_cmdline} ${params}" | tr -s ' ' > "$cmdline_file"
        
        proxmox-boot-tool refresh
    else
        # GRUB
        local grub_file="/etc/default/grub"
        print_msg "$C_BLUE" "检测到 GRUB，正在配置 ${grub_file}..."
        backup_file "$grub_file"
        
        local current_cmdline
        current_cmdline=$(grep "GRUB_CMDLINE_LINUX_DEFAULT" "$grub_file")
        # 同样，先移除旧的
        current_cmdline=$(echo "$current_cmdline" | sed -e 's/intel_iommu=[^ "]*//g' -e 's/i915.enable_guc=[^ "]*//g' -e 's/i915.max_vfs=[^ "]*//g' -e 's/module_blacklist=[^ "]*//g')
        # 重新拼接
        local new_cmdline
        new_cmdline=$(echo "$current_cmdline" | sed "s/\"\(.*\)\"/\"\1 ${params}\"/")
        # 去掉多余空格
        new_cmdline=$(echo "$new_cmdline" | tr -s ' ')
        
        sed -i "/GRUB_CMDLINE_LINUX_DEFAULT/c\\${new_cmdline}" "$grub_file"
        update-grub
    fi
    
    print_msg "$C_GREEN" "内核参数配置完成。"
    update-initramfs -u
}

install_dependencies_and_dkms() {
    print_msg "$C_BLUE" "--- 步骤 3: 安装依赖并部署 DKMS 模块 ---"
    
    print_msg "$C_BLUE" "正在安装构建工具和依赖..."
    apt update
    apt install -y build-essential dkms
    if [[ "$OS_ID" == "ubuntu" ]]; then
        # Ubuntu 特有的包
        apt install -y "linux-modules-extra-$(uname -r)"
    elif [[ "$OS_ID" == "debian" ]]; then
        apt install -y "linux-headers-$(uname -r)" firmware-misc-nonfree
    fi

    print_msg "$C_BLUE" "正在下载 SR-IOV DKMS 模块..."
    wget -O "/tmp/${DKMS_PACKAGE_NAME}" "$DKMS_PACKAGE_URL"
    
    print_msg "$C_BLUE" "正在安装 DKMS 模块..."
    dpkg -i "/tmp/${DKMS_PACKAGE_NAME}"
    
    print_msg "$C_GREEN" "DKMS 模块安装完成。"
    dkms status
}

configure_vf() {
    if [[ "$ENV_TYPE" != "PVE_HOST" ]]; then
        return
    fi
    
    print_msg "$C_BLUE" "--- 步骤 4: 创建 SR-IOV 虚拟功能 (VF) ---"
    local vf_count
    while true; do
        read -p "请输入要创建的 VF 数量 (1-7，推荐从 1 或 2 开始): " vf_count
        if [[ "$vf_count" =~ ^[1-7]$ ]]; then
            break
        else
            print_msg "$C_RED" "输入无效，请输入 1 到 7 之间的数字。"
        fi
    done
    
    local igpu_pci_addr
    igpu_pci_addr=$(lspci -nn | grep -E 'VGA|Display' | grep -i 'intel' | awk '{print $1}')
    if [[ -z "$igpu_pci_addr" ]]; then
        print_msg "$C_RED" "错误：未找到 Intel 核显的 PCI 地址。"
        exit 1
    fi
    print_msg "$C_BLUE" "检测到核显 PCI 地址为: ${igpu_pci_addr}"
    
    print_msg "$C_BLUE" "正在配置开机自动创建 ${vf_count} 个 VF..."
    apt install -y sysfsutils
    local sysfs_file="/etc/sysfs.conf"
    backup_file "$sysfs_file"
    # 移除旧配置，防止重复
    sed -i '/sriov_numvfs/d' "$sysfs_file"
    echo "devices/pci0000:00/${igpu_pci_addr}/sriov_numvfs = ${vf_count}" >> "$sysfs_file"
    
    print_msg "$C_GREEN" "VF 自动创建配置完成。"
}

# --- 主函数 ---
main() {
    # 欢迎语
    print_msg "$C_BLUE" "======================================================"
    print_msg "$C_BLUE" "  Intel i915 SR-IOV 驱动一键安装脚本 v${SCRIPT_VERSION}"
    print_msg "$C_BLUE" "  适用于 PVE 宿主机与 Linux 虚拟机"
    print_msg "$C_BLUE" "  GitHub: https://github.com/iHub-2020/PVE_Utilities"
    print_msg "$C_BLUE" "======================================================"
    
    check_root
    setup_backup_and_trap
    
    # 核心流程
    detect_environment
    check_and_manage_kernel
    configure_kernel_params
    install_dependencies_and_dkms
    configure_vf
    
    # 结束语
    print_msg "$C_GREEN" "=========================================================================="
    print_msg "$C_GREEN" "  恭喜！所有配置步骤已成功完成！"
    print_msg "$C_YELLOW" "  重要：请务必重启系统以应用所有更改 (内核、模块、参数)。"
    if [[ "$ENV_TYPE" == "PVE_HOST" ]]; then
        print_msg "$C_YELLOW" "  重启后，请使用 'lspci -nnk | grep -A3 VGA' 检查 VF 是否已创建。"
    else
        print_msg "$C_YELLOW" "  重启后，请在 PVE 中将 VF 直通给此虚拟机，并关闭虚拟显卡。"
    fi
    print_msg "$C_GREEN" "=========================================================================="
    
    # 清理
    rm -f "/tmp/${DKMS_PACKAGE_NAME}"
    read -p "是否要删除备份目录 ${BACKUP_DIR}? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$BACKUP_DIR"
        print_msg "$C_BLUE" "备份目录已删除。"
    fi
    
    # 解除陷阱
    trap - ERR
}

# --- 脚本入口 ---
main "$@"
