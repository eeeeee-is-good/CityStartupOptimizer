# City Startup Optimizer

Launch Cities: Skylines II from Steam as usual. The existing UnityDoorstop loader starts the optimizer before the game applies the active playset. It checks the installed game libraries against the tested 1.6.4f1 build on every launch. A different build selects the game's stock loading path and records the reason in `session.log`.

The game shows its native studio sequence while startup loading proceeds. Both screen tasks finish before the main menu opens. The optimizer reads playset archive directories through a 64 KiB buffer. During entry scanning it buffers the 30-byte fixed part of each local ZIP header. SharpZipLib still validates those headers, and bulk reads use the original stream at the correct offset. Other stream types keep the game's own read path. The optimizer also reuses identical pack-path comparisons and indexes paths to skip unsuccessful dependency scans during mod registration. Candidate matches still go through the game's lookup, preserving its choice between duplicates. The initial prefab loader waits one frame between batches. The player controls when to open a city.

During playset loading, the optimizer builds an in-memory index of asset IDs by physical path. It uses this index to narrow the candidates for each pack, then applies the existing ownership checks and writes. Each playset application builds its own index.

## Package cache

Every launch, the game opens each `.cok` package, from your mods and its own content, and reads one small `.cid` entry per asset inside it. With the tested playset that is about 145,000 small reads spread across 130 GB of packages. After a Windows restart none of them are in memory, so they cost roughly 10 seconds. The package cache records what each package contributed the first time it is scanned. On later launches it hands the game the same entries without opening the package. The game still registers every asset itself, so ownership, duplicates and events work as before.

A recording is used only if the package file has the same path, size, modification time and creation time, and if the game supports the same file types and maps each one to the same asset type. It must also have been written by the same game libraries. Anything else, including a mod update, scans the package normally and records it again. A scan is recorded only when it finishes without warnings or errors. The cache lives in `ModsData\CityStartupOptimizer\cache\packages.bin` and keeps recordings for other playsets while their packages are unchanged. `session.log` reports how many packages were replayed, scanned or not recorded, and why. To turn the cache off, create an empty `no-package-cache.flag` file in `ModsData\CityStartupOptimizer`. Deleting `packages.bin` is always safe.

In the game, with the Pittman Center playset, every pack's asset IDs matched a run with the cache turned off, and so did the prefab count and missing-prefab warnings. On a repeat launch, applying the playset took 14–16 seconds instead of 18–20.

## Background prefetch

After a Windows restart, startup also waits on other files. The first studio screen appeared 17 seconds later than on a repeat launch. As soon as the optimizer's checks pass, four threads below normal CPU priority read about 460 large files ahead of the game (about 1 GiB):

1. Unity's startup data.
2. The engine and plugins.
3. The DLLs in the mod folders used by your last playset.

They skip the large content packages and any file over 256 MiB, and stop after 3 minutes. They read at most an eighth of your RAM or 5 GiB, whichever is less. A drive that reports a seek penalty (a hard disk), or does not answer, is left alone.

An earlier version also read the game's interface files and all loose mod files, about 17,000 small files. On a repeat launch that made the main menu appear about 21 seconds later, so small files are no longer read. The current version finishes in about half a second on a repeat launch and does not delay startup. Its effect after a Windows restart has not been measured yet. `session.log` records when each group finished. To turn it off, create `no-prefetch.flag` in `ModsData\CityStartupOptimizer`.

