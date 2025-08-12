PVE 下 Intel i915 核显 SR-IOV 直通完整教程（基于官方文档校对与增强）
本教程以官方英文文档为基准校对，结合实践补充为一篇“可直接操作”的正式教程。适用于在 Proxmox VE（PVE）等环境中，为 Intel iGPU 启用 SR-IOV 并直通到 Linux/Windows 客户机。

强烈警告：

本项目为高度实验性，请在理解风险的前提下使用。
必须在“宿主机”和“Linux 客户机”都安装同一版本的 i915 SR-IOV DKMS 模块！
切勿将 PF（物理功能，通常为 0000:00:02.0）直通到 VM，否则会导致所有 VF 崩溃。
1. 支持范围与准备工作
代码来源与说明：
模块基于 https://github.com/intel/mainline-tracking/tree/linux/v6.12 的 i915 快照，并随机合并 linux-stable 的补丁。
项目仓库与发布页：https://github.com/strongtz/i915-sriov-dkms
支持内核：6.8–6.15(-rc5)
已测试示例：
Arch Linux：6.12.10-zen1 / 6.11.9-arch1 / 6.10.9-arch1 / 6.9.10-arch1 / 6.8.9-arch1
PVE 宿主：6.8
Ubuntu 客户：24.04（内核 6.8）
建议硬件/固件准备：
主板 BIOS 开启 VT-d/Intel IOMMU（不同厂商名称可能为“Intel Virtualization for Directed I/O”、“IOMMU”等）。
建议使用 Alder/Raptor Lake 及更新平台的核显。部分低功耗 SoC（如 N100）可用 VF 数量与稳定性受限。
2. 检查当前环境（内核版本、核显与设备地址）
在宿主机（PVE）与客户机（Linux）中都建议先确认以下信息。

检查当前内核版本（决定要安装的 headers 与 DKMS 目标内核）
bash

复制
uname -r
# 或
uname -a
检查核显的 PCI 设备信息（厂商/设备 ID 与总线地址）
bash

复制
# 列出 VGA/Display 设备，记录设备地址（如 0000:00:02.0）与厂商/设备 ID（8086:xxxx）
lspci -nn | grep -E 'VGA|Display'
常见 Intel 厂商 ID 为 8086（示例输出：00:02.0 VGA compatible controller [0300]: Intel Corporation ... [8086:46a6]）。
PF 通常在 0000:00:02.0，创建 VF 后会出现 0000:00:02.1 ～ 0000:00:02.7。
在 PVE 上查看已安装与运行的内核（可选）
bash

复制
pveversion -v | grep -E 'proxmox|kernel|headers'
3. 必要内核参数与模块配置
必需参数（宿主机强制，客户机按需）：
intel_iommu=on
i915.enable_guc=3
i915.max_vfs=7
module_blacklist=xe
有两种配置方式，二选一：

方式 A：写入 GRUB 内核命令行（简单直观）
方式 B：通过 modprobe 配置（更细粒度，除 intel_iommu=on 外均可用该方式）
方式 A（GRUB）示例：

bash

复制
sudo nano /etc/default/grub
# 追加或设置（宿主机示例）：
# GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on i915.enable_guc=3 i915.max_vfs=7 module_blacklist=xe"

sudo update-grub
sudo update-initramfs -u
方式 B（modprobe）示例：

bash

复制
# 宿主机与客户机均可使用（intel_iommu=on 仍建议在宿主机通过 GRUB 设置）
sudo tee /etc/modprobe.d/i915-sriov-dkms.conf >/dev/null << 'EOF'
blacklist xe
options i915 enable_guc=3
options i915 max_vfs=7
EOF
4. 安装 i915 SR-IOV 驱动模块
你可以按发行版选择发行包安装，也可以用通用 DKMS 流程手动安装。

4.1 PVE 宿主机（测试内核 6.8）
安装构建工具
bash

