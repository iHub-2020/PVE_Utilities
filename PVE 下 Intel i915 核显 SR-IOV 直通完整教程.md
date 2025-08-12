PVE 下 Intel i915 核显 SR-IOV 直通完整教程（正式版 | 含内核检查与升级）
本教程以官方英文文档为基准校对并扩展为“一步步可操作”的实战指南。适用于在 Proxmox VE（PVE）等环境中，为 Intel iGPU 启用 SR-IOV 并直通到 Linux/Windows 客户机。

强烈警告：

本项目为高度实验性，请仅在充分理解风险的前提下使用。
必须在“宿主机”和“Linux 客户机”都安装同一版本的 i915 SR-IOV DKMS 模块！
绝对不要将 PF（物理功能，通常为 0000:00:02.0）直通到 VM，否则会导致所有 VF 崩溃。
目录
支持范围与来源
步骤 0：检查并准备环境（内核版本、核显与设备地址）
步骤 1：配置必要内核参数与模块
步骤 2：在 PVE 宿主机安装 i915 SR-IOV 模块
步骤 3：创建并验证 SR-IOV 虚拟功能（VF）
步骤 4：在 Linux 客户机安装模块并验证
步骤 5：在 PVE 中将 VF 直通给 VM/LXC
步骤 6：Windows 客户机直通（避免 Code 43）
故障诊断与常见问题
卸载
附录 A：通用 DKMS 手动安装
附录 B：Arch / NixOS 快速参考
参考与致谢
支持范围与来源
代码来源：
基于 Intel mainline-tracking v6.12 的 i915 快照（https://github.com/intel/mainline-tracking/tree/linux/v6.12）
随机合并 linux-stable 补丁
项目仓库与发布页：
https://github.com/strongtz/i915-sriov-dkms
支持内核版本：
6.8–6.15(-rc5)
已测试示例：
Arch Linux：6.12.10-zen1 / 6.11.9-arch1 / 6.10.9-arch1 / 6.9.10-arch1 / 6.8.9-arch1
PVE 宿主：6.8
Ubuntu 客户：24.04（内核 6.8）
建议硬件/固件：
主板 BIOS 开启 VT-d / Intel IOMMU
Alder/Raptor Lake 及更新平台核显优先。低功耗 SoC（如 N100）可用 VF 数量与稳定性有限
步骤 0：检查并准备环境（内核版本、核显与设备地址）
检查当前运行内核版本（决定 headers 与 DKMS 目标）
bash

复制
uname -r
# 如需更多信息：
uname -a
判断是否在支持范围（6.8–6.15）
若不在范围内，请按下方“升级内核”执行（分别提供 PVE 宿主与 Ubuntu 客户两种方法）
在 PVE 上可以同时安装多个内核版本，重启时选择
检查核显的厂商/设备 ID 与总线地址（BDF）
bash

复制
# 记录设备地址（如 0000:00:02.0）与厂商/设备 ID（示例 8086:46a6）
lspci -nn | grep -E 'VGA|Display'
Intel 厂商 ID 通常为 8086
PF 常见地址为 0000:00:02.0（创建 VF 后会出现 0000:00:02.1 ～ 0000:00:02.7）
PVE 上查看当前内核/头文件（可选）
bash

复制
pveversion -v | grep -E 'proxmox|kernel|headers'
内核不符合时的升级方法
PVE 宿主机（示例安装 6.8 分支内核与头文件）
bash

复制
sudo apt update
# 安装或补齐 6.8 系列内核与 headers（以官方示例为准）
sudo apt install -y proxmox-kernel-6.8 proxmox-headers-6.8

# 如系统使用 systemd-boot（PVE 8 默认），可查看/固定内核（可选）
# 列出已安装内核：
proxmox-boot-tool kernel list
# 固定到当前正在运行内核（可选）：
# proxmox-boot-tool kernel pin 6.8.x-...-pve
# 取消固定（可选）：
# proxmox-boot-tool kernel unpin
安装完成后，重启并用 uname -r 确认已进入支持范围的内核。

Ubuntu 客户机（建议使用 HWE 以获取 6.8 系列）
bash

复制
sudo apt update
# 安装/升级到 HWE 内核（24.04 对应 6.8 系列）
sudo apt install -y linux-generic-hwe-24.04

# 或者按需安装特定版本（示例命名，需以实际仓库可用版本为准）：
# sudo apt install -y linux-image-6.8.0-xx-generic linux-headers-6.8.0-xx-generic

sudo reboot
# 重启后确认
uname -r
步骤 1：配置必要内核参数与模块
必需参数（宿主机必须，客户机按需）：

intel_iommu=on
i915.enable_guc=3
i915.max_vfs=7
module_blacklist=xe
两种配置方式（二选一）：

方式 A：写入 GRUB（简单直观）

bash

复制
sudo nano /etc/default/grub
# 建议将以下参数追加到 GRUB_CMDLINE_LINUX_DEFAULT：
# intel_iommu=on i915.enable_guc=3 i915.max_vfs=7 module_blacklist=xe

