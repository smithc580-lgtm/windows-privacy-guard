using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace LocalVoiceRecorder
{
    internal sealed class AudioFormat
    {
        internal int Rate, Channels, Bits, BlockAlign;
        internal bool Floating;
        internal static AudioFormat FromPointer(IntPtr pointer)
        {
            int tag = (ushort)Marshal.ReadInt16(pointer, 0);
            AudioFormat format = new AudioFormat {
                Channels = (ushort)Marshal.ReadInt16(pointer, 2), Rate = Marshal.ReadInt32(pointer, 4),
                BlockAlign = (ushort)Marshal.ReadInt16(pointer, 12), Bits = (ushort)Marshal.ReadInt16(pointer, 14)
            };
            if (tag == 0xfffe) {
                if ((ushort)Marshal.ReadInt16(pointer, 16) < 22) throw new NotSupportedException("Incomplete device audio format.");
                byte[] guidBytes = new byte[16]; Marshal.Copy(IntPtr.Add(pointer, 24), guidBytes, 0, 16);
                Guid subFormat = new Guid(guidBytes);
                if (subFormat == new Guid("00000001-0000-0010-8000-00aa00389b71")) tag = 1;
                else if (subFormat == new Guid("00000003-0000-0010-8000-00aa00389b71")) tag = 3;
                else throw new NotSupportedException("This microphone has an unsupported encoded audio format.");
            }
            format.Floating = tag == 3;
            if (tag != 1 && tag != 3) throw new NotSupportedException("Only PCM and floating-point microphones are supported.");
            if (format.Channels < 1 || format.Channels > 2) throw new NotSupportedException("Select a mono or stereo input in Windows Sound settings.");
            if (format.Rate < 8000 || format.Rate > 384000 || format.BlockAlign != format.Channels * (format.Bits / 8))
                throw new NotSupportedException("The microphone reported an invalid audio format.");
            if (format.Floating ? (format.Bits != 32 && format.Bits != 64) : (format.Bits != 8 && format.Bits != 16 && format.Bits != 24 && format.Bits != 32))
                throw new NotSupportedException("Unsupported input bit depth.");
            return format;
        }
        public override string ToString() { return Rate + " Hz / " + Channels + " channel" + (Channels == 1 ? "" : "s") + " / " + Bits + "-bit " + (Floating ? "float" : "PCM"); }
    }

    internal struct PacketLevels { internal double Peak, Rms; internal long Clipped; }
    internal static class AudioMath
    {
        internal static PacketLevels Convert(byte[] source, int samples, AudioFormat format, int outputBits, byte[] output, bool silent)
        {
            if (outputBits != 16 && outputBits != 24) throw new ArgumentException("Use 16-bit or 24-bit PCM.");
            double sum = 0, peak = 0; long clipped = 0;
            int bytes = format.Bits / 8, outBytes = outputBits / 8;
            double scale = outputBits == 24 ? 8388608.0 : 32768.0;
            for (int i = 0; i < samples; i++) {
                int offset = i * bytes; double value = 0;
                if (!silent) {
                    if (format.Floating) value = format.Bits == 32 ? BitConverter.ToSingle(source, offset) : BitConverter.ToDouble(source, offset);
                    else if (format.Bits == 8) value = (source[offset] - 128) / 128.0;
                    else if (format.Bits == 16) value = BitConverter.ToInt16(source, offset) / 32768.0;
                    else if (format.Bits == 24) {
                        int number = source[offset] | (source[offset + 1] << 8) | (source[offset + 2] << 16);
                        if ((number & 0x800000) != 0) number |= unchecked((int)0xff000000);
                        value = number / 8388608.0;
                    } else value = BitConverter.ToInt32(source, offset) / 2147483648.0;
                }
                if (double.IsNaN(value) || double.IsInfinity(value)) throw new InvalidDataException("The input driver returned invalid audio samples.");
                double absolute = Math.Abs(value);
                peak = Math.Max(peak, absolute); sum += value * value;
                if (absolute >= 0.999) clipped++;
                value = Math.Max(-1.0, Math.Min(1.0, value));
                int pcm = (int)Math.Max(-scale, Math.Min(scale - 1, Math.Round(value * scale, MidpointRounding.AwayFromZero)));
                int destination = i * outBytes;
                output[destination] = (byte)(pcm & 255); output[destination + 1] = (byte)((pcm >> 8) & 255);
                if (outBytes == 3) output[destination + 2] = (byte)((pcm >> 16) & 255);
            }
            return new PacketLevels { Peak = peak, Rms = samples == 0 ? 0 : Math.Sqrt(sum / samples), Clipped = clipped };
        }
        internal static double Db(double value) { return value <= 0 ? -90 : 20 * Math.Log10(value); }
    }

    internal sealed class WaveWriter : IDisposable
    {
        private readonly FileStream file;
        private readonly BinaryWriter writer;
        private readonly int rate, channels, bits;
        private long bytes, lastCheckpoint;
        internal WaveWriter(string path, int sampleRate, int channelCount, int bitDepth)
        {
            if (channelCount < 1 || channelCount > 2 || (bitDepth != 16 && bitDepth != 24) || sampleRate < 8000 || sampleRate > 384000)
                throw new ArgumentException("Unsupported output format.");
            rate = sampleRate; channels = channelCount; bits = bitDepth;
            file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            writer = new BinaryWriter(file, Encoding.ASCII);
            writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write((uint)36);
            writer.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write((uint)16);
            writer.Write((ushort)1); writer.Write((ushort)channels); writer.Write((uint)rate);
            writer.Write((uint)(rate * channels * bits / 8)); writer.Write((ushort)(channels * bits / 8)); writer.Write((ushort)bits);
            writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write((uint)0);
        }
        internal void Write(byte[] buffer, int length)
        {
            if (length % (channels * bits / 8) != 0) throw new InvalidDataException("Incomplete audio frame.");
            if (bytes + length > uint.MaxValue - 37L) throw new IOException("Reached the WAV file size limit. Start a new take.");
            writer.Write(buffer, 0, length); bytes += length;
            if (bytes - lastCheckpoint >= rate * channels * bits / 8) { Checkpoint(); lastCheckpoint = bytes; }
        }
        private void Checkpoint()
        {
            writer.Flush(); long position = file.Position;
            file.Position = 4; writer.Write((uint)(36 + bytes)); file.Position = 40; writer.Write((uint)bytes);
            writer.Flush(); file.Position = position; file.Flush();
        }
        public void Dispose()
        {
            try {
                // RIFF chunks must have even byte alignment; the data size excludes padding.
                if ((bytes & 1) != 0) writer.Write((byte)0);
                Checkpoint(); file.Position = 4; writer.Write((uint)(36 + bytes + (bytes & 1))); writer.Flush();
            } finally { writer.Dispose(); }
        }
    }

    internal sealed class CaptureSnapshot
    {
        internal double Peak, Rms, PeakHold, Seconds;
        internal long Clipped, Glitches;
        internal string Format, Error, SavedPath;
        internal bool Finished;
        internal CaptureSnapshot Copy() { return (CaptureSnapshot)MemberwiseClone(); }
    }
    internal sealed class CaptureSession : IDisposable
    {
        private readonly ManualResetEvent stop = new ManualResetEvent(false);
        private readonly object gate = new object();
        private readonly CaptureSnapshot state = new CaptureSnapshot();
        private readonly Thread thread;
        internal CaptureSnapshot Snapshot() { lock (gate) return state.Copy(); }
        internal CaptureSession(string deviceId, string destination, int bits)
        {
            thread = new Thread(delegate() { Run(deviceId, destination, bits); });
            thread.IsBackground = true; thread.Name = "Microphone capture"; thread.SetApartmentState(ApartmentState.MTA); thread.Start();
        }
        internal void Stop() { stop.Set(); }
        private void Run(string deviceId, string destination, int bits)
        {
            IMMDeviceEnumerator enumerator = null; IMMDevice device = null;
            object clientObject = null, captureObject = null; IAudioClient client = null;
            IntPtr formatPointer = IntPtr.Zero; WaveWriter writer = null; bool started = false;
            string partial = destination == null ? null : destination + "." + Guid.NewGuid().ToString("N") + ".partial";
            bool completed = false;
            try {
                enumerator = NativeAudio.Enumerator(); NativeAudio.Check(enumerator.GetDevice(deviceId, out device));
                Guid iid = NativeAudio.AudioClientId; NativeAudio.Check(device.Activate(ref iid, 23, IntPtr.Zero, out clientObject));
                client = (IAudioClient)clientObject; NativeAudio.Check(client.GetMixFormat(out formatPointer));
                AudioFormat format = AudioFormat.FromPointer(formatPointer);
                lock (gate) state.Format = format.ToString();
                Guid session = Guid.Empty;
                // Shared WASAPI at the device mix format; no resampling or effects added by this app.
                NativeAudio.Check(client.Initialize(0, 0, 1000000, 0, formatPointer, ref session));
                iid = NativeAudio.CaptureClientId; NativeAudio.Check(client.GetService(ref iid, out captureObject));
                IAudioCaptureClient capture = (IAudioCaptureClient)captureObject;
                if (destination != null) {
                    if (File.Exists(destination)) throw new IOException("That filename already exists. Choose a new take name.");
                    writer = new WaveWriter(partial, format.Rate, format.Channels, bits);
                }
                NativeAudio.Check(client.Start()); started = true;
                byte[] input = new byte[0], output = new byte[0]; long framesRead = 0; bool first = true;
                while (true) {
                    bool ending = stop.WaitOne(8);
                    if (ending) { NativeAudio.Check(client.Stop()); started = false; }
                    uint available; NativeAudio.Check(capture.GetNextPacketSize(out available));
                    while (available != 0) {
                        IntPtr data; uint frames, flags; ulong position, timestamp;
                        NativeAudio.Check(capture.GetBuffer(out data, out frames, out flags, out position, out timestamp));
                        try {
                            int inputSize = checked((int)frames * format.BlockAlign);
                            int samples = checked((int)frames * format.Channels); int outputSize = checked(samples * (bits / 8));
                            if (input.Length < inputSize) input = new byte[inputSize];
                            if (output.Length < outputSize) output = new byte[outputSize];
                            bool silent = (flags & 2) != 0;
                            if (!silent) Marshal.Copy(data, input, 0, inputSize);
                            PacketLevels levels = AudioMath.Convert(input, samples, format, bits, output, silent);
                            if (writer != null) writer.Write(output, outputSize);
                            framesRead += frames;
                            lock (gate) {
                                // Retain recent peaks long enough to be visible between UI refreshes.
                                state.Peak = Math.Max(levels.Peak, state.Peak * Math.Exp(-frames / (format.Rate * 0.35)));
                                state.Rms = levels.Rms; state.PeakHold = Math.Max(state.PeakHold, levels.Peak);
                                state.Clipped += levels.Clipped; state.Seconds = framesRead / (double)format.Rate;
                                if (!first && (flags & 1) != 0) state.Glitches++;
                            }
                            first = false;
                        } finally { NativeAudio.Check(capture.ReleaseBuffer(frames)); }
                        NativeAudio.Check(capture.GetNextPacketSize(out available));
                    }
                    if (ending) break;
                }
                completed = true;
            } catch (Exception error) { lock (gate) state.Error = error.Message; }
            finally {
                if (started && client != null) client.Stop();
                try {
                    if (writer != null) {
                        writer.Dispose(); writer = null;
                        if (completed) { File.Move(partial, destination); lock (gate) state.SavedPath = destination; }
                        else { lock (gate) state.SavedPath = partial; }
                    }
                } catch (Exception error) { lock (gate) { state.Error = (state.Error ?? "") + " Save error: " + error.Message; state.SavedPath = partial; } }
                if (formatPointer != IntPtr.Zero) Marshal.FreeCoTaskMem(formatPointer);
                NativeAudio.Release(captureObject); NativeAudio.Release(clientObject); NativeAudio.Release(device); NativeAudio.Release(enumerator);
                lock (gate) state.Finished = true;
            }
        }
        public void Dispose()
        {
            stop.Set();
            if (thread.Join(3000)) stop.Dispose();
        }
    }
}
