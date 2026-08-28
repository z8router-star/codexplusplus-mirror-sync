[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',
    [string]$ProductId = '9PLM9XGG6VKS'
)

$ErrorActionPreference = 'Stop'

function Get-DeviceAttributes {
    $version = [Environment]::OSVersion.Version.ToString()
    $osArchitecture = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'AMD64' }
    return "BranchReadinessLevel=CB;CurrentBranch=rs_prerelease;InstallLanguage=en-US;OSUILocale=en-US;InstallationType=Client;FlightingBranchName=external;OSSkuId=48;FlightContent=Branch;App=WU;AppVer=$version;OSArchitecture=$osArchitecture;UpdateManagementGroup=2;IsFlightingEnabled=1;TelemetryLevel=3;OSVersion=$version;DeviceFamily=Windows.Desktop;"
}

function Invoke-StoreSoap {
    param([string]$Uri, [string]$Body)
    Invoke-RestMethod -Method Post -Uri $Uri -Body $Body -Headers @{
        'Content-Type' = 'application/soap+xml; charset=utf-8'
    }
}

$serviceUri = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$securedUri = "$serviceUri/secured"
$productUri = "https://storeedgefd.dsx.mp.microsoft.com/v9.0/products/${ProductId}?market=US&locale=en-us&deviceFamily=Windows.Desktop"
$product = Invoke-RestMethod -Method Get -Uri $productUri
$fulfillment = $product.Payload.Skus[0].FulfillmentData | ConvertFrom-Json
$categoryId = [string]$fulfillment.WuCategoryId
if ([string]::IsNullOrWhiteSpace($categoryId)) {
    throw "Microsoft Store returned no fulfillment category for $ProductId."
}

$now = [DateTime]::UtcNow
$created = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$cookieExpires = $now.AddDays(27).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$syncExpires = $now.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$lastChange = $now.AddYears(-2).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
$currentTime = $now.AddMilliseconds(7).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$device = Get-DeviceAttributes

$cookieRequest = @"
<Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns="http://www.w3.org/2003/05/soap-envelope"><Header><Action d3p1:mustUnderstand="1" xmlns:d3p1="http://www.w3.org/2003/05/soap-envelope" xmlns="http://www.w3.org/2005/08/addressing">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie</Action><MessageID xmlns="http://www.w3.org/2005/08/addressing">urn:uuid:$([guid]::NewGuid())</MessageID><To d3p1:mustUnderstand="1" xmlns:d3p1="http://www.w3.org/2003/05/soap-envelope" xmlns="http://www.w3.org/2005/08/addressing">$serviceUri</To><Security d3p1:mustUnderstand="1" xmlns:d3p1="http://www.w3.org/2003/05/soap-envelope" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><Created>$created</Created><Expires>$cookieExpires</Expires></Timestamp><WindowsUpdateTicketsToken d4p1:id="ClientMSA" xmlns:d4p1="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization"><TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><User /></TicketType></WindowsUpdateTicketsToken></Security></Header><Body><GetCookie xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService"><oldCookie /><lastChange>$lastChange</lastChange><currentTime>$currentTime</currentTime><protocolVersion>1.40</protocolVersion></GetCookie></Body></Envelope>
"@
$cookieResponse = Invoke-StoreSoap -Uri $serviceUri -Body $cookieRequest
$cookieNode = $cookieResponse.GetElementsByTagName('EncryptedData')[0]
if ($null -eq $cookieNode) { throw 'Microsoft update service returned no cookie.' }
$cookie = $cookieNode.FirstChild.Data

