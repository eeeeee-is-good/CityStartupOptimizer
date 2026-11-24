param(
    # Folders to populate, as the game does for a mod: the priority pass, then the normal pass. Defaults to a scratch
    # folder with one small package copied from the game. The folders are only read.
    [string[]]$Root = @(),
    # A text file with one folder per line, for more folders than fit on a command line.
    [string]$RootFile,
    [string]$Mode,
    [string]$Out,
    [string]$Cache,
    [string]$Libs
)
# Run with PowerShell 7 after Build.ps1. Populates the same folders with the stock asset database, then with the patched
# one recording into a scratch package cache, then replaying from that cache, each in a fresh process, and requires every
# registered entry to match. Then checks that a changed package and a corrupt cache file fall back to the game's scan.
$ErrorActionPreference = 'Stop'
$managed = $env:CSII_MANAGEDPATH
$pwsh = (Get-Process -Id $PID).Path
if ($RootFile) { $Root = @($Root) + @(Get-Content -LiteralPath $RootFile | Where-Object { $_ }) }

if ($Mode) {
    # The game's logging library asks Unity for its data folder; outside the game the test copy uses a scratch folder.
    $folders = if ($Mode -eq 'stock') { @($Libs, $managed) } else { @($Libs, "$PSScriptRoot/build", $managed) }
    [AppDomain]::CurrentDomain.add_AssemblyResolve({
        param($s, $e)
        $name = [Reflection.AssemblyName]::new($e.Name).Name
        foreach ($folder in $folders) { if (Test-Path "$folder/$name.dll") { return [Reflection.Assembly]::LoadFrom("$folder/$name.dll") } }
        $null
    }.GetNewClosure())
    $null = [Reflection.Assembly]::LoadFrom("$Libs/Colossal.Logging.dll")
    if ($Mode -eq 'stock') { $database = [Reflection.Assembly]::LoadFrom("$managed/Colossal.IO.AssetDatabase.dll") }
    else {
        $database = [Reflection.Assembly]::LoadFrom("$PSScriptRoot/build/Colossal.IO.AssetDatabase.dll")
        $runtime = [Reflection.Assembly]::LoadFrom("$PSScriptRoot/build/CityStartupRuntime.dll")
        # The cache file loads on a background thread, where a PowerShell resolver cannot run: load references here.
        $pending = [Collections.Generic.Queue[Reflection.Assembly]]::new()
        $pending.Enqueue($database); $pending.Enqueue($runtime)
        $seen = [Collections.Generic.HashSet[string]]::new()
        while ($pending.Count) {
            foreach ($reference in $pending.Dequeue().GetReferencedAssemblies()) {
                if ($seen.Add($reference.Name)) { try { $pending.Enqueue([Reflection.Assembly]::Load($reference)) } catch { } }
            }
        }
        $cacheType = $runtime.GetType('CityStartupOptimizer.PackageCache', $true)
        $cacheType.GetMethod('UseFile').Invoke($null, @($Cache))
    }
    $any = [Reflection.BindingFlags]'Public,NonPublic,Instance,Static'
    $source = $database.GetType('Colossal.IO.AssetDatabase.FileSystemDataSource', $true)
    $factory = $database.GetType('Colossal.IO.AssetDatabase.DefaultAssetFactory', $true).GetProperty('instance').GetValue($null)
    $populate = $source.GetMethod('PopulateFromDirectory', $any)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $rows = foreach ($r in $Root) {
        $ds = [Activator]::CreateInstance($source, @("test", $r, $factory, [long]0))
        foreach ($priority in $true, $false) { $populate.Invoke($ds, @($r, $priority, [Threading.CancellationToken]::None, $null, -1)).GetAwaiter().GetResult() }
        $entries = $source.GetMethod('GetEntries', $any).Invoke($ds, $null)
        $walk = $entries.GetEnumerator()
        while ($walk.MoveNext()) {
            $pair = $walk.Current
            $e = $pair.Value
            $fields = foreach ($p in $e.GetType().GetProperties([Reflection.BindingFlags]'Public,Instance') | Sort-Object Name) {
                if ($p.GetIndexParameters().Count -eq 0) { "$($p.Name)=$($p.GetValue($e))" }
            }
            "$r`t$($pair.Key)`t$($fields -join "`t")"
        }
    }
    $elapsed = $watch.Elapsed.TotalSeconds
    [IO.File]::WriteAllLines($Out, [string[]]@($rows | Sort-Object -CaseSensitive))
    if ($Mode -ne 'stock') {
        $summary = $cacheType.GetMethod('Summary', $any).Invoke($null, $null)
        $cacheType.GetMethod('Save').Invoke($null, $null)
        "$summary"
    }
    "$($rows.Count) entries in {0:F1} s" -f $elapsed
    return
}

$scratch = [IO.Directory]::CreateDirectory("$PSScriptRoot/cache-test-$([guid]::NewGuid().ToString('N'))").FullName
try {
    if (!$Root) {
        $sample = Get-ChildItem "$(Split-Path $managed)/Content/Game" -Filter *.cok | Sort-Object Length | Select-Object -First 1
        $folder = [IO.Directory]::CreateDirectory("$scratch/package").FullName
        Copy-Item $sample.FullName, "$($sample.FullName).cid" $folder
        $Root = @($folder)
    }
    $before = foreach ($r in $Root) { Get-ChildItem $r -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } }
    $cache = "$scratch/packages.bin"
    $libs = [IO.Directory]::CreateDirectory("$scratch/testlibs").FullName
    $null = [Reflection.Assembly]::LoadFrom("$managed/Colossal.Mono.Cecil.dll")
    $logging = [Colossal.Mono.Cecil.AssemblyDefinition]::ReadAssembly("$managed/Colossal.Logging.dll")
    $setup = $logging.MainModule.GetType('Colossal.Logging.LogManager').Methods | Where-Object Name -eq '.cctor'
    $unityPath = @($setup.Body.Instructions | Where-Object { $_.Operand.FullName -eq 'System.String UnityEngine.Application::get_persistentDataPath()' })
    if ($unityPath.Count -ne 1) { throw 'Unexpected logging setup' }
    $unityPath[0].OpCode = [Colossal.Mono.Cecil.Cil.OpCodes]::Ldstr
    $unityPath[0].Operand = [IO.Directory]::CreateDirectory("$scratch/userdata").FullName
    $logging.Write("$libs/Colossal.Logging.dll")
    $logging.Dispose()
    [IO.File]::WriteAllLines("$scratch/roots.txt", [string[]]$Root)
    function Pass($mode) {
        $out = "$scratch/$mode.txt"
        $report = & $pwsh -NoProfile -File $PSCommandPath -Mode $mode -RootFile "$scratch/roots.txt" -Out $out -Cache $cache -Libs $libs
        if ($LASTEXITCODE) { throw "$mode pass failed: $report" }
        Write-Host ("{0,-8} {1}" -f $mode, ($report -join '; '))
        [pscustomobject]@{ Report = ($report -join '; '); Lines = [IO.File]::ReadAllLines($out) }
    }
    function Same($a, $b, $what) {
        if ($a.Lines.Count -ne $b.Lines.Count) { throw "$what`: $($a.Lines.Count) entries vs $($b.Lines.Count)" }
        for ($i = 0; $i -lt $a.Lines.Count; $i++) { if ($a.Lines[$i] -cne $b.Lines[$i]) { throw "$what differ:`n$($a.Lines[$i])`n$($b.Lines[$i])" } }
    }
    $stock = Pass stock
    if (!$stock.Lines.Count) { throw 'The stock pass registered nothing' }
    $record = Pass record
    if ($record.Report -notmatch 'replayed 0 packages' -or $record.Report -match 'recorded 0,') { throw 'First patched pass did not record' }
    Same $stock $record 'Stock and recording passes'
    $replay = Pass replay
    if ($replay.Report -notmatch 'replayed [1-9]' -or $replay.Report -notmatch 'recorded 0,') { throw 'Second patched pass did not replay every package' }
    Same $stock $replay 'Stock and replay passes'
    Write-Host 'Verified that recorded and replayed packages register exactly the entries of the stock scan.'

    if ($Root.Count -eq 1 -and $Root[0] -like "$scratch*") {
        $package = Get-ChildItem $Root[0] -Filter *.cok | Select-Object -First 1
        $package.LastWriteTimeUtc = $package.LastWriteTimeUtc.AddSeconds(1)
        $changed = Pass changed
        if ($changed.Report -notmatch 'replayed 0 packages' -or $changed.Report -notmatch 'rejected 1 ') { throw 'A changed package was replayed' }
        Same $stock $changed 'Stock and changed-package passes'
        [IO.File]::WriteAllBytes($cache, [byte[]](1..200))
        $corrupt = Pass corrupt
        if ($corrupt.Report -notmatch 'replayed 0 packages') { throw 'A corrupt cache was used' }
        Same $stock $corrupt 'Stock and corrupt-cache passes'
        Write-Host 'Verified that a changed package and a corrupt cache file fall back to the game scan.'
    }
    $after = foreach ($r in $Root) { Get-ChildItem $r -Recurse -File | Where-Object FullName -notlike "$scratch*" | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } }
    $beforeOutside = @($before | Where-Object { $_ -notlike "$scratch*" })
    if (Compare-Object $beforeOutside @($after) -SyncWindow 0) { throw 'A populated folder changed during the test' }
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
