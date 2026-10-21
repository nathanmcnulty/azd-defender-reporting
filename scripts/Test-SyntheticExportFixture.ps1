#Requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DatasetPath,
    [Parameter(Mandatory)][string]$UploadManifestPath,
    [Parameter(Mandatory)][ValidateRange(1, 5000)][int]$ExpectedDeviceCount,
    [Parameter(Mandatory)][ValidateRange(1, 50000)][int]$ExpectedVulnerabilityRows,
    [ValidatePattern('^$|^[a-f0-9]{64}$')][string]$ExpectedVulnerabilityContentSha256 = '',
    [ValidatePattern('^$|^[a-f0-9]{64}$')][string]$ExpectedFixtureSha256 = '',
    [ValidateRange(1024, 104857600)][long]$MaxExpandedBytes = 52428800
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This offline verifier never uploads or executes data. Only the two approved
# synthetic input families are eligible; control blobs and enrichment are excluded.
$root = [IO.Path]::GetFullPath($DatasetPath)
if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Dataset root must not be a reparse point.' }
$manifestFile = Get-Item -LiteralPath $UploadManifestPath
if ($manifestFile.Length -gt 1MB) { throw 'Upload manifest exceeds the size bound.' }
$manifest = Get-Content -LiteralPath $UploadManifestPath -Raw | ConvertFrom-Json -Depth 20
if ($manifest.uploadManifestVersion -ne 1 -or $manifest.mode -cne 'RawReplay') { throw 'Expected an upstream RawReplay upload manifest.' }
$artifacts = @($manifest.artifacts)
if ($artifacts.Count -lt 2 -or $artifacts.Count -gt 100) { throw 'Unexpected fixture artifact count.' }
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$devices = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$vulnerabilityDevices = [Collections.Generic.List[string]]::new()
$rowHashes = [Collections.Generic.List[string]]::new()
$records = [Collections.Generic.List[object]]::new()
$expandedBytes = 0L
$totalCompressedBytes = 0L
foreach ($artifact in $artifacts) {
    $name = [string]$artifact.name
    if (($name -cne 'Machines_Current.json.gz' -and $name -cnotmatch '^VulnExport_[0-9]+_[0-9]{4}-[0-9]{2}-[0-9]{2}\.json\.gz$') -or -not $names.Add($name)) { throw 'Unexpected or duplicate upload artifact.' }
    $filePath = Join-Path $root $name
    if ([IO.Path]::GetFullPath([string]$artifact.path) -ine $filePath) { throw 'Manifest artifact path does not match the dataset.' }
    $file = Get-Item -LiteralPath $filePath
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact must not be a reparse point.' }
    $totalCompressedBytes += $file.Length
    if ($totalCompressedBytes -gt 10MB) { throw 'Fixture exceeds the compressed size bound.' }
    $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($file.Length -ne [long]$artifact.bytes -or [string]$artifact.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $hash -cne [string]$artifact.sha256) { throw 'Artifact size or SHA256 mismatch.' }
    $stream = [IO.File]::OpenRead($filePath)
    $reader = $null
    $gzip = $null
    $rows = 0
    try {
        if ($stream.Length -lt 18) { throw 'Artifact is incomplete GZip.' }
        if ($stream.ReadByte() -ne 0x1f -or $stream.ReadByte() -ne 0x8b) { throw 'Artifact is not genuine GZip.' }
        $stream.Position = $stream.Length - 4
        $sizeBytes = [byte[]]::new(4)
        if ($stream.Read($sizeBytes, 0, 4) -ne 4) { throw 'Missing GZip footer.' }
        $footerSize = [BitConverter]::ToUInt32($sizeBytes, 0)
        $stream.Position = 0
        $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
        # Bounded copying prevents an unterminated NDJSON line or compression bomb
        # from allocating beyond the aggregate expansion limit before ReadLine.
        $expanded = [IO.MemoryStream]::new()
        try {
            $buffer = [byte[]]::new(8192)
            while (($read = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $expandedBytes += $read
                if ($expandedBytes -gt $MaxExpandedBytes) { throw 'Fixture exceeds the expanded size bound.' }
                $expanded.Write($buffer, 0, $read)
            }
            if ($expanded.Length -ne $footerSize) { throw 'GZip footer does not match the expanded size.' }
            $expanded.Position = 0
            $reader = [IO.StreamReader]::new($expanded, [Text.UTF8Encoding]::new($false, $true), $false)
            while ($null -ne ($line = $reader.ReadLine())) {
                if ([string]::IsNullOrWhiteSpace($line)) { throw 'NDJSON must not contain blank records.' }
                $document = [Text.Json.JsonDocument]::Parse($line)
                try {
                    if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'NDJSON record must be an object.' }
                    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    foreach ($property in $document.RootElement.EnumerateObject()) {
                        if (-not $keys.Add($property.Name)) { throw 'Duplicate NDJSON property.' }
                    }
                } finally { $document.Dispose() }
                $row = $line | ConvertFrom-Json -Depth 30
                $rows++
                if ($name -ceq 'Machines_Current.json.gz') {
                    if ($rows -gt $ExpectedDeviceCount) { throw 'Unexpected device count.' }
                    if ($row.id -isnot [string] -or $row.computerDnsName -isnot [string] -or $row.id -cnotmatch '^sim-[0-9]{7}$' -or $row.computerDnsName -cnotmatch '^device-[0-9]{7}\.synthetic\.test$' -or -not $devices.Add([string]$row.id)) { throw 'Unexpected synthetic device identity.' }
                } else {
                    if ($rowHashes.Count -ge $ExpectedVulnerabilityRows) { throw 'Unexpected vulnerability row count.' }
                    if ($row.DeviceId -isnot [string] -or $row.CveId -isnot [string] -or $row.DeviceId -cnotmatch '^sim-[0-9]{7}$' -or $row.CveId -cnotmatch '^CVE-[0-9]{4}-[0-9]+$') { throw 'Unexpected vulnerability identity.' }
                    $vulnerabilityDevices.Add([string]$row.DeviceId)
                    $compact = $row | ConvertTo-Json -Depth 30 -Compress
                    $rowHashes.Add([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($compact))).ToLowerInvariant())
                }
            }
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            $expanded.Dispose()
        }
    } finally {
        if ($null -ne $gzip) { $gzip.Dispose() }
        $stream.Dispose()
    }
    if ($rows -eq 0) { throw 'Empty fixture artifact.' }
    $records.Add([pscustomobject]@{name=$name;bytes=$file.Length;sha256=$hash;rows=$rows})
}
if (-not $names.Contains('Machines_Current.json.gz') -or $devices.Count -ne $ExpectedDeviceCount -or $rowHashes.Count -ne $ExpectedVulnerabilityRows) { throw 'Fixture does not match the required counts.' }
foreach ($device in $vulnerabilityDevices) { if (-not $devices.Contains($device)) { throw 'Vulnerability references an unknown synthetic device.' } }
foreach ($file in Get-ChildItem -LiteralPath $root -File -Force) {
    if (-not $names.Contains($file.Name) -and $file.Name -cne 'synthetic-legacy-manifest.json') { throw 'Unexpected input in the dataset directory.' }
}
if (@(Get-ChildItem -LiteralPath $root -Directory -Force).Count) { throw 'Fixture subdirectories are not allowed.' }
$rowHashes.Sort([StringComparer]::Ordinal)
$contentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($rowHashes -join "`n")))).ToLowerInvariant()
if ($ExpectedVulnerabilityContentSha256 -and $contentHash -cne $ExpectedVulnerabilityContentSha256) { throw 'Vulnerability content identity mismatch.' }
$artifactIdentity = [Collections.Generic.List[string]]::new()
foreach ($record in $records) { $artifactIdentity.Add(('{0}|{1}|{2}' -f $record.name, $record.bytes, $record.sha256)) }
$artifactIdentity.Sort([StringComparer]::Ordinal)
$fixtureHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($artifactIdentity -join "`n")))).ToLowerInvariant()
if ($ExpectedFixtureSha256 -and $fixtureHash -cne $ExpectedFixtureSha256) { throw 'Fixture identity mismatch.' }
[pscustomobject]@{
    fixtureValid=$true;deviceCount=$devices.Count;vulnerabilityRows=$rowHashes.Count
    vulnerabilityContentSha256=$contentHash;fixtureSha256=$fixtureHash;compressedBytes=$totalCompressedBytes;expandedBytes=$expandedBytes
    artifacts=$records.ToArray();azureActionsPerformed=$false
    limitation='Offline input validation only; does not prove report semantics, job lifecycle or native acceptance.'
}
