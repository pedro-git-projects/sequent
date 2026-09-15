<#
.SYNOPSIS
    Build sequent for Windows x86-64 and stage a portable pre-alpha ZIP.

.DESCRIPTION
    Produces a self-contained directory that can be extracted anywhere and run
    without GHC, Cabal, Stack or MSYS2 on the target machine, then archives it
    and writes a SHA-256 checksum.

    The compiler is pure Haskell: no FFI, no c-sources, no extra-libraries, no
    data-files and no Paths_ module. It therefore needs no runtime resources
    beyond the executable itself. This script still inspects the linked import
    table and copies any non-system DLL it actually finds, rather than assuming
    the result.

.PARAMETER PreRelease
    Pre-release qualifier appended to the version in sequent.cabal.
    Pass an empty string for a plain release build.

.PARAMETER SkipBuild
    Reuse an executable already built by a previous run.

.EXAMPLE
    .\scripts\package-windows.ps1
    .\scripts\package-windows.ps1 -PreRelease alpha.2
#>
[CmdletBinding()]
param(
    [string] $PreRelease = 'alpha.1',
    [string] $OptimizationLevel = '2',
    [switch] $SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host "`n=== $Message" -ForegroundColor Cyan }
function Write-Note { param([string] $Message) Write-Host "    $Message" }
function Write-Warn { param([string] $Message) Write-Host "    WARNING: $Message" -ForegroundColor Yellow }

# --- locate the repository -------------------------------------------------

$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {

$CabalFile = Join-Path $RepoRoot 'sequent.cabal'
if (-not (Test-Path $CabalFile)) {
    throw "sequent.cabal not found at $CabalFile; run this script from the repository."
}

# --- version ---------------------------------------------------------------

Write-Step 'Version'

$versionLine = Select-String -Path $CabalFile -Pattern '^\s*version:\s*(\S+)' | Select-Object -First 1
if (-not $versionLine) { throw "No version: field found in $CabalFile." }
$CabalVersion = $versionLine.Matches[0].Groups[1].Value

$Version = if ([string]::IsNullOrWhiteSpace($PreRelease)) { $CabalVersion } else { "$CabalVersion-$PreRelease" }

$Project  = 'sequent'
$Platform = 'windows-x86_64'
$StageName = "$Project-$Version-$Platform"

Write-Note "manifest version : $CabalVersion"
Write-Note "release version  : $Version"

# --- build -----------------------------------------------------------------

$StageRoot   = Join-Path $RepoRoot 'dist\pre-alpha'
$StageDir    = Join-Path $StageRoot $StageName
$ReleaseDir  = Join-Path $RepoRoot 'dist\releases'
$ExePath     = Join-Path $StageDir 'sequent.exe'

Write-Step 'Staging directory'
if (Test-Path $StageDir) {
    Write-Note "removing previous staging directory"
    Remove-Item -Recurse -Force $StageDir
}
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null
Write-Note $StageDir

if (-not $SkipBuild) {
    Write-Step 'Build (optimized)'

    foreach ($tool in 'cabal', 'ghc') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool was not found on PATH. Building the release requires GHC and Cabal on this machine (the produced .exe does not)."
        }
    }
    $ghcVersion = (& ghc --numeric-version | Out-String).Trim()
    Write-Note "ghc $ghcVersion"

    & cabal update
    if ($LASTEXITCODE -ne 0) { throw "cabal update failed." }

    # Install straight into the staging directory. This avoids guessing the
    # dist-newstyle layout: with --enable-optimization the binary lands in an
    # 'opt' subdirectory, so a bare `cabal list-bin` would report a stale
    # unoptimized path from an earlier plain build.
    & cabal install "exe:$Project" `
        --enable-optimization=$OptimizationLevel `
        --install-method=copy `
        --overwrite-policy=always `
        --installdir="$StageDir"
    if ($LASTEXITCODE -ne 0) { throw "cabal install failed." }
}
else {
    Write-Step 'Build (skipped)'
    $built = (& cabal list-bin "exe:$Project" --enable-optimization=$OptimizationLevel | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $built)) {
        throw "-SkipBuild was given but no previously built executable was found."
    }
    Copy-Item $built $ExePath -Force
    Write-Note "reused $built"
}

if (-not (Test-Path $ExePath)) {
    throw "Expected $ExePath after the build, but it is missing."
}
Write-Note ("sequent.exe {0:N1} MiB" -f ((Get-Item $ExePath).Length / 1MB))

