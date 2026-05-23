# PortBridge

PortBridge — минимальный менеджер TCP/UDP port forwarding для схемы:

```text
Client -> Frontend VPS -> Backend IP:Port
```

Проект нужен, когда хочется использовать один VPS как входную точку, а реальный сервис держать на другом сервере.

## Возможные сценарии

```text
Frontend:443/tcp   -> Backend:443/tcp   для Xray/3x-ui/Trojan/VLESS
Frontend:443/udp   -> Backend:443/udp   для Hysteria2/TUIC/QUIC
Frontend:51820/udp -> Backend:51820/udp для WireGuard
Frontend:2222/tcp  -> Backend:22/tcp    для SSH
```

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Kuzz007/PortBridge/main/portbridge.sh) --install
```

После установки доступна команда:

```bash
portbridge
```

## Команды

```bash
portbridge --install
portbridge --add tcp IN_PORT TARGET_IP OUT_PORT
portbridge --add udp IN_PORT TARGET_IP OUT_PORT
portbridge --add-both IN_PORT TARGET_IP OUT_PORT
portbridge --list
portbridge --remove tcp IN_PORT
portbridge --remove udp IN_PORT
portbridge --purge
portbridge --doctor
portbridge --version
```

## Примеры

TCP bridge:

```bash
portbridge --add tcp 443 1.2.3.4 443
```

UDP bridge:

```bash
portbridge --add udp 51820 1.2.3.4 51820
```

TCP + UDP одновременно:

```bash
portbridge --add-both 443 1.2.3.4 443
```

Список правил:

```bash
portbridge --list
```

Удалить правило:

```bash
portbridge --remove tcp 443
portbridge --remove udp 51820
```

Удалить все правила PortBridge:

```bash
portbridge --purge
```

## Безопасность

PortBridge использует iptables comment-метки вида:

```text
portbridge:tcp:443:1.2.3.4:443
```

Благодаря этому `--remove` и `--purge` удаляют только правила, созданные PortBridge, и не трогают чужие iptables-правила.

## Проверка

```bash
portbridge --doctor
bash -n portbridge.sh
```

## Важно

Этот инструмент открывает входящие порты на frontend VPS и перенаправляет трафик на backend. Не открывай административные панели или SSH в интернет без дополнительной защиты: IP allowlist, VPN, Cloudflare Access, strong auth или firewall.
