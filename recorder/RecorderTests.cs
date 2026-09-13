using System;
using System.Collections.Generic;
using System.IO;
using System.Media;
using System.Text;

namespace LocalVoiceRecorder
{
    internal static class RecorderTests
    {
        private static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); }
        private static double Decode(byte[] bytes, int offset, int bits)
        {
            if (bits == 16) return BitConverter.ToInt16(bytes, offset) / 32768.0;
            int value = bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
            if ((value & 0x800000) != 0) value |= unchecked((int)0xff000000);
            return value / 8388608.0;
        }
        internal static void Run(string reportPath)
        {
            string root = Path.Combine(Path.GetTempPath(), "WPG-AudioTests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root); List<string> report = new List<string>();
            try {
                AudioFormat floatFormat = new AudioFormat { Rate = 48000, Channels = 1, Bits = 32, BlockAlign = 4, Floating = true };
                const int frames = 48000; byte[] input = new byte[frames * 4];
                for (int i = 0; i < frames; i++) Buffer.BlockCopy(BitConverter.GetBytes((float)(0.5 * Math.Sin(2 * Math.PI * 997 * i / 48000))), 0, input, i * 4, 4);
                foreach (int bits in new int[] { 16, 24 }) {
                    byte[] converted = new byte[frames * bits / 8];
                    PacketLevels levels = AudioMath.Convert(input, frames, floatFormat, bits, converted, false);
                    double signal = 0, noise = 0, maximumError = 0;
                    for (int i = 0; i < frames; i++) {
                        double expected = BitConverter.ToSingle(input, i * 4), actual = Decode(converted, i * bits / 8, bits);
                        signal += expected * expected; noise += (actual - expected) * (actual - expected); maximumError = Math.Max(maximumError, Math.Abs(actual - expected));
                    }
                    double snr = 10 * Math.Log10(signal / noise);
                    Assert(maximumError <= (bits == 24 ? 1.0 / 8388608 : 1.0 / 32768), "Quantization error exceeds one bit.");
                    Assert(snr > (bits == 24 ? 130 : 85), "Synthetic tone has unexpected conversion noise.");
                    Assert(levels.Clipped == 0 && levels.Peak > 0.49, "Tone meter or clipping flag incorrect.");
                    string wav = Path.Combine(root, "tone-" + bits + ".wav");
                    using (WaveWriter writer = new WaveWriter(wav, 48000, 1, bits)) {
                        // Deliberately uneven packet sizes check persistence across boundaries.
                        int position = 0;
                        while (position < frames) {
                            int count = Math.Min(617, frames - position); byte[] chunk = new byte[count * bits / 8];
                            Buffer.BlockCopy(converted, position * bits / 8, chunk, 0, chunk.Length); writer.Write(chunk, chunk.Length); position += count;
                        }
                    }
                    byte[] saved = File.ReadAllBytes(wav);
                    Assert(Encoding.ASCII.GetString(saved, 0, 4) == "RIFF" && Encoding.ASCII.GetString(saved, 8, 4) == "WAVE", "Invalid WAV identifier.");
                    Assert(BitConverter.ToUInt32(saved, 24) == 48000 && BitConverter.ToUInt16(saved, 34) == bits, "Wrong WAV format.");
                    Assert(BitConverter.ToUInt32(saved, 40) == converted.Length && saved.Length == 44 + converted.Length, "Wrong duration or truncated packet data.");
                    for (int i = 0; i < converted.Length; i++) Assert(saved[i + 44] == converted[i], "Packet boundary changed an audio sample.");
                    using (SoundPlayer player = new SoundPlayer(wav)) player.Load(); // Validate loading only; do not play sound.
                    report.Add(bits + "-bit conversion, packet continuity, WAV header/data and playback loading PASS; synthetic SNR " + snr.ToString("0.0") + " dB");
                }
                byte[] extremes = new byte[16]; float[] samples = { -1, 0, 1, 1.5f };
                for (int i = 0; i < samples.Length; i++) Buffer.BlockCopy(BitConverter.GetBytes(samples[i]), 0, extremes, i * 4, 4);
                byte[] output = new byte[12]; PacketLevels clipped = AudioMath.Convert(extremes, 4, floatFormat, 24, output, false);
                Assert(clipped.Clipped == 3 && Decode(output, 0, 24) == -1 && Decode(output, 9, 24) < 1 && Decode(output, 9, 24) > 0.99, "Clipping wrapped instead of saturating.");
                AudioMath.Convert(extremes, 4, floatFormat, 24, output, true);
                foreach (byte value in output) Assert(value == 0, "Silent packet leaked stale audio.");
                report.Add("Clipping saturation, near-clipping detection and silent packet handling PASS");
                foreach (int bits in new int[] { 8, 16, 24, 32 }) {
                    byte[] pcm = new byte[bits / 8]; if (bits != 8) pcm[pcm.Length - 1] = 128;
                    AudioFormat format = new AudioFormat { Rate = 48000, Channels = 1, Bits = bits, BlockAlign = bits / 8, Floating = false };
                    byte[] result = new byte[3]; AudioMath.Convert(pcm, 1, format, 24, result, false);
                    Assert(Decode(result, 0, 24) == -1, "Incorrect PCM sign extension: " + bits);
                }
                byte[] stereo = new byte[8]; Buffer.BlockCopy(BitConverter.GetBytes(0.25f), 0, stereo, 0, 4); Buffer.BlockCopy(BitConverter.GetBytes(-0.75f), 0, stereo, 4, 4);
                byte[] stereoOut = new byte[6]; AudioMath.Convert(stereo, 2, floatFormat, 24, stereoOut, false);
                Assert(Decode(stereoOut, 0, 24) == 0.25 && Decode(stereoOut, 3, 24) == -0.75, "Channel order changed.");
                string odd = Path.Combine(root, "odd.wav"); using (WaveWriter writer = new WaveWriter(odd, 48000, 1, 24)) writer.Write(new byte[3], 3);
                byte[] oddFile = File.ReadAllBytes(odd);
                Assert(oddFile.Length == 48 && BitConverter.ToUInt32(oddFile, 4) == 40 && BitConverter.ToUInt32(oddFile, 40) == 3, "RIFF padding incorrect.");
                bool refused = false; try { using (WaveWriter writer = new WaveWriter(odd, 48000, 1, 24)) { } } catch (IOException) { refused = true; }
                Assert(refused && File.ReadAllBytes(odd).Length == 48, "Existing recording was overwritten.");
                report.Add("PCM sign extension, channel order, odd-length RIFF padding and overwrite refusal PASS");
                DraftStore drafts = new DraftStore(root);
                string draft = drafts.NewPath(); File.WriteAllBytes(draft, oddFile);
                DraftStore reopened = new DraftStore(root);
                Assert(Array.IndexOf(reopened.Existing(), draft) >= 0, "An unsaved draft was not found on reopen.");
                bool saveRefused = false;
                try { reopened.Save(draft, odd); } catch (IOException) { saveRefused = true; }
                Assert(saveRefused && File.Exists(draft) && File.ReadAllBytes(odd).Length == oddFile.Length, "Failed save lost a take.");
                string savedDraft = Path.Combine(root, "saved-draft.wav");
                Assert(reopened.Save(draft, savedDraft) && !File.Exists(draft), "Successful save did not move the draft.");
                byte[] savedDraftBytes = File.ReadAllBytes(savedDraft);
                Assert(savedDraftBytes.Length == oddFile.Length, "Draft save truncated audio.");
                for (int i = 0; i < oddFile.Length; i++) Assert(savedDraftBytes[i] == oddFile[i], "Draft save changed audio.");
                report.Add("Draft rediscovery, failed-save preservation, overwrite refusal and successful save integrity PASS");
                using (RecorderForm form = new RecorderForm()) { form.CreateControl(); form.PerformLayout(); }
                report.Add("Recorder UI construction PASS; microphone not opened; no sound played");
                File.WriteAllLines(reportPath, report.ToArray());
            } finally {
                // All files are synthetic fixtures in this invocation's unique directory.
                foreach (string file in Directory.GetFiles(root)) File.Delete(file);
                Directory.Delete(root);
            }
        }
    }
}
