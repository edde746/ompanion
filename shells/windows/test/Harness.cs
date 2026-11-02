// What ci.ps1 does to the app as a person would: copy files in Explorer, choose files in its open panel, drag files
// onto its window, and start its MSIX package's app. C# 5: Windows PowerShell's Add-Type compiles it.
using System;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using ComTypes = System.Runtime.InteropServices.ComTypes;

public static class Harness {
    const int WM_SETTEXT = 0x000C;
    const int WM_COMMAND = 0x0111;
    const int IDOK = 1;
    const int DRAGDROP_S_DROP = 0x00040100;
    const int DRAGDROP_S_USEDEFAULTCURSORS = 0x00040102;
    const int DROPEFFECT_COPY = 1;
    const int DROPEFFECT_LINK = 4;
    const uint MOUSEEVENTF_MOVE = 0x0001;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP = 0x0004;
    const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const byte VK_MENU = 0x12;
    const byte VK_ESCAPE = 0x1B;
    const uint WS_POPUP = 0x80000000;
    const uint WS_VISIBLE = 0x10000000;
    const int WS_EX_TOPMOST = 0x0008;
    const int WS_EX_TOOLWINDOW = 0x0080;
    const uint PM_REMOVE = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    struct Rect {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Msg {
        public IntPtr Window;
        public uint Message;
        public IntPtr WParam, LParam;
        public uint Time;
        public int X, Y;
    }

    delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr dialog, int id);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, string lParam);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extraInfo);
    [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowEx(int exStyle, string className, string title, uint style, int x, int y, int width,
        int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool PeekMessage(out Msg message, IntPtr window, uint first, uint last, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref Msg message);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Msg message);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint thread, uint attachTo, bool attach);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr window);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("ole32.dll")] static extern int OleInitialize(IntPtr reserved);
    [DllImport("ole32.dll")] static extern int DoDragDrop(ComTypes.IDataObject data, IDropSource source, int okEffects, out int effect);

    [ComImport, Guid("00000121-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDropSource {
        [PreserveSig] int QueryContinueDrag([MarshalAs(UnmanagedType.Bool)] bool escapePressed, int keyState);
        [PreserveSig] int GiveFeedback(int effect);
    }

    // Holds the drag over the window long enough for the page to accept it (its dragover handler answers
    // asynchronously), then drops. Counts what OLE asked, for a failure's message.
    class DropSource : IDropSource {
        readonly Stopwatch held = Stopwatch.StartNew();
        readonly int dropAfterMs;
        public int queries, feedbacks, lastKeys, lastEffect;

        public DropSource(int dropAfterMs) { this.dropAfterMs = dropAfterMs; }

        public int QueryContinueDrag(bool escapePressed, int keyState) {
            queries++;
            lastKeys = keyState;
            return held.ElapsedMilliseconds < dropAfterMs ? 0 : DRAGDROP_S_DROP;
        }

        public int GiveFeedback(int effect) {
            feedbacks++;
            lastEffect = effect;
            return DRAGDROP_S_USEDEFAULTCURSORS;
        }

        public override string ToString() {
            return queries + " QueryContinueDrag (last keys " + lastKeys + "), " + feedbacks + " GiveFeedback (last effect " +
                lastEffect + ")";
        }
    }

    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IApplicationActivationManager {
        void ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments, int options, out uint processId);
    }

    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    class ApplicationActivationManager {
    }

    // Starts a packaged app as the Start menu does; its process id.
    public static int Activate(string appUserModelId) {
        uint processId;
        ((IApplicationActivationManager)new ApplicationActivationManager()).ActivateApplication(appUserModelId, "", 0,
            out processId);
        return (int)processId;
    }

    // On a thread of its own: the clipboard and drag and drop need a single-threaded apartment. A thread that is still
    // busy after timeoutMs is left behind (it does not keep the process alive) and the call fails.
    static void OnStaThread(ThreadStart work, int timeoutMs) {
        Exception failure = null;
        Thread thread = new Thread(delegate() {
            try {
                work();
            } catch (Exception error) {
                failure = error;
            }
        });
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!thread.Join(timeoutMs)) throw new Exception("still running after " + timeoutMs + " ms");
        if (failure != null) throw new Exception(failure.Message, failure);
    }

    // What copying the files in Explorer puts on the clipboard (CF_HDROP among others).
    public static void CopyFiles(string[] paths) {
        OnStaThread(delegate() {
            StringCollection list = new StringCollection();
            list.AddRange(paths);
            System.Windows.Forms.Clipboard.SetFileDropList(list);
        }, 10000);
    }

    // Brings the window to the front even when this process may not: Escape closes a shell surface that holds the front
    // (on a fresh Windows 11 arm64 runner a Windows.UI.Core.CoreWindow does), a key this process typed counts as the
    // user's last input, and sharing the foreground thread's input state lets SetForegroundWindow through.
    static void TakeForeground(IntPtr window) {
        keybd_event(VK_ESCAPE, 0, 0, UIntPtr.Zero);
        keybd_event(VK_ESCAPE, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        Pump(500);
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        IntPtr front = GetForegroundWindow();
        uint owner;
        uint frontThread = front == IntPtr.Zero ? 0 : GetWindowThreadProcessId(front, out owner);
        uint thread = GetCurrentThreadId();
        bool attached = frontThread != 0 && frontThread != thread && AttachThreadInput(thread, frontThread, true);
        try {
            BringWindowToTop(window);
            SetForegroundWindow(window);
        } finally {
            if (attached) AttachThreadInput(thread, frontThread, false);
        }
    }

    // Moves the cursor as the mouse does (absolute coordinates on the primary screen).
    static void MoveMouse(int x, int y) {
        mouse_event(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, x * 65536 / GetSystemMetrics(0), y * 65536 / GetSystemMetrics(1),
            0, UIntPtr.Zero);
    }

    static void Pump(int ms) {
        Stopwatch pumped = Stopwatch.StartNew();
        Msg message;
        while (pumped.ElapsedMilliseconds < ms) {
            while (PeekMessage(out message, IntPtr.Zero, 0, 0, PM_REMOVE)) {
                TranslateMessage(ref message);
                DispatchMessage(ref message);
            }
            Thread.Sleep(10);
        }
    }

    // Drags the files onto the middle of the app's window (window class "Ompanion", main.cpp) and drops them there, as a
    // person does from Explorer: the button goes down on a small window of this thread's, which comes to the front so
    // that OLE's drag loop gets the mouse, and the mouse moves to the app's window. The drop effect the window chose.
    public static int Drag(string[] paths, int dropAfterMs) {
        IntPtr window = FindWindow("Ompanion", null);
        if (window == IntPtr.Zero) throw new Exception("no ompanion window");
        Rect rect;
        if (!GetWindowRect(window, out rect)) throw new Win32Exception();
        int targetX = (rect.Left + rect.Right) / 2, targetY = (rect.Top + rect.Bottom) / 2;
        int effect = 0;
        DropSource source = new DropSource(dropAfterMs);
        bool dragging = true;
        // Into the window, then a pixel to and fro while the drag lasts: OLE's drag loop runs on input.
        Thread mouse = new Thread(delegate() {
            for (int step = 1; step <= 20 && dragging; step++) {
                MoveMouse(60 + (targetX - 60) * step / 20, 60 + (targetY - 60) * step / 20);
                Thread.Sleep(50);
            }
            for (int step = 0; dragging; step++) {
                MoveMouse(targetX + step % 2, targetY);
                Thread.Sleep(50);
            }
        });
        mouse.IsBackground = true;
        try {
            OnStaThread(delegate() {
                int initialized = OleInitialize(IntPtr.Zero);
                if (initialized < 0) throw new COMException("OleInitialize failed", initialized);
                IntPtr from = CreateWindowEx(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, "STATIC", "drag source", WS_POPUP | WS_VISIBLE,
                    0, 0, 120, 120, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                if (from == IntPtr.Zero) throw new Win32Exception();
                try {
                    TakeForeground(from);
                    Pump(300);
                    // The button goes down on this window, which a click also brings to the front.
                    MoveMouse(60, 60);
                    Pump(100);
                    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
                    Pump(200);
                    IntPtr front = GetForegroundWindow();
                    if (front != from) {
                        throw new Exception("the drag source is not in front (" + (front == IntPtr.Zero ? "no window" :
                            ClassOf(front)) + " is)");
                    }
                    System.Windows.Forms.DataObject data = new System.Windows.Forms.DataObject();
                    StringCollection list = new StringCollection();
                    list.AddRange(paths);
                    data.SetFileDropList(list);
                    mouse.Start();
                    int result = DoDragDrop(data, source, DROPEFFECT_COPY | DROPEFFECT_LINK, out effect);
                    if (result != DRAGDROP_S_DROP) throw new Exception("DoDragDrop returned 0x" + result.ToString("X8"));
                } finally {
                    DestroyWindow(from);
                }
            }, dropAfterMs + 15000);
        } catch (Exception error) {
            throw new Exception(error.Message + "; OLE asked " + source, error);
        } finally {
            dragging = false;
            mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
        }
        return effect;
    }

    static string ClassOf(IntPtr window) {
        StringBuilder name = new StringBuilder(256);
        GetClassName(window, name, name.Capacity);
        return name.ToString();
    }

    // The process and window class of the window in front, as "<process id> <class>".
    public static string Foreground() {
        IntPtr front = GetForegroundWindow();
        if (front == IntPtr.Zero) return "0 none";
        uint owner;
        GetWindowThreadProcessId(front, out owner);
        return owner + " " + ClassOf(front);
    }

    static IntPtr FindDialog(int processId) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == processId && IsWindowVisible(window) && ClassOf(window) == "#32770") {
                found = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // The panel's file name (or folder) box: the edit field of its combo box, else an edit field outside the address
    // and search bars.
    static IntPtr NameBox(IntPtr dialog) {
        IntPtr inCombo = IntPtr.Zero;
        IntPtr other = IntPtr.Zero;
        EnumChildWindows(dialog, delegate(IntPtr window, IntPtr parameter) {
            if (ClassOf(window) != "Edit" || !IsWindowVisible(window)) return true;
            if (ClassOf(GetParent(window)) == "ComboBox") {
                inCombo = window;
                return false;
            }
            if (other == IntPtr.Zero && !InBar(window, dialog)) other = window;
            return true;
        }, IntPtr.Zero);
        return inCombo != IntPtr.Zero ? inCombo : other;
    }

    static bool InBar(IntPtr window, IntPtr dialog) {
        for (IntPtr parent = GetParent(window); parent != IntPtr.Zero && parent != dialog; parent = GetParent(parent)) {
            string name = ClassOf(parent);
            if (name == "ReBarWindow32" || name == "UniversalSearchBand" || name == "Breadcrumb Parent") return true;
        }
        return false;
    }

    // Every control in the panel, for a failure's message.
    static string Controls(IntPtr dialog) {
        StringBuilder list = new StringBuilder();
        EnumChildWindows(dialog, delegate(IntPtr window, IntPtr parameter) {
            list.Append(ClassOf(window)).Append('#').Append(GetDlgCtrlID(window))
                .Append(IsWindowVisible(window) ? "" : "(hidden)").Append('<').Append(ClassOf(GetParent(window)))
                .Append("; ");
            return true;
        }, IntPtr.Zero);
        return list.ToString();
    }

    static bool WaitClosed(IntPtr dialog, int timeoutMs) {
        Stopwatch waited = Stopwatch.StartNew();
        while (IsWindow(dialog) && IsWindowVisible(dialog)) {
            if (waited.ElapsedMilliseconds > timeoutMs) return false;
            Thread.Sleep(100);
        }
        return true;
    }

    // Waits for the process's open panel, types text into its name box and presses its default button (Open, Select
    // Folder). A folder panel may go into a typed folder instead of choosing it; a second press then chooses the
    // folder it is in.
    public static void Choose(int processId, string text, int timeoutMs) {
        Stopwatch waited = Stopwatch.StartNew();
        IntPtr dialog = IntPtr.Zero;
        while ((dialog = FindDialog(processId)) == IntPtr.Zero) {
            if (waited.ElapsedMilliseconds > timeoutMs) throw new Exception("no open panel after " + timeoutMs + " ms");
            Thread.Sleep(200);
        }
        // The panel fills its controls after it shows.
        Thread.Sleep(1000);
        IntPtr box = NameBox(dialog);
        if (box == IntPtr.Zero) throw new Exception("the open panel has no name box: " + Controls(dialog));
        SendMessage(box, WM_SETTEXT, IntPtr.Zero, text);
        IntPtr ok = GetDlgItem(dialog, IDOK);
        PostMessage(dialog, WM_COMMAND, (IntPtr)IDOK, ok);
        if (WaitClosed(dialog, 3000)) return;
        PostMessage(dialog, WM_COMMAND, (IntPtr)IDOK, ok);
        if (!WaitClosed(dialog, 10000)) throw new Exception("the open panel is still open: " + Controls(dialog));
    }
}