sudo update-grub
sudo update-initramfs -u
方式 B：modprobe（更细粒度，除 intel_iommu=on 外均可在此配置）

bash

复制
sudo tee /etc/modprobe.d/i915-sriov-dkms.conf >/dev/null << 'EOF'
blacklist xe
options i915 enable_guc=3
options i915 max_vfs=7
EOF
说明：

宿主机强烈建议通过 GRUB 启用 intel_iommu=on
其他参数可二选一配置在 GRUB 或 modprobe 中，不必重复
步骤 2：在 PVE 宿主机安装 i915 SR-IOV 模块
安装构建工具与依赖
bash

复制
sudo apt update
sudo apt install -y build-* dkms
安装目标内核与头文件（与当前/目标内核匹配；示例为 6.8）
bash

复制
sudo apt install -y proxmox-kernel-6.8 proxmox-headers-6.8
从 Release 下载并安装 .deb（示例版本 2025.07.22）
bash

复制
wget -O /tmp/i915-sriov-dkms_2025.07.22_amd64.deb \
  "https://github.com/strongtz/i915-sriov-dkms/releases/download/2025.07.22/i915-sriov-dkms_2025.07.22_amd64.deb"

sudo dpkg -i /tmp/i915-sriov-dkms_2025.07.22_amd64.deb
设置内核参数（参考“步骤 1”，GRUB 或 modprobe 二选一）

重启进入目标内核（若刚更换内核）

bash

复制
sudo reboot
可选：验证模块支持 SR-IOV 相关选项
bash

复制
modinfo i915 | grep -i vf
步骤 3：创建并验证 SR-IOV 虚拟功能（VF）
临时创建（重启后失效）：将 N 替换为 1～7
bash

复制
# 假设核显 PF 在 0000:00:02.0（用 lspci -nn 先确认）
echo 3 | sudo tee /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs
开机自动创建（推荐，持久化）
bash

复制
sudo apt install -y sysfsutils
echo 'devices/pci0000:00/0000:00:02.0/sriov_numvfs = 7' | sudo tee /etc/sysfs.conf
验证 VF 是否出现以及驱动绑定情况
bash

复制
# 查看 i915 初始化日志
dmesg | grep -i i915

# 查看 PF/VF 与驱动
lspci -nnk | grep -A3 -E 'VGA|Display'

# PF 目录中应包含 SR-IOV 属性文件
ls /sys/bus/pci/devices/0000:00:02.0/ | grep sriov
提示：

低功耗平台（如 N100）建议先从 1～3 个 VF 试起
此时切记：不要将 PF（0000:00:02.0）直通给 VM
步骤 4：在 Linux 客户机安装模块并验证
安装构建工具与内核组件
bash

复制
sudo apt update
sudo apt install -y build-* dkms linux-headers-$(uname -r) linux-modules-extra-$(uname -r)
安装与宿主机一致版本的 .deb
bash

复制
wget -O /tmp/i915-sriov-dkms_2025.07.22_amd64.deb \
  "https://github.com/strongtz/i915-sriov-dkms/releases/download/2025.07.22/i915-sriov-dkms_2025.07.22_amd64.deb"

sudo dpkg -i /tmp/i915-sriov-dkms_2025.07.22_amd64.deb
设置最小内核参数（客户机）
bash

复制
sudo nano /etc/default/grub
# 建议：
# GRUB_CMDLINE_LINUX_DEFAULT="i915.enable_guc=3 module_blacklist=xe"
# 如平台需要，也可加入 intel_iommu=on

sudo update-grub
sudo update-initramfs -u
sudo reboot
验证客户机已识别 VF 并使用 i915
bash

复制
dmesg | grep -i i915
lspci -nnk | grep -A3 -E 'VGA|Display'   # 确认 VF 正在使用 i915，且 xe 已被黑名单
可选：多媒体/计算库
bash

复制
sudo apt install -y vainfo
vainfo

sudo apt install -y intel-opencl-icd clinfo
clinfo
步骤 5：在 PVE 中将 VF 直通给 VM/LXC
只直通 VF（如 0000:00:02.1），绝不可直通 PF（0000:00:02.0）
直通给 LXC 或 QEMU VM 均可
QEMU VM 配置示例（Linux VM）：

ini

复制
# /etc/pve/qemu-server/<VMID>.conf
hostpci0: 0000:00:02.1,pcie=1
可选：若需要基于 vfio-pci 的统一绑定/控制（通常非必需）

bash

复制
echo -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" | sudo tee -a /etc/modules
sudo update-initramfs -u
步骤 6：Windows 客户机直通（避免 Code 43）
为确保所有版本 Intel 驱动正常工作并避免 Code 43，需要给 VF 指定合适的 Intel GOP EFI ROM。

