#include <Arduino.h>
#include <SPI.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <RadioLib.h>
#include <codec2.h>
#include <string.h>
#include <RingBuf.h>
#include <esp_system.h>
#include <freertos/semphr.h>

// Arduino's auto-generated function prototypes can appear before enum/struct
// definitions. Forward declarations keep those prototypes valid.
enum PacketType : uint8_t;
struct LoRaPacket;

// Keep Arduino loopTask stack safe when setup/libraries are heavy.
SET_LOOP_TASK_STACK_SIZE(16 * 1024);

// =====================================================
// Device identity (sender build)
// =====================================================
#define DEVICE_BLE_NAME            "Heltec_Sender"

// =====================================================
// BLE UUIDs and stream protocol
// =====================================================
#define BLE_SERVICE_UUID           "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID_AUDIO  "beb5483e-36e1-4688-b7f5-ea07361b26a8" // phone -> heltec
#define CHARACTERISTIC_UUID_RX     "beb5483e-36e1-4688-b7f5-ea07361b26a9" // heltec -> phone
#define BLE_PACKET_HEADER_LEN      8
#define BLE_EXPECTED_SAMPLE_RATE_KHZ 8
#define BLE_PCM_NOTIFY_BYTES       236
#define BLE_NOTIFY_INTERVAL_MS     10
#define BLE_STREAM_IDLE_TIMEOUT_MS 250
#define BLE_NOTIFY_POST_PACKET_DELAY_MS 0

#define CODEC2_PCM_SAMPLES_PER_FRAME 320
#define CODEC2_COMPRESSED_BYTES_PER_FRAME 7
#define PCM_INPUT_DECIMATION       1

#define RAW_AUDIO_BUFFER_BYTES       32768
#define COMPRESSED_AUDIO_BUFFER_BYTES 4096
#define DECODED_PCM_BUFFER_BYTES     8192
#define PCM_BUFFER_RESUME_BYTES      4096

#define LORA_PACKET_TARGET_BYTES   63
#define LORA_PACKET_MAX_BYTES      80
#define LORA_QUEUE_DEPTH           16
#define LORA_INTER_PACKET_DELAY_MS 5
#define LORA_QUEUE_PACING_DELAY_MS 0

#define LORA_TASK_RX_BIT  0x01
#define DECODE_TASK_BIT   0x01
#define BLE_TASK_BIT      0x01
#define CORE_RADIO_BLE    0
#define CORE_CODEC        1

#define VERBOSE_STREAM_LOGS 0

enum PacketType : uint8_t {
  PACKET_TYPE_START = 0x01,
  PACKET_TYPE_AUDIO = 0x02,
  PACKET_TYPE_STOP  = 0x03,
};

// =====================================================
// LoRa config
// =====================================================
#define LORA_FREQ_MHZ  865.1
#define LORA_BW_KHZ    125.0
#define LORA_SF        7
#define LORA_CR        5
#define LORA_SYNCWORD  0x12
#define LORA_POWER_DBM 20
#define LORA_PREAMBLE  8

// Heltec V3 SX1262 pins: NSS, DIO1, NRST, BUSY
SX1262 radio(new Module(8, 14, 12, 13));

struct LoRaPacket {
  uint16_t len;
  uint8_t data[LORA_PACKET_MAX_BYTES];
};

BLECharacteristic* pAudioNotifyChar = nullptr;
volatile bool deviceConnected = false;
volatile bool loraEnableIsr = true;
volatile bool pttSessionActive = false;
volatile bool pttStopRequested = false;
volatile bool bleDownlinkStreamActive = false;

TaskHandle_t loraTaskHandle = nullptr;
TaskHandle_t decodeTaskHandle = nullptr;
TaskHandle_t bleTaskHandle = nullptr;
TaskHandle_t encoderTaskHandle = nullptr;
TaskHandle_t loraTxTaskHandle = nullptr;

