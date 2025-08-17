#!/bin/bash
# Intel i915 SR-IOV 一键安装脚本
# Version: 1.9.1 (修复“无限重启”循环；加入候选版本预检；仅在实际升级时提示重启)
# 说明：过程日志走 stderr，可解析结果走 stdout，避免污染命令替换与外层自动化。

set -Eeuo pipefail

# ---------- 彩色输出 ----------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
step(){ echo -e "\n${C_BLUE}==>${C_RESET} ${C_YELLOW}$1${C_RESET}" >&2; }
ok(){   echo -e "${C_GREEN}  [成功]${C_RESET} $1" >&2; }
warn(){ echo -e "${C_YELLOW}  [提示]${C_RESET} $1" >&2; }
fail(){ echo -e "${C_RED}  [错误]${C_RESET} $1" >&2; }
info(){ echo -e "  [信息] $1" >&2; }

# ---------- 变量 ----------
readonly SCRIPT_VERSION="1.9.1"
readonly STATE_DIR="/var/tmp/i915-sriov-setup"
readonly BACKUP_DIR="${STATE_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"

DEBUG="${DEBUG:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
MIN_KERNEL_OVERRIDE="${MIN_KERNEL_OVERRIDE:-}"

IGPU_PCI_ADDR=""; IGPU_DEV_PATH=""
CURRENT_KERNEL=""
ENV_TYPE=""; OS_ID=""; OS_CODENAME=""
DKMS_INFO_URL=""; DKMS_INSTALLED=false
VF_CONTROL_FILE_EXISTS=false
CONFIG_FILES_TO_BACKUP=()

# ---------- 基础工具 ----------
require_root(){ [[ $EUID -eq 0 ]] || { fail "本脚本需要 root 权限"; exit 1; }; }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
ver_ge(){ dpkg --compare-versions "$1" ge "$2"; }
backup_file(){ local f="$1"; [[ -f "$f" ]] || return 0; mkdir -p "$(dirname "$BACKUP_DIR/$f")"; cp -a "$f" "$BACKUP_DIR/$f"; }

trap 'on_error' ERR
on_error(){
  local code=$? line="${BASH_LINENO[0]:-?}" cmd="${BASH_COMMAND:-?}"
  fail "脚本中断（行 $line）：$cmd；退出码 $code。尝试回滚配置文件……"
  for f in "${CONFIG_FILES_TO_BACKUP[@]}"; do
    [[ -f "$BACKUP_DIR/$f" ]] && cp -a "$BACKUP_DIR/$f" "$f" && info "已恢复: $f"
  done
  warn "注意：已安装的软件包不会自动卸载。"
  exit $code
}

# ---------- APT 健康检查 ----------
ensure_apt_healthy(){
  info "APT 索引更新中……"
  if ! apt-get update -y >&2; then
    warn "apt-get update 失败，尝试 clean/autoclean/--fix-missing ……"
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
    OS_ID="${ID:-debian}"
    OS_CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || true)}"
  else
    OS_ID="$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo debian)"
    OS_CODENAME="$(lsb_release -sc 2>/dev/null || echo bookworm)"
  fi
  info "操作系统: ${OS_ID} ${OS_CODENAME}"
}

# ---------- 解析/获取最低内核要求 ----------
fetch_latest_dkms_info(){
  info "查询 i915-sriov-dkms 最新发布信息……"
  local api="https://api.github.com/repos/strongtz/i915-sriov-dkms/releases/latest"
  local json; json="$(curl -fsSL "$api" || true)"
  local url; url="$(echo "$json" | jq -r '.assets[]?.browser_download_url | select(test("amd64\\.deb$"))' | head -n1)"
  [[ -n "$url" ]] || { fail "无法从 GitHub 获取 DKMS 安装包"; exit 1; }
  local kmin; kmin="$(echo "$json" | jq -r '.body' | sed -n -E 's/.*compat v([0-9]+\.[0-9]+).*/\1/p' | head -n1)"
  [[ -n "$kmin" ]] || kmin="6.8"
  echo "$kmin|$url"
}

# ---------- 版本字符串提取 ----------
kernel_numeric(){
  # 从例如 6.12.38-1~bpo12+1 中提取 6.12.38；从 proxmox-kernel-6.11 抽 6.11
  echo "$1" | grep -oE '[0-9]+(\.[0-9]+){1,2}' | head -n1
}

