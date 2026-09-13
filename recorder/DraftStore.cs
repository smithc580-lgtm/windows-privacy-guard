using System;
using System.IO;

namespace LocalVoiceRecorder
{
    internal sealed class DraftStore
    {
        internal readonly string Root;
        internal DraftStore(string root) { Root = Path.GetFullPath(root); }
        internal string NewPath()
        {
            Directory.CreateDirectory(Root);
            return Path.Combine(Root, "Voice-" + DateTime.Now.ToString("yyyy-MM-dd-HHmmss") + "-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".wav");
        }
        internal string[] Existing()
        {
            return Directory.Exists(Root) ? Directory.GetFiles(Root, "*.wav", SearchOption.TopDirectoryOnly) : new string[0];
        }
        internal bool IsDraft(string path)
        {
            return string.Equals(Path.GetDirectoryName(Path.GetFullPath(path)), Root, StringComparison.OrdinalIgnoreCase);
        }
        internal bool Save(string source, string destination)
        {
            if (!IsDraft(source)) throw new InvalidOperationException("Only a recorder draft can be moved by Save take.");
            if (string.Equals(Path.GetFullPath(source), Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase))
                throw new IOException("Choose a location outside this draft's current filename.");
            // Copy without overwriting first; only remove our own draft after a
            // successful copy. A failed/cancelled save leaves the draft intact.
            File.Copy(source, destination, false);
            try { File.Delete(source); return true; }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
    }
}