QueueHandle_t decoderQueue = nullptr;
QueueHandle_t loraTxQueue = nullptr;

RingBuf<uint8_t, RAW_AUDIO_BUFFER_BYTES> rawAudioBuffer;
RingBuf<uint8_t, COMPRESSED_AUDIO_BUFFER_BYTES> compressedAudioBuffer;
RingBuf<uint8_t, DECODED_PCM_BUFFER_BYTES> decodedPcmBuffer;

SemaphoreHandle_t rawAudioMutex = nullptr;
SemaphoreHandle_t compressedAudioMutex = nullptr;
SemaphoreHandle_t decodedPcmMutex = nullptr;
SemaphoreHandle_t streamStateMutex = nullptr;

struct CODEC2* codec2Enc = nullptr;
struct CODEC2* codec2Dec = nullptr;
int samplesPerFrame = 0;
int bytesPerCompressedFrame = 0;
uint16_t bleSequence = 0;
unsigned long lastDecodedAudioMs = 0;
int16_t* decodeOutSamples = nullptr;

void clearRawAudioBuffer() {
  xSemaphoreTake(rawAudioMutex, portMAX_DELAY);
  rawAudioBuffer.clear();
  xSemaphoreGive(rawAudioMutex);
}

void clearCompressedAudioBuffer() {
  xSemaphoreTake(compressedAudioMutex, portMAX_DELAY);
  compressedAudioBuffer.clear();
  xSemaphoreGive(compressedAudioMutex);
}

void clearDecodedPcmBuffer() {
  xSemaphoreTake(decodedPcmMutex, portMAX_DELAY);
  decodedPcmBuffer.clear();
  xSemaphoreGive(decodedPcmMutex);
}

size_t rawAudioSize() {
  size_t size = 0;
  xSemaphoreTake(rawAudioMutex, portMAX_DELAY);
  size = rawAudioBuffer.size();
  xSemaphoreGive(rawAudioMutex);
  return size;
}

size_t compressedAudioSize() {
  size_t size = 0;
  xSemaphoreTake(compressedAudioMutex, portMAX_DELAY);
  size = compressedAudioBuffer.size();
  xSemaphoreGive(compressedAudioMutex);
  return size;
}

void trimDecodedPcmToLatest(size_t targetSize) {
  while (decodedPcmBuffer.size() > targetSize) {
    uint8_t discardByte = 0;
    decodedPcmBuffer.pop(discardByte);
  }
}

void markBleStreamActive(unsigned long decodedAtMs) {
  xSemaphoreTake(streamStateMutex, portMAX_DELAY);
  bleDownlinkStreamActive = true;
  lastDecodedAudioMs = decodedAtMs;
  xSemaphoreGive(streamStateMutex);
}

void stopBleStreamAndResetSequence() {
  xSemaphoreTake(streamStateMutex, portMAX_DELAY);
  bleDownlinkStreamActive = false;
  bleSequence = 0;
  xSemaphoreGive(streamStateMutex);
}

void getBleStreamState(bool* connected, bool* streamActive, uint16_t* sequence, unsigned long* decodedAtMs) {
  xSemaphoreTake(streamStateMutex, portMAX_DELAY);
  if (connected != nullptr) {
    *connected = deviceConnected;
  }
  if (streamActive != nullptr) {
    *streamActive = bleDownlinkStreamActive;
  }
  if (sequence != nullptr) {
    *sequence = bleSequence;
  }
  if (decodedAtMs != nullptr) {
    *decodedAtMs = lastDecodedAudioMs;
  }
  xSemaphoreGive(streamStateMutex);
}

