#!/usr/bin/env bash
# shellcheck disable=SC2016,SC1090  # одинарные кавычки и source здесь намеренные
#
# Сквозной тест amnezia-autoupdate в Docker. ЗАПУСКАТЬ ТОЛЬКО НА ОДНОРАЗОВОЙ МАШИНЕ:
# тест удаляет контейнеры amnezia-*, /opt/amnezia и меняет iptables/sysctl хоста.
#
#   sudo bash tests/e2e.sh /путь/к/amnezia-client/client/server_scripts
#
# Берутся настоящие серверные скрипты приложения (run_container.sh, start.sh,
# configure_container.sh, build_container.sh, prepare_host.sh, setup_host_firewall.sh).
# В Dockerfile убираются только шаги apk/curl, которым нужен интернет внутри сборки:
# нужные программы заранее кладутся в базовые образы из локального registry.
# Через тот же registry проверяется обновление базового образа.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=${1:-${AMNEZIA_SERVER_SCRIPTS:-}}
[[ -d $SRC/awg && -f $SRC/run_container.sh || -d $SRC/awg && -f $SRC/build_container.sh ]] \
  || { echo "usage: $0 /path/to/amnezia-client/client/server_scripts"; exit 2; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }

T=$(mktemp -d /tmp/aau-e2e.XXXXXX)
export AAU_CONF=$T/amnezia-autoupdate.conf
export AAU_STATE_DIR=$T/state
export AAU_BACKUP_DIR=$T/backups
export AAU_LOG_FILE=$T/amnezia-autoupdate.log
export AAU_LOCK_FILE=$T/lock
AAU=(bash "$ROOT/amnezia-autoupdate")
REG=localhost:5000/aau-test
XRAY_RELEASE=$(sed -n 's/^ARG XRAY_RELEASE="\(.*\)"/\1/p' "$SRC/xray/Dockerfile")
XRAY_VERSION=${XRAY_RELEASE#v}

PASS=0
FAILED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
section() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run_aau() { "${AAU[@]}" "$@" > "$T/last.out" 2>&1; local rc=$?; sed 's/^/    | /' "$T/last.out"; return $rc; }
out_has() { grep -q -- "$1" "$T/last.out"; }

wipe_amnezia() {
  local c
  for c in $(docker ps -a --format '{{.Names}}' | grep -E '^amnezia-'); do docker rm -f "$c" >/dev/null; done
  docker volume ls -q | grep -E '^amnezia-' | xargs -r docker volume rm -f >/dev/null
  docker network rm amnezia-dns-net >/dev/null 2>&1
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^amnezia-' | xargs -r docker rmi -f >/dev/null 2>&1
  rm -rf /opt/amnezia
}

awg_pub()   { docker exec amnezia-awg2 awg show awg0 public-key 2>/dev/null; }
awg_peers() { docker exec amnezia-awg2 awg show awg0 peers 2>/dev/null | sort | tr '\n' ' '; }
wg_pub()    { docker exec amnezia-wireguard wg show wg0 public-key 2>/dev/null; }
wg_peers()  { docker exec amnezia-wireguard wg show wg0 peers 2>/dev/null | sort | tr '\n' ' '; }
in_sha()    { docker exec "$1" sha256sum "$2" 2>/dev/null | cut -d' ' -f1; }
img_of()    { docker container inspect -f '{{.Image}}' "$1" 2>/dev/null; }
running()   { [[ $(docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }
no_prev()   { ! docker ps -a --format '{{.Names}}' | grep -q -- '-aau-prev$'; }
xray_listen() { docker exec amnezia-xray sh -c 'pidof xray >/dev/null && netstat -ltn | grep -q ":443 "'; }

snapshot() {   # запоминаем то, что не должно измениться после обновления
  S_AWG_PUB=$(awg_pub)
  S_AWG_PEERS=$(awg_peers)
  S_AWG_CONF=$(in_sha amnezia-awg2 /opt/amnezia/awg/awg0.conf)
  S_AWG_TABLE=$(in_sha amnezia-awg2 /opt/amnezia/awg/clientsTable)
  S_XRAY_JSON=$(in_sha amnezia-xray /opt/amnezia/xray/server.json)
  S_XRAY_PRIV=$(in_sha amnezia-xray /opt/amnezia/xray/xray_private.key)
  S_XRAY_TABLE=$(in_sha amnezia-xray /opt/amnezia/xray/clientsTable)
  S_WG_PUB=$(wg_pub)
  S_WG_PEERS=$(wg_peers)
}
same_as_snapshot() {
  check "AmneziaWG: тот же ключ сервера" [ "$(awg_pub)" == "$S_AWG_PUB" ]
  check "AmneziaWG: те же клиенты ($S_AWG_PEERS)" [ "$(awg_peers)" == "$S_AWG_PEERS" ]
  check "AmneziaWG: awg0.conf не изменился" [ "$(in_sha amnezia-awg2 /opt/amnezia/awg/awg0.conf)" == "$S_AWG_CONF" ]
  check "AmneziaWG: clientsTable не изменился" [ "$(in_sha amnezia-awg2 /opt/amnezia/awg/clientsTable)" == "$S_AWG_TABLE" ]
  check "XRay: server.json не изменился" [ "$(in_sha amnezia-xray /opt/amnezia/xray/server.json)" == "$S_XRAY_JSON" ]
  check "XRay: приватный ключ не изменился" [ "$(in_sha amnezia-xray /opt/amnezia/xray/xray_private.key)" == "$S_XRAY_PRIV" ]
  check "XRay: clientsTable не изменился" [ "$(in_sha amnezia-xray /opt/amnezia/xray/clientsTable)" == "$S_XRAY_TABLE" ]
  check "XRay: слушает 443" xray_listen
  check "DNS: работает" running amnezia-dns
  check "WireGuard: тот же ключ сервера" [ "$(wg_pub)" == "$S_WG_PUB" ]
  check "WireGuard: те же клиенты" [ "$(wg_peers)" == "$S_WG_PEERS" ]
}

# ---------------------------------------------------------------- подготовка
section "подготовка: registry, базовые образы, копия скриптов приложения"
wipe_amnezia
docker rm -f aau-registry >/dev/null 2>&1
docker run -d --name aau-registry -p 127.0.0.1:5000:5000 registry:2 >/dev/null
sleep 2

mkdir -p "$T/base"
cat > "$T/base/dumb-init" <<'EOF'
#!/bin/sh
# тестовая замена dumb-init
exec "$@"
EOF
cat > "$T/base/openssl" <<'EOF'
#!/bin/sh
# тестовая замена "openssl rand -hex N"
n=${3:-8}; head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n'; echo
EOF
chmod 755 "$T/base/dumb-init" "$T/base/openssl"
curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_RELEASE}/Xray-linux-64.zip" -o "$T/base/xray.zip" \
  || { echo "не удалось скачать Xray"; exit 1; }
(cd "$T/base" && python3 -c "import zipfile; zipfile.ZipFile('xray.zip').extract('xray')" && chmod 755 xray)

build_base() {   # build_base NAME FROM [extra RUN]
  cat > "$T/base/Dockerfile.$1" <<EOF
FROM $2
COPY dumb-init openssl /usr/bin/
${4:-}
RUN ${3:-true}
EOF
  docker build -q -f "$T/base/Dockerfile.$1" -t "$REG/$1-base:latest" "$T/base" >/dev/null && docker push -q "$REG/$1-base:latest" >/dev/null
}
build_base awg amneziavpn/amneziawg-go:latest
build_base awglegacy amneziavpn/amnezia-wg:latest
build_base xray amneziavpn/amneziawg-go:latest "mkdir -p /opt/amnezia/xray" "COPY xray /usr/bin/xray"
# DNS как есть, только из локального registry (сборки в тесте не ходят в Docker Hub)
docker image inspect mvance/unbound:latest >/dev/null 2>&1 || docker pull -q mvance/unbound:latest >/dev/null
docker tag mvance/unbound:latest "$REG/unbound-base:latest" && docker push -q "$REG/unbound-base:latest" >/dev/null
check "базовые образы в локальном registry" docker pull -q "$REG/awg-base:latest"

cp -r "$SRC" "$T/upstream"
python3 - "$T/upstream" "$REG" <<'EOF'
import re, sys
up, reg = sys.argv[1], sys.argv[2]
def patch(path, base):
    lines = open(path).read().split('\n')
    out, skip = [], False
    for ln in lines:
        if skip:
            skip = ln.rstrip().endswith('\\')
            continue
        s = ln.strip()
        if s.upper().startswith('FROM '):
            out.append(f'FROM {base}'); continue
        if s.startswith('RUN apk') or s.startswith('RUN curl'):
            skip = ln.rstrip().endswith('\\'); continue
        out.append(ln)
    open(path, 'w').write('\n'.join(out))
patch(f'{up}/awg/Dockerfile', f'{reg}/awg-base:latest')
patch(f'{up}/awg_legacy/Dockerfile', f'{reg}/awglegacy-base:latest')
patch(f'{up}/xray/Dockerfile', f'{reg}/xray-base:latest')
patch(f'{up}/wireguard/Dockerfile', f'{reg}/awglegacy-base:latest')
patch(f'{up}/dns/Dockerfile', f'{reg}/unbound-base:latest')
EOF
cat > "$AAU_CONF" <<EOF
UPSTREAM_LOCAL_DIR="$T/upstream"
OS_UPDATE="no"
HEALTH_TIMEOUT="45"
KEEP_BACKUPS="3"
EOF
chmod 600 "$AAU_CONF"
echo "  тестовая папка: $T"
grep -n '^FROM\|^ENTRYPOINT' "$T/upstream/awg/Dockerfile" "$T/upstream/xray/Dockerfile" | sed 's/^/    /'

# ---------------------------------------------------------------- 1. развёртывание
section "1. deploy awg,xray,dns,wireguard по скриптам приложения"
run_aau deploy awg,xray,dns,wireguard
check "deploy завершился без ошибок" [ $? -eq 0 ]
check "amnezia-awg2 работает" running amnezia-awg2
check "amnezia-xray работает" running amnezia-xray
check "amnezia-dns работает" running amnezia-dns
check "awg0.conf на порту 55424" docker exec amnezia-awg2 grep -q '^ListenPort = 55424' /opt/amnezia/awg/awg0.conf
check "awg0.conf с параметрами AWG 2 (HeaderProtectionKey)" docker exec amnezia-awg2 grep -q '^HeaderProtectionKey = ' /opt/amnezia/awg/awg0.conf
check "в awg0.conf нет пустых параметров" bash -c '! docker exec amnezia-awg2 grep -qE "^[^=#]*= *$" /opt/amnezia/awg/awg0.conf'
check "у xray данные в volume amnezia-xray-data" docker volume inspect amnezia-xray-data
check "xray слушает 443" xray_listen
check "Dockerfile лежит в /opt/amnezia/amnezia-awg2 как у приложения" cmp -s /opt/amnezia/amnezia-awg2/Dockerfile "$T/upstream/awg/Dockerfile"
check "порты опубликованы как у приложения" bash -c 'docker ps --format "{{.Names}} {{.Ports}}" | grep -E "^amnezia-awg2 .*:55424->55424/udp"'
check "amnezia-wireguard работает" running amnezia-wireguard
check "wg0.conf WireGuard на порту 51820" docker exec amnezia-wireguard grep -q '^ListenPort = 51820' /opt/amnezia/wireguard/wg0.conf
check "WireGuard слушает 51820" bash -c '[ "$(docker exec amnezia-wireguard wg show wg0 listen-port)" == 51820 ] || docker exec amnezia-wireguard sh -c "netstat -lnu | grep -q :51820\ "'

# ---------------------------------------------------------------- 2. клиенты как в приложении
section "2. добавляю клиентов так, как это делает приложение"
PSK=$(docker exec amnezia-awg2 cat /opt/amnezia/awg/wireguard_psk.key)
TABLE='['
for i in 2 3 4; do
  priv=$(docker exec amnezia-awg2 awg genkey)
  pub=$(printf '%s\n' "$priv" | docker exec -i amnezia-awg2 awg pubkey)
  docker exec amnezia-awg2 sh -c "printf '\n[Peer]\nPublicKey = $pub\nPresharedKey = $PSK\nAllowedIPs = 10.8.1.$i/32\n\n' >> /opt/amnezia/awg/awg0.conf"
  TABLE+="{\"clientId\":\"$pub\",\"userData\":{\"clientName\":\"user$i\",\"creationDate\":\"Mon Nov 9 2026\"}},"
done
TABLE="${TABLE%,}]"
printf '%s' "$TABLE" | docker exec -i amnezia-awg2 sh -c 'cat > /opt/amnezia/awg/clientsTable'
docker exec amnezia-awg2 bash -c 'awg syncconf awg0 <(awg-quick strip /opt/amnezia/awg/awg0.conf)'
check "у AmneziaWG 3 клиента" [ "$(docker exec amnezia-awg2 awg show awg0 peers | wc -l)" -eq 3 ]
WPSK=$(docker exec amnezia-wireguard cat /opt/amnezia/wireguard/wireguard_psk.key)
wpub=$(docker exec amnezia-wireguard wg genkey | docker exec -i amnezia-wireguard wg pubkey)
docker exec amnezia-wireguard sh -c "printf '\n[Peer]\nPublicKey = $wpub\nPresharedKey = $WPSK\nAllowedIPs = 10.8.1.2/32\n\n' >> /opt/amnezia/wireguard/wg0.conf"
docker exec amnezia-wireguard bash -c 'wg syncconf wg0 <(wg-quick strip /opt/amnezia/wireguard/wg0.conf)'
check "у WireGuard 1 клиент" [ "$(docker exec amnezia-wireguard wg show wg0 peers | wc -l)" -eq 1 ]
U2=$(docker exec amnezia-xray xray uuid)
docker exec amnezia-xray sh -c "cd /opt/amnezia/xray && jq --version >/dev/null 2>&1" || true
docker cp amnezia-xray:/opt/amnezia/xray/server.json "$T/server.json"
jq --arg id "$U2" '.inbounds[0].settings.clients += [{id: $id, flow: "xtls-rprx-vision"}]' "$T/server.json" > "$T/server2.json"
docker cp "$T/server2.json" amnezia-xray:/opt/amnezia/xray/server.json
printf '[{"clientId":"%s","userData":{"clientName":"phone"}}]' "$U2" | docker exec -i amnezia-xray sh -c 'cat > /opt/amnezia/xray/clientsTable'
docker restart amnezia-xray >/dev/null
sleep 4
check "у XRay 2 клиента в server.json" [ "$(docker exec amnezia-xray cat /opt/amnezia/xray/server.json | jq '.inbounds[0].settings.clients | length')" -eq 2 ]
snapshot

# ---------------------------------------------------------------- 3. проверка без изменений
section "3. check: всё актуально"
run_aau check
check "awg2 актуален" out_has "amnezia-awg2: актуален"
check "xray актуален" out_has "amnezia-xray: актуален"
check "dns актуален" out_has "amnezia-dns: актуален"
check "wireguard актуален" out_has "amnezia-wireguard: актуален"

# ---------------------------------------------------------------- 4. принудительное обновление
section "4. update-containers --force: пересборка с сохранением ключей и клиентов"
OLD_AWG_IMG=$(img_of amnezia-awg2)
run_aau update-containers --force
check "обновление без ошибок" [ $? -eq 0 ]
check "образ awg2 новый" [ "$(img_of amnezia-awg2)" != "$OLD_AWG_IMG" ]
same_as_snapshot
check "DNS на прежнем адресе 172.29.172.254" bash -c '[ "$(docker inspect -f "{{(index .NetworkSettings.Networks \"amnezia-dns-net\").IPAddress}}" amnezia-dns)" == 172.29.172.254 ]'
check "временных контейнеров не осталось" no_prev
check "есть резервная копия" bash -c "ls -d $AAU_BACKUP_DIR/*/amnezia-awg2/opt-amnezia/awg >/dev/null"

# ---------------------------------------------------------------- 5. новый Dockerfile в релизе
section "5. на сервере старый Dockerfile: обновляется только awg2"
echo "# old build" >> /opt/amnezia/amnezia-awg2/Dockerfile
run_aau check
check "check видит новый Dockerfile у awg2" out_has "amnezia-awg2: нужно обновление: новый Dockerfile"
check "xray при этом актуален" out_has "amnezia-xray: актуален"
run_aau update-containers
check "обновление прошло" out_has "amnezia-awg2 обновлён"
check "Dockerfile на хосте теперь из релиза" cmp -s /opt/amnezia/amnezia-awg2/Dockerfile "$T/upstream/awg/Dockerfile"
same_as_snapshot

# ---------------------------------------------------------------- 6. новый базовый образ
section "6. вышел новый базовый образ amneziawg-go"
build_base awg amneziavpn/amneziawg-go:latest "touch /etc/aau-base-v2"
run_aau check
check "check видит новый базовый образ" out_has "новый базовый образ $REG/awg-base:latest"
run_aau update-containers
check "awg2 пересобран на новом базовом образе" docker exec amnezia-awg2 test -f /etc/aau-base-v2
same_as_snapshot

# ---------------------------------------------------------------- 7. откат
section "7. новый релиз сломан: контейнер не стартует, должен вернуться старый"
cp "$T/upstream/awg/Dockerfile" "$T/awg.Dockerfile.good"
sed -i 's|^ENTRYPOINT .*|ENTRYPOINT [ "/bin/false" ]|' "$T/upstream/awg/Dockerfile"
GOOD_IMG=$(img_of amnezia-awg2)
run_aau update-containers
check "запуск завершился с ошибкой" [ $? -ne 0 ]
check "в журнале откат" out_has "возвращаю прежний контейнер"
check "прежний контейнер снова работает" out_has "прежний контейнер снова работает"
check "работает прежний образ" [ "$(img_of amnezia-awg2)" == "$GOOD_IMG" ]
same_as_snapshot
check "временных контейнеров не осталось" no_prev
cp "$T/awg.Dockerfile.good" "$T/upstream/awg/Dockerfile"

section "7b. сломанный образ (нет awg-quick) не проходит предварительную проверку"
sed -i '/^LABEL/a RUN rm -f /usr/bin/awg-quick' "$T/upstream/awg/Dockerfile"
run_aau update-containers
check "обновление отклонено до остановки старого" out_has "не прошёл предварительную проверку"
check "работает прежний образ" [ "$(img_of amnezia-awg2)" == "$GOOD_IMG" ]
cp "$T/awg.Dockerfile.good" "$T/upstream/awg/Dockerfile"

# ---------------------------------------------------------------- 8. прерванное обновление
section "8. сервер выключился посреди обновления"
docker stop amnezia-awg2 >/dev/null
docker update --restart no amnezia-awg2 >/dev/null
docker rename amnezia-awg2 amnezia-awg2-aau-prev
docker run -d --name amnezia-awg2 --entrypoint sleep "$REG/awg-base:latest" 3600 >/dev/null
run_aau host-setup
check "при загрузке вернулся прежний контейнер" bash -c '[ "$(docker exec amnezia-awg2 awg show awg0 public-key)" == "'"$S_AWG_PUB"'" ]'
check "временных контейнеров не осталось" no_prev
check "политика перезапуска always" [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' amnezia-awg2)" == always ]

# ---------------------------------------------------------------- 9. экспорт и импорт
section "9. экспорт базы и импорт на «новый» сервер"
run_aau export "$T/export.tar.gz"
check "экспорт без ошибок" [ $? -eq 0 ]
check "архив экспорта создан" [ -s "$T/export.tar.gz" ]
check "права архива 600" [ "$(stat -c %a "$T/export.tar.gz")" == 600 ]
wipe_amnezia
check "контейнеров не осталось" bash -c '! docker ps -a --format "{{.Names}}" | grep -q "^amnezia-"'
run_aau import "$T/export.tar.gz"
check "импорт без ошибок" [ $? -eq 0 ]
same_as_snapshot
check "DNS после импорта на адресе 172.29.172.254" bash -c '[ "$(docker inspect -f "{{(index .NetworkSettings.Networks \"amnezia-dns-net\").IPAddress}}" amnezia-dns)" == 172.29.172.254 ]'
check "restore для DNS отказывается" bash -c '! "$@" restore amnezia-dns >/dev/null 2>&1' _ "${AAU[@]}"

# ---------------------------------------------------------------- 10. legacy AmneziaWG
section "10. старый AmneziaWG (amnezia-awg, как ставили прежние версии приложения)"
python3 - "$T/upstream/awg_legacy/configure_container.sh" "$T/legacy-configure.sh" <<'EOF'
import sys
s = open(sys.argv[1]).read()
v = {"$AWG_SUBNET_IP": "10.8.2.0", "$WIREGUARD_SUBNET_CIDR": "24", "$AWG_SERVER_PORT": "41820",
     "$JUNK_PACKET_COUNT": "4", "$JUNK_PACKET_MIN_SIZE": "10", "$JUNK_PACKET_MAX_SIZE": "50",
     "$INIT_PACKET_JUNK_SIZE": "60", "$RESPONSE_PACKET_JUNK_SIZE": "40",
     "$INIT_PACKET_MAGIC_HEADER": "1325318710", "$RESPONSE_PACKET_MAGIC_HEADER": "1785404561",
     "$UNDERLOAD_PACKET_MAGIC_HEADER": "1121396830", "$TRANSPORT_PACKET_MAGIC_HEADER": "1573312155"}
for k in sorted(v, key=len, reverse=True): s = s.replace(k, v[k])
open(sys.argv[2], "w").write(s)
EOF
mkdir -p /opt/amnezia/amnezia-awg && cp "$T/upstream/awg_legacy/Dockerfile" /opt/amnezia/amnezia-awg/Dockerfile
docker build -q --no-cache --pull -t amnezia-awg /opt/amnezia/amnezia-awg >/dev/null
sed -e 's/\$AWG_SERVER_PORT/41820/g' -e 's/\$CONTAINER_NAME/amnezia-awg/g' "$T/upstream/awg_legacy/run_container.sh" | bash >/dev/null 2>&1
docker cp "$T/legacy-configure.sh" amnezia-awg:/opt/amnezia/configure.sh && docker exec amnezia-awg bash /opt/amnezia/configure.sh
sed -e 's/\$AWG_SUBNET_IP/10.8.2.0/g' -e 's/\$WIREGUARD_SUBNET_CIDR/24/g' "$T/upstream/awg_legacy/start.sh" > "$T/legacy-start.sh"
# start.sh запускается так же, как в конце установки в приложении
docker cp "$T/legacy-start.sh" amnezia-awg:/opt/amnezia/start.sh
docker exec -d amnezia-awg sh -c "chmod a+x /opt/amnezia/start.sh && /opt/amnezia/start.sh"
sleep 4
L_PUB=$(docker exec amnezia-awg wg show wg0 public-key 2>/dev/null)
check "legacy amnezia-awg поднят (wg0)" [ -n "$L_PUB" ]
LPSK=$(docker exec amnezia-awg cat /opt/amnezia/awg/wireguard_psk.key)
lpub=$(docker exec amnezia-awg wg genkey | docker exec -i amnezia-awg wg pubkey)
docker exec amnezia-awg sh -c "printf '\n[Peer]\nPublicKey = $lpub\nPresharedKey = $LPSK\nAllowedIPs = 10.8.2.2/32\n\n' >> /opt/amnezia/awg/wg0.conf"
docker exec amnezia-awg bash -c 'wg syncconf wg0 <(wg-quick strip /opt/amnezia/awg/wg0.conf)'
check "legacy: 1 клиент" [ "$(docker exec amnezia-awg wg show wg0 peers | wc -l)" -eq 1 ]
run_aau update-containers --force --only amnezia-awg
check "legacy обновлён" out_has "amnezia-awg обновлён"
check "legacy: тот же ключ сервера" [ "$(docker exec amnezia-awg wg show wg0 public-key 2>/dev/null)" == "$L_PUB" ]
check "legacy: клиент на месте" [ "$(docker exec amnezia-awg wg show wg0 peers 2>/dev/null)" == "$lpub" ]

# ---------------------------------------------------------------- 11. прочее
section "11. restore, backups, status"
run_aau restore amnezia-awg2
check "restore без ошибок" [ $? -eq 0 ]
check "после restore тот же ключ" [ "$(awg_pub)" == "$S_AWG_PUB" ]
run_aau backups
check "у каждого контейнера не больше KEEP_BACKUPS=3 копий" bash -c '! find "$1" -mindepth 2 -maxdepth 2 -type d -printf "%f\n" | sort | uniq -c | awk "\$1 > 3" | grep -q .' _ "$AAU_BACKUP_DIR"
check "копии awg2 не вытеснены копиями других контейнеров" [ "$(find "$AAU_BACKUP_DIR" -mindepth 2 -maxdepth 2 -type d -name amnezia-awg2 | wc -l)" -eq 3 ]
run_aau status
check "status показывает контейнеры" out_has "amnezia-awg2: работает"
check "status: клиенты AmneziaWG (никто не подключён)" out_has "^  amnezia-awg2: работает, клиентов: 3, на связи: 0$"
check "status: клиенты XRay" out_has "^  amnezia-xray: работает, клиентов: 2$"
check "status: клиенты WireGuard" out_has "^  amnezia-wireguard: работает, клиентов: 1, на связи: 0$"
check "status: версии и откуда контейнер (импорт из шага 9)" out_has "^    amneziawg-go [0-9.]*, awg [0-9.]*; импортирован 20.* (релиз local)$"
check "status: итог последнего запуска" out_has "^Последний запуск: 20.*, итог: ok$"

# ---------------------------------------------------------------- 11b. бот Telegram
section "11b. бот Telegram: /status с настоящими контейнерами (заглушка Bot API)"
python3 "$ROOT/tests/telegram-mock.py" "$T/tg" 42:TEST 777 > "$T/tg-mock.log" 2>&1 &
MOCK=$!
trap 'declare -F bot_stop >/dev/null && bot_stop; kill $MOCK 2>/dev/null' EXIT
for _ in $(seq 50); do [[ -s $T/tg/port ]] && break; sleep 0.1; done
AAU_TELEGRAM_API="http://127.0.0.1:$(cat "$T/tg/port")"
export AAU_TELEGRAM_API
touch "$T/tg/sent.jsonl"
# Служба бота видит свой /tmp (PrivateTmp), поэтому настройки и состояние бота не в $T
BOTDIR=/var/lib/aau-e2e-bot
rm -rf "$BOTDIR"
mkdir -p "$BOTDIR"
cp -a "$AAU_STATE_DIR" "$BOTDIR/state"
cp "$AAU_CONF" "$BOTDIR/bot.conf"
printf 'TELEGRAM_BOT_TOKEN="42:TEST"\nTELEGRAM_CHAT_ID="777"\nSERVER_NAME="e2e"\n' >> "$BOTDIR/bot.conf"
BOT_ENV=(AAU_CONF="$BOTDIR/bot.conf" AAU_STATE_DIR="$BOTDIR/state" AAU_BACKUP_DIR="$BOTDIR/backups"
         AAU_LOG_FILE="$BOTDIR/log" AAU_LOCK_FILE="$BOTDIR/lock" AAU_TELEGRAM_API="$AAU_TELEGRAM_API" AAU_BOT_TIMEOUT=5)
if [[ -d /run/systemd/system ]] && command -v systemd-run >/dev/null 2>&1; then
  # как служба amnezia-autoupdate-bot: с теми же ограничениями, что пишет write_bot_unit
  BOT_PROPS=()
  while IFS= read -r p; do BOT_PROPS+=(-p "$p"); done < <(sed -n '/^write_bot_unit()/,/^EOF/p' "$ROOT/amnezia-autoupdate" \
    | grep -E '^(NoNewPrivileges|PrivateTmp|ProtectSystem|MemoryMax|Nice)=')
  check "в write_bot_unit найдены 5 ограничений службы" [ "${#BOT_PROPS[@]}" -eq 10 ]
  for e in "${BOT_ENV[@]}"; do BOT_PROPS+=(-E "$e"); done
  systemctl reset-failed aau-e2e-bot.service >/dev/null 2>&1
  systemd-run --quiet --unit aau-e2e-bot --collect "${BOT_PROPS[@]}" "$(command -v bash)" "$ROOT/amnezia-autoupdate" bot
  bot_stop() { systemctl stop aau-e2e-bot.service >/dev/null 2>&1; }
  bot_log() { journalctl -u aau-e2e-bot.service --no-pager -o cat 2>/dev/null; }
  echo "  бот запущен как служба aau-e2e-bot"
else
  env "${BOT_ENV[@]}" bash "$ROOT/amnezia-autoupdate" bot > "$BOTDIR/bot.log" 2>&1 &
  BOT=$!
  bot_stop() { kill "$BOT" 2>/dev/null; wait "$BOT" 2>/dev/null; }
  bot_log() { cat "$BOTDIR/bot.log"; }
fi
for _ in $(seq 100); do jq -e 'select(.method == "getUpdates")' "$T/tg/calls.jsonl" >/dev/null 2>&1 && break; sleep 0.1; done
sleep 0.5
curl -fsS -o /dev/null "$AAU_TELEGRAM_API/test/message" -d chat_id=777 --data-urlencode text=/status
for _ in $(seq 300); do [[ -s $T/tg/sent.jsonl ]] && break; sleep 0.1; done
jq -r .text "$T/tg/sent.jsonl" > "$T/bot-reply.txt"
sed 's/^/    | /' "$T/bot-reply.txt"
check "бот ответил на /status" grep -q '^\[e2e\] amnezia-autoupdate ' "$T/bot-reply.txt"
check "в ответе AmneziaWG и его клиенты" grep -q '^  amnezia-awg2: работает, клиентов: 3, на связи: 0$' "$T/bot-reply.txt"
check "в ответе XRay" grep -q '^  amnezia-xray: работает, клиентов: 2$' "$T/bot-reply.txt"
check "в ответе DNS" grep -q '^  amnezia-dns: работает$' "$T/bot-reply.txt"
for _ in $(seq 30); do bot_log | grep -q "ответил на /status" && break; sleep 0.2; done
check "журнал бота" bash -c 'grep -q "ответил на /status" <<< "$1"' _ "$(bot_log)"
check "бот сохранил состояние" grep -q '^LAST_ID=[0-9]' "$BOTDIR/state/bot.state"
bot_stop
bot_log | sed 's/^/    | /'
rm -rf "$BOTDIR"

# ---------------------------------------------------------------- 12. ночной запуск
section "12. run: то, что каждую ночь запускает таймер (без ОС и перезагрузки)"
# старые записи на 3 МБ при LOG_MAX_MB=1: журнал должен обрезаться с начала
printf 'LOG_MAX_MB="1"\n' >> "$AAU_CONF"
# отчёт после каждого запуска в заглушку Telegram
printf 'TELEGRAM_BOT_TOKEN="42:TEST"\nTELEGRAM_CHAT_ID="777"\nNOTIFY="always"\n' >> "$AAU_CONF"
: > "$T/tg/sent.jsonl"
seq 1 60000 | sed 's/^/2026-01-01 00:00:00 старая запись журнала номер /' >> "$AAU_LOG_FILE"
run_aau run --no-os --no-reboot
check "run завершился без ошибок" [ $? -eq 0 ]
check "контейнеры актуальны" out_has "amnezia-awg2: актуален"
check "в журнале как запущен" out_has "запуск вручную на"
check "в журнале ОС и ядро" out_has "ОС: .*, ядро $(uname -r)"
check "в журнале релиз Amnezia" out_has "серверные скрипты Amnezia: релиз"
check "в журнале версия AmneziaWG" out_has "amnezia-awg2: актуален (amneziawg-go [0-9.]*, awg [0-9.]*, релиз Amnezia"
check "в журнале версия XRay" out_has "amnezia-xray: актуален (xray $XRAY_VERSION, релиз Amnezia"
check "в журнале версия unbound" out_has "amnezia-dns: актуален (unbound [0-9.]*, релиз Amnezia"
check "в журнале итог: обновлять нечего" out_has "=== итог: ok, всё актуально, обновлять нечего, заняло"
check "журнал обрезан до LOG_MAX_MB=1" [ "$(stat -c %s "$AAU_LOG_FILE")" -le $((1024 * 1024)) ]
check "в конце журнала этот запуск" bash -c 'tail -n 1 "$1" | grep -q "=== итог: ok"' _ "$AAU_LOG_FILE"
check "журнал начинается с целой строки" bash -c 'head -n 1 "$1" | grep -qE "^2026-01-01 00:00:00 старая запись журнала номер [0-9]+$"' _ "$AAU_LOG_FILE"
check "отчёт ушёл в Telegram" bash -c 'jq -r .text "$1" | grep -q "^\[.*\] Amnezia autoupdate$"' _ "$T/tg/sent.jsonl"
# Запуск так же, как его делает таймер: отдельным сервисом systemd (на машинах с systemd, например в CI)
if [[ -d /run/systemd/system ]] && command -v systemd-run >/dev/null 2>&1; then
  systemd-run --quiet --wait --pipe --collect \
    -E AAU_CONF="$AAU_CONF" -E AAU_STATE_DIR="$AAU_STATE_DIR" -E AAU_BACKUP_DIR="$AAU_BACKUP_DIR" \
    -E AAU_LOG_FILE="$AAU_LOG_FILE" -E AAU_LOCK_FILE="$AAU_LOCK_FILE" -E AAU_TELEGRAM_API="$AAU_TELEGRAM_API" \
    "$(command -v bash)" "$ROOT/amnezia-autoupdate" run --no-os --no-reboot > "$T/last.out" 2>&1
  rc=$?
  sed 's/^/    | /' "$T/last.out"
  check "через systemd: run без ошибок" [ $rc -eq 0 ]
  check "через systemd: в журнале запуск по расписанию" out_has "запуск по расписанию на"
fi
check "настройки хоста применены" out_has "сетевые настройки хоста применены"
check "итог ok записан" grep -q '^RESULT=ok' "$AAU_STATE_DIR/last-run"
check "после ночного запуска тот же ключ AmneziaWG" [ "$(awg_pub)" == "$S_AWG_PUB" ]

# ---------------------------------------------------------------- итог
section "итог: $PASS прошло, $FAILED не прошло"
docker rm -f aau-registry >/dev/null 2>&1
(( FAILED == 0 ))