# --- runtime dependencies --------------------------------------------------

Write-Step 'Runtime dependencies'

# DLLs that are part of Windows itself. These must never be redistributed.
$SystemDlls = @(
    'kernel32.dll', 'kernelbase.dll', 'user32.dll', 'gdi32.dll', 'advapi32.dll',
    'shell32.dll', 'shlwapi.dll', 'ole32.dll', 'oleaut32.dll', 'msvcrt.dll',
    'ws2_32.dll', 'winmm.dll', 'dbghelp.dll', 'ntdll.dll', 'rpcrt4.dll',
    'crypt32.dll', 'bcrypt.dll', 'secur32.dll', 'userenv.dll', 'version.dll',
    'iphlpapi.dll', 'mswsock.dll', 'psapi.dll', 'setupapi.dll', 'imm32.dll',
    'comctl32.dll', 'comdlg32.dll', 'winspool.drv', 'ucrtbase.dll'
)
$SystemPrefixes = @('api-ms-win-', 'ext-ms-win-', 'vcruntime', 'msvcp')

function Get-ImportedDll {
    param([string] $Path)

    $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($dumpbin) {
        Write-Note "inspecting with dumpbin"
        $out = & $dumpbin.Source /NOLOGO /DEPENDENTS $Path 2>$null
        return $out |
            Select-String -Pattern '^\s{4}(\S+\.dll)\s*$' |
            ForEach-Object { $_.Matches[0].Groups[1].Value }
    }

    $objdump = Get-Command objdump.exe -ErrorAction SilentlyContinue
    if ($objdump) {
        Write-Note "inspecting with objdump"
        $out = & $objdump.Source -p $Path 2>$null
        return $out |
            Select-String -Pattern '^\s*DLL Name:\s*(\S+)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value }
    }

    return $null
}

$imports = Get-ImportedDll -Path $ExePath

if ($null -eq $imports) {
    Write-Warn "Neither dumpbin.exe nor objdump.exe is available; the import table was not inspected."
    Write-Warn "sequent has no FFI or C dependencies, so only Windows system DLLs are expected,"
    Write-Warn "but this run could not verify that. Smoke-test on a clean machine before releasing."
    $imports = @()
}

$imports = @($imports | Sort-Object -Unique)
$bundled = @()

foreach ($dll in $imports) {
    $lower = $dll.ToLowerInvariant()
    $isSystem = $SystemDlls -contains $lower
    if (-not $isSystem) {
        foreach ($prefix in $SystemPrefixes) {
            if ($lower.StartsWith($prefix)) { $isSystem = $true; break }
        }
    }

    if ($isSystem) {
        Write-Note "system     $dll"
        continue
    }

    # Not a known system DLL: find it next to the toolchain and bundle it.
    Write-Note "non-system $dll  <- needs bundling"
    $source = $null
    $searchDirs = New-Object System.Collections.Generic.List[string]
    $searchDirs.Add((Split-Path $ExePath))
    $ghcCmd = Get-Command ghc -ErrorAction SilentlyContinue
    if ($ghcCmd) {
        # GHC's own bin directory, and the installation root above it so the
        # bundled mingw toolchain is searched too.
        $ghcBin = Split-Path $ghcCmd.Source
        $searchDirs.Add($ghcBin)
        $searchDirs.Add((Split-Path $ghcBin))
    }
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path $dir)) { continue }
        $candidate = Get-ChildItem -Path $dir -Filter $dll -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($candidate) { $source = $candidate.FullName; break }
    }

    if ($source) {
        Copy-Item $source (Join-Path $StageDir $dll) -Force
        $bundled += $dll
        Write-Note "  bundled from $source"
    }
    else {
        Write-Warn "  $dll could not be located; the release may not run on a clean machine."
    }
}

if ($bundled.Count -eq 0) {
    Write-Note "no non-system DLLs required; nothing bundled"
}

# --- payload ---------------------------------------------------------------

Write-Step 'Payload'

$PackagingDir = Join-Path $RepoRoot 'packaging\windows'

# README.txt, with the version substituted so it cannot drift.
$readmeSrc = Join-Path $PackagingDir 'README.txt'
(Get-Content $readmeSrc -Raw).Replace('@VERSION@', $Version) |
    Set-Content (Join-Path $StageDir 'README.txt') -NoNewline -Encoding ascii
Write-Note 'README.txt'

Copy-Item (Join-Path $PackagingDir 'sequent.cmd') (Join-Path $StageDir 'sequent.cmd') -Force
Write-Note 'sequent.cmd'