bool buildBlePacketHeader(PacketType type, uint8_t payloadLen, bool finalChunk, uint8_t* packet) {
  xSemaphoreTake(streamStateMutex, portMAX_DELAY);
  if (!deviceConnected || pAudioNotifyChar == nullptr) {
    xSemaphoreGive(streamStateMutex);
    return false;
  }

  packet[0] = 0xA5;
  packet[1] = (uint8_t)type;
  packet[2] = bleSequence & 0xFF;
  packet[3] = (bleSequence >> 8) & 0xFF;
  packet[4] = payloadLen;
  packet[5] = BLE_EXPECTED_SAMPLE_RATE_KHZ;
  packet[6] = 1;
  packet[7] = finalChunk ? 0x01 : 0x00;
  bleSequence++;
  xSemaphoreGive(streamStateMutex);
  return true;
}

void notifyBlePacket(PacketType type, const uint8_t* payload, uint8_t payloadLen, bool finalChunk) {
  if (pAudioNotifyChar == nullptr) {
    return;
  }

  uint8_t packet[BLE_PACKET_HEADER_LEN + BLE_PCM_NOTIFY_BYTES];
  if (!buildBlePacketHeader(type, payloadLen, finalChunk, packet)) {
    return;
  }

  if (payloadLen > 0 && payload != nullptr) {
    memcpy(packet + BLE_PACKET_HEADER_LEN, payload, payloadLen);
  }
  if (payloadLen < BLE_PCM_NOTIFY_BYTES) {
    memset(packet + BLE_PACKET_HEADER_LEN + payloadLen, 0, BLE_PCM_NOTIFY_BYTES - payloadLen);
  }

  pAudioNotifyChar->setValue(packet, BLE_PACKET_HEADER_LEN + BLE_PCM_NOTIFY_BYTES);
  pAudioNotifyChar->notify();
}

bool ensureBleStartPacketSent(bool streamActive, uint16_t sequence) {
  if (streamActive && sequence == 0) {
    notifyBlePacket(PACKET_TYPE_START, nullptr, 0, false);
    return true;
  }
  return false;
}

void codec2InitDuplex() {
  codec2Enc = codec2_create(CODEC2_MODE_1300);
  codec2Dec = codec2_create(CODEC2_MODE_1300);
  if (!codec2Enc || !codec2Dec) {
    Serial.println("codec2 duplex init failed");
    while (1) delay(1000);
  }

  samplesPerFrame = codec2_samples_per_frame(codec2Enc);
  bytesPerCompressedFrame = (codec2_bits_per_frame(codec2Enc) + 7) / 8;
  if (samplesPerFrame != CODEC2_PCM_SAMPLES_PER_FRAME ||
      bytesPerCompressedFrame != CODEC2_COMPRESSED_BYTES_PER_FRAME) {
    Serial.printf("Unexpected Codec2 frame geometry: samples=%d bytes=%d\n", samplesPerFrame, bytesPerCompressedFrame);
    while (1) delay(1000);
  }

  decodeOutSamples = (int16_t*)malloc(sizeof(int16_t) * samplesPerFrame);
  if (decodeOutSamples == nullptr) {
    Serial.println("Failed to allocate decodeOutSamples");
    while (1) delay(1000);
  }

  Serial.printf("Duplex samples/frame=%d bytes/frame=%d\n", samplesPerFrame, bytesPerCompressedFrame);
}

bool codec2EncodeSh123(int16_t* speechIn, uint8_t* compressedOut) {
  if (!codec2Enc) return false;
  codec2_encode(codec2Enc, compressedOut, speechIn);
  return true;
}

bool codec2DecodeSh123(uint8_t* compressedIn, int16_t* speechOut) {
  if (!codec2Dec) return false;
  codec2_decode(codec2Dec, speechOut, compressedIn);
  return true;
}

bool pushRawAudioBytes(const uint8_t* data, size_t len) {
  bool trimmedOldestSamples = false;

  xSemaphoreTake(rawAudioMutex, portMAX_DELAY);
  for (size_t i = 0; i < len; i++) {
    if (!rawAudioBuffer.push(data[i])) {
      uint8_t discardByte = 0;
      rawAudioBuffer.pop(discardByte);
      if (!rawAudioBuffer.push(data[i])) {
        xSemaphoreGive(rawAudioMutex);
        return trimmedOldestSamples;
      }
      trimmedOldestSamples = true;
    }
  }
  xSemaphoreGive(rawAudioMutex);

  return trimmedOldestSamples;
}

