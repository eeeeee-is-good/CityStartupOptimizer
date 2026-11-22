$ErrorActionPreference = 'Stop'
$stage = [IO.Directory]::CreateDirectory("$PSScriptRoot/build").FullName
$managed = $env:CSII_MANAGEDPATH
$stock = @{
    'Game.dll'='F076DF4B70AA0F21A80345E03A052CA2273BC6754F41DAB7E63D837837A43745'
    'Colossal.IO.AssetDatabase.dll'='0C42B741C44B87A9F398E5E5D8D3498CAD9FFEEECEAF128C0A4F1C3D04277301'
    'Colossal.Core.dll'='22D6DF2294BE9CFC262EA7C23C14B5393BA6D95CD3305181E1A2662BD5405E4C'
    'ICSharpCode.SharpZipLib.dll'='1CD42AAAE6D5EDA2C1988113B825742775AFFDDDFE9FF925B839711C104C38D8'
}
foreach ($name in $stock.Keys) {
    if ((Get-FileHash "$managed/$name").Hash -cne $stock[$name]) { throw "Unsupported game library $name" }
}
$sdk = (dotnet --list-sdks | Select-Object -Last 1) -replace '^([^ ]+) \[(.+)\]$','$2\$1'
function Compile($name, $sources) {
    dotnet "$sdk/Roslyn/bincore/csc.dll" /nologo /nostdlib /optimize+ /deterministic+ /target:library "/out:$stage/$name.dll" "/reference:$managed/mscorlib.dll" "/reference:$managed/System.dll" "/reference:$managed/System.Core.dll" "/reference:$managed/Colossal.Core.dll" "/reference:$managed/Colossal.IO.AssetDatabase.dll" "/reference:$managed/UnityEngine.CoreModule.dll" @sources
    if ($LASTEXITCODE) { throw "Compile failed for $name" }
}
Compile CityStartupRuntime @("$PSScriptRoot/Ownership.cs","$PSScriptRoot/Session.cs","$PSScriptRoot/Loading.cs","$PSScriptRoot/ArchiveDirectoryStream.cs")
$null = [Reflection.Assembly]::LoadFrom("$managed/Colossal.Mono.Cecil.dll")
$resolver = [Colossal.Mono.Cecil.DefaultAssemblyResolver]::new()
$resolver.AddSearchDirectory($managed)
$reader = [Colossal.Mono.Cecil.ReaderParameters]::new()
$reader.AssemblyResolver = $resolver
$runtime = [Colossal.Mono.Cecil.AssemblyDefinition]::ReadAssembly("$stage/CityStartupRuntime.dll")
$db = [Colossal.Mono.Cecil.AssemblyDefinition]::ReadAssembly("$managed/Colossal.IO.AssetDatabase.dll",$reader)
$game = [Colossal.Mono.Cecil.AssemblyDefinition]::ReadAssembly("$managed/Game.dll",$reader)
$op = [Colossal.Mono.Cecil.Cil.OpCodes]
function Refs($module) {
    $map = @{}
    foreach ($method in $runtime.MainModule.GetType('CityStartupOptimizer.Loading').Methods) {
        if ($method.IsPublic) { $map[$method.Name] = $module.ImportReference($method) }
    }
    $map
}
function Widen($method) {
    foreach ($ins in $method.Body.Instructions) {
        if ($ins.OpCode.OperandType -eq 'ShortInlineBrTarget') {
            $ins.OpCode = $op.GetField($ins.OpCode.Name.Replace('.s','').Replace('.','_'),[reflection.bindingflags]'Public,Static,IgnoreCase').GetValue($null)
        }
    }
}
# Retain incoming branch targets and exception boundaries on the first added instruction.
function Before($method, $target, $instructions) {
    $il = $method.Body.GetILProcessor()
    $tail = $il.Create($op::Nop)
    $tail.OpCode = $target.OpCode
    $tail.Operand = $target.Operand
    $target.OpCode = $op::Nop
    $target.Operand = $null
    $il.InsertAfter($target, $tail)
    foreach ($i in $instructions) { $il.InsertBefore($tail, $i) }
}
function At($method, [int]$offset) {
    $hit = @($method.Body.Instructions | Where-Object Offset -eq $offset)
    # Inserted instructions have offset zero until serialization; use zero only before any edits.
    if ($hit.Count -ne 1) { throw "Missing or ambiguous site $($method.FullName) 0x$($offset.ToString('x'))" }
    $hit[0]
}
function Probe($method, [int]$offset, $name) {
    $il = $method.Body.GetILProcessor()
    Before $method (At $method $offset) @($il.Create($op::Call,$refs[$name]))
}

