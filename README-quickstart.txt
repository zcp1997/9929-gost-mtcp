# 9929-gost-mtcp quick start

CN:
  cd /root/9929-gost-mtcp/cn
  bash install.sh
  systemctl enable --now 9929-gost-mtcp.service
  systemctl enable --now 9929-gost-mtcp-watchdog.service

JP:
  cd /root/9929-gost-mtcp/jp
  bash install.sh

不要 enable：
  9929-gost-mtcp-anchor.service

Anchor 必须由 CN 端的 Prewarm/Watchdog 控制。
详细说明见 README.md。
