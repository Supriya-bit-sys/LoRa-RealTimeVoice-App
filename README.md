# LoRa Media App

Flutter app and Heltec ESP32 LoRa firmware for sending real-time voice/audio over BLE and LoRa.

The phone app scans for Heltec BLE devices, connects to either transceiver board, records microphone audio, sends it over BLE, and receives/playbacks audio coming back from the LoRa link.

## Project Structure

- `lib/main.dart` - Flutter application.
- `lib/heltec1.ino` - Arduino sketch for the board advertised as `Heltec_1`.
- `lib/heltec2.ino` - Arduino sketch for the board advertised as `Heltec_2`.
- `data/tx_input.wav` - sample audio file kept with the project.

## Requirements

Install these before running the project:

- Flutter SDK with Dart support.
- Android Studio or VS Code with Flutter/Dart extensions.
- Android phone with Bluetooth, Location, and Microphone permissions enabled.
- Arduino IDE or Arduino CLI.
- Two Heltec ESP32 LoRa V3/SX1262 boards, or compatible ESP32 LoRa boards using the same pins.
- USB cables for flashing both boards.

Arduino libraries used by the sketches:

- ESP32 board package.
- RadioLib.
- Codec2.
- RingBuf.
- ESP32 BLE libraries, included with the ESP32 board package.

## Clone And Initialize

```bash
git clone <your-repository-url>
cd realtimevoice
flutter pub get
```

Check that Flutter can see your device:

```bash
flutter doctor
flutter devices
```

## Flash The Heltec Boards

1. Open Arduino IDE.
2. Install the ESP32 board package from Boards Manager.
3. Install `RadioLib`, `Codec2`, and `RingBuf` from Library Manager.
4. Select your Heltec ESP32 LoRa board and the correct COM port.
5. Open `lib/heltec1.ino` and upload it to the first transceiver board.
6. Open `lib/heltec2.ino` and upload it to the second transceiver board.
7. Open Serial Monitor at `115200` baud and confirm each board prints that LoRa/BLE is ready.

Important names used by the Flutter app:

- First transceiver BLE name: `Heltec_1`
- Second transceiver BLE name: `Heltec_2`

Keep these names unchanged unless you also update `kTransceiverNameKeywords` in `lib/main.dart`.

## Run The Flutter App

Connect an Android phone with USB debugging enabled, then run:

```bash
flutter run
```

For a release APK:

```bash
flutter build apk --release
```

The APK will be generated under:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## How To Use

1. Turn on both flashed Heltec boards.
2. Turn on Bluetooth and Location on the Android phone.
3. Open the app.
4. Allow Bluetooth, Location, Microphone, and Notification permissions when Android asks.
5. Tap scan and wait for `Heltec_1` or `Heltec_2` to appear.
6. Connect to the required board.
7. Use push-to-talk/audio controls in the app to send and receive audio.

## Notes

- The LoRa frequency is configured in both sketches as `865.1 MHz`. Change `LORA_FREQ_MHZ` in both `.ino` files if your region or hardware requires another legal frequency.
- The sketches use these LoRa settings: bandwidth `250 kHz`, spreading factor `7`, coding rate `5`, sync word `0x12`, and power `20 dBm`.
- Android BLE scanning usually requires Location to be enabled, even when the app is only looking for nearby Bluetooth devices.
- If no board appears in the app, verify the Arduino Serial Monitor output first, then restart Bluetooth on the phone and scan again.

## Common Commands

```bash
flutter clean
flutter pub get
flutter run
flutter build apk --release
```

## Troubleshooting

- `flutter pub get` fails: check your internet connection and Flutter installation.
- No Android device found: enable Developer Options and USB debugging, then run `flutter devices`.
- BLE device not found: make sure the board is powered, the sketch uploaded correctly, and the BLE name still contains `Heltec`.
- Microphone does not work: grant Microphone permission from Android app settings.
- Audio is unstable: keep the boards close while testing, confirm both sketches use the same LoRa frequency/settings, and watch Serial Monitor logs at `115200`.
