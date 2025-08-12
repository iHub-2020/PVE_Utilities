#!/usr/bin/env bash

# ==============================================================================
# PVE Web UI Enhancement Script
#
# Author: Reyanmatic
# Version: 2.2 (Fixed a critical sed syntax error for the 'r' command)
# Date: 2025-08-12
#
# Description:
# This script enhances the Proxmox VE web interface by adding real-time display
# for CPU temperature, frequency, power consumption, and detailed information
# for NVMe and SATA drives. It also removes the subscription nag screen.
#
# Features:
# - Automatically detects and displays data from hardware sensors.
# - Automatically detects and lists NVMe, SSD, and HDD information.
# - Dynamically adjusts the UI layout to fit new elements.
# - Includes robust backup and restore functionality.
# ==============================================================================

# --- 全局控制变量 ---
# 设置为 true 来显示NVMe硬盘信息，false 则不显示
sNVMEInfo=true
# 设置为 true 来显示SATA固态和机械硬盘信息，false 则不显示
sODisksInfo=true
# 调试模式，设置为 true 会输出更多过程信息，用于排查问题
dmode=false

# --- 脚本环境设置 ---
# 获取脚本所在的绝对路径
sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$sdir"

# 获取脚本文件名和完整路径
sname=$(basename "${BASH_SOURCE[0]}")
sap="$sdir/$sname"
echo "脚本执行路径：$sap"

# --- 定义需要修改的目标文件路径 ---
np=/usr/share/perl5/PVE/API2/Nodes.pm
pvejs=/usr/share/pve-manager/js/pvemanagerlib.js
plibjs=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

# --- 依赖检查与自动安装 ---
# 检查核心工具 lm-sensors 是否安装
if ! command -v sensors > /dev/null; then
    echo "检测到系统缺少 'lm-sensors'，这是显示温度所必需的。"
    echo "脚本将尝试为您自动安装..."
    if apt-get update && apt-get install -y lm-sensors; then
        echo "'lm-sensors' 安装成功！"
    else
        echo -e "\033[31m自动安装 'lm-sensors' 失败。\033[0m"
        echo -e "请尝试手动执行命令进行安装：\033[34mapt-get update && apt-get install -y lm-sensors\033[0m"
        echo "脚本退出。"
        exit 1
    fi
fi

# 检查功耗工具 turbostat (属于 linux-cpupower) 是否安装
if ! command -v turbostat > /dev/null; then
    echo "检测到系统缺少 'linux-cpupower'，这是显示CPU功耗所必需的。"
    echo "脚本将尝试为您自动安装..."
    if apt-get install -y linux-cpupower; then
        echo "'linux-cpupower' 安装成功！"
        # 为 turbostat 配置运行环境
        modprobe msr
        echo 'msr' > /etc/modules-load.d/turbostat-msr.conf
        chmod +s /usr/sbin/turbostat
    else
        echo -e "\033[31m自动安装 'linux-cpupower' 失败。\033[0m"
        echo -e "请尝试手动执行命令进行安装：\033[34mapt-get install -y linux-cpupower && modprobe msr && echo 'msr' > /etc/modules-load.d/turbostat-msr.conf && chmod +s /usr/sbin/turbostat\033[0m"
    fi
fi

# --- PVE版本获取与函数定义 ---
# 获取当前PVE版本号，用于备份文件名，避免不同版本间混淆
pvever=$(pveversion | awk -F'/' '{print $2}')
echo "检测到您的PVE版本为：$pvever"

# 定义还原函数，用于撤销所有文件修改
restore() {
    echo "正在还原文件..."
    [ -e "$np.$pvever.bak" ] && mv "$np.$pvever.bak" "$np"
    [ -e "$pvejs.$pvever.bak" ] && mv "$pvejs.$pvever.bak" "$pvejs"
    [ -e "$plibjs.$pvever.bak" ] && mv "$plibjs.$pvever.bak" "$plibjs"
    echo "还原操作完成。"
}

# 定义失败处理函数，在修改过程中出错时调用
fail() {
    echo -e "\033[31m修改失败！可能是脚本与您的PVE版本 ($pvever) 不兼容。\033[0m"
    restore
    exit 1
}

# --- 脚本执行参数处理 ---
case $1 in
restore)
    restore
    if [ "$2" != 'remod' ]; then
        echo "正在重启PVE Web服务以应用还原..."
        systemctl restart pveproxy
        echo -e "还原已完成。请按 \033[31mShift+F5\033[0m 强制刷新您的浏览器缓存。"
    else
        echo "----- 内部还原完成，准备重新修改 -----"
    fi
    exit 0
    ;;
remod)
    echo "检测到 'remod' 参数，将执行强制重新修改流程。"
    # 先静默执行一次还原，确保环境干净
    "$sap" restore remod >/dev/null
    # 接着执行默认的修改流程
    "$sap"
    exit 0
    ;;
esac

# --- 幂等性检查 ---
# 通过在三个文件中查找共同的标记，判断是否已经修改过
if [ "$(grep 'modbyshowtempfreq' "$np" "$pvejs" "$plibjs" 2>/dev/null | wc -l)" -ge 3 ]; then
    echo -e "\033[33m检测到文件已被修改，无需重复操作。\033[0m"
    echo "如果页面显示不正常或一直加载，请尝试以下操作："
    echo -e "1. 按 \033[31mShift+F5\033[0m 强制刷新浏览器缓存。"
    echo -e "2. 如果问题依旧，执行 \033[31m\"$sap\" restore\033[0m 命令可还原所有修改。"
    echo -e "3. 如果您想强制覆盖现有修改，请执行 \033[31m\"$sap\" remod\033[0m 命令。"
    exit 1
fi

# --- 准备注入内容 ---
# 临时文件用于存放即将注入的代码块
contentfornp=/tmp/.contentfornp.tmp
contentforpvejs=/tmp/.contentforpvejs.tmp

# 为 turbostat 准备运行环境
if [ -e /usr/sbin/turbostat ]; then
    modprobe msr
    chmod +s /usr/sbin/turbostat
    echo 'msr' >/etc/modules-load.d/turbostat-msr.conf
fi

# 生成注入到 Perl 后端文件 (Nodes.pm) 的代码
cat >"$contentfornp" <<'EOF'

#modbyshowtempfreq
# 获取全系统的传感器数据 (温度、风扇等)
$res->{thermalstate} = `sensors
