# Multiroom on Proxmox

🇬🇧 **English** | 🇵🇱 [Polski](README.pl.md)

A multiroom music system for a home **Proxmox VE** server. It combines **Lyrion Music Server (LMS)** with **Bluetooth speakers**: internet radio, your own music library, and several rooms playing in sync. You don't need a Raspberry Pi or a separate player for each speaker.

> **Note:** the installer and the `multiroom` menu are currently in **Polish**. The steps below tell you what to choose at each point, so you can follow along without knowing Polish.

## Features

- **Lyrion Music Server** (formerly Logitech Media Server): internet radio, music library, plugins, control from a browser or phone.
- **Bluetooth speakers as players**. Each speaker shows up in LMS as a separate player.
- **Multiroom**. Speakers can be synchronized to play the same thing in several rooms.
- **Automatic reconnect** after a speaker is switched off, a restart, or a power cut.
- **Wi-Fi speakers with Chromecast** (optional, via the Cast Bridge plugin), alongside the Bluetooth speakers.
- **`multiroom` command** with a simple menu to add, test, and remove speakers.
- **Info screen on the container console**: open the container's "Console" in Proxmox and you see the LMS address, IP address, speaker status, and a description of the menu. Press Enter to get the normal login prompt. You can turn the screen off in the menu under **Ustawienia** (Settings).

## Requirements

- Proxmox VE 8 or newer
- A USB Bluetooth adapter plugged into the server (tested: TP-Link UB500)
- Internet access during installation

## Installation

