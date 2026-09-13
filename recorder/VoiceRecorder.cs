using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Media;
using System.Windows.Forms;

namespace LocalVoiceRecorder
{
    internal sealed class LevelMeter : Control
    {
        internal double Level;
        internal string Caption;
        internal LevelMeter(string caption) { Caption = caption; DoubleBuffered = true; Height = 42; Dock = DockStyle.Fill; }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            double db = AudioMath.Db(Level);
            int width = Math.Max(1, Width - 190), left = 82;
            e.Graphics.DrawString(Caption, Font, Brushes.Gainsboro, 0, 7);
            using (Brush background = new SolidBrush(Color.FromArgb(42, 51, 64))) e.Graphics.FillRectangle(background, left, 8, width, 18);
            int fill = (int)(width * Math.Max(0, Math.Min(1, (db + 60) / 60)));
            Color color = db >= -1 ? Color.FromArgb(250, 108, 102) : db >= -6 ? Color.FromArgb(244, 194, 92) : Color.FromArgb(102, 215, 180);
            using (Brush brush = new SolidBrush(color)) e.Graphics.FillRectangle(brush, left, 8, fill, 18);
            e.Graphics.DrawString(db < -60 ? "< -60 dBFS" : db.ToString("0.0") + " dBFS", Font, Brushes.Gainsboro, left + width + 10, 7);
        }
    }
    internal sealed class SavedTake
    {
        internal string Path;
        internal bool IsDraft;
        public override string ToString() { return (IsDraft ? "[Draft] " : "") + System.IO.Path.GetFileName(Path); }
    }
    internal sealed class RecorderForm : Form
    {
        private readonly ComboBox devices = new ComboBox(), depth = new ComboBox();
        private readonly Button refresh, monitor, record, stop, play, stopPlayback, open, folder, sound, save;
        private readonly Label format = new Label(), status = new Label(), clock = new Label();
        private readonly LevelMeter peak = new LevelMeter("Peak"), average = new LevelMeter("Average");
        private readonly ListBox takes = new ListBox();
        private readonly Timer timer = new Timer();
        private CaptureSession capture;
        private SoundPlayer player;
        private bool recording, closeWhenFinished, recordAfterMonitor;
        private readonly DraftStore drafts = new DraftStore(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LocalVoiceRecorder", "Drafts"));
        private readonly Color background = Color.FromArgb(18, 24, 32);

        internal RecorderForm()
        {
            Text = "Local Voice Recorder"; ClientSize = new Size(830, 680); MinimumSize = new Size(830, 680);
            StartPosition = FormStartPosition.CenterScreen; AutoScaleMode = AutoScaleMode.Dpi;
            BackColor = background; ForeColor = Color.Gainsboro; Font = new Font("Segoe UI", 10);
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24), ColumnCount = 1, RowCount = 11 };
            int[] heights = { 44, 30, 48, 52, 44, 42, 42, 62, 62, 0, 50 };
            foreach (int height in heights) layout.RowStyles.Add(height == 0 ? new RowStyle(SizeType.Percent, 100) : new RowStyle(SizeType.Absolute, height));
            layout.Controls.Add(new Label { Text = "Local Voice Recorder", Font = new Font("Segoe UI", 23, FontStyle.Bold), AutoSize = true }, 0, 0);
            layout.Controls.Add(new Label { Text = "Uncompressed WAV. No uploads. No effects added by this app.", AutoSize = true, ForeColor = Color.Silver }, 0, 1);
            TableLayoutPanel options = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, Margin = new Padding(0) };
            options.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); options.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 132)); options.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 165));
            devices.DropDownStyle = ComboBoxStyle.DropDownList; devices.Dock = DockStyle.Fill; devices.Margin = new Padding(0, 8, 10, 0); devices.AccessibleName = "Microphone";
            refresh = MakeButton("Refresh inputs"); refresh.Dock = DockStyle.Fill; refresh.Margin = new Padding(0, 0, 10, 0);
            depth.DropDownStyle = ComboBoxStyle.DropDownList; depth.Dock = DockStyle.Fill; depth.Margin = new Padding(0, 8, 0, 0);
            depth.Items.AddRange(new object[] { "24-bit WAV", "16-bit WAV" }); depth.SelectedIndex = 0; depth.AccessibleName = "WAV bit depth";
            options.Controls.Add(devices, 0, 0); options.Controls.Add(refresh, 1, 0); options.Controls.Add(depth, 2, 0); layout.Controls.Add(options, 0, 2);
            format.Dock = DockStyle.Fill; format.Text = "Select a microphone to see its native capture format."; format.ForeColor = Color.Silver; layout.Controls.Add(format, 0, 3);
            clock.Dock = DockStyle.Fill; clock.Text = "00:00:00  |  Microphone off"; clock.Font = new Font("Segoe UI", 17, FontStyle.Regular); layout.Controls.Add(clock, 0, 4);
            layout.Controls.Add(peak, 0, 5); layout.Controls.Add(average, 0, 6);
            FlowLayoutPanel controls = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0) };
            monitor = MakeButton("Check levels", 150); record = MakeButton("Record", 150); stop = MakeButton("Stop", 150); sound = MakeButton("Sound settings", 160);
            stop.Enabled = false; record.BackColor = Color.FromArgb(45, 103, 87);
            controls.Controls.AddRange(new Control[] { monitor, record, stop, sound }); layout.Controls.Add(controls, 0, 7);
            status.Dock = DockStyle.Fill; status.Text = "Record starts immediately. Stop finishes the take, then asks where to save it.\r\nCancel saving to keep a draft. Red levels mean the microphone gain may be too high."; layout.Controls.Add(status, 0, 8);
            takes.Dock = DockStyle.Fill; takes.BackColor = Color.FromArgb(27, 35, 46); takes.ForeColor = Color.Gainsboro; takes.BorderStyle = BorderStyle.FixedSingle; takes.AccessibleName = "Saved recordings"; layout.Controls.Add(takes, 0, 9);
            FlowLayoutPanel playback = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0) };
            play = MakeButton("Play take", 115); stopPlayback = MakeButton("Stop playback", 140); open = MakeButton("Open WAV...", 135); folder = MakeButton("Show file", 110); save = MakeButton("Save take...", 125);
            playback.Controls.AddRange(new Control[] { play, stopPlayback, save, open, folder }); layout.Controls.Add(playback, 0, 10);
            Controls.Add(layout);
            refresh.Click += delegate { RefreshDevices(); }; devices.SelectedIndexChanged += delegate { DescribeDevice(); };
            monitor.Click += delegate { BeginCapture(null); };
            record.Click += delegate {
                if (capture != null && !recording) { recordAfterMonitor = true; capture.Stop(); record.Enabled = false; return; }
                StartRecording();
            };
            stop.Click += delegate { if (capture != null) { capture.Stop(); stop.Enabled = false; status.Text = "Stopping capture and finishing the file..."; } };
            sound.Click += delegate { try { Process.Start("ms-settings:sound"); } catch (Exception error) { ShowError(error); } };
            play.Click += delegate { PlaySelected(); }; takes.DoubleClick += delegate { if (play.Enabled) PlaySelected(); };
            stopPlayback.Click += delegate { StopPlayback(); };
            save.Enabled = false;
            save.Click += delegate { SaveSelectedDraft(); };
            takes.SelectedIndexChanged += delegate { save.Enabled = capture == null && takes.SelectedItem is SavedTake && ((SavedTake)takes.SelectedItem).IsDraft; };
            open.Click += delegate {
                using (OpenFileDialog dialog = new OpenFileDialog()) {
                    dialog.Filter = "WAV recordings (*.wav)|*.wav";
                    if (dialog.ShowDialog(this) == DialogResult.OK) AddTake(dialog.FileName);
                }
            };
            folder.Click += delegate {
                SavedTake take = takes.SelectedItem as SavedTake;
                if (take != null) { try { Process.Start("explorer.exe", "/select,\"" + take.Path + "\""); } catch (Exception error) { ShowError(error); } }
            };
            timer.Interval = 60; timer.Tick += delegate { UpdateCapture(); }; timer.Start();
            Shown += delegate {
                RefreshDevices();
                try { foreach (string path in drafts.Existing()) AddTake(path, true); }
                catch (Exception error) { ShowError(error); }
            };
            FormClosing += delegate(object sender, FormClosingEventArgs e) {
                if (capture != null) { closeWhenFinished = true; capture.Stop(); e.Cancel = true; status.Text = "Finishing your take before closing..."; }
            };
        }
        private Button MakeButton(string text, int width = 120)
        {
            return new Button { Text = text, Width = width, Height = 40, FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(35, 45, 59), ForeColor = Color.White, Margin = new Padding(0, 6, 10, 0) };
        }
        private void RefreshDevices()
        {
            if (capture != null) return;
            try {
                string previous = devices.SelectedItem is InputDevice ? ((InputDevice)devices.SelectedItem).Id : null;
                List<InputDevice> inputs = NativeAudio.Devices(); devices.Items.Clear(); int selected = 0;
                for (int i = 0; i < inputs.Count; i++) { devices.Items.Add(inputs[i]); if (inputs[i].Id == previous || (previous == null && inputs[i].IsDefault)) selected = i; }
                if (devices.Items.Count > 0) devices.SelectedIndex = selected;
                else { format.Text = "No active microphone found. Connect one and click Refresh inputs."; record.Enabled = monitor.Enabled = false; }
            } catch (Exception error) { record.Enabled = monitor.Enabled = false; ShowError(error); }
        }
        private void DescribeDevice()
        {
            if (capture != null || !(devices.SelectedItem is InputDevice)) return;
            try {
                AudioFormat info = NativeAudio.Describe(((InputDevice)devices.SelectedItem).Id);
                format.Text = info + ". Output keeps this sample rate and channel count.\r\n" +
                    (info.Rate < 44100 ? "Low-bandwidth input: choose a higher-quality microphone or format in Sound settings." : "Windows or device enhancements may still apply; this app adds no processing.");
                record.Enabled = monitor.Enabled = true;
            } catch (Exception error) { format.Text = error.Message; record.Enabled = monitor.Enabled = false; }
        }
        private void BeginCapture(string destination)
        {
            InputDevice input = devices.SelectedItem as InputDevice;
            if (capture != null || input == null) return;
            StopPlayback(); recording = destination != null;
            capture = new CaptureSession(input.Id, destination, depth.SelectedIndex == 0 ? 24 : 16);
            devices.Enabled = depth.Enabled = refresh.Enabled = monitor.Enabled = play.Enabled = open.Enabled = save.Enabled = false;
            record.Enabled = !recording;
            stop.Enabled = true; stop.Text = recording ? "Stop" : "Stop levels";
            status.Text = recording ? "Recording. Click Stop when finished; you'll choose a filename afterward." : "Microphone active for level checking only. Click Record to start a take, or Stop levels to finish.";
            status.ForeColor = Color.Gainsboro;
        }
        private void UpdateCapture()
        {
            if (capture == null) return;
            CaptureSnapshot snapshot = capture.Snapshot();
            peak.Level = snapshot.Peak; average.Level = snapshot.Rms; peak.Invalidate(); average.Invalidate();
            clock.Text = TimeSpan.FromSeconds(snapshot.Seconds).ToString(@"hh\:mm\:ss") + (recording ? "  |  Recording" : "  |  Checking levels");
            if (snapshot.Glitches > 0 || snapshot.Clipped > 0) {
                status.ForeColor = Color.FromArgb(255, 180, 120);
                status.Text = snapshot.Glitches > 0 ? "Input discontinuities detected: " + snapshot.Glitches + ". Check the cable, device, and system load; this take may contain gaps." : "Near-clipping detected. Lower the microphone gain or move farther away. Peak: " + AudioMath.Db(snapshot.PeakHold).ToString("0.0") + " dBFS.";
            }
            if (!snapshot.Finished) return;
            capture.Dispose(); capture = null;
            devices.Enabled = depth.Enabled = refresh.Enabled = monitor.Enabled = record.Enabled = play.Enabled = open.Enabled = true;
            stop.Enabled = false; clock.Text = TimeSpan.FromSeconds(snapshot.Seconds).ToString(@"hh\:mm\:ss") + "  |  Microphone off";
            if (snapshot.Error != null) {
                status.ForeColor = Color.Salmon;
                status.Text = snapshot.Error + (snapshot.SavedPath == null ? "" : "\r\nPartial take retained: " + snapshot.SavedPath);
            } else if (snapshot.SavedPath != null) {
                AddTake(snapshot.SavedPath, true);
                status.Text = "Draft kept: " + snapshot.SavedPath + "\r\nPeak " + AudioMath.Db(snapshot.PeakHold).ToString("0.0") + " dBFS; near-clipping samples: " + snapshot.Clipped + "; input discontinuities: " + snapshot.Glitches + ".";
                if (!closeWhenFinished) SaveSelectedDraft();
            } else status.Text = "Level check finished. Choose Record to save a take.";
            save.Enabled = takes.SelectedItem is SavedTake && ((SavedTake)takes.SelectedItem).IsDraft;
            if (recordAfterMonitor && !closeWhenFinished) { recordAfterMonitor = false; StartRecording(); return; }
            if (closeWhenFinished) Close();
        }
        private void StartRecording()
        {
            if (capture != null || !(devices.SelectedItem is InputDevice)) return;
            try { BeginCapture(drafts.NewPath()); } catch (Exception error) { ShowError(error); }
        }
        private void AddTake(string path, bool isDraft = false) { takes.Items.Add(new SavedTake { Path = path, IsDraft = isDraft || drafts.IsDraft(path) }); takes.SelectedIndex = takes.Items.Count - 1; }
        private void SaveSelectedDraft()
        {
            SavedTake take = takes.SelectedItem as SavedTake;
            if (capture != null || take == null || !take.IsDraft) return;
            StopPlayback();
            using (SaveFileDialog dialog = new SaveFileDialog()) {
                dialog.Filter = "Uncompressed WAV (*.wav)|*.wav"; dialog.DefaultExt = "wav"; dialog.AddExtension = true;
                dialog.Title = "Save your finished recording"; dialog.FileName = System.IO.Path.GetFileName(take.Path);
                dialog.InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
                if (dialog.ShowDialog(this) != DialogResult.OK) { status.Text = "Your recording is kept as a draft. Play it now or use Save take later.\r\n" + take.Path; return; }
                try {
                    bool removedDraft = drafts.Save(take.Path, dialog.FileName);
                    take.Path = dialog.FileName; take.IsDraft = false;
                    int selected = takes.SelectedIndex; takes.Items[selected] = take; takes.SelectedIndex = selected; save.Enabled = false;
                    status.Text = "Saved: " + take.Path + (removedDraft ? "" : "\r\nThe original draft was also retained.");
                } catch (Exception error) { status.Text = "Save failed; your draft is still kept. " + error.Message; status.ForeColor = Color.Salmon; }
            }
        }
        private void PlaySelected()
        {
            SavedTake take = takes.SelectedItem as SavedTake; if (take == null || capture != null) return;
            try { StopPlayback(); player = new SoundPlayer(take.Path); player.Load(); player.Play(); }
            catch (Exception error) { ShowError(error); }
        }
        private void StopPlayback() { if (player != null) { player.Stop(); player.Dispose(); player = null; } }
        private void ShowError(Exception error) { status.Text = error.Message; status.ForeColor = Color.Salmon; }
        protected override void Dispose(bool disposing)
        {
            if (disposing) { timer.Dispose(); StopPlayback(); if (capture != null) capture.Dispose(); }
            base.Dispose(disposing);
        }
    }
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            try {
                Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                if (args.Length == 2 && args[0] == "--self-test") { RecorderTests.Run(args[1]); return 0; }
                if (args.Length == 2 && args[0] == "--devices") {
                    List<string> lines = new List<string>();
                    foreach (InputDevice device in NativeAudio.Devices()) {
                        try { lines.Add(device + " | " + NativeAudio.Describe(device.Id)); }
                        catch (Exception error) { lines.Add(device + " | " + error.Message); }
                    }
                    File.WriteAllLines(args[1], lines.ToArray()); return 0;
                }
                if (args.Length == 2 && args[0] == "--preview") {
                    using (RecorderForm form = new RecorderForm()) {
                        form.StartPosition = FormStartPosition.Manual; form.Location = new Point(-30000, -30000); form.ShowInTaskbar = false;
                        form.Show(); Application.DoEvents(); form.PerformLayout();
                        using (Bitmap bitmap = new Bitmap(form.Width, form.Height)) { form.DrawToBitmap(bitmap, new Rectangle(0, 0, bitmap.Width, bitmap.Height)); bitmap.Save(args[1]); }
                    }
                    return 0;
                }
                if (args.Length != 0) return 2;
                Application.Run(new RecorderForm()); return 0;
            } catch (Exception error) {
                if (args.Length == 2) File.WriteAllText(args[1], "FAIL: " + error);
                else MessageBox.Show(error.Message, "Local Voice Recorder");
                return 1;
            }
        }
    }
}
