# Multiroom na Proxmox

🇬🇧 [English](README.md) | 🇵🇱 **Polski**

System muzyczny multiroom dla domowego serwera **Proxmox VE**. Łączy **Lyrion Music Server (LMS)** z głośnikami **Bluetooth**: radio internetowe, własna biblioteka i kilka pokoi grających razem. Nie trzeba do tego Raspberry Pi ani osobnych odtwarzaczy.

## Co dostajesz

- **Lyrion Music Server** (dawniej Logitech Media Server): radio internetowe, biblioteka plików, wtyczki, sterowanie z przeglądarki i telefonu.
- **Głośniki Bluetooth jako odtwarzacze**. Każdy głośnik jest osobnym odtwarzaczem w LMS.
- **Multiroom**. Głośniki można synchronizować, żeby grały to samo w kilku pokojach.
- **Automatyczne ponowne łączenie** po wyłączeniu głośnika, restarcie albo zaniku prądu.
- **Głośniki Wi-Fi z Chromecastem** (opcjonalnie, przez wtyczkę Cast Bridge), razem z głośnikami Bluetooth.
- **Polecenie `multiroom`** z prostym menu do dodawania, testowania i usuwania głośników.
- **Ekran informacyjny na konsoli kontenera**: po kliknięciu „Konsola” w Proxmoksie od razu widać adres panelu LMS, adres IP, stan głośników i opis menu. Enter otwiera zwykłe logowanie. Ekran wyłączysz w menu **Ustawienia**.

## Wymagania

- Proxmox VE 8 lub nowszy
- Adapter Bluetooth USB podłączony do serwera (sprawdzony: TP-Link UB500)
- Dostęp do internetu podczas instalacji

## Instalacja