bool popRawAudioFrame(int16_t* speechSamples) {
  xSemaphoreTake(rawAudioMutex, portMAX_DELAY);
  const size_t inputBytesPerCodecFrame =
      (size_t)(samplesPerFrame * sizeof(int16_t) * PCM_INPUT_DECIMATION);
  if (rawAudioBuffer.size() < inputBytesPerCodecFrame) {
    xSemaphoreGive(rawAudioMutex);
    return false;
  }

  for (int i = 0; i < samplesPerFrame; i++) {
    int16_t keptSample = 0;
    for (int d = 0; d < PCM_INPUT_DECIMATION; d++) {
      uint8_t low = 0;
      uint8_t high = 0;
      rawAudioBuffer.pop(low);
      rawAudioBuffer.pop(high);
      const int16_t sample = (int16_t)((high << 8) | low);
      if (d == 0) {
        keptSample = sample;
      }
    }
    speechSamples[i] = keptSample;
  }

  xSemaphoreGive(rawAudioMutex);
  return true;
}

bool pushCompressedFrame(const uint8_t* compressedBits) {
  xSemaphoreTake(compressedAudioMutex, portMAX_DELAY);
  if ((COMPRESSED_AUDIO_BUFFER_BYTES - compressedAudioBuffer.size()) < (size_t)bytesPerCompressedFrame) {
    xSemaphoreGive(compressedAudioMutex);
    return false;
  }

  for (int i = 0; i < bytesPerCompressedFrame; i++) {
    if (!compressedAudioBuffer.push(compressedBits[i])) {
      xSemaphoreGive(compressedAudioMutex);
      return false;
    }
  }

  xSemaphoreGive(compressedAudioMutex);
  return true;
}

bool popCompressedPacket(LoRaPacket* pkt, size_t maxLen) {
  xSemaphoreTake(compressedAudioMutex, portMAX_DELAY);
  const size_t available = compressedAudioBuffer.size();
  if (available < maxLen) {
    xSemaphoreGive(compressedAudioMutex);
    return false;
  }

  pkt->len = maxLen;
  for (size_t i = 0; i < maxLen; i++) {
    compressedAudioBuffer.pop(pkt->data[i]);
  }

  xSemaphoreGive(compressedAudioMutex);
  return true;
}

bool popCompressedTailPacket(LoRaPacket* pkt, size_t maxLen) {
  xSemaphoreTake(compressedAudioMutex, portMAX_DELAY);
  const size_t available = compressedAudioBuffer.size();
  if (available == 0) {
    xSemaphoreGive(compressedAudioMutex);
    return false;
  }

  pkt->len = available > maxLen ? maxLen : available;
  for (uint16_t i = 0; i < pkt->len; i++) {
    compressedAudioBuffer.pop(pkt->data[i]);
  }

  xSemaphoreGive(compressedAudioMutex);
  return true;
}

void queueCompressedForLora(size_t loraPacketTarget) {
  LoRaPacket pkt;
  while (popCompressedPacket(&pkt, loraPacketTarget)) {
    if (xQueueSend(loraTxQueue, &pkt, portMAX_DELAY) != pdPASS) {
      break;
    }
    vTaskDelay(pdMS_TO_TICKS(LORA_QUEUE_PACING_DELAY_MS));
  }
}