复制
sudo apt update
sudo apt install -y build-* dkms
安装内核与头文件（按你的目标内核版本选择；以下为官方示例）
bash

复制
# 示例：6.8 分支（unsigned 内核）
sudo apt install -y proxmox-headers-6.8 proxmox-kernel-6.8
从 Releases 下载并安装 .deb（以 2025.07.22 为例）
bash

复制
wget -O /tmp/i915-sriov-dkms_2025.07.22_amd64.deb \
  "https://github.com/strongtz/i915-sriov-dkms/releases/download/2025.07.22/i915-sriov-dkms_2025.07.22_amd64.deb"

sudo dpkg -i /tmp/i915-sriov-dkms_2025.07.22_amd64.deb
设置内核参数（参考第 3 节，任选一种方式）
bash

复制
# GRUB 方式（示例）
sudo nano /etc/default/grub
# GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on i915.enable_guc=3 i915.max_vfs=7 module_blacklist=xe"
sudo update-grub
sudo update-initramfs -u
开机自动创建 VF（推荐）
bash

复制
sudo apt install -y sysfsutils

# 假设核显在 0000:00:02.0（如不同请用 lspci -nn 确认）
echo 'devices/pci0000:00/0000:00:02.0/sriov_numvfs = 7' | sudo tee /etc/sysfs.conf
重启系统
bash

复制
sudo reboot
验证驱动与 VF
bash

复制
# 查看 i915 初始化日志
dmesg | grep -i i915

# 查看 PF/VF 设备与驱动占用情况
lspci -nnk | grep -A3 -E 'VGA|Display'

# 也可查看 PF 节点是否具备 SR-IOV 属性
ls /sys/bus/pci/devices/0000:00:02.0/ | grep sriov
# 结果应包含：sriov_numvfs、sriov_totalvfs 等
提示：

某些低功耗平台（如 N100）在创建过多 VFs 时可能不稳定或性能下降。建议按需设置数量，如 1～3。
不要将 PF（0000:00:02.0）直通给客户机。
4.2 Linux 客户机（Ubuntu 24.04 / 内核 6.8 实测）
安装构建工具与内核组件
bash

复制
sudo apt update
sudo apt install -y build-* dkms linux-headers-$(uname -r) linux-modules-extra-$(uname -r)
安装 .deb（与宿主机相同版本）
bash

复制
wget -O /tmp/i915-sriov-dkms_2025.07.22_amd64.deb \
  "https://github.com/strongtz/i915-sriov-dkms/releases/download/2025.07.22/i915-sriov-dkms_2025.07.22_amd64.deb"

sudo dpkg -i /tmp/i915-sriov-dkms_2025.07.22_amd64.deb
设置最小内核参数（客户机示例）
bash

复制
sudo nano /etc/default/grub
# 建议：
# GRUB_CMDLINE_LINUX_DEFAULT="i915.enable_guc=3 module_blacklist=xe"
# 如你的环境/平台需要，也可加入 intel_iommu=on

sudo update-grub
sudo update-initramfs -u
sudo reboot
验证客户机识别 VF
bash

复制
dmesg | grep -i i915
lspci -nnk | grep -A3 -E 'VGA|Display'   # 确认 VF 正在使用 i915 且 xe 已被黑名单
可选：多媒体/计算库
bash

复制
sudo apt install -y vainfo
vainfo

sudo apt install -y intel-opencl-icd clinfo
clinfo
4.3 其他发行版
Arch Linux（测试内核 6.12.6-zen1）

AUR 包：i915-sriov-dkms
或从发布页下载后：
bash

复制
sudo pacman -U ./i915-sriov-dkms-*.pkg.tar.*
NixOS（测试内核 6.12.36）

模块作为 NixOS module + overlay 提供于 pkgs.i915-sriov：
nix

复制
boot.extraModulePackages = [ pkgs.i915-sriov ];
按第 3 节配置内核参数或 modprobe 选项与黑名单。
5. 手动 DKMS 安装（通用方法）
适用于未覆盖到的发行版或自定义场景。

