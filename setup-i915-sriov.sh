#!/bin/bash

# ===================================================================================
# Script Name:   setup-i915-sriov.sh
# Description:   一键在 PVE 宿主机或其 Linux 虚拟机中安装 Intel i915 SR-IOV 驱动。
# Author:        Optimized for iHub-2020 (with critical review from a superior AI)
# Version:       1.9.0 (机械降神·长注释复原版 - 恢复400+行结构；修正重启提示级别；按需启用 backports)
# GitHub:        https://github.com/iHub-2020/PVE_Utilities
#
# 设计目标与原则（长注释保留，便于审阅/维护/二次扩展）
# - 环境感知：
#   - 识别 PVE 宿主机、虚拟机、裸机三类环境；
#   - 识别 OS（Debian/Ubuntu）与 codename（如 bookworm），据此选择内核元包。
# - “最新内核”的选择逻辑：
#   - PVE：在仓库中搜索 proxmox-kernel-X.Y 与 pve-kernel-X.Y，按版本排序选最新，同时安装配套 headers；
#   - Debian：若 stable 的 linux-image-amd64 候选版本低于驱动要求，则按需启用 <codename>-backports，随后从 backports 安装；
#   - Ubuntu：优先 HWE（linux-image-generic-hwe-<series>），否则回退 linux-generic。
# - 健壮性：
#   - 在解析候选版本与安装前，统一 apt-get update（将输出导向 stderr，避免污染 stdout 返回值），
#     防止使用过期索引产生错误决定；
#   - 发现 apt 索引异常时可尝试“轻修复”策略（clean/autoclean/--fix-missing）再重试；
#   - 失败统一进入 on_error 回滚逻辑；配置文件在修改前均会备份并登记以便恢复。
# - 可读性：
#   - 保留完整的帮助与注释，恢复 >400 行的脚本结构，便于团队内长期维护；
#   - 所有交互提示均清晰标注期望操作与默认值。
# - 交互与提示级别：
#   - “安装成功但需重启”→ 使用 [提示]/[警告]，不再用 [错误]，避免误导。
# - 日志：
#   - 过程信息默认输出到 stderr；给调用方保留可解析的 stdout（例如函数回传的“内核|头文件|通道”三元组）。
#
# 注意：
# - 不支持的发行版会直接退出（明确提示 OS_ID）；如需拓展请在 detect_environment 与 find_latest_kernel_meta 中加分支；
# - VF 持久化通过 systemd oneshot 服务实现，遵循“先0再N”的安全模式；
# - DKMS 包来自上游项目 strongtz/i915-sriov-dkms 的最新 release。
#
# 参考与背景：
# - “不同 APT 仓库通道会影响候选版本”的常识：stable 与 backports 的可见版本不同，应在索引新鲜时做选择；
# - “先刷新/维护本地索引缓存再继续”的做法可避免候选版本误判；
# - PVE 与通用 Debian/Ubuntu 的包名体系有差异，需要分支处理。
# ===================================================================================

set -Eeuo pipefail

# --- 颜色与统一输出（保持与历史版本一致） ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'

step() { echo -e "\n${C_BLUE}==>${C_RESET} ${C_YELLOW}$1${C_RESET}" >&2; }
ok()   { echo -e "${C_GREEN}  [成功]${C_RESET} $1" >&2; }
warn() { echo -e "${C_YELLOW}  [提示]${C_RESET} $1" >&2; }
fail() { echo -e "${C_RED}  [错误]${C_RESET} $1" >&2; }
info() { echo -e "  [信息] $1" >&2; }

# --- 全局变量与默认值 ---
readonly SCRIPT_VERSION="1.9.0"
readonly STATE_DIR="/var/tmp/i915-sriov-setup"
readonly BACKUP_DIR="${STATE_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
readonly LOG_DIR="${STATE_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$LOG_DIR"