void pushDecodedFrameToPcmBufferAndNotify() {
  if (!deviceConnected) {
    stopBleStreamAndResetSequence();
    clearDecodedPcmBuffer();
    return;
  }

  const uint8_t* pcmBytes = reinterpret_cast<const uint8_t*>(decodeOutSamples);
  const uint16_t pcmByteCount = samplesPerFrame * sizeof(int16_t);

  xSemaphoreTake(decodedPcmMutex, portMAX_DELAY);
  if (decodedPcmBuffer.size() > (DECODED_PCM_BUFFER_BYTES - pcmByteCount)) {
    trimDecodedPcmToLatest(PCM_BUFFER_RESUME_BYTES);
  }
  for (uint16_t j = 0; j < pcmByteCount; j++) {
    if (!decodedPcmBuffer.push(pcmBytes[j])) {
      uint8_t discardByte = 0;
      decodedPcmBuffer.pop(discardByte);
      decodedPcmBuffer.push(pcmBytes[j]);
    }
  }
  xSemaphoreGive(decodedPcmMutex);

  markBleStreamActive(millis());
  if (bleTaskHandle != nullptr) {
    xTaskNotify(bleTaskHandle, BLE_TASK_BIT, eSetBits);
  }
}

class AudioWriteCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar) override {
    std::string value = pChar->getValue();
    if (value.empty()) return;

    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(value.data());
    const size_t packetLen = value.size();

    if (packetLen < BLE_PACKET_HEADER_LEN) {
      return;
    }

    const uint8_t marker = bytes[0];
    const uint8_t packetType = bytes[1];
    const uint8_t payloadLen = bytes[4];
    const uint8_t sampleRateKHz = bytes[5];

    if (marker != 0xA5) {
      return;
    }

    if (packetType == PACKET_TYPE_START) {
      clearRawAudioBuffer();
      clearCompressedAudioBuffer();
      pttSessionActive = true;
      pttStopRequested = false;
      return;
    }

    if (packetType == PACKET_TYPE_STOP) {
      pttSessionActive = false;
      pttStopRequested = true;
      return;
    }

    if (packetType != PACKET_TYPE_AUDIO) {
      return;
    }

    if (sampleRateKHz != BLE_EXPECTED_SAMPLE_RATE_KHZ) {
      Serial.printf("Unexpected sample rate marker: %u kHz\n", sampleRateKHz);
    }

    const size_t availablePayload = packetLen - BLE_PACKET_HEADER_LEN;
    const size_t bytesToCopy = payloadLen < availablePayload ? payloadLen : availablePayload;
    pushRawAudioBytes(bytes + BLE_PACKET_HEADER_LEN, bytesToCopy);
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    deviceConnected = true;
    Serial.println("BLE client connected");
  }

  void onDisconnect(BLEServer* pServer) override {
    deviceConnected = false;
    pttSessionActive = false;
    pttStopRequested = false;
    stopBleStreamAndResetSequence();
    clearRawAudioBuffer();
    clearCompressedAudioBuffer();
    clearDecodedPcmBuffer();
    Serial.println("BLE client disconnected");
    pServer->getAdvertising()->start();
  }
};

void ARDUINO_ISR_ATTR onLoraDataAvailableIsr() {
  if (!loraEnableIsr || loraTaskHandle == nullptr) {
    return;
  }

  BaseType_t higherPriorityTaskWoken = pdFALSE;
  xTaskNotifyFromISR(loraTaskHandle, LORA_TASK_RX_BIT, eSetBits, &higherPriorityTaskWoken);
  if (higherPriorityTaskWoken == pdTRUE) {
    portYIELD_FROM_ISR();
  }
}

