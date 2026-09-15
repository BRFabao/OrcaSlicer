param(
    [Parameter(Mandatory = $true)]
    [int]$ParentPid,

    [Parameter(Mandatory = $true)]
    [string]$Root,

    [switch]$CompileOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Accessibility

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class BaleiaNativeWindow
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out RECT rectangle);

    public static IntPtr FindLargestTopWindow(int[] processIds)
    {
        if (processIds == null || processIds.Length == 0) return IntPtr.Zero;
        HashSet<uint> wanted = new HashSet<uint>();
        foreach (int processId in processIds)
            if (processId > 0) wanted.Add((uint)processId);

        IntPtr best = IntPtr.Zero;
        long bestArea = -1;
        EnumWindows(delegate(IntPtr window, IntPtr unused)
        {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (!wanted.Contains(processId)) return true;

            RECT rectangle;
            long area = 0;
            if (GetWindowRect(window, out rectangle))
                area = Math.Max(0, rectangle.Right - rectangle.Left) *
                    (long)Math.Max(0, rectangle.Bottom - rectangle.Top);
            if (area > bestArea)
            {
                best = window;
                bestArea = area;
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }
}

public sealed class BaleiaStatusToast : Form
{
    private readonly Timer closeTimer;
    private readonly bool connected;

    private BaleiaStatusToast(string message, bool isConnected)
    {
        connected = isConnected;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Color.FromArgb(35, 39, 47);
        ForeColor = Color.White;
        ClientSize = new Size(300, 72);

        Rectangle area = Screen.PrimaryScreen == null
            ? new Rectangle(0, 0, 1024, 768)
            : Screen.PrimaryScreen.WorkingArea;
        Location = new Point(
            Math.Max(area.Left, area.Right - Width - 18),
            Math.Max(area.Top, area.Bottom - Height - 18));

        Label title = new Label();
        title.AutoSize = false;
        title.Location = new Point(58, 15);
        title.Size = new Size(225, 42);
        title.TextAlign = ContentAlignment.MiddleLeft;
        title.Font = new Font("Segoe UI", 12.0f, FontStyle.Bold);
        title.ForeColor = Color.White;
        title.BackColor = Color.Transparent;
        title.Text = message ?? String.Empty;
        Controls.Add(title);

        closeTimer = new Timer();
        closeTimer.Interval = 3500;
        closeTimer.Tick += delegate
        {
            closeTimer.Stop();
            Close();
        };
        Shown += delegate { closeTimer.Start(); };
    }

    protected override bool ShowWithoutActivation
    {
        get { return true; }
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= 0x08000000;
            parameters.ExStyle |= 0x00000080;
            return parameters;
        }
    }

    protected override void OnPaint(PaintEventArgs args)
    {
        base.OnPaint(args);
        using (SolidBrush brush = new SolidBrush(
            connected ? Color.FromArgb(24, 190, 88) : Color.FromArgb(230, 62, 62)))
        {
            args.Graphics.SmoothingMode =
                System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            args.Graphics.FillEllipse(brush, 20, 22, 28, 28);
        }
    }

    public static void Display(string message, bool connected)
    {
        BaleiaStatusToast toast = new BaleiaStatusToast(message, connected);
        toast.Show();
    }
}
'@
Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies @(
    [System.Windows.Forms.Form].Assembly.Location,
    [System.Drawing.Color].Assembly.Location
)

if (-not ('BaleiaMsaaBridge' -as [type])) {
    $msaaSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Accessibility;

public static class BaleiaMsaaBridge
{
    private const uint OBJID_CLIENT = 0xFFFFFFFC;
    private const uint SPI_GETSCREENREADER = 0x0046;
    private const uint SPI_SETSCREENREADER = 0x0047;
    private const uint SPIF_SENDCHANGE = 0x0002;

    private const int ROLE_SYSTEM_DIALOG = 0x12;
    private const int ROLE_SYSTEM_GROUPING = 0x14;
    private const int ROLE_SYSTEM_MENUPOPUP = 0x0B;
    private const int ROLE_SYSTEM_MENUITEM = 0x0C;
    private const int ROLE_SYSTEM_LIST = 0x21;
    private const int ROLE_SYSTEM_LISTITEM = 0x22;
    private const int ROLE_SYSTEM_OUTLINE = 0x23;
    private const int ROLE_SYSTEM_PUSHBUTTON = 0x2B;
    private const int ROLE_SYSTEM_RADIOBUTTON = 0x2D;
    private const int ROLE_SYSTEM_COMBOBOX = 0x2E;
    private const int ROLE_SYSTEM_DROPLIST = 0x2F;

    private const int STATE_SYSTEM_UNAVAILABLE = 0x00000001;
    private const int STATE_SYSTEM_CHECKED = 0x00000010;
    private const int STATE_SYSTEM_INVISIBLE = 0x00008000;
    private const int STATE_SYSTEM_OFFSCREEN = 0x00010000;
    private const int MaxDepth = 40;
    private const int MaxChildren = 10000;

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    private sealed class Entry
    {
        public IAccessible Owner;
        public int ChildId;
        public string Name;
        public string Action;
        public int Role;
        public int State;
        public bool InChoiceContainer;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(
        IntPtr hWndParent,
        EnumWindowsProc lpEnumFunc,
        IntPtr lParam);

    [DllImport("oleacc.dll", PreserveSig = true)]
    private static extern int AccessibleObjectFromWindow(
        IntPtr hwnd,
        uint dwObjectID,
        ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IAccessible ppvObject);

    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfoGet(
        uint uiAction,
        uint uiParam,
        ref int pvParam,
        uint fWinIni);

    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfoSet(
        uint uiAction,
        uint uiParam,
        IntPtr pvParam,
        uint fWinIni);

    public static bool GetScreenReaderFlag()
    {
        int value = 0;
        if (!SystemParametersInfoGet(SPI_GETSCREENREADER, 0, ref value, 0))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return value != 0;
    }

    public static void SetScreenReaderFlag(bool enabled)
    {
        if (!SystemParametersInfoSet(
            SPI_SETSCREENREADER,
            enabled ? 1u : 0u,
            IntPtr.Zero,
            SPIF_SENDCHANGE))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    public static string GetConnectionState(IntPtr topWindow)
    {
        if (topWindow == IntPtr.Zero) return "checking";

        bool sawMyPrinters = false;
        bool sawPrinterCard = false;
        bool sawNamedAccount = false;
        bool sawLoginAction = false;

        foreach (IAccessible root in Roots(topWindow))
        {
            foreach (Entry entry in Flatten(root))
            {
                string name = Clean(entry.Name);
                if (String.IsNullOrWhiteSpace(name)) continue;

                if (EqualName(name, "My Printers"))
                    sawMyPrinters = true;
                if (name.IndexOf("Bed:", StringComparison.OrdinalIgnoreCase) >= 0)
                    sawPrinterCard = true;
                if (EqualName(name, "Sign in") ||
                    EqualName(name, "Log in") ||
                    EqualName(name, "Login") ||
                    EqualName(name, "Entrar") ||
                    name.IndexOf("Fazer login", StringComparison.OrdinalIgnoreCase) >= 0)
                    sawLoginAction = true;

                if (name.IndexOf("chevron_down", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    string candidate = Regex.Replace(
                        name,
                        @"chevron_down|expand_more|arrow_drop_down",
                        " ",
                        RegexOptions.IgnoreCase);
                    candidate = Regex.Replace(candidate, @"\s+", " ").Trim();
                    string meaningful = Regex.Replace(
                        candidate,
                        @"\b(account|avatar|person|profile|user|menu|circle|icon)\b",
                        " ",
                        RegexOptions.IgnoreCase);
                    meaningful = Regex.Replace(meaningful, @"\s+", " ").Trim();
                    bool genericSelector = Regex.IsMatch(
                        meaningful,
                        @"^(device\s+name|sort|printer|impressora)$",
                        RegexOptions.IgnoreCase);
                    if (!genericSelector &&
                        Regex.IsMatch(meaningful, @"[\p{L}\p{Nd}]{2,}"))
                        sawNamedAccount = true;
                }
            }
        }

        if (sawNamedAccount || sawPrinterCard) return "connected";
        if (sawLoginAction || sawMyPrinters) return "disconnected";
        return "checking";
    }

    public static bool HasDialog(IntPtr topWindow, string dialogName)
    {
        return FindDialog(topWindow, dialogName) != null;
    }

    public static bool PressExactButton(IntPtr topWindow, string buttonName)
    {
        foreach (IAccessible root in Roots(topWindow))
        {
            foreach (Entry entry in Flatten(root))
            {
                if (entry.Role == ROLE_SYSTEM_PUSHBUTTON &&
                    EqualName(entry.Name, buttonName) &&
                    Invoke(entry))
                    return true;
            }
        }
        return false;
    }

    public static bool PressButtonInDialog(
        IntPtr topWindow,
        string dialogName,
        string buttonName)
    {
        IAccessible dialog = FindDialog(topWindow, dialogName);
        if (dialog == null) return false;

        foreach (Entry entry in Flatten(dialog))
        {
            if (entry.Role == ROLE_SYSTEM_PUSHBUTTON &&
                EqualName(entry.Name, buttonName) &&
                Invoke(entry))
                return true;
        }
        return false;
    }

    public static string OpenPrinterPicker(
        IntPtr topWindow,
        string dialogName,
        string printerName)
    {
        IAccessible dialog = FindDialog(topWindow, dialogName);
        if (dialog == null) return "missing-dialog";

        foreach (Entry entry in Flatten(dialog))
        {
            if (entry.Name.IndexOf("chevron_down", StringComparison.OrdinalIgnoreCase) < 0 ||
                String.IsNullOrWhiteSpace(entry.Action) ||
                IsHiddenOrUnavailable(entry))
                continue;

            string selected = PrinterNameFromSelector(entry.Name);
            if (!String.IsNullOrWhiteSpace(printerName) &&
                ChoiceNameMatches(selected, printerName))
                return "already-selected";
            return Invoke(entry) ? "opened" : "invoke-failed";
        }
        return "missing-selector";
    }

    public static string GetSelectedPrinter(
        IntPtr topWindow,
        string dialogName)
    {
        IAccessible dialog = FindDialog(topWindow, dialogName);
        if (dialog == null) return "missing-dialog";

        foreach (Entry entry in Flatten(dialog))
        {
            if (entry.Name.IndexOf("chevron_down", StringComparison.OrdinalIgnoreCase) < 0 ||
                String.IsNullOrWhiteSpace(entry.Action) ||
                IsHiddenOrUnavailable(entry))
                continue;

            string selected = PrinterNameFromSelector(entry.Name);
            if (!String.IsNullOrWhiteSpace(selected)) return selected;
        }
        return "missing-selector";
    }

    public static bool ChoosePrinter(IntPtr topWindow, string printerName)
    {
        Entry best = null;
        int bestRank = Int32.MaxValue;

        foreach (IAccessible root in Roots(topWindow))
        {
            foreach (Entry entry in Flatten(root))
            {
                if (IsHiddenOrUnavailable(entry) ||
                    !ChoiceNameMatches(entry.Name, printerName) ||
                    entry.Name.IndexOf("chevron_down", StringComparison.OrdinalIgnoreCase) >= 0)
                    continue;

                int rank = ChoiceRank(entry);
                if (rank < bestRank)
                {
                    best = entry;
                    bestRank = rank;
                }
            }
        }

        return best != null && bestRank <= 1 && Invoke(best);
    }

    public static string[] GetFilamentCards(IntPtr topWindow, string dialogName)
    {
        IAccessible dialog = FindDialog(topWindow, dialogName);
        if (dialog == null) return new string[0];

        List<Entry> cards = FilamentCards(dialog);
        List<string> names = new List<string>();
        foreach (Entry card in cards) names.Add(card.Name);
        return names.ToArray();
    }

    public static bool OpenFilamentCard(
        IntPtr topWindow,
        string dialogName,
        int cardIndex)
    {
        IAccessible dialog = FindDialog(topWindow, dialogName);
        if (dialog == null) return false;

        List<Entry> cards = FilamentCards(dialog);
        return cardIndex >= 0 && cardIndex < cards.Count && Invoke(cards[cardIndex]);
    }

    public static bool ChooseFilamentSlot(IntPtr topWindow, string slot)
    {
        Entry best = null;
        int bestRank = Int32.MaxValue;

        foreach (IAccessible root in Roots(topWindow))
        {
            foreach (Entry entry in Flatten(root))
            {
                if (!SlotNameMatches(entry.Name, slot)) continue;
                int rank = ChoiceRank(entry);
                if (rank < bestRank)
                {
                    best = entry;
                    bestRank = rank;
                }
            }
        }

        // A filament card is also clickable, so only accept a real menu/list
        // choice. This prevents changing the wrong model filament by accident.
        return best != null && bestRank <= 1 && Invoke(best);
    }

    public static string SetOption(
        IntPtr topWindow,
        string dialogName,
        string[] labelNames,
        bool enabled)
    {
        IAccessible dialog = FindDialog(topWindow, dialogName);
        if (dialog == null) return "missing-dialog";

        List<Entry> entries = Flatten(dialog);
        int labelIndex = FindOptionLabel(entries, labelNames);
        if (labelIndex < 0) return "missing-label";

        string desired = enabled ? "On" : "Off";
        for (int index = labelIndex + 1; index < entries.Count; index++)
        {
            Entry entry = entries[index];
            if (IsOptionLabel(entry.Name)) break;
            if (entry.Role != ROLE_SYSTEM_RADIOBUTTON || !EqualName(entry.Name, desired))
                continue;
            if (IsSelected(entry)) return "already-selected";
            return Invoke(entry) ? "selected" : "invoke-failed";
        }
        return "missing-choice";
    }

    public static string GetOptionState(
        IntPtr topWindow,
        string dialogName,
        string[] labelNames)
    {
        IAccessible dialog = FindDialog(topWindow, dialogName);
        if (dialog == null) return "missing-dialog";

        List<Entry> entries = Flatten(dialog);
        int labelIndex = FindOptionLabel(entries, labelNames);
        if (labelIndex < 0) return "missing-label";

        bool sawChoice = false;
        for (int index = labelIndex + 1; index < entries.Count; index++)
        {
            Entry entry = entries[index];
            if (IsOptionLabel(entry.Name)) break;
            if (entry.Role != ROLE_SYSTEM_RADIOBUTTON) continue;
            if (!EqualName(entry.Name, "On") && !EqualName(entry.Name, "Off")) continue;
            sawChoice = true;
            if (IsSelected(entry)) return Fold(entry.Name).ToLowerInvariant();
        }
        return sawChoice ? "unknown" : "missing-choice";
    }

    public static string[] Dump(IntPtr topWindow)
    {
        List<string> lines = new List<string>();
        foreach (IAccessible root in Roots(topWindow))
        {
            foreach (Entry entry in Flatten(root))
            {
                if (String.IsNullOrWhiteSpace(entry.Name) &&
                    String.IsNullOrWhiteSpace(entry.Action))
                    continue;
                lines.Add(String.Format(
                    "role={0} | name={1} | action={2} | state=0x{3:X}",
                    entry.Role,
                    Clean(entry.Name),
                    Clean(entry.Action),
                    entry.State));
                if (lines.Count >= MaxChildren) return lines.ToArray();
            }
        }
        return lines.ToArray();
    }

    private static IAccessible FindDialog(IntPtr topWindow, string dialogName)
    {
        foreach (IAccessible root in Roots(topWindow))
        {
            HashSet<long> seen = new HashSet<long>();
            IAccessible found = FindDialogRecursive(root, dialogName, 0, seen);
            if (found != null) return found;
        }
        return null;
    }

    private static IAccessible FindDialogRecursive(
        IAccessible accessible,
        string dialogName,
        int depth,
        HashSet<long> seen)
    {
        if (accessible == null || depth > MaxDepth) return null;
        long identity = ComIdentity(accessible);
        if (identity != 0 && !seen.Add(identity)) return null;

        Entry self = MakeEntry(accessible, 0, false);
        if (self.Role == ROLE_SYSTEM_DIALOG && EqualName(self.Name, dialogName))
            return accessible;

        int childCount = SafeChildCount(accessible);
        for (int childId = 1; childId <= childCount; childId++)
        {
            object child = null;
            try { child = accessible.get_accChild(childId); }
            catch { }
            IAccessible childAccessible = child as IAccessible;
            if (childAccessible == null) continue;
            IAccessible found = FindDialogRecursive(
                childAccessible,
                dialogName,
                depth + 1,
                seen);
            if (found != null) return found;
        }
        return null;
    }

    private static List<IAccessible> Roots(IntPtr topWindow)
    {
        List<IAccessible> roots = new List<IAccessible>();
        if (topWindow == IntPtr.Zero) return roots;

        List<IntPtr> windows = new List<IntPtr>();
        windows.Add(topWindow);
        EnumWindowsProc callback = delegate(IntPtr child, IntPtr unused)
        {
            if (child != IntPtr.Zero) windows.Add(child);
            return true;
        };
        EnumChildWindows(topWindow, callback, IntPtr.Zero);

        foreach (IntPtr window in windows)
        {
            if (window == IntPtr.Zero) continue;
            IAccessible accessible;
            Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
            int result = AccessibleObjectFromWindow(
                window,
                OBJID_CLIENT,
                ref iid,
                out accessible);
            if (result >= 0 && accessible != null) roots.Add(accessible);
        }
        return roots;
    }

    private static List<Entry> Flatten(IAccessible root)
    {
        List<Entry> entries = new List<Entry>();
        HashSet<long> seen = new HashSet<long>();
        Walk(root, 0, false, entries, seen);
        return entries;
    }

    private static void Walk(
        IAccessible accessible,
        int depth,
        bool inChoiceContainer,
        List<Entry> entries,
        HashSet<long> seen)
    {
        if (accessible == null || depth > MaxDepth || entries.Count >= MaxChildren) return;
        long identity = ComIdentity(accessible);
        if (identity != 0 && !seen.Add(identity)) return;

        Entry self = MakeEntry(accessible, 0, inChoiceContainer);
        entries.Add(self);
        bool childInChoice = inChoiceContainer || IsChoiceContainer(self.Role);

        int childCount = SafeChildCount(accessible);
        for (int childId = 1; childId <= childCount; childId++)
        {
            object child = null;
            try { child = accessible.get_accChild(childId); }
            catch { }

            IAccessible childAccessible = child as IAccessible;
            if (childAccessible != null)
            {
                Walk(childAccessible, depth + 1, childInChoice, entries, seen);
            }
            else
            {
                entries.Add(MakeEntry(accessible, childId, childInChoice));
            }
            if (entries.Count >= MaxChildren) return;
        }
    }

    private static List<Entry> FilamentCards(IAccessible dialog)
    {
        List<Entry> entries = Flatten(dialog);
        List<Entry> cards = new List<Entry>();
        bool afterPrinter = false;

        foreach (Entry entry in entries)
        {
            if (entry.Name.IndexOf("chevron_down", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                afterPrinter = true;
                continue;
            }
            if (EqualName(entry.Name, "Print Options")) break;
            if (!afterPrinter || entry.Role != ROLE_SYSTEM_GROUPING ||
                String.IsNullOrWhiteSpace(entry.Action))
                continue;
            if (Regex.IsMatch(entry.Name.Trim(), @"^(Ext|[0-9]+)(?:\s|$)", RegexOptions.IgnoreCase))
                cards.Add(entry);
        }
        return cards;
    }

    private static bool IsHiddenOrUnavailable(Entry entry)
    {
        return entry == null ||
            (entry.State & STATE_SYSTEM_UNAVAILABLE) != 0 ||
            (entry.State & STATE_SYSTEM_INVISIBLE) != 0 ||
            (entry.State & STATE_SYSTEM_OFFSCREEN) != 0;
    }

    private static string PrinterNameFromSelector(string value)
    {
        string result = Regex.Replace(
            value ?? String.Empty,
            @"chevron_down|expand_more|arrow_drop_down",
            " ",
            RegexOptions.IgnoreCase);
        return Regex.Replace(result, @"\s+", " ").Trim();
    }

    private static int ChoiceRank(Entry entry)
    {
        if (IsHiddenOrUnavailable(entry) ||
            String.IsNullOrWhiteSpace(entry.Action))
            return 100;
        if (entry.Role == ROLE_SYSTEM_MENUITEM || entry.Role == ROLE_SYSTEM_LISTITEM)
            return 0;
        if (entry.InChoiceContainer)
            return 1;
        if (entry.Role == ROLE_SYSTEM_GROUPING ||
            entry.Role == ROLE_SYSTEM_COMBOBOX ||
            entry.Role == ROLE_SYSTEM_DROPLIST)
            return 2;
        return 3;
    }

    private static bool ChoiceNameMatches(string actual, string desired)
    {
        if (String.IsNullOrWhiteSpace(actual) || String.IsNullOrWhiteSpace(desired))
            return false;
        string left = Fold(Clean(actual));
        string right = Fold(Clean(desired));
        return String.Equals(left, right, StringComparison.OrdinalIgnoreCase) ||
            left.StartsWith(right + " ", StringComparison.OrdinalIgnoreCase);
    }

    private static bool SlotNameMatches(string actual, string desired)
    {
        if (String.IsNullOrWhiteSpace(actual) || String.IsNullOrWhiteSpace(desired))
            return false;
        string name = actual.Trim();
        string slot = desired.Trim();
        if (String.Equals(slot, "Ext", StringComparison.OrdinalIgnoreCase))
            return Regex.IsMatch(name, @"^Ext(?:\s|$)", RegexOptions.IgnoreCase);
        return Regex.IsMatch(name, @"^(?:A)?" + Regex.Escape(slot) + @"(?:\s|$)", RegexOptions.IgnoreCase);
    }

    private static bool IsChoiceContainer(int role)
    {
        return role == ROLE_SYSTEM_MENUPOPUP ||
            role == ROLE_SYSTEM_LIST ||
            role == ROLE_SYSTEM_OUTLINE ||
            role == ROLE_SYSTEM_COMBOBOX ||
            role == ROLE_SYSTEM_DROPLIST;
    }

    private static bool IsOptionLabel(string name)
    {
        string[] labels = {
            "Timelapse",
            "Bed leveling",
            "Nivelamento da mesa",
            "Nivelamento automatico",
            "Flow dynamic calibration",
            "Dynamic flow calibration",
            "Calibracao dinamica de fluxo"
        };
        return AnyEqual(name, labels);
    }

    private static int FindOptionLabel(List<Entry> entries, string[] labelNames)
    {
        for (int index = 0; index < entries.Count; index++)
            if (AnyEqual(entries[index].Name, labelNames)) return index;
        return -1;
    }

    private static bool IsSelected(Entry entry)
    {
        if ((entry.State & STATE_SYSTEM_CHECKED) != 0) return true;
        string action = entry.Action ?? String.Empty;
        return action.IndexOf("uncheck", StringComparison.OrdinalIgnoreCase) >= 0 ||
            action.IndexOf("deselect", StringComparison.OrdinalIgnoreCase) >= 0 ||
            action.IndexOf("desmarcar", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static bool Invoke(Entry entry)
    {
        if (entry == null || (entry.State & STATE_SYSTEM_UNAVAILABLE) != 0)
            return false;
        try
        {
            entry.Owner.accDoDefaultAction(entry.ChildId);
            return true;
        }
        catch { return false; }
    }

    private static Entry MakeEntry(
        IAccessible owner,
        int childId,
        bool inChoiceContainer)
    {
        object id = childId;
        Entry entry = new Entry();
        entry.Owner = owner;
        entry.ChildId = childId;
        entry.Name = SafeString(delegate { return owner.get_accName(id); });
        entry.Action = SafeString(delegate { return owner.get_accDefaultAction(id); });
        entry.Role = SafeInt(delegate { return owner.get_accRole(id); });
        entry.State = SafeInt(delegate { return owner.get_accState(id); });
        entry.InChoiceContainer = inChoiceContainer;
        return entry;
    }

    private static int SafeChildCount(IAccessible accessible)
    {
        try
        {
            int count = accessible.accChildCount;
            if (count < 0) return 0;
            return Math.Min(count, MaxChildren);
        }
        catch { return 0; }
    }

    private static string SafeString(Func<string> getter)
    {
        try { return (getter() ?? String.Empty).Trim(); }
        catch { return String.Empty; }
    }

    private static int SafeInt(Func<object> getter)
    {
        try
        {
            object value = getter();
            return value == null ? 0 : Convert.ToInt32(value);
        }
        catch { return 0; }
    }

    private static bool EqualName(string actual, string expected)
    {
        return String.Equals(
            Fold(actual),
            Fold(expected),
            StringComparison.OrdinalIgnoreCase);
    }

    private static string Fold(string value)
    {
        string normalized = (value ?? String.Empty).Normalize(NormalizationForm.FormD);
        StringBuilder builder = new StringBuilder(normalized.Length);
        foreach (char item in normalized)
        {
            if (System.Globalization.CharUnicodeInfo.GetUnicodeCategory(item) !=
                System.Globalization.UnicodeCategory.NonSpacingMark)
                builder.Append(item);
        }
        return builder.ToString().Normalize(NormalizationForm.FormC).Trim();
    }

    private static bool AnyEqual(string actual, string[] expected)
    {
        if (expected == null) return false;
        foreach (string item in expected)
            if (EqualName(actual, item)) return true;
        return false;
    }

    private static long ComIdentity(object value)
    {
        IntPtr pointer = IntPtr.Zero;
        try
        {
            pointer = Marshal.GetIUnknownForObject(value);
            return pointer.ToInt64();
        }
        catch { return 0; }
        finally
        {
            if (pointer != IntPtr.Zero) Marshal.Release(pointer);
        }
    }

    private static string Clean(string value)
    {
        if (String.IsNullOrEmpty(value)) return String.Empty;
        return value.Replace("\r", " ").Replace("\n", " ").Replace("|", "/").Trim();
    }
}
'@
    Add-Type -TypeDefinition $msaaSource -ReferencedAssemblies @(
        [Accessibility.IAccessible].Assembly.Location
    )
}

if ($CompileOnly) { exit 0 }

$script:BridgeRoot = Join-Path $Root 'BaleiaConnect'
$script:PendingDir = Join-Path $script:BridgeRoot 'Fila'
$script:WorkingDir = Join-Path $script:BridgeRoot 'Processando'
$script:ErrorDir = Join-Path $script:BridgeRoot 'Erros'
$script:ReceiptDir = Join-Path $script:BridgeRoot 'Comprovantes'
$script:RuntimeDir = Join-Path $script:BridgeRoot 'Runtime'
$script:LogPath = Join-Path $script:RuntimeDir 'helper.log'
$script:StatusPath = Join-Path $script:RuntimeDir 'connect.status'
$script:StopRequested = $false
$script:ConnectExecutable = $null
$script:NotifyIcon = $null
$script:ManualVisible = $false
$script:LoginVisible = $false
$script:ConnectionStatus = 'checking'
$script:CandidateStatus = 'checking'
$script:CandidateSince = [DateTime]::UtcNow
$script:LastStatusWrite = [DateTime]::MinValue
$script:NextConnectStart = [DateTime]::MinValue
$script:SendMayHaveBeenInvoked = $false
$script:QueueBlocked = $false
$script:ActiveReceiptPath = ''
$script:ActiveFileHash = ''
$script:ScreenReaderChanged = $false
$script:ScreenReaderWasEnabled = $true

@($script:PendingDir, $script:WorkingDir, $script:ErrorDir, $script:ReceiptDir, $script:RuntimeDir) | ForEach-Object {
    [void](New-Item -ItemType Directory -Force -Path $_)
}

function Write-BaleiaLog {
    param([string]$Message)
    try {
        $line = '{0:u} {1}' -f [DateTime]::UtcNow, $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch {}
}

function Write-JobAudit {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($script:ActiveReceiptPath)) { return }
    try {
        $line = '{0:u} {1}' -f [DateTime]::UtcNow, $Message
        Add-Content -LiteralPath $script:ActiveReceiptPath -Value $line -Encoding UTF8
    } catch {}
}

function Write-FieldAudit {
    param(
        [string]$Field,
        [string]$Expected,
        [string]$Before,
        [string]$Action,
        [string]$After,
        [string]$Result
    )
    Write-JobAudit ('CAMPO: ' + $Field)
    Write-JobAudit ('  Esperado: ' + $Expected)
    Write-JobAudit ('  Antes: ' + $Before)
    Write-JobAudit ('  Acao: ' + $Action)
    Write-JobAudit ('  Depois: ' + $After)
    Write-JobAudit ('  Resultado: ' + $Result)
    Write-BaleiaLog ($Field + ' => ' + $Result + ' (esperado=' + $Expected + '; depois=' + $After + ')')
}

function Get-SafeProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    try {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    } catch {
        return $null
    }
}

function Start-JobAudit {
    param($Manifest, [string]$GcodePath)
    $jobId = [string](Get-SafeProperty $Manifest 'job_id')
    if ([string]::IsNullOrWhiteSpace($jobId)) {
        $jobId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    }
    $script:ActiveReceiptPath = Join-Path $script:ReceiptDir ($jobId + '.txt')
    $connectVersion = 'desconhecida'
    try {
        if ($script:ConnectExecutable -and (Test-Path -LiteralPath $script:ConnectExecutable)) {
            $connectVersion = [string](Get-Item -LiteralPath $script:ConnectExecutable).VersionInfo.FileVersion
        }
    } catch {}
    @(
        'BALEIA ORCA VR005 - COMPROVANTE DE ENVIO'
        ('Job: ' + $jobId)
        ('Arquivo: ' + [string](Get-SafeProperty $Manifest 'display_name'))
        ('Fila: ' + $GcodePath)
        ('Impressora pedida: ' + [string](Get-SafeProperty (Get-SafeProperty $Manifest 'printer') 'name'))
        ('Bambu Connect: ' + $connectVersion)
        'STATUS: VERIFICANDO'
        ''
    ) | Set-Content -LiteralPath $script:ActiveReceiptPath -Encoding UTF8
}

function Test-BaleiaRunning {
    return [bool](Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)
}

function Show-StatusToast {
    param([string]$Message, [bool]$Connected)
    try { [BaleiaStatusToast]::Display($Message, $Connected) } catch {}
}

function Write-ConnectionStatusFile {
    param([string]$Status, [switch]$Force)
    if (-not $Force -and
        $Status -eq $script:ConnectionStatus -and
        ([DateTime]::UtcNow - $script:LastStatusWrite).TotalSeconds -lt 4) {
        return
    }
    try {
        $partial = $script:StatusPath + '.partial'
        [IO.File]::WriteAllText($partial, $Status, [Text.Encoding]::ASCII)
        Move-Item -LiteralPath $partial -Destination $script:StatusPath -Force
        $script:LastStatusWrite = [DateTime]::UtcNow
    } catch {}
}

function Set-ConnectionStatus {
    param([ValidateSet('checking', 'connected', 'disconnected', 'missing', 'error')][string]$Status)
    $changed = $script:ConnectionStatus -ne $Status
    $script:ConnectionStatus = $Status
    Write-ConnectionStatusFile $Status -Force:$changed
    if (-not $changed) { return }

    Write-BaleiaLog ('Connection status: ' + $Status)
    switch ($Status) {
        'connected' {
            Show-StatusToast 'Conectado' $true
            if ($script:LoginVisible) {
                $script:LoginVisible = $false
                if (-not $script:ManualVisible) { Hide-ConnectWindow }
            }
        }
        'disconnected' {
            Show-StatusToast 'Desconectado' $false
            if (-not $script:ManualVisible -and -not $script:LoginVisible) {
                Show-ConnectWindow -ForLogin
            }
        }
        'missing' { Show-StatusToast 'Bambu Connect nao encontrado' $false }
        'error' { Show-StatusToast 'Erro no Bambu Connect' $false }
    }
}

function Get-RawConnectionStatus {
    if (-not $script:ConnectExecutable -or
        -not (Test-Path -LiteralPath $script:ConnectExecutable)) {
        return 'missing'
    }

    $processes = @(Get-ConnectProcesses)
    if ($processes.Count -eq 0) {
        if ([DateTime]::UtcNow -ge $script:NextConnectStart) {
            $script:NextConnectStart = [DateTime]::UtcNow.AddSeconds(5)
            [void](Ensure-ConnectRunning)
        }
        return 'checking'
    }

    $handle = Get-ConnectWindow
    if ($handle -eq [IntPtr]::Zero) { return 'checking' }
    try {
        return [string][BaleiaMsaaBridge]::GetConnectionState($handle)
    } catch {
        Write-BaleiaLog ('Connection check failed: ' + $_.Exception.Message)
        return 'checking'
    }
}

function Update-ConnectionStatus {
    $raw = Get-RawConnectionStatus
    $now = [DateTime]::UtcNow
    if ($raw -ne $script:CandidateStatus) {
        $script:CandidateStatus = $raw
        $script:CandidateSince = $now
    }

    $delaySeconds = switch ($raw) {
        'connected' { 1 }
        'disconnected' { 7 }
        'checking' { 3 }
        default { 0 }
    }
    if (($now - $script:CandidateSince).TotalSeconds -ge $delaySeconds) {
        Set-ConnectionStatus $raw
    } else {
        Write-ConnectionStatusFile $script:ConnectionStatus
    }
}

function Test-ConnectExecutablePath {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $leaf = [IO.Path]::GetFileName($Path)
    return ($leaf -match '^Bambu[ ._-]*Connect\.exe$')
}

function Get-ConnectExecutableFromRegistry {
    $registryKeys = @(
        'Registry::HKEY_CURRENT_USER\Software\Classes\bambu-connect\shell\open\command',
        'Registry::HKEY_CLASSES_ROOT\bambu-connect\shell\open\command'
    )

    foreach ($key in $registryKeys) {
        try {
            $command = (Get-Item -LiteralPath $key).GetValue('')
            if ($command -match '^\s*"([^"]+\.exe)"' -and (Test-ConnectExecutablePath $Matches[1])) {
                return $Matches[1]
            }
            if ($command -match '^\s*([^\s]+\.exe)' -and (Test-ConnectExecutablePath $Matches[1])) {
                return $Matches[1]
            }
        } catch {}
    }
    return $null
}

function Find-ConnectExecutable {
    $fromRegistry = Get-ConnectExecutableFromRegistry
    if ($fromRegistry) { return $fromRegistry }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Bambu Connect\Bambu Connect.exe'),
        (Join-Path $env:LOCALAPPDATA 'Bambu Connect\Bambu Connect.exe'),
        (Join-Path $env:LOCALAPPDATA 'BambuConnect\BambuConnect.exe'),
        (Join-Path $env:ProgramFiles 'Bambu Connect\Bambu Connect.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Bambu Connect\Bambu Connect.exe')
    }
    foreach ($candidate in $candidates) {
        if (Test-ConnectExecutablePath $candidate) { return $candidate }
    }
    return $null
}

function Get-ConnectProcesses {
    $result = @()
    if (-not $script:ConnectExecutable) { return @($result) }

    try {
        foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
            try {
                if ($process.Path -and
                    [string]::Equals(
                        [IO.Path]::GetFullPath($process.Path),
                        [IO.Path]::GetFullPath($script:ConnectExecutable),
                        [StringComparison]::OrdinalIgnoreCase)) {
                    $result += $process
                }
            } catch {}
        }
    } catch {}
    return @($result)
}

function Get-ConnectWindow {
    $processes = @(Get-ConnectProcesses)
    if ($processes.Count -eq 0) { return [IntPtr]::Zero }
    $ids = @($processes | ForEach-Object { [int]$_.Id })
    try {
        return [BaleiaNativeWindow]::FindLargestTopWindow([int[]]$ids)
    } catch {
        return [IntPtr]::Zero
    }
}

function Wait-ConnectWindow {
    param([int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-BaleiaRunning)) { return [IntPtr]::Zero }
        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero) { return $handle }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return [IntPtr]::Zero
}

function Ensure-ConnectRunning {
    $processes = @(Get-ConnectProcesses)
    if ($processes.Count -gt 0) { return $true }
    if (-not $script:ConnectExecutable -or
        -not (Test-Path -LiteralPath $script:ConnectExecutable)) {
        return $false
    }

    try {
        Start-Process -FilePath $script:ConnectExecutable -WindowStyle Hidden | Out-Null
        $handle = Wait-ConnectWindow -TimeoutSeconds 30
        if ($handle -ne [IntPtr]::Zero) {
            [void][BaleiaNativeWindow]::ShowWindowAsync($handle, 0)
            return $true
        }
        return (@(Get-ConnectProcesses).Count -gt 0)
    } catch {
        Write-BaleiaLog ('Bambu Connect could not be opened: ' + $_.Exception.Message)
        return $false
    }
}

function Show-ConnectWindow {
    param([switch]$ForLogin)
    if (-not (Ensure-ConnectRunning)) { return }
    if ($ForLogin) {
        $script:LoginVisible = $true
    } else {
        $script:ManualVisible = $true
    }

    $handle = Wait-ConnectWindow -TimeoutSeconds 10
    if ($handle -ne [IntPtr]::Zero) {
        [void][BaleiaNativeWindow]::ShowWindowAsync($handle, 9)
        [void][BaleiaNativeWindow]::SetForegroundWindow($handle)
    }
}

function Hide-ConnectWindow {
    $handle = Get-ConnectWindow
    if ($handle -ne [IntPtr]::Zero) {
        [void][BaleiaNativeWindow]::ShowWindowAsync($handle, 0)
    }
}

function Protect-ConnectWindow {
    if ($script:ManualVisible -or $script:LoginVisible) { return }
    Hide-ConnectWindow
}

function Stop-Connect {
    foreach ($process in @(Get-ConnectProcesses)) {
        try { $process.CloseMainWindow() | Out-Null } catch {}
    }
    Start-Sleep -Milliseconds 1200
    foreach ($process in @(Get-ConnectProcesses)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Write-MsaaSnapshot {
    param([string]$Stage)
    try {
        $handle = Get-ConnectWindow
        if ($handle -eq [IntPtr]::Zero) { return }
        $lines = @([BaleiaMsaaBridge]::Dump($handle))
        $path = Join-Path $script:RuntimeDir 'msaa.log'
        Add-Content -LiteralPath $path -Value @(
            ('{0:u} MSAA snapshot: {1}' -f [DateTime]::UtcNow, $Stage),
            $lines,
            ''
        ) -Encoding UTF8
    } catch {}
}

function Wait-MsaaDialog {
    param([string]$Name, [int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-BaleiaRunning)) { return $false }
        Protect-ConnectWindow
        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero -and [BaleiaMsaaBridge]::HasDialog($handle, $Name)) { return $true }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Wait-MsaaDialogClosed {
    param([string]$Name, [int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-BaleiaRunning)) { return $false }
        Protect-ConnectWindow
        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero -and -not [BaleiaMsaaBridge]::HasDialog($handle, $Name)) { return $true }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Wait-AndPressMsaaButton {
    param([string]$Name, [int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-BaleiaRunning)) { return $false }
        Protect-ConnectWindow
        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero -and [BaleiaMsaaBridge]::PressExactButton($handle, $Name)) { return $true }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Wait-AndPressMsaaDialogButton {
    param([string]$DialogName, [string]$ButtonName, [int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-BaleiaRunning)) { return $false }
        Protect-ConnectWindow
        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero -and [BaleiaMsaaBridge]::PressButtonInDialog($handle, $DialogName, $ButtonName)) { return $true }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Get-MsaaPrinter {
    Protect-ConnectWindow
    return [string][BaleiaMsaaBridge]::GetSelectedPrinter(
        (Get-ConnectWindow),
        'Send to print')
}

function Test-PrinterSelection {
    param([string]$Actual, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Actual) -or
        [string]::IsNullOrWhiteSpace($Expected) -or
        $Actual -like 'missing-*') {
        return $false
    }
    return [string]::Equals($Actual, $Expected, [StringComparison]::OrdinalIgnoreCase) -or
        $Actual.StartsWith($Expected + ' ', [StringComparison]::OrdinalIgnoreCase)
}

function Set-MsaaPrinter {
    param([string]$PrinterName, [int]$TimeoutSeconds = 15)
    if (-not $PrinterName) { return $false }

    $before = Get-MsaaPrinter
    if (Test-PrinterSelection $before $PrinterName) {
        Write-FieldAudit 'IMPRESSORA' $PrinterName $before 'Nenhuma' $before 'JA ESTAVA OK'
        return $true
    }

    $after = $before
    $action = 'Trocar para ' + $PrinterName
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $attempt = 0
    do {
        $attempt++
        Protect-ConnectWindow
        $status = [BaleiaMsaaBridge]::OpenPrinterPicker(
            (Get-ConnectWindow),
            'Send to print',
            $PrinterName)
        if ($status -eq 'already-selected') {
            Start-Sleep -Milliseconds 300
        } elseif ($status -eq 'opened') {
            $choiceDeadline = [DateTime]::UtcNow.AddSeconds(5)
            do {
                Protect-ConnectWindow
                if ([BaleiaMsaaBridge]::ChoosePrinter((Get-ConnectWindow), $PrinterName)) { break }
                Start-Sleep -Milliseconds 250
            } while ([DateTime]::UtcNow -lt $choiceDeadline)
            Start-Sleep -Milliseconds 700
        } else {
            Write-BaleiaLog ('Printer selector: ' + $status)
        }

        $after = Get-MsaaPrinter
        if (Test-PrinterSelection $after $PrinterName) {
            Write-FieldAudit 'IMPRESSORA' $PrinterName $before ($action + ' / tentativa ' + $attempt) $after 'OK'
            return $true
        }
        Start-Sleep -Milliseconds 350
    } while ($attempt -lt 2 -and [DateTime]::UtcNow -lt $deadline)

    Write-FieldAudit 'IMPRESSORA' $PrinterName $before ($action + ' / ' + $attempt + ' tentativas') $after 'FALHA'
    return $false
}

function Get-ExpectedFilaments {
    param($Manifest)
    $items = @()
    try {
        $mappingObject = Get-SafeProperty $Manifest 'mapping'
        $mapping = @(Get-SafeProperty $mappingObject 'ams')
        $details = @(Get-SafeProperty $mappingObject 'details')
        for ($index = 0; $index -lt $mapping.Count; $index++) {
            $detail = $null
            if ($index -lt $details.Count) { $detail = $details[$index] }
            $filamentType = [string](Get-SafeProperty $detail 'filamentType')
            $filamentId = [string](Get-SafeProperty $detail 'filamentId')
            $sourceColor = [string](Get-SafeProperty $detail 'sourceColor')
            $targetColor = [string](Get-SafeProperty $detail 'targetColor')
            $used = -not [string]::IsNullOrWhiteSpace($filamentType) -or
                -not [string]::IsNullOrWhiteSpace($filamentId) -or
                -not [string]::IsNullOrWhiteSpace($sourceColor)
            if (-not $used) { continue }

            $number = [int]$mapping[$index]
            $slot = if ($number -lt 0 -or $number -ge 254) { 'Ext' } else { [string]($number + 1) }
            $items += [PSCustomObject]@{
                Slot = $slot
                FilamentType = $filamentType
                SourceColor = $sourceColor
                TargetColor = $targetColor
            }
        }
    } catch {
        Write-BaleiaLog ('Could not read filament mapping: ' + $_.Exception.Message)
        return @()
    }
    return @($items)
}

function Get-ExpectedAmsSlots {
    param($Manifest)
    return @(Get-ExpectedFilaments $Manifest | ForEach-Object { [string]$_.Slot })
}

function Get-FilamentCardSlot {
    param([string]$CardName)
    if ($CardName -match '^Ext(?:\s|$)') { return 'Ext' }
    if ($CardName -match '^(?:A)?([0-9]+)(?:\s|$)') { return [string]$Matches[1] }
    return ''
}

function Wait-MsaaFilamentCards {
    param([int]$ExpectedCount, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Protect-ConnectWindow
        $cards = @([BaleiaMsaaBridge]::GetFilamentCards(
            (Get-ConnectWindow),
            'Send to print'))
        if ($cards.Count -eq $ExpectedCount) { return @($cards) }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return @($cards)
}

function Set-MsaaFilamentMapping {
    param($Manifest)
    $expected = @(Get-ExpectedFilaments $Manifest)
    if ($expected.Count -eq 0) {
        Write-FieldAudit 'FILAMENTOS' 'Sem mapeamento informado' 'Sem dados' 'Nenhuma' 'Sem dados' 'JA ESTAVA OK'
        return $true
    }

    $cards = @(Wait-MsaaFilamentCards $expected.Count 12)
    if ($cards.Count -ne $expected.Count) {
        Write-FieldAudit 'QUANTIDADE DE FILAMENTOS' ([string]$expected.Count) ([string]$cards.Count) 'Ler cartoes do Connect' ([string]$cards.Count) 'FALHA'
        return $false
    }

    for ($index = 0; $index -lt $expected.Count; $index++) {
        $item = $expected[$index]
        $wanted = [string]$item.Slot
        $beforeCard = [string]$cards[$index]
        $current = Get-FilamentCardSlot $beforeCard
        $description = $wanted + ' / ' + [string]$item.FilamentType +
            ' / modelo ' + [string]$item.SourceColor +
            ' / carretel ' + [string]$item.TargetColor

        if ([string]::Equals($current, $wanted, [StringComparison]::OrdinalIgnoreCase)) {
            Write-FieldAudit ('FILAMENTO ' + ($index + 1)) $description $beforeCard 'Nenhuma' $beforeCard 'JA ESTAVA OK'
            continue
        }

        $afterCard = $beforeCard
        $action = 'Selecionar ' + $wanted
        $changed = $false
        for ($attempt = 1; $attempt -le 2 -and -not $changed; $attempt++) {
            Protect-ConnectWindow
            if (-not [BaleiaMsaaBridge]::OpenFilamentCard(
                (Get-ConnectWindow),
                'Send to print',
                $index)) {
                Start-Sleep -Milliseconds 300
                continue
            }
            Start-Sleep -Milliseconds 350

            $chosen = $false
            $choiceDeadline = [DateTime]::UtcNow.AddSeconds(5)
            do {
                Protect-ConnectWindow
                $chosen = [BaleiaMsaaBridge]::ChooseFilamentSlot(
                    (Get-ConnectWindow),
                    $wanted)
                if (-not $chosen) { Start-Sleep -Milliseconds 250 }
            } while (-not $chosen -and [DateTime]::UtcNow -lt $choiceDeadline)

            if ($chosen) {
                Start-Sleep -Milliseconds 650
                $cards = @(Wait-MsaaFilamentCards $expected.Count 5)
                if ($cards.Count -eq $expected.Count) {
                    $afterCard = [string]$cards[$index]
                    $afterSlot = Get-FilamentCardSlot $afterCard
                    $changed = [string]::Equals(
                        $afterSlot,
                        $wanted,
                        [StringComparison]::OrdinalIgnoreCase)
                }
            }
        }

        if (-not $changed) {
            Write-FieldAudit ('FILAMENTO ' + ($index + 1)) $description $beforeCard $action $afterCard 'FALHA'
            return $false
        }
        Write-FieldAudit ('FILAMENTO ' + ($index + 1)) $description $beforeCard $action $afterCard 'OK'
    }
    return $true
}

function Get-MsaaOptionState {
    param([string[]]$Labels)
    Protect-ConnectWindow
    return [string][BaleiaMsaaBridge]::GetOptionState(
        (Get-ConnectWindow),
        'Send to print',
        $Labels)
}

function Set-MsaaOption {
    param([string]$Field, [string[]]$Labels, [bool]$Enabled)
    $wanted = if ($Enabled) { 'on' } else { 'off' }
    $before = Get-MsaaOptionState $Labels
    if ([string]::Equals($before, $wanted, [StringComparison]::OrdinalIgnoreCase)) {
        Write-FieldAudit $Field $wanted $before 'Nenhuma' $before 'JA ESTAVA OK'
        return $true
    }

    $after = $before
    $actions = @()
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Protect-ConnectWindow
        $status = [BaleiaMsaaBridge]::SetOption(
            (Get-ConnectWindow),
            'Send to print',
            $Labels,
            $Enabled)
        $actions += ($status + ' tentativa ' + $attempt)
        Start-Sleep -Milliseconds 500
        $after = Get-MsaaOptionState $Labels
        if ([string]::Equals($after, $wanted, [StringComparison]::OrdinalIgnoreCase)) {
            Write-FieldAudit $Field $wanted $before ($actions -join ' / ') $after 'OK'
            return $true
        }
    }

    Write-FieldAudit $Field $wanted $before ($actions -join ' / ') $after 'FALHA'
    return $false
}

function Test-FinalOption {
    param([string]$Field, [string[]]$Labels, [bool]$Enabled)
    $wanted = if ($Enabled) { 'on' } else { 'off' }
    $actual = Get-MsaaOptionState $Labels
    $result = if ([string]::Equals($actual, $wanted, [StringComparison]::OrdinalIgnoreCase)) { 'OK' } else { 'FALHA' }
    Write-FieldAudit ('FINAL ' + $Field) $wanted $actual 'Somente conferir' $actual $result
    return ($result -eq 'OK')
}

function Test-FinalConnectState {
    param($Manifest, [string]$GcodePath)
    $allOk = $true

    $printerName = [string](Get-SafeProperty (Get-SafeProperty $Manifest 'printer') 'name')
    $actualPrinter = Get-MsaaPrinter
    $printerOk = Test-PrinterSelection $actualPrinter $printerName
    Write-FieldAudit 'FINAL IMPRESSORA' $printerName $actualPrinter 'Somente conferir' $actualPrinter $(if ($printerOk) { 'OK' } else { 'FALHA' })
    if (-not $printerOk) { $allOk = $false }

    $expected = @(Get-ExpectedFilaments $Manifest)
    $cards = @(Wait-MsaaFilamentCards $expected.Count 5)
    if ($cards.Count -ne $expected.Count) {
        Write-FieldAudit 'FINAL QUANTIDADE DE FILAMENTOS' ([string]$expected.Count) ([string]$cards.Count) 'Somente conferir' ([string]$cards.Count) 'FALHA'
        $allOk = $false
    } else {
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $wanted = [string]$expected[$index].Slot
            $card = [string]$cards[$index]
            $actual = Get-FilamentCardSlot $card
            $slotOk = [string]::Equals($actual, $wanted, [StringComparison]::OrdinalIgnoreCase)
            Write-FieldAudit ('FINAL FILAMENTO ' + ($index + 1)) $wanted $card 'Somente conferir' $card $(if ($slotOk) { 'OK' } else { 'FALHA' })
            if (-not $slotOk) { $allOk = $false }
        }
    }

    $options = Get-SafeProperty $Manifest 'options'
    if (-not (Test-FinalOption 'TIMELAPSE' @('Timelapse') ([bool](Get-SafeProperty $options 'timelapse')))) { $allOk = $false }
    if (-not (Test-FinalOption 'CALIBRACAO DE FLUXO' @('Flow dynamic calibration','Dynamic flow calibration','Calibracao dinamica de fluxo') ([bool](Get-SafeProperty $options 'flow_calibration')))) { $allOk = $false }
    if (-not (Test-FinalOption 'NIVELAMENTO' @('Bed leveling','Nivelamento da mesa','Nivelamento automatico') ([bool](Get-SafeProperty $options 'bed_leveling')))) { $allOk = $false }

    $currentHash = ''
    try { $currentHash = (Get-FileHash -LiteralPath $GcodePath -Algorithm SHA256).Hash } catch {}
    $hashOk = -not [string]::IsNullOrWhiteSpace($script:ActiveFileHash) -and
        [string]::Equals($currentHash, $script:ActiveFileHash, [StringComparison]::OrdinalIgnoreCase)
    Write-FieldAudit 'FINAL ARQUIVO SHA256' $script:ActiveFileHash $currentHash 'Ler novamente' $currentHash $(if ($hashOk) { 'OK' } else { 'FALHA' })
    if (-not $hashOk) { $allOk = $false }

    $connection = Get-RawConnectionStatus
    $connectionOk = $connection -eq 'connected'
    Write-FieldAudit 'FINAL CONEXAO' 'connected' $connection 'Somente conferir' $connection $(if ($connectionOk) { 'OK' } else { 'FALHA' })
    if (-not $connectionOk) { $allOk = $false }

    return $allOk
}

function Invoke-ConnectPrintFlow {
    param($Manifest, [string]$GcodePath)
    $script:SendMayHaveBeenInvoked = $false
    if (-not (Ensure-ConnectRunning)) { throw 'Bambu Connect nao foi encontrado ou nao abriu.' }
    if ((Get-RawConnectionStatus) -ne 'connected') { throw 'Bambu Connect esta desconectado. Faca login antes de enviar.' }

    $encodedPath = [Uri]::EscapeDataString($GcodePath)
    $encodedName = [Uri]::EscapeDataString([string]$Manifest.display_name)
    $uri = 'bambu-connect://import-file?path={0}&name={1}&version=1.0.0' -f $encodedPath, $encodedName
    # Call only the verified executable. Windows never resolves this URI through another application.
    Start-Process -FilePath $script:ConnectExecutable -ArgumentList @($uri) -WindowStyle Hidden | Out-Null
    $handle = Wait-ConnectWindow -TimeoutSeconds 30
    if ($handle -eq [IntPtr]::Zero) { throw 'A janela do Bambu Connect nao foi localizada.' }
    Protect-ConnectWindow

    if (-not (Wait-AndPressMsaaDialogButton 'Import file' 'confirm' 45)) {
        Write-MsaaSnapshot 'import confirm not found'
        throw 'O botao de importacao do Bambu Connect nao foi localizado.'
    }
    if (-not (Wait-MsaaDialogClosed 'Import file' 20)) {
        Write-MsaaSnapshot 'import dialog did not close'
        throw 'O Bambu Connect nao concluiu a importacao do arquivo.'
    }
    Write-BaleiaLog ('Import accepted for ' + $Manifest.job_id)
    Write-JobAudit 'IMPORTACAO: ACEITA PELO CONNECT'

    if (-not (Wait-AndPressMsaaButton 'Print' 60)) {
        Write-MsaaSnapshot 'page Print not found'
        throw 'O botao Print do Bambu Connect nao foi localizado.'
    }
    Write-BaleiaLog ('Print dialog requested for ' + $Manifest.job_id)
    if (-not (Wait-MsaaDialog 'Send to print' 30)) {
        Write-MsaaSnapshot 'Send to print dialog not found'
        throw 'A janela final de envio do Bambu Connect nao apareceu.'
    }
    Protect-ConnectWindow

    $printerName = [string]$Manifest.printer.name
    if (-not (Set-MsaaPrinter $printerName 15)) {
        Write-MsaaSnapshot 'printer selection failed'
        throw ('A impressora nao foi confirmada no Connect: ' + $printerName)
    }
    if (-not (Set-MsaaFilamentMapping $Manifest)) {
        Write-MsaaSnapshot 'filament mapping failed'
        throw 'O mapeamento de filamentos nao foi confirmado no Connect.'
    }
    if (-not (Set-MsaaOption 'TIMELAPSE' @('Timelapse') ([bool]$Manifest.options.timelapse))) { throw 'A opcao Timelapse nao foi confirmada no Connect.' }
    if (-not (Set-MsaaOption 'CALIBRACAO DE FLUXO' @('Flow dynamic calibration','Dynamic flow calibration','Calibracao dinamica de fluxo') ([bool]$Manifest.options.flow_calibration))) { throw 'A calibracao dinamica de fluxo nao foi confirmada no Connect.' }
    if (-not (Set-MsaaOption 'NIVELAMENTO' @('Bed leveling','Nivelamento da mesa','Nivelamento automatico') ([bool]$Manifest.options.bed_leveling))) { throw 'O nivelamento da mesa nao foi confirmado no Connect.' }

    Write-JobAudit 'CONFERENCIA FINAL: INICIO'
    if (-not (Test-FinalConnectState $Manifest $GcodePath)) {
        Write-MsaaSnapshot 'final verification failed'
        throw 'A conferencia final encontrou divergencia. O envio foi bloqueado.'
    }
    Write-JobAudit 'CONFERENCIA FINAL: OK'

    # The final Send has exactly one attempt and never retries.
    $handle = Get-ConnectWindow
    if ($handle -eq [IntPtr]::Zero) { throw 'A janela do Bambu Connect desapareceu antes do envio.' }
    $script:SendMayHaveBeenInvoked = $true
    if (-not [BaleiaMsaaBridge]::PressButtonInDialog($handle, 'Send to print', 'confirm')) {
        Write-MsaaSnapshot 'final Send unavailable'
        throw 'O botao Send nao esta disponivel. Verifique se a impressora esta ocupada.'
    }
    Write-BaleiaLog ('Send invoked exactly once for ' + $Manifest.job_id + ' on ' + $printerName)
    Write-JobAudit ('SEND: ACIONADO UMA VEZ PARA ' + $printerName)
    if (-not (Wait-MsaaDialogClosed 'Send to print' 45)) {
        $script:QueueBlocked = $true
        Write-MsaaSnapshot 'final Send result uncertain'
        throw 'O estado do envio ficou incerto. Confira a impressora antes de repetir.'
    }
    Write-JobAudit 'RESULTADO FINAL: ACEITO PELO CONNECT'
    Write-BaleiaLog ('Connect accepted job ' + $Manifest.job_id)
    Show-StatusToast ('Envio conferido: ' + $printerName) $true
    Protect-ConnectWindow
}

function Move-JobToError {
    param([string]$ManifestPath, [string]$GcodePath, [string]$Message)
    if ($script:SendMayHaveBeenInvoked) {
        $script:QueueBlocked = $true
        $Message = 'ATENCAO: o Send pode ter sido acionado. Nao repita este trabalho. ' + $Message
    }
    Write-JobAudit ('RESULTADO FINAL: BLOQUEADO - ' + $Message)
    try {
        $manifestName = [IO.Path]::GetFileName($ManifestPath)
        $baseName = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($manifestName))
        if (Test-Path -LiteralPath $ManifestPath) {
            Move-Item -LiteralPath $ManifestPath -Destination (Join-Path $script:ErrorDir $manifestName) -Force -ErrorAction SilentlyContinue
        }
        if ($GcodePath -and (Test-Path -LiteralPath $GcodePath)) {
            Move-Item -LiteralPath $GcodePath -Destination (Join-Path $script:ErrorDir ([IO.Path]::GetFileName($GcodePath))) -Force -ErrorAction SilentlyContinue
        }
        Set-Content -LiteralPath (Join-Path $script:ErrorDir ($baseName + '.error.txt')) -Value $Message -Encoding UTF8
    } catch {}
    Write-BaleiaLog ('Job stopped safely: ' + $Message)
    Show-StatusToast 'Falha no envio. Veja Erros e Comprovantes.' $false
    if (-not $script:SendMayHaveBeenInvoked -and (Test-BaleiaRunning)) {
        Stop-Connect
        Start-Sleep -Milliseconds 500
        [void](Ensure-ConnectRunning)
        Protect-ConnectWindow
    }
}

function Process-NextJob {
    if ($script:QueueBlocked -or $script:ConnectionStatus -ne 'connected') { return }
    $next = @(Get-ChildItem -LiteralPath $script:PendingDir -Filter '*.job.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc) | Select-Object -First 1
    if (-not $next) { return }
    $workingManifest = Join-Path $script:WorkingDir $next.Name
    try { Move-Item -LiteralPath $next.FullName -Destination $workingManifest -ErrorAction Stop } catch { return }

    $gcodePath = ''
    $script:ActiveReceiptPath = ''
    $script:ActiveFileHash = ''
    try {
        $manifest = Get-Content -LiteralPath $workingManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $sourceGcode = [string]$manifest.file
        Start-JobAudit $manifest $sourceGcode
        if (-not (Test-Path -LiteralPath $sourceGcode)) { throw 'O arquivo G-code 3MF da fila desapareceu.' }

        $sourceHash = (Get-FileHash -LiteralPath $sourceGcode -Algorithm SHA256).Hash
        $sourceLength = [string](Get-Item -LiteralPath $sourceGcode).Length
        $gcodePath = Join-Path $script:WorkingDir ([IO.Path]::GetFileName($sourceGcode))
        Move-Item -LiteralPath $sourceGcode -Destination $gcodePath -ErrorAction Stop
        $workingHash = (Get-FileHash -LiteralPath $gcodePath -Algorithm SHA256).Hash
        $hashOk = [string]::Equals($sourceHash, $workingHash, [StringComparison]::OrdinalIgnoreCase)
        Write-FieldAudit 'ARQUIVO GCODE3MF' ($sourceHash + ' / ' + $sourceLength + ' bytes') $sourceHash 'Mover da Fila para Processando' $workingHash $(if ($hashOk) { 'OK' } else { 'FALHA' })
        if (-not $hashOk) { throw 'O arquivo mudou dentro da fila. O envio foi bloqueado.' }

        $script:ActiveFileHash = $workingHash
        Write-BaleiaLog ('Processing ' + $manifest.job_id + ' for ' + $manifest.printer.name)
        Invoke-ConnectPrintFlow $manifest $gcodePath
        Remove-Item -LiteralPath $gcodePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $workingManifest -Force -ErrorAction SilentlyContinue
        Write-BaleiaLog ('Completed ' + $manifest.job_id)
    } catch {
        if (Test-BaleiaRunning) { Move-JobToError $workingManifest $gcodePath $_.Exception.Message }
    } finally {
        $script:ActiveReceiptPath = ''
        $script:ActiveFileHash = ''
    }
}

function Recover-InterruptedJobs {
    $interrupted = @(Get-ChildItem -LiteralPath $script:WorkingDir -Filter '*.job.json' -File -ErrorAction SilentlyContinue)
    if ($interrupted.Count -eq 0) { return }
    foreach ($manifest in $interrupted) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($manifest.Name))
        $gcodePath = Join-Path $script:WorkingDir ($baseName + '.gcode.3mf')
        $message = 'Trabalho interrompido antes da confirmacao do resultado. Confira a impressora antes de repetir.'
        try {
            Move-Item -LiteralPath $manifest.FullName -Destination (Join-Path $script:ErrorDir $manifest.Name) -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $gcodePath) {
                Move-Item -LiteralPath $gcodePath -Destination (Join-Path $script:ErrorDir ([IO.Path]::GetFileName($gcodePath))) -Force -ErrorAction SilentlyContinue
            }
            Set-Content -LiteralPath (Join-Path $script:ErrorDir ($baseName + '.error.txt')) -Value $message -Encoding UTF8
        } catch {}
    }
    $script:QueueBlocked = $true
    Write-BaleiaLog 'Interrupted jobs moved to Erros; queue blocked for this session.'
    Show-StatusToast 'Fila pausada. Confira a pasta Erros.' $false
}

