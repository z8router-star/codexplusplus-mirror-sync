[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',
    [string]$ProductId = '9PLM9XGG6VKS'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Pin the exact public resolver package before executing its download-function
# region. The Gallery fetch uses normal certificate validation; the temporary
# FE3 workaround is enabled only after this byte-for-byte check succeeds.
$resolverUri = 'https://www.powershellgallery.com/api/v2/package/Get-MSStoreInstaller/1.0.1'
$resolverSha256 = '757b9678cd2c774e8c305febbfb6fc52ce822d33cc000cb4864a8147c69aa923'
$archive = Join-Path ([IO.Path]::GetTempPath()) 'z8-get-msstoreinstaller.zip'
$extract = Join-Path ([IO.Path]::GetTempPath()) 'z8-get-msstoreinstaller'
Invoke-WebRequest -Uri $resolverUri -OutFile $archive
$actualResolverSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualResolverSha256 -ne $resolverSha256) {
    throw "Microsoft Store resolver digest mismatch: expected $resolverSha256, got $actualResolverSha256"
}
if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
$source = Get-Content -Raw -LiteralPath (Join-Path $extract 'Get-MSStoreInstaller.ps1')
$start = $source.IndexOf('#region Download Functions')
$end = $source.LastIndexOf('#endregion')
if ($start -lt 0 -or $end -le $start) { throw 'Unable to load the Microsoft Store resolver functions.' }
Invoke-Expression $source.Substring($start, $end - $start + 10)

# A subset of FE3 edges has served an incomplete certificate chain to hosted
# runners. Keep this exception scoped to the already-pinned resolver call and
# restore the PowerShell defaults immediately afterwards. The workflow still
# accepts only Microsoft's CDN host and verifies MSIX identity + Authenticode.
$restSkipKey = 'Invoke-RestMethod:SkipCertificateCheck'
$webSkipKey = 'Invoke-WebRequest:SkipCertificateCheck'
$hadRestSkip = $PSDefaultParameterValues.ContainsKey($restSkipKey)
$hadWebSkip = $PSDefaultParameterValues.ContainsKey($webSkipKey)
$previousRestSkip = $PSDefaultParameterValues[$restSkipKey]
$previousWebSkip = $PSDefaultParameterValues[$webSkipKey]
try {
    $PSDefaultParameterValues[$restSkipKey] = $true
    $PSDefaultParameterValues[$webSkipKey] = $true
    $items = @(Get-StoreURLS -ProductNumber $ProductId -Architecture $Architecture)
} finally {
    if ($hadRestSkip) { $PSDefaultParameterValues[$restSkipKey] = $previousRestSkip } else { $PSDefaultParameterValues.Remove($restSkipKey) }
    if ($hadWebSkip) { $PSDefaultParameterValues[$webSkipKey] = $previousWebSkip } else { $PSDefaultParameterValues.Remove($webSkipKey) }
}
$item = $items | Where-Object { $_.FileName -match "OpenAI\.Codex_(?<version>\d+\.\d+\.\d+\.\d+)_${Architecture}_" } | Select-Object -First 1
if ($null -eq $item) { throw "Microsoft Store returned no OpenAI.Codex $Architecture MSIX." }

$candidates = foreach ($candidate in @($item.URLS)) {
    # The Store service currently emits HTTP CDN URLs, and some edges reject
    # HTTPS during the TLS handshake. Preserve the protocol here; the workflow
    # accepts only this exact Microsoft CDN host and requires Authenticode
    # verification before an artifact can be published.
    $normalized = [string]$candidate
    $candidateUri = $null
    if (-not [Uri]::TryCreate($normalized, [UriKind]::Absolute, [ref]$candidateUri) -or
        $candidateUri.Host -notmatch '(^|\.)dl\.delivery\.mp\.microsoft\.com$' -or
        $candidateUri.Scheme -notin @('http', 'https')) {
        continue
    }
    try {
        $head = Invoke-WebRequest -Uri $normalized -Method Head
        $length = [long]$head.Headers['Content-Length']
        [pscustomobject]@{ Url = $normalized; Size = $length }
    } catch {
        [pscustomobject]@{ Url = $normalized; Size = 0L }
    }
}
$selected = $candidates | Where-Object { $_.Url -match '\?P1=' } | Select-Object -First 1
if ($null -eq $selected) {
    $selected = $candidates | Sort-Object Size -Descending | Select-Object -First 1
}
if ($null -eq $selected) { $selected = $candidates | Sort-Object Size -Descending | Select-Object -First 1 }
if ($null -eq $selected -or [string]::IsNullOrWhiteSpace($selected.Url)) { throw 'Microsoft Store returned no downloadable MSIX URL.' }

[pscustomobject]@{
    fileName = [string]$item.FileName
    version = [regex]::Match([string]$item.FileName, 'OpenAI\.Codex_(?<version>\d+\.\d+\.\d+\.\d+)_').Groups['version'].Value
    size = [long]$selected.Size
    url = [string]$selected.Url
    urls = @($candidates | ForEach-Object { [string]$_.Url })
} | ConvertTo-Json -Compress
