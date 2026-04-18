import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';

import 'dart:io';
import 'package:geolocator/geolocator.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:record/record.dart';
import 'package:sound_stream/sound_stream.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

const int kAudioSampleRate = 8000;
const int kAudioChannels = 1;
const int kSenderBleAudioPayloadBytes = 200;
const int kPreferredMtu = 247;
const int kBlePacketHeaderBytes = 8;
const String kReceiverNotifyUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a9";
const int kPlaybackChunkBytes = 200;
const int kJitterPrebufferBytes = 960;
const int kPlaybackBufferMaxBytes = 4000;
const int kPlaybackTickMs = 13;
const int kWavHeaderBytes = 44;
const int kSenderPostPttWaitMs = 1400;
const double kReceiverPlaybackGain = 3.0;
const String kSenderNameKeyword = "heltec_sender";
const String kReceiverNameKeyword = "heltec_receiver";
const String kSenderWriteUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
const int kHeltecCompressedBufferBytes = 4096;
const int kCodec2CompressedBytesPerFrame = 7;
const int kCodec2FrameDurationMs = 40;
const double kPttSafetyHeadroom = 0.65;
const int kPttWarningBeforeLimitMs = 3000;
const int kPttLimitBeepLockMs = 3800;
const int kPttFixedLimitMs = 10000;

final int kComputedPttLimitMs = kPttFixedLimitMs;

_DeviceRole _resolveRoleFromName(String name) {
  final normalized = name.toLowerCase();
  if (normalized.contains(kSenderNameKeyword)) {
    return _DeviceRole.sender;
  }
  if (normalized.contains(kReceiverNameKeyword)) {
    return _DeviceRole.receiver;
  }
  return _DeviceRole.unknown;
}

String _deviceDisplayName(BluetoothDevice device) {
  final name = device.platformName.trim();
  if (name.isNotEmpty) {
    return name;
  }
  return device.remoteId.str;
}



void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Enhanced logging to help debug radio timing
  FlutterBluePlus.setLogLevel(LogLevel.info);
  NotificationService.instance.init();
  runApp(const MyApp());
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidInit);
    await _plugin.initialize(settings);

    const androidChannel = AndroidNotificationChannel(
      'messages',
      'Messages',
      description: 'Incoming messages',
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);
  }

  Future<void> showMessage({
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'messages',
      'Messages',
      channelDescription: 'Incoming messages',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      details,
    );
  }
}

class _ReceiverClip {
  const _ReceiverClip({
    required this.path,
    required this.label,
    required this.sizeBytes,
    required this.savedAt,
  });

  final String path;
  final String label;
  final int sizeBytes;
  final DateTime savedAt;
}

class _WavRecorder {
  RandomAccessFile? _file;
  String? _path;
  int _dataBytesWritten = 0;
  int _sampleRate = kAudioSampleRate;
  int _channels = kAudioChannels;

  bool get isRecording => _file != null;

  Future<String> start({
    required int sampleRate,
    required int channels,
  }) async {
    await stop();

    final directory = await _resolveReceiverClipDirectory();
    await directory.create(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File(
      '${directory.path}${Platform.pathSeparator}receiver_$stamp.wav',
    );

    _file = await file.open(mode: FileMode.write);
    _path = file.path;
    _dataBytesWritten = 0;
    _sampleRate = sampleRate;
    _channels = channels;
    await _file!.writeFrom(_buildWavHeader(
      sampleRate: sampleRate,
      channels: channels,
      dataLength: 0,
    ));
    return _path!;
  }

  Future<void> append(Uint8List bytes) async {
    if (_file == null || bytes.isEmpty) {
      return;
    }
    await _file!.writeFrom(bytes);
    _dataBytesWritten += bytes.length;
  }

  Future<String?> stop() async {
    if (_file == null) {
      return _path;
    }

    final file = _file!;
    final path = _path;
    await file.setPosition(0);
    await file.writeFrom(_buildWavHeader(
      sampleRate: _sampleRate,
      channels: _channels,
      dataLength: _dataBytesWritten,
    ));
    await file.close();
    _file = null;
    _path = null;
    _dataBytesWritten = 0;
    return path;
  }

  Future<Directory> _resolveReceiverClipDirectory() async {
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        return Directory(
          '${extDir.path}${Platform.pathSeparator}receiver_clips',
        );
      }
    }

