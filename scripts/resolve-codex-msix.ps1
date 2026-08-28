[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',
    [string]$ProductId = '9PLM9XGG6VKS'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# The FE3 endpoint currently serves an incomplete chain on GitHub's Linux
# runner. The package is still verified after download by its MSIX signature.
$PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
$PSDefaultParameterValues['Invoke-WebRequest:SkipCertificateCheck'] = $true

# Reuse the public Microsoft Store resolver logic to obtain a time-limited
# Microsoft CDN URL; only the resulting official URL is consumed below.
$archive = Join-Path ([IO.Path]::GetTempPath()) 'z8-get-msstoreinstaller.nupkg'
$extract = Join-Path ([IO.Path]::GetTempPath()) 'z8-get-msstoreinstaller'
Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2/package/Get-MSStoreInstaller/1.0.1' -OutFile $archive
if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
$source = Get-Content -Raw -LiteralPath (Join-Path $extract 'Get-MSStoreInstaller.ps1')
$start = $source.IndexOf('#region Download Functions')
$end = $source.LastIndexOf('#endregion')
if ($start -lt 0 -or $end -le $start) { throw 'Unable to load the Microsoft Store resolver functions.' }
Invoke-Expression $source.Substring($start, $end - $start + 10)

$items = @(Get-StoreURLS -ProductNumber $ProductId -Architecture $Architecture)
$item = $items | Where-Object { $_.FileName -match "OpenAI\.Codex_(?<version>\d+\.\d+\.\d+\.\d+)_${Architecture}_" } | Select-Object -First 1
if ($null -eq $item) { throw "Microsoft Store returned no OpenAI.Codex $Architecture MSIX." }

$candidates = foreach ($candidate in @($item.URLS)) {
    $normalized = ([string]$candidate) -replace '^http://', 'https://'
    try {
        $head = Invoke-WebRequest -Uri $normalized -Method Head
        $length = [long]$head.Headers['Content-Length']
        [pscustomobject]@{ Url = $normalized; Size = $length }
    } catch {
        [pscustomobject]@{ Url = $normalized; Size = 0L }
    }
}
$selected = $candidates | Where-Object { $_.Url -match '\?P1=' } | Select-Object -First 1
if ($null -eq $selected) { $selected = $candidates | Sort-Object Size -Descending | Select-Object -First 1 }
if ($null -eq $selected -or [string]::IsNullOrWhiteSpace($selected.Url)) { throw 'Microsoft Store returned no downloadable MSIX URL.' }

[pscustomobject]@{
    fileName = [string]$item.FileName
    version = [regex]::Match([string]$item.FileName, 'OpenAI\.Codex_(?<version>\d+\.\d+\.\d+\.\d+)_').Groups['version'].Value
    size = [long]$selected.Size
    url = [string]$selected.Url
} | ConvertTo-Json -Compress
