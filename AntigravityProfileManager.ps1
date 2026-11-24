[CmdletBinding()]
param()

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $AppDir) { $AppDir = "D:\Device\Apps\Antigravity Multi-Profile" }

# Pre-compiled native helper DLL (loads in ~2ms instead of spawning csc.exe on every launch)
$NativeDllPath = Join-Path $AppDir "AgyNative.v2.dll"
$NativeSource = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;

public class AgyWin32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    struct WTS_PROCESS_INFO {
        public int SessionId;
        public int ProcessId;
        public IntPtr pProcessName;
        public IntPtr pUserSid;
    }

    [DllImport("shell32.dll", SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WTSEnumerateProcessesW(IntPtr hServer, int Reserved, int Version, out IntPtr ppProcessInfo, out int pCount);

    [DllImport("wtsapi32.dll")]
    static extern void WTSFreeMemory(IntPtr pMemory);

    public const int WM_SETICON = 0x0080;

    static Dictionary<string, string> _sidCache = new Dictionary<string, string>();

    public static Dictionary<uint, string> GetProcessOwnersByName(string targetExeName) {
        var res = new Dictionary<uint, string>();
        IntPtr ppInfo;
        int count;
        if (WTSEnumerateProcessesW(IntPtr.Zero, 0, 1, out ppInfo, out count)) {
            try {
                int structSize = Marshal.SizeOf(typeof(WTS_PROCESS_INFO));
                for (int i = 0; i < count; i++) {
                    IntPtr ptr = IntPtr.Add(ppInfo, i * structSize);
                    var info = (WTS_PROCESS_INFO)Marshal.PtrToStructure(ptr, typeof(WTS_PROCESS_INFO));
                    string name = info.pProcessName != IntPtr.Zero ? Marshal.PtrToStringUni(info.pProcessName) : "";
                    if (!string.Equals(name, targetExeName, StringComparison.OrdinalIgnoreCase)) continue;
                    string user = "";
                    if (info.pUserSid != IntPtr.Zero) {
                        try {
                            var sid = new SecurityIdentifier(info.pUserSid);
                            string sidStr = sid.Value;
                            lock (_sidCache) {
                                if (!_sidCache.TryGetValue(sidStr, out user)) {
                                    string nt = sid.Translate(typeof(NTAccount)).Value;
                                    int idx = nt.LastIndexOf('\\');
                                    user = (idx >= 0 ? nt.Substring(idx + 1) : nt).ToLowerInvariant();
                                    _sidCache[sidStr] = user;
                                }
                            }
                        } catch {}
                    }
                    res[(uint)info.ProcessId] = user;
                }
            } finally {
                WTSFreeMemory(ppInfo);
            }
        }
        return res;
    }

    public static Dictionary<uint, int> CountVisibleWindowsByPids(HashSet<uint> targetPids) {
        var counts = new Dictionary<uint, int>();
        if (targetPids == null || targetPids.Count == 0) return counts;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            if (GetWindowTextLength(hWnd) == 0) return true;
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (targetPids.Contains(pid)) {
                var sb = new StringBuilder(256);
                GetWindowText(hWnd, sb, 256);
                if (!string.IsNullOrWhiteSpace(sb.ToString())) {
                    int c;
                    counts.TryGetValue(pid, out c);
                    counts[pid] = c + 1;
                }
            }
            return true;
        }, IntPtr.Zero);
        return counts;
    }

    public static bool FocusByPids(HashSet<uint> targetPids) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            if (GetWindowTextLength(hWnd) == 0) return true;
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (targetPids.Contains(pid)) {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);

        if (found != IntPtr.Zero) {
            if (IsIconic(found)) {
                ShowWindow(found, 9);
            }
            SetForegroundWindow(found);
            return true;
        }
        return false;
    }
}

public class AgyUserMetric {
    public HashSet<uint> Pids = new HashSet<uint>();
    public long Ram;
    public double Cpu;
    public int Windows;
}

public class AgyMetricsSnapshot {
    public Dictionary<string, AgyUserMetric> Users = new Dictionary<string, AgyUserMetric>(StringComparer.OrdinalIgnoreCase);
    public long TotalRam;
    public double TotalCpu;
    public int TotalWindows;
}

public static class AgyBgMonitor {
    static volatile bool _running = false;
    static volatile bool _paused = false;
    static volatile bool _hasMetrics = false;
    static volatile bool _hasStorage = false;
    static volatile int _metricsVersion = 0;
    static volatile int _storageVersion = 0;
    static volatile AgyMetricsSnapshot _latestMetrics = new AgyMetricsSnapshot();
    static volatile Dictionary<string, long> _latestStorage = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
    static readonly AutoResetEvent _metricsWake = new AutoResetEvent(false);
    static readonly AutoResetEvent _storageWake = new AutoResetEvent(false);
    static readonly object _storageCfgLock = new object();

    static string _appBinDir = "";
    static string _appDir = "";
    static string[] _storageUsers = new string[0];

    static Dictionary<uint, double> _prevCpu = new Dictionary<uint, double>();
    static DateTime _lastCpuSample = DateTime.UtcNow;

    public static bool HasMetrics { get { return _hasMetrics; } }
    public static bool HasStorage { get { return _hasStorage; } }
    public static int MetricsVersion { get { return _metricsVersion; } }
    public static int StorageVersion { get { return _storageVersion; } }

    public static void Start(string appBinDir, string appDir, string[] users) {
        if (_running) return;
        _running = true;
        UpdateStorageTargets(appBinDir, appDir, users, false);

        var tMetrics = new Thread(MetricsLoop);
        tMetrics.IsBackground = true;
        tMetrics.Priority = ThreadPriority.BelowNormal;
        tMetrics.Start();

        var tStorage = new Thread(StorageLoop);
        tStorage.IsBackground = true;
        tStorage.Priority = ThreadPriority.Lowest;
        tStorage.Start();
    }

    public static void Stop() {
        _running = false;
        try { _metricsWake.Set(); } catch {}
        try { _storageWake.Set(); } catch {}
    }

    public static void SetPaused(bool paused) {
        bool wasPaused = _paused;
        _paused = paused;
        if (wasPaused && !paused) {
            WakeMetrics();
        }
    }

    public static void WakeMetrics() {
        try { _metricsWake.Set(); } catch {}
    }

    public static void UpdateStorageTargets(string appBinDir, string appDir, string[] users, bool triggerNow) {
        lock (_storageCfgLock) {
            _appBinDir = appBinDir ?? "";
            _appDir = appDir ?? "";
            _storageUsers = users ?? new string[0];
        }
        if (triggerNow) {
            try { _storageWake.Set(); } catch {}
        }
    }

    public static AgyMetricsSnapshot GetMetrics() {
        return _latestMetrics;
    }

    public static Dictionary<string, long> GetStorage() {
        return _latestStorage;
    }

    static void MetricsLoop() {
        while (_running) {
            try {
                SampleMetricsOnce();
            } catch {}
            _metricsWake.WaitOne(_paused ? 5000 : 1500);
        }
    }

    static void SampleMetricsOnce() {
        DateTime now = DateTime.UtcNow;
        double elapsedSec = (now - _lastCpuSample).TotalSeconds;
        if (elapsedSec < 0.2) elapsedSec = 0.2;
        int cpuCores = Math.Max(1, Environment.ProcessorCount);

        var owners = AgyWin32.GetProcessOwnersByName("Antigravity IDE.exe");
        Process[] procs = null;
        try {
            procs = Process.GetProcessesByName("Antigravity IDE");
            var livePids = new HashSet<uint>();
            foreach (var p in procs) {
                try { livePids.Add((uint)p.Id); } catch {}
            }

            var deadPids = new List<uint>();
            foreach (var k in _prevCpu.Keys) {
                if (!livePids.Contains(k)) deadPids.Add(k);
            }
            foreach (var dk in deadPids) _prevCpu.Remove(dk);

            var winCounts = AgyWin32.CountVisibleWindowsByPids(livePids);
            var snap = new AgyMetricsSnapshot();

            foreach (var p in procs) {
                uint pid;
                try { pid = (uint)p.Id; } catch { continue; }
                string owner;
                if (!owners.TryGetValue(pid, out owner) || string.IsNullOrWhiteSpace(owner)) continue;

                AgyUserMetric um;
                if (!snap.Users.TryGetValue(owner, out um)) {
                    um = new AgyUserMetric();
                    snap.Users[owner] = um;
                }
                um.Pids.Add(pid);

                try {
                    long ram = p.WorkingSet64;
                    um.Ram += ram;
                    snap.TotalRam += ram;
                } catch {}

                try {
                    double currCpu = p.TotalProcessorTime.TotalSeconds;
                    double prev;
                    if (_prevCpu.TryGetValue(pid, out prev)) {
                        double delta = currCpu - prev;
                        if (delta > 0) {
                            double pct = (delta / elapsedSec / cpuCores) * 100.0;
                            um.Cpu += pct;
                            snap.TotalCpu += pct;
                        }
                    }
                    _prevCpu[pid] = currCpu;
                } catch {}

                int wc;
                if (winCounts.TryGetValue(pid, out wc)) {
                    um.Windows += wc;
                    snap.TotalWindows += wc;
                }
            }

            snap.TotalCpu = Math.Round(snap.TotalCpu, 1);
            _lastCpuSample = now;
            _latestMetrics = snap;
            _hasMetrics = true;
            _metricsVersion++;
        } finally {
            if (procs != null) {
                foreach (var p in procs) {
                    try { p.Dispose(); } catch {}
                }
            }
        }
    }