bash

复制
# 1) 安装构建工具与 DKMS
# Debian/Ubuntu
sudo apt update
sudo apt install -y build-essential dkms git

# Arch
sudo pacman -S --needed base-devel dkms git

# 2) 安装当前运行内核的头文件
# Debian/Ubuntu
sudo apt install -y linux-headers-$(uname -r)

# Arch
sudo pacman -S --needed linux-headers

# 3) 克隆仓库并加入 DKMS
git clone https://github.com/strongtz/i915-sriov-dkms.git
cd i915-sriov-dkms
sudo dkms add .

# 4) 安装模块（版本号以发布为准；也可用 VERSION 文件）
sudo dkms install i915-sriov-dkms/2025.07.22
# 或
sudo dkms install -m i915-sriov-dkms -v $(cat VERSION)

# 5) 配置内核参数（参考第 3 节：GRUB 或 modprobe 二选一）

# 6) 可选：开机自动创建 VF（以 7 个为例）
sudo apt install -y sysfsutils
echo 'devices/pci0000:00/0000:00:02.0/sriov_numvfs = 7' | sudo tee /etc/sysfs.conf

# 7) 重启
sudo reboot
如 DKMS 安装失败，可重试：

bash

复制
sudo dkms remove i915-sriov-dkms/2025.07.22 --all
sudo dkms install i915-sriov-dkms/2025.07.22
6. 创建与管理 VF
临时创建（重启后失效）：
bash

复制
# 根据需要将 1 改为 1～7
echo 1 | sudo tee /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs
开机自动创建（持久化）：
bash

复制
sudo apt install -y sysfsutils
echo 'devices/pci0000:00/0000:00:02.0/sriov_numvfs = 7' | sudo tee /etc/sysfs.conf
验证创建结果：
bash

复制
lspci -nnk | grep -A3 -E 'VGA|Display'
# 应看到 0000:00:02.1 ~ 0000:00:02.7 等 VF，且由 i915 驱动或 vfio-pci 绑定（取决于你的直通方式）
7. 在 PVE 中直通 VF 给 VM/LXC
重要规则：
只直通 VF（如 0000:00:02.1），绝不可直通 PF（0000:00:02.0）。
直通给 LXC 或 QEMU VM 均可。
QEMU VM 配置示例（Windows VM 参见第 8 节，Linux VM 直通同理）：
ini

复制
# /etc/pve/qemu-server/<VMID>.conf 中添加（示例 VF 地址为 0000:00:02.1）：
hostpci0: 0000:00:02.1,pcie=1
# Windows 需要 GOP ROM 与 x-vga（详见第 8 节）
如你采用传统 VFIO 流程绑定设备，也可在宿主机加载 VFIO 模块（对 iGPU VF 一般非必需）：
bash

复制
# 可选，仅当你需要基于 vfio-pci 的绑定/控制时
echo -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" | sudo tee -a /etc/modules
sudo update-initramfs -u
8. Windows 客户机（Proxmox 8.3 + Windows 11 24H2 实测）
为避免 Code 43 并确保所有驱动版本兼容，需要为 VF 指定合适的 Intel GOP EFI ROM。

8.1 提取并部署 GOP EFI 固件（在你的 PC 上完成）
下载 UEFITool（Windows 推荐 UEFITool_NE_A68_win64；也有 Linux/macOS 版本）
下载与你主板匹配的 BIOS（Alder/Raptor Lake 桌面平台 BIOS 均可尝试）
解压 BIOS（常见为 .cap）
以管理员运行 UEFITool，打开 BIOS 文件
搜索下列十六进制字符串：

