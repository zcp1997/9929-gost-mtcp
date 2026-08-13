9929-gost-mtcp quick start

项目只有一个安装入口：根目录 install.sh。
CN 和 Remote 目录下没有、也不需要单独的安装脚本。

建议顺序：
  1. 先安装 Remote，记录公网 IPv4 和 MTCP 端口
  2. 再安装中国大陆 CN

两台服务器都上传完整项目，然后执行：

  cd /root/9929-gost-mtcp
  bash install.sh

根据当前服务器选择：

  1) CN      中国大陆入口 / 路径优选端
  2) Remote  境外 Relay 端

也可以直接指定：

  bash install.sh remote
  bash install.sh cn

Remote 默认监听 6600/tcp。
kr、us 是 Remote 节点/线路别名，不是 CN 地区。
多条 Remote 线路必须使用不同的 CN 业务端口和 Anchor 端口。

不要 enable CN 的 Anchor unit，它必须由 Prewarm/Watchdog 控制。
详细说明见 README.md。