void loraTask(void* param) {
  LoRaPacket pkt;
  while (true) {
    uint32_t bits = 0;
    xTaskNotifyWait(0x00, ULONG_MAX, &bits, portMAX_DELAY);

    if (!(bits & LORA_TASK_RX_BIT)) {
      continue;
    }

    memset(&pkt, 0, sizeof(pkt));
    pkt.len = radio.getPacketLength();
    if (pkt.len > 0 && pkt.len <= sizeof(pkt.data)) {
      const int state = radio.readData(pkt.data, pkt.len);
      if (state == RADIOLIB_ERR_NONE) {
        if (xQueueSend(decoderQueue, &pkt, pdMS_TO_TICKS(3)) == pdPASS) {
          if (decodeTaskHandle != nullptr) {
            xTaskNotify(decodeTaskHandle, DECODE_TASK_BIT, eSetBits);
          }
        }
      }
    }

    const int state = radio.startReceive();
    if (state != RADIOLIB_ERR_NONE) {
      Serial.printf("Restart receive error: %d\n", state);
    }
  }
}

void decodeTask(void* param) {
  LoRaPacket pkt;
  uint8_t pendingCompressed[16];
  size_t pendingCompressedLen = 0;

  while (true) {
    uint32_t bits = 0;
    xTaskNotifyWait(0x00, ULONG_MAX, &bits, portMAX_DELAY);
    if (!(bits & DECODE_TASK_BIT)) {
      continue;
    }

    while (xQueueReceive(decoderQueue, &pkt, 0) == pdPASS) {
      if (pkt.len == 0) {
        continue;
      }

      size_t offset = 0;
      if (pendingCompressedLen > 0) {
        const size_t needed = bytesPerCompressedFrame - pendingCompressedLen;
        const size_t toCopy = (pkt.len < needed) ? pkt.len : needed;
        memcpy(&pendingCompressed[pendingCompressedLen], &pkt.data[0], toCopy);
        pendingCompressedLen += toCopy;
        offset += toCopy;

        if (pendingCompressedLen == (size_t)bytesPerCompressedFrame) {
          if (codec2DecodeSh123(pendingCompressed, decodeOutSamples)) {
            pushDecodedFrameToPcmBufferAndNotify();
          }
          pendingCompressedLen = 0;
        } else {
          continue;
        }
      }

      for (size_t i = offset; i + bytesPerCompressedFrame <= pkt.len; i += bytesPerCompressedFrame) {
        if (codec2DecodeSh123(&pkt.data[i], decodeOutSamples)) {
          pushDecodedFrameToPcmBufferAndNotify();
        }
        offset = i + bytesPerCompressedFrame;
      }

      const size_t tailBytes = pkt.len - offset;
      if (tailBytes > 0) {
        memcpy(pendingCompressed, &pkt.data[offset], tailBytes);
        pendingCompressedLen = tailBytes;
      }
    }
  }
}

