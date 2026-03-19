import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:tflite_flutter/tflite_flutter.dart';
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
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  bool _isRecording = false;
  bool _recorderReady = false;
  String _statusText = 'Tap mic and speak a command';
  String? _lastRecordedPath;
  Interpreter? _interpreter;
  String _predictedCommand = '';

  @override
 @override
void initState() {
  super.initState();
  _initRecorder();
  // Load model after first frame so context is ready
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _loadModel();
  });
}

  Future<void> _initRecorder() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      setState(() => _statusText = 'Microphone permission denied!');
      return;
    }
    await _recorder.openRecorder();
    setState(() {
      _recorderReady = true;
     
    });
  }

  Future<void> _loadModel() async {
  try {
    // Step 1 — read raw bytes from asset bundle
    final byteData = await DefaultAssetBundle.of(context)
        .load('assets/vocalcare_model.tflite');
    print('Bytes from bundle: ${byteData.lengthInBytes}');

    // Step 2 — write to device storage (uncompressed)
    final dir = await getApplicationDocumentsDirectory();
    final modelFile = File('${dir.path}/vocalcare_model.tflite');
    
    final bytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    await modelFile.writeAsBytes(bytes, flush: true);
    print('Written to disk: ${await modelFile.length()} bytes');

    // Step 3 — load from file path instead of asset
    _interpreter = await Interpreter.fromFile(modelFile);
    
    setState(() => _statusText = 'Model ready — tap mic to speak');
    print('Model loaded successfully!');
    print('Input : ${_interpreter!.getInputTensor(0).shape}');
    print('Output: ${_interpreter!.getOutputTensor(0).shape}');

  } catch (e) {
    print('Error: $e');
    setState(() => _statusText = 'Failed: $e');
  }
}

  Future<void> _startRecording() async {
    if (!_recorderReady || _isRecording) return;

    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/command.wav';

    await _recorder.startRecorder(
      toFile: path,
      codec: Codec.pcm16WAV,
      sampleRate: 16000,
      numChannels: 1,
    );

    setState(() {
      _isRecording = true;
      _statusText = 'Listening... speak now!';
    });

    // Auto stop after 2 seconds
    await Future.delayed(const Duration(seconds: 2));
    if (_isRecording) {
      await _stopRecording();
    }
  }
  

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    final path = await _recorder.stopRecorder();

    setState(() {
      _isRecording = false;
      _lastRecordedPath = path;
    });

    if (path != null) {
      final file = File(path);
      final size = await file.length();
      setState(() {
        _statusText = size > 1000
            ? 'Got it! Recorded $size bytes'
            : 'Too short, try again';
           
      });

      await _testProcessing(path);
    }
  
  }
  Future<void> _testProcessing(String path) async {
  try {
    setState(() => _statusText = 'Processing audio...');
    
    final melSpec = await AudioProcessor.processAudio(path);
    setState(() => _statusText = 'Running model...');
    
    final result = await _runInference(melSpec);
    
    setState(() {
      _predictedCommand = result ?? 'no result';
      _statusText = 'Done! Say another command';
    });

  } catch (e) {
    setState(() => _statusText = 'Error: $e');
    print('Error: $e');
  }
}
final List<String> _commands = [
  'on', 'off', 'yes', 'no', 'stop', 'go', 'up', 'down'
];

Future<String?> _runInference(List<List<double>> melSpec) async {
  if (_interpreter == null) return null;

  try {
    // Reshape mel spec to [1, 64, 32, 1] — what model expects
    final input = List.generate(1, (_) =>
      List.generate(64, (i) =>
        List.generate(32, (j) =>
          List.generate(1, (_) => melSpec[i][j])
        )
      )
    );

    // Output buffer — 8 probabilities
    final output = List.generate(1, (_) => List.filled(8, 0.0));

    // Run the model
    _interpreter!.run(input, output);

    // Find highest probability
    final probs = output[0];
    double maxProb = 0.0;
    int maxIdx = 0;

    for (int i = 0; i < probs.length; i++) {
      if (probs[i] > maxProb) {
        maxProb = probs[i];
        maxIdx = i;
      }
    }

    print('Probabilities: $probs');
    print('Predicted: ${_commands[maxIdx]} (${(maxProb * 100).toStringAsFixed(1)}%)');

    // Only return if confidence is above 40%
    if (maxProb > 0.40) {
      return '${_commands[maxIdx]} (${(maxProb * 100).toStringAsFixed(1)}%)';
    } else {
      return 'unclear (${(maxProb * 100).toStringAsFixed(1)}%)';
    }

  } catch (e) {
    print('Inference error: $e');
    return null;
  }
}

  @override
  void dispose() {
    _recorder.closeRecorder();
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'VocalCare',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Voice Controlled Smart Home',
              style: TextStyle(
                fontSize: 16,
                color: Colors.white.withOpacity(0.6),
              ),
            ),

            const SizedBox(height: 60),

            // Mic button
            GestureDetector(
              onTap: _isRecording ? null : _startRecording,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _isRecording ? 120 : 100,
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

            const SizedBox(height: 40),

            // Status text
            // Model status — always visible
Text(
  _interpreter != null ? 'Model: loaded' : 'Model: NOT loaded',
  style: TextStyle(
    fontSize: 13,
    color: _interpreter != null ? Colors.greenAccent : Colors.redAccent,
  ),
),

const SizedBox(height: 8),

// Recording status
Padding(
  padding: const EdgeInsets.symmetric(horizontal: 32),
  child: Text(
    _statusText,
    textAlign: TextAlign.center,
    style: TextStyle(
      fontSize: 16,
      color: Colors.white.withOpacity(0.8),
    ),
  ),
),
            const SizedBox(height: 20),

            // Predicted command display
            if (_predictedCommand.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24, vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF6750A4).withOpacity(0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF6750A4),
                    width: 1,
                  ),
                ),
                child: Text(
                  _predictedCommand,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}