"$Version`r`n" | Set-Content (Join-Path $StageDir 'VERSION') -NoNewline -Encoding ascii
Write-Note 'VERSION'

# LICENSE: copy only a file that actually exists. Never invent one.
$licenseSrc = Get-ChildItem -Path $RepoRoot -File |
    Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING)(\.\w+)?$' } |
    Select-Object -First 1
if ($licenseSrc) {
    Copy-Item $licenseSrc.FullName (Join-Path $StageDir 'LICENSE') -Force
    Write-Note "LICENSE (from $($licenseSrc.Name))"
}
else {
    $declared = Select-String -Path $CabalFile -Pattern '^\s*license:\s*(\S+)' |
        Select-Object -First 1
    $declaredName = if ($declared) { $declared.Matches[0].Groups[1].Value } else { 'unknown' }
    Write-Warn "No LICENSE file exists in the repository."
    Write-Warn "sequent.cabal declares 'license: $declaredName', but the license text is absent,"
    Write-Warn "so the distribution ships without one. Add a LICENSE file to the repository root;"
    Write-Warn "this script will pick it up automatically. No license has been invented here."
}

# Examples: sources, plus one .bpmn so `import` can be demonstrated.
$examplesSrc = Join-Path $RepoRoot 'examples'
$examplesDst = Join-Path $StageDir 'examples'
New-Item -ItemType Directory -Force -Path $examplesDst | Out-Null
# Ship only examples that are actually in the repository. Some .sq/.bpmn files
# in examples/ are gitignored local scratch files and must not be published.
$useGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
Get-ChildItem -Path $examplesSrc -Filter '*.sq' | ForEach-Object {
    if ($useGit) {
        & git check-ignore -q -- $_.FullName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Note "  skipping $($_.Name) (gitignored)"
            return
        }
    }
    Copy-Item $_.FullName $examplesDst -Force
}
$helloBpmn = Join-Path $examplesSrc 'hello.bpmn'
if (Test-Path $helloBpmn) { Copy-Item $helloBpmn $examplesDst -Force }
Write-Note ("examples ({0} files)" -f (Get-ChildItem $examplesDst).Count)

# --- smoke test ------------------------------------------------------------

Write-Step 'Smoke test (from the staging directory, not the build tree)'

Push-Location $StageDir
try {
    & $ExePath --help | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sequent.exe --help failed with exit code $LASTEXITCODE." }
    Write-Note '--help ok'

    & $ExePath rules | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sequent.exe rules failed with exit code $LASTEXITCODE." }
    Write-Note 'rules ok'

    & $ExePath build 'examples\hello.sq' -o 'examples\smoke.bpmn' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sequent.exe build failed with exit code $LASTEXITCODE." }
    if (-not (Test-Path 'examples\smoke.bpmn')) { throw "build reported success but wrote no output." }
    Write-Note 'build ok'

    & $ExePath check 'examples\order.sq' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sequent.exe check failed with exit code $LASTEXITCODE." }
    Write-Note 'check ok'

    & $ExePath import 'examples\hello.bpmn' -o 'examples\smoke.sq' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sequent.exe import failed with exit code $LASTEXITCODE." }
    Write-Note 'import ok'

    Remove-Item 'examples\smoke.bpmn', 'examples\smoke.sq' -Force -ErrorAction SilentlyContinue
}
finally {
    Pop-Location
}

# --- archive ---------------------------------------------------------------

Write-Step 'Archive'

$ZipPath = Join-Path $ReleaseDir "$StageName.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

Compress-Archive -Path $StageDir -DestinationPath $ZipPath -CompressionLevel Optimal
Write-Note ("{0}  ({1:N1} MiB)" -f (Split-Path $ZipPath -Leaf), ((Get-Item $ZipPath).Length / 1MB))

$hash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$ShaPath = "$ZipPath.sha256"
"$hash  $StageName.zip`n" | Set-Content $ShaPath -NoNewline -Encoding ascii
Write-Note "$hash"
Write-Note (Split-Path $ShaPath -Leaf)

# --- summary ---------------------------------------------------------------

Write-Step 'Done'
Write-Note "staged : $StageDir"
Write-Note "zip    : $ZipPath"
Write-Note "sha256 : $ShaPath"
if ($bundled.Count -gt 0) {
    Write-Note "bundled DLLs: $($bundled -join ', ')"
}

}
finally {
    Pop-Location
}