$m = $db.MainModule
$refs = Refs $m
$fs = $m.GetType('Colossal.IO.AssetDatabase.FileSystemDataSource')
$exe = $m.GetType('Colossal.IO.AssetDatabase.ExecutableAsset')
$play = ($m.GetType('Colossal.IO.AssetDatabase.ParadoxModsDataSource').NestedTypes | Where-Object Name -like '<OnActivePlaysetChanged>*').Methods | Where-Object Name -eq MoveNext
Widen $play
$il = $play.Body.GetILProcessor()
$test = At $play 0x04da
if ($test.Operand.FullName -ne 'System.Boolean System.String::StartsWith(System.String)') { throw 'Pack predicate mismatch' }
$test.OpCode = $op::Call
$test.Operand = $refs.MatchesPack
Probe $play 0x48 PlaysetStart
Before $play (At $play 0x3bc) @($il.Create($op::Dup),$il.Create($op::Call,$refs.Pack))
Before $play (At $play 0x4b4) @($il.Create($op::Ldloc,$play.Body.Variables[15]),$il.Create($op::Call,$refs.StartMap))
Before $play (At $play 0x522) @($il.Create($op::Ldloc,$play.Body.Variables[14]),$il.Create($op::Call,$refs.EndMap))
Probe $play 0x773 PlaysetEnd

# Keep ZipFile's original constructor, ownership, exception handling, and entry reads.
$package = $fs.Methods | Where-Object Name -eq PopulateFromPackage
$zipCtor = At $package 0x31
$directoryDone = At $package 0x37
if ($zipCtor.OpCode.Name -ne 'newobj' -or $zipCtor.Operand.FullName -ne 'System.Void ICSharpCode.SharpZipLib.Zip.ZipFile::.ctor(System.IO.Stream)' -or $directoryDone.OpCode.Name -ne 'ldloc.2') { throw 'Archive directory site mismatch' }
Widen $package
$il = $package.Body.GetILProcessor()
$streamVar = [Colossal.Mono.Cecil.Cil.VariableDefinition]::new($zipCtor.Operand.Parameters[0].ParameterType)
$package.Body.Variables.Add($streamVar)
$playsetType = $m.GetType('Colossal.IO.AssetDatabase.ParadoxModsDataSource')
Before $package $zipCtor @($il.Create($op::Ldarg_0),$il.Create($op::Isinst,$playsetType),$il.Create($op::Ldnull),$il.Create($op::Cgt_Un),$il.Create($op::Call,$refs.BeginArchiveDirectory),$il.Create($op::Dup),$il.Create($op::Stloc,$streamVar))
Before $package $directoryDone @($il.Create($op::Ldloc,$streamVar),$il.Create($op::Call,$refs.EndArchiveDirectory))
$discover = $exe.Methods | Where-Object Name -eq GetModAssets
Widen $discover
Probe $discover 0 RegisterStart
Probe $discover 0x125 RegisterEnd
$resolve = $exe.Methods | Where-Object Name -eq ResolveModAssets
Widen $resolve
Probe $resolve 0 BeginResolve
Probe $resolve 0x1fb EndResolve

