#!/bin/bash

# ===================================================================================
#
# Script Name: setup-i915-sriov.sh
# Description: 一键在 PVE 宿主机或其 Linux 虚拟机中安装 Intel i915 SR-IOV 驱动。
# Author: Generated for iHub-2020
# Version: 1.2 (增加动态获取内核支持范围功能)
# GitHub: https://github.com/iHub-2020/PVE_Utilities
#
# ===================================================================================

# --- 全局变量与常量 ---
readonly SCRIPT_VERSION="1.2"
# 下面这些变量将由函数动态填充
DKMS_PACKAGE_URL=""
DKMS_PACKAGE_NAME=""
SUPPORTED_KERNEL_MIN=""
SUPPORTED_KERNEL_MAX=""

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

check_dependencies() {
    local missing_deps=()
    for dep in curl bc; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_msg "$C_YELLOW" "检测到以下核心依赖未安装: ${missing_deps[*]}"
        read -p "是否要现在安装它们? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            apt update && apt install -y "${missing_deps[@]}"
        else
            print_msg "$C_RED" "用户取消安装依赖。脚本无法继续。正在退出。"
            exit 1
        fi
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

fetch_latest_dkms_info() {
    print_msg "$C_BLUE" "--- 步骤 0a: 获取最新的 DKMS 模块版本 ---"
    
    print_msg "$C_BLUE" "正在通过 GitHub API 查询最新版本..."
    local api_url="https://api.github.com/repos/strongtz/i915-sriov-dkms/releases/latest"
    local response
    response=$(curl -s "$api_url")

    DKMS_PACKAGE_URL=$(echo "$response" | grep '"browser_download_url":' | grep 'amd64.deb' | sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/')
    
    if [[ -z "$DKMS_PACKAGE_URL" ]]; then
        print_msg "$C_RED" "错误：无法从 GitHub API 获取最新的 .deb 下载链接。"
        print_msg "$C_YELLOW" "这可能是网络问题，或 GitHub API 速率限制。请稍后重试。"
        exit 1
    fi
    
    DKMS_PACKAGE_NAME=$(basename "$DKMS_PACKAGE_URL")
    
    print_msg "$C_GREEN" "成功获取最新版本信息:"
    print_msg "$C_GREEN" "  - 包名: ${DKMS_PACKAGE_NAME}"
}

# #################################################
#  新增功能：动态获取内核支持范围
# #################################################
fetch_supported_kernel_range() {
    print_msg "$C_BLUE" "--- 步骤 0b: 自动检测内核支持范围 ---"
    local readme_url="https://raw.githubusercontent.com/strongtz/i915-sriov-dkms/master/README.md"
    print_msg "$C_BLUE" "正在从项目的 README 文件中解析版本要求..."
    
    local version_line
    version_line=$(curl -s "$readme_url" | grep 'SR-IOV support for linux')
    
    if [[ -z "$version_line" ]]; then
        print_msg "$C_RED" "错误：无法在 README 中找到内核版本信息行。"
        print_msg "$C_YELLOW" "可能是项目描述已更改。脚本需要更新。"
        exit 1
    fi
    
    # 使用 sed 和正则表达式提取版本范围，例如 "6.8-6.15"
    local version_range
    version_range=$(echo "$version_line" | sed -n 's/.*linux \([0-9.]\+-[0-9.]\+\).*/\1/p')

    if [[ -z "$version_range" ]]; then
        print_msg "$C_RED" "错误：无法从描述中解析出 'X.Y-Z.W' 格式的版本范围。"
        exit 1
    fi
    
    SUPPORTED_KERNEL_MIN=$(echo "$version_range" | cut -d'-' -f1)
    SUPPORTED_KERNEL_MAX=$(echo "$version_range" | cut -d'-' -f2)

    if [[ -z "$SUPPORTED_KERNEL_MIN" || -z "$SUPPORTED_KERNEL_MAX" ]]; then
        print_msg "$C_RED" "错误：解析出的内核版本为空。"
        exit 1
    fi

    print_msg "$C_GREEN" "成功解析到内核支持范围: ${SUPPORTED_KERNEL_MIN} - ${SUPPORTED_KERNEL_MAX}"
}


detect_environment() {
    print_msg "$C_BLUE" "正在检测运行环境..."
    if command -v pveversion &> /dev/null; then
        ENV_TYPE="PVE_HOST"
        print_msg "$C_GREEN" "检测到 PVE 宿主机环境。"
    else
        ENV_TYPE="GUEST_VM"
        print_msg "$C_GREEN" "检测到虚拟机环境。"
    fi

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
    
    if (( $(echo "$KERNEL_MAJOR_MINOR >= $SUPPORTED_KERNEL_MIN" | bc -l) )) && (( $(echo "$KERNEL_MAJOR_MINOR <= $SUPPORTED_KERNEL_MAX" | bc -l) )); then
        print_msg "$C_GREEN" "内核版本 ${KERNEL_MAJOR_MINOR} 符合要求 (${SUPPORTED_KERNEL_MIN} - ${SUPPORTED_KERNEL_MAX})。"
    else
        print_msg "$C_YELLOW" "内核版本 ${KERNEL_MAJOR_MINOR} 不在支持范围 (${SUPPORTED_KERNEL_MIN} - ${SUPPORTED_KERNEL_MAX})，需要升级。"
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
        # 这里的 6.8 是基于当前已知情况，未来可能需要更智能的判断
        print_msg "$C_BLUE" "为 PVE 宿主机安装 ${SUPPORTED_KERNEL_MIN} 系列内核..."
        apt install -y "proxmox-kernel-${SUPPORTED_KERNEL_MIN}" "proxmox-headers-${SUPPORTED_KERNEL_MIN}"
    elif [[ "$OS_ID" == "debian" ]];
        print_msg "$C_BLUE" "为 Debian 客户机从 backports 安装新内核..."
        backup_file "/etc/apt/sources.list"
        echo "deb http://deb.debian.org/debian bookworm-backports main contrib non-free-firmware" > /etc/apt/sources.list.d/backports.list
        apt update
        apt -t bookworm-backports install -y linux-image-amd64 linux-headers-amd64 firmware-misc-nonfree
    elif [[ "$OS_ID" == "ubuntu" ]]; then
        print_msg "$C_BLUE" "为 Ubuntu 客户机安装 HWE 内核..."
        apt install -y linux-generic-hwe-24.04
    fi
    print_msg "$C_YELLOW" "内核已升级。需要重启系统以应用新内核。请在重启后重新运行此脚本。"
    exit 0
}

cleanup_old_kernels() {
    # 此函数逻辑不变
    mapfile -t INSTALLED_KERNELS < <(dpkg -l | grep -E 'pve-kernel|proxmox-kernel|linux-image' | grep -v 'tools\|common' | awk '{print $2}')
    if [[ ${#INSTALLED_KERNELS[@]} -le 2 ]]; then return; fi
    print_msg "$C_YELLOW" "检测到多个内核版本。是否要检查并清理旧内核? (y/N)"
    read -p "" -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then return; fi
    
    # ... (省略与上一版相同的清理逻辑)
}

configure_kernel_params() {
    # 此函数逻辑不变
    print_msg "$C_BLUE" "--- 步骤 2: 配置内核参数 ---"
    # ... (省略与上一版相同的参数配置逻辑)
}

install_dependencies_and_dkms() {
    # 此函数逻辑不变
    print_msg "$C_BLUE" "--- 步骤 3: 安装依赖并部署 DKMS 模块 ---"
    # ... (省略与上一版相同的安装逻辑)
}

configure_vf() {
    # 此函数逻辑不变
    if [[ "$ENV_TYPE" != "PVE_HOST" ]]; then return; fi
    print_msg "$C_BLUE" "--- 步骤 4: 创建 SR-IOV 虚拟功能 (VF) ---"
    # ... (省略与上一版相同的VF配置逻辑)
}


# --- 主函数 ---
main() {
    print_msg "$C_BLUE" "======================================================"
    print_msg "$C_BLUE" "  Intel i915 SR-IOV 驱动一键安装脚本 v${SCRIPT_VERSION}"
    print_msg "$C_BLUE" "  GitHub: https://github.com/iHub-2020/PVE_Utilities"
    print_msg "$C_BLUE" "======================================================"
    
    check_root
    check_dependencies
    setup_backup_and_trap
    
    # 核心流程进化！
    fetch_latest_dkms_info
    fetch_supported_kernel_range
    detect_environment
    check_and_manage_kernel
    configure_kernel_params
    install_dependencies_and_dkms
    configure_vf
    
    # 结束语
    print_msg "$C_GREEN" "=========================================================================="
    print_msg "$C_GREEN" "  恭喜！所有配置步骤已成功完成！"
    print_msg "$C_YELLOW" "  重要：请务必重启系统以应用所有更改。"
    print_msg "$C_GREEN" "=========================================================================="
    
    # ... (省略与上一版相同的清理逻辑)
    trap - ERR
}

# --- 脚本入口 ---
main "$@"
