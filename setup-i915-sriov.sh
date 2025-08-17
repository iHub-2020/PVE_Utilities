#!/bin/bash
# ==============================================================================
# Script Name:   setup-i915-sriov.sh
# Description:   一键在 PVE 宿主机或其 Linux 虚拟机中安装与配置 Intel i915 SR-IOV。
# Version:       1.9.2
# Changes:
#   - 修复“最低内核判断过严导致无限提示升级/重启”的逻辑死循环
#   - 采用“宽进严出”：先尝试 DKMS 构建，失败再引导升级；仅在确实安装新内核时提示重启
#   - 固定支持窗口 6.8–6.15（可 MIN_KERNEL_OVERRIDE 覆盖最低值）；compat vX.Y 仅作提示
#   - 升级前预检候选版本；无更高候选或不满足窗口时明确中止并给出指引
#   - APT 索引健康检查（update/clean/autoclean/--fix-missing），过程日志与结构化结果分流
#   - HELP_TEXT 使用 cat heredoc，避免 set -e + read -d '' 提前退出
# GitHub:        https://github.com/iHub-2020/PVE_Utilities
# ==============================================================================

set -Eeuo pipefail

# ---------- 颜色与输出 ----------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
step(){ echo -e "\n${C_BLUE}==>${C_RESET} ${C_YELLOW}$1${C_RESET}" >&2; }
ok(){   echo -e "${C_GREEN}  [成功]${C_RESET} $1" >&2; }
warn(){ echo -e "${C_YELLOW}  [提示]${C_RESET} $1" >&2; }
fail(){ echo -e "${C_RED}  [错误]${C_RESET} $1" >&2; }
info(){ echo -e "  [信息] $1" >&2; }

# ---------- 全局变量 ----------
readonly SCRIPT_VERSION="1.9.2"
readonly STATE_DIR="/var/tmp/i915-sriov-setup"
readonly BACKUP_DIR="${STATE_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"

# 行为与支持窗口
DEBUG="${DEBUG:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
MIN_KERNEL_OVERRIDE="${MIN_KERNEL_OVERRIDE:-}"
SUPPORTED_MIN_DEFAULT="6.8"
SUPPORTED_MAX_DEFAULT="6.15"

# 环境与设备
ENV_TYPE=""; OS_ID=""; OS_CODENAME=""
CURRENT_KERNEL=""; CURRENT_KERNEL_NUM=""
IGPU_PCI_ADDR=""; IGPU_DEV_PATH=""
VF_CONTROL_FILE_EXISTS=false
DKMS_INSTALLED=false
DKMS_INFO_URL=""
DKMS_PKG_NAME="i915-sriov-dkms"

CONFIG_FILES_TO_BACKUP=()

# ---------- 帮助文本 ----------
HELP_TEXT="$(cat <<'EOS'
用法:
  sudo bash setup-i915-sriov.sh [选项]

常用选项:
  --help, -h           显示本帮助并退出
  --debug              打开调试日志
  --assume-yes         自动回答“是”（风险自负）
  --non-interactive    尽量减少交互（关键节点仍会二次确认）

支持与策略:
  - 支持窗口：内核 6.8–6.15（教程与实测范围）；可用 MIN_KERNEL_OVERRIDE=6.12 覆盖最低值应急
  - 安装顺序：先写参数/黑名单 → 安装 headers → 安装 DKMS → 检查 DKMS 构建状态
  - 失败时再建议升级；仅在“确实安装了新内核”时提示重启，避免循环
  - APT 索引会先健康检查并刷新；过程日志到 stderr，结构化结果到 stdout

环境变量:
  DEBUG=1              打印更多调试信息
  ASSUME_YES=1         默认为“是”
  NONINTERACTIVE=1     尽量无交互（仍会进行关键提醒）
  MIN_KERNEL_OVERRIDE=6.12  手动覆盖最低内核需求（谨慎使用）

示例:
  sudo ASSUME_YES=1 bash setup-i915-sriov.sh
  sudo MIN_KERNEL_OVERRIDE=6.12 bash setup-i915-sriov.sh
EOS
)"

# ---------- 工具函数 ----------
require_root(){ [[ $EUID -eq 0 ]] || { fail "本脚本需要 root 权限"; exit 1; }; }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
ver_ge(){ dpkg --compare-versions "$1" ge "$2"; }
ver_le(){ dpkg --compare-versions "$1" le "$2"; }