function Remove-StaleFiles {
    $cutoff = [DateTime]::UtcNow.AddHours(-24)
    foreach ($directory in @($script:PendingDir, $script:WorkingDir, $script:ErrorDir)) {
        Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue | Where-Object {
            $_.LastWriteTimeUtc -lt $cutoff
        } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

$createdNew = $false
$mutexName = 'Local\BaleiaConnectHelper_' + $ParentPid
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }

try {
    $script:ConnectExecutable = Find-ConnectExecutable
    Write-ConnectionStatusFile 'checking' -Force

    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    if ($script:ConnectExecutable) {
        try { $script:NotifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:ConnectExecutable) } catch {}
    }
    if (-not $script:NotifyIcon.Icon) { $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Application }
    $script:NotifyIcon.Text = 'Baleia Orca + Bambu Connect'
    $script:NotifyIcon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $openItem = $menu.Items.Add('Abrir Bambu Connect')
    $exitItem = $menu.Items.Add('Fechar Connect e ajudante')
    $openItem.add_Click({ Show-ConnectWindow })
    $exitItem.add_Click({ $script:StopRequested = $true })
    $script:NotifyIcon.ContextMenuStrip = $menu
    $script:NotifyIcon.add_DoubleClick({ Show-ConnectWindow })

    Write-BaleiaLog ('Helper started for Baleia PID ' + $ParentPid)
    Recover-InterruptedJobs

    if (-not $script:ConnectExecutable) {
        Set-ConnectionStatus 'missing'
    } else {
        $script:ScreenReaderWasEnabled = [BaleiaMsaaBridge]::GetScreenReaderFlag()
        if (-not $script:ScreenReaderWasEnabled) {
            [BaleiaMsaaBridge]::SetScreenReaderFlag($true)
            $script:ScreenReaderChanged = $true
        }
        if (-not (Ensure-ConnectRunning)) {
            Set-ConnectionStatus 'error'
        } else {
            Protect-ConnectWindow
        }
    }

    $lastStatusCheck = [DateTime]::MinValue
    $lastCleanup = [DateTime]::MinValue
    while (-not $script:StopRequested) {
        if (-not (Test-BaleiaRunning)) { break }

        if (([DateTime]::UtcNow - $lastStatusCheck).TotalSeconds -ge 2) {
            Update-ConnectionStatus
            $lastStatusCheck = [DateTime]::UtcNow
        }

        $handle = Get-ConnectWindow
        if ($handle -eq [IntPtr]::Zero) {
            $script:ManualVisible = $false
            $script:LoginVisible = $false
        } else {
            $minimized = [BaleiaNativeWindow]::IsIconic($handle)
            $visible = [BaleiaNativeWindow]::IsWindowVisible($handle)
            if (($script:ManualVisible -or $script:LoginVisible) -and ($minimized -or -not $visible)) {
                $script:ManualVisible = $false
                $script:LoginVisible = $false
                Hide-ConnectWindow
            }
        }

        Protect-ConnectWindow
        Process-NextJob
        if (([DateTime]::UtcNow - $lastCleanup).TotalMinutes -ge 15) {
            Remove-StaleFiles
            $lastCleanup = [DateTime]::UtcNow
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
    }
} catch {
    Write-BaleiaLog ('Fatal helper error: ' + $_.Exception.Message)
    Set-ConnectionStatus 'error'
} finally {
    Write-BaleiaLog 'Helper stopping with Baleia.'
    if ($script:ScreenReaderChanged) {
        try { [BaleiaMsaaBridge]::SetScreenReaderFlag($script:ScreenReaderWasEnabled) } catch {}
    }
    Stop-Connect
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