void bleTask(void* param) {
  uint8_t payload[BLE_PCM_NOTIFY_BYTES];
  unsigned long lastBleNotifyMs = 0;

  while (true) {
    uint32_t bits = 0;
    xTaskNotifyWait(0x00, ULONG_MAX, &bits, pdMS_TO_TICKS(BLE_NOTIFY_INTERVAL_MS));

    bool connected = false;
    bool streamActive = false;
    uint16_t sequence = 0;
    unsigned long decodedAtMs = 0;
    getBleStreamState(&connected, &streamActive, &sequence, &decodedAtMs);

    if (!connected) {
      vTaskDelay(pdMS_TO_TICKS(20));
      continue;
    }

    unsigned int decodedSize = 0;
    xSemaphoreTake(decodedPcmMutex, portMAX_DELAY);
    decodedSize = decodedPcmBuffer.size();
    xSemaphoreGive(decodedPcmMutex);

    if (decodedSize >= BLE_PCM_NOTIFY_BYTES && millis() - lastBleNotifyMs >= BLE_NOTIFY_INTERVAL_MS) {
      xSemaphoreTake(decodedPcmMutex, portMAX_DELAY);
      for (uint16_t i = 0; i < BLE_PCM_NOTIFY_BYTES; i++) {
        decodedPcmBuffer.pop(payload[i]);
      }
      decodedSize = decodedPcmBuffer.size();
      xSemaphoreGive(decodedPcmMutex);

      if (ensureBleStartPacketSent(streamActive, sequence)) {
        sequence = 1;
      }

      notifyBlePacket(PACKET_TYPE_AUDIO, payload, BLE_PCM_NOTIFY_BYTES, false);
      if (VERBOSE_STREAM_LOGS) {
        Serial.printf("BLE notify audio payload=%u decodedRemaining=%u\n", (unsigned int)BLE_PCM_NOTIFY_BYTES, decodedSize);
      }
      vTaskDelay(pdMS_TO_TICKS(BLE_NOTIFY_POST_PACKET_DELAY_MS));
      lastBleNotifyMs = millis();
    }

    getBleStreamState(nullptr, &streamActive, nullptr, &decodedAtMs);
    if (streamActive && millis() - decodedAtMs > BLE_STREAM_IDLE_TIMEOUT_MS && millis() - lastBleNotifyMs >= BLE_NOTIFY_INTERVAL_MS) {
      size_t remaining = 0;
      while (true) {
        size_t chunkLen = 0;
        size_t remainingAfter = 0;

        xSemaphoreTake(decodedPcmMutex, portMAX_DELAY);
        remaining = decodedPcmBuffer.size();
        if (remaining > 0) {
          chunkLen = remaining > BLE_PCM_NOTIFY_BYTES ? BLE_PCM_NOTIFY_BYTES : remaining;
          for (size_t i = 0; i < chunkLen; i++) {
            decodedPcmBuffer.pop(payload[i]);
          }
          remainingAfter = decodedPcmBuffer.size();
        }
        xSemaphoreGive(decodedPcmMutex);

        if (chunkLen == 0) {
          break;
        }

        if (ensureBleStartPacketSent(streamActive, sequence)) {
          sequence = 1;
        }

        const bool finalChunk = (remainingAfter == 0);
        notifyBlePacket(PACKET_TYPE_AUDIO, payload, (uint8_t)chunkLen, finalChunk);
        vTaskDelay(pdMS_TO_TICKS(BLE_NOTIFY_POST_PACKET_DELAY_MS));
      }

      notifyBlePacket(PACKET_TYPE_STOP, nullptr, 0, false);
      stopBleStreamAndResetSequence();
      lastBleNotifyMs = millis();
    }
  }
}

void encoderTask(void* pvParameters) {
  int16_t speechSamples[CODEC2_PCM_SAMPLES_PER_FRAME];
  uint8_t compressedBits[CODEC2_COMPRESSED_BYTES_PER_FRAME];
  const uint16_t loraPacketTarget = LORA_PACKET_TARGET_BYTES;

  while (true) {
    if (popRawAudioFrame(speechSamples)) {
      if (codec2EncodeSh123(speechSamples, compressedBits)) {
        while ((COMPRESSED_AUDIO_BUFFER_BYTES - compressedAudioSize()) < (size_t)bytesPerCompressedFrame) {
          queueCompressedForLora(loraPacketTarget);
          vTaskDelay(pdMS_TO_TICKS(1));
        }

        if (!pushCompressedFrame(compressedBits)) {
          continue;
        }

        queueCompressedForLora(loraPacketTarget);
      }
    } else if (pttStopRequested) {
      LoRaPacket pkt;
      while (popCompressedTailPacket(&pkt, loraPacketTarget)) {
        if (xQueueSend(loraTxQueue, &pkt, portMAX_DELAY) != pdPASS) {
          break;
        }
        vTaskDelay(pdMS_TO_TICKS(LORA_QUEUE_PACING_DELAY_MS));
      }
      clearRawAudioBuffer();
      pttStopRequested = false;
    } else {
      vTaskDelay(pdMS_TO_TICKS(2));
    }
  }
}

