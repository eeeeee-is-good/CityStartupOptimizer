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
function Probe($method, $target, $name) {
    $il = $method.Body.GetILProcessor()
    Before $method $target @($il.Create($op::Call,$refs[$name]))
}

# Every patch site is found by the code around it, never by IL offset, and checked before
# anything is changed. If a game update moves or rewrites any of them, the build stops here.
function Need($ok, $what) {
    if (!$ok) { throw "Patch site not found or changed: $what. The game code no longer matches what this build expects." }
}
function One($what, $items) {
    $items = @($items)
    Need ($items.Count -eq 1) "$what (found $($items.Count) candidates)"
    $items[0]
}
function Find($method, [scriptblock]$test) { @($method.Body.Instructions | Where-Object $test) }
function Calls($method, $fullName) { Find $method { $_.Operand -is [Colossal.Mono.Cecil.MethodReference] -and $_.Operand.FullName -eq $fullName } }
function Back($ins, [int]$count) { for ($i = 0; $i -lt $count -and $ins; $i++) { $ins = $ins.Previous }; $ins }
function Span($from, $to) { for ($i = $from; $i -and $i -ne $to; $i = $i.Next) { $i } }
# The local variable an ldloc/stloc instruction uses, or null.
function LocalOf($method, $ins) {
    if (!$ins) { return $null }
    if ($ins.Operand -is [Colossal.Mono.Cecil.Cil.VariableDefinition]) { return $ins.Operand }
    if ($ins.OpCode.Name -match '^(ld|st)loc\.([0-3])$') { return $method.Body.Variables[[int]$Matches[2]] }
    $null
}
function Load($il, $variable) {
    if ($variable.Index -lt 4) { $il.Create($op::"Ldloc_$($variable.Index)") } else { $il.Create($op::Ldloc, $variable) }
}
# The method's only exit, which must be its last instruction.
function OnlyExit($method) {
    $ret = One "single exit of $($method.FullName)" (Find $method { $_.OpCode.Name -eq 'ret' })
    Need ($ret -eq $method.Body.Instructions[$method.Body.Instructions.Count - 1]) "exit of $($method.FullName) is not its last instruction"
    $ret
}
# The first instruction, which must not be a branch target.
function Entry($method) {
    $first = $method.Body.Instructions[0]
    Need (!(Find $method { $_.Operand -eq $first })) "entry of $($method.FullName) is a branch target"
    $first
}
# In an async state machine, the normal-completion state reset before the single SetResult.
function Completion($method) {
    $result = One "completion of $($method.FullName)" (Calls $method 'System.Void System.Runtime.CompilerServices.AsyncTaskMethodBuilder::SetResult()')
    $state = $result
    while ($state -and !($state.OpCode.Name -eq 'ldc.i4.s' -and [int]$state.Operand -eq -2 -and $state.Next.OpCode.Name -eq 'stfld' -and $state.Next.Operand.Name -eq '<>1__state')) { $state = $state.Previous }
    Need ($state -and $state.Previous.OpCode.Name -eq 'ldarg.0') "completion state of $($method.FullName)"
    $state.Previous
}
$waitFrames = 'System.Threading.Tasks.Task Colossal.Core.MainThreadDispatcher::WaitXFrames(System.Int32)'

