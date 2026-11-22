using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;

namespace CityStartupOptimizer
{
    // UnityDoorstop 3 calls the parameterless Main in the configured target assembly.
    public static class Bootstrap
    {
        static bool Matches(string path, string expected)
        {
            if (!File.Exists(path)) return false;
            using (var file = File.OpenRead(path))
            using (var hash = SHA256.Create())
                return BitConverter.ToString(hash.ComputeHash(file)).Replace("-", "") == expected;
        }

        public static void Main()
        {
            string game = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);
            string data = Path.Combine(Path.GetDirectoryName(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)),
                "LocalLow", "Colossal Order", "Cities Skylines II");
            Start(game, data);
        }

        static void Start(string game, string data)
        {
            Action<string> log = delegate {};
            try
            {
                string managed = Path.Combine(game, "Cities2_Data", "Managed");
                string package = Path.GetDirectoryName(typeof(Bootstrap).Assembly.Location);
                string helper = Path.Combine(package, "CityStartupRuntime.dll");
                if (!Matches(helper, Build.Runtime)) return;
                var session = Assembly.LoadFrom(helper).GetType("CityStartupOptimizer.Session", true);
                session.GetMethod("Start").Invoke(null, new object[] { data });
                log = (Action<string>)Delegate.CreateDelegate(typeof(Action<string>), session.GetMethod("Event"));
                string database = "Colossal.IO.AssetDatabase.dll", gameDll = "Game.dll";
                if (!Matches(Path.Combine(managed, database), Build.StockDatabase) ||
                    !Matches(Path.Combine(managed, gameDll), Build.StockGame) ||
                    !Matches(Path.Combine(managed, "Colossal.Core.dll"), Build.StockCore) ||
                    !Matches(Path.Combine(managed, "ICSharpCode.SharpZipLib.dll"), Build.StockZip))
                {
                    log("Stock loading selected. The installed game build differs from the tested build.");
                    return;
                }
                // The patched libraries live in Managed\CityStartupOptimizer\ so that Assembly.Location stays inside the
                // game's Managed folder, where mods and the game expect game assemblies (see Loading.SameAssemblyFile).
                string relocated = Path.Combine(managed, "CityStartupOptimizer");
                if (!Matches(Path.Combine(relocated, database), Build.Database) || !Matches(Path.Combine(relocated, gameDll), Build.Game))
                {
                    log("Stock loading selected. The optimizer files failed verification.");
                    return;
                }
                foreach (var a in AppDomain.CurrentDomain.GetAssemblies())
                {
                    if (a.GetName().Name == "Game" || a.GetName().Name == "Colossal.IO.AssetDatabase")
                    {
                        log("Stock loading selected. Game assemblies were loaded before the optimizer.");
                        return;
                    }
                }
                foreach (var name in new[] { database, gameDll })
                {
                    var file = Path.Combine(relocated, name);
                    var loaded = Assembly.LoadFrom(file);
                    if (!String.Equals(Path.GetFullPath(loaded.Location), Path.GetFullPath(file), StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException(name + " was already bound to another location");
                    log("Loaded verified " + name);
                }
                log("Enabled pack prefix reuse, indexed registration misses, one-frame prefab batches, overlapping native studio screens and 64 KiB directory and 30-byte ZIP entry-header reads.");
            }
            catch (Exception ex) { log("Optimizer initialization stopped. " + ex); }
        }
    }
}



