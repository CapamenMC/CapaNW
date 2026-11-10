param(
    [string]$Version = '1.0.11'
)

$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot
$dotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) {
    $dotnet = 'dotnet'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$artifactDirectory = Join-Path $projectDirectory "artifacts\capanw-$Version-$stamp"
$plainDirectory = Join-Path $artifactDirectory 'plain'
$obfuscatedDirectory = Join-Path $artifactDirectory 'obfuscated'
$releaseDirectory = Join-Path $artifactDirectory 'release'
$configPath = Join-Path $artifactDirectory 'obfuscar.xml'
$logPath = Join-Path $artifactDirectory 'obfuscar.log'
$assemblyPath = Join-Path $plainDirectory 'CapaNW.dll'

New-Item -ItemType Directory -Path $plainDirectory, $obfuscatedDirectory, $releaseDirectory -Force | Out-Null

Push-Location $projectDirectory
try {
    & $dotnet tool restore
    if ($LASTEXITCODE -ne 0) {
        throw 'Restoring the pinned .NET tools failed.'
    }

    & $dotnet publish 'CapaNW.Launcher.csproj' `
        --configuration Release `
        --runtime win-x64 `
        --self-contained true `
        --output $plainDirectory `
        -p:PublishSingleFile=false `
        -p:DebugType=None `
        -p:DebugSymbols=false `
        -p:Version=$Version
    if ($LASTEXITCODE -ne 0) {
        throw 'Publishing the WPF launcher failed.'
    }

    & (Join-Path $PSScriptRoot 'test-native-guard.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw 'Native guard verification tests failed.'
    }

    foreach ($requiredPath in @(
        $assemblyPath,
        (Join-Path $plainDirectory 'CapaNW.exe'),
        (Join-Path $plainDirectory 'CapaNW.NativeGuard.dll'),
        (Join-Path $plainDirectory 'auth-config.json'),
        (Join-Path $plainDirectory 'mod\capanw-1.0.5.jar')
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required publish file is missing: $requiredPath"
        }
    }

    $escapedInput = [System.Security.SecurityElement]::Escape($plainDirectory)
    $escapedOutput = [System.Security.SecurityElement]::Escape($obfuscatedDirectory)
    $escapedLog = [System.Security.SecurityElement]::Escape($logPath)
    $escapedAssembly = [System.Security.SecurityElement]::Escape($assemblyPath)
    $configuration = @"
<?xml version="1.0" encoding="utf-8"?>
<Obfuscator>
  <Var name="InPath" value="$escapedInput" />
  <Var name="OutPath" value="$escapedOutput" />
  <Var name="LogFile" value="$escapedLog" />
  <Var name="KeepPublicApi" value="false" />
  <Var name="HidePrivateApi" value="true" />
  <Module file="$escapedAssembly">
    <SkipType name="CapaNW.Launcher.App" skipMethods="true" skipFields="true" skipProperties="true" skipEvents="true" skipStringHiding="true" />
    <SkipType name="CapaNW.Launcher.MainWindow" skipMethods="true" skipFields="true" skipProperties="true" skipEvents="true" skipStringHiding="true" />
  </Module>
</Obfuscator>
"@
    Set-Content -LiteralPath $configPath -Value $configuration -Encoding UTF8

    & $dotnet tool run obfuscar.console $configPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Obfuscar failed to transform the launcher assembly.'
    }

    Copy-Item -Path (Join-Path $plainDirectory '*') -Destination $releaseDirectory -Recurse -Force
    $obfuscatedAssembly = Join-Path $obfuscatedDirectory 'CapaNW.dll'
    if (-not (Test-Path -LiteralPath $obfuscatedAssembly -PathType Leaf)) {
        throw 'Obfuscar did not produce CapaNW.dll.'
    }
    Copy-Item -LiteralPath $obfuscatedAssembly -Destination (Join-Path $releaseDirectory 'CapaNW.dll') -Force
    Get-ChildItem -LiteralPath $releaseDirectory -Filter '*.pdb' -File | Remove-Item -Force

    $plainHash = (Get-FileHash -LiteralPath $assemblyPath -Algorithm SHA256).Hash
    $obfuscatedHash = (Get-FileHash -LiteralPath (Join-Path $releaseDirectory 'CapaNW.dll') -Algorithm SHA256).Hash
    if ($plainHash -eq $obfuscatedHash) {
        throw 'Obfuscation output is identical to the unprotected assembly.'
    }

    & $dotnet run `
        --project (Join-Path $projectDirectory 'tests\ObfuscationSmokeTest\ObfuscationSmokeTest.csproj') `
        --configuration Release `
        -- $releaseDirectory
    if ($LASTEXITCODE -ne 0) {
        throw 'Obfuscated WPF/XAML smoke test failed.'
    }

    $installerCompiler = (Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue).Source
    if (-not $installerCompiler) {
        $candidate = Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
        if (Test-Path -LiteralPath $candidate) {
            $installerCompiler = $candidate
        }
    }
    if (-not $installerCompiler) {
        throw 'Inno Setup 6 (ISCC.exe) is required to create the Windows installer.'
    }

    & $installerCompiler `
        "/DAppVersion=$Version" `
        "/DSourceDirectory=$releaseDirectory" `
        "/DOutputDirectory=$artifactDirectory" `
        (Join-Path $PSScriptRoot 'CapaNW.iss')
    if ($LASTEXITCODE -ne 0) {
        throw 'Building the Windows installer failed.'
    }

    $installerPath = Join-Path $artifactDirectory "CapaNW-Setup-$Version.exe"
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "Windows installer was not produced: $installerPath"
    }
    $installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$installerPath.sha256" -Value "$installerHash  CapaNW-Setup-$Version.exe" -Encoding ASCII

    $manifest = [ordered]@{
        version = $Version
        installerUrl = "https://github.com/CapamenMC/CapaNW/releases/download/v$Version/CapaNW-Setup-$Version.exe"
        checksumUrl = "https://github.com/CapamenMC/CapaNW/releases/download/v$Version/CapaNW-Setup-$Version.exe.sha256"
    } | ConvertTo-Json
    $manifestPath = Join-Path (Split-Path -Parent $projectDirectory) 'update-manifest.json'
    [System.IO.File]::WriteAllText(
        $manifestPath,
        $manifest,
        [System.Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $artifactDirectory 'update-manifest.json') -Force

    Write-Output "Obfuscated launcher output: $(Join-Path $releaseDirectory 'CapaNW.exe')"
    Write-Output "Windows installer: $installerPath"
    Write-Output "Update manifest (publish to the main branch after the release assets are uploaded): $manifestPath"
    Write-Output "Release folder: $releaseDirectory"
    Write-Output "Native DLL: $(Join-Path $releaseDirectory 'CapaNW.NativeGuard.dll')"
}
finally {
    Pop-Location
}