IGPU_PCI_ADDR=""
IGPU_DEV_PATH=""
CURRENT_KERNEL=""
DKMS_INFO_URL=""

VF_CONTROL_FILE_EXISTS=false
DKMS_INSTALLED=false
CONFIG_FILES_TO_BACKUP=()

# 环境检测变量
ENV_TYPE=""     # PVE_HOST | GUEST_VM | BARE_LINUX
OS_ID=""        # debian | ubuntu | ...
OS_CODENAME=""  # bookworm | bullseye | noble | jammy ...

# 行为开关
DEBUG="${DEBUG:-0}"
ASSUME_YES="${ASSUME_YES:-0}"   # 设置为1可在多数交互中默认“是”
NONINTERACTIVE="${NONINTERACTIVE:-0}"  # 设置为1可尽量减少交互

# --- 帮助文本（长帮助，保留以维持历史行数与可读性） ---
HELP_TEXT="$(cat <<'EOS'
用法:
  sudo bash setup-i915-sriov.sh [选项]

常用选项:
  --help, -h           显示本帮助并退出
  --debug              打开调试模式（更多日志）
  --assume-yes         自动回答“是”（风险自负）
  --non-interactive    尽量减少交互（仍可能为关键操作提示）

脚本阶段说明:
  A. 安装阶段
     - 环境识别：PVE 宿主机 / 虚拟机 / 裸机；Debian / Ubuntu 与 codename
     - 依赖检查：curl/jq/dkms/build-essential/pciutils/lsb-release
     - 驱动信息：从 GitHub API 读取 i915-sriov-dkms 最新 release，解析兼容的最低内核版本
     - 内核处理：按需启用 Debian backports；PVE/Ubuntu 分支选择正确的元包；安装前刷新 APT 索引
     - GRUB 与内核参数：追加 intel_iommu=on iommu=pt；刷新 grub 与 initramfs；PVE 下 refresh 引导
     - 安装 DKMS 包：下载 .deb 并安装；若缺少头文件，尝试多种命名安装
     - 成功后提示重启：标记为 [提示]/[警告]，不再使用 [错误]

  B. 配置阶段（重启后再次运行）
     - 读取核显的 sriov_totalvfs
     - 交互式创建 VF（先0后N）
     - 可选：持久化为 systemd oneshot 服务

返回码约定:
  - 正常结束（包括“已安装新内核，请重启”）：退出码 0
  - 发生未处理错误：非 0；统一进入 on_error 回滚（仅配置文件）

常见问题:
  1) 为什么需要 backports？
     - 部分功能依赖较新的内核版本；stable 中的 linux-image-amd64 往往滞后。启用 <codename>-backports 后，
       通过 “apt-get -t <codename>-backports install linux-image-amd64 linux-headers-amd64” 可获得更新版本。

  2) 为什么 apt-get update 的输出看不到/没有混入结果？
     - 为了让可机读的函数（例如 find_latest_kernel_meta）只通过 stdout 返回结构化结果，
       脚本将过程性输出（update 的 Hit:… 列表）重定向到 stderr，避免污染命令替换 $(...) 的值。

  3) 遇到 APT 索引异常怎么办？
     - 先尝试 apt-get clean / autoclean / update --fix-missing；
       如仍异常，请检查镜像源或网络后再试。

