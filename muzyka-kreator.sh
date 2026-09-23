#!/usr/bin/env bash
# =====================================================================
#  muzyka-kreator.sh – kreator głośników Bluetooth dla LMS (Proxmox)
#
#  Uruchamiać na HOŚCIE Proxmoksa jako root:
#      multiroom   (po instalacji instalatorem)  albo:  bash muzyka-kreator.sh
#
#  Wszystkie głośniki obsługuje JEDEN kontener (wykrywany automatycznie).
#  Każdy głośnik dostaje własną instancję Squeezelite (squeezelite@NAZWA),
#  własne urządzenie ALSA (bt_NAZWA) i unikalny adres MAC odtwarzacza,
#  żeby LMS widział je jako osobne odtwarzacze (multiroom).
#
#  Istniejąca, ręczna konfiguracja (squeezelite.service) NIE jest ruszana.
# =====================================================================
set -uo pipefail

DEFAULT_CTID=""   # numer kontenera z muzyką (puste = wykryj automatycznie)
LMS_IP=""         # adres LMS dla Squeezelite (puste = wykryj automatycznie)
LMS_WEB=""        # adres panelu WWW LMS (puste = wylicz z LMS_IP)
# Instalator zapisuje tu swoje ustawienia (numer kontenera, adres LMS):
# shellcheck disable=SC1091
[[ -f /etc/muzyka-kreator.conf ]] && source /etc/muzyka-kreator.conf
TITLE="Multiroom na Proxmoksie"
HELPER=/usr/local/sbin/muzyka-helper.sh
CTID=""

# ---------- sprawdzenia wstępne ----------
if [[ $EUID -ne 0 ]]; then echo "Uruchom jako root."; exit 1; fi
if ! command -v pct >/dev/null; then echo "Brak polecenia pct – uruchom na hoście Proxmoksa."; exit 1; fi
if ! command -v whiptail >/dev/null; then apt-get install -y whiptail || exit 1; fi

# ---------- okienka ----------
msg()   { whiptail --title "$TITLE" --msgbox "$1" "${2:-12}" "${3:-74}"; }
info()  { TERM=ansi whiptail --title "$TITLE" --infobox "$1" 9 74; }
ask()   { whiptail --title "$TITLE" --yesno "$1" "${2:-12}" "${3:-74}"; }
input() { whiptail --title "$TITLE" --inputbox "$1" 11 74 "${2:-}" 3>&1 1>&2 2>&3; }
showfile() { whiptail --title "$TITLE" --scrolltext --textbox "$1" 22 90; }

hx() { pct exec "$CTID" -- "$HELPER" "$@"; }

