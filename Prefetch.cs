using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace CityStartupOptimizer
{
    // After a Windows restart the files the game needs are not in memory, and the game reads most of them one at a time
    // between other work. This reads them ahead on background threads, so the game's own reads find them in memory.
    // It only reads: nothing is opened for writing, locked, or changed. On a repeat launch the files are already in memory
    // and the reads are cheap memory copies. The threads run below normal
    // CPU priority. Their disk reads use normal priority: at background I/O priority Windows throttled them far below the
    // game's own reads, so they no longer ran ahead.
    public static class Prefetch
    {
        const long MaxFile = 256L << 20;
        const int Workers = 4;
        static readonly TimeSpan Limit = TimeSpan.FromMinutes(3);
        static readonly object gate = new object();
        static readonly List<string> packs = new List<string>();
        static string packList;
        static Stopwatch clock;

        sealed class Group
        {
            public string Name;
            public readonly List<KeyValuePair<string, long>> Files = new List<KeyValuePair<string, long>>();
            public long Bytes;
            public int Remaining, Read;
            public long ReadBytes;
        }

        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll")] static extern bool SetThreadPriority(IntPtr thread, int priority);
        const int BelowNormal = -1;

        [StructLayout(LayoutKind.Sequential)]
        struct MemoryStatus
        {
            public uint Length, MemoryLoad;
            public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual;
        }
        [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);

        [StructLayout(LayoutKind.Sequential)]
        struct PropertyQuery { public int PropertyId, QueryType; public byte Extra; }
        [StructLayout(LayoutKind.Sequential)]
        struct SeekPenalty { public uint Version, Size; [MarshalAs(UnmanagedType.U1)] public bool IncursSeekPenalty; }
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(IntPtr device, uint code, ref PropertyQuery input, int inputSize, out SeekPenalty output, int outputSize, out int returned, IntPtr overlapped);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

        // Called by the bootstrap once the verified libraries are loaded.
        public static void Start(string game, string data)
        {
            try
            {
                clock = Stopwatch.StartNew();
                string folder = Path.Combine(data, "ModsData", "CityStartupOptimizer");
                packList = Path.Combine(folder, "cache", "packs.txt");
                PackageCache.Start(data);
                if (File.Exists(Path.Combine(folder, "no-prefetch.flag")))
                {
                    Session.Event("Prefetch disabled by no-prefetch.flag.");
                    return;
                }
                var thread = new Thread(delegate () { Run(game); }) { IsBackground = true, Name = "CityStartupOptimizer prefetch" };
                thread.Start();
            }
            catch (Exception ex) { Session.Event("Prefetch not started. " + ex.GetType().Name); }
        }

        // The game's mod folders for the playset applied in this session, read ahead on the next launch.
        public static void NotePack(string path)
        {
            lock (gate) if (packList != null && !string.IsNullOrEmpty(path)) packs.Add(path);
        }

        public static void SavePacks()
        {
            string[] list;
            string target;
            lock (gate)
            {
                if (packList == null || packs.Count == 0) return;
                list = packs.ToArray();
                packs.Clear();
                target = packList;
            }
            try
            {
                string text = string.Join("\n", list);
                if (File.Exists(target) && File.ReadAllText(target, Encoding.UTF8) == text) return;
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                string temp = target + "." + Process.GetCurrentProcess().Id + ".tmp";
                File.WriteAllText(temp, text, new UTF8Encoding(false));
                if (File.Exists(target)) File.Replace(temp, target, null);
                else File.Move(temp, target);
            }
            catch (Exception ex) { Session.Event("Prefetch pack list not saved. " + ex.GetType().Name); }
        }

        static string Seconds() { return clock.Elapsed.TotalSeconds.ToString("F1", CultureInfo.InvariantCulture); }

        // A drive that reports a seek penalty (a hard disk) is slowed down by parallel reads, so it is left alone, as is
        // a drive that cannot answer.
        static bool SolidState(string path, Dictionary<string, bool> known)
        {
            string root = Path.GetPathRoot(Path.GetFullPath(path));
            bool result;
            if (known.TryGetValue(root, out result)) return result;
            result = false;
            if (root.Length >= 2 && root[1] == ':')
            {
                IntPtr handle = CreateFile(@"\\.\" + root.Substring(0, 2), 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                if (handle != new IntPtr(-1))
                {
                    try
                    {
                        var query = new PropertyQuery { PropertyId = 7, QueryType = 0 };
                        SeekPenalty answer;
                        int returned;
                        if (DeviceIoControl(handle, 0x2D1400, ref query, Marshal.SizeOf(typeof(PropertyQuery)), out answer,
                                Marshal.SizeOf(typeof(SeekPenalty)), out returned, IntPtr.Zero) && returned >= 9)
                            result = !answer.IncursSeekPenalty;
                    }
                    finally { CloseHandle(handle); }
                }
            }
            known[root] = result;
            return result;
        }

        static void AddFile(Group group, string path, ref long budget)
        {
            try
            {
                var info = new FileInfo(path);
                long length = info.Length;
                if (length <= 0 || length > MaxFile || length > budget) return;
                budget -= length;
                group.Files.Add(new KeyValuePair<string, long>(path, length));
                group.Bytes += length;
            }
            catch (Exception) { }
        }

        static void AddTree(Group group, string root, Func<string, bool> include, ref long budget)
        {
            if (!Directory.Exists(root)) return;
            var stack = new Stack<string>();
            stack.Push(root);
            while (stack.Count > 0 && budget > 0)
            {
                string folder = stack.Pop();
                try
                {
                    foreach (var file in Directory.GetFiles(folder))
                        if (include(file)) AddFile(group, file, ref budget);
                    var subfolders = Directory.GetDirectories(folder);
                    for (int i = subfolders.Length - 1; i >= 0; i--) stack.Push(subfolders[i]);
                }
                catch (Exception) { }
            }
        }

        static bool Extension(string file, params string[] names)
        {
            string extension = Path.GetExtension(file);
            foreach (var name in names) if (string.Equals(extension, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        // Files waiting to be read. Readers start as soon as the first group is listed; the mod folders are listed while
        // the game files are read, because listing them on a cold disk takes time of its own.
        static readonly Queue<KeyValuePair<Group, KeyValuePair<string, long>>> queue = new Queue<KeyValuePair<Group, KeyValuePair<string, long>>>();
        static bool listing = true;

        static void Enqueue(Group group)
        {
            group.Remaining = group.Files.Count;
            lock (queue)
            {
                foreach (var file in group.Files) queue.Enqueue(new KeyValuePair<Group, KeyValuePair<string, long>>(group, file));
                Monitor.PulseAll(queue);
            }
        }

        static void Run(string game)
        {
            var threads = new List<Thread>();
            try
            {
                SetThreadPriority(GetCurrentThread(), BelowNormal);
                var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf(typeof(MemoryStatus)) };
                long budget = GlobalMemoryStatusEx(ref memory) ? (long)Math.Min(memory.TotalPhys / 8, 5UL << 30) : 1L << 30;
                var known = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
                string data = Path.Combine(game, "Cities2_Data");
                var groups = new List<Group>();
                for (int i = 0; i < Workers; i++)
                {
                    var t = new Thread(Work) { IsBackground = true, Name = "CityStartupOptimizer prefetch " + i };
                    threads.Add(t);
                    t.Start();
                }
                Session.Event("Prefetch started at " + Seconds() + " s.");
                if (SolidState(game, known))
                {
                    // Unity's startup data, then the engine. Not the large .cok content packages: startup reads only small
                    // parts of those, and the package cache covers their directories.
                    var unity = new Group { Name = "Unity data" };
                    foreach (var file in Directory.GetFiles(data)) AddFile(unity, file, ref budget);
                    Enqueue(unity);
                    var engine = new Group { Name = "engine and plugins" };
                    foreach (var file in Directory.GetFiles(game, "*.dll")) AddFile(engine, file, ref budget);
                    AddTree(engine, Path.Combine(data, "Plugins"), f => true, ref budget);
                    AddTree(engine, Path.Combine(data, "Managed"), f => Extension(f, ".dll"), ref budget);
                    Enqueue(engine);
                    groups.Add(unity); groups.Add(engine);
                }
                else Session.Event("Prefetch skipped the game folder: its drive reports a seek penalty or did not answer.");
                // The mods' code from the mod folders of the last applied playset. Only large files are read ahead: in the
                // game, reading the ~17,000 small interface, data and image files as well made a repeat launch reach the
                // main menu about 21 seconds later.
                var packFolders = new List<string>();
                if (File.Exists(packList))
                    foreach (var line in File.ReadAllLines(packList, Encoding.UTF8))
                        if (line.Trim().Length > 0 && SolidState(line.Trim(), known)) packFolders.Add(line.Trim());
                var modCode = new Group { Name = "mod code" };
                foreach (var pack in packFolders) AddTree(modCode, pack, f => Extension(f, ".dll"), ref budget);
                Enqueue(modCode);
                groups.Add(modCode);
                long total = 0;
                int files = 0;
                foreach (var g in groups) { total += g.Bytes; files += g.Files.Count; }
                Session.Event("Prefetch listed " + files + " files, " + (total >> 20) + " MiB, by " + Seconds() + " s.");
            }
            catch (Exception ex) { Session.Event("Prefetch stopped listing. " + ex.GetType().Name); }
            finally
            {
                lock (queue) { listing = false; Monitor.PulseAll(queue); }
            }
            foreach (var t in threads) t.Join();
            Session.Event("Prefetch finished at " + Seconds() + " s.");
        }

        static void Work()
        {
            SetThreadPriority(GetCurrentThread(), BelowNormal);
            var buffer = new byte[1 << 20];
            while (clock.Elapsed < Limit)
            {
                KeyValuePair<Group, KeyValuePair<string, long>> next;
                lock (queue)
                {
                    while (queue.Count == 0 && listing) Monitor.Wait(queue, 1000);
                    if (queue.Count == 0) return;
                    next = queue.Dequeue();
                }
                long bytes = 0;
                try
                {
                    using (var stream = new FileStream(next.Value.Key, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.SequentialScan))
                    {
                        int n;
                        while ((n = stream.Read(buffer, 0, buffer.Length)) > 0 && clock.Elapsed < Limit) bytes += n;
                    }
                }
                catch (Exception) { }
                var group = next.Key;
                bool done;
                lock (group)
                {
                    group.ReadBytes += bytes;
                    group.Read++;
                    done = --group.Remaining == 0;
                }
                if (done)
                    Session.Event("Prefetch read " + group.Name + " by " + Seconds() + " s: " + group.Read + " files, " + (group.ReadBytes >> 20) + " MiB.");
            }
        }
    }
}