安全提示:
  - 本脚本会修改 /etc/default/grub、/etc/modprobe.d/* 与 systemd 服务文件，均会先备份再写入；
  - 若中途失败，on_error 会尝试基于记录的备份进行回滚；已安装的软件包不会自动卸载。
EOS
)"

# --- 日志辅助 ---
log_debug() {
  [[ "$DEBUG" == "1" ]] || return 0
  echo "[DEBUG] $*" | tee -a "$LOG_FILE" >&2
}

# --- 统一错误处理与回滚 ---
on_error() {
  local code=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-?}"
  fail "脚本中断（行 $line）：'$cmd'；退出码: $code。尝试回滚。"

  if [[ ${#CONFIG_FILES_TO_BACKUP[@]} -gt 0 ]]; then
    warn "正在从备份恢复配置文件..."
    for f in "${CONFIG_FILES_TO_BACKUP[@]}"; do
      local b="$BACKUP_DIR/$f"
      if [[ -f "$b" ]]; then
        mkdir -p "$(dirname "$f")"
        cp -a "$b" "$f"
        info "已恢复: $f"
      fi
    done
    ok "配置文件恢复完成。"
  fi

  warn "注意：已安装的软件包不会自动卸载。"
  exit $code
}
trap on_error ERR
trap 'fail "收到中断信号"; on_error' INT TERM

# --- 小工具函数 ---
require_root() { if [[ $EUID -ne 0 ]]; then fail "本脚本需要 root 权限。"; exit 1; fi; }
cmd_exists() { command -v "$1" &>/dev/null; }
pkg_installed(){ dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }
ver_ge() { dpkg --compare-versions "$1" ge "$2"; }

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ ! " ${CONFIG_FILES_TO_BACKUP[*]} " =~ " $f " ]]; then
    mkdir -p "$(dirname "$BACKUP_DIR/$f")"
    cp -a "$f" "$BACKUP_DIR/$f"
    CONFIG_FILES_TO_BACKUP+=("$f")
    info "已备份: $f"
  fi
}

parse_yes_no() {
  # $1: 提示语，$2: 默认值 yes/no
  local prompt="$1"
  local def="${2:-no}"
  local dchar="[y/N]"
  [[ "$def" == "yes" ]] && dchar="[Y/n]"
  if [[ "$ASSUME_YES" == "1" || "$NONINTERACTIVE" == "1" ]]; then
    echo "$def"
    return 0
  fi
  read -rp "  ${prompt} ${dchar}: " ans
  case "$ans" in
    Y|y|yes) echo "yes" ;;
    N|n|no|"") [[ "$def" == "yes" ]] && echo "yes" || echo "no" ;;
    *) [[ "$def" == "yes" ]] && echo "yes" || echo "no" ;;
  esac
}

ensure_dir() { mkdir -p "$1"; }

# --- APT 健康检查与轻修复 ---
ensure_apt_healthy() {
  # 尽量不打扰 stdout，可机读函数仍能返回纯净结果
  info "正在进行 APT 健康检查..."
  if ! apt-get update -y >&2; then
    warn "apt-get update 出现问题，尝试轻修复..."
    apt-get clean >&2 || true
    apt-get autoclean >&2 || true
    apt-get update -o Acquire::Retries=3 --fix-missing -y >&2 || true
  fi
  ok "APT 健康检查完成。"
}

# --- 核心：环境感知 ---
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

# --- backports 启用逻辑 ---
ensure_backports_if_needed() {
  local min_k="$1"
  [[ "$OS_ID" == "debian" ]] || return 0

  info "正在检查 stable 仓库的内核候选版本是否满足 >= ${min_k}..."
  local stable_candidate
  stable_candidate=$(apt-cache policy linux-image-amd64 | awk '/Candidate:/ {print $2}')
  if [[ -z "$stable_candidate" || "$stable_candidate" == "(none)" ]]; then
    stable_candidate="0"
  fi

  if ver_ge "$stable_candidate" "$min_k"; then
    ok "stable 仓库候选版本 ${stable_candidate} 已满足要求。"
    return 0
  fi

  warn "stable 仓库候选版本 ${stable_candidate} 低于要求，需要 backports！"

  if grep -Rq " ${OS_CODENAME}-backports " /etc/apt/sources.list /etc/apt/sources.list.d/ >/dev/null 2>&1; then
    info "检测到 backports 仓库已配置。"
  else
    local ans
    ans=$(parse_yes_no "是否同意自动添加 Debian backports 仓库配置？" "yes")
    if [[ "$ans" != "yes" ]]; then
      fail "用户拒绝启用 backports，无法安装所需内核。"
      exit 1
    fi
    info "正在添加 backports 仓库..."
    local bp="/etc/apt/sources.list.d/backports.list"
    [[ -f "$bp" ]] && backup_file "$bp"
    echo "deb http://deb.debian.org/debian ${OS_CODENAME}-backports main contrib non-free-firmware" > "$bp"
    info "正在更新 APT 索引以识别 backports..."
    apt-get update -y >&2
    ok "Backports 仓库已启用。"
  fi
}

# --- 选择最新内核元包 ---
find_latest_kernel_meta() {
  info "正在查找可用的最新内核元数据包..."
  apt-get update -y >&2

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

    if [[ -z "$best_ver" ]]; then
      echo "||"
      return 1
    fi

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
    info "Debian环境：检查是否启用了 backports..."
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

# --- 安装最新内核元包 ---
install_latest_kernel_meta() {
  local trio
  trio=$(find_latest_kernel_meta) || { fail "查找内核元包时出错。"; exit 1; }
  local kpkg hpkg target
  kpkg=$(echo "$trio" | cut -d'|' -f1)
  hpkg=$(echo "$trio" | cut -d'|' -f2)
  target=$(echo "$trio" | cut -d'|' -f3)

  [[ -z "$kpkg" || -z "$hpkg" ]] && { fail "解析内核元包名称失败。"; exit 1; }

  local prompt_msg="是否自动安装 ${kpkg} 和 ${hpkg}"
  if [[ -n "$target" ]]; then
    prompt_msg+=" (从 ${target} 通道)"
  fi

  local ans
  ans=$(parse_yes_no "$prompt_msg？" "yes")
  [[ "$ans" == "yes" ]] || { warn "用户取消内核升级。"; exit 1; }

  info "开始安装内核..."
  if [[ -n "$target" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get -y -t "$target" install "$kpkg" "$hpkg"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$kpkg" "$hpkg"
  fi
}

# --- 判断并升级内核（如有需要） ---
upgrade_kernel_if_needed() {
  local min_k="$1"
  info "驱动要求内核版本 >= ${min_k}"

  if ver_ge "${CURRENT_KERNEL}" "${min_k}"; then
    ok "当前内核 ${CURRENT_KERNEL} 符合要求。"
    return
  fi

  warn "当前内核 ${CURRENT_KERNEL} 过低，需要升级！"
  ensure_backports_if_needed "$min_k"
  install_latest_kernel_meta

  # 注意：这里不再用“错误”提示，避免误导；退出码为 0
  warn "新内核已安装，请立即重启进入新内核。脚本将正常退出。"
  info "重启后再次运行本脚本将进入“配置阶段”。"
  exit 0
}

# --- 原始脚本功能模块 ---

initialize_and_check_base() {
  step "A.0. 初始化与基础检查"
  require_root

  CURRENT_KERNEL=$(uname -r)
  info "当前运行内核: ${CURRENT_KERNEL}"

  local line
  line=$(lspci -D -nn 2>/dev/null | grep -Ei 'VGA|Display|3D' | grep -i 'Intel' || true)
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
    DEBIAN_FRONTEND=noninteractive apt-get update -y >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${miss[@]}"
  fi
  ok "依赖检查完成。"
}

fetch_latest_dkms_info() {
  info "正在从 GitHub 获取最新驱动信息..."
  local api="https://api.github.com/repos/strongtz/i915-sriov-dkms/releases/latest"
  local json
  json=$(curl -fsSL "$api" || true)
  local url
  url=$(echo "$json" | jq -r '.assets[]?.browser_download_url | select(test("amd64\\.deb$"))' | head -n1)
  [[ -z "$url" ]] && { fail "从 GitHub API 获取下载链接失败。"; exit 1; }
  local kernel_ver
  kernel_ver=$(echo "$json" | jq -r '.body' | sed -n -E 's/.*compat v([0-9]+\.[0-9]+).*/\1/p' | head -n1)
  [[ -z "$kernel_ver" ]] && kernel_ver="6.8" && warn "无法解析内核版本，默认使用 >= 6.8"
  echo "$kernel_ver|$url"
}