void loraTxTask(void* param) {
  LoRaPacket pkt;
  while (true) {
    if (xQueueReceive(loraTxQueue, &pkt, portMAX_DELAY) != pdPASS) {
      continue;
    }

    loraEnableIsr = false;
    int txState = radio.transmit(pkt.data, pkt.len);
    if (txState != RADIOLIB_ERR_NONE) {
      Serial.printf("LoRa TX failed, code=%d\n", txState);
    }

    int rxState = radio.startReceive();
    if (rxState != RADIOLIB_ERR_NONE) {
      Serial.printf("Restart RX after TX failed, code=%d\n", rxState);
    }
    loraEnableIsr = true;

    vTaskDelay(pdMS_TO_TICKS(LORA_INTER_PACKET_DELAY_MS));
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.printf("%s Duplex Booting...\n", DEVICE_BLE_NAME);
  Serial.printf("Reset reason: %d\n", esp_reset_reason());

  int state = radio.begin(LORA_FREQ_MHZ, LORA_BW_KHZ, LORA_SF, LORA_CR, LORA_SYNCWORD, LORA_POWER_DBM, LORA_PREAMBLE);
  if (state == RADIOLIB_ERR_NONE) {
    Serial.println("Radio init OK");
    radio.setCurrentLimit(120.0);
    radio.setDio1Action(onLoraDataAvailableIsr);
  } else {
    Serial.printf("Radio failed, code: %d\n", state);
    while (1) delay(1000);
  }

  rawAudioMutex = xSemaphoreCreateMutex();
  compressedAudioMutex = xSemaphoreCreateMutex();
  decodedPcmMutex = xSemaphoreCreateMutex();
  streamStateMutex = xSemaphoreCreateMutex();
  if (!rawAudioMutex || !compressedAudioMutex || !decodedPcmMutex || !streamStateMutex) {
    Serial.println("Failed to create mutexes");
    while (1) delay(1000);
  }

  decoderQueue = xQueueCreate(LORA_QUEUE_DEPTH, sizeof(LoRaPacket));
  loraTxQueue = xQueueCreate(LORA_QUEUE_DEPTH, sizeof(LoRaPacket));
  if (!decoderQueue || !loraTxQueue) {
    Serial.println("Failed to create queues");
    while (1) delay(1000);
  }

  codec2InitDuplex();

  BLEDevice::init(DEVICE_BLE_NAME);
  BLEServer* pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* pService = pServer->createService(BLE_SERVICE_UUID);

  BLECharacteristic* pAudioWriteChar = pService->createCharacteristic(
    CHARACTERISTIC_UUID_AUDIO,
    BLECharacteristic::PROPERTY_WRITE_NR
  );
  pAudioWriteChar->setCallbacks(new AudioWriteCallbacks());

  pAudioNotifyChar = pService->createCharacteristic(
    CHARACTERISTIC_UUID_RX,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pAudioNotifyChar->addDescriptor(new BLE2902());

  pService->start();
  pServer->getAdvertising()->start();

  xTaskCreatePinnedToCore(loraTask, "lora_task", 8192, NULL, 5, &loraTaskHandle, CORE_RADIO_BLE);
  xTaskCreatePinnedToCore(decodeTask, "decode_task", 32768, NULL, 4, &decodeTaskHandle, CORE_CODEC);
  xTaskCreatePinnedToCore(bleTask, "ble_task", 8192, NULL, 3, &bleTaskHandle, CORE_RADIO_BLE);
  xTaskCreatePinnedToCore(encoderTask, "encoder_task", 16384, NULL, 3, &encoderTaskHandle, CORE_CODEC);
  xTaskCreatePinnedToCore(loraTxTask, "lora_tx_task", 8192, NULL, 4, &loraTxTaskHandle, CORE_RADIO_BLE);

  state = radio.startReceive();
  if (state != RADIOLIB_ERR_NONE) {
    Serial.printf("Failed to start receive, code: %d\n", state);
  }

  Serial.println("Duplex ready: phone<->BLE + LoRa TX/RX active");
}

void loop() {
  delay(20);
}
