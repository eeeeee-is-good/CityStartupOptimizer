"""Compare protected Pittman Center runs, including the stock pack ownership inventory."""
import csv
import hashlib
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent / "settings-load-test"))
from compare import index, unpack


def text(path):
    return path.read_text(encoding="utf-8-sig")


def rows(path):
    with path.open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def session(run):
    return Path(text(run / "session-path.txt").strip())


def warnings(run, module, cutoff=None):
    messages = re.findall(r"^\[([\d:, -]+)\] (?:\{.*?\} )?\[(WARN|ERROR|CRITICAL|FATAL)\]\s+(.*)$",
                          text(run / (module + ".log")), re.M)
    return Counter((level, re.sub(r"\$\d+\b", "$id", msg.strip())) for stamp, level, msg in messages
                   if cutoff is None or stamp <= cutoff)


def settings(run, stage):
    return {key: unpack(value) for key, value in index(run / stage / "files").items()}


def compare(baseline, candidate, through_quit=False):
    a, b = session(baseline), session(candidate)
    checks = {}
    checks["starting_settings"] = settings(baseline, "baseline") == settings(candidate, "baseline")
    old, new = settings(baseline, "exit"), settings(candidate, "exit")
    changed = sorted(k for k in old.keys() | new.keys() if old.get(k) != new.get(k))
    checks["resulting_settings"] = not changed
    print("Exit settings differing by value:", changed)
    for key in changed:
        print("  differing keys:", [k for k in old.get(key, {}).keys() | new.get(key, {}).keys()
                                    if old.get(key, {}).get(k) != new.get(key, {}).get(k)][:20])
    packs_a, packs_b = rows(a / "packs.tsv"), rows(b / "packs.tsv")
    fields = ["pack", "assets_owned", "entries_compared"]
    checks["pack_counts_and_order"] = [tuple(r[k] for k in fields) for r in packs_a] == [tuple(r[k] for k in fields) for r in packs_b]
    reference = ROOT.parent / "startup-profile/results-20261121-152133/2-original-wait/ownership.tsv"
    ids = defaultdict(list)
    for line in text(reference).splitlines():
        pack, asset = line.split("\t")
        ids[Path(pack).name].append(asset)
    def same_ids(row):
        keys = sorted(ids.get(row["pack"], []))
        digest = hashlib.sha256("\n".join(keys).encode()).hexdigest().upper()
        return row.get("verified_ids_sha256") == digest and int(row["assets_owned"]) == len(keys)
    checks["stock_pack_asset_ids"] = (all(same_ids(row) for row in packs_b)
        and set(ids) <= {row["pack"] for row in packs_b})
    def dependencies(folder):
        return Counter((r["package_path"], r["file_path"], r["result"]) for r in rows(folder / "registration.tsv"))
    checks["dependency_results"] = dependencies(a) == dependencies(b)
    def mods(run):
        return sorted(re.findall(r"\[INFO\]\s+Loaded (.+?, Version=.*?) in [\d.]+ms", text(run / "Modding.log")))
    checks["initialized_mods"] = bool(mods(baseline)) and mods(baseline) == mods(candidate)
    for key, file, pattern in [
        ("ui_module_ids", "Modding", r"Registered UI Module .*?\(UIModuleAsset:([0-9a-f]{32})"),
        ("importer_cache_names", "ExtraAssetsImporter", r"Cached data for (.*?), loading the cache\."),
    ]:
        previous = Counter(re.findall(pattern, text(baseline / (file + ".log"))))
        checks[key] = bool(previous) and previous == Counter(re.findall(pattern, text(candidate / (file + ".log"))))
    def config(run):
        return json.loads(re.search(r"Configuration: (\{.*\})", text(run / "SceneFlow.log")).group(1))
    before, after = config(baseline), config(candidate)
    prior_skip, candidate_skip = before.pop("noSplash"), after.pop("noSplash")
    startup_log = text(b / "session.log")
    if "overlapping native studio screens" in startup_log:
        screens = re.findall(r"Studio overlay activated: (\w+)", startup_log)
        checks["native_studio_sequence"] = (candidate_skip is False and
            screens == ["Splash1", "SplashIceflake", "Splash2", "Splash4"] and
            "Studio sequence completed." in startup_log)
    else:
        checks["native_noSplash"] = prior_skip is False and candidate_skip is True
    checks["other_game_flags"] = before == after
    selected = re.search(r"Buffered archive directories=(\d+)", text(b / "session.log"))
    checks["buffered_all_test_packages"] = selected is not None and int(selected.group(1)) == 263
    for file, pattern in [
        ("SceneFlow", r"Loaded (\d+) prefabs in"),
        ("ExtraAssetsImporter", r"saving (\d+) assets\."),
        ("SimpleModCheckerPlus", r"((?:Game Settings|Keybinds|Mod Settings) Restoration (?:Complete|Failed))")
    ]:
        old_values = re.findall(pattern, text(baseline / (file + ".log")))
        checks[file + "_results"] = bool(old_values) and old_values == re.findall(pattern, text(candidate / (file + ".log")))
    def cutoff(run):
        return re.search(r"^\[([\d:, -]+)\].*\[harness\] > quit\s*$", text(run / "CS2TestHarness.log"), re.M).group(1) if through_quit else None
    print("Warning comparison window:", "launch through Quit request" if through_quit else "full launch through process exit")
    for module in ["SceneFlow", "Modding", "FileSystem", "ExtraAssetsImporter", "SimpleModCheckerPlus"]:
        old_warnings, new_warnings = warnings(baseline, module, cutoff(baseline)), warnings(candidate, module, cutoff(candidate))
        gained, lost = new_warnings - old_warnings, old_warnings - new_warnings
        print(module, "new warning/error occurrences:", sum(gained.values()), "removed:", sum(lost.values()))
        if gained:
            print("  examples:", list(gained.items())[:4])
        checks[module + "_no_new_warnings_or_errors"] = not gained
    batches = rows(b / "prefabs.tsv")
    checks["one_frame_batches"] = len(batches) == len(rows(a / "prefabs.tsv")) and all(r["wait_frames"] == "1" for r in batches)
    for arm in [a, b]:
        timeline = rows(arm / "timeline.tsv")
        marks = [r["event"] for r in timeline]
        checks[arm.name + "_city"] = ("City loading complete. Missing-prefab warnings=0" in marks and
            "Test harness observed playable city" in marks and "ExtraAssetsImporter finished" in marks and
            next(r["event_utc"] for r in timeline if r["event"] == "ExtraAssetsImporter finished")
            <= next(r["event_utc"] for r in timeline if r["event"] == "City load requested"))
        for r in timeline:
            if r["event"] in ["Main menu reached", "Test harness observed playable city"]:
                print(arm.name, r["event"], r["seconds_from_steam_launcher"], r["seconds_from_game_process"])
    for run in [baseline, candidate]:
        checks[run.name + "_save_and_settings_integrity"] = "Verified save, sidecar, playset definition" in text(run / "integrity.txt")
        checks[run.name + "_playset_file"] = text(run / "playset-integrity.txt").strip().endswith("True")
    print("Content counts:", len(packs_b), sum(int(r["assets_owned"]) for r in packs_b), sum(dependencies(b).values()), len(mods(candidate)), len(batches))
    failed = [k for k, v in checks.items() if not v]
    print("Failed checks:", failed)
    return not failed


if __name__ == "__main__":
    sys.exit(0 if compare(Path(sys.argv[1]), Path(sys.argv[2]), "--through-quit" in sys.argv[3:]) else 1)

