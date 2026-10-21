BeforeAll {
    $script:verifier = Join-Path $PSScriptRoot '../scripts/Test-SyntheticExportFixture.ps1'
    function Write-TestGzip {
        param([string]$Path, [string]$Text)
        $file = [IO.File]::Create($Path)
        $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Compress)
        $writer = [IO.StreamWriter]::new($gzip, [Text.UTF8Encoding]::new($false))
        try { $writer.Write($Text) } finally { $writer.Dispose() }
    }
    function Update-TestManifest {
        $artifacts = @(Get-ChildItem -LiteralPath $script:dataset -File | ForEach-Object {
            [ordered]@{name=$_.Name;path=$_.FullName;bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
        })
        [ordered]@{uploadManifestVersion=1;mode='RawReplay';artifacts=$artifacts} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:manifest
    }
    function Invoke-TestVerifier {
        & $script:verifier -DatasetPath $script:dataset -UploadManifestPath $script:manifest -ExpectedDeviceCount 2 -ExpectedVulnerabilityRows 2
    }
}
Describe 'Bounded genuine synthetic upload verification' {
    BeforeEach {
        $script:dataset = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dataset | Out-Null
        $script:manifest = $script:dataset + '-upload.json'
        $script:machines = Join-Path $script:dataset 'Machines_Current.json.gz'
        $script:vulnerabilities = Join-Path $script:dataset 'VulnExport_100_2026-10-21.json.gz'
        Write-TestGzip $script:machines "{`"id`":`"sim-0000000`",`"computerDnsName`":`"device-0000000.synthetic.test`"}`n{`"id`":`"sim-0000001`",`"computerDnsName`":`"device-0000001.synthetic.test`"}`n"
        Write-TestGzip $script:vulnerabilities "{`"DeviceId`":`"sim-0000000`",`"CveId`":`"CVE-2026-1000`"}`n{`"DeviceId`":`"sim-0000001`",`"CveId`":`"CVE-2026-1001`"}`n"
        Update-TestManifest
    }
    It 'accepts actual GZip NDJSON with exact counts, joined devices and a content identity' {
        $result = Invoke-TestVerifier
        $result.fixtureValid | Should -BeTrue
        $result.deviceCount | Should -Be 2
        $result.vulnerabilityRows | Should -Be 2
        $result.azureActionsPerformed | Should -BeFalse
        $result.vulnerabilityContentSha256 | Should -Match '^[a-f0-9]{64}$'
        $repeat = & $script:verifier -DatasetPath $script:dataset -UploadManifestPath $script:manifest -ExpectedDeviceCount 2 -ExpectedVulnerabilityRows 2 -ExpectedVulnerabilityContentSha256 $result.vulnerabilityContentSha256
        $repeat.fixtureValid | Should -BeTrue
    }
    It 'rejects renamed plaintext even when the manifest matches its hash' {
        Set-Content -LiteralPath $script:vulnerabilities -Value '{}'
        Update-TestManifest
        { Invoke-TestVerifier } | Should -Throw '*GZip*'
    }
    It 'rejects a truncated GZip stream with a recomputed transport hash' {
        $bytes = [IO.File]::ReadAllBytes($script:vulnerabilities)
        [IO.File]::WriteAllBytes($script:vulnerabilities, $bytes[0..($bytes.Length-9)])
        Update-TestManifest
        { Invoke-TestVerifier } | Should -Throw
    }
    It 'rejects a JSON array instead of NDJSON objects' {
        Write-TestGzip $script:vulnerabilities "[]`n"
        Update-TestManifest
        { Invoke-TestVerifier } | Should -Throw '*object*'
    }
    It 'rejects corrupt transport bytes without trusting counts' {
        [IO.File]::AppendAllText($script:vulnerabilities, 'altered')
        { Invoke-TestVerifier } | Should -Throw '*SHA256*'
    }
    It 'rejects unexpected vulnerability counts' {
        { & $script:verifier -DatasetPath $script:dataset -UploadManifestPath $script:manifest -ExpectedDeviceCount 2 -ExpectedVulnerabilityRows 3 } | Should -Throw '*counts*'
    }
    It 'rejects altered content even with a recomputed transport manifest' {
        $baseline = Invoke-TestVerifier
        Write-TestGzip $script:vulnerabilities "{`"DeviceId`":`"sim-0000000`",`"CveId`":`"CVE-2026-9999`"}`n{`"DeviceId`":`"sim-0000001`",`"CveId`":`"CVE-2026-1001`"}`n"
        Update-TestManifest
        { & $script:verifier -DatasetPath $script:dataset -UploadManifestPath $script:manifest -ExpectedDeviceCount 2 -ExpectedVulnerabilityRows 2 -ExpectedVulnerabilityContentSha256 $baseline.vulnerabilityContentSha256 } | Should -Throw '*content identity*'
    }
    It 'rejects a foreign or unknown device' {
        Write-TestGzip $script:vulnerabilities "{`"DeviceId`":`"sim-0000999`",`"CveId`":`"CVE-2026-1000`"}`n{`"DeviceId`":`"sim-0000001`",`"CveId`":`"CVE-2026-1001`"}`n"
        Update-TestManifest
        { Invoke-TestVerifier } | Should -Throw '*unknown*device*'
    }
    It 'rejects array-valued identities instead of coercing them to strings' {
        Write-TestGzip $script:vulnerabilities "{`"DeviceId`":`"sim-0000000`",`"CveId`":[]}`n"
        Update-TestManifest
        { Invoke-TestVerifier } | Should -Throw '*identity*'
    }
    It 'rejects duplicate object properties' {
        Write-TestGzip $script:vulnerabilities "{`"DeviceId`":`"sim-0000000`",`"DeviceId`":`"sim-0000001`",`"CveId`":`"CVE-2026-1000`"}`n"
        Update-TestManifest
        { Invoke-TestVerifier } | Should -Throw '*Duplicate*'
    }
    It 'binds machine content as well as vulnerability rows to the fixture identity' {
        $baseline = Invoke-TestVerifier
        Write-TestGzip $script:machines "{`"id`":`"sim-0000000`",`"computerDnsName`":`"device-0000099.synthetic.test`"}`n{`"id`":`"sim-0000001`",`"computerDnsName`":`"device-0000001.synthetic.test`"}`n"
        Update-TestManifest
        { & $script:verifier -DatasetPath $script:dataset -UploadManifestPath $script:manifest -ExpectedDeviceCount 2 -ExpectedVulnerabilityRows 2 -ExpectedFixtureSha256 $baseline.fixtureSha256 } | Should -Throw '*Fixture identity*'
    }
    It 'rejects unexpected controls outside the upload list' {
        Set-Content -LiteralPath (Join-Path $script:dataset 'ExportAndGenerate.control.json') -Value '{}'
        { Invoke-TestVerifier } | Should -Throw '*Unexpected input*'
    }
    It 'rejects unexpected enrichment files even in a matching manifest' {
        Copy-Item -LiteralPath $script:vulnerabilities -Destination (Join-Path $script:dataset 'AdvancedHunting_Current.json.gz')
        Update-TestManifest
        { Invoke-TestVerifier } | Should -Throw '*Unexpected or duplicate*'
    }
    It 'rejects a manifest path pointing outside the selected dataset' {
        $value = Get-Content -LiteralPath $script:manifest -Raw | ConvertFrom-Json
        $value.artifacts[0].path = Join-Path $TestDrive 'other.json.gz'
        $value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:manifest
        { Invoke-TestVerifier } | Should -Throw '*path does not match*'
    }
    It 'enforces a decompression bound before parsing oversized records' {
        Write-TestGzip $script:vulnerabilities ('x' * 5000)
        Update-TestManifest
        { & $script:verifier -DatasetPath $script:dataset -UploadManifestPath $script:manifest -ExpectedDeviceCount 2 -ExpectedVulnerabilityRows 2 -MaxExpandedBytes 1024 } | Should -Throw '*expanded size*'
    }
}