    static void StorageLoop() {
        while (_running) {
            try {
                string appBinDir;
                string appDir;
                string[] users;
                lock (_storageCfgLock) {
                    appBinDir = _appBinDir;
                    appDir = _appDir;
                    users = (string[])_storageUsers.Clone();
                }

                var cache = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
                cache["__app_bin__"] = WalkDirSize(appBinDir);

                string[] browserFolders = new[] { "ChromeData", "BraveData", "EdgeData" };
                foreach (var u in users) {
                    if (!_running) return;
                    if (string.IsNullOrWhiteSpace(u)) continue;
                    string uKey = u.ToLowerInvariant();
                    long total = 0;
                    total += WalkDirSize(Path.Combine("C:\\Users", u, "AppData\\Roaming\\Antigravity IDE"));
                    foreach (var bf in browserFolders) {
                        total += WalkDirSize(Path.Combine(appDir, bf, u));
                    }
                    cache[uKey] = total;
                }

                _latestStorage = cache;
                _hasStorage = true;
                _storageVersion++;
            } catch {}
            _storageWake.WaitOne(60000);
        }
    }

    static long WalkDirSize(string rootPath) {
        if (string.IsNullOrWhiteSpace(rootPath) || !Directory.Exists(rootPath)) return 0;
        long total = 0;
        var stack = new Stack<string>();
        stack.Push(rootPath);
        while (stack.Count > 0 && _running) {
            string dir = stack.Pop();
            try {
                foreach (string file in Directory.EnumerateFiles(dir)) {
                    try {
                        total += new FileInfo(file).Length;
                    } catch {}
                }
            } catch {}
            try {
                foreach (string sub in Directory.EnumerateDirectories(dir)) {
                    stack.Push(sub);
                }
            } catch {}
        }
        return total;
    }
}
"@

if (Test-Path $NativeDllPath) {
    try {
        [void][System.Reflection.Assembly]::LoadFrom($NativeDllPath)
    } catch {
        Add-Type -TypeDefinition $NativeSource
    }
} else {
    try {
        Add-Type -TypeDefinition $NativeSource -OutputAssembly $NativeDllPath
        [void][System.Reflection.Assembly]::LoadFrom($NativeDllPath)
    } catch {
        Add-Type -TypeDefinition $NativeSource
    }
}

# Set explicit AppUserModelID BEFORE creating WPF Window so Windows 11 Taskbar uses app.ico instead of PowerShell's icon
try {
    [void][AgyWin32]::SetCurrentProcessExplicitAppUserModelID("Antigravity.Hub.MultiProfile")
} catch {}

$ConfigFile   = Join-Path $AppDir "profiles.json"
$SettingsFile = Join-Path $AppDir "hub_settings.json"
$IgnoredFile  = Join-Path $AppDir "ignored_users.json"
$XamlFile     = Join-Path $AppDir "MainWindow.xaml"
$SetupPs1     = Join-Path $AppDir "Setup-MultiUser.ps1"
$IcoFile      = Join-Path $AppDir "app.ico"
$PngFile      = Join-Path $AppDir "app.png"
$TagsDir      = Join-Path $AppDir "tags"
if (-not (Test-Path $TagsDir)) { New-Item -ItemType Directory -Path $TagsDir -Force | Out-Null }

# Unicode symbols via explicit char codes
$SYM_UP     = [char]0x25B2
$SYM_DOWN   = [char]0x25BC
$SYM_EDIT   = [char]0x270E
$SYM_CHECK  = [char]0x2713
$SYM_BULLET = [char]0x2022
$SYM_CLOSE  = [char]0x2715
$SYM_GLOBE  = [char]::ConvertFromUtf32(0x1F310)

# Detect Antigravity IDE executable
$AntigravityExe = "D:\Device\Apps\Antigravity IDE\Antigravity IDE.exe"
if (-not (Test-Path $AntigravityExe)) {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Antigravity IDE\Antigravity IDE.exe",
        "$env:LOCALAPPDATA\Programs\antigravity\antigravity.exe",
        "$env:ProgramFiles\Antigravity IDE\Antigravity IDE.exe"
    )
    foreach ($cand in $candidates) {
        if (Test-Path $cand) {
            $AntigravityExe = $cand
            break
        }
    }
}

$script:IsEditingName = $false
$script:BrushCache    = @{}
$script:CardUiRefs    = @{}
$script:RawBrushConv  = [System.Windows.Media.BrushConverter]::new()

function Get-FrozenBrush {
    param([string]$Hex)
    if ($script:BrushCache.ContainsKey($Hex)) { return $script:BrushCache[$Hex] }
    $brush = $script:RawBrushConv.ConvertFromString($Hex)
    if ($brush.CanFreeze) { $brush.Freeze() }
    $script:BrushCache[$Hex] = $brush
    return $brush
}

$script:FrozenBrushConv = [PSCustomObject]@{}
$script:FrozenBrushConv | Add-Member -MemberType ScriptMethod -Name ConvertFromString -Value {
    param([string]$Hex)
    return (Get-FrozenBrush -Hex $Hex)
}

function Load-HubSettings {
    $defaults = [PSCustomObject]@{
        TitleFormat      = "u_name"   # u_name | u_only | paren | bracket | none
        HideActiveEditor = $false     # true = hide active editor filename from window.title
        BrowserMode      = "chrome"   # chrome | brave | edge | host
    }
    if (Test-Path $SettingsFile) {
        try {
            $parsed = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($parsed.TitleFormat) { $defaults.TitleFormat = $parsed.TitleFormat }
            if ($null -ne $parsed.HideActiveEditor) { $defaults.HideActiveEditor = [bool]$parsed.HideActiveEditor }
            if ($parsed.BrowserMode) { $defaults.BrowserMode = $parsed.BrowserMode }
        } catch {}
    } else {
        Save-HubSettings -Settings $defaults
    }
    return $defaults
}

function Save-HubSettings {
    param($Settings)
    $json = ConvertTo-Json -InputObject $Settings -Depth 3
    [System.IO.File]::WriteAllText($SettingsFile, $json, [System.Text.UTF8Encoding]::new($false))
}

function Load-IgnoredUsers {
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path $IgnoredFile) {
        try {
            $arr = Get-Content $IgnoredFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($item in $arr) {
                if (-not [string]::IsNullOrWhiteSpace($item)) {
                    [void]$set.Add($item.ToString())
                }
            }
        } catch {}
    }
    return ,$set
}

function Save-IgnoredUsers {
    param($Set)
    $arr = @($Set)
    $json = ConvertTo-Json -InputObject $arr -Depth 2
    [System.IO.File]::WriteAllText($IgnoredFile, $json, [System.Text.UTF8Encoding]::new($false))
}

function Ensure-ProfileSchema {
    param($Profile)
    if ($Profile -and -not ($Profile.PSObject.Properties.Name -contains "Note")) {
        $Profile | Add-Member -NotePropertyName "Note" -NotePropertyValue "" -Force
    }
}

function Load-ProfilesConfig {
    if (Test-Path $ConfigFile) {
        try {
            $json = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $list = [System.Collections.ArrayList]@($json)
            foreach ($p in $list) { Ensure-ProfileSchema -Profile $p }
            return ,$list
        } catch {}
    }

    $defaultProfiles = @(
        [PSCustomObject]@{
            Id        = "default"
            Name      = "Akun Google 1 (Utama)"
            IsDefault = $true
            BoxName   = ""
            Note      = ""
        }
    )
    Save-ProfilesConfig -Profiles $defaultProfiles
    return ,([System.Collections.ArrayList]@($defaultProfiles))
}

function Save-ProfilesConfig {
    param($Profiles)
    $arr = @($Profiles)
    $json = ConvertTo-Json -InputObject $arr -Depth 4
    [System.IO.File]::WriteAllText($ConfigFile, $json, [System.Text.UTF8Encoding]::new($false))
}

function Format-DisplayNameFromUser {
    param([string]$UserName)
    if ($UserName -match '^AkunGoogle(\d+)$') { return "Akun Google $($matches[1])" }
    if ($UserName -match '^Google(\d+)$') { return "Akun Google $($matches[1])" }
    return $UserName
}