W panelu Proxmoksa kliknij serwer, a potem **Shell**. Wklej:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/elektron81/multiroom-proxmox/main/muzyka-instalator.sh)"
```

Wybierz **„Domyślna (zalecana)”** i poczekaj kilka minut. Na końcu instalator pokaże adres panelu LMS i zaproponuje dodanie pierwszego głośnika.

**Czas instalacji zależy od dysku:**

| Dysk, na którym powstaje kontener | Czas instalacji |
|---|---|
| SSD / NVMe | ok. 3–5 minut |
| HDD (dysk talerzowy) | **nawet 10–15 minut** |

Postęp widać na pasku w konsoli. Na dysku HDD pasek może na dłużej zatrzymać się przy instalacji pakietów. To normalne, nie przerywaj instalacji. W trybie **„Zaawansowana”** możesz wybrać, na którym dysku ma powstać kontener. Jeśli masz SSD, wybierz SSD.

## Dodawanie kolejnych głośników

W konsoli Proxmoksa wpisz:

```bash
multiroom
```

Z menu wybierz **„Dodaj nowy głośnik”**, przełącz głośnik w tryb parowania i wybierz go z listy. Po około minucie głośnik pojawi się w LMS.

Na koniec kreator zaproponuje **dźwięk testowy**: dwa krótkie, ciche piknięcia „pip-pip” (1000 Hz, niecała sekunda). Jeśli je słyszysz, głośnik jest dobrze skonfigurowany. Ten sam test możesz powtórzyć w dowolnej chwili: `multiroom` → **„Test dźwięku”**. Jeśli nic nie słychać, sprawdź głośność na głośniku i jego stan w menu **„Stan głośników”**.

Granie w kilku pokojach naraz: w LMS wybierz odtwarzacz, otwórz **Ustawienia**, a potem **Synchronizuj**.

## Głośniki Wi-Fi (Chromecast)

Oprócz głośników Bluetooth do LMS można dodać głośniki i soundbary z **Chromecastem** (np. JBL Bar, JBL Authentics, Google Nest). Robi to wtyczka **Cast Bridge**. Głośnik pojawia się wtedy w LMS jako zwykły odtwarzacz i można go synchronizować z pozostałymi. Sprawdzone na **JBL Bar 500MK2**.

**1. Sprawdź, czy głośnik jest w sieci** (Shell Proxmoksa, `NUMER` = numer kontenera):
```bash
pct exec NUMER -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends avahi-daemon avahi-utils >/dev/null 2>&1; systemctl start avahi-daemon; sleep 5; timeout 20 avahi-browse -artp 2>/dev/null | awk -F";" "\$1==\"=\" && \$3==\"IPv4\" && \$5 ~ /googlecast|airplay/ {print \$5\"  |  \"\$4\"  |  \"\$8}" | sort -u; systemctl disable --now avahi-daemon >/dev/null 2>&1'
```
Głośnik z wpisem `_googlecast` obsługuje Chromecast.

**2. Aktywuj Chromecast w głośniku.** Wiele głośników (np. JBL z aplikacją JBL One) wymaga jednorazowej konfiguracji w aplikacji **Google Home**. Bez tego głośnik jest widoczny w sieci, ale nie chce grać. Sprawdź, czy da się na niego przesłać muzykę z telefonu.

**3. Zainstaluj wtyczkę:** w LMS **Ustawienia → Wtyczki → Cast Bridge → Zastosuj** i restart LMS.

**4. Ustaw wtyczkę** (zamień `NUMER` na numer kontenera, a `192.168.1.17` na adres serwera Proxmox). Polecenie wybiera wersję programu, która działa w kontenerze, przypisuje most do naszego serwera i włącza zamianę dźwięku na FLAC:
```bash
pct exec NUMER -- bash -c 'IP=192.168.1.17; B=/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/CastBridge/Bin; P=/var/lib/squeezeboxserver/prefs/plugin/castbridge.prefs; X=/var/lib/squeezeboxserver/prefs/castbridge.xml; systemctl stop lyrionmusicserver; sleep 2; chmod +x $B/squeeze2cast-linux-x86_64-static; sed -i "/^bin:/d; /^opts:/d" $P; echo "bin: squeeze2cast-linux-x86_64-static" >> $P; echo "opts: -b $IP -s $IP" >> $P; [ -f $X ] && sed -i "s|<mode>thru</mode>|<mode>flc</mode>|g" $X; systemctl start lyrionmusicserver'
```
Jeśli plik `castbridge.xml` jeszcze nie istniał, uruchom polecenie drugi raz po około minucie, gdy most utworzy już ten plik.

Po minucie głośnik pojawi się na liście odtwarzaczy w LMS.

**Dlaczego te ustawienia:**
- **Wersja „static” programu:** zwykła wersja nie uruchamia się w kontenerze, bo brakuje jej bibliotek.
- **`-s` (adres serwera):** jeśli w sieci działa drugi LMS albo **Music Assistant / Home Assistant**, most może podłączyć głośniki do niego zamiast do naszego serwera.
- **`flc`:** część głośników nie przyjmuje radia w formacie AAC. Most zamienia wtedy każdy strumień na FLAC.

**Synchronizacja z głośnikami Bluetooth to kompromis.** Chromecast ma własny bufor i opóźnienie (1–2 s), a most nie raportuje dokładnie pozycji w utworze. W grupie z Bluetoothem głośniki mogą wtedy chwilami cichnąć albo zachowywać się nieprzewidywalnie. Najlepiej działa tak:
- głośnik Chromecast **używany osobno** (np. soundbar w salonie),
- **synchronizowane tylko głośniki Bluetooth**.

Jeśli mimo to chcesz je łączyć, w ustawieniach odtwarzacza Chromecast (**Ustawienia → Odtwarzacz → Synchronizacja**) wyłącz **„Utrzymuj synchronizację podczas odtwarzania”** i **„Synchronizuj głośność”**. Przy głośniku Bluetooth ustaw **Synchronization Delay** na ok. 1000 ms.

**Głośność:** suwak w LMS steruje głośnością samego głośnika Chromecast.

## Aktualizacja kreatora

Nową wersję polecenia `multiroom` pobierzesz z GitHuba jednym poleceniem w konsoli Proxmoksa:

```bash
curl -fsSL https://raw.githubusercontent.com/elektron81/multiroom-proxmox/main/muzyka-kreator.sh -o /usr/local/bin/multiroom && chmod +x /usr/local/bin/multiroom && echo OK
```

Twoje głośniki i ustawienia zostają bez zmian.

## Adapter Bluetooth

Możesz użyć dowolnego adaptera USB, który **obsługuje Linux**. Większość działa od razu, bez instalowania sterowników.

| Chip w adapterze | Przykładowe modele | Uwagi |
|---|---|---|
| **Realtek RTL8761B / RTL8761BU** | TP-Link UB500, UGREEN BT 5.0, ASUS USB-BT500 | najlepszy wybór, są też wersje z anteną |
| **Intel** (AX200, AX210 itp.) | Bluetooth wbudowany w płytę główną lub kartę Wi-Fi | działa bez problemu |
| **CSR8510** | starsze, tanie adaptery BT 4.0 | działają, ale podróbki bywają kapryśne |

**Lepiej unikać** tanich adapterów „Bluetooth 5.3/5.4” na chipach **Actions ATS2851** i **Barrot**. Często działają tylko na Windowsie. Przy zakupie szukaj w opisie słów **„Linux”** albo **„RTL8761B”**. Wersja Bluetootha nie ma dużego znaczenia dla muzyki. Na zasięg bardziej wpływa zewnętrzna antena.

### Jak sprawdzić, czy adapter działa

Podłącz adapter do serwera i wklej w konsoli Proxmoksa:

```bash
lsusb | tail -n 5; echo ----; ls /sys/class/bluetooth; echo ----; dmesg | grep -i bluetooth | tail -n 5
```

- W środkowej części widać **`hci0`** (albo `hci1`): adapter działa.
- Jest pusto albo pojawia się błąd ze słowem `firmware`: Linux nie obsługuje tego adaptera albo brakuje mu sterownika. Najprościej wymienić go na model z tabeli powyżej.

### Wymiana adaptera na inny

1. Wyjmij stary adapter, włóż nowy i sprawdź go poleceniem powyżej.
2. Zrestartuj kontener: `pct reboot NUMER` (zamień `NUMER` na numer kontenera).
3. **Sparuj głośniki od nowa.** Parowanie jest przypisane do konkretnego adaptera. W menu `multiroom`, dla każdego głośnika: **Usuń głośnik** (z rozparowaniem), a potem **Dodaj nowy głośnik**. Nadaj głośnikom te same nazwy co wcześniej, a LMS zachowa ich ustawienia.

## Wskazówki

- **Strażnik muzyki (automatyczny restart).** W menu `multiroom` wybierz **„Strażnik muzyki”** i włącz go. Co 5 minut sprawdza, czy głośniki, które mają grać, faktycznie grają. Jeśli radio się zawiesi (tryb „gra”, a cisza) albo przerwie przez błąd strumienia, strażnik sam zrestartuje LMS i wznowi muzykę. Robi najwyżej 3 restarty na godzinę. Muzyki zatrzymanej ręcznie nie rusza. Domyślnie jest **wyłączony**. W tym samym menu możesz go wyłączyć i zobaczyć jego dziennik.
- **Muzyka nagle ucichła, a głośnik jest połączony.** Wpisz `multiroom` i wybierz **„Uruchom ponownie muzykę”**. Menu zrestartuje LMS i odtwarzacze. Jeśli nie gra tylko jedna stacja, jej adres mógł się zmienić. Wyszukaj ją ponownie przez **Radio → TuneIn** albo **Radio Browser**.
- **Radio długo „buforuje” albo nie startuje.** Jeśli na serwerze Proxmox działa **Tailscale**, kontener może korzystać z jego DNS (`100.100.100.100`) i przez to czasem nie znajdować serwerów radia. Instalator ustawia wtedy sam DNS routera. W starszej instalacji zrób to ręcznie (zamień `NUMER` na numer kontenera, a `192.168.1.1` na adres swojego routera):
  ```bash
  pct set NUMER --nameserver "192.168.1.1 1.1.1.1" && pct reboot NUMER
  ```
- **Echo między głośnikami.** Każdy głośnik Bluetooth ma inne opóźnienie. Wyrównasz je w LMS: **Ustawienia → Odtwarzacz → Audio → Synchronization Delay**. Ustaw je w tym głośniku, który gra wcześniej, np. 100 ms, i dostrój na słuch.
- **Przerywanie dźwięku.** Postaw adapter USB z dala od obudowy serwera (przedłużacz USB, port USB 2.0). Porty USB 3.0 zakłócają Bluetooth.
- **Zasięg.** Wszystkie głośniki muszą być w zasięgu adaptera w serwerze, czyli zwykle około 10 m, mniej przez ściany.
- **Strona ustawień LMS się nie otwiera („restricted to the local network”).** LMS pokazuje ustawienia tylko komputerom z sieci lokalnej. Jeśli łączysz się przez **Tailscale** albo VPN, wyłącz go na chwilę albo otwórz panel z urządzenia w domowym Wi-Fi. Możesz też na stałe wyłączyć tę blokadę (zamień `NUMER` na numer kontenera):
  ```bash
  pct exec NUMER -- bash -c 'systemctl stop lyrionmusicserver; f=/var/lib/squeezeboxserver/prefs/server.prefs; grep -q "^protectSettings:" $f && sed -i "s/^protectSettings:.*/protectSettings: 0/" $f || echo "protectSettings: 0" >> $f; systemctl start lyrionmusicserver'
  ```
- **Kopia zapasowa.** Dodaj kontener do zadania backupu: **Centrum danych → Kopia zapasowa**.

## Jak to działa

Wszystko działa w jednym uprzywilejowanym kontenerze LXC, który korzysta z sieci hosta (`lxc.net.0.type: none`). Bluetooth w Linuksie działa tylko w głównej przestrzeni sieciowej. Dla każdego głośnika tworzone są:

- urządzenie ALSA `bt_<nazwa>` (przez BlueALSA),
- usługa `squeezelite@<nazwa>` z unikalnym adresem MAC odtwarzacza,
- wpis w `/etc/muzyka/<nazwa>.env`.

Usługa `muzyka-bt-reconnect` co 30 s sprawdza połączenia i w razie potrzeby łączy ponownie. BlueALSA działa ze średnią jakością SBC (około 230 kb/s), żeby kilka głośników na jednym adapterze grało bez przerw.

## Pliki

| Plik | Opis |
|---|---|
| `muzyka-instalator.sh` | Pełna instalacja od zera (kontener, LMS, Bluetooth, kreator). |
| `muzyka-kreator.sh` | Sam kreator głośników. Przydaje się, gdy LMS i kontener już masz. |
| `README.md` | Ten opis po angielsku. |

## Licencja

MIT: możesz używać, zmieniać i udostępniać dalej.