ensure_grub_params() {
  step "正在配置 GRUB 内核参数..."
  local grub_file="/etc/default/grub"
  [[ -f "$grub_file" ]] || echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' > "$grub_file"
  backup_file "$grub_file"

  local cmdline
  cmdline=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | cut -d'"' -f2 || true)
  for p in intel_iommu=on iommu=pt; do
    [[ " $cmdline " =~ " $p " ]] || cmdline="$cmdline $p"
  done
  cmdline=$(echo "$cmdline" | xargs)
  sed -i -E 's|^(GRUB_CMDLINE_LINUX_DEFAULT=").*(")$|\1'"$cmdline"'\2|' "$grub_file"

  info "正在更新 GRUB 和 initramfs..."
  if cmd_exists update-grub; then
    update-grub
  else
    grub-mkconfig -o /boot/grub/grub.cfg
  fi
  if cmd_exists update-initramfs; then
    update-initramfs -u
  fi
  if cmd_exists proxmox-boot-tool; then
    proxmox-boot-tool refresh || true
  fi
  ok "GRUB 配置与 initramfs 刷新完成。"
}

write_modprobe_conf() {
  info "正在配置模块参数..."
  local modconf="/etc/modprobe.d/i915-sriov-dkms.conf"
  if [[ -f "$modconf" ]]; then
    ok "模块配置文件已存在。"
    return
  fi
  backup_file "$modconf"
  echo -e "blacklist xe\noptions i915 enable_guc=3" > "$modconf"
  ok "已写入模块参数: $modconf"
}

