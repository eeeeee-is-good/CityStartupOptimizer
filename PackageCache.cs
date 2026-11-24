using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Colossal;
using Colossal.IO.AssetDatabase;
using Entry = Colossal.IO.AssetDatabase.FileSystemDataSource.EntryInfo;

namespace CityStartupOptimizer
{
    // Remembers what each top-level .cok package contributed to the asset database, so a later launch can register the
    // same entries without opening the package or reading one .cid entry per asset. On a cold disk those are tens of
    // thousands of small reads scattered across the packages.
    //
    // A recording is reused only while all of these hold, and otherwise the game's own scan runs:
    //  - the package file has the same full path, length, last-write time and creation time;
    //  - the game's supported extensions are the same set, and each recorded extension still maps to the same type;
    //  - the same patched AssetDatabase, SharpZipLib and Colossal.Core builds are loaded.
    // A scan is recorded only when it finished without warnings or errors, every AddEntry call carried the expected
    // arguments, and the package file did not change while it was read. Replay calls the game's own AddEntry with the
    // recorded arguments in the recorded order, so ownership, collisions, events and nested packages behave as in a scan.
    public static class PackageCache
    {
        const string Magic = "CityStartupOptimizer.PackageCache";
        const int Format = 1;
        const int KeepGenerations = 30;

        sealed class Item
        {
            public int Type;
            public long Size, Offset;
            public Hash128 Hash;
            public string Name;
        }
        sealed class Package
        {
            public string Path;
            public long Length, Written, Created;
            public string Extensions;
            public int LastUsed;
            public string[] MappedExtensions;
            public int[] MappedTypes;
            public Item[] Items;
        }
        sealed class Frame
        {
            public FileSystemDataSource Source;
            public Entry Info;
            public Hash128 Guid;
            public long Offset;
            public bool Warn, Priority, Cacheable, Issue;
            public string Reason;
            public object NewData;
            public int Relative;
            public long Length, Written, Created;
            public string Extensions;
            public List<Item> Items;
            public Dictionary<string, int> Mapped;
        }

        delegate Identifier AddEntryCall(FileSystemDataSource source, DataSourceModification modification, bool warnCollision,
            string path, Type type, long size, long offset, bool priorityData, Hash128 guid, Hash128 package, string packageEntryName,
            bool fromCache, List<ValueTuple<Type, Identifier>> newData, int relativePathStartOverride);

        static readonly object gate = new object();
        static readonly object replayed = new object();
        static readonly Dictionary<string, Package> packages = new Dictionary<string, Package>(StringComparer.OrdinalIgnoreCase);
        static readonly List<string> typeNames = new List<string>();
        static readonly Dictionary<string, int> typeIndex = new Dictionary<string, int>(StringComparer.Ordinal);
        static readonly Dictionary<string, Type> resolved = new Dictionary<string, Type>(StringComparer.Ordinal);
        [ThreadStatic] static List<Frame> frames;
        static AddEntryCall addEntry;
        static object gameLog;
        static MethodInfo logError;
        static PropertyInfo factoryProperty;
        static string file, build;
        static bool enabled, loaded, dirty;
        static int generation;
        static Task loading;
        static int hits, hitEntries, recorded, rejected, uncacheable;
        static readonly Dictionary<string, int> declined = new Dictionary<string, int>(StringComparer.Ordinal);
        static long replayTicks;

        // Called once the verified libraries are loaded. Loading the file starts at once on a background thread.
        internal static void Start(string data)
        {
            string folder = Path.Combine(data, "ModsData", "CityStartupOptimizer");
            if (File.Exists(Path.Combine(folder, "no-package-cache.flag")))
            {
                Session.Event("Package cache disabled by no-package-cache.flag.");
                return;
            }
            UseFile(Path.Combine(folder, "cache", "packages.bin"));
        }

        // Also used by TestPackageCache.ps1 to point the cache at a scratch file.
        public static void UseFile(string path)
        {
            lock (gate)
            {
                file = path;
                enabled = true;
                loaded = false;
                packages.Clear(); typeNames.Clear(); typeIndex.Clear();
                hits = hitEntries = recorded = rejected = uncacheable = 0;
                declined.Clear();
                replayTicks = 0;
                loading = Task.Run((Action)Load);
            }
        }

