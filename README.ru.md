# Xray VPS Kit (кратко по-русски)

Установщик Xray-core (VLESS + REALITY + XTLS Vision, TCP 443) для VPS и команда `xray-client` для
управления клиентами. Полная документация на английском: [README.md](README.md).

## Требования

Debian 12/13 или Ubuntu 22.04/24.04, systemd и apt, root, публичный IPv4 и открытый TCP-порт
(по умолчанию 443; откройте его и в файрволе хостера). amd64 или arm64 (arm64 нативно не проверялся).

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/install.sh | bash -s -- --first-client user_01
```

Скрипт при необходимости ставит `git` и зависимости, клонирует кит в `/opt/xray-vps-kit-src`, спрашивает
порт и SNI (Enter — значения по умолчанию) и в конце печатает URI и QR-код первого клиента.
Для автоматизации добавьте `--non-interactive`. Установить код конкретного тега или коммита:
`... | XVK_REF=v0.1.1 bash -s -- ...`.

## Клиенты

```bash
xray-client add NAME [--fp firefox]   # создать клиента, показать URI и QR
xray-client list                      # список
xray-client show NAME                 # показать URI и QR ещё раз
xray-client remove NAME               # отозвать клиента
xray-client doctor [--probe-reality]  # проверка сервера (ключи и URI не печатает); --probe-reality — пробное REALITY-соединение через временный клиент
xray-client recover                   # откатить изменение, прерванное сбоем или отключением питания
```

Одно устройство — один клиент. Если клиент подключается лишь иногда, попробуйте `--fp firefox`.
`add` и `remove` перезапускают Xray, подключённые клиенты на секунды теряют связь.

## Обновление и удаление

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/update.sh | bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/uninstall.sh | bash
```

`update.sh --check` только сообщает о новой версии, `--rollback` возвращает предыдущую.
`uninstall.sh --keep-config` сохраняет ключи и клиентов (потом `install.sh --restore`);
`--purge-preserved` удаляет сохранённое окончательно. Если GitHub недоступен, удаление использует
копию, установленную вместе с китом (нужен `--yes`).

## Автообновление ядра (по желанию, выключено по умолчанию)

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/xray-vps-kit/master/auto-update.sh | bash -s -- enable
```

Раз в сутки в 03:MM по времени сервера (минута выбирается случайно один раз) проверяется
официальный стабильный релиз Xray-core; он ставится, только если ему не меньше трёх дней.
`... auto-update.sh status|run|disable` — состояние, проверка сейчас, выключение.

## block-ping

`block-ping on` отбрасывает входящие ICMP echo-запросы на внешнем интерфейсе (собственная таблица
nftables, переживает перезагрузку и `systemctl reload nftables`), `block-ping off` убирает блокировку.
Это лишь один из признаков туннеля, от всех видов обнаружения он не защищает.

## Безопасность

Об уязвимостях сообщайте приватно: см. [SECURITY.md](SECURITY.md). Изменения: [CHANGELOG.md](CHANGELOG.md).
