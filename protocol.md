# Realtimevoice Protocol

This document describes the current wire protocol used by the Flutter app and
the Heltec ESP32 LoRa firmware.

## Transport Overview

Realtimevoice moves audio across two links:

1. Phone to Heltec over BLE.
2. Heltec to Heltec over LoRa.
3. Heltec back to phone over BLE notifications.

The phone records 8 kHz mono PCM audio, sends it to a connected Heltec board,
and receives decoded PCM audio from the remote board.

## BLE Device Names

The Flutter app scans for BLE devices with `Heltec` in the name.

| Board | BLE name |
| --- | --- |
| First board | `Heltec_1` |
| Second board | `Heltec_2` |

## BLE UUIDs

| Purpose | UUID |
| --- | --- |
| BLE service | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` |
| Phone to Heltec audio write | `beb5483e-36e1-4688-b7f5-ea07361b26a8` |
| Heltec to phone audio notify | `beb5483e-36e1-4688-b7f5-ea07361b26a9` |

## BLE Packet Format

Every BLE audio/control packet starts with an 8-byte header.

| Offset | Size | Field | Description |
| --- | ---: | --- | --- |
| 0 | 1 | marker | Fixed value `0xA5`. |
| 1 | 1 | packet type | `0x01` start, `0x02` audio, `0x03` stop. |
| 2 | 2 | sequence | Little-endian packet sequence number. |
| 4 | 1 | payload length | Number of valid payload bytes after the header. |
| 5 | 1 | sample rate kHz | Current value is `8`. |
| 6 | 1 | channels | Current value is `1`. |
| 7 | 1 | flags | Bit `0x01` marks a final audio chunk. |

Audio payload bytes begin at offset `8`.

## Packet Types

| Type | Value | Payload | Meaning |
| --- | ---: | --- | --- |
| Start | `0x01` | Empty | Starts a push-to-talk audio session. |
| Audio | `0x02` | PCM bytes | Carries raw 16-bit mono PCM audio. |
| Stop | `0x03` | Empty | Ends the current push-to-talk session. |

## Phone to Heltec Audio

The Flutter app sends audio to the write characteristic using:

| Setting | Value |
| --- | ---: |
| Sample rate | `8000 Hz` |
| Channels | `1` |
| Encoding | 16-bit PCM |
| Header size | `8 bytes` |
| Normal PCM payload size | `200 bytes` |
| Preferred BLE MTU | `247` |

The final audio packet may contain fewer than `200` valid bytes. In that case,
the payload is padded to the normal packet size and the valid byte count is
stored in the payload length field.

## Heltec to Phone Audio

The Heltec firmware sends decoded PCM back to the phone through BLE
notifications.

| Setting | Value |
| --- | ---: |
| Header size | `8 bytes` |
| Notify PCM payload size | `236 bytes` |
| Notify interval | `10 ms` |
| Stream idle timeout | `250 ms` |

The Flutter app uses the payload length field to ignore padding bytes.

## LoRa Audio Link

Between the two Heltec boards, PCM is encoded with Codec2 before being sent over
LoRa.

| Setting | Value |
| --- | ---: |
| Codec2 mode | `CODEC2_MODE_1300` |
| PCM samples per Codec2 frame | `320` |
| Compressed bytes per Codec2 frame | `7` |
| Target LoRa packet size | `63 bytes` |
| Max LoRa packet size | `80 bytes` |
| LoRa queue depth | `16` |
| Inter-packet delay | `5 ms` |

## LoRa Radio Settings

| Setting | Value |
| --- | ---: |
| Frequency | `865.1 MHz` |
| Bandwidth | `250 kHz` |
| Spreading factor | `7` |
| Coding rate | `5` |
| Sync word | `0x12` |
| Power | `20 dBm` |
| Preamble | `8` |

## Session Flow

1. Phone connects to `Heltec_1` or `Heltec_2`.
2. Phone writes a start packet.
3. Phone streams audio packets with 8-byte headers and PCM payloads.
4. Heltec encodes the PCM with Codec2 and transmits compressed frames over LoRa.
5. The remote Heltec receives LoRa packets and decodes Codec2 frames back to PCM.
6. Remote Heltec sends start/audio/stop packets to the phone notify
   characteristic.
7. Phone plays the PCM stream and saves received audio clips as WAV files.