kernel_numeric(){ echo "$1" | grep -oE '[0-9]+(\.[0-9]+){1,2}' | head -n1; }

backup_file(){
  local f="$1"; [[ -f "$f" ]] || return 0
  mkdir -p "$(dirname "$BACKUP_DIR/$f")"
  cp -a "$f" "$BACKUP_DIR/$f"
  CONFIG_FILES_TO_BACKUP+=("$f")
}

parse_yes_no(){
  local prompt="$1" def="${2:-no}" dchar="[y/N]"
  [[ "$def" == "yes" ]] && dchar="[Y/n]"
  if [[ "$ASSUME_YES" == "1" || "$NONINTERACTIVE" == "1" ]]; then
    echo "$def"; return 0
  fi
  read -rp "  ${prompt} ${dchar}: " ans
  case "$ans" in
    Y|y|yes) echo "yes" ;;
    N|n|no|"") [[ "$def" == "yes" ]] && echo "yes" || echo "no" ;;
    *) [[ "$def" == "yes" ]] && echo "yes" || echo "no" ;;
  esac
}

# ---------- 错误回滚 ----------
on_error(){
  local code=$? line="${BASH_LINENO[0]:-?}" cmd="${BASH_COMMAND:-?}"
  fail "脚本中断（行 $line）：$cmd；退出码 $code。尝试回滚配置文件……"
  for f in "${CONFIG_FILES_TO_BACKUP[@]}"; do
    [[ -f "$BACKUP_DIR/$f" ]] && { cp -a "$BACKUP_DIR/$f" "$f"; info "已恢复: $f"; }
  done
  warn "注意：已安装的软件包不会自动卸载。"
  exit $code
}
trap on_error ERR
trap 'fail "收到中断信号"; on_error' INT TERM

# ---------- APT 健康检查 ----------
ensure_apt_healthy(){
  info "APT 索引更新中……"
  if ! apt-get update -y >&2; then
    warn "update 失败，尝试 clean/autoclean/--fix-missing ……"
    apt-get clean >&2 || true
    apt-get autoclean >&2 || true
    apt-get update -o Acquire::Retries=3 --fix-missing -y >&2 || true
  fi
  ok "APT 健康检查完成。"
}

# ---------- 环境感知 ----------
detect_environment(){
  step "A.1. 环境感知"
  if cmd_exists pveversion; then ENV_TYPE="PVE_HOST"
  elif cmd_exists systemd-detect-virt && [[ "$(systemd-detect-virt 2>/dev/null)" != "none" ]]; then ENV_TYPE="GUEST_VM"
  else ENV_TYPE="BARE_LINUX"; fi
  info "环境类型: $ENV_TYPE"

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-debian}"; OS_CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || true)}"
  else
    OS_ID="$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo debian)"
    OS_CODENAME="$(lsb_release -sc 2>/dev/null || echo bookworm)"
  fi
  info "操作系统: ${OS_ID} ${OS_CODENAME}"
}