# Limit the fast path to this single registration call, including exceptional exits.
$lookup = At $resolve 0xff
$original = $lookup.Operand
if ($original.Name -ne 'Exists' -or $original.GenericArguments[0].Name -ne 'ExecutableAsset') { throw 'Registration call mismatch' }
$wrapper = [Colossal.Mono.Cecil.MethodDefinition]::new('StartupOptimizerLookup',[Colossal.Mono.Cecil.MethodAttributes]'Private,Static,HideBySig',$m.TypeSystem.Boolean)
$exe.Methods.Add($wrapper)
foreach ($type in @($original.DeclaringType,$original.Parameters[0].ParameterType,[Colossal.Mono.Cecil.ByReferenceType]::new($exe))) {
    $wrapper.Parameters.Add([Colossal.Mono.Cecil.ParameterDefinition]::new($type))
}
$wrapper.Body.InitLocals = $true
$wrapper.Body.Variables.Add([Colossal.Mono.Cecil.Cil.VariableDefinition]::new($m.TypeSystem.Boolean))
$il = $wrapper.Body.GetILProcessor()
$start = $il.Create($op::Ldarg_0)
$finally = $il.Create($op::Call,$refs.EndLookup)
$done = $il.Create($op::Ldloc_0)
foreach ($i in @($il.Create($op::Call,$refs.BeginLookup),$start,$il.Create($op::Ldarg_1),$il.Create($op::Ldarg_2),$il.Create($op::Callvirt,$original),$il.Create($op::Stloc_0),$il.Create($op::Leave,$done),$finally,$il.Create($op::Endfinally),$done,$il.Create($op::Ret))) { $il.Append($i) }
$handler = [Colossal.Mono.Cecil.Cil.ExceptionHandler]::new([Colossal.Mono.Cecil.Cil.ExceptionHandlerType]::Finally)
$handler.TryStart=$start; $handler.TryEnd=$finally; $handler.HandlerStart=$finally; $handler.HandlerEnd=$done
$wrapper.Body.ExceptionHandlers.Add($handler)
$lookup.OpCode=$op::Call; $lookup.Operand=$wrapper

