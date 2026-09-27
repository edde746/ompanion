// The Windows half of the ms-desktop capture: the display's mode and scale, the photograph of the app's window, and
// a job that ends every process of the run. `run.ps1` builds it with the .NET Framework's own csc, so the capture
// machine needs nothing installed.
//
//   winshot display                          the primary display: "<width> <height> <scale %>"
//   winshot display <width> <height> <scale>  sets them; the mode is not written to the registry, the scale is
//   winshot capture <directory> <out.png>     the window of the process whose executable lies under <directory>
//   winshot run <log> <program> [<arg>...]    runs the program, its output appended to <log>, in a job whose
//                                             processes all end when winshot does, however it ends
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class Winshot {
    static int Main(string[] args) {
        // Physical pixels everywhere: without this, a scaled display reports and photographs logical ones.
        SetProcessDpiAwarenessContext(new IntPtr(-4));
        try {
            if (args.Length == 1 && args[0] == "display") {
                Console.WriteLine(DescribeDisplay());
                return 0;
            }
            if (args.Length == 4 && args[0] == "display") {
                SetDisplay(int.Parse(args[1]), int.Parse(args[2]), int.Parse(args[3]));
                Console.WriteLine(DescribeDisplay());
                return 0;
            }
            if (args.Length == 3 && args[0] == "capture") {
                Capture(args[1], args[2]);
                return 0;
            }
            if (args.Length >= 3 && args[0] == "run") {
                string[] arguments = new string[args.Length - 3];
                Array.Copy(args, 3, arguments, 0, arguments.Length);
                return Run(args[1], args[2], arguments);
            }
            Console.Error.WriteLine("usage: winshot display [<width> <height> <scale>] | capture <directory> <out.png> | run <log> <program> [<arg>...]");
            return 2;
        } catch (Exception error) {
            Console.Error.WriteLine("winshot: " + error.Message);
            return 1;
        }
    }

    // ---------------------------------------------------------------------------------------------------- run

    // `flutter drive` leaves processes behind (MSBuild's nodes, the compiler's PDB server) and a cancelled run leaves
    // all of them, the app included. Every child of this process joins its job, and the job kills what is in it
    // when its last handle closes: when this process exits or is killed.
    static int Run(string log, string program, string[] arguments) {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Exception("CreateJobObject failed");
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(limits, buffer, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size)) {
                throw new Exception("SetInformationJobObject failed");
            }
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
        if (!AssignProcessToJobObject(job, Process.GetCurrentProcess().Handle)) throw new Exception("AssignProcessToJobObject failed");

        StringBuilder line = new StringBuilder();
        foreach (string argument in arguments) {
            if (line.Length > 0) line.Append(' ');
            line.Append(argument.IndexOfAny(new[] { ' ', '\t', '"' }) < 0 ? argument : "\"" + argument.Replace("\"", "\\\"") + "\"");
        }
        ProcessStartInfo start = new ProcessStartInfo(program, line.ToString());
        start.UseShellExecute = false;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.StandardOutputEncoding = Encoding.UTF8;
        start.StandardErrorEncoding = Encoding.UTF8;
        object gate = new object();
        using (StreamWriter writer = new StreamWriter(log, true, new UTF8Encoding(false))) {
            writer.AutoFlush = true;
            DataReceivedEventHandler append = (sender, received) => {
                if (received.Data == null) return;
                lock (gate) writer.WriteLine(received.Data);
            };
            using (Process child = new Process()) {
                child.StartInfo = start;
                child.OutputDataReceived += append;
                child.ErrorDataReceived += append;
                child.Start();
                child.BeginOutputReadLine();
                child.BeginErrorReadLine();
                child.WaitForExit();
                return child.ExitCode;
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ display

    // The scale steps Windows offers; the display config API speaks of them relative to the recommended one.
    static readonly int[] Scales = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };

    static string DescribeDisplay() {
        Source source = PrimarySource();
        DEVMODE mode = CurrentMode(source.GdiName);
        return mode.dmPelsWidth + " " + mode.dmPelsHeight + " " + CurrentScale(source);
    }

    static void SetDisplay(int width, int height, int scale) {
        Source source = PrimarySource();
        DEVMODE mode = CurrentMode(source.GdiName);
        if (mode.dmPelsWidth != width || mode.dmPelsHeight != height) {
            mode.dmPelsWidth = width;
            mode.dmPelsHeight = height;
            mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
            int result = ChangeDisplaySettingsEx(source.GdiName, ref mode, IntPtr.Zero, 0, IntPtr.Zero);
            if (result != 0) throw new Exception(source.GdiName + " refused " + width + "x" + height + " (" + result + ")");
        }
        // The recommended scale depends on the mode, so it is read again after the mode changed.
        int[] relative = ScaleRange(PrimarySource());
        int recommended = -relative[0];
        int target = Array.IndexOf(Scales, scale);
        if (target < 0 || target - recommended > relative[2]) throw new Exception("scale " + scale + " % is not offered");
        byte[] packet = Header(DISPLAYCONFIG_DEVICE_INFO_SET_DPI_SCALE, 24, source);
        BitConverter.GetBytes(target - recommended).CopyTo(packet, 20);
        int status = DisplayConfigSetDeviceInfo(packet);
        if (status != 0) throw new Exception("setting the scale failed (" + status + ")");
    }

    static int CurrentScale(Source source) {
        int[] relative = ScaleRange(source);
        return Scales[-relative[0] + relative[1]];
    }

    // min, current and max, each relative to the recommended scale.
    static int[] ScaleRange(Source source) {
        byte[] packet = Header(DISPLAYCONFIG_DEVICE_INFO_GET_DPI_SCALE, 32, source);
        int status = DisplayConfigGetDeviceInfo(packet);
        if (status != 0) throw new Exception("reading the scale failed (" + status + ")");
        return new[] { BitConverter.ToInt32(packet, 20), BitConverter.ToInt32(packet, 24), BitConverter.ToInt32(packet, 28) };
    }

    static DEVMODE CurrentMode(string gdiName) {
        DEVMODE mode = new DEVMODE();
        mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(gdiName, ENUM_CURRENT_SETTINGS, ref mode)) throw new Exception("no mode for " + gdiName);
        return mode;
    }

    struct Source {
        public uint AdapterLow;
        public int AdapterHigh;
        public uint Id;
        public string GdiName;
    }

    // The active display path whose source is the primary monitor.
    static Source PrimarySource() {
        string primary = System.Windows.Forms.Screen.PrimaryScreen.DeviceName;
        uint pathCount, modeCount;
        int status = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
        if (status != 0) throw new Exception("GetDisplayConfigBufferSizes failed (" + status + ")");
        byte[] paths = new byte[pathCount * PathInfoSize];
        byte[] modes = new byte[modeCount * ModeInfoSize];
        status = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
        if (status != 0) throw new Exception("QueryDisplayConfig failed (" + status + ")");
        for (int index = 0; index < pathCount; index++) {
            int offset = index * PathInfoSize;
            Source source = new Source {
                AdapterLow = BitConverter.ToUInt32(paths, offset),
                AdapterHigh = BitConverter.ToInt32(paths, offset + 4),
                Id = BitConverter.ToUInt32(paths, offset + 8),
            };
            byte[] name = Header(DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, 84, source);
            if (DisplayConfigGetDeviceInfo(name) != 0) continue;
            source.GdiName = System.Text.Encoding.Unicode.GetString(name, 20, 64).TrimEnd('\0');
            if (string.Equals(source.GdiName, primary, StringComparison.OrdinalIgnoreCase)) return source;
        }
        throw new Exception("no active display path for " + primary);
    }

    static byte[] Header(int type, int size, Source source) {
        byte[] packet = new byte[size];
        BitConverter.GetBytes(type).CopyTo(packet, 0);
        BitConverter.GetBytes(size).CopyTo(packet, 4);
        BitConverter.GetBytes(source.AdapterLow).CopyTo(packet, 8);
        BitConverter.GetBytes(source.AdapterHigh).CopyTo(packet, 12);
        BitConverter.GetBytes(source.Id).CopyTo(packet, 16);
        return packet;
    }

    // ------------------------------------------------------------------------------------------------ capture

    // PrintWindow with PW_RENDERFULLCONTENT asks DWM for the window as it composes it, title bar included, so
    // whatever overlaps it on the screen (the taskbar, a notification) stays out of the picture. The window rect
    // holds the invisible resize borders; the extended frame bounds are the window as it is seen.
    static void Capture(string directory, string output) {
        IntPtr window = FindWindow(Path.GetFullPath(directory));
        RECT outer, frame;
        if (!GetWindowRect(window, out outer)) throw new Exception("GetWindowRect failed");
        if (DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, out frame, Marshal.SizeOf(typeof(RECT))) != 0) {
            throw new Exception("DwmGetWindowAttribute failed");
        }
        using (Bitmap whole = new Bitmap(outer.Right - outer.Left, outer.Bottom - outer.Top, PixelFormat.Format32bppArgb)) {
            using (Graphics graphics = Graphics.FromImage(whole)) {
                IntPtr hdc = graphics.GetHdc();
                bool printed = PrintWindow(window, hdc, PW_RENDERFULLCONTENT);
                graphics.ReleaseHdc(hdc);
                if (!printed) throw new Exception("PrintWindow failed");
            }
            Rectangle seen = new Rectangle(frame.Left - outer.Left, frame.Top - outer.Top, frame.Right - frame.Left, frame.Bottom - frame.Top);
            using (Bitmap shot = whole.Clone(seen, PixelFormat.Format24bppRgb)) {
                shot.Save(output, ImageFormat.Png);
            }
        }
        Console.WriteLine(output + " " + (frame.Right - frame.Left) + "x" + (frame.Bottom - frame.Top));
    }

    static IntPtr FindWindow(string directory) {
        int session = Process.GetCurrentProcess().SessionId;
        foreach (Process process in Process.GetProcesses()) {
            if (process.SessionId != session || process.MainWindowHandle == IntPtr.Zero) continue;
            string path;
            try {
                path = process.MainModule.FileName;
            } catch (Exception) {
                continue; // an elevated or protected process: not the app
            }
            if (path.StartsWith(directory, StringComparison.OrdinalIgnoreCase)) return process.MainWindowHandle;
        }
        throw new Exception("no window of a process under " + directory);
    }

    // --------------------------------------------------------------------------------------------- interop

    const int ENUM_CURRENT_SETTINGS = -1;
    const int DM_PELSWIDTH = 0x80000;
    const int DM_PELSHEIGHT = 0x100000;
    const uint QDC_ONLY_ACTIVE_PATHS = 2;
    const int PathInfoSize = 72;
    const int ModeInfoSize = 64;
    const int DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME = 1;
    const int DISPLAYCONFIG_DEVICE_INFO_GET_DPI_SCALE = -3;
    const int DISPLAYCONFIG_DEVICE_INFO_SET_DPI_SCALE = -4;
    const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    const uint PW_RENDERFULLCONTENT = 2;
    const int JobObjectExtendedLimitInformation = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    struct RECT {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("user32.dll")] static extern IntPtr SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE devMode);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE devMode, IntPtr window, uint flags, IntPtr parameter);
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint pathCount, byte[] paths, ref uint modeCount, byte[] modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(byte[] packet);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(byte[] packet);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr hdc, uint flags);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out RECT value, int size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}
