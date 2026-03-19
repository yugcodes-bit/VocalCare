# Cell 4 — Load one audio file and listen to what we're working with

import librosa
import librosa.display
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path

DATASET_PATH = Path("./data/speech_commands")

# Load one sample — the word "on"
sample_path = list((DATASET_PATH / "on").glob("*.wav"))[0]
audio, sample_rate = librosa.load(sample_path, sr=16000)

print(f"File: {sample_path.name}")
print(f"Sample rate: {sample_rate} Hz")
print(f"Duration: {len(audio)/sample_rate:.2f} seconds")
print(f"Audio array shape: {audio.shape}")

# Plot the raw waveform
plt.figure(figsize=(10, 3))
librosa.display.waveshow(audio, sr=sample_rate, color='steelblue')
plt.title("Raw audio waveform — word: 'on'")
plt.xlabel("Time (seconds)")
plt.ylabel("Amplitude")
plt.tight_layout()
plt.show()




give me your honest opinions about this whole project i am going to build and thinking of scaling it up as something big as a product and pitch in big colleges events

tell me the novelty (score out of 10)of thi prject is there anything exisiting in the market? what do u thiink if this project overall , i want a deep study and research from u . your brutual honest opinions about all this.