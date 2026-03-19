import 'dart:io';
import 'dart:math';
import 'package:wav/wav.dart';

class AudioProcessor {
  static const int sampleRate = 16000;
  static const int nMels = 64;
  static const int nFft = 1024;
  static const int hopLength = 512;
  static const int targetLength = 16000;

  // Main method — takes WAV file path, returns mel spectrogram
  static Future<List<List<double>>> processAudio(String filePath) async {
    // Step 1 — Read WAV file
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final wav = Wav.read(bytes);

    // Step 2 — Get audio samples as doubles
    List<double> samples = wav.channels[0].toList();
    print('WAV samples loaded: ${samples.length}');

    // Step 3 — Pad or trim to exactly 1 second
    samples = _fixLength(samples, targetLength);
    print('After fix length: ${samples.length}');

    // Step 4 — Compute mel spectrogram
    final melSpec = _melSpectrogram(samples);
    print('Mel spec shape: ${melSpec.length} x ${melSpec[0].length}');

    // Step 5 — Normalize to 0-1 range
    final normalized = _normalize(melSpec);

    // Step 6 — Fix time axis to exactly 32 columns
    final fixed = _fixTimeAxis(normalized, 32);
    print('After fix time axis: ${fixed.length} x ${fixed[0].length}');

    return fixed;
  }

  // Pad or trim samples to exact length
  static List<double> _fixLength(List<double> samples, int length) {
    if (samples.length >= length) {
      return samples.sublist(0, length);
    }
    final padded = List<double>.filled(length, 0.0);
    for (int i = 0; i < samples.length; i++) {
      padded[i] = samples[i];
    }
    return padded;
  }

  // Pad or trim time axis to exact columns
  static List<List<double>> _fixTimeAxis(
      List<List<double>> spec, int targetCols) {
    return spec.map((row) {
      if (row.length >= targetCols) {
        return row.sublist(0, targetCols);
      }
      final padded = List<double>.filled(targetCols, 0.0);
      for (int i = 0; i < row.length; i++) {
        padded[i] = row[i];
      }
      return padded;
    }).toList();
  }

  // Compute mel spectrogram
  static List<List<double>> _melSpectrogram(List<double> samples) {
    final frames = _stft(samples);

    final powerSpec = frames
        .map((frame) =>
            frame.map((c) => c[0] * c[0] + c[1] * c[1]).toList())
        .toList();

    final melFilters = _melFilterbank(nMels, nFft, sampleRate);
    final melSpec = <List<double>>[];

    for (int m = 0; m < nMels; m++) {
      final melRow = <double>[];
      for (int t = 0; t < powerSpec.length; t++) {
        double val = 0.0;
        for (int f = 0; f < melFilters[m].length; f++) {
          val += melFilters[m][f] * powerSpec[t][f];
        }
        melRow.add(val > 1e-10 ? 10.0 * log(val) / ln10 : -100.0);
      }
      melSpec.add(melRow);
    }

    return melSpec;
  }

  // Short Time Fourier Transform
  static List<List<List<double>>> _stft(List<double> samples) {
    final frames = <List<List<double>>>[];
    final window = _hannWindow(nFft);

    for (int start = 0; start + nFft <= samples.length; start += hopLength) {
      final frame = List<double>.generate(
          nFft, (i) => samples[start + i] * window[i]);
      frames.add(_fft(frame));
    }
    return frames;
  }

  // Hann window
  static List<double> _hannWindow(int size) {
    return List<double>.generate(
        size, (i) => 0.5 * (1 - cos(2 * pi * i / (size - 1))));
  }

  // FFT implementation
  static List<List<double>> _fft(List<double> input) {
    final n = input.length;
    final real = List<double>.from(input);
    final imag = List<double>.filled(n, 0.0);

    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      while (j >= bit) {
        j -= bit;
        bit >>= 1;
      }
      j += bit;
      if (i < j) {
        final tmpR = real[i];
        real[i] = real[j];
        real[j] = tmpR;
        final tmpI = imag[i];
        imag[i] = imag[j];
        imag[j] = tmpI;
      }
    }

    for (int len = 2; len <= n; len <<= 1) {
      final ang = -2 * pi / len;
      final wReal = cos(ang);
      final wImag = sin(ang);
      for (int i = 0; i < n; i += len) {
        double curReal = 1.0, curImag = 0.0;
        for (int k = 0; k < len ~/ 2; k++) {
          final uR = real[i + k];
          final uI = imag[i + k];
          final vR = real[i + k + len ~/ 2] * curReal -
              imag[i + k + len ~/ 2] * curImag;
          final vI = real[i + k + len ~/ 2] * curImag +
              imag[i + k + len ~/ 2] * curReal;
          real[i + k] = uR + vR;
          imag[i + k] = uI + vI;
          real[i + k + len ~/ 2] = uR - vR;
          imag[i + k + len ~/ 2] = uI - vI;
          final newCurReal = curReal * wReal - curImag * wImag;
          curImag = curReal * wImag + curImag * wReal;
          curReal = newCurReal;
        }
      }
    }

    return List.generate(n ~/ 2 + 1, (i) => [real[i], imag[i]]);
  }

  // Mel filterbank
  static List<List<double>> _melFilterbank(int nMels, int nFft, int sr) {
    double hzToMel(double hz) => 2595 * log(1 + hz / 700) / ln10;
    double melToHz(double mel) => 700 * (pow(10, mel / 2595) - 1);

    final melMin = hzToMel(0);
    final melMax = hzToMel(sr / 2.0);
    final melPoints = List<double>.generate(
        nMels + 2,
        (i) => melMin + i * (melMax - melMin) / (nMels + 1));
    final hzPoints = melPoints.map(melToHz).toList();
    final binPoints = hzPoints
        .map((hz) => (hz * (nFft / 2 + 1) / (sr / 2)).floor())
        .toList();

    return List.generate(nMels, (m) {
      final filter = List<double>.filled(nFft ~/ 2 + 1, 0.0);
      for (int k = binPoints[m]; k < binPoints[m + 1]; k++) {
        if (k < filter.length) {
          filter[k] = (k - binPoints[m]) /
              (binPoints[m + 1] - binPoints[m]).toDouble();
        }
      }
      for (int k = binPoints[m + 1]; k < binPoints[m + 2]; k++) {
        if (k < filter.length) {
          filter[k] = (binPoints[m + 2] - k) /
              (binPoints[m + 2] - binPoints[m + 1]).toDouble();
        }
      }
      return filter;
    });
  }

  // Normalize to 0-1 range
  static List<List<double>> _normalize(List<List<double>> spec) {
    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;

    for (final row in spec) {
      for (final val in row) {
        if (val < minVal) minVal = val;
        if (val > maxVal) maxVal = val;
      }
    }

    final range = maxVal - minVal;
    return spec
        .map((row) => row
            .map((val) => range > 0 ? (val - minVal) / range : 0.0)
            .toList())
        .toList();
  }
}