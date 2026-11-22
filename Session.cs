using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace CityStartupOptimizer
{
    public static class Session
    {
        internal static bool VerifyContents { get; private set; }
        static readonly object gate = new object();
        static readonly Dictionary<string, StreamWriter> files = new Dictionary<string, StreamWriter>();
        static readonly string[] outputs = { "session.log", "packs.tsv", "registration.tsv", "prefabs.tsv", "game-events.log", "timeline.tsv", "resources.tsv" };
        static readonly string[] sources = { "SceneFlow", "Modding", "ExtraAssetsImporter", "SimpleModCheckerPlus", "CS2TestHarness" };
        static readonly Dictionary<string, long> offsets = new Dictionary<string, long>();
        static readonly List<string> milestones = new List<string>();
        static readonly Regex scene = new Regex(@"\[(WARN|ERROR|CRITICAL)\]|Boot completed|MainMenu reached|Loading mode|Loading completed|Loaded \d+ prefabs|Added \d+/\d+ explicitly|GameManager (initialized|destroyed)|WaitForModsLoaded|HandleLocaleCaching|LoadAssetLibraryAsync|Creating ECS systems|Preload Mods at boot|Initializing VT", RegexOptions.IgnoreCase);
        static readonly Regex mod = new Regex(@"\[(WARN|ERROR|CRITICAL)\]|[0-9]ms\s*$|^\s*- |^=+ |Active Playset|Registering|Initializing", RegexOptions.IgnoreCase);
        static readonly Regex checker = new Regex(@"backup|restoration|restore|\[(WARN|ERROR|CRITICAL)\]", RegexOptions.IgnoreCase);
        static readonly Regex privateLine = new Regex(@"command.?line|access.?token|refresh.?token|bearer |password|steam://|https?://", RegexOptions.IgnoreCase);
        static string directory, gameLogs;
        static Process process;
        static DateTime processStart, launcherStart, sampleUntil;
        static int steamAttempts;
        static bool loadingCity;
        static int missingDuringLoad;
        static Timer timer;
        static DateTime start;
        static int polling;
        static readonly UTF8Encoding utf8 = new UTF8Encoding(false);

        [StructLayout(LayoutKind.Sequential)]
        struct MemoryCounters
        {
            public uint Size, PageFaults;
            public UIntPtr PeakWorkingSet, WorkingSet, PeakPagedPool, PagedPool, PeakNonPagedPool, NonPagedPool;
            public UIntPtr PageFile, PeakPageFile, PrivateUsage;
        }
        [DllImport("psapi.dll")]
        static extern bool GetProcessMemoryInfo(IntPtr processHandle, ref MemoryCounters counters, uint size);
        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();

        static void SampleResources()
        {
            // Unity's Mono returns zero for Process.WorkingSet64 and PrivateMemorySize64 on this build.
            var counters = new MemoryCounters { Size = (uint)Marshal.SizeOf(typeof(MemoryCounters)) };
            bool measured = GetProcessMemoryInfo(GetCurrentProcess(), ref counters, counters.Size);
            Row("resources.tsv", DateTime.UtcNow.ToString("O") + "\t" + Seconds(process.TotalProcessorTime) +
                "\t" + (measured ? (counters.WorkingSet.ToUInt64() >> 20).ToString() : "") +
                "\t" + (measured ? (counters.PrivateUsage.ToUInt64() >> 20).ToString() : ""));
        }

        public static void Start(string data)
        {
            try
            {
                start = DateTime.UtcNow;
                var root = Path.Combine(data, "ModsData", "CityStartupOptimizer", "Logs");
                var name = start.ToString("yyyyMMdd-HHmmss-fff", CultureInfo.InvariantCulture) + "-" + Process.GetCurrentProcess().Id;
                directory = Directory.CreateDirectory(Path.Combine(root, name)).FullName;
                gameLogs = Path.Combine(data, "Logs");
                process = Process.GetCurrentProcess();
                processStart = process.StartTime.ToUniversalTime();
                sampleUntil = start.AddMinutes(12);
                VerifyContents = File.Exists(Path.Combine(data, "ModsData", "CityStartupOptimizer", "verify-content.flag"));
                Event("Game process started " + processStart.ToString("O"));
                Row("packs.tsv", "pack\tpopulate_and_map_ms\tmap_ms\tentries_compared\treused\tassets_owned\tverified_ids_sha256");
                Row("registration.tsv", "package_path\tfile_path\tlookup\tresult");
                Row("prefabs.tsv", "batch\twait_frames\tinterval_ms");
                Row("game-events.log", "Source and original game log time (local).");
                Row("timeline.tsv", "event_utc\tseconds_from_steam_launcher\tseconds_from_game_process\tevent");
                Row("resources.tsv", "utc\tcumulative_process_cpu_seconds\tworking_set_MiB\tprivate_memory_MiB");
                Flush();
                timer = new Timer(delegate { Poll(); }, null, 2000, 2000);
                AppDomain.CurrentDomain.ProcessExit += delegate { Poll(); Flush(); };
                AppDomain.CurrentDomain.DomainUnload += delegate { Poll(); Flush(); };
                Prune(root);
            }
            catch (Exception) { /* Logging must not interfere with game startup. */ }
        }
        static void Prune(string root)
        {
            var own = Directory.GetDirectories(root).Where(d => Regex.IsMatch(Path.GetFileName(d), @"^\d{8}-\d{6}-\d{3}-\d+$"))
                .OrderByDescending(d => d, StringComparer.Ordinal).Skip(12);
            foreach (string dir in own)
            {
                if ((File.GetAttributes(dir) & FileAttributes.ReparsePoint) != 0 || !File.Exists(Path.Combine(dir, "session.log"))) continue;
                var children = Directory.GetFileSystemEntries(dir);
                if (children.Any(p => !outputs.Contains(Path.GetFileName(p)) ||
                    (File.GetAttributes(p) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)) continue;
                foreach (string p in children) File.Delete(p);
                Directory.Delete(dir, false);
            }
        }
        public static void Event(string message) { Row("session.log", DateTime.UtcNow.ToString("O") + "\t" + message); Flush(); }
        internal static void Row(string file, string message)
        {
            lock (gate)
            {
                if (directory == null) return;
                try
                {
                    StreamWriter w;
                    if (!files.TryGetValue(file, out w))
                    {
                        w = new StreamWriter(new FileStream(Path.Combine(directory, file), FileMode.Append, FileAccess.Write, FileShare.ReadWrite), utf8);
                        files.Add(file, w);
                    }
                    w.WriteLine(message);
                }
                catch (Exception) { }
            }
        }
        static void Flush()
        {
            lock (gate) foreach (var w in files.Values) { try { w.Flush(); } catch (Exception) { } }
        }
        static void Poll()
        {
            if (Interlocked.Exchange(ref polling, 1) != 0) return;
            try
            {
                if (launcherStart == default(DateTime) && steamAttempts++ < 12)
                {
                    try { FindSteamLaunch(); } catch (Exception) { }
                }
                foreach (string source in sources)
                {
                    try { ReadEvents(source); } catch (Exception) { }
                }
                milestones.Sort(StringComparer.Ordinal);
                foreach (string row in milestones) Row("timeline.tsv", row);
                milestones.Clear();
                if (DateTime.UtcNow <= sampleUntil)
                {
                    try
                    {
                        process.Refresh();
                        SampleResources();
                    }
                    catch (Exception) { }
                }
                Flush();
                GC.KeepAlive(timer);
            }
            finally { Volatile.Write(ref polling, 0); }
        }
        // Steam timestamps are local, to the second. Match this Cities2 PID to its launcher session.
        static void FindSteamLaunch()
        {
            string log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam", "logs", "gameprocess_log.txt");
            using (var file = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                file.Position = Math.Max(0, file.Length - 262144);
                using (var reader = new StreamReader(file))
                {
                    DateTime candidate = default(DateTime);
                    string line;
                    string pid = "AppID 949230 adding PID " + process.Id + " ";
                    while ((line = reader.ReadLine()) != null)
                    {
                        if (line.Contains("Remove 949230 from running list")) candidate = default(DateTime);
                        if (line.Contains("AppID 949230 adding PID ") && line.IndexOf("dowser.exe", StringComparison.OrdinalIgnoreCase) >= 0 && line.Length >= 21)
                            DateTime.TryParseExact(line.Substring(1, 19), "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal | DateTimeStyles.AdjustToUniversal, out candidate);
                        DateTime tracked;
                        if (candidate != default(DateTime) && candidate <= processStart && line.Contains(pid) && line.IndexOf("Cities2.exe", StringComparison.OrdinalIgnoreCase) >= 0 &&
                            DateTime.TryParseExact(line.Substring(1, 19), "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal | DateTimeStyles.AdjustToUniversal, out tracked) &&
                            Math.Abs((tracked - processStart).TotalMinutes) < 2)
                        {
                            launcherStart = candidate;
                            Milestone(candidate, "Steam started the Paradox launcher");
                            Milestone(processStart, "Cities2 process started");
                            return;
                        }
                    }
                }
            }
        }
        static string Seconds(TimeSpan t) { return t.TotalSeconds.ToString("F3", CultureInfo.InvariantCulture); }
        static void Milestone(DateTime time, string label)
        {
            milestones.Add(time.ToString("O") + "\t" +
                (launcherStart == default(DateTime) ? "" : Seconds(time - launcherStart)) + "\t" +
                Seconds(time - processStart) + "\t" + label);
        }
        static void Track(string source, string line)
        {
            if (line.Length < 25 || line[0] != '[') return;
            DateTime time;
            if (!DateTime.TryParseExact(line.Substring(1, 23), "yyyy-MM-dd HH:mm:ss,fff", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal | DateTimeStyles.AdjustToUniversal, out time)) return;
            if (time < processStart) return;
            string label = null;
            if (source == "SceneFlow")
            {
                bool warning = line.Contains("[WARN]");
                if (warning && loadingCity && Regex.IsMatch(line, @"unknown prefab|missing prefab|prefab.*not found", RegexOptions.IgnoreCase)) missingDuringLoad++;
                if (line.Contains("Loading mode Game with purpose LoadGame"))
                {
                    loadingCity = true;
                    missingDuringLoad = 0;
                    sampleUntil = time.AddMinutes(12);
                    label = "City load requested";
                }
                else if (loadingCity && line.Contains("[INFO]  Loading completed"))
                {
                    loadingCity = false;
                    sampleUntil = time.AddSeconds(10);
                    label = "City loading complete. Missing-prefab warnings=" + missingDuringLoad;
                }
                else if (!warning && line.Contains("MainMenu reached")) { label = "Main menu reached"; sampleUntil = time.AddMinutes(2); }
                else if (line.Contains("[INFO]  Loaded ") && line.Contains(" prefabs in ")) label = line.Substring(line.IndexOf("Loaded ", StringComparison.Ordinal));
            }
            else if (source == "ExtraAssetsImporter" && line.Contains("All custom assets have been loaded")) label = "ExtraAssetsImporter finished";
            else if (source == "CS2TestHarness") label = "Test harness observed playable city";
            else if (source == "Modding" && (line.Contains("Mods registered in ") || line.Contains("Mods initialized in ")))
                label = line.Substring(line.IndexOf("Mods ", StringComparison.Ordinal));
            if (label != null) Milestone(time, label);
        }
        static void ReadEvents(string source)
        {
            string path = Path.Combine(gameLogs, source + ".log");
            if (File.GetLastWriteTimeUtc(path) < start || !File.Exists(path)) return;
            long offset;
            offsets.TryGetValue(source, out offset);
            using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (f.Length < offset) offset = 0;
                if (f.Length == offset) return;
                f.Position = offset;
                byte[] bytes = new byte[Math.Min(1024L * 1024, f.Length - offset)];
                int read = f.Read(bytes, 0, bytes.Length);
                int end = Array.LastIndexOf(bytes, (byte)'\n', read - 1, read);
                if (end < 0) return;
                offsets[source] = offset + end + 1;
                foreach (string raw in utf8.GetString(bytes, 0, end + 1).Split('\n'))
                {
                    string line = raw.TrimEnd('\r');
                    if (line.Length == 0 || privateLine.IsMatch(line)) continue;
                    bool keep = source == "ExtraAssetsImporter" ||
                        (source == "SceneFlow" && scene.IsMatch(line)) ||
                        (source == "Modding" && mod.IsMatch(line)) ||
                        (source == "SimpleModCheckerPlus" && checker.IsMatch(line)) ||
                        (source == "CS2TestHarness" && line.Contains("city loaded, autosave off"));
                    if (keep)
                    {
                        Row("game-events.log", source + "\t" + line);
                        Track(source, line);
                    }
                }
            }
        }
    }
}