6.1 提取并部署 GOP ROM
下载 UEFITool（Windows 建议 UEFITool_NE_A68_win64）
下载与你主板匹配的 BIOS（Alder/Raptor Lake 桌面平台通常可用）
解压 BIOS（常见为 .cap），管理员运行 UEFITool 并打开
搜索十六进制串：

复制
49006e00740065006c00280052002900200047004f0050002000440072006900760065007200
双击命中项并右键 “Extract body...” 导出
保存为任意文件名（如 intelgopdriver_desktop.bin）
校验 SHA256（可选）：
UHD 730/770（桌面）：131c32cadb6716dba59d13891bb70213c6ee931dd1e8b1a5593dee6f3a4c2cbd
ADL-N：FA12486D93BEE383AD4D3719015EFAD09FC03352382F17C63DF10B626755954B
上传到 PVE 宿主机 /usr/share/kvm/，重命名为 Intelgopdriver_desktop.efi（任意名）
6.2 配置 Windows VM
创建 VM，CPU 设为 host
安装阶段可用本地账号（Shift+F10 -> OOBE\BYPASSNRO）
首次进桌面后启用 RDP，然后关机
编辑 VM 配置，添加 VF 并指定 ROM 与 x-vga：
ini

复制
# /etc/pve/qemu-server/<VMID>.conf
hostpci0: 0000:00:02.1,pcie=1,romfile=Intelgopdriver_desktop.efi,x-vga=1
在 PVE 界面将 Display 设为 none
启动 VM，使用 RDP 安装 Intel 显卡驱动（任意版本）
安装过程中可能黑屏，等待数分钟后重启
重启后在设备管理器确认 Intel Graphics 正常工作
故障诊断与常见问题
查看 i915 初始化与 VF 识别：

bash

复制
dmesg | grep -i i915
确认 VF 绑定与 xe 黑名单：

bash

复制
lspci -nnk | grep -A3 -E 'VGA|Display'
检查 SR-IOV 接口：

bash

复制
ls /sys/bus/pci/devices/0000:00:02.0/ | grep sriov
cat /sys/bus/pci/devices/0000:00:02.0/sriov_totalvfs
cat /sys/bus/pci/devices/0000:00:02.0/sriov_numvfs
稳定性与性能建议：

VF 数量越多，单 VF 资源越少；如不稳定/性能差，降低 sriov_numvfs
不建议热插拔 VF；修改 VF 数量或直通配置后，冷启动更稳
卸载
使用 dpkg 安装：

bash

复制
sudo dpkg -P i915-sriov-dkms
使用 pacman 安装：

bash

复制
sudo pacman -R i915-sriov-dkms
手动 DKMS：

bash

复制
sudo dkms remove i915-sriov-dkms/2025.07.22 --all
附录 A：通用 DKMS 手动安装
适用于未覆盖的发行版或自定义场景。

bash

复制
# 1) 构建工具与 DKMS
# Debian/Ubuntu
sudo apt update
sudo apt install -y build-essential dkms git

# Arch
sudo pacman -S --needed base-devel dkms git

# 2) 安装当前运行内核的 headers
# Debian/Ubuntu
sudo apt install -y linux-headers-$(uname -r)

# Arch
sudo pacman -S --needed linux-headers

# 3) 克隆并加入 DKMS
git clone https://github.com/strongtz/i915-sriov-dkms.git
cd i915-sriov-dkms
sudo dkms add .

# 4) 安装模块（版本以发布为准，或读取 VERSION）
sudo dkms install i915-sriov-dkms/2025.07.22
# 或
sudo dkms install -m i915-sriov-dkms -v $(cat VERSION)

# 5) 配置内核参数（见“步骤 1”）

# 6) 持久化创建 VF（以 7 个为例）
sudo apt install -y sysfsutils
echo 'devices/pci0000:00/0000:00:02.0/sriov_numvfs = 7' | sudo tee /etc/sysfs.conf

# 7) 重启
sudo reboot
如 DKMS 安装失败，可重试：

bash

复制
sudo dkms remove i915-sriov-dkms/2025.07.22 --all
sudo dkms install i915-sriov-dkms/2025.07.22
附录 B：Arch / NixOS 快速参考
Arch（AUR）
bash

复制
paru -S i915-sriov-dkms   # 或 yay/pikaur
# 或从 Releases 下载后：
sudo pacman -U ./i915-sriov-dkms-*.pkg.tar.*
NixOS（测试内核 6.12.36）
nix

复制
# configuration.nix
boot.extraModulePackages = [ pkgs.i915-sriov ];
# 其他参数请按“步骤 1”配置（enable_guc/max_vfs 与 blacklist xe）
参考与致谢
项目与发布：https://github.com/strongtz/i915-sriov-dkms
Intel mainline-tracking（v6.12）：https://github.com/intel/mainline-tracking/tree/linux/v6.12
特别感谢 resiliencer（见 issue #225）与相关讨论（见 issue #8 评论）
温馨提示：将本文保存为 README.md 可直接用于 GitHub 仓库。
