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

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class BaleiaNativeWindow
{
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
'@

if (-not ('BaleiaMsaaBridge' -as [type])) {
    $msaaSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
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
            if (entry.Name.IndexOf("chevron_down", StringComparison.OrdinalIgnoreCase) < 0)
                continue;
            if (String.IsNullOrWhiteSpace(entry.Action))
                continue;
            if (!String.IsNullOrWhiteSpace(printerName) &&
                entry.Name.IndexOf(printerName.Trim(), StringComparison.OrdinalIgnoreCase) >= 0)
                return "already-selected";
            return Invoke(entry) ? "opened" : "invoke-failed";
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
                if (!ChoiceNameMatches(entry.Name, printerName) ||
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
        int labelIndex = -1;
        for (int index = 0; index < entries.Count; index++)
        {
            if (AnyEqual(entries[index].Name, labelNames))
            {
                labelIndex = index;
                break;
            }
        }
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
        List<IntPtr> windows = new List<IntPtr>();
        windows.Add(topWindow);
        EnumWindowsProc callback = delegate(IntPtr child, IntPtr unused)
        {
            windows.Add(child);
            return true;
        };
        EnumChildWindows(topWindow, callback, IntPtr.Zero);

        List<IAccessible> roots = new List<IAccessible>();
        foreach (IntPtr window in windows)
        {
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

    private static int ChoiceRank(Entry entry)
    {
        if ((entry.State & STATE_SYSTEM_UNAVAILABLE) != 0 ||
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
        string left = actual.Trim();
        string right = desired.Trim();
        return String.Equals(left, right, StringComparison.OrdinalIgnoreCase) ||
            left.StartsWith(right + " ", StringComparison.OrdinalIgnoreCase) ||
            left.IndexOf(right, StringComparison.OrdinalIgnoreCase) >= 0;
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
            (actual ?? String.Empty).Trim(),
            (expected ?? String.Empty).Trim(),
            StringComparison.OrdinalIgnoreCase);
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
$script:RuntimeDir = Join-Path $script:BridgeRoot 'Runtime'
$script:LogPath = Join-Path $script:RuntimeDir 'helper.log'
$script:StopRequested = $false
$script:TrayMode = $false
$script:ConnectExecutable = $null
$script:NotifyIcon = $null
$script:SendMayHaveBeenInvoked = $false

@($script:PendingDir, $script:WorkingDir, $script:ErrorDir, $script:RuntimeDir) | ForEach-Object {
    [void](New-Item -ItemType Directory -Force -Path $_)
}

function Write-BaleiaLog {
    param([string]$Message)
    try {
        $line = '{0:u} {1}' -f [DateTime]::UtcNow, $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch {}
}

function Test-BaleiaRunning {
    return [bool](Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)
}

function Get-ConnectExecutableFromRegistry {
    $registryKeys = @(
        'Registry::HKEY_CURRENT_USER\Software\Classes\bambu-connect\shell\open\command',
        'Registry::HKEY_CLASSES_ROOT\bambu-connect\shell\open\command'
    )

    foreach ($key in $registryKeys) {
        try {
            $command = (Get-Item -LiteralPath $key).GetValue('')
            if ($command -match '^\s*"([^"]+\.exe)"' -and (Test-Path -LiteralPath $Matches[1])) {
                return $Matches[1]
            }
            if ($command -match '^\s*([^\s]+\.exe)' -and (Test-Path -LiteralPath $Matches[1])) {
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
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Get-ConnectProcesses {
    $result = @()
    try {
        foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
            try {
                $titleMatch = $process.MainWindowTitle -like '*Bambu Connect*'
                $nameMatch = $process.ProcessName -match '^Bambu[ ._-]*Connect$'
                $pathMatch = $false
                if ($script:ConnectExecutable -and $process.Path) {
                    $pathMatch = [string]::Equals($process.Path, $script:ConnectExecutable, [StringComparison]::OrdinalIgnoreCase)
                }
                if ($titleMatch -or $nameMatch -or $pathMatch) { $result += $process }
            } catch {}
        }
    } catch {}
    return @($result)
}

function Get-ConnectWindow {
    foreach ($process in (Get-ConnectProcesses)) {
        try {
            $process.Refresh()
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) { return $process.MainWindowHandle }
        } catch {}
    }
    return [IntPtr]::Zero
}

function Wait-ConnectWindow {
    param([int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-BaleiaRunning)) { return [IntPtr]::Zero }
        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero) { return $handle }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return [IntPtr]::Zero
}

function Ensure-ConnectRunning {
    if ((Get-ConnectProcesses).Count -gt 0) { return $true }
    try {
        if ($script:ConnectExecutable -and (Test-Path -LiteralPath $script:ConnectExecutable)) {
            Start-Process -FilePath $script:ConnectExecutable | Out-Null
        } else {
            Start-Process 'bambu-connect://' | Out-Null
        }
        return ((Wait-ConnectWindow -TimeoutSeconds 30) -ne [IntPtr]::Zero)
    } catch {
        Write-BaleiaLog ('Bambu Connect could not be opened: ' + $_.Exception.Message)
        return $false
    }
}

function Show-ConnectWindow {
    $script:TrayMode = $false
    if (-not (Ensure-ConnectRunning)) { return }
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
        $script:TrayMode = $true
    }
}

function Stop-Connect {
    foreach ($process in (Get-ConnectProcesses)) {
        try {
            $process.Refresh()
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                [void][BaleiaNativeWindow]::PostMessage($process.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            } else {
                $process.CloseMainWindow() | Out-Null
            }
        } catch {}
    }
    Start-Sleep -Milliseconds 1200
    foreach ($process in (Get-ConnectProcesses)) {
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
        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero -and [BaleiaMsaaBridge]::HasDialog($handle, $Name)) {
            return $true
        }
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
        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero -and [BaleiaMsaaBridge]::PressExactButton($handle, $Name)) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Wait-AndPressMsaaDialogButton {
    param(
        [string]$DialogName,
        [string]$ButtonName,
        [int]$TimeoutSeconds
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-BaleiaRunning)) { return $false }
        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero -and
            [BaleiaMsaaBridge]::PressButtonInDialog($handle, $DialogName, $ButtonName)) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Set-MsaaPrinter {
    param([string]$PrinterName, [int]$TimeoutSeconds = 15)
    if (-not $PrinterName) { return $false }

    $handle = Get-ConnectWindow
    $status = [BaleiaMsaaBridge]::OpenPrinterPicker(
        $handle,
        'Send to print',
        $PrinterName)
    if ($status -eq 'already-selected') {
        Write-BaleiaLog ('Connect already shows printer ' + $PrinterName)
        return $true
    }
    if ($status -ne 'opened') {
        Write-BaleiaLog ('Printer selector: ' + $status)
        return $false
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ([BaleiaMsaaBridge]::ChoosePrinter((Get-ConnectWindow), $PrinterName)) {
            Write-BaleiaLog ('Connect printer selected: ' + $PrinterName)
            Start-Sleep -Milliseconds 700
            return $true
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Get-ExpectedAmsSlots {
    param($Manifest)
    $slots = @()
    try {
        foreach ($value in @($Manifest.mapping.ams)) {
            $number = [int]$value
            if ($number -lt 0) { $slots += 'Ext' } else { $slots += [string]($number + 1) }
        }
    } catch { return @() }
    return @($slots)
}

function Get-FilamentCardSlot {
    param([string]$CardName)
    if ($CardName -match '^(Ext|[0-9]+)(?:\s|$)') { return [string]$Matches[1] }
    return ''
}

function Wait-MsaaFilamentCards {
    param([int]$ExpectedCount, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
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
    $expected = @(Get-ExpectedAmsSlots $Manifest)
    if ($expected.Count -eq 0) {
        Write-BaleiaLog 'Manifest has no filament mapping to apply.'
        return $true
    }

    $cards = @(Wait-MsaaFilamentCards $expected.Count 12)
    if ($cards.Count -ne $expected.Count) {
        Write-BaleiaLog ('Filament cards found: ' + $cards.Count + '; expected: ' + $expected.Count)
        return $false
    }

    for ($index = 0; $index -lt $expected.Count; $index++) {
        $current = Get-FilamentCardSlot ([string]$cards[$index])
        $wanted = [string]$expected[$index]
        if ([string]::Equals($current, $wanted, [StringComparison]::OrdinalIgnoreCase)) { continue }

        if (-not [BaleiaMsaaBridge]::OpenFilamentCard(
            (Get-ConnectWindow),
            'Send to print',
            $index)) {
            return $false
        }
        Start-Sleep -Milliseconds 350

        $chosen = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $chosen = [BaleiaMsaaBridge]::ChooseFilamentSlot(
                (Get-ConnectWindow),
                $wanted)
            if (-not $chosen) { Start-Sleep -Milliseconds 300 }
        } while (-not $chosen -and [DateTime]::UtcNow -lt $deadline)
        if (-not $chosen) { return $false }
        Start-Sleep -Milliseconds 500
        $cards = @(Wait-MsaaFilamentCards $expected.Count 5)
    }

    $actual = @($cards | ForEach-Object { Get-FilamentCardSlot ([string]$_) })
    Write-BaleiaLog ('Filament mapping: [' + ($actual -join ',') + ']')
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if (-not [string]::Equals(
            [string]$actual[$index],
            [string]$expected[$index],
            [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Set-MsaaOption {
    param([string[]]$Labels, [bool]$Enabled)
    $status = [BaleiaMsaaBridge]::SetOption(
        (Get-ConnectWindow),
        'Send to print',
        $Labels,
        $Enabled)
    Write-BaleiaLog (($Labels | Select-Object -First 1) + ': ' + $status)
    return ($status -eq 'selected' -or $status -eq 'already-selected')
}

function Invoke-ConnectPrintFlow {
    param($Manifest, [string]$GcodePath)

    $returnToTray = $script:TrayMode
    $script:SendMayHaveBeenInvoked = $false
    if (-not (Ensure-ConnectRunning)) { throw 'Bambu Connect não foi encontrado ou não abriu.' }

    $screenReaderWasEnabled = [BaleiaMsaaBridge]::GetScreenReaderFlag()
    try {
        if (-not $screenReaderWasEnabled) {
            [BaleiaMsaaBridge]::SetScreenReaderFlag($true)
        }
        Start-Sleep -Milliseconds 1200

        $encodedPath = [Uri]::EscapeDataString($GcodePath)
        $encodedName = [Uri]::EscapeDataString([string]$Manifest.display_name)
        $uri = 'bambu-connect://import-file?path={0}&name={1}&version=1.0.0' -f $encodedPath, $encodedName
        Start-Process $uri | Out-Null

        $handle = Wait-ConnectWindow -TimeoutSeconds 30
        if ($handle -eq [IntPtr]::Zero) { throw 'A janela do Bambu Connect não apareceu.' }
        if ($returnToTray) { Hide-ConnectWindow }

        if (-not (Wait-AndPressMsaaDialogButton 'Import file' 'confirm' 45)) {
            Write-MsaaSnapshot 'import confirm not found'
            throw 'O botão de importação do Bambu Connect não foi localizado.'
        }
        Write-BaleiaLog ('Import accepted for ' + $Manifest.job_id)

        if (-not (Wait-AndPressMsaaButton 'Print' 60)) {
            Write-MsaaSnapshot 'page Print not found'
            throw 'O botão Print do Bambu Connect não foi localizado.'
        }
        Write-BaleiaLog ('Print dialog requested for ' + $Manifest.job_id)

        if (-not (Wait-MsaaDialog 'Send to print' 30)) {
            Write-MsaaSnapshot 'Send to print dialog not found'
            throw 'A janela final de envio do Bambu Connect não apareceu.'
        }

        $printerName = [string]$Manifest.printer.name
        if (-not (Set-MsaaPrinter $printerName 15)) {
            Write-MsaaSnapshot 'printer selection failed'
            throw ('A impressora não foi selecionada no Connect: ' + $printerName)
        }

        if (-not (Set-MsaaFilamentMapping $Manifest)) {
            Write-MsaaSnapshot 'filament mapping failed'
            throw 'O mapeamento de filamentos não foi aplicado no Connect.'
        }

        if (-not (Set-MsaaOption @('Timelapse') ([bool]$Manifest.options.timelapse))) {
            throw 'A opção Timelapse não foi aplicada no Connect.'
        }
        if (-not (Set-MsaaOption @(
            'Flow dynamic calibration',
            'Dynamic flow calibration',
            'Calibracao dinamica de fluxo'
        ) ([bool]$Manifest.options.flow_calibration))) {
            throw 'A calibração dinâmica de fluxo não foi aplicada no Connect.'
        }
        if (-not (Set-MsaaOption @(
            'Bed leveling',
            'Nivelamento da mesa',
            'Nivelamento automatico'
        ) ([bool]$Manifest.options.bed_leveling))) {
            throw 'O nivelamento da mesa não foi aplicado no Connect.'
        }

        # The final button is invoked exactly once. There is deliberately no
        # retry after this point: Connect owns validation and transport.
        $script:SendMayHaveBeenInvoked = $true
        if (-not [BaleiaMsaaBridge]::PressButtonInDialog(
            (Get-ConnectWindow),
            'Send to print',
            'confirm')) {
            Write-MsaaSnapshot 'final confirm result uncertain'
            throw 'O estado do envio ficou incerto. Confira o Connect antes de repetir.'
        }
        Write-BaleiaLog ('Send invoked once for ' + $Manifest.job_id + ' on ' + $printerName)

        if ($returnToTray) { Hide-ConnectWindow }
    } finally {
        if (-not $screenReaderWasEnabled) {
            try { [BaleiaMsaaBridge]::SetScreenReaderFlag($false) } catch {}
        }
    }
}

function Move-JobToError {
    param([string]$ManifestPath, [string]$GcodePath, [string]$Message)
    if ($script:SendMayHaveBeenInvoked) {
        $Message = 'ATENÇÃO: o Send pode ter sido acionado. Confira o Connect e a impressora antes de repetir. ' + $Message
    }
    try {
        $baseName = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($ManifestPath))
        $targetManifest = Join-Path $script:ErrorDir ([IO.Path]::GetFileName($ManifestPath))
        Move-Item -LiteralPath $ManifestPath -Destination $targetManifest -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $GcodePath) {
            Copy-Item -LiteralPath $GcodePath -Destination (Join-Path $script:ErrorDir ([IO.Path]::GetFileName($GcodePath))) -Force -ErrorAction SilentlyContinue
        }
        Set-Content -LiteralPath (Join-Path $script:ErrorDir ($baseName + '.error.txt')) -Value $Message -Encoding UTF8
    } catch {}
    Write-BaleiaLog ('Job stopped safely: ' + $Message)
    if ($script:NotifyIcon) {
        $script:NotifyIcon.BalloonTipTitle = 'Baleia Connect'
        $script:NotifyIcon.BalloonTipText = $Message
        $script:NotifyIcon.ShowBalloonTip(8000)
    }
    Show-ConnectWindow
}

function Process-NextJob {
    $next = Get-ChildItem -LiteralPath $script:PendingDir -Filter '*.job.json' -File -ErrorAction SilentlyContinue |
        Sort-Object CreationTimeUtc | Select-Object -First 1
    if (-not $next) { return }

    $workingManifest = Join-Path $script:WorkingDir $next.Name
    try {
        Move-Item -LiteralPath $next.FullName -Destination $workingManifest -ErrorAction Stop
    } catch { return }

    $gcodePath = ''
    try {
        $manifest = Get-Content -LiteralPath $workingManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $sourceGcode = [string]$manifest.file
        if (-not (Test-Path -LiteralPath $sourceGcode)) { throw 'O arquivo G-code 3MF da fila desapareceu.' }
        $gcodePath = Join-Path $script:WorkingDir ([IO.Path]::GetFileName($sourceGcode))
        Move-Item -LiteralPath $sourceGcode -Destination $gcodePath -ErrorAction Stop

        Write-BaleiaLog ('Processing ' + $manifest.job_id + ' for ' + $manifest.printer.name)
        Invoke-ConnectPrintFlow $manifest $gcodePath

        Remove-Item -LiteralPath $gcodePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $workingManifest -Force -ErrorAction SilentlyContinue
        Write-BaleiaLog ('Completed ' + $manifest.job_id)
    } catch {
        if (Test-BaleiaRunning) {
            Move-JobToError $workingManifest $gcodePath $_.Exception.Message
        }
    }
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
    [void](Ensure-ConnectRunning)
    $lastCleanup = [DateTime]::MinValue

    while (-not $script:StopRequested) {
        if (-not (Test-BaleiaRunning)) { break }

        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero -and [BaleiaNativeWindow]::IsIconic($handle)) {
            Hide-ConnectWindow
        } elseif ($script:TrayMode -and $handle -ne [IntPtr]::Zero) {
            [void][BaleiaNativeWindow]::ShowWindowAsync($handle, 0)
        }

        Process-NextJob
        if (([DateTime]::UtcNow - $lastCleanup).TotalMinutes -ge 15) {
            Remove-StaleFiles
            $lastCleanup = [DateTime]::UtcNow
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 350
    }
} catch {
    Write-BaleiaLog ('Fatal helper error: ' + $_.Exception.Message)
} finally {
    Write-BaleiaLog 'Helper stopping with Baleia.'
    Stop-Connect
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