# ---------- 查询某通道候选版本 ----------
candidate_version_for(){
  # $1: 包名  $2: 通道（可空，例：bookworm-backports）
  local pkg="$1" target="${2:-}"
  if [[ -n "$target" ]]; then
    apt-cache -o APT::Default-Release="$target" policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
  else
    apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
  fi
}

# ---------- 根据环境选择元包 ----------
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
    if apt-cache show "$hwe" >/dev/null 2>&1; then
      kpkg="$hwe"; hpkg="$hhwe"
    else
      kpkg="linux-image-generic"; hpkg="linux-headers-generic"
    fi
    echo "${kpkg}|${hpkg}|${apt_target}"; return 0
  fi

  echo "||"; return 1
}

# ---------- 如需启用 backports ----------
ensure_backports_if_needed(){
  local min_k="$1"
  [[ "$OS_ID" == "debian" ]] || return 0
  local cand; cand="$(candidate_version_for linux-image-amd64)"
  local cand_num; cand_num="$(kernel_numeric "$cand")"
  if ver_ge "${cand_num:-0}" "$min_k"; then
    ok "stable 候选 $cand_num 已满足 ≥ $min_k"
    return 0
  fi
  if ! grep -Rq " ${OS_CODENAME}-backports " /etc/apt/sources.list /etc/apt/sources.list.d/ >/dev/null 2>&1; then
    local ans="n"
    if [[ "$ASSUME_YES" == "1" ]]; then ans="y"; else read -rp "  启用 ${OS_CODENAME}-backports 获取更新内核？[y/N]: " ans; fi
    [[ "$ans" =~ ^[Yy]$ ]] || { warn "未启用 backports，可能无法满足内核版本要求。"; return 0; }
    echo "deb http://deb.debian.org/debian ${OS_CODENAME}-backports main contrib non-free-firmware" >/etc/apt/sources.list.d/backports.list
    ensure_apt_healthy
  fi
}