In the Proxmox web UI, click your node, then **Shell**. Paste:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/elektron81/multiroom-proxmox/main/muzyka-instalator.sh)"
```

Choose **„Domyślna (zalecana)”** (Default, recommended) and wait a few minutes. At the end, the installer shows the LMS web address and offers to add your first speaker.

**Installation time depends on the disk:**

| Disk where the container is created | Installation time |
|---|---|
| SSD / NVMe | about 3–5 minutes |
| HDD (spinning disk) | **up to 10–15 minutes** |

A progress bar shows how far the installation is. On an HDD the bar may sit still for a while during package installation. This is normal, so don't interrupt it. In **„Zaawansowana”** (Advanced) mode you can choose which disk the container goes on. If you have an SSD, pick it.

## Adding more speakers

In the Proxmox shell, type:

```bash
multiroom
```

Choose **„Dodaj nowy głośnik”** (Add new speaker), put the speaker into pairing mode, and select it from the list. After about a minute it appears in LMS.

At the end, the wizard offers a **test sound**: two short, quiet beeps (1000 Hz, under a second). If you hear them, the speaker is set up correctly. You can repeat the test any time: `multiroom` → **„Test dźwięku”** (Sound test). If you hear nothing, check the volume on the speaker and its status under **„Stan głośników”** (Speaker status).

To play in several rooms at once: in LMS, select a player, open **Settings**, then **Synchronize**.

## Wi-Fi speakers (Chromecast)

Besides Bluetooth speakers, you can add speakers and soundbars with **Chromecast** (e.g. JBL Bar, JBL Authentics, Google Nest). This is done with the **Cast Bridge** plugin. The speaker then appears in LMS as a regular player. Tested with the **JBL Bar 500MK2**.

**1. Check that the speaker is on the network** (Proxmox shell, `CTID` = container number):
```bash
pct exec CTID -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends avahi-daemon avahi-utils >/dev/null 2>&1; systemctl start avahi-daemon; sleep 5; timeout 20 avahi-browse -artp 2>/dev/null | awk -F";" "\$1==\"=\" && \$3==\"IPv4\" && \$5 ~ /googlecast|airplay/ {print \$5\"  |  \"\$4\"  |  \"\$8}" | sort -u; systemctl disable --now avahi-daemon >/dev/null 2>&1'
```
A speaker listed with `_googlecast` supports Chromecast.

**2. Activate Chromecast on the speaker.** Many speakers (e.g. JBL models using the JBL One app) need a one-time setup in the **Google Home** app. Until then the speaker is visible on the network but refuses to play. Check that you can cast music to it from your phone.

**3. Install the plugin:** in LMS go to **Settings → Plugins → Cast Bridge → Apply**, then restart LMS.

**4. Configure the plugin** (replace `CTID` with the container number and `192.168.1.17` with your Proxmox server's IP). This command picks the program version that works inside the container, ties the bridge to this server, and turns on conversion to FLAC:
```bash
pct exec CTID -- bash -c 'IP=192.168.1.17; B=/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/CastBridge/Bin; P=/var/lib/squeezeboxserver/prefs/plugin/castbridge.prefs; X=/var/lib/squeezeboxserver/prefs/castbridge.xml; systemctl stop lyrionmusicserver; sleep 2; chmod +x $B/squeeze2cast-linux-x86_64-static; sed -i "/^bin:/d; /^opts:/d" $P; echo "bin: squeeze2cast-linux-x86_64-static" >> $P; echo "opts: -b $IP -s $IP" >> $P; [ -f $X ] && sed -i "s|<mode>thru</mode>|<mode>flc</mode>|g" $X; systemctl start lyrionmusicserver'
```
If `castbridge.xml` didn't exist yet, run the command again after about a minute, once the bridge has created the file.

After a minute the speaker appears in the LMS player list.

**Why these settings:**
- **"static" program version:** the regular version doesn't start in the container because some libraries are missing.
- **`-s` (server address):** if another LMS or **Music Assistant / Home Assistant** runs on your network, the bridge may attach the speakers to that server instead of this one.
- **`flc`:** some speakers don't accept radio streams in AAC format. The bridge converts every stream to FLAC.

**Syncing with Bluetooth speakers is a compromise.** Chromecast has its own buffer and delay (1–2 s), and the bridge doesn't report the exact playback position. In a group with Bluetooth speakers, players may go silent for a moment or behave unpredictably. This setup works best:
- the Chromecast speaker **used on its own** (e.g. a soundbar in the living room),
- **only Bluetooth speakers synchronized** with each other.

If you still want to group them, in the Chromecast player's settings (**Settings → Player → Synchronization**) turn off **"Maintain synchronization while playing"** and **"Synchronize volume"**. On the Bluetooth speaker, set **Synchronization Delay** to about 1000 ms.

**Volume:** the LMS volume slider controls the Chromecast speaker's own volume.

## Updating the menu

Get the latest version of the `multiroom` command from GitHub with one command in the Proxmox shell:

```bash
curl -fsSL https://raw.githubusercontent.com/elektron81/multiroom-proxmox/main/muzyka-kreator.sh -o /usr/local/bin/multiroom && chmod +x /usr/local/bin/multiroom && echo OK
```

Your speakers and settings stay unchanged.

## Bluetooth adapter

Any USB adapter **supported by Linux** works. Most work out of the box, with no drivers to install.

| Chip in the adapter | Example models | Notes |
|---|---|---|
| **Realtek RTL8761B / RTL8761BU** | TP-Link UB500, UGREEN BT 5.0, ASUS USB-BT500, EDUP EP-B3536 | best choice; versions with an antenna exist |
| **Intel** (AX200, AX210, etc.) | Bluetooth built into the motherboard or a Wi-Fi card | works well |
| **CSR8510** | older, cheap BT 4.0 adapters | work, but clones can be unreliable |

**Avoid** cheap "Bluetooth 5.3/5.4" adapters with **Actions ATS2851** or **Barrot** chips (e.g. EDUP EP-B3552). They often work only on Windows. When buying, look for **"Linux"** or **"RTL8761B"** in the description. The Bluetooth version barely matters for music. An external antenna matters more for range.

### How to check that the adapter works

Plug the adapter into the server and paste in the Proxmox shell:

```bash
lsusb | tail -n 5; echo ----; ls /sys/class/bluetooth; echo ----; dmesg | grep -i bluetooth | tail -n 5
```

- **`hci0`** (or `hci1`) appears in the middle section: the adapter works.
- The middle section is empty, or there's an error mentioning `firmware`: Linux doesn't support this adapter or a driver is missing. The easiest fix is to use a model from the table above.

### Replacing the adapter

1. Remove the old adapter, plug in the new one, and check it with the command above.
2. Restart the container: `pct reboot CTID` (replace `CTID` with the container number).
3. **Pair the speakers again.** Pairing is tied to a specific adapter. In the `multiroom` menu, for each speaker: **„Usuń głośnik”** (Remove speaker, including unpairing), then **„Dodaj nowy głośnik”** (Add new speaker). Give the speakers the same names as before, and LMS keeps their settings.

## Tips

- **Music watchdog (automatic restart).** In the `multiroom` menu, choose **„Strażnik muzyki”** (Music watchdog) and turn it on. Every 5 minutes it checks that speakers which should be playing actually are. If the radio stalls (playing, but silent) or stops because of a stream error, the watchdog restarts LMS and resumes playback. It does at most 3 restarts per hour and leaves music you stopped yourself alone. It is **off** by default. In the same menu you can turn it off and view its log.
- **Music suddenly stopped, but the speaker is connected.** Type `multiroom` and choose **„Uruchom ponownie muzykę”** (Restart music). This restarts LMS and the players. If only one station won't play, its address may have changed. Search for it again via **Radio → TuneIn** or **Radio Browser**.
- **Radio keeps "buffering" or won't start.** If **Tailscale** runs on the Proxmox server, the container may use its DNS (`100.100.100.100`) and sometimes fail to find radio servers. The installer sets the router's DNS automatically in that case. On an older install, do it by hand (replace `CTID` with the container number and `192.168.1.1` with your router's address):
  ```bash
  pct set CTID --nameserver "192.168.1.1 1.1.1.1" && pct reboot CTID
  ```
- **Echo between speakers.** Each Bluetooth speaker has a different delay. Even it out in LMS: **Settings → Player → Audio → Synchronization Delay**. Set it on the speaker that plays earlier, e.g. 100 ms, and fine-tune by ear.
- **Audio dropouts.** Keep the USB adapter away from the server case (use a USB extension cable and a USB 2.0 port). USB 3.0 ports interfere with Bluetooth. One adapter comfortably handles 2–3 speakers playing at once.
- **Range.** All speakers must be within range of the adapter in the server, usually about 10 m, less through walls.
- **LMS settings page won't open ("restricted to the local network").** LMS only shows its settings to devices on the local network. If you connect through **Tailscale** or a VPN, turn it off for a moment or open the page from a device on your home Wi-Fi. You can also turn this restriction off permanently (replace `CTID` with the container number):
  ```bash
  pct exec CTID -- bash -c 'systemctl stop lyrionmusicserver; f=/var/lib/squeezeboxserver/prefs/server.prefs; grep -q "^protectSettings:" $f && sed -i "s/^protectSettings:.*/protectSettings: 0/" $f || echo "protectSettings: 0" >> $f; systemctl start lyrionmusicserver'
  ```
- **Backup.** Add the container to a backup job: **Datacenter → Backup**.

## How it works

Everything runs in a single privileged LXC container that shares the host's network (`lxc.net.0.type: none`). On Linux, Bluetooth only works in the main network namespace. For each speaker, the setup creates:

- an ALSA device `bt_<name>` (via BlueALSA),
- a `squeezelite@<name>` service with a unique player MAC address,
- an entry in `/etc/muzyka/<name>.env`.

The `muzyka-bt-reconnect` service checks the connections every 30 s and reconnects when needed. BlueALSA uses medium SBC quality (about 230 kb/s) so several speakers on one adapter play without dropouts.

## Files

| File | Description |
|---|---|
| `muzyka-instalator.sh` | Full installation from scratch (container, LMS, Bluetooth, menu). |
| `muzyka-kreator.sh` | The speaker menu on its own. Useful if you already have LMS and a container. |
| `README.pl.md` | This description in Polish. |

## License

MIT: you may use, modify, and share it.