The patched `Game.dll` and `Colossal.IO.AssetDatabase.dll` are installed in `Cities2_Data\Managed\CityStartupOptimizer\`, next to the originals, which stay untouched. Their `Assembly.Location` therefore stays inside the game's `Managed` folder, where mods expect game assemblies (Write Everywhere, for example, labels types as coming from the game by that path). The game's check that skips game libraries shipped inside a mod pairs the relocated copy with the original file. A mod that hashes `Game.dll` at its location still sees the patched file.

These changes apply to the active playset before you choose a save. The installed game build and the Pittman Center playset are the tested configuration. Other saves still need their own required mods and assets, and playsets with background importers may need time at the menu. The game honors explicit splash options in the Steam launch arguments.

## Reading a launch

Open `%USERPROFILE%\AppData\LocalLow\Colossal Order\Cities Skylines II\ModsData\CityStartupOptimizer\Logs` and choose the newest folder. Folder names use UTC and the game process ID. The logger retains the latest 12 sessions.

| File | Contents |
| --- | --- |
| `timeline.tsv` | Steam launcher and game-process times, mod registration and initialization, prefab count and duration, main menu, EAI completion, city load request and completion, and the count of missing-prefab warnings from SceneFlow during each city load. A benchmark with the test harness also records its playable-city observation. The Steam column is blank if the launcher cannot be matched to this game process. |
| `session.log` | Loader decision, playset and registration boundaries, buffered archive directory count and time, number of indexed misses and stock hits, and count of one-frame prefab waits. |
| `packs.tsv` | One row per pack, with population and mapping time, comparisons, reused results, and asset ownership count. Content-validation runs include a SHA-256 digest of the pack's sorted asset IDs. |
| `registration.tsv` | Candidate paths, indexed misses, stock scans and resolved asset IDs. |
| `prefabs.tsv` | Batch number, wait setting, and elapsed wall time since the previous batch or the start of prefab loading. The interval includes batch work. |
| `game-events.log` | Loading milestones, mod timings, EAI activity, Simple Mod Checker Plus backup and restore messages, and loading warnings with their original local timestamps. |
| `resources.tsv` | Two-second samples of cumulative game-process CPU time, working set, and private memory during startup and city loading. |

For Pittman Center, the timeline entry `ExtraAssetsImporter finished` marks when imported surfaces and decals are ready. Opening the save before it can produce unknown-prefab warnings. Search `game-events.log` for `Unknown prefab ID` to see the asset names.

## Validation script

`Verify.ps1` is the end-to-end check used while developing the optimizer, and it only runs on the author's machine. It launches the game through the CS2 Test Harness, opens one particular save, pauses, and quits. It then confirms that the optimizer's session log recorded the playset, dependency-resolution and prefab steps, and that the save, active playset and settings files are unchanged. It depends on files outside this repository:

- `..\settings-load-test\snapshots.ps1`, which backs up and restores the game's settings files.
- The harness runner `cs2-test.ps1`, given by `-Runner` (the default is the author's local copy), and one specific CS2TestHarness build, checked by hash.
- A save named by `-SaveName`, found under the game's Saves folder; the default is the author's Pittman Center test save.
- With `-WaitForImporter`, a staged harness from `..\pittman-loading` that waits for ExtraAssetsImporter before opening the save.

`-CompareContents` turns on the content audit, which adds a SHA-256 digest of each pack's asset IDs to `packs.tsv`. To check your own installation, run `TestFallback.ps1` and read the session logs described in "Reading a launch". `TestFallback.ps1` runs without starting the game. Run it with PowerShell 7 after `Build.ps1`. It reads the game folder from the modding toolchain's `CSII_MANAGEDPATH` variable.

`TestPackageCache.ps1` also runs without the game. It registers the same folders three times, each in a fresh process: with the stock asset database, while the patched one records, and while it replays from the cache. It requires identical entries every time. With no arguments it uses a small package copied from the game, then checks that a changed package and a corrupt cache file fall back to the normal scan. Pass `-Root` or `-RootFile` (one folder per line) to test real mod folders. They are only read, and the script checks that they are unchanged afterwards.

## Disable or re-enable

Close the game. In Windows PowerShell or PowerShell 7, from this folder, run `.\Install.ps1 -Mode Disable` to restore the original loader configuration byte for byte. Run `.\Install.ps1 -Mode Enable` to enable the verified build again. The install stores its rollback copy at `CityStartupOptimizer\previous-doorstop.ini` inside the game's Steam folder.