        static string BuildId()
        {
            return typeof(FileSystemDataSource).Module.ModuleVersionId + "/" +
                typeof(ICSharpCode.SharpZipLib.Zip.ZipFile).Module.ModuleVersionId + "/" + typeof(Hash128).Module.ModuleVersionId;
        }

        static void Load()
        {
            long start = Stopwatch.GetTimestamp();
            string outcome;
            try
            {
                build = BuildId();
                if (!File.Exists(file)) outcome = "Package cache is empty; packages are scanned and recorded.";
                else
                {
                    using (var reader = new BinaryReader(new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16)))
                    {
                        if (reader.ReadString() != Magic || reader.ReadInt32() != Format || reader.ReadString() != build)
                            outcome = "Package cache was written by a different build and is ignored.";
                        else
                        {
                            int gen = reader.ReadInt32();
                            var names = new string[reader.ReadInt32()];
                            for (int i = 0; i < names.Length; i++) names[i] = reader.ReadString();
                            var read = new List<Package>();
                            int count = reader.ReadInt32(), entries = 0;
                            for (int p = 0; p < count; p++)
                            {
                                var package = new Package
                                {
                                    Path = reader.ReadString(), Length = reader.ReadInt64(), Written = reader.ReadInt64(), Created = reader.ReadInt64(),
                                    Extensions = reader.ReadString(), LastUsed = reader.ReadInt32()
                                };
                                int mapped = reader.ReadInt32();
                                package.MappedExtensions = new string[mapped];
                                package.MappedTypes = new int[mapped];
                                for (int m = 0; m < mapped; m++) { package.MappedExtensions[m] = reader.ReadString(); package.MappedTypes[m] = Check(reader.ReadInt32(), names.Length); }
                                package.Items = new Item[reader.ReadInt32()];
                                for (int i = 0; i < package.Items.Length; i++)
                                {
                                    package.Items[i] = new Item
                                    {
                                        Type = Check(reader.ReadInt32(), names.Length), Size = reader.ReadInt64(), Offset = reader.ReadInt64(),
                                        Hash = new Hash128(reader.ReadUInt32(), reader.ReadUInt32(), reader.ReadUInt32(), reader.ReadUInt32()),
                                        Name = reader.ReadString()
                                    };
                                }
                                entries += package.Items.Length;
                                read.Add(package);
                            }
                            if (reader.ReadString() != Magic) throw new InvalidDataException("Missing end marker");
                            lock (gate)
                            {
                                generation = gen;
                                foreach (var name in names) { typeIndex[name] = typeNames.Count; typeNames.Add(name); }
                                foreach (var package in read) packages[package.Path] = package;
                            }
                            outcome = "Package cache loaded " + read.Count + " packages with " + entries + " entries";
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                lock (gate) { packages.Clear(); typeNames.Clear(); typeIndex.Clear(); }
                outcome = "Package cache could not be read and is ignored. " + ex.GetType().Name;
            }
            lock (gate) loaded = true;
            Session.Event(outcome + " (" + Ms(start) + " ms).");
        }

        static int Check(int index, int count)
        {
            if (index < 0 || index >= count) throw new InvalidDataException("Type index out of range");
            return index;
        }

        static string Ms(long start)
        {
            return ((Stopwatch.GetTimestamp() - start) * 1000.0 / Stopwatch.Frequency).ToString("F1", System.Globalization.CultureInfo.InvariantCulture);
        }

        static string Fingerprint(IReadOnlyCollection<string> extensions)
        {
            var list = new List<string>(extensions);
            list.Sort(StringComparer.Ordinal);
            return string.Join("|", list.ToArray());
        }

        static bool Stat(string path, out long length, out long written, out long created)
        {
            length = written = created = 0;
            try
            {
                var info = new FileInfo(path);
                if (!info.Exists) return false;
                length = info.Length;
                written = info.LastWriteTimeUtc.Ticks;
                created = info.CreationTimeUtc.Ticks;
                return true;
            }
            catch (Exception) { return false; }
        }

        static void Bind()
        {
            if (addEntry != null) return;
            var method = typeof(FileSystemDataSource).GetMethod("AddEntry", BindingFlags.Instance | BindingFlags.NonPublic, null, new[]
            {
                typeof(DataSourceModification), typeof(bool), typeof(string), typeof(Type), typeof(long), typeof(long), typeof(bool),
                typeof(Hash128), typeof(Hash128), typeof(string), typeof(bool), typeof(List<ValueTuple<Type, Identifier>>), typeof(int)
            }, null);
            if (method == null) throw new MissingMethodException("FileSystemDataSource.AddEntry");
            factoryProperty = typeof(FileSystemDataSource).GetProperty("assetFactory", BindingFlags.Instance | BindingFlags.Public);
            var logField = typeof(FileSystemDataSource).GetField("log", BindingFlags.Static | BindingFlags.NonPublic);
            gameLog = logField == null ? null : logField.GetValue(null);
            if (gameLog != null) logError = gameLog.GetType().GetMethod("Error", new[] { typeof(Exception), typeof(object) });
            addEntry = (AddEntryCall)Delegate.CreateDelegate(typeof(AddEntryCall), method);
        }

        static List<Frame> Frames { get { return frames ?? (frames = new List<Frame>()); } }

        static void Decline(Frame frame, string reason)
        {
            if (frame.Issue) return;
            frame.Issue = true;
            frame.Reason = reason;
        }

        // Start of PopulateFromPackage, after the package entry and file were found. Returns a marker for a replayed
        // package (the method then returns at once) or the frame to pass to PackageEnd.
        public static object PackageBegin(FileSystemDataSource source, Entry info, Hash128 guid, long offset, bool warnCollision,
            bool priorityData, List<ValueTuple<Type, Identifier>> newData, int relativePathStartOverride, IReadOnlyCollection<string> supported)
        {
            var frame = new Frame
            {
                Source = source, Info = info, Guid = guid, Offset = offset, Warn = warnCollision, Priority = priorityData,
                NewData = newData, Relative = relativePathStartOverride
            };
            try
            {
                Bind();
                Task wait;
                lock (gate) wait = enabled && !loaded ? loading : null;
                if (wait != null) wait.Wait();
                bool on;
                lock (gate) on = enabled;
                frame.Cacheable = on && offset == 0 && info != null && !info.isPackaged && info.path != null && supported != null &&
                    Stat(info.path, out frame.Length, out frame.Written, out frame.Created);
                if (frame.Cacheable)
                {
                    frame.Extensions = Fingerprint(supported);
                    Package package;
                    lock (gate) packages.TryGetValue(info.path, out package);
                    if (package != null && Replay(frame, package)) return replayed;
                    frame.Items = new List<Item>();
                    frame.Mapped = new Dictionary<string, int>(StringComparer.Ordinal);
                }
                else Interlocked.Increment(ref uncacheable);
            }
            catch (Exception ex)
            {
                frame.Cacheable = false;
                string reason = "of an internal error (" + ex.GetType().Name + ": " + ex.Message + ")";
                bool first;
                lock (gate) { int n; first = !declined.TryGetValue(reason, out n); declined[reason] = n + 1; }
                if (first) Session.Event("Package cache unavailable. Using the game's scan. " + ex);
            }
            Frames.Add(frame);
            return frame;
        }

        public static bool Replayed(object frame) { return ReferenceEquals(frame, replayed); }

        static bool Replay(Frame frame, Package package)
        {
            if (package.Length != frame.Length || package.Written != frame.Written || package.Created != frame.Created ||
                !string.Equals(package.Extensions, frame.Extensions, StringComparison.Ordinal))
            {
                Interlocked.Increment(ref rejected);
                return false;
            }
            var factory = factoryProperty == null ? null : factoryProperty.GetValue(frame.Source, null) as IAssetFactory;
            if (factory == null) return false;
            var types = new Type[typeNames.Count];
            lock (gate)
            {
                for (int m = 0; m < package.MappedExtensions.Length; m++)
                {
                    int index = package.MappedTypes[m];
                    Type current, recordedType;
                    if (!factory.GetAssetType(package.MappedExtensions[m], out current) || (recordedType = Resolve(typeNames[index])) == null ||
                        current != recordedType)
                    {
                        Interlocked.Increment(ref rejected);
                        return false;
                    }
                    types[index] = recordedType;
                }
            }
            foreach (var item in package.Items)
                if (types[item.Type] == null) { Interlocked.Increment(ref rejected); return false; }
            long start = Stopwatch.GetTimestamp();
            var newData = (List<ValueTuple<Type, Identifier>>)frame.NewData;
            foreach (var item in package.Items)
            {
                try
                {
                    addEntry(frame.Source, DataSourceModification.Added, frame.Warn, frame.Info.path, types[item.Type], item.Size,
                        frame.Offset + item.Offset, frame.Priority, item.Hash, frame.Guid, item.Name, false, newData, frame.Relative);
                }
                catch (Exception ex)
                {
                    // The game's scan logs the same message for a failed entry and continues with the next one.
                    string message = "Failed to add '" + item.Name + "' to '" + frame.Source.GetType().Name + "' data source";
                    if (logError != null) logError.Invoke(gameLog, new object[] { ex, message });
                    Session.Event("Package cache replay: " + message + ". " + ex.GetType().Name);
                }
            }
            lock (gate)
            {
                package.LastUsed = generation + 1;
                hits++;
                hitEntries += package.Items.Length;
                replayTicks += Stopwatch.GetTimestamp() - start;
            }
            return true;
        }

        static Type Resolve(string name)
        {
            Type type;
            if (!resolved.TryGetValue(name, out type)) resolved[name] = type = Type.GetType(name, false);
            return type;
        }

        // Replaces the game's AddEntry call inside PopulateFromPackage. Records the entry, then makes the same call.
        public static Identifier PackageEntry(FileSystemDataSource source, DataSourceModification modification, bool warnCollision,
            string path, Type type, long size, long offset, bool priorityData, Hash128 guid, Hash128 package, string packageEntryName,
            bool fromCache, List<ValueTuple<Type, Identifier>> newData, int relativePathStartOverride)
        {
            var list = frames;
            var frame = list != null && list.Count > 0 ? list[list.Count - 1] : null;
            if (frame != null && frame.Cacheable && !frame.Issue)
            {
                if (!ReferenceEquals(source, frame.Source) || modification != DataSourceModification.Added || warnCollision != frame.Warn ||
                    !string.Equals(path, frame.Info.path, StringComparison.Ordinal) || priorityData != frame.Priority || !package.Equals(frame.Guid) ||
                    fromCache || !ReferenceEquals(newData, frame.NewData) || relativePathStartOverride != frame.Relative || packageEntryName == null ||
                    type == null || offset < frame.Offset)
                {
                    Decline(frame, "unexpected entry arguments");
                }
                else
                {
                    string extension = Path.GetExtension(packageEntryName);
                    int index = TypeIndex(type);
                    int mapped;
                    if (frame.Mapped.TryGetValue(extension, out mapped)) { if (mapped != index) Decline(frame, "one extension with two types"); }
                    else frame.Mapped.Add(extension, index);
                    frame.Items.Add(new Item { Type = index, Size = size, Offset = offset - frame.Offset, Hash = guid, Name = packageEntryName });
                }
            }
            if (addEntry == null) Bind();
            return addEntry(source, modification, warnCollision, path, type, size, offset, priorityData, guid, package, packageEntryName,
                fromCache, newData, relativePathStartOverride);
        }

        static int TypeIndex(Type type)
        {
            string name = type.AssemblyQualifiedName;
            lock (gate)
            {
                int index;
                if (!typeIndex.TryGetValue(name, out index))
                {
                    index = typeNames.Count;
                    typeNames.Add(name);
                    typeIndex.Add(name, index);
                    resolved[name] = type;
                }
                return index;
            }
        }

        // Before each warning or error the game logs while scanning a package: none of the open scans is recorded.
        public static void PackageIssue()
        {
            var list = frames;
            if (list != null) foreach (var frame in list) Decline(frame, "the game logged a warning or error");
        }

        // Normal completion of PopulateFromPackage.
        public static void PackageEnd(object value)
        {
            var frame = value as Frame;
            var list = frames;
            if (frame == null || list == null) return;
            int at = list.LastIndexOf(frame);
            if (at < 0) return;
            if (at != list.Count - 1) Decline(frame, "a nested package scan ended abnormally");
            list.RemoveRange(at, list.Count - at);
            if (!frame.Cacheable) return;
            long length, written, created;
            if (!frame.Issue && (!Stat(frame.Info.path, out length, out written, out created) || length != frame.Length || written != frame.Written || created != frame.Created))
                Decline(frame, "the file changed while it was read");
            if (frame.Issue)
            {
                lock (gate) { int n; declined.TryGetValue(frame.Reason, out n); declined[frame.Reason] = n + 1; }
                return;
            }
            length = frame.Length; written = frame.Written; created = frame.Created;
            var package = new Package
            {
                Path = frame.Info.path, Length = length, Written = written, Created = created, Extensions = frame.Extensions,
                Items = frame.Items.ToArray(), MappedExtensions = new string[frame.Mapped.Count], MappedTypes = new int[frame.Mapped.Count]
            };
            int i = 0;
            foreach (var pair in frame.Mapped) { package.MappedExtensions[i] = pair.Key; package.MappedTypes[i] = pair.Value; i++; }
            lock (gate)
            {
                if (!enabled) return;
                package.LastUsed = generation + 1;
                packages[package.Path] = package;
                recorded++;
                dirty = true;
            }
        }

        internal static string Summary()
        {
            lock (gate)
            {
                if (!enabled) return "Package cache off.";
                return "Package cache replayed " + hits + " packages (" + hitEntries + " entries, " +
                    (replayTicks * 1000.0 / Stopwatch.Frequency).ToString("F0", System.Globalization.CultureInfo.InvariantCulture) +
                    " ms), recorded " + recorded + ", rejected " + rejected + " changed recordings, " + uncacheable + " packages not cacheable" +
                    Reasons() + ".";
            }
        }

        static string Reasons()
        {
            if (declined.Count == 0) return "";
            var parts = new List<string>();
            foreach (var pair in declined) parts.Add(pair.Value + " not recorded because " + pair.Key);
            return ", " + string.Join(", ", parts.ToArray());
        }

        // Writes new recordings on a background thread. Keeps recordings of other playsets for a while if their file is unchanged.
        public static void SaveLater()
        {
            lock (gate) if (!enabled || !dirty) return;
            Task.Run((Action)Save);
        }

        // Synchronous form, for tests and the background writer.
        public static void Save()
        {
            List<Package> snapshot;
            string[] names;
            int gen;
            string target;
            lock (gate)
            {
                if (!enabled || !dirty || !loaded) return;
                dirty = false;
                gen = ++generation;
                snapshot = new List<Package>(packages.Values);
                names = typeNames.ToArray();
                target = file;
            }
            try
            {
                var keep = new List<Package>();
                foreach (var package in snapshot)
                {
                    if (package.LastUsed >= gen) { keep.Add(package); continue; }
                    long length, written, created;
                    if (gen - package.LastUsed <= KeepGenerations && Stat(package.Path, out length, out written, out created) &&
                        length == package.Length && written == package.Written && created == package.Created)
                        keep.Add(package);
                }
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                string temp = target + "." + Process.GetCurrentProcess().Id + ".tmp";
                int entries = 0;
                using (var writer = new BinaryWriter(new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16)))
                {
                    writer.Write(Magic); writer.Write(Format); writer.Write(build ?? BuildId()); writer.Write(gen);
                    writer.Write(names.Length);
                    foreach (var name in names) writer.Write(name);
                    writer.Write(keep.Count);
                    foreach (var package in keep)
                    {
                        writer.Write(package.Path); writer.Write(package.Length); writer.Write(package.Written); writer.Write(package.Created);
                        writer.Write(package.Extensions); writer.Write(package.LastUsed);
                        writer.Write(package.MappedExtensions.Length);
                        for (int m = 0; m < package.MappedExtensions.Length; m++) { writer.Write(package.MappedExtensions[m]); writer.Write(package.MappedTypes[m]); }
                        writer.Write(package.Items.Length);
                        foreach (var item in package.Items)
                        {
                            writer.Write(item.Type); writer.Write(item.Size); writer.Write(item.Offset);
                            writer.Write(item.Hash.value.x); writer.Write(item.Hash.value.y); writer.Write(item.Hash.value.z); writer.Write(item.Hash.value.w);
                            writer.Write(item.Name);
                        }
                        entries += package.Items.Length;
                    }
                    writer.Write(Magic);
                }
                if (File.Exists(target)) File.Replace(temp, target, null);
                else File.Move(temp, target);
                Session.Event("Package cache saved " + keep.Count + " packages with " + entries + " entries.");
            }
            catch (Exception ex)
            {
                lock (gate) dirty = true;
                Session.Event("Package cache could not be saved. " + ex.GetType().Name + ": " + ex.Message);
            }
        }
    }
}
