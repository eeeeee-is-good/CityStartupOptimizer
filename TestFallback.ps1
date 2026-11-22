$ErrorActionPreference='Stop'
$fake = [IO.Directory]::CreateDirectory("$PSScriptRoot/guard-test-$([guid]::NewGuid().ToString('N'))").FullName
$package = [IO.Directory]::CreateDirectory("$fake/CityStartupOptimizer")
$managed = [IO.Directory]::CreateDirectory("$fake/Cities2_Data/Managed")
Copy-Item -LiteralPath "$PSScriptRoot/build/CityStartupRuntime.dll" -Destination $package.FullName
[IO.File]::WriteAllText("$managed/Colossal.IO.AssetDatabase.dll",'different game version')
$assembly = [Reflection.Assembly]::LoadFrom("$PSScriptRoot/build/CityStartupBootstrap.dll")
$method = $assembly.GetType('CityStartupOptimizer.Bootstrap').GetMethod('Start',[Reflection.BindingFlags]'NonPublic,Static')
$null = $method.Invoke($null, @($fake, "$fake/user"))
$log = Get-ChildItem "$fake/user" -Recurse -File -Filter session.log
if (!(Select-String -LiteralPath $log.FullName -SimpleMatch 'Stock loading selected. The installed game build differs' -Quiet)) { throw 'Unsupported build did not select stock' }
if ([appdomain]::CurrentDomain.GetAssemblies().GetName().Name -contains 'Colossal.IO.AssetDatabase') { throw 'Game library unexpectedly loaded' }
Add-Type 'public class TestEntry {public string relativePath {get; set;}}'
$entry = [TestEntry]::new()
$entry.relativePath = 'a/b.dll'
$entries = @{ one = $entry }
[CityStartupOptimizer.Loading]::BeginResolve()
[CityStartupOptimizer.Loading]::BeginLookup()
if ([CityStartupOptimizer.Loading]::Absent($entries, 'A/B.DLL', 'absent')) { throw 'Case-insensitive package path missed' }
if (![CityStartupOptimizer.Loading]::Absent($entries, 'c.cok', 'c.dll')) { throw 'Expected indexed miss' }
[CityStartupOptimizer.Loading]::BeginWrite()
if ([CityStartupOptimizer.Loading]::Absent($entries, 'c.cok', 'c.dll')) { throw 'Used index during mutation' }
$entry.relativePath='c.dll'
[CityStartupOptimizer.Loading]::EndWrite()
if ([CityStartupOptimizer.Loading]::Absent($entries, 'c.cok', 'C.DLL')) { throw 'Stale path after same-count mutation' }
[CityStartupOptimizer.Loading]::EndLookup()
[CityStartupOptimizer.Loading]::EndResolve()
if ([CityStartupOptimizer.Loading]::RegisteringDependency()) { throw 'Fast path still active outside registration' }
Write-Host 'Verified unknown-build fallback and registration path invalidation in an isolated directory.'

