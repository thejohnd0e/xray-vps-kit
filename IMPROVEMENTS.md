# xray-vps-kit: отчёт ревью и план улучшений

Дата: 2026-11-08. Версия: 0.1.1 (master, коммит 2c99bc8).
Метод: статическое чтение `lib/*`, входных скриптов, `xray-client`, `templates/`, CI и сверка с `аудит.txt`. Код не менялся, тесты не запускались. Пункты помечены «проверить», если нужна проверка на ВМ.

## 1. Исправлено с прошлого аудита (fcd3ef7)

- Восстановление воркера автообновления после неудачного refresh.
- Бандл-кандидат не удаляется, пока он выбран активным.
- `doctor` проверяет ownership и принадлежность слушающего сокета.
- Параллельные `xray-client add/remove` ставятся в очередь.
- Установленный воркер распознаётся при относительном запуске и через симлинк.

## 2. Новые недостатки

| # | Приоритет | Проблема | Где |
|---|-----------|----------|-----|
| 1 | P1 | `Restart=on-failure` + `StartLimitBurst=3` за 60 с: после 3 падений systemd перестаёт перезапускать Xray, доступ к VPS через прокси теряется до ручного вмешательства. Нужно `Restart=always`, `RestartSec=5`, `StartLimitIntervalSec=0`. | `templates/xray-vps-kit.service` |
| 2 | P2 | Слабая изоляция юнита. Добавить: `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `SystemCallFilter=@system-service`, `PrivateDevices`, `ProtectKernelTunables/Modules`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname`, `ProtectProc=invisible`, `RestrictNamespaces`, `RestrictSUIDSGID`, `LockPersonality`. Оценка: `systemd-analyze security`. | юнит |
| 3 | P2 | Автообновление ставит релиз Xray в день выхода; SHA256 берётся из того же GitHub API, что и архив (защита от битой загрузки, не от подмены). Добавить выдержку N дней по `published_at` и написать о границе доверия в README. | `lib/auto-run.sh`, `lib/auto-release.sh` |
| 4 | P2 | Cron у всех серверов в 03:30. Случайная минута при `enable` или systemd timer (`RandomizedDelaySec`, `Persistent=true`), без установки cron. | `lib/auto-owned.sh:15`, `lib/auto-lifecycle.sh` |
| 5 | P2 (проверить) | `ufw insert 1` может падать с `Invalid position '1'` при пустом наборе правил; тесты ВМ всегда сначала добавляют `allow 22/tcp`. | `lib/firewall.sh:90` |
| 6 | P3 | В git закоммичены `tests/helpers/__pycache__/*.pyc`; в `.gitignore` нет `__pycache__/`. В корне неотслеживаемый `аудит.txt`. | репозиторий |
| 7 | P3 | Нет git-тегов и GitHub Releases при `VERSION` 0.1.1; bootstrap всегда берёт `master`. Существующий клон в `/opt/xray-vps-kit-src` не учитывает смену `XVK_REPO`. | bootstrap |

## 3. Открыто с прошлого аудита

- **block-ping:** неверная ссылка на `awg-vps-kit` в шапке (строка 12); `systemctl reload nftables` стирает таблицу; интерфейс определяется один раз; `apt-get install` без `update` и `--no-remove`; жёсткий путь `/usr/sbin/nft`; shebang `#!/bin/bash`; тестов нет.
- Нет восстановления после SIGKILL / потери питания посреди транзакции (журнал prepared/applying/committed).
- `uninstall.sh` требует сети (клон `master`); нет fallback на локальную копию.
- Bootstrap-блок (~40 строк) скопирован в 4 скрипта; нет Ubuntu 26.04; нет `--skip-os-check`.
- CI: только Ubuntu 22.04/24.04; Debian и arm64 не проверяются.
- Нет IPv6 (`listen 0.0.0.0`).
- `add`/`remove` перезапускают Xray и обрывают всех клиентов.
- `uninstall --keep-config` нельзя потом очистить штатно (нужен `--purge-preserved`).
- Healthcheck не проверяет реальный REALITY-трафик.

## 4. Предложения по функциям

- `doctor`: TLS 1.3/h2 к REALITY-target с сервера, совпадение endpoint с публичным IP, наличие UFW-правила, результат последнего автообновления, синхронизация времени, BBR, подсказка MTU/MSS.
- Маршрутизация: опциональная блокировка BitTorrent; расширить блок приватных сетей (`198.18.0.0/15`, `192.0.0.0/24`), проверить `::ffff:127.0.0.1`.
- Клиенты: добавление/удаление без перезапуска через gRPC API, трафик по клиенту, срок действия, `list --json`, экспорт для sing-box / Clash Meta.
- Выбор SNI: короткий список или автоподбор вместо единого `github.com`.
- Документы: `SECURITY.md`, `CHANGELOG.md`, `README.ru.md`.

## 5. План