$exists = $fs.Methods | Where-Object { $_.Name -eq 'Exists' -and $_.Parameters.Count -eq 3 }
Widen $exists
$il = $exists.Body.GetILProcessor()
$miss = At $exists 0x13e
$getEntries = $fs.Methods | Where-Object Name -eq GetEntries
$stockScan = $il.Create($op::Nop)
Before $exists (At $exists 0x83) @($il.Create($op::Call,$refs.RegisteringDependency),$il.Create($op::Brfalse,$stockScan),$il.Create($op::Ldarg_0),$il.Create($op::Call,$getEntries),$il.Create($op::Ldloc_3),$il.Create($op::Ldloc_2),$il.Create($op::Call,$refs.Absent),$il.Create($op::Brtrue,$miss),$stockScan)
$guid = $exists.Parameters[2].ParameterType.ElementType
foreach ($ret in @($exists.Body.Instructions | Where-Object { $_.OpCode.Name -eq 'ret' })) {
    $stockResult = $il.Create($op::Nop)
    Before $exists $ret @($il.Create($op::Call,$refs.RegisteringDependency),$il.Create($op::Brfalse,$stockResult),$il.Create($op::Ldarg_3),$il.Create($op::Ldobj,$guid),$il.Create($op::Box,$guid),$il.Create($op::Call,$refs.Record),$stockResult)
}
# Invalidate for adds, same-count replacements, deletions, clears and in-place path mutations.
$entry = $fs.NestedTypes | Where-Object Name -eq EntryInfo
$mutations = 0
foreach ($method in @($fs.Methods) + @($entry.Methods)) {
    if (!$method.HasBody) { continue }
    $writes = @($method.Body.Instructions | Where-Object {
        ($_.Operand.DeclaringType.Name -eq 'ConcurrentDictionary`2' -and $_.Operand.Name -in 'AddOrUpdate','TryRemove','Clear','TryAdd','TryUpdate','set_Item') -or
        ($method.DeclaringType.Name -eq 'EntryInfo' -and $method.Name -ne '.ctor' -and $_.OpCode.Name -eq 'stfld' -and $_.Operand.Name -in 'm_Path','<relativePathStart>k__BackingField')
    })
    if (!$writes.Count) { continue }
    Widen $method
    $il = $method.Body.GetILProcessor()
    foreach ($write in $writes) {
        $finish = $il.Create($op::Call,$refs.EndWrite)
        $il.InsertAfter($write,$finish)
        Before $method $write @($il.Create($op::Call,$refs.BeginWrite))
        $mutations++
    }
}
if ($mutations -ne 6) { throw "Expected six mutation sites, got $mutations" }
$own=@{}
foreach($method in $runtime.MainModule.GetType('CityStartupOptimizer.Ownership').Methods){
    if($method.IsPublic){$own[$method.Name]=$m.ImportReference($method)}
}
$beforeEnum=At $play 0x4ba
if($beforeEnum.Operand.Name -ne 'GetEnumerator'){throw 'Unexpected pack enumeration'}
$il=$play.Body.GetILProcessor()
Before $play $beforeEnum @($il.Create($op::Ldloc_1),$il.Create($op::Ldloc,$play.Body.Variables[15]),$il.Create($op::Call,$own.Candidates))
$add=$fs.Methods|Where-Object {$_.Name -eq 'AddEntry' -and $_.Parameters.Count -eq 13}
$store=$add.Body.Instructions|Where-Object {$_.Operand.Name -eq 'AddOrUpdate'}
$guidArg=$add.Parameters|Where-Object Name -eq guid
$il=$add.Body.GetILProcessor()
$note=$il.Create($op::Call,$own.Changed)
$il.InsertAfter($store,$note)
$il.InsertBefore($note,$il.Create($op::Ldarg_0))
$il.InsertBefore($note,$il.Create($op::Ldarg,$guidArg))
foreach($method in @($fs.Methods)+@($entry.Methods)){
    if(!$method.HasBody){continue}
    foreach($site in @($method.Body.Instructions)){
        $observer=$null
        if($site.Operand.DeclaringType.Name -like 'ConcurrentDictionary*' -and $site.Operand.Name -in 'Clear','TryRemove'){$observer=$own.Reset}
        if($site.OpCode.Name -eq 'stfld' -and $site.Operand.Name -eq 'm_Path' -and $method.DeclaringType.Name -eq 'EntryInfo'){$observer=$own.Moved}
        if($observer){$il=$method.Body.GetILProcessor(); Before $method $site @($il.Create($op::Ldarg_0),$il.Create($op::Call,$observer))}
    }
}
# The patched libraries load from Managed\CityStartupOptimizer\. GetModAssets pairs a loaded assembly with the resolver's
# Managed\<name>.dll by comparing Assembly.Location to that file name; Loading.SameAssemblyFile also accepts the relocated copy.
$sites = @(foreach ($closure in @($exe.NestedTypes | Where-Object Name -like '<>c__DisplayClass*')) {
    foreach ($method in @($closure.Methods | Where-Object { $_.Name -like '<GetModAssets>b__*' -and $_.HasBody })) {
        $body = @($method.Body.Instructions)
        foreach ($ins in $body) {
            if ($ins.OpCode.Name -eq 'call' -and $ins.Operand.FullName -eq 'System.Boolean System.String::op_Equality(System.String,System.String)' -and
                ($body | Where-Object { $_.Operand.Name -eq 'get_Location' }) -and ($body | Where-Object { $_.Operand.Name -eq 'get_FileName' })) { $ins }
        }
    }
})
if ($sites.Count -ne 1) { throw "Expected one GetModAssets location comparison, got $($sites.Count)" }
$sites[0].Operand = $refs.SameAssemblyFile
$db.Write("$stage/Colossal.IO.AssetDatabase.dll")

