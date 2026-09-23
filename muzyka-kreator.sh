#!/usr/bin/env bash
# =====================================================================
#  muzyka-kreator.sh – kreator głośników Bluetooth dla LMS (Proxmox)
#
#  Uruchamiać na HOŚCIE Proxmoksa jako root:
#      muzyka      (po instalacji instalatorem)  albo:  bash muzyka-kreator.sh
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
TITLE="Muzyka na Proxmoksie – kreator"
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
  check|install|scan|pair|configure|test|list|lms|status|remove) "cmd_$sub" "$@" ;;
  *) echo "Użycie: $0 {check|install|scan|pair|configure|test|list|lms|status|remove}"; exit 1 ;;
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

settings() {
  local ip; ip=$(input "Adres serwera LMS (używany dla NOWO dodawanych głośników):" "$LMS_IP") || return
  [[ -n $ip ]] && LMS_IP="$ip"
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

while true; do
  choice=$(whiptail --title "$TITLE" --menu "Kontener: $CTID    LMS: $LMS_WEB\n\nCo chcesz zrobić?" 19 70 7 \
    "1" "Dodaj nowy głośnik (nowy pokój)" \
    "2" "Stan głośników" \
    "3" "Test dźwięku" \
    "4" "Usuń głośnik" \
    "5" "Ustawienia (adres LMS)" \
    "0" "Wyjście" 3>&1 1>&2 2>&3) || break
  case "$choice" in
    1) add_speaker ;;
    2) show_status ;;
    3) test_speaker ;;
    4) remove_speaker ;;
    5) settings ;;
    0) break ;;
  esac
done
clear
