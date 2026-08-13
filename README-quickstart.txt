9929-gost-mtcp quick start

项目只有一个安装入口：根目录 install.sh。
CN 和 Remote 目录下没有、也不需要单独的安装脚本。

建议顺序：
  1. 先安装 Remote，记录公网 IPv4 和 MTCP 端口
  2. 再安装中国大陆 CN

下载项目：

  CN（中国大陆，走 ghfast）：
    git clone https://ghfast.top/https://github.com/zcp1997/9929-gost-mtcp.git

  Remote（境外，直连 GitHub）：
    git clone https://github.com/zcp1997/9929-gost-mtcp.git

两台服务器进入项目根目录后执行：

  cd /root/9929-gost-mtcp
  bash install.sh

根据当前服务器选择：

  1) CN      中国大陆入口 / 路径优选端
  2) Remote  境外 Relay 端

也可以直接指定：

  bash install.sh remote
  bash install.sh cn

Remote 默认监听 6600/tcp。
CN 安装时会询问 RTT 快路准入阈值，默认 40ms，可自定义。
CN 安装完成后会自动 enable 并启动对应的主服务与 Watchdog。
CN 安装 GOST 时默认通过 ghfast.top 下载，Remote 默认直连 GitHub。
如需让 CN 强制直连：GITHUB_PROXY_PREFIX= bash install.sh cn
de、us 是 Remote 节点/线路别名，不是 CN 地区。
多条 Remote 线路必须使用不同的 CN 业务端口和 Anchor 端口。

别名 de 的事件日志：
  tail -n 30 /root/9929-gost-mtcp/cn/instances/de/state/events.jsonl

不要 enable CN 的 Anchor unit，它必须由 Prewarm/Watchdog 控制。
详细说明见 README.md。
