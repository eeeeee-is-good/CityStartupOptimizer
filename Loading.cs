using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace CityStartupOptimizer
{
    public static class Loading
    {
        sealed class References : IEqualityComparer<string>
        {
            public bool Equals(string a, string b) { return ReferenceEquals(a, b); }
            public int GetHashCode(string a) { return RuntimeHelpers.GetHashCode(a); }
        }
        sealed class PackScan
        {
            public string Prefix;
            public CultureInfo Culture;
            public long Start, Tested, Reused, Owned;
            public Dictionary<string, bool> Matches = new Dictionary<string, bool>(new References());
        }
        static readonly ConcurrentDictionary<string, long> packStarts = new ConcurrentDictionary<string, long>();
        [ThreadStatic] static PackScan scan;
        static long Now { get { return Stopwatch.GetTimestamp(); } }
        static string Milliseconds(long start, long end)
        {
            return ((end - start) * 1000.0 / Stopwatch.Frequency).ToString("F3", CultureInfo.InvariantCulture);
        }

        public static void Pack(string path) { packStarts[path + "/"] = Now; }
        public static void StartMap(string prefix)
        {
            scan = new PackScan { Prefix = prefix, Culture = CultureInfo.CurrentCulture, Start = Now };
        }
        public static bool MatchesPack(string path, string prefix)
        {
            var s = scan;
            if (s == null || !ReferenceEquals(prefix, s.Prefix) || path == null) return path.StartsWith(prefix);
            var culture = CultureInfo.CurrentCulture;
            if (!ReferenceEquals(s.Culture, culture)) { s.Matches.Clear(); s.Culture = culture; }
            bool match;
            if (s.Matches.TryGetValue(path, out match)) s.Reused++;
            else { match = path.StartsWith(prefix); s.Matches.Add(path, match); }
            s.Tested++;
            if (match) s.Owned++;
            return match;
        }
        static string OwnershipDigest(IEnumerable keys)
        {
            var ids = new List<string>();
            foreach (object key in keys) ids.Add(key.ToString());
            ids.Sort(StringComparer.Ordinal);
            using (var hash = SHA256.Create())
                return BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(string.Join("\n", ids.ToArray())))).Replace("-", "");
        }
        public static void EndMap(object keys)
        {
            var s = scan;
            scan = null;
            if (s == null) return;
            long end = Now, start;
            string elapsed = packStarts.TryRemove(s.Prefix, out start) ? Milliseconds(start, end) : "";
            Session.Row("packs.tsv", Path.GetFileName(s.Prefix.TrimEnd('/', '\\')) + "\t" + elapsed + "\t" +
                Milliseconds(s.Start, end) + "\t" + s.Tested + "\t" + s.Reused + "\t" + s.Owned + "\t" +
                (Session.VerifyContents ? OwnershipDigest((IEnumerable)keys) : ""));
        }

        sealed class PathIndex
        {
            public long Revision;
            public HashSet<string> Paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        }
        sealed class Resolution
        {
            public Dictionary<object, PathIndex> Indexes = new Dictionary<object, PathIndex>();
            public long Start = Now;
            public int Checked, Skipped, Hits, Rebuilds;
        }
        [ThreadStatic] static Resolution resolution;
        [ThreadStatic] static int lookupDepth;
        [ThreadStatic] static string query;
        [ThreadStatic] static bool skipped;
        static long revision;
        static int writers;
        internal static long WriteRevision { get { return Interlocked.Read(ref revision); } }
        internal static int ActiveWriters { get { return Volatile.Read(ref writers); } }
        public static void BeginWrite() { Interlocked.Increment(ref writers); }
        public static void EndWrite() { Interlocked.Increment(ref revision); Interlocked.Decrement(ref writers); }
        public static void BeginResolve()
        {
            resolution = new Resolution();
            Session.Event("Dependency resolution started");
        }
        public static void EndResolve()
        {
            var r = resolution;
            resolution = null;
            if (r != null) Session.Event("Dependency resolution finished in " + Milliseconds(r.Start, Now) +
                " ms. Queries=" + r.Checked + " indexed misses=" + r.Skipped + " stock hits=" + r.Hits +
                " index builds=" + r.Rebuilds);
        }
        public static void BeginLookup() { lookupDepth++; query = null; skipped = false; }
        public static void EndLookup() { lookupDepth--; query = null; }
        public static bool RegisteringDependency() { return lookupDepth == 1 && resolution != null; }
        public static bool Absent(object dictionary, string packagePath, string filePath)
        {
            var r = resolution;
            if (lookupDepth != 1 || r == null) return false;
            query = packagePath + "\t" + filePath;
            skipped = false;
            long generation = Interlocked.Read(ref revision);
            if (Volatile.Read(ref writers) != 0) return false;
            try
            {
                PathIndex index;
                if (!r.Indexes.TryGetValue(dictionary, out index) || index.Revision != generation)
                {
                    index = new PathIndex { Revision = generation };
                    PropertyInfo property = null;
                    foreach (DictionaryEntry entry in (IDictionary)dictionary)
                    {
                        if (property == null) property = entry.Value.GetType().GetProperty("relativePath");
                        index.Paths.Add((string)property.GetValue(entry.Value, null));
                    }
                    r.Indexes[dictionary] = index;
                    r.Rebuilds++;
                }
                skipped = !index.Paths.Contains(packagePath) && !index.Paths.Contains(filePath)
                    && Volatile.Read(ref writers) == 0 && Interlocked.Read(ref revision) == generation;
                return skipped;
            }
            catch (Exception ex)
            {
                Session.Event("Dependency index unavailable. Using game lookup. " + ex.GetType().Name);
                return false;
            }
        }
        public static bool Record(bool found, object guid)
        {
            var r = resolution;
            if (r != null && lookupDepth == 1 && query != null)
            {
                r.Checked++;
                if (skipped) r.Skipped++;
                if (found) r.Hits++;
                Session.Row("registration.tsv", query + "\t" + (skipped ? "indexed miss" : "game scan") +
                    "\t" + (found ? guid.ToString() : "absent"));
                query = null;
            }
            return found;
        }
        static int batches;
        static long previous;
        public static void PrefabsStart()
        {
            batches = 0;
            previous = Now;
            Session.Event("Prefab loading started");
        }
        public static int BatchFrames()
        {
            long now = Now;
            Session.Row("prefabs.tsv", (++batches) + "\t1\t" + Milliseconds(previous, now));
            previous = now;
            return 1;
        }
        public static void PrefabsEnd() { Session.Event("Prefab loading finished. One-frame waits=" + batches); }
        static long archiveTicks;
        static int archives;

        public static Stream BeginArchiveDirectory(Stream source, bool playset)
        {
            if (!playset || !(source is FileStream) || !source.CanSeek || !source.CanRead || source.CanWrite)
                return source;
            return new ArchiveDirectoryStream(source);
        }

        public static void EndArchiveDirectory(Stream stream)
        {
            var archive = stream as ArchiveDirectoryStream;
            if (archive == null) return;
            archive.FinishDirectory();
            Interlocked.Add(ref archiveTicks, Now - archive.Start);
            Interlocked.Increment(ref archives);
        }

        // The patched Game.dll and Colossal.IO.AssetDatabase.dll load from Cities2_Data\Managed\CityStartupOptimizer\, so
        // their Assembly.Location stays inside the game's Managed folder (Write Everywhere, for one, classifies game types
        // by that path). ExecutableAsset.GetModAssets matches a loaded assembly to the resolver's Managed\<name>.dll by exact
        // location; this also accepts the relocated copy, which keeps the game's "in-game assembly shipped with a mod" skip.
        public const string RelocatedFolder = "CityStartupOptimizer";

        public static bool SameAssemblyFile(string loadedLocation, string resolvedFile)
        {
            if (string.Equals(loadedLocation, resolvedFile)) return true; // the game's own comparison
            if (string.IsNullOrEmpty(loadedLocation) || string.IsNullOrEmpty(resolvedFile)) return false;
            try
            {
                string folder = Path.GetDirectoryName(Path.GetFullPath(loadedLocation));
                return string.Equals(Path.GetFileName(folder), RelocatedFolder, StringComparison.OrdinalIgnoreCase)
                    && string.Equals(Path.GetFileName(loadedLocation), Path.GetFileName(resolvedFile), StringComparison.OrdinalIgnoreCase)
                    && string.Equals(Path.GetDirectoryName(folder), Path.GetDirectoryName(Path.GetFullPath(resolvedFile)), StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception) { return false; }
        }

        public static Task JoinStartupScreens(Task loading, Task splash)
        {
            Session.Event("Startup loading continues alongside the native studio sequence.");
            return Task.WhenAll(loading, splash);
        }

        public static void SplashShown(object screen)
        {
            Session.Event("Studio overlay activated: " + screen);
        }

        public static void SplashComplete()
        {
            Session.Event("Studio sequence completed.");
        }
        public static void PlaysetStart()
        {
            Ownership.Begin(); Interlocked.Exchange(ref archiveTicks, 0);
            Interlocked.Exchange(ref archives, 0);
            Session.Event("Applying playset");
        }
        public static void PlaysetEnd()
        {
            Ownership.End(); packStarts.Clear();
            Session.Event("Finished applying playset. Buffered archive directories=" + Volatile.Read(ref archives) +
                " directory read ms=" + Milliseconds(0, Interlocked.Read(ref archiveTicks)));
        }
        public static void RegisterStart() { Session.Event("Discovering mod assemblies"); }
        public static void RegisterEnd() { Session.Event("Finished discovering mod assemblies"); }
    }
}