$path="$fake/sample.zip"
$w=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($index in 1..1200) {
        $compression = if ($index % 2) { [IO.Compression.CompressionLevel]::NoCompression } else { [IO.Compression.CompressionLevel]::Optimal }
        $entry=$w.CreateEntry("assets/テスト-entry-$index.txt",$compression)
        $body=[IO.StreamWriter]::new($entry.Open())
        try { $body.Write("content of asset $index") } finally { $body.Dispose() }
    }
} finally { $w.Dispose() }
$null=[Reflection.Assembly]::LoadFrom("$env:CSII_MANAGEDPATH/ICSharpCode.SharpZipLib.dll")
$file=[IO.File]::OpenRead($path)
$stream=[CityStartupOptimizer.Loading]::BeginArchiveDirectory($file,$true)
try {
    if ([object]::ReferenceEquals($file,$stream)) { throw 'Directory buffering was not selected' }
    $zip=[ICSharpCode.SharpZipLib.Zip.ZipFile]::new($stream)
    try {
        $expected=$stream.Position
        [CityStartupOptimizer.Loading]::EndArchiveDirectory($stream)
        if ($stream.Position -ne $expected) { throw 'Archive position changed at handoff' }
        foreach ($i in 1200..1) {
            $entry=$zip.GetEntry("assets/テスト-entry-$i.txt")
            $r=[IO.StreamReader]::new($zip.GetInputStream($entry))
            try { if ($r.ReadToEnd() -cne "content of asset $i") { throw "Archive payload mismatch for $i" } } finally { $r.Dispose() }
        }
    } finally { $zip.Close() }
    if ($file.CanRead) { throw 'Archive did not close the owned file' }
} finally { $stream.Dispose() }
$file=[IO.File]::OpenRead($path)
try {
    if (![object]::ReferenceEquals($file,[CityStartupOptimizer.Loading]::BeginArchiveDirectory($file,$false))) { throw 'Non-playset source was wrapped' }
    $s=[CityStartupOptimizer.Loading]::BeginArchiveDirectory($file,$true)
    try {
        $null=$s.ReadByte()
        [CityStartupOptimizer.Loading]::EndArchiveDirectory($s)
        if ($s.Position -ne 1 -or $s.ReadByte() -ne 75) { throw 'Unread lookahead was lost at handoff' }
    } finally { $s.Dispose() }
} finally { $file.Dispose() }
# Partial header reads must preserve the logical position across bulk reads, relative
# seeks, and EOF. Compare with a separate stock file handle.
$stockFile=[IO.File]::OpenRead($path)
$probeFile=[IO.File]::OpenRead($path)
$s=[CityStartupOptimizer.Loading]::BeginArchiveDirectory($probeFile,$true)
try {
    [CityStartupOptimizer.Loading]::EndArchiveDirectory($s)
    foreach($i in 1..7){if($s.ReadByte() -ne $stockFile.ReadByte()){throw 'Byte mismatch'}}
    if($s.Position -ne $stockFile.Position){throw 'Incorrect logical position'}
    if($s.Seek(-2,'Current') -ne $stockFile.Seek(-2,'Current')){throw 'Relative seek mismatch'}
    $null=$s.ReadByte(); $null=$stockFile.ReadByte()
    $a=[byte[]]::new(93); $b=[byte[]]::new(93)
    if($s.Read($a,3,89) -ne $stockFile.Read($b,3,89) -or [Convert]::ToBase64String($a) -ne [Convert]::ToBase64String($b)){throw 'Bulk read after lookahead differs'}
    $null=$s.Seek(-3,'End'); $null=$stockFile.Seek(-3,'End')
    foreach($i in 1..4){if($s.ReadByte() -ne $stockFile.ReadByte()){throw 'EOF mismatch'}}
    $s.Position=0
    if($s.ReadByte() -ne 80){throw 'Seek after EOF failed'}
    $s.Flush()
    if($probeFile.Position -ne 1){throw 'Flush left unread lookahead'}
} finally {$s.Dispose();$stockFile.Dispose()}
$screen=[Threading.Tasks.TaskCompletionSource[bool]]::new()
$load=[Threading.Tasks.TaskCompletionSource[bool]]::new()
$joined=[CityStartupOptimizer.Loading]::JoinStartupScreens($load.Task,$screen.Task)
$load.SetResult($true)
if($joined.IsCompleted){throw 'Boot join lost the studio task'}
$screen.SetResult($true)
$joined.GetAwaiter().GetResult()
$failure=[Threading.Tasks.Task]::FromException([InvalidOperationException]::new('splash test'))
$joined=[CityStartupOptimizer.Loading]::JoinStartupScreens([Threading.Tasks.Task]::CompletedTask,$failure)
if(!$joined.IsFaulted){throw 'Splash failure was lost'}
Write-Host 'Verified archive handoff and integrity, screen completion and failure propagation.'

