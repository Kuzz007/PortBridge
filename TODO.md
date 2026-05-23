# TODO

## Выполнено

- [x] Базовый `portbridge.sh`.
- [x] Установка глобальной команды `portbridge`.
- [x] Включение IPv4 forwarding.
- [x] Добавление TCP bridge.
- [x] Добавление UDP bridge.
- [x] Добавление TCP+UDP bridge.
- [x] Список правил PortBridge.
- [x] Удаление правила по protocol + input port.
- [x] Purge только правил с comment `portbridge:*`.
- [x] Doctor.
- [x] README.

## Следующие задачи

- [ ] Добавить JSON-статус.
- [ ] Добавить export/backup правил.
- [ ] Добавить restore из backup.
- [ ] Добавить nftables backend.
- [ ] Добавить allowlist source IP.
- [ ] Добавить systemd health-check.
- [ ] Добавить интеграционные тесты на Ubuntu.