function Sync-WindowsUsers {
    param([switch]$IncludeIgnored)
    $ignored = if ($IncludeIgnored) {
        [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    } else {
        Load-IgnoredUsers
    }

    if ($IncludeIgnored -and (Test-Path $IgnoredFile)) {
        Remove-Item $IgnoredFile -Force -ErrorAction SilentlyContinue
    }

    $changed = $false
    $hasDefault = @($script:ProfilesList | Where-Object { $_.IsDefault -eq $true -or $_.Id -eq "default" }).Count -gt 0
    if (-not $hasDefault) {
        $script:ProfilesList.Insert(0, [PSCustomObject]@{
            Id        = "default"
            Name      = "Akun Google 1 (Utama)"
            IsDefault = $true
            BoxName   = ""
            Note      = ""
        })
        $changed = $true
    }

    $existingBoxes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $script:ProfilesList) {
        if ($p.BoxName) { [void]$existingBoxes.Add($p.BoxName.Trim()) }
    }

    try {
        $localUsers = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object {
            $_.Enabled -eq $true -and $_.Name -ine $env:USERNAME
        } | Sort-Object Name

        foreach ($u in $localUsers) {
            if ($ignored.Contains($u.Name)) { continue }
            if (-not $existingBoxes.Contains($u.Name)) {
                $newProf = [PSCustomObject]@{
                    Id        = "win_$($u.Name.ToLower())"
                    Name      = (Format-DisplayNameFromUser -UserName $u.Name)
                    IsDefault = $false
                    BoxName   = $u.Name
                    Note      = ""
                }
                [void]$script:ProfilesList.Add($newProf)
                [void]$existingBoxes.Add($u.Name)
                $changed = $true
            }
        }
    } catch {}

    if ($changed) {
        Save-ProfilesConfig -Profiles $script:ProfilesList
    }
    return $changed
}

function Get-FormattedTag {
    param([int]$IndexNum, [string]$ShortLabel)
    switch ($script:HubSettings.TitleFormat) {
        "u_only"  { return "[U$IndexNum]" }
        "paren"   { return "($IndexNum)" }
        "bracket" { return "[$IndexNum]" }
        "none"    { return "" }
        default   { return "[U$IndexNum`: $ShortLabel]" }
    }
}

function Get-DesiredWindowTitle {
    param([string]$Tag)
    $baseTitle = if ($script:HubSettings.HideActiveEditor) {
        "`${rootName}`${separator}`${appName}"
    } else {
        "`${dirty}`${activeEditorShort}`${separator}`${rootName}`${separator}`${appName}"
    }
    if ($Tag) { return "$Tag $baseTitle" }
    return $baseTitle
}

function Sync-WindowTags {
    for ($i = 0; $i -lt $script:ProfilesList.Count; $i++) {
        $prof = $script:ProfilesList[$i]
        $num = $i + 1
        $isDef = ($prof.IsDefault -eq $true -or $prof.Id -eq "default")
        $winUser = if ($isDef) { $env:USERNAME } else { $prof.BoxName }
        if ([string]::IsNullOrWhiteSpace($winUser)) { continue }

        $shortLabel = if ($isDef) { "Host" } else { $winUser }
        $tag = Get-FormattedTag -IndexNum $num -ShortLabel $shortLabel
        $tagFile = Join-Path $TagsDir "$winUser.txt"
        try {
            [System.IO.File]::WriteAllText($tagFile, $tag, [System.Text.UTF8Encoding]::new($false))
        } catch {}

        # Update user's settings.json live (always works for Host; best-effort for secondary users if writable)
        $targetSettings = if ($isDef) {
            Join-Path $env:APPDATA "Antigravity IDE\User\settings.json"
        } else {
            "C:\Users\$winUser\AppData\Roaming\Antigravity IDE\User\settings.json"
        }
        if ($isDef -or (Test-Path $targetSettings)) {
            try {
                $userDir = Split-Path -Parent $targetSettings
                if ($isDef -and -not (Test-Path $userDir)) {
                    New-Item -ItemType Directory -Path $userDir -Force | Out-Null
                }

                $obj = @{}
                if (Test-Path $targetSettings) {
                    $raw = Get-Content -LiteralPath $targetSettings -Raw -Encoding UTF8
                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        $parsed = $raw | ConvertFrom-Json
                        foreach ($prop in $parsed.PSObject.Properties) {
                            $obj[$prop.Name] = $prop.Value
                        }
                    }
                }
                $desiredTitle = Get-DesiredWindowTitle -Tag $tag
                if ($obj["window.title"] -ne $desiredTitle) {
                    $obj["window.title"] = $desiredTitle
                    $json = ConvertTo-Json -InputObject $obj -Depth 10
                    [System.IO.File]::WriteAllText($targetSettings, $json, [System.Text.UTF8Encoding]::new($false))
                }
            } catch {}
        }
    }
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N0} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N0} KB" -f ($Bytes / 1KB)) }
    return "0 MB"
}

function Sync-BgStorageTargets {
    param([switch]$TriggerNow)
    $appBinDir = Split-Path -Parent $AntigravityExe
    $users = New-Object System.Collections.Generic.List[string]
    foreach ($prof in $script:ProfilesList) {
        $u = Get-ProfileTargetUser -Profile $prof
        if (-not [string]::IsNullOrWhiteSpace($u)) { [void]$users.Add($u) }
    }
    [AgyBgMonitor]::UpdateStorageTargets($appBinDir, $AppDir, $users.ToArray(), [bool]$TriggerNow)
}

function Get-ScopeMetrics {
    return [AgyBgMonitor]::GetMetrics()
}

function Get-NextSuggestedNumber {
    $maxNum = 1
    foreach ($prof in $script:ProfilesList) {
        if ($prof.Name -match '(\d+)') {
            $n = [int]$matches[1]
            if ($n -gt $maxNum) { $maxNum = $n }
        }
        if ($prof.BoxName -match '(\d+)') {
            $n = [int]$matches[1]
            if ($n -gt $maxNum) { $maxNum = $n }
        }
    }
    return ($maxNum + 1)
}

function Get-NextSuggestedName {
    return "Akun Google $(Get-NextSuggestedNumber)"
}

function Get-ProfileTargetUser {
    param($Profile)
    if ($Profile.IsDefault -eq $true -or $Profile.Id -eq "default") {
        return $env:USERNAME
    }
    if ($Profile.BoxName) { return $Profile.BoxName.Trim() }
    return ($Profile.Name -replace '[^a-zA-Z0-9]', '')
}

function Ensure-LocalAccountAndCreds {
    param([string]$AccountName)
    $userObj = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
    if (-not $userObj) {
        $res = [System.Windows.MessageBox]::Show(
            "Akun Windows lokal '$AccountName' belum dibuat di sistem.`n`nKlik 'OK' untuk membuat akun secara otomatis (memerlukan UAC Administrator).",
            "Inisialisasi Akun Sistem",
            [System.Windows.MessageBoxButton]::OKCancel,
            [System.Windows.MessageBoxImage]::Information
        )
        if ($res -eq [System.Windows.MessageBoxResult]::OK) {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$SetupPs1`" -TargetAccount `"$AccountName`"" -Verb RunAs -Wait
            $userObj = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
            if (-not $userObj) { return $false }
        } else {
            return $false
        }
    }

    $svc = Get-Service seclogon -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Running") {
        Start-Process powershell.exe -ArgumentList "-NoProfile -Command Start-Service seclogon" -Verb RunAs -Wait
    }

    try {
        $cmdkeyOut = (cmdkey /list) -join "`n"
        $targetPattern = "Domain:interactive=.*\\$([regex]::Escape($AccountName))\b"
        if ($cmdkeyOut -notmatch $targetPattern) {
            $helperVbs = Join-Path $AppDir "savecred-helper.vbs"
            if (Test-Path $helperVbs) {
                Start-Process -FilePath "cscript.exe" -ArgumentList "//nologo `"$helperVbs`" `"$AccountName`" `"AgyPass2026!`"" -WindowStyle Hidden -Wait
            }
        }
    } catch {}

    return $true
}

function Open-ProfileBrowser {
    param([string]$UserName, [string]$Url = "")
    if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = $env:USERNAME }

    $mode = $script:HubSettings.BrowserMode
    $chromeExe = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    $braveExe  = "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
    $edgeExe   = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

    if ($mode -eq "host") {
        if ($Url) { Start-Process $Url } else { Start-Process "https://accounts.google.com" }
        return
    }

    $exe = $chromeExe
    $dataSub = "ChromeData"
    if ($mode -eq "brave" -and (Test-Path $braveExe)) {
        $exe = $braveExe
        $dataSub = "BraveData"
    } elseif ($mode -eq "edge" -and (Test-Path $edgeExe)) {
        $exe = $edgeExe
        $dataSub = "EdgeData"
    } elseif (-not (Test-Path $chromeExe)) {
        if (Test-Path $braveExe) { $exe = $braveExe; $dataSub = "BraveData" }
        elseif (Test-Path $edgeExe) { $exe = $edgeExe; $dataSub = "EdgeData" }
    }

    $dataDir = Join-Path $AppDir "$dataSub\$UserName"
    if (-not (Test-Path $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    }

    $targetUrl = if ($Url) { $Url } else { "https://accounts.google.com" }
    Start-Process -FilePath $exe -ArgumentList "--no-first-run --no-default-browser-check --user-data-dir=`"$dataDir`" `"$targetUrl`""
}