复制
49006e00740065006c00280052002900200047004f0050002000440072006900760065007200
双击搜索结果以定位，右键高亮项选择“Extract body...”
保存为任意文件名（如 intelgopdriver_desktop.bin）
可校验 SHA256：
UHD 730/770（桌面）：131c32cadb6716dba59d13891bb70213c6ee931dd1e8b1a5593dee6f3a4c2cbd
ADL-N：FA12486D93BEE383AD4D3719015EFAD09FC03352382F17C63DF10B626755954B
将该文件上传至 PVE 宿主机的 /usr/share/kvm/，并可重命名为 Intelgopdriver_desktop.efi
8.2 创建与配置 Windows VM
创建 Windows 11 VM，CPU 类型设为 host
安装引导时可用本地账户（Shift+F10 -> OOBE\BYPASSNRO）
初次进入桌面，启用远程桌面（RDP），然后关机
编辑 VM 配置，直通 VF 并指定 ROM：
ini

复制
# /etc/pve/qemu-server/<VMID>.conf
# 直通 0000:00:02.1，指定 ROM 并开启 x-vga
hostpci0: 0000:00:02.1,pcie=1,romfile=Intelgopdriver_desktop.efi,x-vga=1
在 PVE 界面的 Hardware 里将 Display 设为 none
启动 VM，通过 RDP 登录并安装 Intel 显卡驱动（任意版本均可）
安装过程中可能出现黑屏，属正常；等待数分钟并观察 VM CPU 使用率后重启
重启后在设备管理器中确认 Intel Graphics 正常工作
9. 验证、诊断与常见问题
查看 i915 初始化与 VF 识别
bash

复制
dmesg | grep -i i915
确认 VF 与驱动绑定情况、xe 是否黑名单
bash

复制
lspci -nnk | grep -A3 -E 'VGA|Display'
# 期望：VF 使用 i915（Linux 客户机），宿主机上 xe 被 blacklist
检查 SR-IOV 接口是否存在
bash

复制
ls /sys/bus/pci/devices/0000:00:02.0/ | grep sriov
cat /sys/bus/pci/devices/0000:00:02.0/sriov_totalvfs
cat /sys/bus/pci/devices/0000:00:02.0/sriov_numvfs
多媒体/计算能力（Linux 客户机可选）
bash

复制
vainfo
clinfo
稳定性与性能建议
VF 数量越多，单个 VF 可用资源越少；如遇不稳定或性能不佳，减少 sriov_numvfs 再试。
某些平台上，为 VM 热插拔 VF 可能失败，建议关机/冷启动后再变更 VF 数量或直通配置。
10. 卸载模块
使用 dpkg 安装的：
bash

复制
sudo dpkg -P i915-sriov-dkms
使用 pacman 安装的：
bash

复制
sudo pacman -R i915-sriov-dkms
手动 DKMS：
bash

复制
sudo dkms remove i915-sriov-dkms/2025.07.22 --all
11. 附录：手动创建 VF 与回收
创建/调整 VF 数量（即时生效）
bash

复制
# 设置为 1～7
echo 3 | sudo tee /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs
回收所有 VF（先关闭/解绑使用这些 VF 的 VM）
bash

复制
echo 0 | sudo tee /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs
12. 附录：Arch/NixOS 快速参考
Arch（AUR）
bash

复制
paru -S i915-sriov-dkms   # 或 yay/pikaur 等 AUR 助手
# 或从 Releases 下载后：
sudo pacman -U ./i915-sriov-dkms-*.pkg.tar.*
NixOS
nix

复制
# 在 configuration.nix
boot.extraModulePackages = [ pkgs.i915-sriov ];
# 另按第 3 节设置 i915 参数与 blacklist xe
13. 重要提醒与参考
宿主机与 Linux 客户机“都需要”安装 i915-sriov DKMS 模块（版本尽量一致）。
永远不要将 PF（0000:00:02.0）直通给 VM，只直通 VF（0000:00:02.1～）。
官方仓库与发布：
https://github.com/strongtz/i915-sriov-dkms
Intel mainline-tracking（v6.12）：https://github.com/intel/mainline-tracking/tree/linux/v6.12
致谢：resiliencer（见 issue #225），另可参考 issue #8 的评论。
