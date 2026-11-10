#!/usr/bin/env bash
# shellcheck disable=SC2016,SC1090  # одинарные кавычки и source здесь намеренные
#
# Проверка установки, настроек, таймера, self-update и удаления. ЗАПУСКАТЬ ТОЛЬКО НА
# ОДНОРАЗОВОЙ МАШИНЕ: тест пишет в /usr/local/sbin, /etc/systemd/system и /etc.
# systemctl подменяется заглушкой, поэтому systemd в машине не нужен.
#
#   sudo bash tests/install.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }

T=$(mktemp -d /tmp/aau-install.XXXXXX)
BIN=/usr/local/sbin/amnezia-autoupdate
UNITS=/etc/systemd/system
CONF=/etc/amnezia-autoupdate.conf
[[ -e $CONF || -e $BIN ]] && { echo "на машине уже стоит amnezia-autoupdate, тест не для неё"; exit 2; }

PASS=0
FAILED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
section() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run() { "$@" > "$T/last.out" 2>&1; local rc=$?; sed 's/^/    | /' "$T/last.out"; return $rc; }
out_has() { grep -q -- "$1" "$T/last.out"; }
conf_val() { (set +u; . "$CONF"; eval "printf '%s' \"\${$1}\""); }

# Заглушки: systemctl записывает вызовы, check и run не нужны (их проверяет e2e.sh)
mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/systemctl.log"
case "\$1" in list-timers) echo "Mon 2026-11-10 04:12:00 MSK 19h left - - amnezia-autoupdate.timer amnezia-autoupdate.service" ;; esac
exit 0
EOF
chmod 755 "$T/bin/systemctl"
export PATH="$T/bin:$PATH"

# Копия скрипта, в которой check ничего не делает (без Docker и сети)
SRC="$T/amnezia-autoupdate"
sed 's/^cmd_check() {$/cmd_check() { echo "check: пропущен в тесте"; return 0; }\ncmd_check_real() {/' \
  "$ROOT/amnezia-autoupdate" > "$SRC"

section "1. первая установка"
# правило logrotate от версии 1.0.0: install его убирает, журнал теперь циклический сам
mkdir -p /etc/logrotate.d
printf '/var/log/amnezia-autoupdate.log {\n  weekly\n}\n' > /etc/logrotate.d/amnezia-autoupdate
run bash "$SRC" install --time 05:30 --tz Europe/Moscow --delay 45min --reboot never \
  --telegram-token '123:ABC$x"y`z\w' --telegram-chat -100500 --name 'srv $HOME "1"' --no-os-update
check "install завершился без ошибок" [ $? -eq 0 ]
check "скрипт установлен в $BIN" [ -x "$BIN" ]
check "в установленном скрипте нет CR" bash -c "! grep -q $'\r' '$BIN'"
check "установленный скрипт запускается" bash -c "'$BIN' version | grep -q '^amnezia-autoupdate '"
check "настройки созданы" [ -f "$CONF" ]
check "права настроек 600" [ "$(stat -c %a "$CONF")" == 600 ]
check "UPDATE_TIME=05:30" [ "$(conf_val UPDATE_TIME)" == 05:30 ]
check "REBOOT=never" [ "$(conf_val REBOOT)" == never ]
check "OS_UPDATE=no" [ "$(conf_val OS_UPDATE)" == no ]
check "токен со спецсимволами сохранён как есть" [ "$(conf_val TELEGRAM_BOT_TOKEN)" == '123:ABC$x"y`z\w' ]
check "имя сервера со спецсимволами сохранено как есть" [ "$(conf_val SERVER_NAME)" == 'srv $HOME "1"' ]
check "chat id сохранён" [ "$(conf_val TELEGRAM_CHAT_ID)" == -100500 ]
check "таймер: 05:30 по Москве" grep -qx 'OnCalendar=\*-\*-\* 05:30:00 Europe/Moscow' "$UNITS/amnezia-autoupdate.timer"
check "таймер: задержка 45min" grep -qx 'RandomizedDelaySec=45min' "$UNITS/amnezia-autoupdate.timer"
check "сервис запускает run" grep -qx "ExecStart=$BIN run" "$UNITS/amnezia-autoupdate.service"
check "сервис настроек хоста при загрузке" grep -qx "ExecStart=$BIN host-setup" "$UNITS/amnezia-hostsetup.service"
check "systemctl: таймер включён" grep -qx 'enable --now amnezia-autoupdate.timer' "$T/systemctl.log"
check "systemctl: host-setup включён" grep -qx 'enable amnezia-hostsetup.service' "$T/systemctl.log"
check "журнал ограничен 200M" grep -qx 'SystemMaxUse=200M' /etc/systemd/journald.conf.d/60-amnezia-autoupdate.conf
check "старое правило logrotate убрано" [ ! -e /etc/logrotate.d/amnezia-autoupdate ]
check "install пишет про циклический журнал" out_has "циклический, до 10 МБ"
check "LOG_MAX_MB=10 в настройках" [ "$(conf_val LOG_MAX_MB)" == 10 ]
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$UNITS/amnezia-autoupdate.service" "$UNITS/amnezia-autoupdate.timer" \
    "$UNITS/amnezia-hostsetup.service" > "$T/verify.log" 2>&1
  check "systemd-analyze verify без ошибок про наши юниты" bash -c "! grep -i amnezia '$T/verify.log' | grep -viE 'not found|No such|bus|Failed to (connect|create)' | grep -q ."
  sed 's/^/    | /' "$T/verify.log"
  check "systemd понимает расписание" systemd-analyze calendar '*-*-* 05:30:00 Europe/Moscow'