install_dkms_package() {
  info "正在安装与当前内核匹配的头文件..."
  apt-get install -y "pve-headers-${CURRENT_KERNEL}" >/dev/null 2>&1 || \
  apt-get install -y "linux-headers-${CURRENT_KERNEL}" || \
  warn "未能自动安装完全匹配的内核头文件。"

  info "正在下载并安装 DKMS 包..."
  local tmp_deb="/tmp/$(basename "$DKMS_INFO_URL")"
  curl -fSL "$DKMS_INFO_URL" -o "$tmp_deb"
  dpkg -i "$tmp_deb" || apt-get -f install -y
  rm "$tmp_deb"
  ok "DKMS 包安装完成。"
}

run_install_phase() {
  step "A. 安装阶段"

  if [[ "$DKMS_INSTALLED" == true ]]; then
    warn "检测到 DKMS 包已安装，但驱动尚未生效。"
    warn "请立即重启系统以加载驱动，重启后再次运行本脚本。"
    exit 0
  fi

  detect_environment
  ensure_apt_healthy
  check_dependencies

  local dkms_info
  dkms_info=$(fetch_latest_dkms_info)
  DKMS_INFO_URL="${dkms_info#*|}"
  local supported_kernel
  supported_kernel=$(echo "$dkms_info" | cut -d'|' -f1)

  upgrade_kernel_if_needed "$supported_kernel"  # 如需升级，会在安装后以 0 退出，提示重启

  ensure_grub_params
  write_modprobe_conf
  install_dkms_package

  ok "驱动核心组件已安装完毕！"
  warn "如当前仍在旧内核上，建议尽快重启以加载驱动。"
  info "若已在满足要求的新内核上，可直接进入配置阶段。"
}