# ---------- 依赖检查 ----------
check_dependencies(){
  step "A.2. 依赖检查"
  local deps=(curl jq dkms build-essential pciutils lsb-release)
  local miss=()
  for d in "${deps[@]}"; do cmd_exists "$d" || miss+=("$d"); done
  if ((${#miss[@]})); then
    warn "缺少依赖：${miss[*]}，开始安装"
    DEBIAN_FRONTEND=noninteractive apt-get update -y >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${miss[@]}"
  fi
  ok "依赖就绪。"
}

# ---------- 解析 DKMS 发布（仅取 URL；兼容版本仅作提示） ----------
fetch_latest_dkms_info(){
  info "查询 i915-sriov-dkms 最新发布信息……"
  local api="https://api.github.com/repos/strongtz/i915-sriov-dkms/releases/latest"
  local json url compat
  json="$(curl -fsSL "$api" || true)"
  url="$(echo "$json" | jq -r '.assets[]?.browser_download_url | select(test("amd64\\.deb$"))' | head -n1)"
  compat="$(echo "$json" | jq -r '.body' | sed -n -E 's/.*compat v([0-9]+\.[0-9]+).*/\1/p' | head -n1 || true)"
  [[ -z "$url" ]] && { fail "无法从 GitHub 获取 DKMS 安装包"; exit 1; }
  [[ -n "$compat" ]] && info "上游提示的 compat 版本：$compat（仅供参考）"
  echo "$url"
}

# ---------- 版本/候选查询 ----------
candidate_version_for(){
  # $1: 包名  $2: 通道（可空）
  local pkg="$1" target="${2:-}"
  if [[ -n "$target" ]]; then
    apt-cache -o APT::Default-Release="$target" policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
  else
    apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
  fi
}

# ---------- backports 启用（Debian） ----------
ensure_backports_if_needed(){
  [[ "$OS_ID" == "debian" ]] || return 0
  if grep -Rq " ${OS_CODENAME}-backports " /etc/apt/sources.list /etc/apt/sources.list.d/ >/dev/null 2>&1; then
    info "已检测到 backports。"
    return 0
  fi
  local ans; ans="$(parse_yes_no "启用 ${OS_CODENAME}-backports 以获取更新内核？" "yes")"
  if [[ "$ans" != "yes" ]]; then
    warn "未启用 backports，若 stable 版本过低可能无法升级。"
    return 0
  fi
  echo "deb http://deb.debian.org/debian ${OS_CODENAME}-backports main contrib non-free-firmware" >/etc/apt/sources.list.d/backports.list
  ensure_apt_healthy
  ok "backports 已启用。"
}

# ---------- 选择元包 ----------
find_latest_kernel_meta(){
  local apt_target="" kpkg="" hpkg=""
  if [[ "$ENV_TYPE" == "PVE_HOST" ]]; then
    local names versions best=""; info "PVE 环境：搜索 proxmox/pve 内核……"
    names="$(apt-cache search --names-only '^(proxmox|pve)-kernel-[0-9]+\.[0-9]+$' | awk '{print $1}')"
    versions="$(echo "$names" | sed -E 's/.*-([0-9]+\.[0-9]+)$/\1/' | sort -V | uniq)"
    for v in $versions; do best="$v"; done
    [[ -n "$best" ]] || { echo "||"; return 1; }
    if echo "$names" | grep -q "proxmox-kernel-${best}"; then
      kpkg="proxmox-kernel-${best}"; hpkg="proxmox-headers-${best}"
    else
      kpkg="pve-kernel-${best}";     hpkg="pve-headers-${best}"
    fi
    echo "${kpkg}|${hpkg}|${apt_target}"; return 0
  fi

  if [[ "$OS_ID" == "debian" ]]; then
    if grep -Rq " ${OS_CODENAME}-backports " /etc/apt/sources.list /etc/apt/sources.list.d/ >/dev/null 2>&1; then
      apt_target="${OS_CODENAME}-backports"
    fi
    kpkg="linux-image-amd64"; hpkg="linux-headers-amd64"
    echo "${kpkg}|${hpkg}|${apt_target}"; return 0
  fi

  if [[ "$OS_ID" == "ubuntu" ]]; then
    local series; series="$(lsb_release -rs 2>/dev/null || true)"
    local hwe="linux-image-generic-hwe-${series}" hhwe="linux-headers-generic-hwe-${series}"
    if apt-cache show "$hwe" >/dev/null 2>&1; then kpkg="$hwe"; hpkg="$hhwe"; else kpkg="linux-image-generic"; hpkg="linux-headers-generic"; fi
    echo "${kpkg}|${hpkg}|${apt_target}"; return 0
  fi

  echo "||"; return 1
}

# ---------- 安装 headers（尽力而为） ----------
install_headers_for_running_kernel(){
  info "安装与当前内核匹配的头文件（尽力匹配 uname -r）……"
  apt-get install -y "pve-headers-$(uname -r)" >/dev/null 2>&1 || \
  apt-get install -y "linux-headers-$(uname -r)" || \
  warn "未能安装到完全匹配的头文件（若 DKMS 构建失败，请先解决头文件问题）"
}

# ---------- 安装 DKMS ----------
install_dkms_package(){
  local url="$1"
  info "下载并安装 DKMS 包……"
  local tmp="/tmp/$(basename "$url")"
  curl -fSL "$url" -o "$tmp"
  dpkg -i "$tmp" || apt-get -f install -y
  rm -f "$tmp"
  ok "DKMS 包安装完成。"
}

# ---------- DKMS 状态检测 ----------
dkms_ok_for_running_kernel(){
  # 返回 0 表示针对当前内核已 installed
  local k="$(uname -r)"
  dkms status 2>/dev/null | grep -E "^${DKMS_PKG_NAME}," | grep -q "$k, installed"
}

# ---------- 升级内核（仅在需要/同意时） ----------
candidate_info_msg(){
  local pkg="$1" target="$2"
  local cand ver; cand="$(candidate_version_for "$pkg" "$target")"; ver="$(kernel_numeric "$cand")"
  echo "$cand|$ver"
}

install_latest_kernel_meta(){
  local trio; trio="$(find_latest_kernel_meta)" || { fail "无法解析内核元包"; exit 1; }
  local kpkg hpkg target; kpkg="${trio%%|*}"; hpkg="$(echo "$trio" | cut -d'|' -f2)"; target="$(echo "$trio" | cut -d'|' -f3)"
  local cand ver; IFS="|" read -r cand ver < <(candidate_info_msg "$kpkg" "$target")
  [[ -n "$ver" ]] || { fail "无法获取 $kpkg 候选版本"; exit 1; }
  info "目标通道 $(echo ${target:-stable}) 中 $kpkg 候选版本：$cand（解析：$ver）"

  # 若已安装且不低于候选，则无需安装
  local before="$(dpkg-query -W -f='${Version}' "$kpkg" 2>/dev/null || echo none)"
  if [[ "$before" != "none" ]]; then
    local before_num; before_num="$(kernel_numeric "$before")"
    if ver_ge "${before_num:-0}" "${ver:-0}"; then
      warn "$kpkg 已安装且版本 $before_num ≥ 候选 $ver，无需重复安装。"
      echo "NO_INSTALL"; return 0
    fi
  fi

  # 询问是否安装
  local ans; ans="$(parse_yes_no "安装 $kpkg 与 $hpkg（通道: ${target:-stable}）？" "yes")"
  [[ "$ans" == "yes" ]] || { warn "用户取消安装。"; echo "NO_INSTALL"; return 0; }

  if [[ -n "$target" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get -y -t "$target" install "$kpkg" "$hpkg"
  else
    DEBIAN_FRONTEND=noninteractive apt-get -y install "$kpkg" "$hpkg"
  fi
  echo "INSTALLED"
}

# ---------- 升级决策：仅在 DKMS 构建确实失败时引导 ----------
maybe_upgrade_kernel_after_failed_build(){
  local supported_min="$1" supported_max="$2"
  info "检测到 DKMS 未能在当前内核构建成功，评估是否需要升级内核……"

  # 预检候选是否有意义（高于当前）
  ensure_apt_healthy
  [[ "$OS_ID" == "debian" ]] && ensure_backports_if_needed

  local trio; trio="$(find_latest_kernel_meta)" || { fail "解析元包失败"; exit 1; }
  local kpkg hpkg target; kpkg="${trio%%|*}"; hpkg="$(echo "$trio" | cut -d'|' -f2)"; target="$(echo "$trio" | cut -d'|' -f3)"
  local cand ver; IFS="|" read -r cand ver < <(candidate_info_msg "$kpkg" "$target")
  if [[ -z "$ver" ]]; then
    fail "当前通道无法获取候选版本信息，暂不升级。"; return 1
  fi

  if ! ver_ge "$ver" "$supported_min"; then
    fail "当前通道可获得的最高内核为 $ver，低于支持下限 $supported_min，升级无意义。"
    warn "可选方案：更换更高通道（测试/不稳定或 PVE 新内核）或稍后再试。"
    return 1
  fi

  if ver_ge "$CURRENT_KERNEL_NUM" "$ver"; then
    warn "候选版本 $ver 不高于当前 $CURRENT_KERNEL_NUM，升级无意义。"
    return 1
  fi

  local res; res="$(install_latest_kernel_meta)"
  if [[ "$res" == "INSTALLED" ]]; then
    warn "已安装新内核，请立即重启进入新内核后再次运行脚本。"
    exit 0
  else
    warn "未执行内核安装。"
    return 1
  fi
}

# ---------- GRUB 与模块参数 ----------
ensure_grub_params(){
  step "配置内核参数与 GRUB"
  local grub_file="/etc/default/grub"
  [[ -f "$grub_file" ]] || echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' > "$grub_file"
  backup_file "$grub_file"

  local cmdline; cmdline="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | sed -E 's/^[^"]*"(.*)".*$/\1/')" || true
  # 必需参数：intel_iommu=on；模块参数建议通过 modprobe，但为兼容也追加常用项
  for p in intel_iommu=on; do
    [[ " $cmdline " =~ " $p " ]] || cmdline="$cmdline $p"
  done
  cmdline="$(echo "$cmdline" | xargs)"
  sed -i -E 's|^(GRUB_CMDLINE_LINUX_DEFAULT=").*(")$|\1'"$cmdline"'\2|' "$grub_file"

  if cmd_exists update-grub; then update-grub; else grub-mkconfig -o /boot/grub/grub.cfg; fi
  cmd_exists update-initramfs && update-initramfs -u
  cmd_exists proxmox-boot-tool && proxmox-boot-tool refresh || true
  ok "GRUB/Initramfs 刷新完成。"
}

write_modprobe_conf(){
  info "写入 i915/xe 模块参数……"
  local modconf="/etc/modprobe.d/i915-sriov-dkms.conf"
  if [[ -f "$modconf" ]]; then ok "模块参数已存在：$modconf"; return; fi
  backup_file "$modconf"
  cat >"$modconf"<<'EOF'
blacklist xe
options i915 enable_guc=3
options i915 max_vfs=7
EOF
  ok "模块参数写入完成：$modconf"
}

# ---------- 阶段 A：安装 ----------
run_install_phase(){
  step "A. 安装阶段"

  detect_environment
  ensure_apt_healthy
  check_dependencies

  CURRENT_KERNEL="$(uname -r)"
  CURRENT_KERNEL_NUM="$(kernel_numeric "$CURRENT_KERNEL")"
  info "当前运行内核：$CURRENT_KERNEL（解析：$CURRENT_KERNEL_NUM）"

  # 支持窗口
  local supported_min="${MIN_KERNEL_OVERRIDE:-$SUPPORTED_MIN_DEFAULT}"
  local supported_max="$SUPPORTED_MAX_DEFAULT"
  info "采用支持窗口：[$supported_min, $supported_max]"

  ensure_grub_params
  write_modprobe_conf
  install_headers_for_running_kernel

  # 获取 DKMS 包并安装
  if [[ -n "${DKMS_DEB_URL:-}" ]]; then
    DKMS_INFO_URL="$DKMS_DEB_URL"
  else
    DKMS_INFO_URL="$(fetch_latest_dkms_info)"
  fi
  install_dkms_package "$DKMS_INFO_URL"

  # 首次检测：DKMS 是否已为当前内核 installed
  if dkms_ok_for_running_kernel; then
    ok "DKMS 已为当前内核构建成功，可直接进入“配置阶段”。"
    return 0
  fi

  # 若不在支持窗口，给出更明确提示
  if ! ver_ge "$CURRENT_KERNEL_NUM" "$supported_min"; then
    warn "当前内核 $CURRENT_KERNEL_NUM 低于支持下限 $supported_min，尝试引导升级。"
    maybe_upgrade_kernel_after_failed_build "$supported_min" "$supported_max" || true
    fail "DKMS 未构建成功且无法有效升级，请先将内核升级到 ≥$supported_min 后再试。"
    exit 1
  fi
  if ! ver_le "$CURRENT_KERNEL_NUM" "$supported_max"; then
    warn "当前内核 $CURRENT_KERNEL_NUM 高于建议上限 $supported_max，可能存在兼容性风险。"
    warn "你仍可继续创建 VF 并验证；若异常，再考虑降级或切换通道。"
  fi

  # 尝试补救构建
  info "尝试 DKMS 重新构建（autoinstall）……"
  dkms autoinstall -k "$(uname -r)" || true
  if dkms_ok_for_running_kernel; then
    ok "DKMS 重新构建成功。"
    return 0
  fi

  # 构建仍失败：最后提供升级建议（仅当有更高可用）
  maybe_upgrade_kernel_after_failed_build "$supported_min" "$supported_max" || {
    fail "DKMS 构建仍失败，且未能进行有效升级。请根据日志修复头文件/依赖或调整内核版本后重试。"
    exit 1
  }
}

# ---------- 阶段 B：配置 ----------
run_configure_phase(){
  step "B. 配置阶段"
  local total; total="$(cat "${IGPU_DEV_PATH}/sriov_totalvfs")"
  info "设备最大支持 VF 数量：$total"
  local n
  if [[ "$NONINTERACTIVE" == "1" ]]; then n="$total"; info "非交互模式：默认创建 $n 个 VF。"
  else read -rp "  请输入要创建的 VF 数量 (1-${total}): " n; fi
  [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=total)) || { fail "输入无效"; exit 1; }

  info "创建 VF（先 0 再 N，避免多次写入冲突）……"
  echo 0 > "${IGPU_DEV_PATH}/sriov_numvfs"
  echo "$n" > "${IGPU_DEV_PATH}/sriov_numvfs"
  ok "已临时创建 $n 个 VF。"

  local ans; ans="$(parse_yes_no "是否持久化为开机自动创建？" "yes")"
  [[ "$ans" == "yes" ]] && create_systemd_service "$n" || warn "已按要求跳过持久化。"

  finalize
}

create_systemd_service(){
  local num="$1" svc="/etc/systemd/system/i915-sriov-vf.service"
  backup_file "$svc"
  cat >"$svc"<<EOF
[Unit]
Description=Configure i915 SR-IOV VFs at boot
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0 > ${IGPU_DEV_PATH}/sriov_numvfs; echo ${num} > ${IGPU_DEV_PATH}/sriov_numvfs'
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable i915-sriov-vf.service
  ok "已设置开机自动创建 ${num} 个 VF。"
}

# ---------- 初始化 ----------
initialize_and_check_base(){
  step "A.0. 初始化与基础检查"
  require_root

  CURRENT_KERNEL="$(uname -r)"
  CURRENT_KERNEL_NUM="$(kernel_numeric "$CURRENT_KERNEL")"
  info "当前运行内核: ${CURRENT_KERNEL}"

  local line; line="$(lspci -D -nn 2>/dev/null | grep -Ei 'VGA|Display|3D' | grep -i 'Intel' || true)"
  IGPU_PCI_ADDR="$(echo "$line" | awk '{print $1}' | head -n1 || true)"
  if [[ -z "$IGPU_PCI_ADDR" ]]; then
    read -rp "未自动发现 Intel 核显，请手动输入 PCI 地址（如 0000:00:02.0）: " IGPU_PCI_ADDR
  fi
  [[ -n "$IGPU_PCI_ADDR" ]] || { fail "未提供 iGPU PCI 地址"; exit 1; }
  IGPU_DEV_PATH="/sys/bus/pci/devices/${IGPU_PCI_ADDR}"
  ok "检测到核显设备: ${IGPU_PCI_ADDR}"

  if [[ -f "${IGPU_DEV_PATH}/sriov_numvfs" ]]; then
    VF_CONTROL_FILE_EXISTS=true
    info "SR-IOV 控制文件存在：${IGPU_DEV_PATH}/sriov_numvfs"
  fi

  if cmd_exists dkms && dkms status 2>/dev/null | grep -q "^${DKMS_PKG_NAME},"; then
    DKMS_INSTALLED=true
    info "已检测到 ${DKMS_PKG_NAME}。"
  fi
}

finalize(){
  step "C. 完成与验证"
  ok "全部完成。验证建议："
  info "1) dmesg | grep -i i915 | grep -i sriov"
  info "2) lspci -nnk | grep -A3 -E 'VGA|Display'"
  info "3) cat ${IGPU_DEV_PATH}/sriov_numvfs"
}

# ---------- 参数解析 ----------
show_help(){ echo "$HELP_TEXT"; }
parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) show_help; exit 0 ;;
      --debug) DEBUG=1; shift ;;
      --assume-yes) ASSUME_YES=1; shift ;;
      --non-interactive) NONINTERACTIVE=1; shift ;;
      *) warn "忽略未知参数: $1"; shift ;;
    esac
  done
}

# ---------- 主流程 ----------
main(){
  parse_args "$@"

  echo -e "${C_BLUE}======================================================${C_RESET}" >&2
  echo -e "${C_BLUE}  Intel i915 SR-IOV 一键安装脚本 v${SCRIPT_VERSION}${C_RESET}" >&2
  echo -e "${C_BLUE}======================================================${C_RESET}" >&2

  initialize_and_check_base

  # 已具备控制文件 => 进入配置阶段
  if [[ "$VF_CONTROL_FILE_EXISTS" == true ]]; then
    run_configure_phase
    return 0
  fi

  # 未具备控制文件：
  # - 若 DKMS 已安装但未生效，多半需要重启以加载参数/模块，或当前内核不在窗口
  if [[ "$DKMS_INSTALLED" == true && "$VF_CONTROL_FILE_EXISTS" == false ]]; then
    warn "检测到 DKMS 已安装但未生效；若刚安装/变更参数，请先重启后再运行以加载模块。"
  fi

  run_install_phase
}

main "$@"
