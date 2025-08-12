version: "3.8"

  # 用于与海外 VPS (如甲骨文日本) 同步的 Syncthing 实例
  syncthing-vps:
    image: syncthing/syncthing:latest                     # 使用最新版 Syncthing 镜像
    container_name: syncthing                             # 容器名称
    environment:
      - PUID=1000                                         # 容器内运行用户的 UID
      - PGID=1000                                         # 容器内运行用户的 GID
      - TZ=Asia/Shanghai                                  # 时区设置
      # 【最终修正】根据官方协议与Passwall2情报分析，代理环境变量必须是全小写的 "all_proxy"，
      # 且必须指向提供代理服务的路由器IP(假设为192.168.1.198)及其全局Socks监听端口(1092)。
      - all_proxy=socks5://192.168.9.198:1092
      # 【指令正确】强制走代理不回退，确保所有通信都通过安全信道
      - ALL_PROXY_NO_FALLBACK=0
    volumes:
      - /opt/syncthing/vps-config:/config                 # 配置文件目录映射（持久化同步设置）
      - /srv/media/03_Received:/sync_received             # 同步接收的文件夹挂载到容器内
    ports:
      - 8385:8384                                         # Syncthing Web 管理界面端口（用于管理此实例，注意端口不与 LAN 冲突）
      - 22001:22000                                       # 同步数据端口（与 LAN 实例不冲突）
      - 21028:21027/udp                                   # 设备发现广播用端口（UDP，避免端口冲突）
    restart: always
