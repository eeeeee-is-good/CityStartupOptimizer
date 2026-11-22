param([ValidateSet('Enable','Disable')][string]$Mode='Enable')
$ErrorActionPreference='Stop'
if (Get-Process Cities2 -ErrorAction SilentlyContinue) { throw 'Close Cities: Skylines II before changing its loader.' }
$root = (Get-Item -LiteralPath $env:CSII_INSTALLATIONPATH).FullName
$package = Join-Path $root 'CityStartupOptimizer'
$managed = Join-Path $root 'Cities2_Data\Managed'
# The patched game libraries go next to the originals so that Assembly.Location stays inside the game's Managed folder.
$relocated = Join-Path $managed 'CityStartupOptimizer'
$ini = Join-Path $root 'doorstop_config.ini'
$original = '2255E7640434FDFCCBFEB123A5F4FCCB05032481B39C2BA822E905CCBA58D20E'
if ((Get-FileHash "$root/winhttp.dll").Hash -ne 'CF9DD372CA0DDBE01153502C49F8F756197BB260001792FE766F6C0242DC7FC0') { throw 'Unrecognized game mod loader' }
$backup = "$package/previous-doorstop.ini"
$current = (Get-FileHash $ini).Hash
if (!(Test-Path $package)) {
    if ($Mode -eq 'Disable' -and $current -eq $original) { return }
    if ($current -ne $original) { throw 'The loader configuration has changed.' }
    $null = [IO.Directory]::CreateDirectory($package)
    Copy-Item -LiteralPath $ini -Destination $backup
}
if ((Get-Item $package).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or (Get-FileHash $backup).Hash -ne $original) { throw 'Unexpected installation or backup.' }
$utf8 = New-Object Text.UTF8Encoding($false)
$enabled = [IO.File]::ReadAllText($backup).Replace('targetAssembly=BepInEx\core\BepInEx.Preloader.dll','targetAssembly=CityStartupOptimizer\CityStartupBootstrap.dll')
$sha = [Security.Cryptography.SHA256]::Create()
$activeHash = [BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($enabled))).Replace('-','')
if ($current -notin @($original,$activeHash)) { throw 'Loader configuration edited independently. Review before changing it.' }

# Windows PowerShell 5.1 has no overwriting File.Move, so an existing file is swapped with File.Replace.
function Set-FileFrom([string]$temp, [string]$dest) {
    if (Test-Path -LiteralPath $dest) { [IO.File]::Replace($temp, $dest, [NullString]::Value) } else { [IO.File]::Move($temp, $dest) }
}

if ($Mode -eq 'Enable') {
    if (Test-Path "$root/BepInEx/core/BepInEx.Preloader.dll") { throw 'An active BepInEx installation would be displaced.' }
    if ((Get-FileHash "$managed/Game.dll").Hash -ne 'F076DF4B70AA0F21A80345E03A052CA2273BC6754F41DAB7E63D837837A43745' -or
        (Get-FileHash "$managed/Colossal.IO.AssetDatabase.dll").Hash -ne '0C42B741C44B87A9F398E5E5D8D3498CAD9FFEEECEAF128C0A4F1C3D04277301') { throw 'Unsupported game build' }
    if (!(Test-Path $relocated)) { $null = [IO.Directory]::CreateDirectory($relocated) }
    if ((Get-Item $relocated).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected link at the patched library folder.' }
    $targets = [ordered]@{
        'CityStartupRuntime.dll' = $package
        'CityStartupBootstrap.dll' = $package
        'Game.dll' = $relocated
        'Colossal.IO.AssetDatabase.dll' = $relocated
    }
    foreach ($file in $targets.Keys) {
        $source = "$PSScriptRoot/build/$file"
        $dest = Join-Path $targets[$file] $file
        $temp = "$dest.$([guid]::NewGuid()).tmp"
        Copy-Item -LiteralPath $source -Destination $temp
        if ((Get-FileHash $temp).Hash -ne (Get-FileHash $source).Hash) { throw "Copy failed for $file" }
        Set-FileFrom $temp $dest
    }
    # Earlier versions kept the patched libraries next to the bootstrap; they are no longer loaded from there.
    foreach ($file in 'Game.dll','Colossal.IO.AssetDatabase.dll') {
        $stale = Join-Path $package $file
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force -Confirm:$false }
    }
}
$next = "$ini.$([guid]::NewGuid()).tmp"
if ($Mode -eq 'Disable') { [IO.File]::Copy($backup,$next) } else { [IO.File]::WriteAllText($next,$enabled,$utf8) }
Set-FileFrom $next $ini
$expected = if ($Mode -eq 'Disable') { $original } else { $activeHash }
if ((Get-FileHash $ini).Hash -ne $expected) { throw 'Loader write verification failed.' }
Write-Host "Optimizer mode $Mode verified."
