# Local Voice Recorder

Double-click `VoiceRecorder.cmd` in the project root. It builds and opens a
standalone Windows desktop recorder; no administrator rights or downloads are
needed. Built versions are kept under `recorder/bin/`; use `VoiceRecorder.cmd`
to open the current version without interrupting an already-running older one.

Choose your microphone. **Record** starts recording immediately; **Stop**
finishes the take and then asks where to save the WAV. Cancelling that dialog
keeps a playable draft; choose **Save take...** later. Drafts reappear when you
reopen the app. **Check levels** lets you check the microphone without saving;
you can click **Record** directly from that mode. **Play take** plays the
selected recording. **Open WAV...** loads an earlier take.
There is no five-second cap. The ordinary RIFF WAV size limit is just
under 4 GB per take; start another take for longer sessions.

## Capture and quality

- Uses Windows WASAPI shared capture, not the disposable test's legacy MCI
  recording method. Input is captured at the device's Windows mix format.
- Saves uncompressed 24-bit PCM WAV by default, with 16-bit available for
  compatibility. Sample rate and channel order/count are preserved. Native
  float/integer samples are converted to the selected PCM container depth.
- Live peak and RMS meters, held peak, near-clipping count, and driver-reported
  buffer discontinuity warnings. Check levels only starts when you click it.
- No app-applied gain, resampling, denoising, compression, normalization, or
  networking. Windows/driver enhancements and hardware noise can still affect
  the input. Saving more bits cannot recreate quality missing from a microphone.
- Supports active mono/stereo PCM or float endpoints. For a multichannel
  interface, configure a mono/stereo capture endpoint in Windows first.

For the first comparison, record a short spoken sentence, stop, and play it
back. If it is still scratchy, note any near-clipping or discontinuity warning
and the selected device/format before changing settings. **Sound settings**
opens Windows' controls; the app never changes microphone gain automatically.

## Keeping takes

You choose each file location. Saved WAV files are never auto-deleted or
overwritten. This app has no upload code; another application's folder sync can
still act on a file saved into a synced folder.

Recording starts in `%LOCALAPPDATA%\LocalVoiceRecorder\Drafts`, without asking
for a name first. During capture, audio is streamed to a unique `.partial`
file there. The header is checkpointed roughly each second and finalized on
normal stop. Finished drafts become `.wav`. Save copies the completed draft
to your chosen filename without overwriting; only after a successful copy is
the app's draft removed. A failed save leaves the draft intact.

Capture errors retain partial files for recovery. After a crash, retain the
partial file and ask for recovery rather than deleting it. Normal window
closing finishes the take as a draft before exiting, without forcing a save
dialog. Finished drafts are listed again at the next launch.

## Validation

Run `tests/Test-VoiceRecorder.ps1` for compilation, synthetic signal conversion,
WAV header/data/packet continuity, clipping/silence, playback loading, overwrite
protection, UI construction, and device enumeration checks. These checks do not
start microphone capture or play sound. Synthetic signal-to-noise measurements
measure conversion math, not the real microphone's noise floor.

The previous disposable recorder's physical microphone/firewall test passed.
This new WASAPI recorder still requires its own spoken recording/playback test.
It has no network probe mode and is separate from the temporary firewall test.

References: Microsoft's [capture sequence](https://learn.microsoft.com/en-us/windows/win32/coreaudio/capturing-a-stream)
and [capture packet flags](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer).