fi

section "2. повторная установка сохраняет настройки"
run bash "$SRC" install --time 03:15
check "повторный install без ошибок" [ $? -eq 0 ]
check "время поменялось на 03:15" grep -qx 'OnCalendar=\*-\*-\* 03:15:00 Europe/Moscow' "$UNITS/amnezia-autoupdate.timer"
check "токен остался" [ "$(conf_val TELEGRAM_BOT_TOKEN)" == '123:ABC$x"y`z\w' ]
check "REBOOT остался never" [ "$(conf_val REBOOT)" == never ]
check "в выводе: настройки сохранены" out_has "сохранены прежние"

section "3. неверные параметры"
run bash "$SRC" install --time 25:00
check "время 25:00 отклонено" [ $? -ne 0 ]
check "таймер не испорчен" grep -qx 'OnCalendar=\*-\*-\* 03:15:00 Europe/Moscow' "$UNITS/amnezia-autoupdate.timer"
sed -i 's/^UPDATE_TIME=.*/UPDATE_TIME="03:15"/' "$CONF"
run bash "$SRC" install --reboot sometimes
check "--reboot sometimes отклонено" [ $? -ne 0 ]
run bash "$SRC" install --tz Mars/Base
check "неизвестный часовой пояс: предупреждение" out_has "не понимает часовой пояс"
check "неизвестный часовой пояс: время по часам сервера" grep -qx 'OnCalendar=\*-\*-\* 03:15:00' "$UNITS/amnezia-autoupdate.timer"
run bash "$SRC" install --tz Europe/Moscow
run bash "$SRC" bogus
check "неизвестная команда: код 2" [ $? -eq 2 ]
chown nobody "$CONF"
run "$BIN" status
check "настройки не от root отклоняются" out_has "должен принадлежать root"
chown root "$CONF"

section "4. status и self-update"
run "$BIN" status
check "status показывает таймер" out_has "Следующий запуск: Mon 2026-11-10"
sed 's/^VERSION="[^"]*"/VERSION="9.9.9"/' "$ROOT/amnezia-autoupdate" > "$T/new-version"
echo "SELF_UPDATE_URL=\"file://$T/new-version\"" >> "$CONF"
run "$BIN" self-update
check "self-update без ошибок" [ $? -eq 0 ]
check "версия теперь 9.9.9" bash -c "'$BIN' version | grep -q 9.9.9"
printf 'echo hacked\n' > "$T/not-a-script"
sed -i "s|^SELF_UPDATE_URL=.*|SELF_UPDATE_URL=\"file://$T/not-a-script\"|" "$CONF"
run "$BIN" self-update
check "чужой файл не ставится" [ $? -ne 0 ]
check "версия осталась 9.9.9" bash -c "'$BIN' version | grep -q 9.9.9"

section "5. удаление"
run "$BIN" uninstall
check "uninstall без ошибок" [ $? -eq 0 ]
check "юниты удалены" bash -c "! ls $UNITS/amnezia-* 2>/dev/null | grep -q ."
check "скрипт удалён" [ ! -e "$BIN" ]
check "настройки оставлены" [ -f "$CONF" ]
bash "$SRC" install > /dev/null 2>&1
run "$BIN" uninstall --purge
check "uninstall --purge удалил настройки" [ ! -e "$CONF" ]
check "journald drop-in удалён" [ ! -e /etc/systemd/journald.conf.d/60-amnezia-autoupdate.conf ]

section "итог: $PASS прошло, $FAILED не прошло"
(( FAILED == 0 ))