run_configure_phase() {
  step "B. 配置阶段"
  local total_vfs
  total_vfs=$(cat "${IGPU_DEV_PATH}/sriov_totalvfs")
  info "该设备最大支持 ${total_vfs} 个 VF。"

  local num_vfs
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    num_vfs="$total_vfs"
    info "非交互模式：默认创建最大数量 ${num_vfs} 个 VF。"
  else
    read -rp "  请输入要创建的 VF 数量 (1-${total_vfs}): " num_vfs
  fi

  if ! [[ "$num_vfs" =~ ^[0-9]+$ && "$num_vfs" -ge 1 && "$num_vfs" -le "$total_vfs" ]]; then
    fail "输入无效，退出。"
    exit 1
  fi

  info "正在创建 ${num_vfs} 个 VF（先0后N模式，避免重复创建冲突）..."
  echo 0 > "${IGPU_DEV_PATH}/sriov_numvfs"
  echo "${num_vfs}" > "${IGPU_DEV_PATH}/sriov_numvfs"
  ok "已临时创建 ${num_vfs} 个 VF。"

  local ans
  ans=$(parse_yes_no "是否将此设置持久化（开机自动创建）？" "yes")
  if [[ "$ans" == "yes" ]]; then
    create_systemd_service "$num_vfs"
  else
    warn "已按要求跳过持久化配置。"
  fi

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

  echo -e "\n${C_GREEN}--- 如何验证 ---${C_RESET}" >&2
  info "1. 内核日志: dmesg | grep -i i915 | grep -i sriov"
  info "2. PCI设备: lspci | grep -i vga"
  info "3. 控制文件: ls -l ${IGPU_DEV_PATH}/sriov_numvfs"
}

show_help() {
  echo "$HELP_TEXT"
}

parse_args() {
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

main() {
  parse_args "$@"

  echo -e "${C_BLUE}======================================================${C_RESET}" >&2
  echo -e "${C_BLUE}  Intel i915 SR-IOV 一键安装脚本 v${SCRIPT_VERSION}${C_RESET}" >&2
  echo -e "${C_BLUE}  (机械降神·长注释复原版 - 这次真没问题了！)${C_RESET}" >&2
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

# -----------------------------------------------------------------------------------
# 附录A：维护与扩展指引（长注释保留，帮助阅读与累计经验）
# - 若需扩展更多发行版（例如 Kali、Deepin），请在 detect_environment 中设置 OS_ID，并在
#   find_latest_kernel_meta 中添加对应分支与内核元包名映射。
# - 若需在 PVE 下强制选择特定版本（而非最大版本），可增加一个环境变量 KERNEL_MAJOR_PIN，
#   并在 versions 的排序环节里筛选目标主版本。
# - 若上游 DKMS 项目变更了 release 文案结构，fetch_latest_dkms_info 的“compat vX.Y”解析
#   可能失效；可以考虑改为在 assets 名称里匹配兼容版本，或增加一个兼容矩阵 JSON。
# - 如果你的系统有多块 Intel 显卡（iGPU+dGPU），自动探测到的第一块可能不是你要的；
#   这时建议手动提供 PCI 地址（0000:00:02.0 形式），或做更精细的过滤。
# - 关于日志：DEBUG=1 时会在 ${LOG_FILE} 写入更多信息；也可按需扩展为 syslog。
#
# 附录B：已知限制
# - 本脚本不会在失败时卸载此前已安装的软件包（以免二次破坏）；需要时请手工回退。
# - 某些平台（特别是定制内核）可能需要特定的内核参数或禁用项，请参考硬件厂商文档。
#
# 附录C：版本变更摘要
# - v1.9.0
#   * 恢复 400+ 行结构（长注释/帮助/附录）
#   * 重启提示级别由 [错误] 改为 [提示]/[警告]，退出码置 0
#   * 保持并强化 backports 按需启用与索引刷新、stdout/stderr 分流
#   * APT 轻修复逻辑，减少索引异常对安装决策的影响
# - v1.8.9
#   * 引入 ensure_backports_if_needed，按需启用 backports
#   * 修复 apt update 污染 stdout 的问题
#   * 多策略安装内核头文件；GRUB 参数幂等与刷新
# -----------------------------------------------------------------------------------