    final docsDir = await getApplicationDocumentsDirectory();
    return Directory(
      '${docsDir.path}${Platform.pathSeparator}receiver_clips',
    );
  }

  Uint8List _buildWavHeader({
    required int sampleRate,
    required int channels,
    required int dataLength,
  }) {
    final byteRate = sampleRate * channels * 2;
    final blockAlign = channels * 2;
    final totalLength = 36 + dataLength;
    final data = ByteData(kWavHeaderBytes);

    void writeString(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        data.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeString(0, 'RIFF');
    data.setUint32(4, totalLength, Endian.little);
    writeString(8, 'WAVE');
    writeString(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, channels, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, byteRate, Endian.little);
    data.setUint16(32, blockAlign, Endian.little);
    data.setUint16(34, 16, Endian.little);
    writeString(36, 'data');
    data.setUint32(40, dataLength, Endian.little);
    return data.buffer.asUint8List();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ScanScreen(),
    );
  }
}

// --- SCAN SCREEN ---
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _isScanning = false;
  late StreamSubscription<bool> _scanSubscription;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _scanSubscription = FlutterBluePlus.isScanning.listen((s) {
      if (mounted) setState(() => _isScanning = s);
    });
  }

  @override
  void dispose() {
    _scanSubscription.cancel();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.locationWhenInUse,
      Permission.camera,
      Permission.microphone,
      Permission.notification,
    ].request();
  }

  void _startScan() async {
    try {
      final btState = await FlutterBluePlus.adapterState.first;
      if (btState != BluetoothAdapterState.on) {
        await _promptEnableBluetooth();
        return;
      }

      final locationEnabled = await Geolocator.isLocationServiceEnabled();
      if (!locationEnabled) {
        await _promptEnableLocation();
        return;
      }

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        withKeywords: ["Heltec"], // Filter specifically for your boards
      );
    } catch (e) {
      debugPrint("Scan Error: $e");
    }
  }

  void _openDeviceScreen(BluetoothDevice device) {
    final role = _resolveRoleFromName(_deviceDisplayName(device));
    final Widget page = switch (role) {
      _DeviceRole.sender => SenderScreen(device: device),
      _DeviceRole.receiver => ReceiverScreen(device: device),
      _DeviceRole.unknown => ChatScreen(device: device),
    };

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
  }

  Future<void> _promptEnableBluetooth() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Bluetooth is off"),
        content:
            const Text("Please enable Bluetooth to scan for nearby devices."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await FlutterBluePlus.turnOn();
              } catch (_) {
                // If user rejects or device can't turn on programmatically.
              }
            },
            child: const Text("Turn on"),
          ),
        ],
      ),
    );
  }

  Future<void> _promptEnableLocation() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Location is off"),
        content: const Text(
            "Please enable Location services to scan for nearby devices."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await Geolocator.openLocationSettings();
            },
            child: const Text("Open settings"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("LoRa-BLE Gateway")),
      body: Column(
        children: [
          LinearProgressIndicator(value: _isScanning ? null : 0),
          Expanded(
            child: StreamBuilder<List<ScanResult>>(
              stream: FlutterBluePlus.scanResults,
              builder: (context, snapshot) {
                final results = snapshot.data ?? [];
                return ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final r = results[index];
                    return ListTile(
                      leading: const Icon(Icons.router),
                      title: Text(r.device.platformName.isEmpty ? "Unknown" : r.device.platformName),
                      subtitle: Text(r.device.remoteId.str),
                      onTap: () => _openDeviceScreen(r.device),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? null : _startScan,
        label: Text(_isScanning ? "Scanning..." : "Search Devices"),
        icon: const Icon(Icons.bluetooth_searching),
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.device,
    this.screenTitle,
  });

  final BluetoothDevice device;
  final String? screenTitle;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class SenderScreen extends StatelessWidget {
  const SenderScreen({super.key, required this.device});

  final BluetoothDevice device;

  @override
  Widget build(BuildContext context) {
    return ChatScreen(
      device: device,
      screenTitle: 'Sender',
    );
  }
}

class ReceiverScreen extends StatelessWidget {
  const ReceiverScreen({super.key, required this.device});

  final BluetoothDevice device;

  @override
  Widget build(BuildContext context) {
    return ChatScreen(
      device: device,
      screenTitle: 'Receiver',
    );
  }
}

class _ChatScreenState extends State<ChatScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  final PlayerStream _player = PlayerStream();
  final AudioPlayer _clipPlayer = AudioPlayer();
  final _WavRecorder _wavRecorder = _WavRecorder();
  final Queue<int> _pcmBuffer = Queue<int>();
  final Queue<int> _playbackBuffer = Queue<int>();
  final List<_ChatLog> _logs = <_ChatLog>[];
  final List<_ReceiverClip> _receiverClips = <_ReceiverClip>[];

  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;//connected or disconnected
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<List<int>>? _notifySubscription;
  Timer? _playbackDrainTimer;
  Timer? _pttLimitTimer;
  Future<void> _receiverPacketChain = Future<void>.value();

  BluetoothCharacteristic? _writeCharacteristic;
  BluetoothCharacteristic? _notifyCharacteristic;
  bool _connecting = true;
  bool _connected = false;
  bool _streaming = false;
  bool _senderWaitingForSave = false;
  bool _draining = false;
  bool _playerReady = false;
  bool _receiverStreaming = false;
  bool _remotePttActive = false;
  bool _clipsExpanded = false;
  bool _playbackStarted = false;
  bool _receiverClipFinalizing = false;
  bool _pttAutoStopInProgress = false;
  int _sequence = 0;
  int _playbackSampleRate = kAudioSampleRate;
  int _currentClipBytes = 0;
  int _pttRemainingMs = kComputedPttLimitMs;
  String? _activeClipPath;
  String? _playingClipPath;
  DateTime? _pttStartedAt;
  DateTime? _pttLockedUntil;
  bool _pttWarningPlayed = false;
  String _status = 'Connecting...';

  @override
  void initState() {
    super.initState();
    _connectToDevice();
  }

  @override
  void dispose() {
    _audioSubscription?.cancel();
    _connectionSubscription?.cancel();
    _notifySubscription?.cancel();
    _playbackDrainTimer?.cancel();
    _pttLimitTimer?.cancel();
    unawaited(_player.stop());
    unawaited(_clipPlayer.dispose());
    unawaited(_wavRecorder.stop());
    _recorder.dispose();
    widget.device.disconnect();
    super.dispose();
  }

  Future<void> _connectToDevice() async {
    _appendLog('Connecting to ${_deviceLabel(widget.device)}', false);

    try {
      _connectionSubscription = widget.device.connectionState.listen((state) {
        if (!mounted) {
          return;
        }
        setState(() {
          _connected = state == BluetoothConnectionState.connected;
          if (!_connected) {
            _streaming = false;
            _receiverStreaming = false;
            _remotePttActive = false;
            _writeCharacteristic = null;
            _notifyCharacteristic = null;
            _status = 'Disconnected';
          }
        });
        if (state != BluetoothConnectionState.connected) {
          unawaited(_finishReceiverClip());
        }
      });

      await widget.device.connect(mtu: kPreferredMtu);

      if (Platform.isAndroid) {
        await widget.device.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
      }

      final services = await widget.device.discoverServices();
      final characteristic = _pickWriteCharacteristic(services);
      final notifyCharacteristic = _pickNotifyCharacteristic(services);

      if (!mounted) {
        return;
      }

      setState(() {
        _writeCharacteristic = characteristic;
        _notifyCharacteristic = notifyCharacteristic;
        _connecting = false;
        _connected = true;
        _status = 'Connected';
      });

      if (characteristic != null) {
        _appendLog(
          'Connected. Audio write characteristic: ${characteristic.uuid.str}',
          false,
        );
      } else {
        _appendLog('Audio write characteristic not found.', false);
      }
      if (notifyCharacteristic != null) {
        await _startBleAudioReceiver(notifyCharacteristic);
        await _loadReceiverClips();
      } else {
        _appendLog('Audio notify characteristic not found.', false);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _connecting = false;
        _connected = false;
        _status = 'Connection failed';
      });
      _appendLog('BLE connect error: $e', false);
    }
  }

  BluetoothCharacteristic? _pickWriteCharacteristic(
    List<BluetoothService> services,
  ) {
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.str.toLowerCase();
        final props = characteristic.properties;
        if (uuid == kSenderWriteUuid &&
            (props.writeWithoutResponse || props.write)) {
          return characteristic;
        }
      }
    }

    for (final service in services) {
      for (final characteristic in service.characteristics) {
        final props = characteristic.properties;
        if (props.writeWithoutResponse || props.write) {
          return characteristic;
        }
      }
    }
    return null;
  }

  BluetoothCharacteristic? _pickNotifyCharacteristic(
    List<BluetoothService> services,
  ) {
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.str.toLowerCase();
        final props = characteristic.properties;
        if (uuid == kReceiverNotifyUuid &&
            (props.notify || props.indicate)) {
          return characteristic;
        }
      }
    }

    return null;
  }

  Future<void> _startBleAudioReceiver(
    BluetoothCharacteristic characteristic,
  ) async {
    await _ensurePlayerInitialized(kAudioSampleRate);
    _startPlaybackDrainLoop();
    await characteristic.setNotifyValue(true);
    _notifySubscription?.cancel();
    _notifySubscription = characteristic.onValueReceived.listen((value) {
      final packet = Uint8List.fromList(value);
      _receiverPacketChain = _receiverPacketChain.then((_) {
        return _handleIncomingBlePacket(packet);
      }).catchError((error, stackTrace) {
        _appendLog('Receiver packet error: $error', false);
      });
    });
    _appendLog(
      'Subscribed to receiver audio on ${characteristic.uuid.str}',
      false,
    );
  }

  Future<void> _ensurePlayerInitialized(int sampleRate) async {
    if (_playerReady && _playbackSampleRate == sampleRate) {
      return;
    }

    if (_playerReady) {
      await _player.stop();
      _playerReady = false;
    }

    await _player.initialize(sampleRate: sampleRate);
    await _player.usePhoneSpeaker(true);
    await _player.start();
    _playbackSampleRate = sampleRate;
    _playerReady = true;
  }

  void _startPlaybackDrainLoop() {
    _playbackDrainTimer?.cancel();
    _playbackDrainTimer = Timer.periodic(
      const Duration(milliseconds: kPlaybackTickMs),
      (_) {
        unawaited(_drainPlaybackBuffer());
      },
    );
  }

  Future<void> _drainPlaybackBuffer() async {
    if (!_playerReady) {
      return;
    }

    if (!_playbackStarted) {
      if (_playbackBuffer.length >= kJitterPrebufferBytes) {
        _playbackStarted = true;
        _appendLog(
          'Playback buffer ready: ${_playbackBuffer.length} bytes',
          false,
        );
      } else {
        return;
      }
    }

    if (_playbackBuffer.length < kPlaybackChunkBytes) {
      if (!_receiverStreaming && _playbackBuffer.isNotEmpty) {
        final tail = Uint8List.fromList(
          List<int>.generate(_playbackBuffer.length, (_) => _playbackBuffer.removeFirst()),
        );
        _player.audioStream.add(_applyPlaybackGain(tail));
      }
      return;
    }

    final chunk = Uint8List.fromList(
      List<int>.generate(kPlaybackChunkBytes, (_) => _playbackBuffer.removeFirst()),
    );
    _player.audioStream.add(_applyPlaybackGain(chunk));
  }

  Uint8List _applyPlaybackGain(Uint8List pcmBytes) {
    if (kReceiverPlaybackGain <= 1.0 || pcmBytes.length < 2) {
      return pcmBytes;
    }

    final samples = ByteData.sublistView(pcmBytes);
    for (var offset = 0; offset + 1 < pcmBytes.length; offset += 2) {
      final input = samples.getInt16(offset, Endian.little);
      final boosted = (input * kReceiverPlaybackGain).round();
      final clamped = boosted.clamp(-32768, 32767).toInt();
      samples.setInt16(offset, clamped, Endian.little);
    }
    return pcmBytes;
  }

  Future<void> _handleIncomingBlePacket(Uint8List packet) async {
    if (packet.length < kBlePacketHeaderBytes) {
      return;
    }

    if (packet[0] != 0xA5) {
      _appendLog('Ignored packet with invalid marker', false);
      return;
    }

    final packetType = packet[1];
    final payloadLength = packet[4];
    final sampleRateKHz = packet[5];
    final availablePayload = packet.length - kBlePacketHeaderBytes;
    final effectiveLength =
        payloadLength < availablePayload ? payloadLength : availablePayload;
    final packetSampleRate =
        sampleRateKHz > 0 ? sampleRateKHz * 1000 : kAudioSampleRate;

    if (packetType == _PacketType.start.code) {
      if (mounted) {
        setState(() {
          _receiverStreaming = true;
          _remotePttActive = true;
          if (!_streaming) {
            _status = 'Remote PTT active';
          }
        });
      } else {
        _receiverStreaming = true;
        _remotePttActive = true;
      }
      _playbackStarted = false;
      _playbackBuffer.clear();
      _currentClipBytes = 0;
      await _startReceiverClip(packetSampleRate);
      _appendLog('Incoming voice started', false);
      return;
    }

    if (packetType == _PacketType.stop.code) {
      if (mounted) {
        setState(() {
          _receiverStreaming = false;
          _remotePttActive = false;
          if (!_streaming) {
            _status = _connected ? 'Connected' : 'Disconnected';
          }
        });
      } else {
        _receiverStreaming = false;
        _remotePttActive = false;
      }
      await _finishReceiverClip();
      _appendLog('Incoming voice ended', false);
      return;
    }

    if (packetType != _PacketType.audio.code || effectiveLength <= 0) {
      return;
    }

    await _ensurePlayerInitialized(packetSampleRate);
    final payload = Uint8List.sublistView(
      packet,
      kBlePacketHeaderBytes,
      kBlePacketHeaderBytes + effectiveLength,
    );
    await _wavRecorder.append(Uint8List.fromList(payload));
    _currentClipBytes += effectiveLength;
    _playbackBuffer.addAll(payload);
    while (_playbackBuffer.length > kPlaybackBufferMaxBytes) {
      _playbackBuffer.removeFirst();
    }
  }

  Future<void> _startReceiverClip(int sampleRate) async {
    if (_wavRecorder.isRecording) {
      await _finishReceiverClip();
    }
    final path = await _wavRecorder.start(
      sampleRate: sampleRate,
      channels: kAudioChannels,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _activeClipPath = path;
    });
  }

  Future<void> _finishReceiverClip() async {
    if (_receiverClipFinalizing) {
      return;
    }
    _receiverClipFinalizing = true;
    final path = await _wavRecorder.stop();
    if (!mounted || path == null) {
      _receiverClipFinalizing = false;
      return;
    }

    final file = File(path);
    FileStat? stat;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (await file.exists()) {
        stat = await file.stat();
        if (stat.size > kWavHeaderBytes || _currentClipBytes == 0) {
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }

    if (stat == null || !(await file.exists())) {
      if (mounted) {
        setState(() {
          _activeClipPath = null;
        });
      }
      _receiverClipFinalizing = false;
      return;
    }
    final fileStat = stat;
    final label = 'Clip ${_receiverClips.length + 1}';

    setState(() {
      _activeClipPath = null;
      _clipsExpanded = true;
      _receiverClips.insert(
        0,
        _ReceiverClip(
          path: path,
          label: label,
          sizeBytes: fileStat.size,
          savedAt: fileStat.modified,
        ),
      );
      if (_receiverClips.length > 8) {
        _receiverClips.removeRange(8, _receiverClips.length);
      }
    });
    await _loadReceiverClips();
    _appendLog('Saved received clip', false);
    _currentClipBytes = 0;
    _receiverClipFinalizing = false;
  }

  Future<void> _loadReceiverClips() async {
    final tempRecorder = _WavRecorder();
    final directory = await tempRecorder._resolveReceiverClipDirectory();
    if (!await directory.exists()) {
      return;
    }

    final entities = await directory
        .list()
        .where((entity) => entity is File && entity.path.toLowerCase().endsWith('.wav'))
        .cast<File>()
        .toList();
    entities.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );

    final clips = <_ReceiverClip>[];
    for (var i = 0; i < entities.length && i < 8; i++) {
      final file = entities[i];
      final stat = await file.stat();
      clips.add(
        _ReceiverClip(
          path: file.path,
          label: 'Clip ${i + 1}',
          sizeBytes: stat.size,
          savedAt: stat.modified,
        ),
      );
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _receiverClips
        ..clear()
        ..addAll(clips);
    });
  }

  Future<void> _toggleClipPlayback(_ReceiverClip clip) async {
    if (_playingClipPath == clip.path) {
      await _clipPlayer.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        _playingClipPath = null;
      });
      return;
    }

    await _clipPlayer.stop();
    await _clipPlayer.play(DeviceFileSource(clip.path));
    if (!mounted) {
      return;
    }
    setState(() {
      _playingClipPath = clip.path;
    });
  }

  Future<void> _deleteClip(_ReceiverClip clip) async {
    final file = File(clip.path);
    if (await file.exists()) {
      await file.delete();
    }
    if (_playingClipPath == clip.path) {
      await _clipPlayer.stop();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _receiverClips.removeWhere((item) => item.path == clip.path);
      if (_playingClipPath == clip.path) {
        _playingClipPath = null;
      }
    });
  }

  String _formatClipSize(int sizeBytes) {
    final kb = sizeBytes / 1024;
    return '${kb.toStringAsFixed(1)} KB';
  }

  String _formatClipTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  Widget _buildReceiverClipsPanel() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _clipsExpanded = !_clipsExpanded;
              });
            },
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Received Clips',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  _receiverClips.isEmpty
                      ? '0'
                      : '${_receiverClips.length}',
                ),
                const SizedBox(width: 8),
                Icon(
                  _clipsExpanded ? Icons.expand_less : Icons.expand_more,
                ),
              ],
            ),
          ),
          if (_activeClipPath != null) ...[
            const SizedBox(height: 6),
            const Text(
              'Recording current received clip...',
              style: TextStyle(fontSize: 12),
            ),
          ],
          if (_clipsExpanded) ...[
            const SizedBox(height: 10),
            if (_receiverClips.isEmpty)
              const Text('No clips yet.')
            else
              SizedBox(
                height: 170,
                child: ListView.separated(
                  itemCount: _receiverClips.length,
                  separatorBuilder: (_, __) => const Divider(height: 12),
                  itemBuilder: (context, index) {
                    final clip = _receiverClips[index];
                    final isPlaying = _playingClipPath == clip.path;
                    return Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                clip.label,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              Text(
                                '${_formatClipTime(clip.savedAt)}  ${_formatClipSize(clip.sizeBytes)}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => _toggleClipPlayback(clip),
                          child: Text(isPlaying ? 'Stop' : 'Play'),
                        ),
                        TextButton(
                          onPressed: () => _deleteClip(clip),
                          child: const Text('Delete'),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _startPtt() async {
    if (_streaming ||
        _senderWaitingForSave ||
        !_connected ||
        _writeCharacteristic == null) {
      return;
    }

    try {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        throw Exception('Microphone permission not granted.');
      }

      _pcmBuffer.clear();
      _sequence = 0;
      _pttWarningPlayed = false;
      _pttStartedAt = DateTime.now();
      _pttRemainingMs = kComputedPttLimitMs;

      await _sendControlPacket(_PacketType.start);

      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: kAudioSampleRate,
          numChannels: kAudioChannels,
        ),
      );

      _audioSubscription = stream.listen(
        (chunk) {
          _pcmBuffer.addAll(chunk);
          unawaited(_drainAudioBuffer());
        },
        onError: (Object e) {
          _appendLog('Audio stream error: $e', false);
        },
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _streaming = true;
        _status = 'Streaming voice';
      });
      _startPttLimitCountdown();
      _appendLog('PTT started', true);
    } catch (e) {
      _appendLog('PTT start failed: $e', false);
    }
  }

  void _startPttLimitCountdown() {
    _pttLimitTimer?.cancel();
    _pttLimitTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final startedAt = _pttStartedAt;
      if (!_streaming || startedAt == null) {
        return;
      }

      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      final remaining = (kComputedPttLimitMs - elapsed).clamp(0, kComputedPttLimitMs);

      if (mounted) {
        setState(() {
          _pttRemainingMs = remaining;
        });
      } else {
        _pttRemainingMs = remaining;
      }

      if (!_pttWarningPlayed && remaining <= kPttWarningBeforeLimitMs && remaining > 0) {
        _pttWarningPlayed = true;
        unawaited(SystemSound.play(SystemSoundType.click));
      }

      if (remaining <= 0) {
        unawaited(_enforcePttLimitStop());
      }
    });
  }

  Future<void> _playLimitBeepAndLock() async {
    _pttLockedUntil = DateTime.now().add(
      const Duration(milliseconds: kPttLimitBeepLockMs),
    );
    await SystemSound.play(SystemSoundType.alert);
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(
      const Duration(milliseconds: kPttLimitBeepLockMs),
    );
  }

  bool _isPttLocked() {
    final lockedUntil = _pttLockedUntil;
    if (lockedUntil == null) {
      return false;
    }
    return DateTime.now().isBefore(lockedUntil);
  }

  Future<void> _enforcePttLimitStop() async {
    if (!_streaming || _pttAutoStopInProgress) {
      return;
    }
    _pttAutoStopInProgress = true;
    try {
      await _playLimitBeepAndLock();
      await _stopPtt(autoStoppedByLimit: true);
    } finally {
      _pttAutoStopInProgress = false;
    }
  }

  Future<void> _stopPtt({bool autoStoppedByLimit = false}) async {
    if (!_streaming) {
      return;
    }

    _pttLimitTimer?.cancel();
    _pttStartedAt = null;
    _pttRemainingMs = kComputedPttLimitMs;

    try {
      await _audioSubscription?.cancel();
      _audioSubscription = null;
      await _recorder.stop();
      await _drainAudioBuffer(flushFinalPacket: true);
      await _sendControlPacket(_PacketType.stop);
    } catch (e) {
      _appendLog('PTT stop failed: $e', false);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _streaming = false;
      _senderWaitingForSave = true;
      _status = _connected
          ? (autoStoppedByLimit
              ? 'PTT time limit reached. Waiting for save'
              : 'Waiting for file save')
          : 'Disconnected';
    });
    _appendLog(
      autoStoppedByLimit
          ? 'PTT auto-stopped at time limit to avoid buffer overflow'
          : 'PTT stopped',
      true,
    );

    Future<void>.delayed(const Duration(milliseconds: kSenderPostPttWaitMs))
        .then((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _senderWaitingForSave = false;
        _status = _connected ? 'Connected' : 'Disconnected';
      });
    });
  }

  Future<void> _drainAudioBuffer({bool flushFinalPacket = false}) async {
    if (_draining) {
      return;
    }

    final characteristic = _writeCharacteristic;
    if (characteristic == null) {
      return;
    }

    _draining = true;
    try {
      while (_pcmBuffer.length >= kSenderBleAudioPayloadBytes) {
        final payload = Uint8List.fromList(
          List<int>.generate(
            kSenderBleAudioPayloadBytes,
            (_) => _pcmBuffer.removeFirst(),
          ),
        );
        await _writePacket(
          _buildAudioPacket(
            sequence: _sequence++,
            payload: payload,
            payloadLength: payload.length,
            isFinalChunk: false,
          ),
          characteristic,
        );
      }

      if (flushFinalPacket && _pcmBuffer.isNotEmpty) {
        final remaining = _pcmBuffer.length;
        final payload = Uint8List(kSenderBleAudioPayloadBytes);
        for (var i = 0; i < remaining; i++) {
          payload[i] = _pcmBuffer.removeFirst();
        }
        await _writePacket(
          _buildAudioPacket(
            sequence: _sequence++,
            payload: payload,
            payloadLength: remaining,
            isFinalChunk: true,
          ),
          characteristic,
        );
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _sendControlPacket(_PacketType type) async {
    final characteristic = _writeCharacteristic;
    if (characteristic == null) {
      throw Exception('Writable BLE characteristic not available.');
    }
    await _writePacket(_buildControlPacket(type), characteristic);
  }

  Future<void> _writePacket(
    Uint8List packet,
    BluetoothCharacteristic characteristic,
  ) async {
    final withoutResponse = characteristic.properties.writeWithoutResponse;
    await characteristic.write(packet, withoutResponse: withoutResponse);
  }

  Uint8List _buildAudioPacket({
    required int sequence,
    required Uint8List payload,
    required int payloadLength,
    required bool isFinalChunk,
  }) {
    final builder = BytesBuilder(copy: false);
    builder.add(<int>[
      0xA5,
      _PacketType.audio.code,
      sequence & 0xFF,
      (sequence >> 8) & 0xFF,
      payloadLength & 0xFF,
      kAudioSampleRate ~/ 1000,
      kAudioChannels,
      isFinalChunk ? 0x01 : 0x00,
    ]);
    builder.add(payload);
    return builder.takeBytes();
  }

  Uint8List _buildControlPacket(_PacketType type) {
    return Uint8List.fromList(<int>[
      0xA5,
      type.code,
      0x00,
      0x00,
      0x00,
      kAudioSampleRate ~/ 1000,
      kAudioChannels,
      0x00,
    ]);
  }

  String _deviceLabel(BluetoothDevice device) {
    final name = device.platformName.trim();
    if (name.isNotEmpty) {
      return name;
    }
    return device.remoteId.str;
  }

  void _appendLog(String message, bool fromMe) {
    if (!mounted) {
      return;
    }
    setState(() {
      _logs.add(_ChatLog(message: message, fromMe: fromMe));
    });
  }

  @override
  Widget build(BuildContext context) {
    final isReceivingOrSaving =
        _receiverStreaming || _remotePttActive || _activeClipPath != null;
    final pttLocked = _isPttLocked();
    final canTalk = _connected &&
        !_connecting &&
        !_senderWaitingForSave &&
        !pttLocked &&
        !isReceivingOrSaving &&
        _writeCharacteristic != null;
    final remainingSeconds = (_pttRemainingMs / 1000).clamp(0, 999).toStringAsFixed(1);
    final pttLabel = _senderWaitingForSave
        ? 'Wait while file is saving'
        : pttLocked
            ? 'Beep active. Please wait...'
        : isReceivingOrSaving && !_streaming
            ? 'Other side is talking...'
        : canTalk
            ? (_streaming
                ? 'Talking... $remainingSeconds s left'
                : 'Tap to start PTT')
            : 'Connecting BLE audio...';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.screenTitle ?? _deviceLabel(widget.device)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.blue.shade50,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Status: $_status'),
                  const SizedBox(height: 4),
                  Text('Device: ${widget.device.remoteId.str}'),
                  const SizedBox(height: 4),
                  Text(
                    'PTT packet: 8-byte header + $kSenderBleAudioPayloadBytes byte PCM payload',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'PTT talk limit: ${(kComputedPttLimitMs / 1000).toStringAsFixed(1)}s fixed (auto-stop + beep near limit)',
                  ),
                ],
              ),
            ),
            if (_notifyCharacteristic != null) _buildReceiverClipsPanel(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  final log = _logs[index];
                  return Align(
                    alignment:
                        log.fromMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: log.fromMe ? Colors.blue : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        log.message,
                        style: TextStyle(
                          color: log.fromMe ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.amber.shade100),
                    ),
                    child: Text(
                      _streaming
                          ? 'Speak clearly and stop before timer ends. App will auto-stop at limit.'
                          : isReceivingOrSaving
                              ? 'Receiver PTT is locked while the sender is talking.'
                          : 'Instruction: hold short voice bursts. When beep plays, wait until button is enabled again.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.amber.shade900,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: canTalk
                        ? () {
                            if (_streaming) {
                              unawaited(_stopPtt());
                            } else {
                              unawaited(_startPtt());
                            }
                          }
                        : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: double.infinity,
                      height: 120,
                      decoration: BoxDecoration(
                        color: _senderWaitingForSave
                            ? Colors.amber
                            : isReceivingOrSaving
                                ? Colors.grey
                                : (_streaming ? Colors.red : Colors.green),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Center(
                        child: Text(
                          pttLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _DeviceRole { sender, receiver, unknown }

class _ChatLog {
  const _ChatLog({
    required this.message,
    required this.fromMe,
  });

  final String message;
  final bool fromMe;
}

enum _PacketType {
  start(0x01),
  audio(0x02),
  stop(0x03);

  const _PacketType(this.code);

  final int code;
}