# ---------- 仅当确有更高版本可装时才安装 ----------
install_latest_kernel_meta(){
  local trio; trio="$(find_latest_kernel_meta)" || { fail "无法解析内核元包"; exit 1; }
  local kpkg hpkg target; kpkg="${trio%%|*}"; hpkg="$(echo "$trio" | cut -d'|' -f2)"; target="$(echo "$trio" | cut -d'|' -f3)"

  # 查询目标通道候选版本
  local cand ver_num; cand="$(candidate_version_for "$kpkg" "$target")"; ver_num="$(kernel_numeric "$cand")"
  [[ -n "$ver_num" ]] || { fail "无法获取 $kpkg 的候选版本"; exit 1; }

  info "目标通道 $(echo ${target:-stable}) 中 $kpkg 候选版本：$cand (解析为 $ver_num)"

  # 安装前后版本对比，决定是否需要安装
  local before="$(dpkg-query -W -f='${Version}' "$kpkg" 2>/dev/null || echo none)"
  if [[ "$before" != "none" ]]; then
    local before_num; before_num="$(kernel_numeric "$before")"
    if ver_ge "${before_num:-0}" "${ver_num:-0}"; then
      warn "$kpkg 已安装且版本 $before_num ≥ 候选 $ver_num，无需重复安装。"
      echo "NO_INSTALL"
      return 0
    fi
  fi

  local msg="安装 $kpkg 与 $hpkg（通道: ${target:-stable}）？[y/N]: "
  local ans="n"; [[ "$ASSUME_YES" == "1" ]] && ans="y" || read -rp "  $msg" ans
  [[ "$ans" =~ ^[Yy]$ ]] || { warn "用户取消安装。"; echo "NO_INSTALL"; return 0; }

  if [[ -n "$target" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get -y -t "$target" install "$kpkg" "$hpkg"
  else
    DEBIAN_FRONTEND=noninteractive apt-get -y install "$kpkg" "$hpkg"
  fi

  echo "INSTALLED"
}

# ---------- 内核升级决策（修复循环的关键） ----------
upgrade_kernel_if_needed(){
  local min_k="${1}"
  [[ -n "$MIN_KERNEL_OVERRIDE" ]] && { warn "使用 MIN_KERNEL_OVERRIDE=$MIN_KERNEL_OVERRIDE 覆盖最低要求"; min_k="$MIN_KERNEL_OVERRIDE"; }

  info "最低内核要求：≥ $min_k"
  if ver_ge "$(kernel_numeric "$(uname -r)")" "$min_k"; then
    ok "当前内核 $(uname -r) 已满足要求。"
    return 0
  fi

  # 尝试启用 backports（如需要）
  ensure_backports_if_needed "$min_k"

  # 预先判断目标通道“能否满足要求”
  local trio; trio="$(find_latest_kernel_meta)" || { fail "无法解析内核元包"; exit 1; }
  local kpkg hpkg target; kpkg="${trio%%|*}"; hpkg="$(echo "$trio" | cut -d'|' -f2)"; target="$(echo "$trio" | cut -d'|' -f3)"
  local cand ver_num; cand="$(candidate_version_for "$kpkg" "$target")"; ver_num="$(kernel_numeric "$cand")"

  if [[ -z "$ver_num" ]]; then
    fail "无法获取 $kpkg 在 ${target:-stable} 的候选版本。"
    exit 1
  fi

  if ! ver_ge "$ver_num" "$min_k"; then
    fail "当前软件源可获得的最高内核为 $ver_num（通道：${target:-stable}），低于所需 $min_k，无法满足。"
    warn "可选方案：1) 切换到更新发行版/通道（例如 Debian testing/unstable 或 PVE 新版内核）；2) 使用第三方内核（如 Liquorix，需自评风险）；3) 手动设置 MIN_KERNEL_OVERRIDE=6.12 以继续（不推荐）。"
    exit 1
  fi

  # 真正执行安装，并仅在“确实安装了新内核”时提示重启
  local res; res="$(install_latest_kernel_meta)"
  if [[ "$res" == "INSTALLED" ]]; then
    warn "已安装新内核，请重启系统进入新内核后再次运行脚本。"
    exit 0
  fi

  # 没有安装任何内核（已是候选或用户取消）
  if ver_ge "$(kernel_numeric "$(uname -r)")" "$min_k"; then
    ok "当前内核已满足要求。"
    return 0
  fi

  fail "未安装新内核且当前内核仍低于要求（≥$min_k）。为避免误导，脚本不会再提示重启。请按上述“可选方案”调整后再试。"
  exit 1
}

# ---------- 其它步骤（保持不变/小幅整理） ----------
ensure_grub_params(){
  step "配置 GRUB 内核参数"
  local grub_file="/etc/default/grub"; [[ -f "$grub_file" ]] || echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' > "$grub_file"
  backup_file "$grub_file"; CONFIG_FILES_TO_BACKUP+=("$grub_file")
  local cmdline; cmdline="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | cut -d'"' -f2 || true)"
  for p in intel_iommu=on iommu=pt; do [[ " $cmdline " =~ " $p " ]] || cmdline="$cmdline $p"; done
  cmdline="$(echo "$cmdline" | xargs)"
  sed -i -E 's|^(GRUB_CMDLINE_LINUX_DEFAULT=").*(")$|\1'"$cmdline"'\2|' "$grub_file"
  if cmd_exists update-grub; then update-grub; else grub-mkconfig -o /boot/grub/grub.cfg; fi
  cmd_exists update-initramfs && update-initramfs -u
  cmd_exists proxmox-boot-tool && proxmox-boot-tool refresh || true
  ok "GRUB/Initramfs 刷新完成。"
}

write_modprobe_conf(){
  info "写入模块参数……"
  local modconf="/etc/modprobe.d/i915-sriov-dkms.conf"
  [[ -f "$modconf" ]] && { ok "模块参数已存在"; return; }
  backup_file "$modconf"; CONFIG_FILES_TO_BACKUP+=("$modconf")
  echo -e "blacklist xe\noptions i915 enable_guc=3" > "$modconf"
  ok "模块参数写入完成。"
}

install_dkms_package(){
  info "安装与当前内核匹配的头文件（尽力而为）……"
  apt-get install -y "pve-headers-$(uname -r)" >/dev/null 2>&1 || \
  apt-get install -y "linux-headers-$(uname -r)" || \
  warn "未能安装到完全匹配的头文件（如后续 DKMS 构建失败，请先解决头文件问题）"
  info "下载并安装 DKMS 包……"
  local tmp="/tmp/$(basename "$DKMS_INFO_URL")"
  curl -fSL "$DKMS_INFO_URL" -o "$tmp"
  dpkg -i "$tmp" || apt-get -f install -y
  rm -f "$tmp"
  ok "DKMS 包安装完成。"
}

initialize_and_check_base(){
  step "A.0. 初始化与基础检查"
  require_root
  CURRENT_KERNEL="$(uname -r)"; info "当前运行内核: $CURRENT_KERNEL"
  local line; line="$(lspci -D -nn 2>/dev/null | grep -Ei 'VGA|Display|3D' | grep -i 'Intel' || true)"
  IGPU_PCI_ADDR="$(echo "$line" | awk '{print $1}' | head -n1 || true)"
  if [[ -z "$IGPU_PCI_ADDR" ]]; then read -rp "未自动发现核显，请手输 PCI 地址(如 0000:00:02.0): " IGPU_PCI_ADDR; fi
  [[ -n "$IGPU_PCI_ADDR" ]] || { fail "未提供 iGPU PCI 地址"; exit 1; }
  IGPU_DEV_PATH="/sys/bus/pci/devices/${IGPU_PCI_ADDR}"; ok "核显: $IGPU_PCI_ADDR"
  [[ -f "${IGPU_DEV_PATH}/sriov_numvfs" ]] && { VF_CONTROL_FILE_EXISTS=true; info "SR-IOV 控制文件已存在"; }
  if cmd_exists dkms && dkms status 2>/dev/null | grep -q 'i915-sriov-dkms.*installed'; then DKMS_INSTALLED=true; fi
}

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

run_install_phase(){
  step "A. 安装阶段"
  detect_environment
  ensure_apt_healthy
  check_dependencies

  local info_line; info_line="$(fetch_latest_dkms_info)"
  local min_k="${info_line%%|*}"; DKMS_INFO_URL="${info_line#*|}"

  upgrade_kernel_if_needed "$min_k"   # 若确实安装了新内核，会提示重启并以 0 退出

  ensure_grub_params
  write_modprobe_conf
  install_dkms_package

  ok "驱动核心组件已安装。"
  if ! ver_ge "$(kernel_numeric "$(uname -r)")" "$min_k"; then
    warn "建议尽快重启到更高内核后再运行“配置阶段”。"
  fi
}

create_systemd_service(){
  local num="$1" svc="/etc/systemd/system/i915-sriov-vf.service"
  backup_file "$svc"; CONFIG_FILES_TO_BACKUP+=("$svc")
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

run_configure_phase(){
  step "B. 配置阶段"
  local total; total="$(cat "${IGPU_DEV_PATH}/sriov_totalvfs")"
  info "设备最大支持 VF 数量：$total"
  local n
  if [[ "$NONINTERACTIVE" == "1" ]]; then n="$total"; else read -rp "输入要创建的 VF 数量(1-$total): " n; fi
  [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=total)) || { fail "输入无效"; exit 1; }
  echo 0 > "${IGPU_DEV_PATH}/sriov_numvfs"
  echo "$n" > "${IGPU_DEV_PATH}/sriov_numvfs"
  ok "已临时创建 $n 个 VF。"
  local ans="y"; [[ "$ASSUME_YES" == "1" ]] || read -rp "是否持久化为开机自动创建？[Y/n]: " ans
  [[ "$ans" =~ ^[Nn]$ ]] || create_systemd_service "$n"
  finalize
}

finalize(){
  step "C. 完成与验证"
  ok "全部完成。验证建议："
  info "dmesg | grep -i i915 | grep -i sriov"
  info "lspci | grep -i vga"
  info "cat ${IGPU_DEV_PATH}/sriov_numvfs"
}

main(){
  echo -e "${C_BLUE}======================================================${C_RESET}" >&2
  echo -e "${C_BLUE}  Intel i915 SR-IOV 一键安装脚本 v${SCRIPT_VERSION}${C_RESET}" >&2
  echo -e "${C_BLUE}======================================================${C_RESET}" >&2

  initialize_and_check_base

  if [[ -f "${IGPU_DEV_PATH}/sriov_numvfs" ]]; then
    run_configure_phase
  else
    run_install_phase
  fi
}

main "$@"