slugify() {
  local s="$1" i
  local from=(ą ć ę ł ń ó ś ź ż Ą Ć Ę Ł Ń Ó Ś Ź Ż)
  local to=(a c e l n o s z z a c e l n o s z z)
  for i in "${!from[@]}"; do s=${s//${from[$i]}/${to[$i]}}; done
  s=$(printf '%s' "$s" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | tr -s '-')
  s=${s#-}; s=${s%-}; s=${s:0:20}
  [[ -z $s ]] && s="glosnik"
  printf '%s' "$s"
}

# =====================================================================
#  Skrypt pomocniczy wgrywany do kontenera
# =====================================================================
write_helper() {
cat <<'HELPER_EOF'
#!/bin/bash
set -uo pipefail
CONF_DIR=/etc/muzyka
ASOUND=/etc/asound.conf
mkdir -p "$CONF_DIR"

is_connected() { bluetoothctl info "$1" 2>/dev/null | grep -q "Connected: yes"; }
strip_colors() { sed 's/\x1b\[[0-9;]*m//g; s/\r//g'; }

cmd_check() {
  local p missing=()
  for p in bluez bluez-alsa-utils squeezelite alsa-utils; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  echo "${missing[*]:-}"
}

cmd_install() {
  export DEBIAN_FRONTEND=noninteractive
  export PKGSYSTEM_ENABLE_FSYNC=0
  apt-get update && apt-get install -y --no-install-recommends bluez bluez-alsa-utils squeezelite alsa-utils || return 1
  # Pakiet squeezelite włącza własną usługę domyślną – nie jest nam potrzebna,
  # chyba że to stara, ręczna konfiguracja (MiniBox) w /etc/systemd/system.
  if [[ ! -f /etc/systemd/system/squeezelite.service ]]; then
    systemctl disable --now squeezelite.service >/dev/null 2>&1 || true
  fi
  systemctl enable --now bluetooth
  enable_bluealsa
  set_sbc_quality
}

enable_bluealsa() {
  # nowsze wersje bluez-alsa nazywają usługę bluealsad
  systemctl enable --now bluealsa >/dev/null 2>&1 || systemctl enable --now bluealsad >/dev/null 2>&1
}

# Średnia jakość SBC (~230 kb/s zamiast ~330 kb/s) – kilka głośników na jednym
# adapterze gra wtedy bez przerw. Przy radiu internetowym różnicy nie słychać.
set_sbc_quality() {
  local svc bin d f
  if systemctl cat bluealsa >/dev/null 2>&1; then svc=bluealsa; else svc=bluealsad; fi
  bin=$(command -v "$svc") || return 0
  "$bin" --help 2>&1 | grep -q -- '--sbc-quality' || return 0
  d="/etc/systemd/system/$svc.service.d"; f="$d/zz-muzyka-jakosc.conf"
  [[ -f $f ]] && return 0
  mkdir -p "$d"
  printf '[Service]\nExecStart=\nExecStart=%s -S -p a2dp-source -p a2dp-sink --sbc-quality=medium\n' "$bin" >"$f"
  systemctl daemon-reload
  systemctl restart "$svc"
  sleep 2
}

cmd_scan() {
  local secs="${1:-20}"
  {
    echo "power on"
    echo "scan on"
    sleep "$secs"
    echo "scan off"
    sleep 1
    echo "quit"
  } | bluetoothctl >/dev/null 2>&1
  bluetoothctl devices 2>/dev/null | strip_colors | while read -r _ mac name; do
    [[ $mac =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] || continue
    inf=$(bluetoothctl info "$mac" 2>/dev/null)
    grep -q "Paired: yes" <<<"$inf" && continue
    audio=0
    grep -qE "Audio Sink|Icon: audio" <<<"$inf" && audio=1
    [[ -z ${name:-} || $name == "${mac//:/-}" ]] && name="(bez nazwy)"
    echo "$mac|${name//|/ }|$audio"
  done | sort -t'|' -k3,3r
}

cmd_pair() {
  local mac="$1" log=/tmp/muzyka-pair.log
  {
    echo "agent NoInputNoOutput"
    echo "default-agent"
    echo "pair $mac"
    sleep 15
    echo "trust $mac"
    sleep 2
    echo "connect $mac"
    sleep 10
    echo "quit"
  } | bluetoothctl >"$log" 2>&1

  local inf; inf=$(bluetoothctl info "$mac" 2>/dev/null)
  if ! grep -qE "Paired: yes|Connected: yes" <<<"$inf"; then
    echo "Parowanie nie powiodło się. Ostatnie komunikaty bluetoothctl:"
    echo
    strip_colors <"$log" | grep -v '^\s*$' | tail -n 15
    return 1
  fi
  bluetoothctl trust "$mac" >/dev/null 2>&1
  if ! is_connected "$mac"; then
    timeout 20 bluetoothctl connect "$mac" >/dev/null 2>&1
    sleep 3
  fi
  if is_connected "$mac"; then
    echo "Głośnik sparowany i połączony."
  else
    echo "Głośnik sparowany, ale jeszcze niepołączony – usługa ponawiania spróbuje sama co 30 s."
  fi
}

write_common() {
  cat >/etc/systemd/system/squeezelite@.service <<'EOF'
[Unit]
Description=Squeezelite – glosnik %i
After=network-online.target bluetooth.service bluealsa.service bluealsad.service
Wants=network-online.target

[Service]
EnvironmentFile=/etc/muzyka/%i.env
ExecStart=/usr/bin/squeezelite -o ${PCM} -s ${LMS} -n ${PLAYER_NAME} -m ${PLAYER_MAC} -C 5
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat >/usr/local/bin/muzyka-bt-reconnect.sh <<'EOF'
#!/bin/bash
# Co 30 s sprawdza głośniki z /etc/muzyka/*.env i łączy ponownie, jeśli padło połączenie.
while true; do
  for f in /etc/muzyka/*.env; do
    [[ -e $f ]] || continue
    mac=$(sed -n 's/^BT_MAC="\{0,1\}\([0-9A-Fa-f:]*\)"\{0,1\}$/\1/p' "$f")
    [[ -n $mac ]] || continue
    if ! bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"; then
      timeout 20 bluetoothctl connect "$mac" >/dev/null 2>&1
    fi
  done
  sleep 30
done
EOF
  chmod 755 /usr/local/bin/muzyka-bt-reconnect.sh

  cat >/etc/systemd/system/muzyka-bt-reconnect.service <<'EOF'
[Unit]
Description=Muzyka – automatyczne ponowne łączenie głośników Bluetooth
After=bluetooth.service
Wants=bluetooth.service

[Service]
ExecStart=/usr/local/bin/muzyka-bt-reconnect.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

remove_alsa_block() {
  local n="$1"
  [[ -f $ASOUND ]] && sed -i "/^# >>> muzyka:${n}\$/,/^# <<< muzyka:${n}\$/d" "$ASOUND"
}

cmd_configure() {
  local n="$1" mac="$2" player="$3" lms="$4"
  local pcm="bt_${n//-/_}"
  local pmac="02:${mac#*:}"   # unikalny, stały MAC odtwarzacza dla LMS

  touch "$ASOUND"
  remove_alsa_block "$n"
  cat >>"$ASOUND" <<EOF
# >>> muzyka:${n}
pcm.${pcm} {
    type plug
    slave.pcm {
        type bluealsa
        device "${mac}"
        profile "a2dp"
    }
}
# <<< muzyka:${n}
EOF

  cat >"$CONF_DIR/$n.env" <<EOF
BT_MAC="${mac}"
PCM="${pcm}"
PLAYER_NAME="${player}"
PLAYER_MAC="${pmac,,}"
LMS="${lms}"
EOF

  write_common
  set_sbc_quality
  systemctl daemon-reload
  systemctl enable --now muzyka-bt-reconnect.service >/dev/null 2>&1
  systemctl enable "squeezelite@$n" >/dev/null 2>&1
  systemctl restart "squeezelite@$n"
  sleep 2
  systemctl is-active --quiet "squeezelite@$n" && echo "Squeezelite działa." || { echo "Squeezelite nie wystartował:"; journalctl -u "squeezelite@$n" -n 15 --no-pager; return 1; }
}

cmd_test() {
  local n="$1"
  # shellcheck disable=SC1090
  source "$CONF_DIR/$n.env"
  systemctl stop "squeezelite@$n"
  sleep 1
  # Mały bufor (0,2 s) – inaczej niektóre wersje BlueALSA wybierają bufor
  # ~11 s i krótki test kończy się, zanim cokolwiek zagra. Ton gra ok. 4 s.
  timeout 4 speaker-test -D "$PCM" -c 2 -t sine -f 440 -b 200000 -p 50000 -l 0 >/tmp/muzyka-test.log 2>&1
  local rc=$?
  systemctl start "squeezelite@$n"
  [[ $rc -eq 0 || $rc -eq 124 ]] || { tail -n 10 /tmp/muzyka-test.log; return 1; }
}

cmd_lms() {
  # Wykrywa adres LMS: z dodanych już głośników, ze starej konfiguracji
  # squeezelite albo z LMS zainstalowanego w tym samym kontenerze.
  local f v
  for f in "$CONF_DIR"/*.env; do
    [[ -e $f ]] || continue
    v=$(sed -n 's/^LMS="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$f")
    [[ -n $v ]] && { echo "$v"; return; }
  done
  v=$(grep -ho -- '-s [0-9A-Za-z.:-]*' /etc/systemd/system/squeezelite.service 2>/dev/null | head -1 | cut -d' ' -f2)
  [[ -n $v ]] && { echo "$v"; return; }
  systemctl cat lyrionmusicserver >/dev/null 2>&1 && echo "127.0.0.1"
}

# ---------------------------------------------------------------------
#  Strażnik muzyki – co 5 minut sprawdza, czy odtwarzacze, które mają
#  grać, faktycznie grają. Jeśli nie – restartuje LMS i odtwarzacze
#  i wznawia muzykę. Domyślnie wyłączony (włącza się z menu kreatora).
# ---------------------------------------------------------------------
write_straznik() {
  cat >/usr/local/bin/muzyka-straznik.sh <<'STRAZNIK_EOF'
#!/bin/bash
# Strażnik muzyki. Wykrywa trzy sytuacje:
#  A) LMS nie odpowiada,
#  B) odtwarzacz jest w trybie "gra", ale czas utworu stoi (cisza),
#  C) odtwarzacz grał 5 min temu, teraz stoi, a w logu LMS są błędy strumienia.
# Wtedy restartuje LMS + odtwarzacze i wznawia granie. Max 3 restarty na godzinę.
LOG=/var/log/muzyka-straznik.log
STATE=/var/lib/muzyka-straznik
mkdir -p "$STATE"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >>"$LOG"; }

LMS=127.0.0.1
for f in /etc/muzyka/*.env; do
  [[ -e $f ]] || continue
  v=$(sed -n 's/^LMS="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$f"); [[ -n $v ]] && { LMS=$v; break; }
done
URL="http://$LMS:9000/jsonrpc.js"
rpc() { curl -s -m 10 -H 'Content-Type: application/json' \
  -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$1\",$2]}" "$URL"; }
lms_ok() { rpc "" '["version","?"]' | jq -e '.result._version' >/dev/null 2>&1; }
name_of() { rpc "$1" '["name","?"]' | jq -r '.result._value // empty' 2>/dev/null; }

do_restart() {  # $1 = powód, $2.. = odtwarzacze do wznowienia
  local why="$1"; shift
  local now; now=$(date +%s)
  touch "$STATE/restarty"
  awk -v n="$now" '$1 > n-3600' "$STATE/restarty" >"$STATE/r.tmp"; mv "$STATE/r.tmp" "$STATE/restarty"
  if [[ $(wc -l <"$STATE/restarty") -ge 3 ]]; then
    log "POMIJAM restart ($why) – już 3 restarty w ostatniej godzinie. Sprawdź internet / stację."
    return
  fi
  echo "$now" >>"$STATE/restarty"
  log "RESTART: $why"
  systemctl cat lyrionmusicserver >/dev/null 2>&1 && systemctl restart lyrionmusicserver
  systemctl restart bluealsa >/dev/null 2>&1 || systemctl restart bluealsad >/dev/null 2>&1
  sleep 2
  systemctl restart "squeezelite@*" >/dev/null 2>&1
  [[ -f /etc/systemd/system/squeezelite.service ]] && systemctl restart squeezelite
  for _ in $(seq 1 30); do lms_ok && break; sleep 3; done
  sleep 20   # odtwarzacze muszą ponownie połączyć się z LMS
  local p
  local names=""
  for p in "$@"; do rpc "$p" '["play"]' >/dev/null; names+="$(name_of "$p") "; done
  [[ $# -gt 0 ]] && log "Wznowiono granie na: $names"
}

# --- A) LMS żyje? ---
if ! lms_ok; then
  sleep 30
  lms_ok || { do_restart "LMS nie odpowiada"; exit 0; }
fi

# --- odtwarzacze w trybie "gra": pierwszy pomiar czasu ---
declare -A T1
mapfile -t PLAYERS < <(rpc "" '["players","0","99"]' | jq -r '.result.players_loop[]? | select(.connected==1) | .playerid')
for p in "${PLAYERS[@]}"; do
  s=$(rpc "$p" '["status","-","1"]')
  [[ $(jq -r '.result.mode' <<<"$s") == play ]] && T1[$p]=$(jq -r '.result.time // 0' <<<"$s")
done

# --- B) czas stoi mimo trybu "gra" ---
STUCK=(); NOW_PLAYING=()
if [[ ${#T1[@]} -gt 0 ]]; then
  sleep 20
  for p in "${!T1[@]}"; do
    s=$(rpc "$p" '["status","-","1"]')
    [[ $(jq -r '.result.mode' <<<"$s") == play ]] || continue
    t2=$(jq -r '.result.time // 0' <<<"$s")
    if awk -v a="${T1[$p]}" -v b="$t2" 'BEGIN{exit !(b-a < 5)}'; then STUCK+=("$p"); else NOW_PLAYING+=("$p"); fi
  done
fi
if [[ ${#STUCK[@]} -gt 0 ]]; then
  names=""; for p in "${STUCK[@]}"; do names+="$(name_of "$p") "; done
  do_restart "cisza mimo trybu gra: $names" "${STUCK[@]}" "${NOW_PLAYING[@]}"
  printf '%s\n' "${STUCK[@]}" "${NOW_PLAYING[@]}" >"$STATE/grajace"
  exit 0
fi

# --- C) grało poprzednio, teraz stoi, a LMS zgłaszał błędy strumienia ---
LOST=()
if [[ -f $STATE/grajace ]]; then
  while read -r p; do
    [[ -n $p ]] || continue
    printf '%s\n' "${NOW_PLAYING[@]}" | grep -qx "$p" || LOST+=("$p")
  done <"$STATE/grajace"
fi
if [[ ${#LOST[@]} -gt 0 ]]; then
  cutoff=$(date -d '-6 min' '+%y-%m-%d %H:%M:%S')
  errs=$(awk -v c="$cutoff" 'substr($0,2,17) >= c' /var/log/squeezeboxserver/server.log 2>/dev/null \
         | grep -cE "Can't connect to remote server|Select task failed|Can't call method" || true)
  if [[ ${errs:-0} -gt 0 ]]; then
    names=""; for p in "${LOST[@]}"; do names+="$(name_of "$p") "; done
    do_restart "muzyka przerwana przez błąd strumienia ($errs błędów w logu LMS): $names" "${LOST[@]}" "${NOW_PLAYING[@]}"
    printf '%s\n' "${LOST[@]}" "${NOW_PLAYING[@]}" >"$STATE/grajace"
    exit 0
  fi
fi

printf '%s\n' "${NOW_PLAYING[@]}" >"$STATE/grajace"
exit 0
STRAZNIK_EOF
  chmod 755 /usr/local/bin/muzyka-straznik.sh

  cat >/etc/systemd/system/muzyka-straznik.service <<'EOF'
[Unit]
Description=Muzyka – strażnik (automatyczny restart przy ciszy)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/muzyka-straznik.sh
EOF

  cat >/etc/systemd/system/muzyka-straznik.timer <<'EOF'
[Unit]
Description=Muzyka – strażnik co 5 minut

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
}

cmd_straznik() {
  case "${1:-status}" in
    on)
      if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq curl >/dev/null 2>&1 || { echo "Nie udało się zainstalować jq/curl."; return 1; }
      fi
      write_straznik
      rm -f /var/lib/muzyka-straznik/grajace
      systemctl daemon-reload
      systemctl enable --now muzyka-straznik.timer >/dev/null 2>&1
      echo "$(date '+%Y-%m-%d %H:%M:%S')  Strażnik WŁĄCZONY" >>/var/log/muzyka-straznik.log
      echo "Strażnik włączony." ;;
    off)
      systemctl disable --now muzyka-straznik.timer >/dev/null 2>&1
      echo "$(date '+%Y-%m-%d %H:%M:%S')  Strażnik WYŁĄCZONY" >>/var/log/muzyka-straznik.log
      echo "Strażnik wyłączony." ;;
    status)
      if systemctl is-enabled --quiet muzyka-straznik.timer 2>/dev/null; then echo "ON"; else echo "OFF"; fi ;;
    log)
      tail -n 25 /var/log/muzyka-straznik.log 2>/dev/null || echo "(brak wpisów)" ;;
  esac
}

# ---------------------------------------------------------------------
#  Ekran konsoli kontenera – po otwarciu "Konsoli" w Proxmoksie od razu
#  widać adres LMS, IP, stan głośników i opis menu. Enter = logowanie.
# ---------------------------------------------------------------------
write_ekran() {
  cat >/usr/local/bin/multiroom-ekran.sh <<'EKRAN_EOF'
#!/bin/bash
# Wypisuje ekran informacyjny Multiroom (używany na konsoli kontenera).
B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
TS=$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
LINE="${C}  ════════════════════════════════════════════════════════════════════${N}"
echo
echo "$LINE"
echo "${B}    MULTIROOM NA PROXMOKSIE${N}          kontener: $(hostname)"
echo "$LINE"
if systemctl cat lyrionmusicserver >/dev/null 2>&1; then
  echo "    Panel LMS:   ${B}http://${IP:-?}:9000${N}   (otwórz w przeglądarce)"
fi
echo "    Adres IP:    ${IP:-brak}   (wspólny z serwerem Proxmox)"
[[ -n $TS ]] && echo "    Tailscale:   $TS"
echo
if systemctl cat lyrionmusicserver >/dev/null 2>&1; then
  v=$(dpkg-query -W -f='${Version}' lyrionmusicserver 2>/dev/null)
  if systemctl is-active --quiet lyrionmusicserver; then s="${G}✓ działa${N} (wersja $v)"; else s="${R}✗ NIE DZIAŁA${N}"; fi
  echo "    Serwer LMS:  $s"
fi
ctrl=$(bluetoothctl list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '/Controller/{print $2; exit}')
if [[ -n $ctrl ]]; then s="${G}✓ adapter $ctrl${N}"; else s="${R}✗ brak adaptera${N}"; fi
echo "    Bluetooth:   $s"
if systemctl is-enabled --quiet muzyka-straznik.timer 2>/dev/null; then s="${G}✓ włączony${N}"; else s="${Y}wyłączony${N}"; fi
echo "    Strażnik:    $s"
echo
echo "    ${B}Głośniki:${N}"
n=0
for f in /etc/muzyka/*.env; do
  [[ -e $f ]] || continue
  n=$((n+1)); BT_MAC=""; PLAYER_NAME=""
  # shellcheck disable=SC1090
  . "$f"
  i=$(basename "$f" .env)
  if bluetoothctl info "$BT_MAC" 2>/dev/null | grep -q "Connected: yes"; then bt="${G}● połączony${N}"; else bt="${R}○ niepołączony${N}"; fi
  if systemctl is-active --quiet "squeezelite@$i"; then sq="odtwarzacz działa"; else sq="${R}odtwarzacz stoi${N}"; fi
  printf '      %-26s %s, %s\n' "${PLAYER_NAME:0:26}" "$bt" "$sq"
done
if [[ -f /etc/systemd/system/squeezelite.service ]]; then
  n=$((n+1))
  if systemctl is-active --quiet squeezelite; then sq="odtwarzacz działa"; else sq="${R}odtwarzacz stoi${N}"; fi
  printf '      %-26s %s\n' "(stara konfiguracja)" "$sq"
fi
[[ $n -eq 0 ]] && echo "      (brak – dodaj głośnik w menu multiroom)"
echo
echo "    ${B}Menu${N} – na serwerze Proxmox otwórz ${B}Shell${N} i wpisz: ${B}multiroom${N}"
echo "      1 Dodaj głośnik     – sparuj nowy głośnik Bluetooth (nowy pokój)"
echo "      2 Stan głośników    – połączenia i odtwarzacze"
echo "      3 Test dźwięku      – krótki sygnał na wybranym głośniku"
echo "      4 Usuń głośnik      – usuwa odtwarzacz (i ewentualnie parowanie)"
echo "      5 Restart muzyki    – gdy muzyka nagle ucichła"
echo "      6 Strażnik muzyki   – automatyczny restart przy ciszy"
echo "      7 Ustawienia        – adres LMS, ten ekran"
echo
echo "    Stan z: $(date '+%d.%m.%Y %H:%M:%S')"
EKRAN_EOF
  chmod 755 /usr/local/bin/multiroom-ekran.sh

  cat >/usr/local/bin/multiroom-konsola <<'KONSOLA_EOF'
#!/bin/bash
# Pokazuje ekran informacyjny na konsoli; Enter = zwykłe logowanie.
trap '' INT QUIT TSTP
while true; do
  printf '\e[H\e[2J'
  /usr/local/bin/multiroom-ekran.sh 2>/dev/null
  printf '\n    \e[1m[Enter]\e[0m – zaloguj się          (ekran odświeża się co 5 s)\n'
  if read -r -s -n 1 -t 5 _; then
    printf '\e[H\e[2J'
    exec /sbin/agetty -o '-p -- \u' --noclear -t 60 - "${TERM:-linux}"
  fi
done
KONSOLA_EOF
  chmod 755 /usr/local/bin/multiroom-konsola

  # po zalogowaniu też pokaż ekran (raz)
  cat >/etc/profile.d/multiroom.sh <<'EOF'
[ -x /usr/local/bin/multiroom-ekran.sh ] && case "$-" in *i*) /usr/local/bin/multiroom-ekran.sh ;; esac
EOF
}

getty_units() {
  systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | grep -E '^(container-getty@|getty@|console-getty)' || true
}

ekran_dropin_dir() {  # $1 = nazwa jednostki
  local u="$1"
  if [[ $u == *@* ]]; then echo "/etc/systemd/system/${u%%@*}@.service.d"; else echo "/etc/systemd/system/$u.d"; fi
}

ekran_on() {
  write_ekran
  local u d units=()
  for u in $(getty_units); do
    # tylko konsole, które dostają terminal na wejściu (tak jak w Proxmoksie)
    [[ $(systemctl show -p StandardInput --value "$u") == tty* ]] || continue
    d=$(ekran_dropin_dir "$u"); mkdir -p "$d"
    printf '[Service]\nExecStart=\nExecStart=-/usr/local/bin/multiroom-konsola\n' >"$d/multiroom.conf"
    units+=("$u")
  done
  systemctl daemon-reload
  [[ ${#units[@]} -gt 0 ]] && systemctl restart "${units[@]}"
  return 0
}

ekran_off() {
  rm -f /etc/systemd/system/*getty*.d/multiroom.conf /etc/profile.d/multiroom.sh
  systemctl daemon-reload
  local units; mapfile -t units < <(getty_units)
  [[ ${#units[@]} -gt 0 ]] && systemctl restart "${units[@]}"
  return 0
}

cmd_ekran() {
  case "${1:-auto}" in
    auto)   # przy każdym uruchomieniu menu: odśwież pliki; włącz, jeśli nie wyłączono ręcznie
      [[ -f $CONF_DIR/ekran.off ]] && return 0
      if compgen -G "/etc/systemd/system/*getty*.d/multiroom.conf" >/dev/null; then write_ekran; else ekran_on; fi ;;
    on)  rm -f "$CONF_DIR/ekran.off"; ekran_on; echo "Ekran konsoli włączony." ;;
    off) touch "$CONF_DIR/ekran.off"; ekran_off; echo "Ekran konsoli wyłączony." ;;
    status) if [[ -f $CONF_DIR/ekran.off ]]; then echo OFF; else echo ON; fi ;;
  esac
}

cmd_restart() {
  systemctl cat lyrionmusicserver >/dev/null 2>&1 && systemctl restart lyrionmusicserver
  systemctl restart bluealsa >/dev/null 2>&1 || systemctl restart bluealsad >/dev/null 2>&1
  sleep 2
  systemctl restart "squeezelite@*" >/dev/null 2>&1
  [[ -f /etc/systemd/system/squeezelite.service ]] && systemctl restart squeezelite
  echo "OK"
}

cmd_list() {
  local f
  for f in "$CONF_DIR"/*.env; do
    [[ -e $f ]] || continue
    ( source "$f"; echo "$(basename "$f" .env)|$PLAYER_NAME|$BT_MAC" )
  done
}

cmd_status() {
  local f n
  echo "GŁOŚNIKI DODANE KREATOREM"
  echo "-------------------------------------------------------------------------"
  for f in "$CONF_DIR"/*.env; do
    [[ -e $f ]] || continue
    n=$(basename "$f" .env)
    (
      source "$f"
      bt=$(is_connected "$BT_MAC" && echo "połączony" || echo "NIEPOŁĄCZONY")
      sq=$(systemctl is-active "squeezelite@$n" 2>/dev/null)
      echo "* $PLAYER_NAME  (nazwa: $n)"
      echo "    głośnik $BT_MAC – Bluetooth: $bt"
      echo "    squeezelite@$n: $sq, LMS: $LMS, MAC odtwarzacza: $PLAYER_MAC"
    )
  done
  compgen -G "$CONF_DIR/*.env" >/dev/null || echo "(brak)"
  echo
  if [[ -f /etc/systemd/system/squeezelite.service ]]; then
    echo "STARA KONFIGURACJA (ręczna, np. MiniBox)"
    echo "-------------------------------------------------------------------------"
    echo "squeezelite.service: $(systemctl is-active squeezelite.service 2>/dev/null)"
    echo "bt-reconnect.service: $(systemctl is-active bt-reconnect.service 2>/dev/null)"
    echo
  fi
  echo "USŁUGI WSPÓLNE"
  echo "-------------------------------------------------------------------------"
  for s in bluetooth bluealsa bluealsad muzyka-bt-reconnect lyrionmusicserver; do
    systemctl cat "$s" >/dev/null 2>&1 || continue
    echo "$s: $(systemctl is-active $s 2>/dev/null)"
  done
  echo
  echo "Adaptery Bluetooth:"
  bluetoothctl list 2>/dev/null | strip_colors | sed 's/^/    /'
}

cmd_remove() {
  local n="$1" unpair="${2:-0}"
  [[ -f $CONF_DIR/$n.env ]] || { echo "Nie ma głośnika $n"; return 1; }
  # shellcheck disable=SC1090
  source "$CONF_DIR/$n.env"
  systemctl disable --now "squeezelite@$n" >/dev/null 2>&1
  remove_alsa_block "$n"
  rm -f "$CONF_DIR/$n.env"
  [[ $unpair == 1 ]] && bluetoothctl remove "$BT_MAC" >/dev/null 2>&1
  echo "Usunięto głośnik $n."
}

sub="${1:-}"; shift || true
case "$sub" in
  check|install|scan|pair|configure|test|list|lms|status|remove|restart|straznik|ekran) "cmd_$sub" "$@" ;;
  *) echo "Użycie: $0 {check|install|scan|pair|configure|test|list|lms|status|remove|restart|straznik|ekran}"; exit 1 ;;
esac
HELPER_EOF
}

# =====================================================================
#  Przygotowanie kontenera
# =====================================================================
choose_container() {
  local id="" conf f c
  # Kontener z muzyką rozpoznajemy sami – to ten z siecią wspólną z hostem
  # (lxc.net.0.type: none). Pytamy tylko, gdy nie da się tego ustalić.
  local cands=()
  for f in /etc/pve/lxc/*.conf; do
    [[ -e $f ]] || continue
    grep -q '^lxc.net.0.type: none' "$f" && cands+=("$(basename "$f" .conf)")
  done
  if [[ ${#cands[@]} -eq 1 ]]; then
    id="${cands[0]}"
  elif [[ ${#cands[@]} -gt 1 ]]; then
    for c in "${cands[@]}"; do [[ $c == "$DEFAULT_CTID" ]] && id="$c"; done
    if [[ -z $id ]]; then
      local items=()
      for c in "${cands[@]}"; do
        items+=("$c" "$(sed -n 's/^hostname: //p' "/etc/pve/lxc/$c.conf")")
      done
      id=$(whiptail --title "$TITLE" --menu "Który kontener obsługuje muzykę?" 15 60 6 "${items[@]}" 3>&1 1>&2 2>&3) || exit 0
    fi
  else
    id=$(input "Nie znalazłem kontenera z muzyką automatycznie.\nPodaj jego numer:" "$DEFAULT_CTID") || exit 0
  fi
  conf="/etc/pve/lxc/$id.conf"
  if [[ ! -f $conf ]]; then msg "Nie ma kontenera $id."; exit 1; fi
  CTID="$id"

  if ! grep -q '^lxc.net.0.type: none' "$conf"; then
    ask "UWAGA: kontener $CTID nie ma ustawionej sieci hosta (lxc.net.0.type: none).\n\nBez tego Bluetooth w kontenerze nie działa. Kontynuować mimo to?" 13 || exit 0
  fi
  if grep -q '^unprivileged: 1' "$conf"; then
    ask "UWAGA: kontener $CTID jest nieuprzywilejowany (unprivileged).\n\nBluetooth wymaga kontenera uprzywilejowanego. Kontynuować mimo to?" 13 || exit 0
  fi

  if ! pct status "$CTID" | grep -q running; then
    ask "Kontener $CTID jest zatrzymany. Uruchomić go?" 9 || exit 0
    pct start "$CTID" || { msg "Nie udało się uruchomić kontenera."; exit 1; }
    sleep 5
  fi

  local tmp; tmp=$(mktemp)
  write_helper >"$tmp"
  pct push "$CTID" "$tmp" "$HELPER" --perms 755 || { rm -f "$tmp"; msg "Nie udało się wgrać skryptu do kontenera."; exit 1; }
  rm -f "$tmp"

  local missing; missing=$(hx check)
  if [[ -n $missing ]]; then
    ask "W kontenerze brakuje pakietów:\n\n    $missing\n\nZainstalować teraz?" 13 || exit 0
    clear; echo "Instaluję pakiety w kontenerze $CTID..."
    hx install || { msg "Instalacja pakietów nie powiodła się – sprawdź komunikaty powyżej."; exit 1; }
  fi

  local n_hci; n_hci=$(find /sys/class/bluetooth -maxdepth 1 -name 'hci*' 2>/dev/null | grep -c . || true)
  if [[ ${n_hci:-0} -eq 0 ]]; then
    msg "Nie widzę żadnego adaptera Bluetooth na hoście (/sys/class/bluetooth jest puste).\n\nSprawdź, czy adapter USB jest podłączony (lsusb)."
    exit 1
  fi
}

# =====================================================================
#  Akcje z menu
# =====================================================================
add_speaker() {
  msg "Włącz głośnik i przełącz go w TRYB PAROWANIA\n(zwykle przytrzymanie przycisku Bluetooth/zasilania, aż dioda zacznie szybko migać).\n\nPo naciśnięciu OK szukam urządzeń przez ok. 20 sekund." 13 || return

  local found=()
  while true; do
    info "Szukam urządzeń Bluetooth w pobliżu...\n\nTo potrwa ok. 20 sekund."
    mapfile -t found < <(hx scan 20)
    [[ ${#found[@]} -gt 0 ]] && break
    ask "Nie znalazłem żadnych nowych urządzeń.\n\nUpewnij się, że głośnik jest w trybie parowania i blisko serwera.\n\nSzukać ponownie?" 13 || return
  done

  local items=() i mac name audio label
  for i in "${!found[@]}"; do
    IFS='|' read -r mac name audio <<<"${found[$i]}"
    label="$name  [$mac]"
    [[ $audio == 1 ]] && label="♪ $label"
    items+=("$((i+1))" "$label")
  done
  local sel
  sel=$(whiptail --title "$TITLE" --menu "Wybierz głośnik (♪ = urządzenie audio):" 20 78 10 "${items[@]}" 3>&1 1>&2 2>&3) || return
  IFS='|' read -r mac name audio <<<"${found[$((sel-1))]}"

  local player
  [[ $name == "(bez nazwy)" ]] && name="Glosnik"
  while true; do
    player=$(input "Nazwa odtwarzacza widoczna w LMS (np. Salon, Kuchnia):" "$name") || return
    player=$(printf '%s' "$player" | tr -d '"$`\\|')
    [[ -n ${player// } ]] && break
  done

  local slug existing
  slug=$(slugify "$player")
  existing=$(hx list | cut -d'|' -f1)
  while grep -qx "$slug" <<<"$existing"; do
    slug=$(input "Nazwa techniczna \"$slug\" jest już zajęta. Podaj inną (małe litery, cyfry, myślnik):" "${slug}-2") || return
    slug=$(slugify "$slug")
  done

  info "Paruję z głośnikiem $name ($mac)...\n\nTo potrwa ok. 30 sekund. Głośnik musi być nadal w trybie parowania."
  local out
  if ! out=$(hx pair "$mac" 2>&1); then
    local t; t=$(mktemp); printf '%s\n' "$out" >"$t"; showfile "$t"; rm -f "$t"
    return
  fi

  info "Konfiguruję ALSA i Squeezelite dla \"$player\"..."
  local cfg
  if ! cfg=$(hx configure "$slug" "$mac" "$player" "$LMS_IP" 2>&1); then
    local t; t=$(mktemp); printf '%s\n' "$out" "$cfg" >"$t"; showfile "$t"; rm -f "$t"
    return
  fi

  if ask "$out\n$cfg\n\nZagrać krótki dźwięk testowy (ton 440 Hz) na głośniku?" 13; then
    info "Gram dźwięk testowy (ok. 4 sekundy)..."
    local terr
    if ! terr=$(hx test "$slug" 2>&1); then
      local t; t=$(mktemp); printf 'Test dźwięku się nie powiódł:\n\n%s\n' "$terr" >"$t"; showfile "$t"; rm -f "$t"
    fi
    ask "Czy słyszałeś dźwięk testowy?" 8 || msg "Sprawdź głośność na głośniku i stan połączenia (menu: Stan głośników).\nKonfiguracja jest zapisana – możesz spróbować ponownie z menu Test dźwięku." 11
  fi

  msg "Gotowe!\n\nOdtwarzacz \"$player\" powinien pojawić się w LMS:\n    $LMS_WEB\n\nAby grał razem z innymi pokojami: w LMS wybierz odtwarzacz → Ustawienia → Synchronizuj." 15
}

pick_speaker() {
  local list=() items=() i n p m
  mapfile -t list < <(hx list)
  if [[ ${#list[@]} -eq 0 ]]; then msg "Nie ma jeszcze głośników dodanych kreatorem."; return 1; fi
  for i in "${!list[@]}"; do
    IFS='|' read -r n p m <<<"${list[$i]}"
    items+=("$n" "$p  [$m]")
  done
  whiptail --title "$TITLE" --menu "$1" 18 74 8 "${items[@]}" 3>&1 1>&2 2>&3
}

show_status() {
  local t; t=$(mktemp)
  hx status >"$t" 2>&1
  showfile "$t"; rm -f "$t"
}

test_speaker() {
  local n; n=$(pick_speaker "Na którym głośniku zagrać dźwięk testowy?") || return
  info "Gram dźwięk testowy na \"$n\"..."
  if hx test "$n" >/dev/null 2>&1; then
    msg "Dźwięk testowy wysłany. Jeśli nic nie słychać – sprawdź głośność i czy głośnik jest połączony (Stan głośników)." 10
  else
    msg "Nie udało się odtworzyć dźwięku. Głośnik jest pewnie niepołączony – sprawdź Stan głośników." 10
  fi
}

remove_speaker() {
  local n; n=$(pick_speaker "Który głośnik usunąć?") || return
  ask "Usunąć głośnik \"$n\" (odtwarzacz, konfigurację ALSA)?" 9 || return
  local unpair=0
  ask "Czy także ROZPAROWAĆ głośnik z Bluetooth?\n\n(Tak – trzeba będzie parować od nowa; Nie – zostaje sparowany)" 11 && unpair=1
  local out; out=$(hx remove "$n" "$unpair" 2>&1)
  msg "$out\n\nW LMS stary odtwarzacz zniknie po chwili (albo usuń go ręcznie w Ustawienia → Odtwarzacze)." 11
}

restart_all() {
  ask "Uruchomić ponownie LMS i wszystkie odtwarzacze?\n\nPomaga, gdy muzyka nagle ucichła, a głośniki są połączone.\nMuzyka na chwilę się zatrzyma – potem włącz ją ponownie w LMS." 12 || return
  info "Uruchamiam ponownie LMS i odtwarzacze...\n\nTo potrwa ok. 30 sekund."
  hx restart >/dev/null 2>&1
  sleep 25
  msg "Gotowe. Włącz muzykę ponownie w LMS:\n    $LMS_WEB" 9
}

straznik_menu() {
  while true; do
    local st c t
    st=$(hx straznik status 2>/dev/null)
    [[ $st == ON ]] && st="WŁĄCZONY" || st="WYŁĄCZONY"
    c=$(whiptail --title "$TITLE" --menu "Strażnik muzyki:  $st\n\nCo 5 minut sprawdza, czy głośniki, które mają grać, grają.\nGdy wykryje ciszę (np. zawieszone radio), sam restartuje LMS\ni wznawia muzykę. Najwyżej 3 restarty na godzinę." 18 74 4 \
      "1" "Włącz strażnika" \
      "2" "Wyłącz strażnika" \
      "3" "Pokaż, co strażnik robił (dziennik)" \
      "0" "Powrót" 3>&1 1>&2 2>&3) || return
    case "$c" in
      1) info "Włączam strażnika..."; msg "$(hx straznik on 2>&1)\n\nPierwsze sprawdzenie za 5 minut." 9 ;;
      2) msg "$(hx straznik off 2>&1)" 8 ;;
      3) t=$(mktemp); hx straznik log >"$t" 2>&1; showfile "$t"; rm -f "$t" ;;
      0) return ;;
    esac
  done
}

settings() {
  while true; do
    local c ek
    ek=$(hx ekran status 2>/dev/null); [[ $ek == ON ]] && ek="włączony" || ek="wyłączony"
    c=$(whiptail --title "$TITLE" --menu "Ustawienia" 14 74 3 \
      "1" "Adres serwera LMS (teraz: $LMS_IP)" \
      "2" "Ekran informacyjny na konsoli kontenera ($ek)" \
      "0" "Powrót" 3>&1 1>&2 2>&3) || return
    case "$c" in
      1) local ip; ip=$(input "Adres serwera LMS (używany dla NOWO dodawanych głośników):" "$LMS_IP") || continue
         [[ -n $ip ]] && LMS_IP="$ip" ;;
      2) if [[ $ek == włączony ]]; then
           ask "Wyłączyć ekran informacyjny?\n\nKonsola kontenera wróci do zwykłego ekranu logowania." 10 && msg "$(hx ekran off 2>&1)" 8
         else
           msg "$(hx ekran on 2>&1)\n\nOtwórz Konsolę kontenera w Proxmoksie – ekran pojawi się sam." 10
         fi ;;
      0) return ;;
    esac
  done
}

# =====================================================================
#  Start
# =====================================================================
detect_lms() {
  [[ -n $LMS_IP ]] || LMS_IP=$(hx lms 2>/dev/null)
  while [[ -z $LMS_IP ]]; do
    LMS_IP=$(input "Nie wykryłem serwera LMS automatycznie.\nPodaj adres IP serwera LMS (np. 192.168.1.50):" "") || exit 0
  done
  if [[ -z $LMS_WEB ]]; then
    if [[ $LMS_IP == 127.0.0.1 || $LMS_IP == localhost ]]; then
      local hip; hip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
      LMS_WEB="http://${hip:-IP-serwera}:9000"
    else
      LMS_WEB="http://$LMS_IP:9000"
    fi
  fi
}

choose_container
detect_lms
hx ekran auto >/dev/null 2>&1 || true   # ekran informacyjny na konsoli kontenera
[[ ${1:-} == --przygotuj ]] && exit 0     # używane przez instalator

while true; do
  choice=$(whiptail --title "$TITLE" --menu "Kontener: $CTID    LMS: $LMS_WEB\n\nCo chcesz zrobić?" 21 70 9 \
    "1" "Dodaj nowy głośnik (nowy pokój)" \
    "2" "Stan głośników" \
    "3" "Test dźwięku" \
    "4" "Usuń głośnik" \
    "5" "Uruchom ponownie muzykę (gdy ucichło)" \
    "6" "Strażnik muzyki (automatyczny restart)" \
    "7" "Ustawienia (adres LMS, ekran konsoli)" \
    "0" "Wyjście" 3>&1 1>&2 2>&3) || break
  case "$choice" in
    1) add_speaker ;;
    2) show_status ;;
    3) test_speaker ;;
    4) remove_speaker ;;
    5) restart_all ;;
    6) straznik_menu ;;
    7) settings ;;
    0) break ;;
  esac
done
clear
