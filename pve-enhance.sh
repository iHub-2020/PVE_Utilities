#!/usr/bin/env bash

# ==============================================================================
# PVE Web UI Enhancement Script
#
# Author: Reyanmatic
# Version: 2.0 (Optimized based on original work by a904055262)
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
# 这段代码通过执行shell命令获取硬件信息，并将其添加到API响应中
cat >"$contentfornp" <<'EOF'

#modbyshowtempfreq
# 获取全系统的传感器数据 (温度、风扇等)
$res->{thermalstate} = `sensors -A`;
# 获取CPU频率、调速器、功耗等信息
$res->{cpuFreq} = `
    goverf=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
    maxf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
    minf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq

    cat /proc/cpuinfo | grep -i "cpu mhz"
    echo -n 'gov:'
    [ -f \$goverf ] && cat \$goverf || echo none
    echo -n 'min:'
    [ -f \$minf ] && cat \$minf || echo none
    echo -n 'max:'
    [ -f \$maxf ] && cat \$maxf || echo none
    echo -n 'pkgwatt:'
    [ -e /usr/sbin/turbostat ] && turbostat --quiet --cpu package --show "PkgWatt" -S sleep 0.25 2>&1 | tail -n1
`;
EOF

# 生成注入到 PVE 前端 JS 文件 (pvemanagerlib.js) 的代码
# 这段JS代码定义了如何在Web界面上渲染从后端获取到的硬件信息
cat >"$contentforpvejs" <<'EOF'
//modbyshowtempfreq
    // 温度显示模块
    {
        itemId: 'thermal',
        colspan: 2,
        printBar: false,
        title: gettext('温度 (°C)'),
        textField: 'thermalstate',
        renderer: function(value) {
            if (!value) return 'N/A';
            // 对 'sensors -A' 的输出进行解析和格式化
            const lines = value.trim().split(/\s+(?=^\w+-)/m).sort();
            const formatted = lines.map(line => {
                // 提取风扇转速
                const fanMatch = line.match(/(?<=:\s+)[1-9]\d*(?=\s+RPM\s+)/ig);
                if (fanMatch) {
                    return `风扇: ${fanMatch.join(';')} RPM`;
                }
                
                const nameMatch = line.match(/^[^-]+/);
                let name = nameMatch ? nameMatch[0].toUpperCase() : 'UNKNOWN';
                
                // 提取温度值
                const tempMatch = line.match(/(?<=:\s+)[+-][\d.]+(?=.?°C)/g);
                if (tempMatch) {
                    const temps = tempMatch.map(t => Number(t).toFixed(0));
                    if (/coretemp/i.test(name)) {
                        name = 'CPU';
                        // 格式化CPU多核心温度
                        return `CPU: ${temps[0]}` + (temps.length > 1 ? ` (${temps.slice(1).join('|')})` : '');
                    }
                    const critMatch = line.match(/(?<=\bcrit\b[^+]+\+)\d+/);
                    return `${name}: ${temps[0]}` + (critMatch ? ` (crit ${critMatch[0]})` : '');
                }
                return null; // 非温度或风扇数据，过滤掉
            }).filter(Boolean); // 移除null项

            // 将CPU温度提前到最前面
            const cpuIndex = formatted.findIndex(item => /CPU/i.test(item));
            if (cpuIndex > 0) {
                formatted.unshift(formatted.splice(cpuIndex, 1)[0]);
            }
            
            return formatted.join(' | ');
        }
    },
    // CPU频率显示模块
    {
        itemId: 'cpumhz',
        colspan: 2,
        printBar: false,
        title: gettext('CPU 状态'),
        textField: 'cpuFreq',
        renderer: function(v) {
            if (!v) return 'N/A';
            // 解析CPU频率
            const freqs = (v.match(/(?<=^cpu[^\d]+)\d+/img) || []).map(e => (e / 1000).toFixed(1));
            const freqStr = freqs.length > 0 ? `频率: ${freqs.join('|')} GHz` : '';
            
            // 解析调速器、最大/最小频率和功耗
            const gov = (v.match(/(?<=^gov:).+/im) || ['N/A'])[0].toUpperCase();
            let min = (v.match(/(?<=^min:).+/im) || ['none'])[0];
            min = min !== 'none' ? `${(min / 1000000).toFixed(1)}` : 'N/A';
            let max = (v.match(/(?<=^max:).+/im) || ['none'])[0];
            max = max !== 'none' ? `${(max / 1000000).toFixed(1)}` : 'N/A';
            const wattMatch = v.match(/(?<=^pkgwatt:)[\d.]+$/im);
            const watt = wattMatch ? ` | 功耗: ${(wattMatch[0] / 1).toFixed(1)}W` : '';

            return `${freqStr} | 范围: ${min}-${max} GHz | 调速器: ${gov}${watt}`;
        }
    },