$syncRequest = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Header><a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates</a:Action><a:MessageID>urn:uuid:$([guid]::NewGuid())</a:MessageID><a:To s:mustUnderstand="1">$serviceUri</a:To><o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wssecurity-utility-1.0.xsd"><Created>$created</Created><Expires>$syncExpires</Expires></Timestamp><wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization"><TicketType Name="MSA" Version="1.0" Policy="MBI_SSL">Retail</TicketType></wuws:WindowsUpdateTicketsToken></o:Security></s:Header><s:Body><SyncUpdates xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService"><cookie><Expiration>2045-03-11T02:02:48Z</Expiration><EncryptedData>$cookie</EncryptedData></cookie><parameters><ExpressQuery>false</ExpressQuery><InstalledNonLeafUpdateIDs><int>1</int><int>2</int><int>11</int><int>23110993</int></InstalledNonLeafUpdateIDs><OtherCachedUpdateIDs /><SkipSoftwareSync>false</SkipSoftwareSync><NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates><FilterAppCategoryIds><CategoryIdentifier><Id>$categoryId</Id></CategoryIdentifier></FilterAppCategoryIds><TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled><AlsoPerformRegularSync>false</AlsoPerformRegularSync><ComputerSpec /><ExtendedUpdateInfoParameters><XmlUpdateFragmentTypes><XmlUpdateFragmentType>Extended</XmlUpdateFragmentType></XmlUpdateFragmentTypes><Locales><string>en-US</string><string>en</string></Locales></ExtendedUpdateInfoParameters><ClientPreferredLanguages><string>en-US</string></ClientPreferredLanguages><ProductsParameters><SyncCurrentVersionOnly>false</SyncCurrentVersionOnly><DeviceAttributes>$device</DeviceAttributes><CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes><Products /></ProductsParameters></parameters></SyncUpdates></s:Body></s:Envelope>
"@
$syncResponse = Invoke-StoreSoap -Uri $serviceUri -Body $syncRequest
[xml]$syncXml = $syncResponse.InnerXml.ToString().Replace('&lt;', '<').Replace('&gt;', '>')
$updates = @{}
foreach ($fragment in $syncXml.GetElementsByTagName('SecuredFragment')) {
    $id = $fragment.ParentNode.ParentNode.ParentNode.GetElementsByTagName('ID')[0].FirstChild.Value
    $identity = $fragment.ParentNode.ParentNode.FirstChild
    $updates[$id] = [pscustomobject]@{ UpdateId = $identity.UpdateID; Revision = $identity.RevisionNumber }
}

$packages = foreach ($filesNode in $syncXml.GetElementsByTagName('Files')) {
    $file = $filesNode.FirstChild
    if ($null -eq $file) { continue }
    $id = $filesNode.ParentNode.ParentNode.GetElementsByTagName('ID')[0].FirstChild.Value
    if (-not $updates.ContainsKey($id)) { continue }
    $fileName = $file.Attributes['InstallerSpecificIdentifier'].Value + '_' + $file.Attributes['FileName'].Value
    if ($fileName -notmatch "^OpenAI\.Codex_(?<version>\d+\.\d+\.\d+\.\d+)_${Architecture}__.*\.(msix|msixbundle)$") { continue }
    [pscustomobject]@{
        fileName = $fileName
        version = [version]$Matches.version
        digest = $file.Attributes['Digest'].Value
        size = [long]$file.Attributes['Size'].Value
        updateId = $updates[$id].UpdateId
        revision = $updates[$id].Revision
    }
}
$package = $packages | Sort-Object version -Descending | Select-Object -First 1
if ($null -eq $package) { throw "Microsoft Store returned no OpenAI.Codex $Architecture MSIX." }

$fileRequest = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Header><a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2</a:Action><a:MessageID>urn:uuid:$([guid]::NewGuid())</a:MessageID><a:To s:mustUnderstand="1">$securedUri</a:To><o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wssecurity-utility-1.0.xsd"><Created>$created</Created><Expires>$syncExpires</Expires></Timestamp><wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization"><TicketType Name="MSA" Version="1.0" Policy="MBI_SSL">Retail</TicketType></wuws:WindowsUpdateTicketsToken></o:Security></s:Header><s:Body><GetExtendedUpdateInfo2 xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService"><updateIDs><UpdateIdentity><UpdateID>$($package.updateId)</UpdateID><RevisionNumber>$($package.revision)</RevisionNumber></UpdateIdentity></updateIDs><infoTypes><XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType><XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType></infoTypes><deviceAttributes>$device</deviceAttributes></GetExtendedUpdateInfo2></s:Body></s:Envelope>
"@
$fileResponse = Invoke-StoreSoap -Uri $securedUri -Body $fileRequest
$location = $fileResponse.GetElementsByTagName('FileLocation') | Where-Object { $_.FileDigest -eq $package.digest } | Select-Object -First 1
if ($null -eq $location -or [string]::IsNullOrWhiteSpace($location.Url)) {
    throw 'Microsoft update service returned no matching MSIX URL.'
}

[pscustomobject]@{
    fileName = $package.fileName
    version = $package.version.ToString()
    size = $package.size
    url = [string]$location.Url
} | ConvertTo-Json -Compress
