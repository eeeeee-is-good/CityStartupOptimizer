# City Startup Optimizer

Launch Cities: Skylines II from Steam as usual. The existing UnityDoorstop loader starts the optimizer before the game applies the active playset. It checks the installed game libraries against the tested 1.6.4f1 build on every launch. A different build selects the game's stock loading path and records the reason in `session.log`.

The game shows its native studio sequence while startup loading proceeds. Both screen tasks finish before the main menu opens. The optimizer reads playset archive directories through a 64 KiB buffer. During entry scanning it buffers the 30-byte fixed part of each local ZIP header. SharpZipLib still validates those headers, and bulk reads use the original stream at the correct offset. Other stream types keep the game's own read path. The optimizer also reuses identical pack-path comparisons and indexes paths to skip unsuccessful dependency scans during mod registration. Candidate matches still go through the game's lookup, preserving its choice between duplicates. The initial prefab loader waits one frame between batches. The player controls when to open a city.

During playset loading, the optimizer builds an in-memory index of asset IDs by physical path. It uses this index to narrow the candidates for each pack, then applies the existing ownership checks and writes. Each playset application builds its own index.

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

## Disable or re-enable

Close the game. In Windows PowerShell or PowerShell 7, from this folder, run `.\Install.ps1 -Mode Disable` to restore the original loader configuration byte for byte. Run `.\Install.ps1 -Mode Enable` to enable the verified build again. The install stores its rollback copy at `CityStartupOptimizer\previous-doorstop.ini` inside the game's Steam folder.


