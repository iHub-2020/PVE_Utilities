# PVE 超强工具集 (PVE_Utilities)
各位，这个仓库是 PVE 用户的实用“工具箱”。这里面放的是我整理的、能一键解决常见问题的高效脚本，目标就是把各种复杂、繁琐的 PVE 配置操作，变成一行命令即可完成的顺畅体验。

告别重复劳动，把时间留给更重要的事情！

---

1. PVE 网页 UI 增强脚本 (pve-enhance.sh)
这个脚本可以为你的 PVE Web 界面启用“增强功能”，让你在节点概要里直接看到关键硬件状态，同时移除烦人的订阅提示。

### 主要功能
*   **实时硬件监控**：在 PVE 节点概要页面直接显示 CPU 的**温度**、**实时频率**和**功耗 (Package Power)**。
*   **硬盘信息展示**：自动检测并展示所有 **NVMe** 和 **SATA (SSD/HDD)** 硬盘的型号、温度、通电时间和健康度信息。对于休眠中的机械硬盘，会智能地显示“休眠中”状态而不会将其唤醒。
*   **移除订阅提示**：移除每次登录都会弹出的“无有效订阅”提示框。
*   **智能适配**：脚本会自动检测 PVE 版本，动态调整 UI，并提供完善的备份与还原能力。

### 一键安装与执行
下面这行命令是“完整流程”，它会先尝试从 GitHub 官方直接下载脚本，如果失败（比如网络问题），会自动切换到国内镜像下载。下载后赋予执行权限，并以 `remod` 模式运行，确保无论你是首次安装还是覆盖升级，都能一步到位。

直接在 PVE 的 Shell 中执行：

```bash
(curl -Lf -o /tmp/pve.sh https://raw.githubusercontent.com/iHub-2020/PVE_Utilities/main/pve-enhance.sh || curl -Lf -o /tmp/pve.sh https://mirror.ghproxy.com/https://raw.githubusercontent.com/iHub-2020/PVE_Utilities/main/pve-enhance.sh) && chmod +x /tmp/pve.sh && /tmp/pve.sh remod
```
执行完毕后，按 `Shift+F5` 强制刷新你的浏览器页面，就能看到效果了。

### 脚本参数说明
*   `bash /tmp/pve.sh`：首次安装时使用。
*   `bash /tmp/pve.sh remod`：推荐使用。强制重新安装，当你更新了脚本或者 PVE 版本后，用这个命令来覆盖更新。
*   `bash /tmp/pve.sh restore`：一键还原。如果你不想要这些功能了，执行此命令会彻底卸载脚本，将所有文件恢复到 PVE 的原始状态。

---

## 2. Intel 核显 SR-IOV 一键配置脚本 (setup-i915-sriov.sh)
这是一款更智能、省心的 Intel 核显 SR-IOV 配置脚本。无论是在 PVE 宿主机上，还是在 Debian/Ubuntu 虚拟机里，它都能把繁琐步骤自动化完成。

### 核心特性
*   **全自动适配**：能自动判断当前环境是 **PVE 宿主机** 还是 **虚拟机**，并执行相应逻辑。
*   **动态版本探测**：
    *   自动从上游 GitHub 仓库获取最新的 DKMS 驱动包**。
    *   自动解析上游项目的 README 文件，获取当前驱动支持的 Linux 内核版本范围**。
*   **智能内核管理**：
    *   检查当前内核版本；若不在支持范围内，会提示并引导自动升级到合适版本。
    *   自动搜索并安装匹配的内核头文件（linux-headers），满足 DKMS 编译需求。
    *   提供**交互式的旧内核清理功能，并允许保留一个备用旧内核，降低风险。
*   **完整配置**：自动配置 GRUB 的内核启动参数（如 intel_iommu=on），以及 modprobe 的模块参数（如 blacklist xe, max_vfs 等）。
*   **交互式引导**：在关键步骤（如创建 VF 数量、配置模块参数）提供交互确认，让你全程可控。
*   **安全机制**：在修改系统文件前会自动创建备份。如发生错误，脚本会停止并自动回滚文件修改，最大限度保护系统稳定性。
### 一键启动
> **注意：** 这个脚本需要以 root 或 sudo 权限运行。下面的命令已经处理好了权限问题。

同样，这条命令也包含国内镜像作为备用下载路径。

```bash
(curl -Lf -o /tmp/sriov.sh https://raw.githubusercontent.com/iHub-2020/PVE_Utilities/main/setup-i915-sriov.sh || curl -Lf -o /tmp/sriov.sh https://mirror.ghproxy.com/https://raw.githubusercontent.com/iHub-2020/PVE_Utilities/main/setup-i915-sriov.sh) && chmod +x /tmp/sriov.sh && sudo /tmp/sriov.sh
```
### **【必读】重要执行流程说明 **
这个脚本具备较强的自动化能力，建议先了解它的执行逻辑：

1. **首次运行**：执行上述命令后，脚本开始工作。
2. **内核检查**：脚本会检查你的内核版本。如果版本不满足驱动要求，会提示并在你同意后，自动安装合适的新内核。
3. **自动退出**：内核安装完成后，脚本会提示需要重启，然后自动退出。这是正常流程，因为新内核必须重启才能生效。
4. **重启系统**：根据提示，重启你的 PVE 主机或虚拟机。
5. **再次运行**：系统进入新内核后，你需要再次执行上述一键命令。这一次，脚本会检测到内核版本满足要求，并继续完成后续配置步骤。

简单说，整个过程通常需要你执行两次同样的命令，中间重启一次系统。

---
