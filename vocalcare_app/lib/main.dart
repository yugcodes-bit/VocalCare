import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'audio_processor.dart';

void main() {
  runApp(const VocalCareApp());
}

class VocalCareApp extends StatelessWidget {
  const VocalCareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VocalCare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ── Recorder ──────────────────────────────────
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  bool _isRecording   = false;
  bool _recorderReady = false;

  // ── Model ─────────────────────────────────────
  Interpreter? _interpreter;

  // ── MQTT ──────────────────────────────────────
  MqttServerClient? _mqttClient;
  bool _mqttConnected = false;

  // ── UI state ──────────────────────────────────
  String _statusText       = 'Starting...';
  String _predictedCommand = '';
  String? _lastRecordedPath;

  // ── Commands ──────────────────────────────────
  final List<String> _commands = [
    'on', 'off', 'yes', 'no', 'stop', 'go', 'up', 'down'
  ];

  // ─────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _initRecorder();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadModel();
      _connectMQTT();
    });
  }

  // ─────────────────────────────────────────────
  // Microphone init
  // ─────────────────────────────────────────────
  Future<void> _initRecorder() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      setState(() => _statusText = 'Microphone permission denied!');
      return;
    }
    await _recorder.openRecorder();
    setState(() => _recorderReady = true);
  }

  // ─────────────────────────────────────────────
  // Load TFLite model
  // ─────────────────────────────────────────────
  Future<void> _loadModel() async {
    try {
      final byteData = await DefaultAssetBundle.of(context)
          .load('assets/vocalcare_model.tflite');

      final dir = await getApplicationDocumentsDirectory();
      final modelFile = File('${dir.path}/vocalcare_model.tflite');
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      await modelFile.writeAsBytes(bytes, flush: true);

      _interpreter = await Interpreter.fromFile(modelFile);
      print('Model loaded! Input: ${_interpreter!.getInputTensor(0).shape}');
      setState(() => _statusText = 'Ready — tap mic to speak');
    } catch (e) {
      print('Model error: $e');
      setState(() => _statusText = 'Model failed: $e');
    }
  }

  // ─────────────────────────────────────────────
  // MQTT connect
  // ─────────────────────────────────────────────
  Future<void> _connectMQTT() async {
  try {
    final clientId = 'VocalCare_${DateTime.now().millisecondsSinceEpoch}';
    _mqttClient = MqttServerClient('broker.hivemq.com', clientId);
    _mqttClient!.port = 1883;
    _mqttClient!.keepAlivePeriod = 20;
    _mqttClient!.connectTimeoutPeriod = 15000;
    _mqttClient!.logging(on: false);

    final connMsg = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);
    _mqttClient!.connectionMessage = connMsg;

    print('Connecting to HiveMQ...');
    final status = await _mqttClient!.connect();
    print('Connection status: $status');

    if (_mqttClient!.connectionStatus!.state ==
    MqttConnectionState.connected) {
  setState(() => _mqttConnected = true);
  print('MQTT connected successfully!');
} else {
  setState(() => _mqttConnected = false);
  print('MQTT not connected: ${_mqttClient!.connectionStatus}');
}
} catch (e) {
  setState(() => _mqttConnected = false);
  print('MQTT error: $e');
}
}

  // ─────────────────────────────────────────────
  // Publish command to ESP8266
  // ─────────────────────────────────────────────
 void _publishCommand(String command) async {
  try {
    // Check actual state, not just our flag
    if (_mqttClient == null ||
        _mqttClient!.connectionStatus!.state != MqttConnectionState.connected) {
      print('MQTT disconnected — reconnecting...');
      setState(() => _mqttConnected = false);
      await _connectMQTT();
      // Wait a moment for connection to establish
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (_mqttClient!.connectionStatus!.state != MqttConnectionState.connected) {
      print('Still not connected — cannot publish');
      return;
    }

    final builder = MqttClientPayloadBuilder();
    builder.addString(command);
    _mqttClient!.publishMessage(
      'vocalcare/command',
      MqttQos.atMostOnce,
      builder.payload!,
    );
    print('Published successfully: $command');
  } catch (e) {
    print('Publish error: $e');
  }
}

  // ─────────────────────────────────────────────
  // Recording
  // ─────────────────────────────────────────────
  Future<void> _startRecording() async {
    if (!_recorderReady || _isRecording) return;

    final dir  = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/command.wav';

    await _recorder.startRecorder(
      toFile: path,
      codec: Codec.pcm16WAV,
      sampleRate: 16000,
      numChannels: 1,
    );

    setState(() {
      _isRecording = true;
      _statusText  = 'Listening... speak now!';
    });

    await Future.delayed(const Duration(seconds: 2));
    if (_isRecording) await _stopRecording();
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    final path = await _recorder.stopRecorder();
    setState(() {
      _isRecording      = false;
      _lastRecordedPath = path;
    });

    if (path != null) {
      final size = await File(path).length();
      if (size > 1000) {
        await _processAndPredict(path);
      } else {
        setState(() => _statusText = 'Too short, try again');
      }
    }
  }

  // ─────────────────────────────────────────────
  // Process audio → mel spec → inference → publish
  // ─────────────────────────────────────────────
  Future<void> _processAndPredict(String path) async {
    try {
      setState(() => _statusText = 'Processing...');
      final melSpec = await AudioProcessor.processAudio(path);

      setState(() => _statusText = 'Recognising...');
      final result = await _runInference(melSpec);

      setState(() {
        _predictedCommand = result ?? 'unclear';
        _statusText       = 'Say another command';
      });
    } catch (e) {
      setState(() => _statusText = 'Error: $e');
    }
  }

  // ─────────────────────────────────────────────
  // Run TFLite inference
  // ─────────────────────────────────────────────
  Future<String?> _runInference(List<List<double>> melSpec) async {
    if (_interpreter == null) return null;

    try {
      final input = List.generate(
        1, (_) => List.generate(
          64, (i) => List.generate(
            32, (j) => List.generate(1, (_) => melSpec[i][j]))));

      final output = List.generate(1, (_) => List.filled(8, 0.0));
      _interpreter!.run(input, output);

      final probs = output[0];
      double maxProb = 0.0;
      int maxIdx = 0;
      for (int i = 0; i < probs.length; i++) {
        if (probs[i] > maxProb) {
          maxProb = probs[i];
          maxIdx  = i;
        }
      }

      print('Predicted: ${_commands[maxIdx]} '
            '(${(maxProb * 100).toStringAsFixed(1)}%)');

      if (maxProb > 0.40) {
        final command = _commands[maxIdx];
        _publishCommand(command);  // send to ESP8266
        return '$command (${(maxProb * 100).toStringAsFixed(1)}%)';
      } else {
        return 'unclear (${(maxProb * 100).toStringAsFixed(1)}%)';
      }
    } catch (e) {
      print('Inference error: $e');
      return null;
    }
  }

  // ─────────────────────────────────────────────
  @override
  void dispose() {
    _recorder.closeRecorder();
    _interpreter?.close();
    _mqttClient?.disconnect();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // UI
  // ─────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [

              // Title
              const Text(
                'VocalCare',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Voice Controlled Smart Home',
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.white.withOpacity(0.6),
                ),
              ),

              const SizedBox(height: 16),

              // Status indicators row
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Model status
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: _interpreter != null
                          ? Colors.green.withOpacity(0.2)
                          : Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _interpreter != null
                            ? Colors.greenAccent
                            : Colors.redAccent,
                      ),
                    ),
                    child: Text(
                      _interpreter != null ? '● Model' : '○ Model',
                      style: TextStyle(
                        fontSize: 12,
                        color: _interpreter != null
                            ? Colors.greenAccent
                            : Colors.redAccent,
                      ),
                    ),
                  ),

                  const SizedBox(width: 10),

                  // MQTT status
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: _mqttConnected
                          ? Colors.green.withOpacity(0.2)
                          : Colors.orange.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _mqttConnected
                            ? Colors.greenAccent
                            : Colors.orange,
                      ),
                    ),
                    child: Text(
                      _mqttConnected ? '● MQTT' : '○ MQTT',
                      style: TextStyle(
                        fontSize: 12,
                        color: _mqttConnected
                            ? Colors.greenAccent
                            : Colors.orange,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 50),

              // Mic button
              GestureDetector(
                onTap: _isRecording ? null : _startRecording,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width:  _isRecording ? 120 : 100,
                  height: _isRecording ? 120 : 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isRecording
                        ? const Color(0xFFE53935)
                        : const Color(0xFF6750A4),
                    boxShadow: _isRecording
                        ? [BoxShadow(
                            color: Colors.red.withOpacity(0.5),
                            blurRadius: 20,
                            spreadRadius: 5,
                          )]
                        : [],
                  ),
                  child: Icon(
                    _isRecording ? Icons.mic : Icons.mic_none,
                    size: 48,
                    color: Colors.white,
                  ),
                ),
              ),

              const SizedBox(height: 36),

              // Status text
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.white.withOpacity(0.8),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Predicted command box
              if (_predictedCommand.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6750A4).withOpacity(0.25),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF6750A4),
                      width: 1.5,
                    ),
                  ),
                  child: Text(
                    _predictedCommand,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),

              const SizedBox(height: 30),

              // Hardware status display
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _hardwareCard('LED', Icons.lightbulb_outline,
                        _predictedCommand.startsWith('on') ||
                        _predictedCommand.startsWith('yes') ||
                        _predictedCommand.startsWith('up') ||
                        _predictedCommand.startsWith('go')),
                    _hardwareCard('Buzzer', Icons.notifications_active,
                        _predictedCommand.startsWith('stop')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Hardware status card widget
  Widget _hardwareCard(String label, IconData icon, bool isActive) {
    return Container(
      width: 110,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: isActive
            ? const Color(0xFF00B4A6).withOpacity(0.2)
            : Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? const Color(0xFF00B4A6)
              : Colors.white.withOpacity(0.15),
          width: 1.5,
        ),
      ),
      child: Column(
        children: [
          Icon(icon,
            color: isActive ? const Color(0xFF00B4A6) : Colors.white38,
            size: 28,
          ),
          const SizedBox(height: 6),
          Text(label,
            style: TextStyle(
              fontSize: 13,
              color: isActive ? const Color(0xFF00B4A6) : Colors.white38,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(isActive ? 'ON' : 'OFF',
            style: TextStyle(
              fontSize: 11,
              color: isActive ? Colors.greenAccent : Colors.white24,
            ),
          ),
        ],
      ),
    );
  }
}