#Requires -Version 5.1
<#
  build-release.ps1

  Builds the release archive for discord-media-hosts-fix from the three files
  that are handed to users, without touching the working tree:

    dist/discord-media-hosts-fix.zip
    dist/SHA256SUMS
    dist/release-notes.md   (the CHANGELOG section for this version)

  The build is reproducible on purpose: shipped files are written with CRLF and
  no BOM, zip timestamps are fixed, and the file list is explicit. The script
  also refuses to build when the tag does not match $AppVersion, when the
  PowerShell syntax is broken, or when README/CHANGELOG still name another
  version - so a release cannot ship stale files.

  Usage:
    powershell -ExecutionPolicy Bypass -File .\build-release.ps1
    powershell -ExecutionPolicy Bypass -File .\build-release.ps1 -Tag v1.8.0

  The GitHub Actions workflow (.github/workflows/release.yml) runs this script
  for a pushed tag, so a local build and a CI build are the same operation.

  License: MIT, Copyright (c) 2026 TestSoulja. See LICENSE in the repository.
#>
[CmdletBinding()]
param(
    [string]$Tag = '',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$shipped = @('fix-discord-media.bat', 'fix-discord-media.ps1', 'remove-pins.bat')
$ps1Path = Join-Path $root 'fix-discord-media.ps1'
$readmePath = Join-Path $root 'README.md'
$changelogPath = Join-Path $root 'CHANGELOG.md'

# ---------- the version comes from the script itself ----------
$ps1Text = [IO.File]::ReadAllText($ps1Path)
$versionMatch = [regex]::Match($ps1Text, '(?m)^\$AppVersion\s*=\s*''([0-9]+\.[0-9]+\.[0-9]+)''')
if (-not $versionMatch.Success) {
    throw 'Could not read $AppVersion from fix-discord-media.ps1.'
}
$version = $versionMatch.Groups[1].Value

if ($Tag) {
    $tagVersion = $Tag -replace '^v', ''
    if ($tagVersion -ne $version) {
        throw ("Tag {0} does not match AppVersion {1} in fix-discord-media.ps1." -f $Tag, $version)
    }
}

# ---------- syntax check, so a broken script never becomes a release ----------
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ps1Path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    $first = $parseErrors[0]
    throw ("PowerShell syntax error at line {0}: {1}" -f $first.Extent.StartLineNumber, $first.Message)
}

# ---------- docs must already name this version ----------
$readme = [IO.File]::ReadAllText($readmePath, [Text.Encoding]::UTF8)
$required = @(
    "**Version $version**"
)
foreach ($needle in $required) {
    if (-not $readme.Contains($needle)) {
        throw ("README.md is not updated for {0}: missing '{1}'." -f $version, $needle)
    }
}
# Both language sections end with a "**v<version>**" release marker. The marker
# itself is ASCII, so the check works in Windows PowerShell 5.1 regardless of
# the README encoding.
$releaseMarker = "**v$version**"
if ([regex]::Matches($readme, [regex]::Escape($releaseMarker)).Count -lt 2) {
    throw ("README.md is not updated for {0}: expected two '{1}' markers." -f $version, $releaseMarker)
}

$changelog = [IO.File]::ReadAllText($changelogPath, [Text.Encoding]::UTF8)
$sectionPattern = '(?ms)^## \[' + [regex]::Escape($version) + '\][^\r\n]*\r?\n.*?(?=^## \[|\z)'
$sectionMatch = [regex]::Match($changelog, $sectionPattern)
if (-not $sectionMatch.Success) {
    throw ("CHANGELOG.md has no '## [{0}]' section." -f $version)
}
$section = $sectionMatch.Value.TrimEnd()

# ---------- build the archive ----------
$outDirFull = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $outDirFull)) {
    New-Item -ItemType Directory -Path $outDirFull -Force | Out-Null
}

$zipName = 'discord-media-hosts-fix.zip'
$zipPath = Join-Path $outDirFull $zipName
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
# Fixed timestamp: a rebuild from the same commit produces the same bytes.
$fixedTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$sizes = @{}

$zipStream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
try {
    $archive = [System.IO.Compression.ZipArchive]::new(
        $zipStream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $true
    )
    try {
        foreach ($name in $shipped) {
            $path = Join-Path $root $name
            if (-not (Test-Path -LiteralPath $path)) {
                throw ("Missing shipped file: {0}" -f $name)
            }

            # The .gitattributes rule is eol=crlf for these files; normalise here
            # so a Linux checkout can never ship LF-only .bat/.ps1.
            $text = [IO.File]::ReadAllText($path)
            $text = $text -replace "`r?`n", "`r`n"
            $bytes = $utf8NoBom.GetBytes($text)

            $entry = $archive.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTime
            $entryStream = $entry.Open()
            try {
                $entryStream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $entryStream.Dispose()
            }
            $sizes[$name] = $bytes.Length
        }
    }
    finally {
        $archive.Dispose()
    }
}
finally {
    $zipStream.Dispose()
}

# ---------- checksum ----------
$hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$sumsPath = Join-Path $outDirFull 'SHA256SUMS'
[IO.File]::WriteAllText($sumsPath, ("{0}  {1}`n" -f $hash, $zipName), $utf8NoBom)

# ---------- release notes ----------
$noteLines = New-Object System.Collections.Generic.List[string]
$noteLines.Add($section)
$noteLines.Add('')
$noteLines.Add('---')
$noteLines.Add('')
$noteLines.Add('**The archive contains exactly three files**')
$noteLines.Add('')
$noteLines.Add('```')
foreach ($name in $shipped) {
    $noteLines.Add(("{0,-26} {1,6} bytes" -f $name, $sizes[$name]))
}
$noteLines.Add('```')
$noteLines.Add('')
$noteLines.Add('**SHA256**')
$noteLines.Add('')
$noteLines.Add('```')
$noteLines.Add(("{0}  {1}" -f $hash, $zipName))
$noteLines.Add('```')
$noteLines.Add('')
$noteLines.Add('Full history: [CHANGELOG.md](https://github.com/TestSoulja/discord-media-hosts-fix/blob/main/CHANGELOG.md).')

$notesPath = Join-Path $outDirFull 'release-notes.md'
[IO.File]::WriteAllText($notesPath, (($noteLines -join "`n") + "`n"), $utf8NoBom)

# ---------- summary ----------
Write-Host ''
Write-Host ("Built {0} {1}" -f $zipName, $version) -ForegroundColor Green
Write-Host ("  {0}" -f $zipPath) -ForegroundColor DarkGray
Write-Host ("  SHA256 {0}" -f $hash) -ForegroundColor DarkGray
foreach ($name in $shipped) {
    Write-Host ("  {0,-26} {1,6} bytes" -f $name, $sizes[$name]) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host ("Upload with the release: {0} and {1}" -f $zipName, 'SHA256SUMS') -ForegroundColor Gray