**Этап 1 — быстрые правки, низкий риск**
1. Юнит: `Restart=always`, снять лимит рестартов (п.1). Добавить безопасные директивы изоляции (п.2), прогнать e2e/VM-сюиту.
2. `.gitignore` + `git rm --cached` для `__pycache__`; решить судьбу `аудит.txt` (п.6).
3. block-ping: ссылка, shebang, `command -v nft`, `apt-get update` + `--no-remove` + `DEBIAN_FRONTEND`, пересчёт интерфейса при старте юнита, `PartOf=nftables.service`; сюита `block-ping` (`nft -c`, цикл on/status/off) и добавление в CI и README.

**Этап 2 — автообновление**
4. Выдержка N дней после `published_at`; уточнение границы доверия в README (п.3).
5. Случайная минута или systemd timer вместо cron (п.4); тесты scheduling.
6. Проверить `ufw insert 1` на пустом UFW в ВМ, при необходимости fallback на `ufw allow` (п.5).

**Этап 3 — надёжность**
7. Журнал транзакции и восстановление при старте/повторном запуске.
8. `uninstall.sh` с fallback на локальную копию; `--purge-preserved`.
9. Опциональный функциональный healthcheck (REALITY handshake через временного клиента).

**Этап 4 — проект и CI**
10. Теги/Releases, `XVK_REF`, вынос общего bootstrap, Ubuntu 26.04 / `--skip-os-check`.
11. CI: Debian в контейнере, arm64-раннер, workflow обновления `xray.lock.json`, Dependabot.
12. `SECURITY.md`, `CHANGELOG.md`, `README.ru.md`.

**Этап 5 — функции**
13. IPv6, клиенты через gRPC API без рестарта, статистика трафика, расширение `doctor`, экспорт форматов.

После каждого этапа: `bash tests/lint.sh`, нужные сюиты через `bash tests/run.sh --suite NAME`, обновление STATUS/DECISIONS/TODO и README (проверяется `--suite docs`). Привилегированные тесты только в одноразовых гостях.

## 6. Статус этапа 1 (2026-11-08, не закоммичено)

- Юнит: `Restart=always`, `RestartSec=5`, без лимита рестартов; добавлена изоляция (PrivateDevices, ProtectKernel*, ProtectControlGroups/Clock/Hostname, ProtectProc=invisible, RestrictAddressFamilies с AF_NETLINK, RestrictNamespaces/SUIDSGID/Realtime, LockPersonality, SystemCallFilter=@system-service). Не проверено на живом systemd: нужен прогон в гостевой ВМ (lifecycle-coexistence) и `systemd-analyze security`.
- `.gitignore`: `__pycache__/`, `*.pyc`; `.pyc` убраны из индекса. `аудит.txt` не тронут.
- `block-ping`: исправлены ссылка, shebang, `nft` через `command -v`, `apt-get update` + `--no-remove`; интерфейс определяется заново при каждом старте/reload (helper `/etc/block-ping/apply`), `PartOf` + `ReloadPropagatedFrom=nftables.service`, повтор при отсутствии маршрута. Новая сюита `block-ping` (40 проверок, зелёная), добавлена в `tests/run.sh`, CI и README.
- Проверено: сюита `block-ping` и ShellCheck по изменённым файлам. Остальные сюиты на Windows/Git Bash не запускаются (бинарник Xray), в WSL нет jq/unzip — полный прогон нужен на Debian 13 (192.168.0.173).

## 7. Статус этапа 2 (2026-11-08, не закоммичено)

- Cron автообновления: минута выбирается случайно один раз при `enable` и дальше сохраняется (`MM 3 * * *`); проверка drift сверяет файл с текстом для этой же минуты, повторный `enable` минуту не меняет. Старые установки с `30 3` остаются валидными.
- Плановый запуск ждёт, пока релиз станет старше 3 дней (`published_at`; `XVK_AUTO_MIN_AGE_DAYS` — только для тестов/ручной настройки); `run` вручную ждать не нужно. Отсутствующая или нечитаемая дата — релиз считается слишком свежим. Итог записывается как `skipped`.
- UFW: если `ufw insert 1` отказывает, правило добавляется в конец (`xvk_ufw_add_allow`), эффективность по-прежнему проверяется. Сам отказ на пустом UFW не подтверждён — проверить на ВМ.
- Тесты добавлены (cron-минута, `xvk_auto_release_aged`, плановый запуск с молодым релизом, UFW-fallback); README обновлён. Проверено вручную в Git Bash только сами функции и ShellCheck; сюиты `auto-update` и `install` нужно прогнать на Debian (вместе с проверками этапа 1).

## 8. Статус этапа 3 (2026-11-08, не закоммичено)

