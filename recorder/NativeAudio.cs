using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace LocalVoiceRecorder
{
    internal sealed class InputDevice
    {
        internal string Id, Name;
        internal bool IsDefault;
        public override string ToString() { return Name + (IsDefault ? " (Windows default)" : ""); }
    }

    internal static class NativeAudio
    {
        internal static readonly Guid AudioClientId = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
        internal static readonly Guid CaptureClientId = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
        internal static void Check(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }
        internal static void Release(object value) { if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }
        internal static IMMDeviceEnumerator Enumerator()
        {
            return (IMMDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")));
        }
        internal static List<InputDevice> Devices()
        {
            IMMDeviceEnumerator enumerator = Enumerator();
            IMMDeviceCollection collection = null;
            IMMDevice defaultDevice = null;
            List<InputDevice> result = new List<InputDevice>();
            try {
                string defaultId = null;
                if (enumerator.GetDefaultAudioEndpoint(1, 1, out defaultDevice) >= 0) Check(defaultDevice.GetId(out defaultId));
                Check(enumerator.EnumAudioEndpoints(1, 1, out collection)); // capture, active
                uint count; Check(collection.GetCount(out count));
                for (uint i = 0; i < count; i++) {
                    IMMDevice device = null;
                    IPropertyStore properties = null;
                    try {
                        Check(collection.Item(i, out device));
                        string id; Check(device.GetId(out id));
                        Check(device.OpenPropertyStore(0, out properties));
                        PropertyKey key = new PropertyKey { FormatId = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), Id = 14 };
                        PropVariant value;
                        Check(properties.GetValue(ref key, out value));
                        string name;
                        try { name = value.Type == 31 ? Marshal.PtrToStringUni(value.Pointer) : "Microphone " + (i + 1); }
                        finally { PropVariantClear(ref value); }
                        result.Add(new InputDevice { Id = id, Name = name, IsDefault = id == defaultId });
                    } finally { Release(properties); Release(device); }
                }
                return result;
            } finally { Release(defaultDevice); Release(collection); Release(enumerator); }
        }
        internal static AudioFormat Describe(string id)
        {
            IMMDeviceEnumerator enumerator = Enumerator(); IMMDevice device = null; object clientObject = null;
            IntPtr pointer = IntPtr.Zero;
            try {
                Check(enumerator.GetDevice(id, out device));
                Guid iid = AudioClientId;
                Check(device.Activate(ref iid, 23, IntPtr.Zero, out clientObject));
                Check(((IAudioClient)clientObject).GetMixFormat(out pointer));
                return AudioFormat.FromPointer(pointer);
            } finally { if (pointer != IntPtr.Zero) Marshal.FreeCoTaskMem(pointer); Release(clientObject); Release(device); Release(enumerator); }
        }
        [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant value);
    }

    [StructLayout(LayoutKind.Sequential)] internal struct PropertyKey { internal Guid FormatId; internal uint Id; }
    // Build targets x64, where PROPVARIANT occupies 24 bytes.
    [StructLayout(LayoutKind.Explicit, Size = 24)] internal struct PropVariant
    {
        [FieldOffset(0)] internal ushort Type;
        [FieldOffset(8)] internal IntPtr Pointer;
    }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, uint states, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        [PreserveSig] int OpenPropertyStore(uint access, out IPropertyStore properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }
    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }
    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, uint flags, long bufferDuration, long periodicity, IntPtr format, ref Guid session);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint frames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long normal, out long minimum);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }
    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }
}
