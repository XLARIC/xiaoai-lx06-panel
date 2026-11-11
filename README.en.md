# XiaoAI LX06 Panel

[简体中文](README.md) · English

**Get local time and date answers in your time zone, and weather forecasts for your location.** Open the XiaoAI Speaker Pro's lightweight control panel from a phone or computer on the same Wi-Fi. The panel also manages Bluetooth and synchronized playback.

## Fix local time, date, and weather

- **Spoken time and date.** Select the IANA time zone where you use the speaker, such as `Pacific/Auckland` for Auckland. XiaoAI uses that zone for local time and date questions such as “What time is it?” and “What's today's date?”
- **Local weather forecasts.** Enter your latitude and longitude to set the default forecast location. XiaoAI then uses that location when you ask about the weather without specifying a city.

## Compatibility

- Targets the XiaoAI Speaker Pro (LX06) on firmware 1.94.13. The installer checks system file checksums and stops on a mismatch.
- Root SSH access is required. For flashing and enabling SSH, see the [original Open-XiaoAI flashing guide](https://github.com/idootop/open-xiaoai/blob/main/docs/flash.md) and the [upstream LX06 1.94.13 release](https://github.com/idootop/open-xiaoai/releases/tag/LX06_1.94.13).
- QQ Music playback on both the XiaoAI and an LG PL7 was verified on one previously configured LX06. The panel used about 3.7 MB of resident memory at idle. A fresh install from this release and behavior after reboot still need hardware testing.

## One-command installation

Connect the computer and speaker to the same Wi-Fi. Use OpenSSH on macOS, Linux, or Windows with WSL. Download `xiaoai-lx06-panel-v0.1.1.tar.gz` from [GitHub Releases](https://github.com/XLARIC/xiaoai-lx06-panel/releases), verify it against the accompanying SHA-256 checksum, then run the following commands. Replace the example IP with the speaker's LAN address.

```sh
tar -xzf xiaoai-lx06-panel-v0.1.1.tar.gz
cd xiaoai-lx06-panel-v0.1.1
./install.sh 192.168.1.50
```

On the first SSH connection, verify the host fingerprint and authenticate with your existing speaker credentials. The installer prints the panel URL on port `8086`, the username, and a separate password generated for this installation. Save the login details. The installer puts the program and configuration in the speaker's writable data partition and configures startup at boot. Use the HTTP panel on a trusted LAN.

## Using the panel

- **Set the location.** On a fresh install, enter your coordinates and time zone under Location, confirm that Xiaomi's weather and time services may use those values, then save the settings to the speaker.
- **Receive audio from a phone.** The panel starts in receive mode on a fresh install. Leave it in receive mode and connect to the XiaoAI from the phone's Bluetooth settings.
- **Send and sync audio.** Put an external speaker into pairing mode, then select output mode in the panel and find, select, and pair one speaker. Changing modes may briefly interrupt playback. Both speakers will play the audio. The delay is applied to the XiaoAI itself. It can be set from 0 to 750 milliseconds and starts at 320 ms. Adjust by ear until the two speakers line up.
- **Starting music before powering on the external speaker.** Once the Bluetooth link is established, XiaoAI briefly pauses playback, opens the Bluetooth audio output, and resumes the same song. It attempts this automatically once per connection and resumes local playback if initialization fails. If the Bluetooth link has not been established, pause the music to allow XiaoAI to reconnect.

To check a fresh speaker without installing, run `./install.sh --check 192.168.1.50` with the speaker’s address.

## LG PL7 pairing and reconnection

To enter pairing mode on the LG PL7, hold its Bluetooth button for about two seconds, release it after the tone, and check that the LED beside the Bluetooth symbol is blinking. Then search for and select the speaker in the panel. See the [official LG PL7 manual](https://www.lg.com/content/dam/channel/wcms/pl/support/products/documents/PL7.DEUSLLK_WEB_POL_MFL71448060.pdf) for the button instructions.

If pairing succeeds but the external speaker cannot initiate a return connection, you can review and explicitly enable that permission through the XiaoAI's SSH connection. Run `bluetoothctl`, use `paired-devices` to identify the external speaker, and replace the example address in the following commands. The `trust` setting persistently allows that device to initiate connections, so review the address and permission before applying it.

```text
info AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
quit
```

To revoke the permission, run `untrust AA:BB:CC:DD:EE:FF` inside `bluetoothctl`.

If the Bluetooth output is ready but music remains paused, ask XiaoAI to continue playing. The following SSH command restored the current song on the tested device. Confirm that the playback position advances afterward.

```sh
ubus call mediaplayer player_play_operation '{"action":"play","media":"app_ios"}'
```

## Uninstall

From the extracted release directory, run the following command with the speaker's IP address.

```sh
./install.sh --uninstall 192.168.1.50
```

## Build from source

Install Go 1.26.x and Zig 0.15.2, then run the following command from the project directory.

```sh
./scripts/build.sh
```

The installation archive and SHA-256 checksum are written to `dist/`.

## License

Project code is available under the [MIT license](LICENSE). Third-party components retain their respective licenses.