- **Журнал транзакций (п.7).** `xvk_transaction_apply` пишет `etc/xray-vps-kit/transaction.journal` (снимок «до») перед первой заменой файла и удаляет его после успеха или успешного отката. При SIGKILL/потере питания следующая мутация сначала откатывает снимок и просит повторить команду; добавлена команда `xray-client recover`; `doctor` показывает незавершённую транзакцию. Нечитаемый журнал не трогается, нужен ручной разбор.
- **`uninstall.sh` без сети (п.8).** Если скрипт запущен через pipe, GitHub недоступен (curl HEAD, 10 с) и рядом с ядром стоит установка, используется её копия `lib/` (нужен `--yes`). Общий bootstrap-блок не менялся (тест требует одинаковых блоков в 4 скриптах). Заодно убраны буквальные переводы строки внутри `printf` в 4 входных скриптах.
- **`--purge-preserved`.** Удаляет то, что оставил `--keep-config` (с подтверждением; отказ, пока кит установлен или с `--keep-config`).
- **Сделано позже: функциональный healthcheck (п.9)** — `xray-client doctor --probe-reality` (временный локальный клиент, проверено на ВМ 173, e2e 35 проверок).
- Тесты добавлены: сюита `transaction` (краш через `kill -9` в hook `activate`, recover, откат следующей операцией, битый журнал), сюита `uninstall` (purge). Ни одна сюита здесь не запускалась (нет `flock`/Xray в Windows, WSL без `jq`); ShellCheck чист.

## 9. Статус этапа 4 (2026-11-08, этапы 1-3 закоммичены)

- Сделано: `XVK_REF` (тег/коммит) и `XVK_ALLOW_UNSUPPORTED_OS=1` в bootstrap и `xvk_platform`; блок bootstrap генерируется из `tools/bootstrap.block.in` (`tools/sync-bootstrap.sh [--check]`, проверка в CI); `tools/update-lock.sh` + недельный workflow, открывающий PR с новым пином Xray-core; Dependabot для Actions; advisory-job Debian 12/13 в CI; `SECURITY.md`, `CHANGELOG.md`, `README.ru.md`.
- Проверено: ShellCheck, поток `XVK_REF` вручную в WSL (checkout тега, отказ на неизвестном/некорректном ref, возврат на master).
- Не сделано: arm64 в CI (тесты жёстко берут amd64-ядро, нужна параметризация); теги и GitHub Releases (публикация, только по вашей команде: `git tag -s v0.1.1 && git push origin v0.1.1`); пиннинг Actions по SHA (Dependabot обновляет версии, SHA нужно получить из GitHub); Ubuntu 26.04 не заявлена как поддерживаемая, только через `XVK_ALLOW_UNSUPPORTED_OS=1`.

## 10. Статус этапа 5 (2026-11-08)

- Сделано: `xray-client export --format singbox|clash` (вывод проверен вручную на фикстуре, в реальных клиентах не импортировался), `list --json` (только имена), заметки в `doctor` (часы, congestion control, результат последнего автообновления) и `doctor --probe-target` (TLS 1.3 у REALITY-target). Тесты добавлены в `export-doctor`, не запускались.
- Сознательно отложено, нужен живой Xray/сеть: IPv6 (listen `::`, правило UFW для `::/0`, URI с `[addr]`), добавление/удаление клиентов без перезапуска через gRPC API, статистика трафика по клиентам, срок действия клиентов, автоподбор SNI. Эти пункты меняют конфиг и состояние и без прогона на ВМ их добавлять небезопасно.

## 11. Прогон на ВМ 192.168.0.173 (Debian 13, 2026-11-08)

- Все 15 sandbox-сюит зелёные на ВМ (harness 14, block-ping 40, validation 96, release 19, render 34, transaction 77, install 57, clients 38, export-doctor 46, update 77, uninstall 68, coexistence 11, docs 64, packaging 70, auto-update); `tests/lint.sh` — 73 файла, чисто. Сюита e2e (root + netns): 32 проверки, зелёная.
- `tests/run-vm.sh --guest ... --case all` с новым юнитом: lifecycle-coexistence 63+42, selected-tcp-port-opened 83, occupied-port-and-rollback 35 — без ошибок.
- Живой systemd: `update.sh` 0.1.0 -> 0.1.1 применил усиленный юнит, сервис active; `systemd-analyze security` = 1.7 OK; `kill -9` Xray -> перезапуск через ~5 с; add/remove, `list --json`, export singbox/clash, `doctor` (note про bbr), `recover` работают; искусственный журнал откатывается при следующей мутации, doctor до этого показывает FAIL.
- `ufw insert 1` на активном UFW без правил действительно даёт `ERROR: Invalid position '1'`; запасной `ufw allow` срабатывает (гипотеза подтверждена).
- Исправлены ошибки в моих тестах transaction (неверное допущение про ownership после kill во время activate; повторный каталог бандла).
- Не проверено: arm64, реальные клиентские приложения (импорт sing-box/Clash), REALITY-трафик с внешней сети.
