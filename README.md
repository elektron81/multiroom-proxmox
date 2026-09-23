# Muzyka na Proxmoksie

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
bash -c "$(curl -fsSL https://raw.githubusercontent.com/elektron81/muzyka-proxmox/main/muzyka-instalator.sh)"
```

Wybierz **„Domyślna (zalecana)”** i poczekaj kilka minut. Na końcu instalator pokaże adres panelu LMS i zaproponuje dodanie pierwszego głośnika.

## Dodawanie kolejnych głośników

W konsoli Proxmoksa wpisz:

```bash
muzyka
```

Z menu wybierz **„Dodaj nowy głośnik”**, przełącz głośnik w tryb parowania i wybierz go z listy. Po około minucie głośnik pojawi się w LMS.

Granie w kilku pokojach naraz: w LMS wybierz odtwarzacz, otwórz **Ustawienia**, a potem **Synchronizuj**.

## Wskazówki

- **Echo między głośnikami.** Każdy głośnik Bluetooth ma inne opóźnienie. Wyrównasz je w LMS: **Ustawienia → Odtwarzacz → Audio → Synchronization Delay**. Ustaw je w tym głośniku, który gra wcześniej, np. 100 ms, i dostrój na słuch.
- **Przerywanie dźwięku.** Postaw adapter USB z dala od obudowy serwera (przedłużacz USB, port USB 2.0). Porty USB 3.0 zakłócają Bluetooth.
- **Zasięg.** Wszystkie głośniki muszą być w zasięgu adaptera w serwerze, czyli zwykle około 10 m, mniej przez ściany.
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
