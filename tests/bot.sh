#!/usr/bin/env bash
# shellcheck disable=SC2016  # одинарные кавычки здесь намеренные
#
# Проверка бота Telegram (команда /status) на заглушке Bot API (tests/telegram-mock.py):
# отвечает только своему чату, не отвечает на старые команды и второй раз после
# перезапуска, один бот на два сервера, ошибки Telegram. Docker и systemd не нужны,
# системные папки не трогаются. Бот читает настройки только от root:
#
#   sudo bash tests/bot.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "нужен python3"; exit 2; }

T=$(mktemp -d /tmp/aau-bot.XXXXXX)
PASS=0
FAILED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
section() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

declare -A PID=()
MOCK=""
cleanup() {
  local p
  for p in "${PID[@]}" $MOCK; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------- заглушка и "серверы"
python3 "$ROOT/tests/telegram-mock.py" "$T/tg" 42:TEST 777,-100500 > "$T/mock.log" 2>&1 &
MOCK=$!
for _ in $(seq 50); do [[ -s $T/tg/port ]] && break; sleep 0.1; done
[[ -s $T/tg/port ]] || { echo "заглушка Telegram не запустилась"; cat "$T/mock.log"; exit 1; }
API="http://127.0.0.1:$(cat "$T/tg/port")"
touch "$T/tg/sent.jsonl" "$T/tg/calls.jsonl"
echo "  заглушка Telegram: $API, папка теста: $T"

server() {   # server ИМЯ [строки настроек]: папка с настройками отдельного "сервера"
  local d="$T/$1"
  mkdir -p "$d"
  printf 'TELEGRAM_BOT_TOKEN="42:TEST"\nTELEGRAM_CHAT_ID="777"\nSERVER_NAME="%s"\n' "$1" > "$d/conf"
  shift
  (( $# )) && printf '%s\n' "$@" >> "$d/conf"
  chmod 600 "$d/conf"
}
srv_env() {   # окружение "сервера": его настройки, состояние и заглушка Telegram
  local d="$T/$1"
  printf '%s\n' AAU_CONF="$d/conf" AAU_STATE_DIR="$d/state" AAU_BACKUP_DIR="$d/backups" AAU_LOG_FILE="$d/log" \
    AAU_LOCK_FILE="$d/lock" AAU_TELEGRAM_API="$API" AAU_BOT_TIMEOUT=5 AAU_BOT_POLL=1
}
aau() {   # aau ИМЯ КОМАНДА...: запуск скрипта от имени "сервера"
  local envs
  mapfile -t envs < <(srv_env "$1")
  env "${envs[@]}" bash "$ROOT/amnezia-autoupdate" "${@:2}"
}
start_bot() {   # start_bot ИМЯ [env ...]: в PID процесс самого бота, а не обёртки
  local name=$1 envs
  shift
  mapfile -t envs < <(srv_env "$name")
  env "${envs[@]}" "$@" bash "$ROOT/amnezia-autoupdate" bot >> "$T/$name/bot.log" 2>&1 &
  PID[$name]=$!
}
stop_bot() { kill "${PID[$1]}" 2>/dev/null; wait "${PID[$1]}" 2>/dev/null; unset "PID[$1]"; }
restart_bot() {   # restart_bot ИМЯ [env ...]: журнал бота начинается заново
  stop_bot "$1"
  : > "$T/$1/bot.log"
  start_bot "$@"
}

say() {   # say ЧАТ ТЕКСТ [сколько секунд назад]
  curl -fsS -o /dev/null "$API/test/message" -d "chat_id=$1" --data-urlencode "text=$2" -d "age=${3:-0}"
}
sent() { wc -l < "$T/tg/sent.jsonl"; }
wait_sent() {   # wait_sent N [секунд]: ждать, пока отправленных станет не меньше N
  local i
  for ((i = 0; i < ${2:-15} * 10; i++)); do (( $(sent) >= $1 )) && return 0; sleep 0.1; done
  return 1
}
quiet_for() {   # quiet_for СЕКУНД: за это время новых ответов нет
  local n
  n=$(sent)
  sleep "$1"
  [[ $(sent) -eq $n ]]
}
reply() { sed -n "${1}p" "$T/tg/sent.jsonl" | jq -r .text; }   # текст N-го ответа
reply_has() { reply "$1" | grep -q -- "$2"; }
log_has() { grep -q -- "$2" "$T/$1/bot.log"; }
wait_log() {   # wait_log ИМЯ ТЕКСТ [секунд]
  local i
  for ((i = 0; i < ${3:-15} * 10; i++)); do log_has "$1" "$2" && return 0; sleep 0.1; done
  return 1
}

# ---------------------------------------------------------------- 1. без настроек
section "1. бот без токена и с выключенными командами"
mkdir -p "$T/none"
: > "$T/none/conf"
chmod 600 "$T/none/conf"
timeout 10 bash -c 'AAU_CONF="$1" bash "$2" bot' _ "$T/none/conf" "$ROOT/amnezia-autoupdate" > "$T/none.out" 2>&1
check "без токена бот сразу выходит с кодом 0" [ $? -eq 0 ]
check "и пишет почему" grep -q "не заданы TELEGRAM_BOT_TOKEN" "$T/none.out"
server off 'TELEGRAM_COMMANDS="no"'
timeout 10 bash -c 'AAU_CONF="$1" bash "$2" bot' _ "$T/off/conf" "$ROOT/amnezia-autoupdate" > "$T/off.out" 2>&1
check "TELEGRAM_COMMANDS=no: бот сразу выходит" [ $? -eq 0 ]
check "и пишет, что команды выключены" grep -q "команды выключены" "$T/off.out"
server name 'TELEGRAM_CHAT_ID="@mychannel"'
timeout 10 bash -c 'AAU_CONF="$1" bash "$2" bot' _ "$T/name/conf" "$ROOT/amnezia-autoupdate" > "$T/name.out" 2>&1
check "id чата не числом: бот не запускается" grep -q "нужен числовой ID чата" "$T/name.out"

# ---------------------------------------------------------------- 2. первый запуск
section "2. запуск: на свежую команду отвечает, на старую нет"
server srv1
say 777 /help 3600          # час назад: не отвечать
say 777 /status 30          # полминуты назад: ответить
start_bot srv1
check "бот ответил на /status, отправленный до запуска" wait_sent 1
check "ответ в наш чат 777" [ "$(sed -n 1p "$T/tg/sent.jsonl" | jq -r .chat_id)" == 777 ]
check "в ответе имя сервера и версия" reply_has 1 '^\[srv1\] amnezia-autoupdate [0-9]'
check "в ответе место на диске" reply_has 1 "Свободно на диске: [0-9]* МБ"
check "в ответе последний запуск" reply_has 1 "Последний запуск: ещё не было"
check "на /help часовой давности не ответил" quiet_for 2
check "в журнале бота: имя бота и чат" log_has srv1 "бот @aau_test_bot: жду команды из чата 777 (ответ сразу)"
check "бот зарегистрировал команду /status в меню" bash -c 'jq -r "select(.method == \"setMyCommands\") | .params.commands" "$1" | jq -e "any(.[]; .command == \"status\")" >/dev/null' _ "$T/tg/calls.jsonl"
check "long polling: getUpdates ждёт сообщений (timeout=5)" bash -c 'jq -e "select(.method == \"getUpdates\" and .params.timeout == \"5\")" "$1" >/dev/null' _ "$T/tg/calls.jsonl"
for _ in $(seq 30); do pgrep -x curl >/dev/null && break; sleep 0.1; done
check "бот ждёт сообщений в curl" bash -c 'pgrep -x curl >/dev/null'
check "токена нет в командной строке curl" bash -c '! for p in $(pgrep -x curl); do tr "\0" " " < /proc/$p/cmdline; echo; done | grep -q "42:TEST"'

# ---------------------------------------------------------------- 3. кому отвечает
section "3. отвечает только своему чату и только на свои команды"
n=$(sent)
say 555 /status
check "чужой чат 555: ответа нет" quiet_for 2
check "чужой чат: бот не пытался туда писать" bash -c '! jq -e "select(.method == \"sendMessage\" and .params.chat_id == \"555\")" "$1" >/dev/null' _ "$T/tg/calls.jsonl"
check "чужой чат записан в журнал бота" log_has srv1 "сообщение из чужого чата 555, не отвечаю"
say 555 /status
sleep 1
check "чужой чат в журнале один раз" [ "$(grep -c 'чужого чата 555' "$T/srv1/bot.log")" -eq 1 ]
say 777 "/status@aau_test_bot"
check "/status@aau_test_bot: ответил" wait_sent $((n + 1))
say 777 "/status@other_bot"
check "/status@other_bot (команда другому боту): молчит" quiet_for 2
say 777 "/STATUS srv1"
check "/STATUS srv1 (своё имя, другой регистр): ответил" wait_sent $((n + 2))
say 777 "/status srv9"
check "/status srv9 (чужое имя): молчит" quiet_for 2
say 777 "привет"
check "обычный текст: молчит" quiet_for 2
say 777 /help
check "/help: ответил" wait_sent $((n + 3))
check "в помощи есть /status" reply_has $((n + 3)) "^/status — состояние сервера"
say 777 /foo
check "незнакомая команда: ответ с помощью" wait_sent $((n + 4))
check "в ответе на /foo есть /status" reply_has $((n + 4)) "/status"
aau srv1 status 2>/dev/null | grep -vE '^(Сервер запущен|Свободно на диске)' > "$T/status.cli"
reply 1 | grep -vE '^(Сервер запущен|Свободно на диске)' > "$T/status.bot"
check "ответ на /status тот же, что у команды status" diff "$T/status.cli" "$T/status.bot"

# ---------------------------------------------------------------- 4. перезапуск
section "4. после перезапуска второй раз не отвечает"
n=$(sent)
# Telegram отвечает на sendMessage с задержкой: бота перезапускают, пока он ещё отвечает
curl -fsS -o /dev/null "$API/test/slow?send=2"
say 777 /status
check "ответил на /status" wait_sent $((n + 1))
restart_bot srv1
curl -fsS -o /dev/null "$API/test/slow?send=0"
check "бот перезапущен" wait_log srv1 "жду команды" 10
check "на уже отвеченный /status второй раз не ответил" quiet_for 3
check "в состоянии бота последний update_id" grep -q '^LAST_ID=[0-9]' "$T/srv1/state/bot.state"

# ---------------------------------------------------------------- 5. длинный отчёт
section "5. длинный отчёт обрезается под лимит Telegram"
{
  printf 'FINISHED_AT=%s\nRESULT=errors\n[srv1] Amnezia autoupdate\nОшибки:\n' "$(date -Is)"
  for i in $(seq 40); do printf '• ошибка номер %s: %s\n' "$i" "$(printf 'очень длинное описание %.0s' $(seq 8))"; done
} > "$T/srv1/state/last-run"
n=$(sent)
say 777 /status
check "ответ на /status с длинным отчётом отправлен" wait_sent $((n + 1))
check "итог последнего запуска: ошибки" reply_has $((n + 1)) "итог: ошибки"
check "ответ не длиннее 4096 символов" [ "$(reply $((n + 1)) | python3 -c 'import sys; print(len(sys.stdin.read().encode("utf-16-le")) // 2)')" -le 4096 ]
check "обрезанный ответ кончается на …" [ "$(reply $((n + 1)) | tail -n 1)" == "…" ]
rm -f "$T/srv1/state/last-run"

# ---------------------------------------------------------------- 6. один бот на два сервера
section "6. тот же бот на втором сервере: оба переходят на общий режим"
server srv2
start_bot srv2
check "srv1 перешёл на общий режим" wait_log srv1 "перехожу на общий режим" 90
check "srv2 перешёл на общий режим" wait_log srv2 "перехожу на общий режим" 30
check "общий режим записан в состояние" grep -q '^MODE=shared' "$T/srv1/state/bot.state"
sleep 2
n=$(sent)
say 777 /status
check "на /status ответили оба сервера" wait_sent $((n + 2)) 15
check "ответил srv1" bash -c 'tail -n 2 "$1" | jq -r .text | grep -q "^\[srv1\]"' _ "$T/tg/sent.jsonl"
check "ответил srv2" bash -c 'tail -n 2 "$1" | jq -r .text | grep -q "^\[srv2\]"' _ "$T/tg/sent.jsonl"
check "больше ответов нет" quiet_for 3
n=$(sent)
say 777 "/status srv2"
check "/status srv2: ответил srv2" wait_sent $((n + 1)) 15
check "это ответ srv2" reply_has $((n + 1)) "^\[srv2\]"
check "srv1 промолчал" quiet_for 3
n=$(sent)
say 777 /help
check "/help: ответили оба" wait_sent $((n + 2)) 15
check "в помощи сказано, что бот общий" reply_has $((n + 1)) "слушают несколько серверов"
check "общий режим: getUpdates без ожидания (offset=-5)" bash -c 'jq -e "select(.method == \"getUpdates\" and .params.offset == \"-5\")" "$1" >/dev/null' _ "$T/tg/calls.jsonl"

section "6b. перезапуск в общем режиме"
restart_bot srv1
check "srv1 после перезапуска сразу в общем режиме" wait_log srv1 "жду команды из чата 777 (бот общий" 10
check "srv1 не ответил второй раз на прошлые команды" quiet_for 3
n=$(sent)
say 777 /status
check "после перезапуска снова отвечают оба" wait_sent $((n + 2)) 15

section "6c. второй сервер убрали: srv1 сам возвращается на мгновенный ответ"
stop_bot srv2
sed -i "s/^SINCE=.*/SINCE=$(date +%s)/" "$T/srv1/state/bot.state"
restart_bot srv1 AAU_BOT_PROBE=4
check "srv1 стартовал в общем режиме" wait_log srv1 "жду команды из чата 777 (бот общий" 10
check "srv1 проверил, не остался ли он один" wait_log srv1 "не остался ли этот сервер у бота один" 20
sleep 4
check "srv1 остался в обычном режиме" bash -c '! grep -q "перехожу на общий режим" "$1"' _ "$T/srv1/bot.log"
check "в состоянии снова MODE=single" grep -q '^MODE=single' "$T/srv1/state/bot.state"
n=$(sent)
say 777 /status
check "ответ пришёл" wait_sent $((n + 1)) 10
check "и только один" quiet_for 2
stop_bot srv1

# ---------------------------------------------------------------- 7. ошибки Telegram
section "7. ошибки Telegram: бот пишет в журнал один раз и ждёт"
server wrong 'TELEGRAM_BOT_TOKEN="42:WRONG"'
start_bot wrong
check "неверный токен: в журнале 401 и подсказка" wait_log wrong "401 Unauthorized (Telegram не принимает токен" 10
sleep 2
check "неверный токен: запись одна" [ "$(grep -c '401 Unauthorized' "$T/wrong/bot.log")" -eq 1 ]
check "неверный токен: бот работает и ждёт" kill -0 "${PID[wrong]}"
stop_bot wrong
server offline
start_bot offline AAU_TELEGRAM_API=http://127.0.0.1:9
check "нет связи: в журнале причина и повтор через 5 с" wait_log offline "нет связи с Telegram (.*), повторяю через 5 с" 10
sleep 7
check "нет связи: повторы не пишутся в журнал заново" [ "$(grep -c 'повторяю через' "$T/offline/bot.log")" -eq 1 ]
check "нет связи: бот работает" kill -0 "${PID[offline]}"
stop_bot offline
server hook
curl -fsS -o /dev/null "$API/test/webhook?on=1"
start_bot hook
check "у бота webhook: понятное сообщение" wait_log hook "у бота включён webhook" 10
stop_bot hook
curl -fsS -o /dev/null "$API/test/webhook?on=0"

section "итог: $PASS прошло, $FAILED не прошло"
(( FAILED == 0 ))