$refs = Refs $game.MainModule
# Keep the native logo sequence and its input/cancellation behavior. Join its task to
# the existing loading-screen task checked before boot completion. The early await
# yields once to render the first logo, then Unity resumes its usual startup sequence.
$manager = $game.MainModule.GetType('Game.SceneFlow.GameManager')
$init = ($manager.NestedTypes | Where-Object Name -like '<Initialize>d__*').Methods | Where-Object Name -eq MoveNext
$screenOwner = At $init 0x2ec
$screenStart = At $init 0x2ed
$screenAwait = At $init 0x2f2
$loadingTask = (At $init 0x2e7).Operand
$frameWait = (At $init 0x466).Operand
if ($screenOwner.OpCode.Name -ne 'ldloc.1' -or $screenStart.Operand.Name -ne 'SetScreenActive' -or
    $screenStart.Operand.GenericArguments[0].Name -ne 'SplashScreenSequence' -or $screenAwait.Operand.Name -ne 'GetAwaiter' -or
    $loadingTask.Name -notlike '<loading>5__*' -or (At $init 0x7c5).Operand.FullName -ne $loadingTask.FullName -or
    $frameWait.FullName -ne 'System.Threading.Tasks.Task Colossal.Core.MainThreadDispatcher::WaitXFrames(System.Int32)') {
    throw 'Unexpected startup screen sequence or boot-completion join'
}
Widen $init
$il = $init.Body.GetILProcessor()
Before $init $screenOwner @($il.Create($op::Ldarg_0),$il.Create($op::Ldarg_0),$il.Create($op::Ldfld,$loadingTask))
Before $init $screenAwait @($il.Create($op::Call,$refs.JoinStartupScreens),$il.Create($op::Stfld,$loadingTask),
    $il.Create($op::Ldc_I4_1),$il.Create($op::Call,$frameWait))
$sequence = ($game.MainModule.GetType('Game.SceneFlow.SplashScreenSequence').NestedTypes | Where-Object Name -like '<Execute>d__*').Methods | Where-Object Name -eq MoveNext
Widen $sequence
$il = $sequence.Body.GetILProcessor()
foreach ($offset in 0xc9,0xf2) {
    $show = At $sequence $offset
    if ($show.Operand.Name -notin 'ActivateScreen','SwapScreen') { throw 'Unexpected studio screen transition' }
    Before $sequence $show @($il.Create($op::Dup),$il.Create($op::Box,$game.MainModule.GetType('Game.SceneFlow.OverlayScreen')),$il.Create($op::Call,$refs.SplashShown))
}
$endScreen=At $sequence 0x2b4
if($endScreen.Operand.Name -ne 'SetResult'){throw 'Unexpected sequence completion'}
Before $sequence $endScreen @($il.Create($op::Call,$refs.SplashComplete))
$prefab = ($game.MainModule.GetType('Game.SceneFlow.GameManager').NestedTypes | Where-Object Name -like '<LoadPrefabs>*').Methods | Where-Object Name -eq MoveNext
Widen $prefab
$wait = At $prefab 0x194
if ($wait.OpCode.Name -ne 'ldc.i4.8' -or $wait.Next.Operand.FullName -ne 'System.Threading.Tasks.Task Colossal.Core.MainThreadDispatcher::WaitXFrames(System.Int32)') { throw 'Prefab wait site mismatch' }
$wait.OpCode=$op::Call; $wait.Operand=$refs.BatchFrames
Probe $prefab 0x11 PrefabsStart
Probe $prefab 0x2d6 PrefabsEnd
$game.Write("$stage/Game.dll")
$db.Dispose(); $game.Dispose(); $runtime.Dispose()
$values = @{
    StockGame=$stock['Game.dll'];StockCore=$stock['Colossal.Core.dll'];StockDatabase=$stock['Colossal.IO.AssetDatabase.dll']
    StockZip=$stock['ICSharpCode.SharpZipLib.dll']
    Runtime=(Get-FileHash "$stage/CityStartupRuntime.dll").Hash; Game=(Get-FileHash "$stage/Game.dll").Hash
    Database=(Get-FileHash "$stage/Colossal.IO.AssetDatabase.dll").Hash
}
$constants = $values.Keys | ForEach-Object { 'internal const string ' + $_ + '="' + $values[$_] + '";' }
[IO.File]::WriteAllText("$stage/Build.cs", "namespace CityStartupOptimizer { internal static class Build { $constants } }")
Compile CityStartupBootstrap @("$PSScriptRoot/Bootstrap.cs","$stage/Build.cs")
Write-Host "Built optimizer for the verified Steam libraries in $stage"


