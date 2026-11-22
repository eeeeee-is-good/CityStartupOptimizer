param(
    [switch]$WaitForImporter,
    [switch]$CompareContents,
    # The CS2 Test Harness runner script.
    [string]$Runner = (Join-Path $env:USERPROFILE 'Documents/CS2 Road Sign Generator/CS2TestHarness/cs2-test.ps1'),
    # The save the harness opens, by name (as in Load Game).
    [string]$SaveName = '20-November-22-29-14'
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../settings-load-test/snapshots.ps1"
$data = $env:CSII_USERDATAPATH
$harness = Join-Path $data 'ModsData/CS2TestHarness'
$auditFlag = Join-Path $data 'ModsData/CityStartupOptimizer/verify-content.flag'
$out = Join-Path $harness 'out'
# Saves sit in a per-account folder under Saves; find the one save with this name.
$save = @(Get-ChildItem -LiteralPath (Join-Path $data 'Saves') -Recurse -File -Filter "$SaveName.cok" | Select-Object -ExpandProperty FullName)
if ($save.Count -ne 1) { throw "Expected exactly one save named $SaveName, found $($save.Count)" }
$save = $save[0]
$playset = Join-Path $data '.cache/Mods/playset_config.json'
$round = [IO.Directory]::CreateDirectory("$PSScriptRoot/validation-$(Get-Date -Format yyyyMMdd-HHmmss)").FullName
function Definition {
    $c = Get-Content -LiteralPath $playset -Raw | ConvertFrom-Json
    $p = $c.playsets | Where-Object id -eq $c.activePlaysetId
    if (!$p) { throw 'Active playset missing' }
    [ordered]@{id=$p.id;mods=$p.mods;presentation=$p.presentation;autoSorted=$p.isAutoSorted} | ConvertTo-Json -Depth 30 -Compress
}
if (Get-Process Cities2 -ErrorAction SilentlyContinue) { throw 'Another city session is open' }
if ($CompareContents -and (Test-Path $auditFlag)) { throw 'An existing content audit is active.' }
foreach ($control in 'running.lock','commands.txt','live.txt','wait-for-importer.flag','prefab-frames.txt') {
    if (Test-Path "$harness/$control") { throw "Existing harness control $control" }
}
if ((Get-FileHash "$env:CSII_LOCALMODSPATH/CS2TestHarness/CS2TestHarness.dll").Hash -ne '00F26AAB8002AB586F119807B590FA98E9102A20D829F8382FB002D5F8025ABF') { throw 'Unexpected test harness' }
$fingerprints = @($save,"$save.cid") | Get-FileHash | Select-Object -ExpandProperty Hash
$before = Definition
$playsetBefore = (Get-FileHash $playset).Hash
Save-TestSnapshot $data "$round/baseline"
$hadOut=Test-Path $out
if ([IO.Path]::GetFullPath($out) -cne [IO.Path]::GetFullPath("$data/ModsData/CS2TestHarness/out") -or (Get-Item $harness).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected harness path' }
if ($hadOut) {
    if ((Get-Item $out).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected output link' }
    Move-Item -LiteralPath $out -Destination "$round/prior-out"
}
$started = Get-Date
$started.ToString('O') | Set-Content "$round/started.txt"
Write-Host "Starting protected validation $round"
try {
    if ($CompareContents) {
        [IO.File]::Open($auditFlag,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read).Dispose()
        $ownsAuditFlag = $true
    }
    if ($WaitForImporter) {
        $dll = "$env:CSII_LOCALMODSPATH/CS2TestHarness/CS2TestHarness.dll"
        Copy-Item -LiteralPath $dll -Destination "$round/original-harness.dll"
        Copy-Item -LiteralPath "$PSScriptRoot/../pittman-loading/staged/CS2TestHarness/CS2TestHarness.dll" -Destination $dll -Force
        [IO.File]::WriteAllText("$harness/wait-for-importer.flag",'Validation only')
    }
    # The harness sends quit itself. Let Unity finish teardown before considering a window close.
    & $Runner -NoBuild -KeepOpen -Commands @("loadsave $SaveName",'speed 0','wait 6','quit') -WaitForOtherMinutes 0 -LoadTimeoutMinutes 8 -TimeoutMinutes 10 *> "$round/runner.log"
    $status=$LASTEXITCODE
} finally {
    $closing=Get-Process Cities2 -ErrorAction SilentlyContinue | Where-Object StartTime -ge $started
    if ($closing -and !$closing.WaitForExit(45000)) {
        $null=$closing.CloseMainWindow()
        $null=$closing.WaitForExit(20000)
    }
    if ($ownsAuditFlag) { Remove-Item -LiteralPath $auditFlag }
    if (Get-Process Cities2 -ErrorAction SilentlyContinue) { throw "Validation still open. Snapshot $round/baseline" }
    if ($WaitForImporter -and (Test-Path "$round/original-harness.dll")) {
        Copy-Item -LiteralPath "$round/original-harness.dll" -Destination $dll -Force
        if ((Get-FileHash $dll).Hash -ne '00F26AAB8002AB586F119807B590FA98E9102A20D829F8382FB002D5F8025ABF') { throw 'Verification harness restoration failed' }
        if (Test-Path "$harness/wait-for-importer.flag") { Remove-Item -LiteralPath "$harness/wait-for-importer.flag" }
    }
    try {
        # Match the runner's protected-file behavior before comparing the other mod settings.
        foreach ($name in 'UserState.coc','continue_game.json') {
            $saved="$round/baseline/files/$name"
            if (Test-Path -LiteralPath $saved) { [IO.File]::Copy($saved,"$data/$name",$true) }
            elseif (Test-Path -LiteralPath "$data/$name") { Move-Item -LiteralPath "$data/$name" -Destination "$round/test-$name" }
        }
        if ($CompareContents) { Save-TestSnapshot $data "$round/exit" }
    } finally {
        Restore-TestSnapshot $data "$round/baseline" "$round/new-settings"
    }
    if (Test-Path $out) { Move-Item -LiteralPath $out -Destination "$round/test-out" }
    if ($hadOut) { Move-Item -LiteralPath "$round/prior-out" -Destination $out }
    if (Test-Path "$harness/commands.txt") { Move-Item -LiteralPath "$harness/commands.txt" -Destination "$round/unconsumed-commands.txt" }
    foreach ($file in 'SceneFlow','Modding','ExtraAssetsImporter','SimpleModCheckerPlus','CS2TestHarness','FileSystem') {
        $p = Get-Item "$data/Logs/$file.log" -ErrorAction SilentlyContinue
        if ($p -and $p.LastWriteTime -ge $started) { Copy-Item -LiteralPath $p.FullName -Destination $round }
    }
    $after = @($save,"$save.cid") | Get-FileHash | Select-Object -ExpandProperty Hash
    if (Compare-Object $fingerprints $after -SyncWindow 0) { throw 'Save fingerprint mismatch' }
    if ((Definition) -cne $before) { throw 'Playset definition mismatch' }
    "Full playset file matched before and after: $((Get-FileHash $playset).Hash -eq $playsetBefore)" | Set-Content "$round/playset-integrity.txt"
    "Verified save, sidecar, playset definition and $(@(Get-TestFiles $data).Count) settings and backup files." | Tee-Object "$round/integrity.txt"
}
if ($status -ne 0) { throw "Game validation failed. See $round/runner.log" }
$session=Get-ChildItem "$data/ModsData/CityStartupOptimizer/Logs" -Directory | Where-Object CreationTime -ge $started | Sort-Object Name -Descending | Select-Object -First 1
if (!$session) { throw 'Optimizer did not create a session' }
$session.FullName | Set-Content "$round/session-path.txt"
foreach ($event in 'Finished applying playset','Dependency resolution finished','One-frame waits=[1-9]') {
    if (!(Select-String -LiteralPath "$session/session.log" -Pattern $event -Quiet)) { throw "Missing optimizer event $event" }
}
if (!(Select-String -LiteralPath "$round/CS2TestHarness.log" -Pattern 'city loaded, autosave off' -Quiet)) { throw 'Playable marker missing' }
Write-Host "Game reached Pittman Center. Session $session"