EOF

# --- 动态添加硬盘信息模块 ---
# 检测并添加 NVMe 硬盘信息
echo "正在检测 NVMe 硬盘..."
nvi=0
if $sNVMEInfo; then
    chmod +s /usr/sbin/smartctl
    for nvme in $(ls /dev/nvme[0-9] 2>/dev/null); do
        # 为每个找到的NVMe硬盘，在后端追加数据获取命令
        cat >>"$contentfornp" <<EOF
\$res->{nvme$nvi} = \`smartctl $nvme -a -j\`;
EOF
        # 同时在前端追加对应的UI渲染模块
        cat >>"$contentforpvejs" <<EOF
        {
            itemId: 'nvme${nvi}',
            colspan: 2,
            printBar: false,
            title: gettext('NVMe ${nvi}'),
            textField: 'nvme${nvi}',
            renderer: function(value) {
                try {
                    const v = JSON.parse(value);
                    if (!v.model_name) return '硬盘不存在 (可能已直通或移除)';
                    const model = v.model_name;
                    const temp = v.temperature?.current ? ` | ${v.temperature.current}°C` : '';
                    const health = v.nvme_smart_health_information_log?.percentage_used !== undefined ? ` | 健康: ${100 - v.nvme_smart_health_information_log.percentage_used}%` : '';
                    const pot = v.power_on_time?.hours ? ` | 通电: ${v.power_on_time.hours}h` : '';
                    const smart = v.smart_status?.passed !== undefined ? (v.smart_status.passed ? ' | SMART正常' : ' | SMART警告!') : '';
                    return `${model}${temp}${health}${pot}${smart}`;
                } catch (e) {
                    return '无法解析硬盘信息';
                }
            }
        },
EOF
        nvi=$((nvi + 1))
    done
fi
echo "完成，已为 $nvi 个 NVMe 硬盘添加监控模块。"

# 检测并添加 SATA 硬盘信息 (包括 SSD 和 HDD)
echo "正在检测 SATA 硬盘..."
sdi=0
if $sODisksInfo; then
    chmod +s /usr/sbin/smartctl
    chmod +s /usr/sbin/hdparm
    for sd in $(ls /dev/sd[a-z] 2>/dev/null); do
        sdsn=$(basename "$sd")
        sdcr="/sys/block/$sdsn/queue/rotational"
        [ ! -f "$sdcr" ] && continue

        if [ "$(cat "$sdcr")" = "0" ]; then
            hddisk=false
            sdtype="SSD ${sdi}"
        else
            hddisk=true
            sdtype="HDD ${sdi}"
        fi

        # 后端数据获取逻辑：对于机械盘，先检查是否休眠
        cat >>"$contentfornp" <<EOF
\$res->{sd$sdi} = \`
    if [ -b $sd ]; then
        if $hddisk && hdparm -C $sd 2>/dev/null | grep -iq 'standby'; then
            echo '{"standby": true, "model_name": "$(smartctl -i $sd | grep "Device Model" | awk -F': ' '{print \$2}')"}'
        else
            smartctl $sd -a -j
        fi
    else
        echo '{}'
    fi
\`;
EOF
        # 前端UI渲染模块
        cat >>"$contentforpvejs" <<EOF
        {
            itemId: 'sd${sdi}',
            colspan: 2,
            printBar: false,
            title: gettext('${sdtype}'),
            textField: 'sd${sdi}',
            renderer: function(value) {
                try {
                    const v = JSON.parse(value);
                    if (v.standby === true) return `${v.model_name || '硬盘'} (休眠中)`;
                    if (!v.model_name) return '硬盘不存在 (可能已直通或移除)';
                    const model = v.model_name;
                    const temp = v.temperature?.current ? ` | ${v.temperature.current}°C` : '';
                    const pot = v.power_on_time?.hours ? ` | 通电: ${v.power_on_time.hours}h` : '';
                    const smart = v.smart_status?.passed !== undefined ? (v.smart_status.passed ? ' | SMART正常' : ' | SMART警告!') : '';
                    return `${model}${temp}${pot}${smart}`;
                } catch (e) {
                    return '无法解析硬盘信息';
                }
            }
        },
EOF
        sdi=$((sdi + 1))
    done
fi
echo "完成，已为 $sdi 个 SATA 硬盘添加监控模块。"

# --- 执行文件修改 ---
echo "--- 开始修改系统文件 ---"

# 1. 修改 Perl 后端文件 (Nodes.pm)
echo "正在修改 Nodes.pm..."
if ! grep -q 'modbyshowtempfreq' "$np"; then
    # 备份原始文件
    [ ! -e "$np.$pvever.bak" ] && cp "$np" "$np.$pvever.bak" && echo "已备份 Nodes.pm -> Nodes.pm.$pvever.bak"
    # 使用sed在指定锚点后插入我们准备好的Perl代码
    if sed -i "/PVE::pvecfg::version_text()/{ r $contentfornp }" "$np"; then
        echo "Nodes.pm 修改成功。"
        $dmode && sed -n "/PVE::pvecfg::version_text()/,+5p" "$np"
    else
        echo "在 Nodes.pm 中找不到修改点。"
        fail
    fi
else
    echo "Nodes.pm 已被修改过，跳过。"
fi

# 2. 修改 PVE 前端 JS 文件 (pvemanagerlib.js)
echo "正在修改 pvemanagerlib.js..."
if ! grep -q 'modbyshowtempfreq' "$pvejs"; then
    # 备份原始文件
    [ ! -e "$pvejs.$pvever.bak" ] && cp "$pvejs" "$pvejs.$pvever.bak" && echo "已备份 pvemanagerlib.js -> pvemanagerlib.js.$pvever.bak"
    # 找到 'pveversion' 项，在其后插入我们准备好的JS代码块
    if sed -i "/pveversion/,+3{ /},/r $contentforpvejs }" "$pvejs"; then
        echo "pvemanagerlib.js 内容注入成功。"
        $dmode && sed -n "/pveversion/,+8p" "$pvejs"
    else
        echo "在 pvemanagerlib.js 中找不到内容注入点。"
        fail
    fi

    # 动态调整UI面板高度以适应新增内容
    echo "正在动态调整UI面板高度..."
    addRs=$(grep -c '\$res' "$contentfornp")
    addHei=$((28 * addRs)) # 每个新增条目大约需要28px的高度
    $dmode && echo "检测到 $addRs 个新增条目，UI高度需增加 ${addHei}px。"

    # 修改左侧状态栏高度
    wph_line=$(sed -n '/widget.pveNodeStatus/,+4{ /height:/{=;p;q} }' "$pvejs")
    if [ -n "$wph_line" ]; then
        wph=$(sed -n -E "${wph_line}s/[^0-9]*([0-9]+).*/\1/p" "$pvejs")
        sed -i -E "${wph_line}s#[0-9]+#$((wph + addHei))#" "$pvejs"
        echo "左侧面板高度调整成功。"
    else
        echo "未找到左侧面板高度修改点，跳过。"
    fi

    # 修改右侧摘要栏最小高度，使其与左侧匹配，防止布局错位
    nph_line=$(sed -n '/nodeStatus:\s*nodeStatus/,+10{ /minHeight:/{=;p;q} }' "$pvejs")
    if [ -n "$nph_line" ]; then
        nph=$(sed -n -E "${nph_line}s/[^0-9]*([0-9]+).*/\1/p" "$pvejs")
        wph_new=$(sed -n -E "/widget\.pveNodeStatus/,+4{ /height:/{s/[^0-9]*([0-9]+).*/\1/p;q} }" "$pvejs")
        sed -i -E "${nph_line}s#[0-9]+#$((nph + addHei))#" "$pvejs"
        echo "右侧面板高度调整成功。"
    else
        echo "未找到右侧面板高度修改点，跳过。"
    fi
else
    echo "pvemanagerlib.js 已被修改过，跳过。"
fi

# 3. 修改 PVE 组件库 JS (proxmoxlib.js) 以去除订阅提示
echo "正在修改 proxmoxlib.js 以移除订阅提示..."
if ! grep -q 'modbyshowtempfreq' "$plibjs"; then
    # 备份原始文件
    [ ! -e "$plibjs.$pvever.bak" ] && cp "$plibjs" "$plibjs.$pvever.bak" && echo "已备份 proxmoxlib.js -> proxmoxlib.js.$pvever.bak"
    # 找到验证订阅的逻辑，将其判断条件直接改为 false
    if sed -i '/\/nodes\/localhost\/subscription/,+10{ /res === null/{ N; s/(.*)/(false)/; a //modbyshowtempfreq } }' "$plibjs"; then
        echo "订阅提示移除成功。"
        $dmode && sed -n "/\/nodes\/localhost\/subscription/,+10p" "$plibjs"
    else
        echo "未找到订阅提示的修改点，放弃修改此项。"
    fi
else
    echo "proxmoxlib.js 已被修改过，跳过。"
fi

# --- 完成与收尾 ---
# 清理临时文件
rm -f "$contentfornp" "$contentforpvejs"

echo -e "\033[32m----------------------------------------\033[0m"
echo -e "\033[32m所有修改已成功应用！\033[0m"
echo "正在重启PVE Web服务以使更改生效..."
systemctl restart pveproxy

echo -e "请按 \033[31mShift+F5\033[0m 强制刷新您的浏览器以查看最新效果。"
echo -e "如果遇到任何问题，请执行 \033[31m\"$sap\" restore\033[0m 命令来一键还原。"
echo -e "\033[32m----------------------------------------\033[0m"
