# Multiroom na Proxmox

System muzyczny multiroom dla domowego serwera **Proxmox VE**. Łączy **Lyrion Music Server (LMS)** z głośnikami **Bluetooth**: radio internetowe, własna biblioteka i kilka pokoi grających razem. Nie trzeba do tego Raspberry Pi ani osobnych odtwarzaczy.

## Co dostajesz

- **Lyrion Music Server** (dawniej Logitech Media Server): radio internetowe, biblioteka plików, wtyczki, sterowanie z przeglądarki i telefonu.
- **Głośniki Bluetooth jako odtwarzacze**. Każdy głośnik jest osobnym odtwarzaczem w LMS.
- **Multiroom**. Głośniki można synchronizować, żeby grały to samo w kilku pokojach.
- **Automatyczne ponowne łączenie** po wyłączeniu głośnika, restarcie albo zaniku prądu.
- **Kreator `muzyka`** z prostym menu do dodawania, testowania i usuwania głośników.

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
muzyka
```

Z menu wybierz **„Dodaj nowy głośnik”**, przełącz głośnik w tryb parowania i wybierz go z listy. Po około minucie głośnik pojawi się w LMS.

Granie w kilku pokojach naraz: w LMS wybierz odtwarzacz, otwórz **Ustawienia**, a potem **Synchronizuj**.

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
3. **Sparuj głośniki od nowa.** Parowanie jest przypisane do konkretnego adaptera. W kreatorze `muzyka`, dla każdego głośnika: **Usuń głośnik** (z rozparowaniem), a potem **Dodaj nowy głośnik**. Nadaj głośnikom te same nazwy co wcześniej, a LMS zachowa ich ustawienia.

## Wskazówki

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

## Licencja

MIT: możesz używać, zmieniać i udostępniać dalej.
