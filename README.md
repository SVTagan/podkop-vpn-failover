# podkop-vpn-failover

[English](README.en.md)

Небольшой shell-скрипт для OpenWrt, который я сделал для своей конфигурации с [Podkop](https://github.com/itdoginfo/podkop).

Задача простая: в proxy-режиме Podkop умеет проверять несколько прокси через `urltest`, а для нескольких VPN-интерфейсов аналогичного failover нет. Скрипт проверяет, что активный AmneziaWG-туннель действительно пропускает HTTPS-трафик, и при устойчивом отказе переключает Podkop на рабочий резервный `awg*`.

Это независимый проект, он не является частью Podkop и не связан с его разработчиками. По вопросам самого Podkop лучше обращаться в [репозиторий Podkop](https://github.com/itdoginfo/podkop) и на [podkop.net](https://podkop.net/).

## Статус

Текущая версия: **0.1.5**.

### OpenWrt 25.12 / apk

По просьбе трудящихся добавлена **поддержка OpenWrt 25.12 с пакетным менеджером `apk`**. Поддержка OpenWrt 24.10 и более старых совместимых сборок с `opkg` сохранена.

Изменение касается установщика: он автоматически определяет доступный пакетный менеджер и через него проверяет/устанавливает `curl` и `luci-app-commands`. Runtime-логика failover в 0.1.4 не менялась.

Обновление `0.1.3 → 0.1.4` проверено на реальном OpenWrt 24.10.5: корректно определён `opkg`, сохранены running/autostart, сервис после обновления работает штатно, оба AWG проходят HTTPS health-check.

На реальном OpenWrt 25.12 я эту версию лично пока не проверял. Поддержка `apk` реализована по актуальной CLI-модели OpenWrt 25.12 и требует дополнительного подтверждения на реальном устройстве.

## Что умеет

- автоматически находит интерфейсы `awg*` с протоколом `amneziawg`;
- считает VPN рабочим только если через него проходит реальный HTTPS-запрос;
- последовательно проверяет независимые health targets Google → Apple → Mozilla и останавливается на первом успешном ответе;
- ждёт 3 ошибки подряд, чтобы не переключаться из-за краткого сбоя;
- перед переключением дважды проверяет резервный VPN;
- переключает `podkop.main.interface` и делает штатный reload Podkop;
- проверяет новый `main-out.bind_interface` и сам туннель после переключения;
- временно помещает недавно упавший VPN в quarantine;
- не возвращается автоматически на прежний VPN, пока текущий работает;
- после полного отказа всего пула не перебирает все VPN непрерывно;
- имеет 120-секундный grace period после запуска сервиса;
- умеет работать через LuCI `System → Custom Commands`, поэтому для обычного использования SSH не нужен.

## Как выбираются VPN

Список резервов вручную задавать не нужно. Скрипт берёт все UCI-интерфейсы с именами `awg*` и протоколом `amneziawg`.

Текущий основной VPN — тот, который сейчас указан в:

```text
podkop.main.interface
```

Остальные интерфейсы считаются резервами и проверяются в естественном порядке имён, например:

```text
awg0
awg0_2
awg1
awg2
awg2_2
awg9
awg10
```

Если активный VPN позже восстановился, скрипт сам обратно на него не прыгает. Переключение происходит только при отказе текущего VPN.

## Как проверяется туннель

Проверяется не handshake AmneziaWG, а реальный HTTPS-трафик, привязанный к конкретному интерфейсу через `curl --interface <awg*> -4`.

В 0.1.5 используется небольшой упорядоченный набор независимых health targets:

1. `https://www.gstatic.com/generate_204` — ожидается HTTP `204`;
2. `https://captive.apple.com/hotspot-detect.html` — ожидается HTTP `200`, а тело ответа должно содержать `Success`;
3. `https://detectportal.firefox.com/success.txt` — ожидается HTTP `200`, а тело ответа должно содержать `success`.

Проверка идёт последовательно и прекращается после первого успешного target. Поэтому в нормальном состоянии, когда отвечает `gstatic`, остаётся один запрос на цикл — как и раньше. Только отказ всех трёх targets считается одной неудачной health-check попыткой для существующего счётчика `FAIL_THRESHOLD`.

Редиректы специально не разрешаются, проверка TLS-сертификата не отключается. Для всех targets сохраняются текущие `CONNECT_TIMEOUT=5` и `MAX_TIME=10`.

Важно: `CHECK_INTERVAL=30` — это пауза после завершения очередной проверки, а не гарантированный интервал между её началами. Если туннель полностью недоступен, targets проверяются последовательно и каждый может ждать свой timeout, поэтому фактическое обнаружение устойчивого отказа занимает заметно больше времени. В реальном тесте полного отказа три targets добавляли примерно 15 секунд к одному циклу, и предупреждения шли примерно раз в 45 секунд. Это сознательный компромисс в пользу устойчивости к ложным переключениям, а не мгновенной реакции.

## Требования

Проверено на нескольких реальных роутерах:

- **Cudy TR3000 v1 / OpenWrt 24.10.5** — полный тест failover, включая принудительный отказ активного туннеля и переключение `awg0 ↔ awg0_2`;
- **Cudy TR3000 / OpenWrt 24.10.4** — установка, запуск, autostart, startup grace и health-check; само переключение пока не тестировалось;
- **Xiaomi Redmi AX6000 / OpenWrt 24.10.5** — установка, обнаружение двух AWG-интерфейсов, health-check, запуск, autostart и startup grace; само переключение пока не тестировалось.

Основной стенд полного тестирования: Podkop 0.7.21, sing-box 1.12.22 и AmneziaWG.

Установщик 0.1.4 поддерживает OpenWrt с `opkg` и `apk`, автоматически выбирая доступный пакетный менеджер. Для работы нужен Podkop в VPN-режиме и интерфейсы AmneziaWG с именами `awg*`. OpenWrt 25.12 лично на реальном устройстве пока не проверялся.

## Установка

Скачать и запустить установщик можно любым доступным способом.

Через `uclient-fetch`:

```sh
uclient-fetch -q -O /tmp/pvf-install.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/install.sh && \
sh /tmp/pvf-install.sh
```

Через `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/install.sh \
  -o /tmp/pvf-install.sh && sh /tmp/pvf-install.sh
```

Через `wget`:

```sh
wget -q -O /tmp/pvf-install.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/install.sh && \
sh /tmp/pvf-install.sh
```

Сам установщик при необходимости ставит `curl`, по умолчанию устанавливает/настраивает `luci-app-commands` и добавляет procd-сервис. Для загрузки своих файлов он умеет использовать `curl`, `uclient-fetch` или `wget`.

### После первой установки

Для безопасности failover оставляется выключенным. Сначала стоит проверить, что интерфейсы обнаруживаются и проходят health-check:

```sh
podkop-vpn-failover test
podkop-vpn-failover status
```

Затем включить сервис:

```sh
podkop-vpn-failover-control start
```

При последующих обновлениях установщик сохраняет состояние сервиса и autostart.

## LuCI

Если установлен `luci-app-commands`, в `System → Custom Commands` появляются команды:

- `VPN Failover: Status`
- `VPN Failover: Test all VPNs`
- `VPN Failover: Logs`
- `VPN Failover: Show settings`
- `VPN Failover: Enable + Start`
- `VPN Failover: Restart`
- `VPN Failover: Stop + Disable`

Добавлять и удалять резервные VPN можно обычным способом через `Network → Interfaces`. Скрипт подхватит изменения автоматически.

## Логика по умолчанию

- пауза между завершёнными проверками текущего VPN: 30 секунд;
- health targets: `gstatic` → `apple` → `mozilla`, short-circuit после первого успеха;
- отказ: 3 неудачные проверки подряд;
- подтверждение резерва: 2 успешные проверки;
- quarantine упавшего интерфейса: 180 секунд;
- startup grace period: 120 секунд;
- после полного провала пула новый полный перебор резервов: через 300 секунд;
- задержка выбирается не по ping/latency — нужен только факт рабочей передачи трафика.

Текущие значения можно посмотреть командой:

```sh
podkop-vpn-failover config
```

## CLI

```text
podkop-vpn-failover status
podkop-vpn-failover test
podkop-vpn-failover check awg0
podkop-vpn-failover logs
podkop-vpn-failover config
podkop-vpn-failover version

podkop-vpn-failover-control start
podkop-vpn-failover-control restart
podkop-vpn-failover-control stop
```

## Логи и состояние

События пишутся в обычный системный log OpenWrt с тегом `podkop-vpn-failover`:

```sh
logread | grep podkop-vpn-failover
```

Отдельный постоянный лог на flash не создаётся. Runtime-состояние хранится в `/tmp` и после reboot начинается заново.

## Удаление

Как и при установке, `uninstall.sh` можно скачать любым доступным способом.

Через `uclient-fetch`:

```sh
uclient-fetch -q -O /tmp/pvf-uninstall.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/uninstall.sh && \
sh /tmp/pvf-uninstall.sh
```

Через `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/uninstall.sh \
  -o /tmp/pvf-uninstall.sh && sh /tmp/pvf-uninstall.sh
```

Через `wget`:

```sh
wget -q -O /tmp/pvf-uninstall.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/uninstall.sh && \
sh /tmp/pvf-uninstall.sh
```

`luci-app-commands` при удалении не удаляется: он может использоваться другими скриптами.

## Ограничения

Сейчас проект рассчитан именно на мою исходную задачу:

- Podkop VPN mode через `podkop.main.interface`;
- AmneziaWG-интерфейсы `awg*`;
- IPv4 health-check;
- health-check targets пока встроены в shell-скрипт и не настраиваются через LuCI;
- настройки failover пока встроены в shell-скрипт, отдельной формы LuCI нет;
- поддержка установщика через `apk` для OpenWrt 25.12 реализована, но лично на реальном устройстве пока не проверялась.

## Проверка на реальных роутерах

Полный failover-тест выполнен на Cudy TR3000 v1 / OpenWrt 24.10.5: UDP-транспорт активного туннеля блокировался отдельно при остающемся поднятым AWG-интерфейсе, после чего failover успешно выполнялся в обе стороны (`awg0 → awg0_2` и обратно).

На втором Cudy TR3000 с OpenWrt 24.10.4 дополнительно подтверждены штатная установка и запуск, procd/autostart, startup grace и реальные HTTPS health-check.

На Xiaomi Redmi AX6000 / OpenWrt 24.10.5 для 0.1.5 отдельно проверены все три health targets, fallback на Apple и Mozilla, корректный полный отказ всех targets, реальный failover `awg0 → awg0_2` при блокировке UDP-транспорта активного туннеля и восстановление `awg0` без автоматического переключения обратно.

История изменений: [CHANGELOG.md](CHANGELOG.md).

## Лицензия

MIT — см. [LICENSE](LICENSE).