$m = $db.MainModule
$refs = Refs $m
$fs = $m.GetType('Colossal.IO.AssetDatabase.FileSystemDataSource')
$exe = $m.GetType('Colossal.IO.AssetDatabase.ExecutableAsset')
$playsetType = $m.GetType('Colossal.IO.AssetDatabase.ParadoxModsDataSource')
$play = One 'playset state machine' (($playsetType.NestedTypes | Where-Object Name -like '<OnActivePlaysetChanged>*').Methods | Where-Object Name -eq MoveNext)
# Playset boundaries: the opening debug log entry, and the point right after the wait dialog closes.
$logStart = One 'playset start log entry' (Find $play { $_.OpCode.Name -eq 'ldstr' -and $_.Operand -ceq 'ParadoxModsDataSource.OnActivePlaysetChanged' })
$playStart = $logStart.Previous
Need ($playStart.OpCode.Name -eq 'ldsfld' -and $playStart.Operand.Name -eq 'log') 'playset start log target'
$playEnd = (One 'playset wait-dialog close' (Find $play { $_.Operand -is [Colossal.Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'HidePleaseWait' })).Next
# Pack start: the mod path argument of the first, recursive PopulateFromDirectory(path, true, None, null, start).
$populate = One 'recursive mod folder population' (Find $play {
    $_.Operand -is [Colossal.Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'PopulateFromDirectory' -and $_.Operand.Parameters.Count -eq 5 -and (Back $_ 5).OpCode.Name -eq 'ldc.i4.1' })
$packFlag = Back $populate 5
Need ($packFlag.Previous.OpCode.Name -eq 'ldfld' -and $packFlag.Previous.Operand.FullName -eq 'System.String Colossal.PSI.Common.Mod::path' -and
    $packFlag.Next.Operand.Name -eq 'get_None' -and $packFlag.Next.Next.OpCode.Name -eq 'ldnull' -and $populate.Operand.Parameters[0].ParameterType.FullName -eq 'System.String') 'mod folder population arguments'
# Ownership mapping: prefix = path + "/"; foreach (entry in source.GetEntries()) if (entry.path.StartsWith(prefix)) { ...; keys.Add(id); }
$entries = One 'pack entry listing' (Calls $play 'System.Collections.Generic.IReadOnlyDictionary`2<Colossal.Hash128,Colossal.IO.AssetDatabase.FileSystemDataSource/EntryInfo> Colossal.IO.AssetDatabase.FileSystemDataSource::GetEntries()')
$mapStart = $entries.Previous
$source = LocalOf $play $mapStart
Need ($mapStart.OpCode.Name -like 'ldloc*' -and $source.VariableType.FullName -eq $playsetType.FullName) 'data source passed to the pack entry listing'
$prefixStore = $mapStart.Previous
$prefix = LocalOf $play $prefixStore
Need ($prefixStore.OpCode.Name -like 'stloc*' -and $prefix.VariableType.FullName -eq 'System.String' -and
    $prefixStore.Previous.Operand.FullName -eq 'System.String System.String::Concat(System.String,System.String)' -and
    $prefixStore.Previous.Previous.OpCode.Name -eq 'ldstr' -and $prefixStore.Previous.Previous.Operand -ceq '/') 'pack prefix (path + "/")'
$enumerate = $entries.Next
Need ($enumerate.Operand.Name -eq 'GetEnumerator' -and $enumerate.Next.OpCode.Name -like 'stloc*') 'pack entry enumeration'
$loop = One 'pack entry loop' ($play.Body.ExceptionHandlers | Where-Object { $_.TryStart -eq $enumerate.Next.Next -and $_.HandlerType -eq 'Finally' })
$inLoop = @(Span $loop.TryStart $loop.HandlerStart)
$test = One 'pack path test' ($inLoop | Where-Object { $_.Operand -is [Colossal.Mono.Cecil.MethodReference] -and $_.Operand.FullName -eq 'System.Boolean System.String::StartsWith(System.String)' })
Need ((LocalOf $play $test.Previous) -eq $prefix -and $test.Previous.OpCode.Name -like 'ldloc*' -and $test.Previous.Previous.Operand.Name -eq 'get_path') 'pack path test arguments'
$add = One 'pack ID set insert' ($inLoop | Where-Object { $_.Operand -is [Colossal.Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'Add' -and $_.Operand.DeclaringType.FullName -eq 'System.Collections.Generic.HashSet`1<Colossal.Hash128>' })
$keys = LocalOf $play (Back $add 2)
Need ((Back $add 2).OpCode.Name -like 'ldloc*' -and $keys.VariableType.FullName -eq 'System.Collections.Generic.HashSet`1<Colossal.Hash128>') 'pack ID set'
$mapEnd = $loop.HandlerEnd
Need ($mapEnd) 'end of pack entry loop'

Widen $play
$il = $play.Body.GetILProcessor()
$test.OpCode = $op::Call
$test.Operand = $refs.MatchesPack
Probe $play $playStart PlaysetStart
Before $play $packFlag @($il.Create($op::Dup),$il.Create($op::Call,$refs.Pack))
Before $play $mapStart @((Load $il $prefix),$il.Create($op::Call,$refs.StartMap))
Before $play $mapEnd @((Load $il $keys),$il.Create($op::Call,$refs.EndMap))
Probe $play $playEnd PlaysetEnd

# Keep ZipFile's original constructor, ownership, exception handling, and entry reads.
$package = One 'package population' ($fs.Methods | Where-Object Name -eq PopulateFromPackage)
$zipCtor = One 'archive open' (Find $package { $_.OpCode.Name -eq 'newobj' -and $_.Operand.FullName -eq 'System.Void ICSharpCode.SharpZipLib.Zip.ZipFile::.ctor(System.IO.Stream)' })
$zipStore = $zipCtor.Next
$directoryDone = $zipStore.Next
Need ($zipCtor.Previous.Operand.Name -eq 'GetReadStream' -and $zipStore.OpCode.Name -like 'stloc*' -and $directoryDone.OpCode.Name -like 'ldloc*' -and
    (LocalOf $package $directoryDone) -eq (LocalOf $package $zipStore) -and ($package.Body.ExceptionHandlers | Where-Object { $_.TryStart -eq $directoryDone })) 'archive directory site'
Widen $package
$il = $package.Body.GetILProcessor()
$streamVar = [Colossal.Mono.Cecil.Cil.VariableDefinition]::new($zipCtor.Operand.Parameters[0].ParameterType)
$package.Body.Variables.Add($streamVar)
Before $package $zipCtor @($il.Create($op::Ldarg_0),$il.Create($op::Isinst,$playsetType),$il.Create($op::Ldnull),$il.Create($op::Cgt_Un),$il.Create($op::Call,$refs.BeginArchiveDirectory),$il.Create($op::Dup),$il.Create($op::Stloc,$streamVar))
Before $package $directoryDone @($il.Create($op::Ldloc,$streamVar),$il.Create($op::Call,$refs.EndArchiveDirectory))
$discover = One 'mod assembly discovery' ($exe.Methods | Where-Object Name -eq GetModAssets)
$discoverStart = Entry $discover
$discoverEnd = OnlyExit $discover
Widen $discover
Probe $discover $discoverStart RegisterStart
Probe $discover $discoverEnd RegisterEnd
$resolve = One 'mod dependency resolution' ($exe.Methods | Where-Object Name -eq ResolveModAssets)
$resolveStart = Entry $resolve
$resolveEnd = OnlyExit $resolve
$lookup = One 'registration lookup' (Find $resolve { $_.Operand -is [Colossal.Mono.Cecil.GenericInstanceMethod] -and $_.Operand.Name -eq 'Exists' -and $_.Operand.GenericArguments.Count -eq 1 -and $_.Operand.GenericArguments[0].Name -eq 'ExecutableAsset' })
Need ($lookup.OpCode.Name -eq 'callvirt' -and $lookup.Operand.Parameters.Count -eq 2) 'registration lookup call'
Widen $resolve
Probe $resolve $resolveStart BeginResolve
Probe $resolve $resolveEnd EndResolve

# Limit the fast path to this single registration call, including exceptional exits.
$original = $lookup.Operand
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

# The stock scan walks every entry. An entry can only match when its relativePath equals one of the two
# candidate paths (the file-name test runs only after the first path matched), so an index of relative
# paths may skip the scan when neither path is present. Check exactly that structure.
$exists = One 'asset lookup' ($fs.Methods | Where-Object { $_.Name -eq 'Exists' -and $_.Parameters.Count -eq 3 })
$getEntries = One 'entry accessor' ($fs.Methods | Where-Object { $_.Name -eq 'GetEntries' -and $_.Parameters.Count -eq 0 })
$scan = One 'asset lookup scan' (Find $exists { $_.Operand -is [Colossal.Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'GetEnumerator' })
$scanStart = Back $scan 2
$accessor = @($getEntries.Body.Instructions)
Need ($scanStart.OpCode.Name -eq 'ldarg.0' -and $scan.Previous.OpCode.Name -eq 'ldfld' -and $accessor.Count -eq 3 -and $accessor[0].OpCode.Name -eq 'ldarg.0' -and
    $accessor[1].OpCode.Name -eq 'ldfld' -and $accessor[1].Operand.FullName -eq $scan.Previous.Operand.FullName -and $accessor[2].OpCode.Name -eq 'ret') 'asset lookup scans the same dictionary GetEntries returns'
$compares = @(Calls $exists 'System.Boolean System.String::Equals(System.String,System.StringComparison)')
Need (($compares | ForEach-Object { "$((Back $_ 3).Operand.Name)/$($_.Previous.OpCode.Name)" }) -join ',' -ceq
    'get_relativePath/ldc.i4.5,get_fileNameWithExtension/ldc.i4.5,get_relativePath/ldc.i4.5') 'asset lookup match rules'
$packagePath = LocalOf $exists (Back $compares[0] 2)
$filePath = LocalOf $exists (Back $compares[2] 2)
Need ($packagePath -and $filePath -and $packagePath -ne $filePath -and $packagePath.VariableType.FullName -eq 'System.String' -and $filePath.VariableType.FullName -eq 'System.String' -and
    $compares[0].Next.OpCode.Name -like 'brfalse*' -and $compares[0].Next.Operand -eq (Back $compares[2] 5)) 'asset lookup candidate paths'
$miss = One 'asset lookup not-found exit' (Find $exists { $_.OpCode.Name -eq 'ldarg.3' -and $_.Next.OpCode.Name -eq 'initobj' -and $_.Next.Operand.FullName -eq 'Colossal.Hash128' -and
    $_.Next.Next.OpCode.Name -eq 'ldc.i4.0' -and $_.Next.Next.Next.OpCode.Name -eq 'ret' })
Widen $exists
$il = $exists.Body.GetILProcessor()
$stockScan = $il.Create($op::Nop)
Before $exists $scanStart @($il.Create($op::Call,$refs.RegisteringDependency),$il.Create($op::Brfalse,$stockScan),$il.Create($op::Ldarg_0),$il.Create($op::Call,$getEntries),(Load $il $packagePath),(Load $il $filePath),$il.Create($op::Call,$refs.Absent),$il.Create($op::Brtrue,$miss),$stockScan)
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
Need ($mutations -eq 6) "six entry mutation sites (found $mutations)"
$own=@{}
foreach($method in $runtime.MainModule.GetType('CityStartupOptimizer.Ownership').Methods){
    if($method.IsPublic){$own[$method.Name]=$m.ImportReference($method)}
}
$il=$play.Body.GetILProcessor()
Before $play $enumerate @((Load $il $source),(Load $il $prefix),$il.Create($op::Call,$own.Candidates))
$add=One 'entry insert' ($fs.Methods|Where-Object {$_.Name -eq 'AddEntry' -and $_.Parameters.Count -eq 13})
$store=One 'entry insert store' ($add.Body.Instructions|Where-Object {$_.Operand.Name -eq 'AddOrUpdate'})
$guidArg=One 'entry insert ID' ($add.Parameters|Where-Object Name -eq guid)
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
$location = One 'GetModAssets location comparison' $sites
$location.Operand = $refs.SameAssemblyFile
$db.Write("$stage/Colossal.IO.AssetDatabase.dll")

$refs = Refs $game.MainModule
# Keep the native logo sequence and its input/cancellation behavior. Join its task to
# the existing loading-screen task checked before boot completion. The early await
# yields once to render the first logo, then Unity resumes its usual startup sequence.
$manager = $game.MainModule.GetType('Game.SceneFlow.GameManager')
$init = One 'startup state machine' (($manager.NestedTypes | Where-Object Name -like '<Initialize>d__*').Methods | Where-Object Name -eq MoveNext)
$screenStart = One 'studio sequence start' (Calls $init 'System.Threading.Tasks.Task Game.SceneFlow.GameManager::SetScreenActive<Game.SceneFlow.SplashScreenSequence>()')
$screenOwner = $screenStart.Previous
$screenAwait = $screenStart.Next
$loadingStore = $screenOwner.Previous
$loadingTask = $loadingStore.Operand
$loadingReads = @(Find $init { $_.OpCode.Name -eq 'ldfld' -and $_.Operand.FullName -eq $loadingTask.FullName })
$frameWait = (Calls $init $waitFrames | Select-Object -First 1).Operand
Need ($screenOwner.OpCode.Name -like 'ldloc*' -and (LocalOf $init $screenOwner).VariableType.FullName -eq $manager.FullName -and $screenAwait.Operand.Name -eq 'GetAwaiter' -and
    $loadingStore.OpCode.Name -eq 'stfld' -and $loadingTask.Name -like '<loading>5__*' -and
    $loadingStore.Previous.Operand.FullName -eq 'System.Threading.Tasks.Task Game.SceneFlow.GameManager::SetScreenActive<Game.SceneFlow.LoadingScreen>()' -and
    $loadingReads.Count -eq 1 -and $loadingReads[0].Next.OpCode.Name -eq 'stelem.ref' -and $frameWait) 'startup screen sequence or boot-completion join'
Widen $init
$il = $init.Body.GetILProcessor()
Before $init $screenOwner @($il.Create($op::Ldarg_0),$il.Create($op::Ldarg_0),$il.Create($op::Ldfld,$loadingTask))
Before $init $screenAwait @($il.Create($op::Call,$refs.JoinStartupScreens),$il.Create($op::Stfld,$loadingTask),
    $il.Create($op::Ldc_I4_1),$il.Create($op::Call,$frameWait))
$sequence = One 'studio sequence state machine' (($game.MainModule.GetType('Game.SceneFlow.SplashScreenSequence').NestedTypes | Where-Object Name -like '<Execute>d__*').Methods | Where-Object Name -eq MoveNext)
$shows = @(Find $sequence { $_.OpCode.Name -eq 'callvirt' -and $_.Operand.DeclaringType.FullName -eq 'Game.SceneFlow.OverlayBindings' -and $_.Operand.Name -in 'ActivateScreen','SwapScreen' })
Need ((($shows | ForEach-Object { $_.Operand.Name }) -join ',') -ceq 'ActivateScreen,SwapScreen' -and
    !($shows | Where-Object { $_.Operand.Parameters[$_.Operand.Parameters.Count - 1].ParameterType.FullName -ne 'Game.SceneFlow.OverlayScreen' })) 'studio screen transitions'
$endScreen = One 'studio sequence completion' (Calls $sequence 'System.Void System.Runtime.CompilerServices.AsyncTaskMethodBuilder::SetResult()')
Widen $sequence
$il = $sequence.Body.GetILProcessor()
foreach ($show in $shows) {
    Before $sequence $show @($il.Create($op::Dup),$il.Create($op::Box,$game.MainModule.GetType('Game.SceneFlow.OverlayScreen')),$il.Create($op::Call,$refs.SplashShown))
}
Before $sequence $endScreen @($il.Create($op::Call,$refs.SplashComplete))
$prefab = One 'prefab state machine' (($manager.NestedTypes | Where-Object Name -like '<LoadPrefabs>*').Methods | Where-Object Name -eq MoveNext)
$wait = (One 'prefab batch wait' (Calls $prefab $waitFrames)).Previous
Need ($wait.OpCode.Name -eq 'ldc.i4.8') 'prefab batch wait frame count'
# First run only: the closure allocation right after the resume dispatch.
$closureNew = One 'prefab closure allocation' (Find $prefab { $_.OpCode.Name -eq 'newobj' -and $_.Operand.DeclaringType.Name -like '<>c__DisplayClass*' -and
    $_.Previous.OpCode.Name -eq 'ldarg.0' -and $_.Next.OpCode.Name -eq 'stfld' -and $_.Next.Operand.Name -eq '<>8__1' })
$prefabStart = $closureNew.Previous
$prefabEnd = Completion $prefab
Need (!(Find $prefab { $_.Operand -eq $prefabStart }) -and ($prefab.Body.ExceptionHandlers | Where-Object { $_.HandlerEnd -eq $prefabEnd -and $_.HandlerType -eq 'Catch' })) 'prefab loading boundaries'
Widen $prefab
$wait.OpCode=$op::Call; $wait.Operand=$refs.BatchFrames
Probe $prefab $prefabStart PrefabsStart
Probe $prefab $prefabEnd PrefabsEnd
$game.Write("$stage/Game.dll")
$db.Dispose(); $game.Dispose(); $runtime.Dispose()
$values = [ordered]@{
    StockGame=$stock['Game.dll'];StockCore=$stock['Colossal.Core.dll'];StockDatabase=$stock['Colossal.IO.AssetDatabase.dll']
    StockZip=$stock['ICSharpCode.SharpZipLib.dll']
    Runtime=(Get-FileHash "$stage/CityStartupRuntime.dll").Hash; Game=(Get-FileHash "$stage/Game.dll").Hash
    Database=(Get-FileHash "$stage/Colossal.IO.AssetDatabase.dll").Hash
}
$constants = $values.Keys | ForEach-Object { 'internal const string ' + $_ + '="' + $values[$_] + '";' }
[IO.File]::WriteAllText("$stage/Build.cs", "namespace CityStartupOptimizer { internal static class Build { $constants } }")
Compile CityStartupBootstrap @("$PSScriptRoot/Bootstrap.cs","$stage/Build.cs")
Write-Host "Built optimizer for the verified Steam libraries in $stage"