function Launch-Or-FocusProfile {
    param($Profile, [switch]$ForceNewWindow)
    if (-not $Profile) { return }
    if (-not (Test-Path $AntigravityExe)) {
        [System.Windows.MessageBox]::Show("Executable Antigravity IDE tidak ditemukan di:`n$AntigravityExe", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        return
    }

    $targetUser = Get-ProfileTargetUser -Profile $Profile
    $uKey = $targetUser.ToLower()

    if (-not $ForceNewWindow -and $script:LastMetrics -and $script:LastMetrics.Users.ContainsKey($uKey)) {
        $pids = $script:LastMetrics.Users[$uKey].Pids
        if ($pids.Count -gt 0) {
            $focused = [AgyWin32]::FocusByPids($pids)
            if ($focused) { return }
        }
    }

    Sync-WindowTags

    if ($Profile.IsDefault -eq $true -or $Profile.Id -eq "default") {
        Start-Process -FilePath $AntigravityExe
        return
    }

    $ok = Ensure-LocalAccountAndCreds -AccountName $targetUser
    if (-not $ok) { return }

    $launcherCmd = Join-Path $AppDir "launch-antigravity.cmd"
    Start-Process -FilePath "runas.exe" -ArgumentList "/savecred /user:$targetUser `"$launcherCmd`"" -WindowStyle Hidden
}

function Close-ProfileWindows {
    param($Profile)
    $targetUser = Get-ProfileTargetUser -Profile $Profile
    $uKey = $targetUser.ToLower()
    if (-not ($script:LastMetrics -and $script:LastMetrics.Users.ContainsKey($uKey))) { return }

    $m = $script:LastMetrics.Users[$uKey]
    $winCount = $m.Windows
    $msg = "Tutup semua jendela Antigravity IDE untuk '$($Profile.Name)' ($winCount window aktif, user: $targetUser)?`n`nAkun Google lain tidak akan terpengaruh."
    $res = [System.Windows.MessageBox]::Show($msg, "Konfirmasi Tutup Window", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($res -ne [System.Windows.MessageBoxResult]::Yes) { return }

    foreach ($pidVal in $m.Pids) {
        try {
            Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    [AgyBgMonitor]::WakeMetrics()
}

# Clear stale pending URLs on fresh start
$pendingUrlFile = Join-Path $AppDir "pending_urls.txt"
if (Test-Path $pendingUrlFile) { Remove-Item $pendingUrlFile -Force -ErrorAction SilentlyContinue }

# Load Settings & Window XAML
$script:HubSettings = Load-HubSettings
[xml]$xaml = Get-Content $XamlFile -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

if (Test-Path $IcoFile) {
    try {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new($IcoFile))
        $window.Add_SourceInitialized({
            try {
                $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
                $ico = New-Object System.Drawing.Icon($IcoFile)
                [void][AgyWin32]::SendMessage($hwnd, [AgyWin32]::WM_SETICON, [IntPtr]1, $ico.Handle)
                [void][AgyWin32]::SendMessage($hwnd, [AgyWin32]::WM_SETICON, [IntPtr]0, $ico.Handle)
            } catch {}
        })
    } catch {}
}

$profilesContainer = $window.FindName("ProfilesContainer")
$loadingOverlay    = $window.FindName("LoadingOverlay")
$txtLoadingStatus  = $window.FindName("TxtLoadingStatus")
$txtNewProfile     = $window.FindName("TxtNewProfileName")
$btnAddProfile     = $window.FindName("BtnAddProfile")
$btnClose          = $window.FindName("BtnClose")
$btnMin            = $window.FindName("BtnMinimize")
$btnSyncUsers      = $window.FindName("BtnSyncUsers")
$btnToggleSettings = $window.FindName("BtnToggleSettings")
$settingsPanel     = $window.FindName("SettingsPanel")
$titleBar          = $window.FindName("TitleBarArea")
$txtSummary        = $window.FindName("TxtStatusSummary")
$headerIconImg     = $window.FindName("HeaderIconImage")

# Global Stats Elements
$statTotalWin     = $window.FindName("StatTotalWindows")
$statTotalRam     = $window.FindName("StatTotalRam")
$statTotalCpu     = $window.FindName("StatTotalCpu")
$statTotalStorage = $window.FindName("StatTotalStorage")

# Settings Chip Buttons
$fmtButtons = @{
    "u_name"  = $window.FindName("FmtUName")
    "u_only"  = $window.FindName("FmtUOnly")
    "paren"   = $window.FindName("FmtParen")
    "bracket" = $window.FindName("FmtBracket")
    "none"    = $window.FindName("FmtNone")
}
$edTitleButtons = @{
    "show" = $window.FindName("EdTitleShow")
    "hide" = $window.FindName("EdTitleHide")
}
$brwButtons = @{
    "chrome" = $window.FindName("BrwChrome")
    "brave"  = $window.FindName("BrwBrave")
    "edge"   = $window.FindName("BrwEdge")
    "host"   = $window.FindName("BrwHost")
}

# Load XAML Styles
$stylePrimary      = $window.FindResource("PrimaryActionBtn")
$styleActive       = $window.FindResource("ActiveActionBtn")
$styleMini         = $window.FindResource("MiniIconBtn")
$styleDanger       = $window.FindResource("DangerTextBtn")
$styleDangerIcon   = $window.FindResource("DangerIconBtn")
$styleChip         = $window.FindResource("ChipBtn")
$styleChipSelected = $window.FindResource("ChipBtnSelected")

if ($headerIconImg -and (Test-Path $PngFile)) {
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = [System.Uri]::new($PngFile)
        $bmp.EndInit()
        $headerIconImg.Source = $bmp
    } catch {}
}

function Update-SettingsChipsUI {
    foreach ($kv in $fmtButtons.GetEnumerator()) {
        $kv.Value.Style = if ($kv.Key -eq $script:HubSettings.TitleFormat) { $styleChipSelected } else { $styleChip }
    }
    $activeEdKey = if ($script:HubSettings.HideActiveEditor) { "hide" } else { "show" }
    foreach ($kv in $edTitleButtons.GetEnumerator()) {
        $kv.Value.Style = if ($kv.Key -eq $activeEdKey) { $styleChipSelected } else { $styleChip }
    }
    foreach ($kv in $brwButtons.GetEnumerator()) {
        $kv.Value.Style = if ($kv.Key -eq $script:HubSettings.BrowserMode) { $styleChipSelected } else { $styleChip }
    }
}

foreach ($kv in $fmtButtons.GetEnumerator()) {
    $fmtKey = $kv.Key
    $kv.Value.Add_Click({
        $script:HubSettings.TitleFormat = $this.Tag
        Save-HubSettings -Settings $script:HubSettings
        Update-SettingsChipsUI
        Sync-WindowTags
        Render-Profiles -ForceRender
    })
    $kv.Value.Tag = $fmtKey
}

foreach ($kv in $edTitleButtons.GetEnumerator()) {
    $edKey = $kv.Key
    $kv.Value.Add_Click({
        $script:HubSettings.HideActiveEditor = ($this.Tag -eq "hide")
        Save-HubSettings -Settings $script:HubSettings
        Update-SettingsChipsUI
        Sync-WindowTags
        Render-Profiles -ForceRender
    })
    $kv.Value.Tag = $edKey
}

foreach ($kv in $brwButtons.GetEnumerator()) {
    $brwKey = $kv.Key
    $kv.Value.Add_Click({
        $script:HubSettings.BrowserMode = $this.Tag
        Save-HubSettings -Settings $script:HubSettings
        Update-SettingsChipsUI
    })
    $kv.Value.Tag = $brwKey
}

Update-SettingsChipsUI

$btnToggleSettings.Add_Click({
    if ($settingsPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
        $settingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
    } else {
        $settingsPanel.Visibility = [System.Windows.Visibility]::Visible
    }
})

$titleBar.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        $window.DragMove()
    }
})

$btnClose.Add_Click({ $window.Close() })
$btnMin.Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })

$script:ProfilesList = Load-ProfilesConfig
$txtNewProfile.Text = Get-NextSuggestedName
$script:InitialLoaded = $false
$script:LastMetricsVer = -1
$script:LastStorageVer = -1

$btnSyncUsers.Add_Click({
    Close-ActiveInlineEdit
    Sync-WindowsUsers -IncludeIgnored | Out-Null
    Sync-WindowTags
    Sync-BgStorageTargets -TriggerNow
    [AgyBgMonitor]::WakeMetrics()
    $txtNewProfile.Text = Get-NextSuggestedName
    Render-Profiles -ForceRender
})

function Move-ProfileItem {
    param($Index, $Direction)
    $targetIndex = $Index + $Direction
    if ($targetIndex -lt 0 -or $targetIndex -ge $script:ProfilesList.Count) { return }

    $temp = $script:ProfilesList[$Index]
    $script:ProfilesList[$Index] = $script:ProfilesList[$targetIndex]
    $script:ProfilesList[$targetIndex] = $temp

    Save-ProfilesConfig -Profiles $script:ProfilesList
    Sync-WindowTags
    Render-Profiles -ForceRender
}

$script:LastRenderSig = ""
$script:ActiveEditCtx = $null

function Close-ActiveInlineEdit {
    if ($null -ne $script:ActiveEditCtx) {
        try {
            $script:ActiveEditCtx.EditPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $script:ActiveEditCtx.BtnEdit.Content = "$SYM_EDIT"
            $script:ActiveEditCtx.BtnEdit.Foreground = Get-FrozenBrush "#787886"
        } catch {}
        $script:ActiveEditCtx = $null
    }
    $script:IsEditingName = $false
}

function Open-ProfileInlineEdit {
    param($Ctx, [string]$FocusField = "name")
    if ($null -eq $Ctx) { return }

    if ($script:ActiveEditCtx -eq $Ctx -and $Ctx.EditPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
        if ($FocusField -eq "note") {
            $Ctx.TxtNote.Focus()
            $Ctx.TxtNote.SelectAll()
            return
        }
        Close-ActiveInlineEdit
        return
    }

    Close-ActiveInlineEdit

    $script:IsEditingName = $true
    $script:ActiveEditCtx = $Ctx
    $Ctx.TxtName.Text = if ($Ctx.Profile.Name) { $Ctx.Profile.Name } else { "" }
    $Ctx.TxtNote.Text = if ($Ctx.Profile.Note) { $Ctx.Profile.Note } else { "" }
    $Ctx.EditPanel.Visibility = [System.Windows.Visibility]::Visible
    $Ctx.BtnEdit.Content = "$SYM_CLOSE"
    $Ctx.BtnEdit.Foreground = Get-FrozenBrush "#E4E4E7"

    if ($FocusField -eq "note") {
        $Ctx.TxtNote.Focus()
        $Ctx.TxtNote.SelectAll()
    } else {
        $Ctx.TxtName.Focus()
        $Ctx.TxtName.SelectAll()
    }
}

function Save-ProfileInlineEdit {
    param($Ctx)
    if ($null -eq $Ctx) { return }

    $newName = $Ctx.TxtName.Text.Trim()
    $newNote = $Ctx.TxtNote.Text.Trim()
    Ensure-ProfileSchema -Profile $Ctx.Profile

    if (-not [string]::IsNullOrWhiteSpace($newName)) {
        $Ctx.Profile.Name = $newName
    }
    $Ctx.Profile.Note = $newNote

    Save-ProfilesConfig -Profiles $script:ProfilesList
    Sync-WindowTags
    $txtNewProfile.Text = Get-NextSuggestedName

    Close-ActiveInlineEdit
    Render-Profiles -ForceRender
}

function Render-Profiles {
    param([switch]$ForceRender)

    $mVer = [AgyBgMonitor]::MetricsVersion
    $sVer = [AgyBgMonitor]::StorageVersion
    if (-not $ForceRender -and $mVer -eq $script:LastMetricsVer -and $sVer -eq $script:LastStorageVer) {
        return
    }
    $script:LastMetricsVer = $mVer
    $script:LastStorageVer = $sVer

    $metrics = Get-ScopeMetrics
    $storageCache = [AgyBgMonitor]::GetStorage()
    $hasStorage = [AgyBgMonitor]::HasStorage
    $script:LastMetrics = $metrics

    # Update Global Scope Stats Bar every tick (lightweight text-only update)
    $activeUsersCount = 0
    $totalStorageBytes = [int64]0
    if ($storageCache.ContainsKey("__app_bin__")) { $totalStorageBytes = [int64]$storageCache["__app_bin__"] }
    foreach ($prof in $script:ProfilesList) {
        $uKey = (Get-ProfileTargetUser -Profile $prof).ToLower()
        if ($metrics.Users.ContainsKey($uKey)) { $activeUsersCount++ }
        if ($storageCache.ContainsKey($uKey)) { $totalStorageBytes += [int64]$storageCache[$uKey] }
    }

    if ($statTotalWin)     { $statTotalWin.Text = "$($metrics.TotalWindows) aktif" }
    if ($statTotalRam)     { $statTotalRam.Text = (Format-Bytes -Bytes $metrics.TotalRam) }
    if ($statTotalCpu)     { $statTotalCpu.Text = "$($metrics.TotalCpu)%" }
    if ($statTotalStorage) { $statTotalStorage.Text = if ($hasStorage) { Format-Bytes -Bytes $totalStorageBytes } else { "..." } }
    if ($txtSummary)       { $txtSummary.Text = "$activeUsersCount/$($script:ProfilesList.Count) akun aktif $SYM_BULLET $($metrics.TotalWindows) window berjalan" }

    if ($script:IsEditingName -and -not $ForceRender) { return }

    # Structural signature: only rebuild cards when profiles/settings/active-state change (NOT on RAM/CPU ticks)
    $sigParts = @()
    foreach ($prof in $script:ProfilesList) {
        Ensure-ProfileSchema -Profile $prof
        $uKey = (Get-ProfileTargetUser -Profile $prof).ToLower()
        $nVal = if ($prof.Note) { $prof.Note } else { "" }
        $actFlag = if ($metrics.Users.ContainsKey($uKey)) { "1" } else { "0" }
        $sigParts += "$($prof.Id)`:$uKey`:$($prof.Name)`:$nVal`:$actFlag"
    }
    $sig = ($sigParts -join "|") + "|$($script:HubSettings.TitleFormat)|$($script:HubSettings.HideActiveEditor)|$($script:ProfilesList.Count)"

    # Fast path: update RAM / CPU / Window count / Storage text in-place without rebuilding UI tree
    if (-not $ForceRender -and $sig -eq $script:LastRenderSig -and $script:CardUiRefs.Count -gt 0) {
        foreach ($prof in $script:ProfilesList) {
            $uKey = (Get-ProfileTargetUser -Profile $prof).ToLower()
            if (-not $script:CardUiRefs.ContainsKey($uKey)) { continue }
            $uiRef = $script:CardUiRefs[$uKey]
            $uStorage = if ($hasStorage -and $storageCache.ContainsKey($uKey)) { Format-Bytes -Bytes $storageCache[$uKey] } elseif ($hasStorage) { "0 MB" } else { "..." }
            if ($metrics.Users.ContainsKey($uKey)) {
                $uMetric = $metrics.Users[$uKey]
                $newSt = "ACTIVE ($($uMetric.Windows) win)"
                if ($uiRef.StatusText.Text -ne $newSt) { $uiRef.StatusText.Text = $newSt }
                $ramStr = Format-Bytes -Bytes $uMetric.Ram
                $cpuStr = "{0:N1}%" -f $uMetric.Cpu
                $newRes = "RAM: $ramStr $SYM_BULLET CPU: $cpuStr $SYM_BULLET Data: $uStorage"
                if ($uiRef.ResText.Text -ne $newRes) { $uiRef.ResText.Text = $newRes }
            } else {
                $newRes = "Data Profil & Browser: $uStorage"
                if ($uiRef.ResText.Text -ne $newRes) { $uiRef.ResText.Text = $newRes }
            }
        }
        return
    }
    $script:LastRenderSig = $sig

    $script:ActiveEditCtx = $null
    $script:CardUiRefs = @{}
    $profilesContainer.Children.Clear()
    $bc = $script:FrozenBrushConv
    $totalCount = $script:ProfilesList.Count

    for ($i = 0; $i -lt $totalCount; $i++) {
        $prof = $script:ProfilesList[$i]
        Ensure-ProfileSchema -Profile $prof
        $targetUser = Get-ProfileTargetUser -Profile $prof
        $uKey = $targetUser.ToLower()
        $isActive = $metrics.Users.ContainsKey($uKey)
        $uMetric = if ($isActive) { $metrics.Users[$uKey] } else { $null }
        $uStorage = if ($hasStorage -and $storageCache.ContainsKey($uKey)) { Format-Bytes -Bytes $storageCache[$uKey] } elseif ($hasStorage) { "0 MB" } else { "..." }
        $currIndex = $i

        $cardBorderColor = if ($isActive) { "#1F3D26" } else { "#1E1E26" }
        $cardHoverBorderColor = if ($isActive) { "#2E5E39" } else { "#2F2F3B" }

        $card = New-Object System.Windows.Controls.Border
        $card.Background = Get-FrozenBrush "#131318"
        $card.BorderBrush = Get-FrozenBrush $cardBorderColor
        $card.BorderThickness = New-Object System.Windows.Thickness(1)
        $card.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $card.Padding = New-Object System.Windows.Thickness(10, 9, 11, 9)
        $card.Margin = New-Object System.Windows.Thickness(0, 0, 0, 7)
        $card.Tag = @{
            BgIdle     = (Get-FrozenBrush "#131318")
            BgHover    = (Get-FrozenBrush "#181820")
            BorderIdle = (Get-FrozenBrush $cardBorderColor)
            BorderHov  = (Get-FrozenBrush $cardHoverBorderColor)
        }

        $card.Add_MouseEnter({
            param($sender, $e)
            $sender.Background = $sender.Tag.BgHover
            $sender.BorderBrush = $sender.Tag.BorderHov
        })
        $card.Add_MouseLeave({
            param($sender, $e)
            $sender.Background = $sender.Tag.BgIdle
            $sender.BorderBrush = $sender.Tag.BorderIdle
        })

        $cardRoot = New-Object System.Windows.Controls.StackPanel

        $grid = New-Object System.Windows.Controls.Grid
        $colReorder = New-Object System.Windows.Controls.ColumnDefinition; $colReorder.Width = [System.Windows.GridLength]::Auto
        $colBadge   = New-Object System.Windows.Controls.ColumnDefinition; $colBadge.Width = [System.Windows.GridLength]::Auto
        $colInfo    = New-Object System.Windows.Controls.ColumnDefinition; $colInfo.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $colActions = New-Object System.Windows.Controls.ColumnDefinition; $colActions.Width = [System.Windows.GridLength]::Auto
        [void]$grid.ColumnDefinitions.Add($colReorder)
        [void]$grid.ColumnDefinitions.Add($colBadge)
        [void]$grid.ColumnDefinitions.Add($colInfo)
        [void]$grid.ColumnDefinitions.Add($colActions)

        # 1. Reorder Up/Down
        $reorderPanel = New-Object System.Windows.Controls.StackPanel
        $reorderPanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $reorderPanel.Margin = New-Object System.Windows.Thickness(0, 0, 7, 0)

        $btnUp = New-Object System.Windows.Controls.Button
        $btnUp.Style = $styleMini
        $btnUp.Content = "$SYM_UP"
        $btnUp.FontSize = 8
        $btnUp.Width = 17; $btnUp.Height = 14
        $btnUp.IsEnabled = ($currIndex -gt 0)
        $btnUp.Tag = $currIndex
        $btnUp.Add_Click({
            param($sender, $e)
            $e.Handled = $true
            Move-ProfileItem -Index ([int]$sender.Tag) -Direction -1
        })
        [void]$reorderPanel.Children.Add($btnUp)

        $btnDown = New-Object System.Windows.Controls.Button
        $btnDown.Style = $styleMini
        $btnDown.Content = "$SYM_DOWN"
        $btnDown.FontSize = 8
        $btnDown.Width = 17; $btnDown.Height = 14
        $btnDown.IsEnabled = ($currIndex -lt $totalCount - 1)
        $btnDown.Tag = $currIndex
        $btnDown.Add_Click({
            param($sender, $e)
            $e.Handled = $true
            Move-ProfileItem -Index ([int]$sender.Tag) -Direction 1
        })
        [void]$reorderPanel.Children.Add($btnDown)

        [System.Windows.Controls.Grid]::SetColumn($reorderPanel, 0)
        [void]$grid.Children.Add($reorderPanel)

        # 2. Number Badge
        $badgeBg = if ($isActive) { "#122616" } else { "#1A1A22" }
        $badgeBrd = if ($isActive) { "#204727" } else { "#272733" }
        $badgeTxtColor = if ($isActive) { "#4ADE80" } else { "#E4E4E7" }

        $badgeBorder = New-Object System.Windows.Controls.Border
        $badgeBorder.Width = 31; $badgeBorder.Height = 31
        $badgeBorder.CornerRadius = New-Object System.Windows.CornerRadius(16)
        $badgeBorder.Background = $bc.ConvertFromString($badgeBg)
        $badgeBorder.BorderBrush = $bc.ConvertFromString($badgeBrd)
        $badgeBorder.BorderThickness = New-Object System.Windows.Thickness(1)
        $badgeBorder.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        $badgeBorder.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        $badgeText = New-Object System.Windows.Controls.TextBlock
        $badgeText.Text = "U$($currIndex + 1)"
        $badgeText.Foreground = $bc.ConvertFromString($badgeTxtColor)
        $badgeText.FontWeight = [System.Windows.FontWeights]::SemiBold
        $badgeText.FontSize = 11
        $badgeText.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $badgeText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $badgeBorder.Child = $badgeText
        [System.Windows.Controls.Grid]::SetColumn($badgeBorder, 1)
        [void]$grid.Children.Add($badgeBorder)

        # 3. Profile Information
        $stackInfo = New-Object System.Windows.Controls.StackPanel
        $stackInfo.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        $titleRow = New-Object System.Windows.Controls.StackPanel
        $titleRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal

        $lblTitle = New-Object System.Windows.Controls.TextBlock
        $lblTitle.Text = $prof.Name
        $lblTitle.FontSize = 13
        $lblTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
        $lblTitle.Foreground = $bc.ConvertFromString("#F4F4F6")
        $lblTitle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [void]$titleRow.Children.Add($lblTitle)

        $btnEdit = New-Object System.Windows.Controls.Button
        $btnEdit.Style = $styleMini
        $btnEdit.Content = "$SYM_EDIT"
        $btnEdit.FontSize = 10.5
        $btnEdit.Width = 20; $btnEdit.Height = 20
        $btnEdit.Margin = New-Object System.Windows.Thickness(3, 0, 0, 0)
        $btnEdit.ToolTip = "Ubah Nama & Catatan Profil"
        $btnEdit.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [void]$titleRow.Children.Add($btnEdit)

        # Status Badge
        $statusBadge = New-Object System.Windows.Controls.Border
        $statusBadge.CornerRadius = New-Object System.Windows.CornerRadius(4)
        $statusBadge.BorderThickness = New-Object System.Windows.Thickness(1)
        $statusBadge.Padding = New-Object System.Windows.Thickness(5, 1, 5, 1)
        $statusBadge.Margin = New-Object System.Windows.Thickness(5, 0, 0, 0)
        $statusBadge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        $stText = New-Object System.Windows.Controls.TextBlock
        $stText.FontSize = 9
        $stText.FontWeight = [System.Windows.FontWeights]::Bold

        if ($isActive) {
            $statusBadge.Background  = $bc.ConvertFromString("#132817")
            $statusBadge.BorderBrush = $bc.ConvertFromString("#234D28")
            $stText.Text = "ACTIVE ($($uMetric.Windows) win)"
            $stText.Foreground = $bc.ConvertFromString("#4ADE80")
        } else {
            $statusBadge.Background  = $bc.ConvertFromString("#191920")
            $statusBadge.BorderBrush = $bc.ConvertFromString("#282833")
            $stText.Text = "IDLE"
            $stText.Foreground = $bc.ConvertFromString("#6B6B78")
        }
        $statusBadge.Child = $stText
        [void]$titleRow.Children.Add($statusBadge)

        [void]$stackInfo.Children.Add($titleRow)

        # Line 2: Account & Window Tag
        $isDef = ($prof.IsDefault -eq $true -or $prof.Id -eq "default")
        $winLabel = if ($isDef) { "$env:USERNAME (Host)" } else { "$targetUser" }
        $shortLbl = if ($isDef) { "Host" } else { $targetUser }
        $tagPreview = Get-FormattedTag -IndexNum ($currIndex + 1) -ShortLabel $shortLbl
        $tagDisplay = if ($tagPreview) { "Tag: $tagPreview" } else { "Tag: Off" }

        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Text = "User: $winLabel $SYM_BULLET $tagDisplay"
        $sub.FontSize = 10.5
        $sub.Foreground = $bc.ConvertFromString("#7A7A86")
        $sub.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
        [void]$stackInfo.Children.Add($sub)

        # Line 3: Per-profile Resource Stats
        $resText = if ($isActive) {
            $ramStr = Format-Bytes -Bytes $uMetric.Ram
            $cpuStr = "{0:N1}%" -f $uMetric.Cpu
            "RAM: $ramStr $SYM_BULLET CPU: $cpuStr $SYM_BULLET Data: $uStorage"
        } else {
            "Data Profil & Browser: $uStorage"
        }
        $subRes = New-Object System.Windows.Controls.TextBlock
        $subRes.Text = $resText
        $subRes.FontSize = 10
        $resColor = if ($isActive) { "#94A3B8" } else { "#52525E" }
        $subRes.Foreground = $bc.ConvertFromString($resColor)
        $subRes.Margin = New-Object System.Windows.Thickness(0, 1, 0, 0)
        [void]$stackInfo.Children.Add($subRes)

        # Line 4: Custom Tag / Note (clickable to edit)
        $noteVal = if ($prof.Note) { $prof.Note.Trim() } else { "" }
        $noteBorder = New-Object System.Windows.Controls.Border
        $noteBorder.Cursor = [System.Windows.Input.Cursors]::Hand
        $noteBorder.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $noteBorder.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
        $noteBorder.ToolTip = "Klik untuk edit tag / deskripsi profil"

        $noteText = New-Object System.Windows.Controls.TextBlock
        $noteText.FontSize = 10
        $noteText.TextWrapping = [System.Windows.TextWrapping]::Wrap
        if ($noteVal) {
            $noteBorder.Background = $bc.ConvertFromString("#191926")
            $noteBorder.BorderBrush = $bc.ConvertFromString("#2B2B3D")
            $noteBorder.BorderThickness = New-Object System.Windows.Thickness(1)
            $noteBorder.CornerRadius = New-Object System.Windows.CornerRadius(5)
            $noteBorder.Padding = New-Object System.Windows.Thickness(6, 2, 6, 2)
            $noteText.Text = $noteVal
            $noteText.Foreground = $bc.ConvertFromString("#CBD5E1")
        } else {
            $noteBorder.Background = [System.Windows.Media.Brushes]::Transparent
            $noteBorder.Padding = New-Object System.Windows.Thickness(0, 1, 4, 1)
            $noteText.Text = "+ Tambah tag / deskripsi"
            $noteText.Foreground = $bc.ConvertFromString("#4E4E5E")
        }
        $noteBorder.Child = $noteText
        [void]$stackInfo.Children.Add($noteBorder)

        # Inline Edit Panel (Name + Tag/Note)
        $editPanel = New-Object System.Windows.Controls.Border
        $editPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $editPanel.BorderBrush = $bc.ConvertFromString("#242432")
        $editPanel.BorderThickness = New-Object System.Windows.Thickness(0, 1, 0, 0)
        $editPanel.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
        $editPanel.Padding = New-Object System.Windows.Thickness(0, 8, 0, 0)

        $editStack = New-Object System.Windows.Controls.StackPanel

        # Edit Row 1: Nama Profil
        $nameEditGrid = New-Object System.Windows.Controls.Grid
        $nameEditGrid.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
        $cNameLbl = New-Object System.Windows.Controls.ColumnDefinition; $cNameLbl.Width = New-Object System.Windows.GridLength(62)
        $cNameInp = New-Object System.Windows.Controls.ColumnDefinition; $cNameInp.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        [void]$nameEditGrid.ColumnDefinitions.Add($cNameLbl)
        [void]$nameEditGrid.ColumnDefinitions.Add($cNameInp)

        $lblNameInp = New-Object System.Windows.Controls.TextBlock
        $lblNameInp.Text = "Nama"
        $lblNameInp.FontSize = 10.5
        $lblNameInp.Foreground = $bc.ConvertFromString("#8A8A9A")
        $lblNameInp.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Controls.Grid]::SetColumn($lblNameInp, 0)
        [void]$nameEditGrid.Children.Add($lblNameInp)

        $txtNameEdit = New-Object System.Windows.Controls.TextBox
        $txtNameEdit.Text = $prof.Name
        $txtNameEdit.FontSize = 11.5
        $txtNameEdit.Height = 26
        $txtNameEdit.Padding = New-Object System.Windows.Thickness(7, 0, 7, 0)
        $txtNameEdit.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Center
        $txtNameEdit.Background = $bc.ConvertFromString("#0B0B0E")
        $txtNameEdit.Foreground = $bc.ConvertFromString("#FFFFFF")
        $txtNameEdit.CaretBrush = $bc.ConvertFromString("#FFFFFF")
        $txtNameEdit.BorderBrush = $bc.ConvertFromString("#343444")
        $txtNameEdit.BorderThickness = New-Object System.Windows.Thickness(1)
        [System.Windows.Controls.Grid]::SetColumn($txtNameEdit, 1)
        [void]$nameEditGrid.Children.Add($txtNameEdit)
        [void]$editStack.Children.Add($nameEditGrid)

        # Edit Row 2: Tag / Deskripsi
        $noteEditGrid = New-Object System.Windows.Controls.Grid
        $noteEditGrid.Margin = New-Object System.Windows.Thickness(0, 0, 0, 7)
        $cNoteLbl = New-Object System.Windows.Controls.ColumnDefinition; $cNoteLbl.Width = New-Object System.Windows.GridLength(62)
        $cNoteInp = New-Object System.Windows.Controls.ColumnDefinition; $cNoteInp.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        [void]$noteEditGrid.ColumnDefinitions.Add($cNoteLbl)
        [void]$noteEditGrid.ColumnDefinitions.Add($cNoteInp)

        $lblNoteInp = New-Object System.Windows.Controls.TextBlock
        $lblNoteInp.Text = "Deskripsi"
        $lblNoteInp.FontSize = 10.5
        $lblNoteInp.Foreground = $bc.ConvertFromString("#8A8A9A")
        $lblNoteInp.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Controls.Grid]::SetColumn($lblNoteInp, 0)
        [void]$noteEditGrid.Children.Add($lblNoteInp)

        $txtNoteEdit = New-Object System.Windows.Controls.TextBox
        $txtNoteEdit.Text = $noteVal
        $txtNoteEdit.FontSize = 11.5
        $txtNoteEdit.Height = 26
        $txtNoteEdit.Padding = New-Object System.Windows.Thickness(7, 0, 7, 0)
        $txtNoteEdit.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Center
        $txtNoteEdit.Background = $bc.ConvertFromString("#0B0B0E")
        $txtNoteEdit.Foreground = $bc.ConvertFromString("#FFFFFF")
        $txtNoteEdit.CaretBrush = $bc.ConvertFromString("#FFFFFF")
        $txtNoteEdit.BorderBrush = $bc.ConvertFromString("#343444")
        $txtNoteEdit.BorderThickness = New-Object System.Windows.Thickness(1)
        $txtNoteEdit.ToolTip = "Contoh: email@gmail.com, Project Client A, Pro Plan"
        [System.Windows.Controls.Grid]::SetColumn($txtNoteEdit, 1)
        [void]$noteEditGrid.Children.Add($txtNoteEdit)
        [void]$editStack.Children.Add($noteEditGrid)

        # Edit Row 3: Buttons
        $editBtnRow = New-Object System.Windows.Controls.StackPanel
        $editBtnRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $editBtnRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

        $btnCancelEdit = New-Object System.Windows.Controls.Button
        $btnCancelEdit.Style = $styleChip
        $btnCancelEdit.Content = "Batal"
        $btnCancelEdit.Padding = New-Object System.Windows.Thickness(10, 3, 10, 3)
        $btnCancelEdit.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
        [void]$editBtnRow.Children.Add($btnCancelEdit)

        $btnSaveEdit = New-Object System.Windows.Controls.Button
        $btnSaveEdit.Style = $stylePrimary
        $btnSaveEdit.Content = "Simpan"
        $btnSaveEdit.FontSize = 11
        $btnSaveEdit.Padding = New-Object System.Windows.Thickness(12, 4, 12, 4)
        [void]$editBtnRow.Children.Add($btnSaveEdit)
        [void]$editStack.Children.Add($editBtnRow)

        $editPanel.Child = $editStack

        $editCtx = @{
            Profile   = $prof
            EditPanel = $editPanel
            TxtName   = $txtNameEdit
            TxtNote   = $txtNoteEdit
            BtnEdit   = $btnEdit
        }

        $btnEdit.Tag = $editCtx
        $noteBorder.Tag = $editCtx
        $txtNameEdit.Tag = $editCtx
        $txtNoteEdit.Tag = $editCtx
        $btnSaveEdit.Tag = $editCtx
        $btnCancelEdit.Tag = $editCtx

        $btnEdit.Add_Click({
            param($sender, $e)
            $e.Handled = $true
            Open-ProfileInlineEdit -Ctx $sender.Tag -FocusField "name"
        })

        $noteBorder.Add_MouseLeftButtonUp({
            param($sender, $e)
            $e.Handled = $true
            Open-ProfileInlineEdit -Ctx $sender.Tag -FocusField "note"
        })

        $btnSaveEdit.Add_Click({
            param($sender, $e)
            $e.Handled = $true
            Save-ProfileInlineEdit -Ctx $sender.Tag
        })

        $btnCancelEdit.Add_Click({
            param($sender, $e)
            $e.Handled = $true
            Close-ActiveInlineEdit
        })

        $keyHandler = {
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
                $e.Handled = $true
                Save-ProfileInlineEdit -Ctx $sender.Tag
            } elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $e.Handled = $true
                Close-ActiveInlineEdit
            }
        }
        $txtNameEdit.Add_KeyDown($keyHandler)
        $txtNoteEdit.Add_KeyDown($keyHandler)

        [System.Windows.Controls.Grid]::SetColumn($stackInfo, 2)
        [void]$grid.Children.Add($stackInfo)

        # 4. Action Buttons
        $actions = New-Object System.Windows.Controls.StackPanel
        $actions.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $actions.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        if ($isActive) {
            $btnFocus = New-Object System.Windows.Controls.Button
            $btnFocus.Style = $styleActive
            $btnFocus.Content = "Fokus"
            $btnFocus.Tag = $prof
            $btnFocus.ToolTip = "Tampilkan jendela Antigravity akun ini"
            $btnFocus.Add_Click({
                param($sender, $e)
                $e.Handled = $true
                Launch-Or-FocusProfile -Profile $sender.Tag
            })
            [void]$actions.Children.Add($btnFocus)

            $btnNewWin = New-Object System.Windows.Controls.Button
            $btnNewWin.Style = $styleMini
            $btnNewWin.Content = "+"
            $btnNewWin.FontSize = 13
            $btnNewWin.FontWeight = [System.Windows.FontWeights]::Bold
            $btnNewWin.Width = 26; $btnNewWin.Height = 26
            $btnNewWin.Margin = New-Object System.Windows.Thickness(4, 0, 0, 0)
            $btnNewWin.Tag = $prof
            $btnNewWin.ToolTip = "Buka jendela Antigravity baru"
            $btnNewWin.Add_Click({
                param($sender, $e)
                $e.Handled = $true
                Launch-Or-FocusProfile -Profile $sender.Tag -ForceNewWindow
            })
            [void]$actions.Children.Add($btnNewWin)

            $btnBrowser = New-Object System.Windows.Controls.Button
            $btnBrowser.Style = $styleMini
            $btnBrowser.Content = "$SYM_GLOBE"
            $btnBrowser.FontSize = 11.5
            $btnBrowser.Width = 26; $btnBrowser.Height = 26
            $btnBrowser.Margin = New-Object System.Windows.Thickness(2, 0, 0, 0)
            $btnBrowser.Tag = $targetUser
            $btnBrowser.ToolTip = "Buka Browser Terisolasi ($targetUser)"
            $btnBrowser.Add_Click({
                param($sender, $e)
                $e.Handled = $true
                Open-ProfileBrowser -UserName $sender.Tag
            })
            [void]$actions.Children.Add($btnBrowser)

            $btnKillWin = New-Object System.Windows.Controls.Button
            $btnKillWin.Style = $styleDangerIcon
            $btnKillWin.Content = "$SYM_CLOSE"
            $btnKillWin.FontSize = 10
            $btnKillWin.Width = 24; $btnKillWin.Height = 26
            $btnKillWin.Margin = New-Object System.Windows.Thickness(4, 0, 0, 0)
            $btnKillWin.Tag = $prof
            $btnKillWin.ToolTip = "Tutup semua jendela Antigravity untuk akun ini"
            $btnKillWin.Add_Click({
                param($sender, $e)
                $e.Handled = $true
                Close-ProfileWindows -Profile $sender.Tag
            })
            [void]$actions.Children.Add($btnKillWin)
        } else {
            $btnLaunch = New-Object System.Windows.Controls.Button
            $btnLaunch.Style = $stylePrimary
            $btnLaunch.Content = "Buka"
            $btnLaunch.Tag = $prof
            $btnLaunch.Add_Click({
                param($sender, $e)
                $e.Handled = $true
                Launch-Or-FocusProfile -Profile $sender.Tag
            })
            [void]$actions.Children.Add($btnLaunch)

            $btnBrowser = New-Object System.Windows.Controls.Button
            $btnBrowser.Style = $styleMini
            $btnBrowser.Content = "$SYM_GLOBE"
            $btnBrowser.FontSize = 11.5
            $btnBrowser.Width = 26; $btnBrowser.Height = 26
            $btnBrowser.Margin = New-Object System.Windows.Thickness(4, 0, 0, 0)
            $btnBrowser.Tag = $targetUser
            $btnBrowser.ToolTip = "Buka Browser Terisolasi ($targetUser)"
            $btnBrowser.Add_Click({
                param($sender, $e)
                $e.Handled = $true
                Open-ProfileBrowser -UserName $sender.Tag
            })
            [void]$actions.Children.Add($btnBrowser)
        }

        if (-not $isDef) {
            $btnDel = New-Object System.Windows.Controls.Button
            $btnDel.Style = $styleDanger
            $btnDel.Content = "Hapus"
            $btnDel.Margin = New-Object System.Windows.Thickness(2, 0, 0, 0)
            $btnDel.Tag = $prof
            $btnDel.Add_Click({
                param($sender, $e)
                $e.Handled = $true
                $targetProf = $sender.Tag
                $ignored = Load-IgnoredUsers
                if ($targetProf.BoxName -and $ignored) {
                    [void]$ignored.Add($targetProf.BoxName)
                    Save-IgnoredUsers -Set $ignored
                }
                $script:ProfilesList = [System.Collections.ArrayList]@($script:ProfilesList | Where-Object { $_.Id -ne $targetProf.Id })
                Save-ProfilesConfig -Profiles $script:ProfilesList
                Sync-WindowTags
                $txtNewProfile.Text = Get-NextSuggestedName
                Render-Profiles -ForceRender
            })
            [void]$actions.Children.Add($btnDel)
        }

        [System.Windows.Controls.Grid]::SetColumn($actions, 3)
        [void]$grid.Children.Add($actions)

        [void]$cardRoot.Children.Add($grid)
        [void]$cardRoot.Children.Add($editPanel)
        $card.Child = $cardRoot
        [void]$profilesContainer.Children.Add($card)

        $script:CardUiRefs[$uKey] = @{
            StatusText = $stText
            ResText    = $subRes
        }
    }
}

function Add-NewProfile {
    $name = $txtNewProfile.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return }

    $existing = @($script:ProfilesList | Where-Object { $_.Name.Trim().ToLower() -eq $name.ToLower() })
    if ($existing.Count -gt 0) {
        [System.Windows.MessageBox]::Show("Nama profil '$name' sudah terdaftar.", "Nama Sudah Ada", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $nextNum = Get-NextSuggestedNumber
    $boxName = "Google$nextNum"
    $usedBoxes = @($script:ProfilesList | ForEach-Object { $_.BoxName })
    while ($usedBoxes -contains $boxName) {
        $nextNum++
        $boxName = "Google$nextNum"
    }

    $ignored = Load-IgnoredUsers
    if ($ignored -and $ignored.Remove($boxName)) { Save-IgnoredUsers -Set $ignored }

    $newProf = [PSCustomObject]@{
        Id        = "prof_$([guid]::NewGuid().ToString().Substring(0,8))"
        Name      = $name
        IsDefault = $false
        BoxName   = $boxName
        Note      = ""
    }

    [void]$script:ProfilesList.Add($newProf)
    Save-ProfilesConfig -Profiles $script:ProfilesList
    Sync-WindowTags
    Sync-BgStorageTargets -TriggerNow
    $txtNewProfile.Text = Get-NextSuggestedName
    Render-Profiles -ForceRender
}

$btnAddProfile.Add_Click({ Add-NewProfile })
$txtNewProfile.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
        $e.Handled = $true
        Add-NewProfile
    }
})

# Lightweight UI DispatcherTimer: fast-check (120ms) during initial load, then 1500ms steady-state
$script:SyncTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SyncTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:SyncTimer.Add_Tick({
    if (Test-Path $pendingUrlFile) {
        try {
            $lines = Get-Content $pendingUrlFile -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne "" }
            Remove-Item $pendingUrlFile -Force -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                $parts = $line.Split("|", 2)
                if ($parts.Count -eq 2) {
                    $srcUser = $parts[0].Trim()
                    $url = $parts[1].Trim()
                    if ($url -match "^https?://") {
                        Open-ProfileBrowser -UserName $srcUser -Url $url
                    }
                } elseif ($line.Trim() -match "^https?://") {
                    Open-ProfileBrowser -UserName $env:USERNAME -Url $line.Trim()
                }
            }
        } catch {}
    }

    if (-not $script:InitialLoaded) {
        if ([AgyBgMonitor]::HasMetrics) {
            $script:InitialLoaded = $true
            $script:SyncTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
            Render-Profiles -ForceRender
            if ($loadingOverlay) { $loadingOverlay.Visibility = [System.Windows.Visibility]::Collapsed }
            Sync-WindowTags
        }
        return
    }

    if ($window.IsVisible -and $window.WindowState -ne [System.Windows.WindowState]::Minimized) {
        Render-Profiles
    }
})

# Defer background monitor start until window is painted so UI appears immediately with loading indicator
$window.Add_ContentRendered({
    $initUsers = New-Object System.Collections.Generic.List[string]
    foreach ($prof in $script:ProfilesList) {
        $u = Get-ProfileTargetUser -Profile $prof
        if (-not [string]::IsNullOrWhiteSpace($u)) { [void]$initUsers.Add($u) }
    }
    [AgyBgMonitor]::Start((Split-Path -Parent $AntigravityExe), $AppDir, $initUsers.ToArray())
    $script:SyncTimer.Start()
})

$window.Add_StateChanged({
    $isMin = ($window.WindowState -eq [System.Windows.WindowState]::Minimized)
    [AgyBgMonitor]::SetPaused($isMin)
    if (-not $isMin -and $script:InitialLoaded) {
        Render-Profiles
    }
})

$window.Add_Closed({
    try { $script:SyncTimer.Stop() } catch {}
    try { [AgyBgMonitor]::Stop() } catch {}
})

[void]$window.ShowDialog()
