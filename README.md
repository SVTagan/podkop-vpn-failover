# podkop-vpn-failover

[English](README.en.md)

Небольшой shell-скрипт для OpenWrt, который я сделал для своей конфигурации с [Podkop](https://github.com/itdoginfo/podkop).

Задача простая: в proxy-режиме Podkop умеет проверять несколько прокси через `urltest`, а для нескольких VPN-интерфейсов аналогичного failover нет. Скрипт проверяет, что активный AmneziaWG-туннель действительно пропускает HTTPS-трафик, и при устойчивом отказе переключает Podkop на рабочий резервный `awg*`.

Это независимый проект, он не является частью Podkop и не связан с его разработчиками. По вопросам самого Podkop лучше обращаться в [репозиторий Podkop](https://github.com/itdoginfo/podkop) и на [podkop.net](https://podkop.net/).

## Что умеет

- автоматически находит интерфейсы `awg*` с протоколом `amneziawg`;
- считает VPN рабочим только если через него проходит реальный HTTPS-запрос;
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

Проверяется не handshake AmneziaWG, а реальный HTTP-запрос, привязанный к конкретному интерфейсу:

```sh
curl --interface awg0 -4 https://www.gstatic.com/generate_204
```

По умолчанию рабочим считается туннель, через который запрос успешно возвращает HTTP `204`.

## Требования

Проверено на:

- Cudy TR3000 v1;
- OpenWrt 24.10.5;
- Podkop 0.7.21;
- sing-box 1.12.22;
- AmneziaWG.

Текущий установщик рассчитан на OpenWrt с `opkg`. Для работы нужен Podkop в VPN-режиме и интерфейсы AmneziaWG с именами `awg*`.

## Установка

Если на роутере есть штатный `uclient-fetch`:

```sh
uclient-fetch -q -O /tmp/pvf-install.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/install.sh && \
sh /tmp/pvf-install.sh
```

Если `curl` уже установлен:

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/install.sh \
  -o /tmp/pvf-install.sh && sh /tmp/pvf-install.sh
```

Сам установщик при необходимости ставит `curl`, по умолчанию устанавливает/настраивает `luci-app-commands` и добавляет procd-сервис.

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

- проверка текущего VPN: каждые 30 секунд;
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

```sh
uclient-fetch -q -O /tmp/pvf-uninstall.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-vpn-failover/main/uninstall.sh && \
sh /tmp/pvf-uninstall.sh
```

`luci-app-commands` при удалении не удаляется: он может использоваться другими скриптами.

## Ограничения

Сейчас проект рассчитан именно на мою исходную задачу:

- Podkop VPN mode через `podkop.main.interface`;
- AmneziaWG-интерфейсы `awg*`;
- IPv4 health-check;
- один внешний health-check URL — `www.gstatic.com/generate_204`;
- настройки пока встроены в shell-скрипт, отдельной формы LuCI нет;
- установщик рассчитан на `opkg`.

Поддержка нескольких независимых health-check URL оставлена как [отдельная будущая доработка](https://github.com/SVTagan/podkop-vpn-failover/issues/3).

## Проверка на реальном роутере

На Cudy TR3000 v1 тестировался именно отказ передачи данных при остающемся поднятым AWG-интерфейсе: UDP-транспорт активного туннеля блокировался отдельно, после чего failover успешно выполнялся в обе стороны (`awg0 → awg0_2` и обратно).

Также проверены debounce, подтверждение резерва, quarantine, отсутствие автоматического switch-back, procd/autostart, LuCI-команды и запуск после reboot.

История изменений: [CHANGELOG.md](CHANGELOG.md).

## Лицензия

MIT — см. [LICENSE](LICENSE).
