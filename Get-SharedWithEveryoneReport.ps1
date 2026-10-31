#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Finds what everyone in your organization can open in SharePoint and OneDrive: public teams
    and groups, and files and folders shared with everyone or by link. Read-only.

.DESCRIPTION
    Signs in to Microsoft Graph and checks three things:

    - Public teams and Microsoft 365 groups. Everyone in the organization can open and edit the
      files on their SharePoint sites.
    - Files that match words such as salary or passport, found with Microsoft Search the same way
      any employee, or Copilot, could find them. Each match is checked to see whether everyone
      can open it.
    - The document libraries of every SharePoint site your account can open. Every folder is
      checked, and every file that has been shared.

    It reports anything shared with "Everyone except external users" or "Everyone", "People in
    your organization" links and "Anyone" links. It prints a table, saves the results to a CSV
    file, and changes nothing.

    Works in PowerShell 7 on Windows, Linux and macOS.

.PARAMETER SearchTerms
    Words and phrases to search for. Put a phrase in double quotes inside single quotes, for
    example '"bank account"'. The defaults cover pay, identity documents, passwords and HR files.

.PARAMETER SkipLibraryScan
    Check public teams and groups and the search results only. Much faster on a large tenant.

.PARAMETER CheckEveryFile
    In the library scan, check every file, not only folders and files that were shared. Slower.

.PARAMETER UseDeviceCode
    Sign in with a code on another device. Use this on a machine without a browser.

.PARAMETER OutputPath
    Where to save the CSV. Defaults to SharedWithEveryone.csv in the current folder.

.EXAMPLE
    ./Get-SharedWithEveryoneReport.ps1

.EXAMPLE
    ./Get-SharedWithEveryoneReport.ps1 -SearchTerms 'salary', '"bank account"', 'Contoso bid' -SkipLibraryScan

.NOTES
    Needs the Microsoft.Graph.Authentication module and the GroupMember.Read.All and Sites.Read.All
    permissions. An admin has to consent to GroupMember.Read.All the first time.
    Search and the library scan see only what your account can open, and for a file you don't own,
    Microsoft Graph returns only the permissions that apply to you.
#>
[CmdletBinding()]
param(
    [string[]]$SearchTerms = @('salary', 'payroll', '"social security"', 'SSN', 'passport', '"date of birth"',
        'password', '"bank account"', '"routing number"', '"tax return"', '"W-2"', '"I-9"',
        '"performance review"', 'disciplinary', 'termination', 'medical', 'confidential'),
    [switch]$SkipLibraryScan,
    [switch]$CheckEveryFile,
    [switch]$UseDeviceCode,
    [string]$OutputPath = './SharedWithEveryone.csv'
)

$findings = [System.Collections.Generic.List[object]]::new()
$reported = @{}                   # item and type -> row, so nothing is listed twice
$candidates = [ordered]@{}        # drive/item -> a file or folder to check
$publicSites = @{}                # site ID -> the public team or group that owns it
$script:unreadable = 0

$adviceFor = @{
    'Everyone except external users'   = "Everyone in the company can open it. Remove 'Everyone except external users' under Manage access, and share it with the people who need it."
    'Everyone'                         = "Everyone in the company can open it. Remove 'Everyone' under Manage access, and share it with the people who need it."
    'People in your organization link' = 'Anyone in the company who has the link can open it. Delete the link if the file is sensitive, and share it with specific people.'
    'Anyone link'                      = "Anyone with the link can open it without signing in, including people outside the company. Delete the link unless that's what you want."
}

function Add-Finding {
    # One row of the report.
    param([string]$Key, [string]$Type, [string]$Name, [string]$Access, [string]$FoundBy, [string]$Location, [string]$Advice)
    if ($reported.ContainsKey("$Key|$Type")) { return }
    $row = [pscustomobject]@{ Type = $Type; Name = $Name; Access = $Access; FoundBy = $FoundBy; Location = $Location; Advice = $Advice }
    $reported["$Key|$Type"] = $row
    $findings.Add($row)
}

function Protect-CsvCell {
    # Spreadsheets run cells that start with = + - or @ as formulas, and some importers trim
    # leading whitespace first, so look past any leading whitespace. Prefix an apostrophe so a
    # hostile file or group name is shown as text instead of executed.
    param($Value)
    if ($Value -is [string] -and $Value -match '^\s*[=+\-@]') { "'" + $Value } else { $Value }
}

function Get-GraphPaged {
    # Every item in a Graph list, following @odata.nextLink.
    param([string]$Uri)
    while ($Uri) {
        $page = Invoke-MgGraphRequest -Uri $Uri -OutputType PSObject
        $page.value | Where-Object { $null -ne $_ }
        $Uri = $page.'@odata.nextLink'
    }
}

function Get-Candidate {
    # The file or folder with this drive and item ID, added to the list to check if it's new.
    param([string]$DriveId, [string]$ItemId, [string]$Name, [string]$Url, [string]$SiteId)
    $key = "$DriveId/$ItemId"
    if (-not $candidates.Contains($key)) {
        $candidates[$key] = [pscustomobject]@{ Key = $key; DriveId = $DriveId; ItemId = $ItemId; Name = $Name; Url = $Url
            SiteId = $SiteId; Terms = [System.Collections.Generic.List[string]]::new(); Scanned = $false }
    }
    $candidates[$key]
}

function Get-FoundBy {
    # How an item was found: the search words that matched it, the library scan, or both.
    param($Candidate)
    $parts = @()
    if ($Candidate.Terms.Count -gt 0) { $parts += "Search: $($Candidate.Terms -join ', ')" }
    if ($Candidate.Scanned) { $parts += 'Library scan' }
    $parts -join '; '
}

function Get-EveryoneType {
    # Who a permission opens an item to, if it's everyone or anyone with a link. Returns nothing for
    # permissions given to specific people or groups, and for Limited Access, which SharePoint adds
    # on the folders above a shared file and doesn't let anyone open them.
    param($Permission)
    $roles = @($Permission.roles | Where-Object { $_ })
    if ($roles.Count -gt 0 -and -not ($roles | Where-Object { $_ -notmatch 'limited access' })) { return }
    switch ("$($Permission.link.scope)") {
        'organization' { return 'People in your organization link' }
        'anonymous' { return 'Anyone link' }
    }
    foreach ($identity in @($Permission.grantedToV2) + @($Permission.grantedToIdentitiesV2) | Where-Object { $_ }) {
        # The sign-in name is the same in every language; the display name is a fallback.
        $login = "$($identity.siteUser.loginName)"
        $name = "$($identity.siteUser.displayName)"
        if ($login -match 'spo-grid-all-users' -or (-not $login -and $name -eq 'Everyone except external users')) { return 'Everyone except external users' }
        if ($login -eq 'c:0(.s|true' -or (-not $login -and $name -eq 'Everyone')) { return 'Everyone' }
    }
}

function Get-Access {
    param($Permission)
    if (@($Permission.roles) | Where-Object { $_ -in 'write', 'owner', 'sp.full control' }) { 'Edit' } else { 'View' }
}

function Get-FolderName {
    # "/drives/b!x/root:/HR/Private" -> "the folder HR/Private"
    param([string]$Path)
    $relative = [uri]::UnescapeDataString((($Path -split 'root:', 2)[1] + '').Trim('/'))
    if ($relative) { "the folder $relative" } else { 'its library' }
}

function Get-Permission {
    # Reads the sharing permissions of many items, 20 to a request, and returns item key ->
    # permissions. Throttled reads are retried. Items that can't be read are counted and left out.
    param([object[]]$Items)
    $result = @{}
    $tries = @{}
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($item in $Items) { $queue.Enqueue($item) }
    while ($queue.Count -gt 0) {
        $chunk = [System.Collections.Generic.List[object]]::new()
        while ($queue.Count -gt 0 -and $chunk.Count -lt 20) { $chunk.Add($queue.Dequeue()) }
        $requests = for ($i = 0; $i -lt $chunk.Count; $i++) {
            @{ id = "$i"; method = 'GET'; url = "/drives/$($chunk[$i].DriveId)/items/$($chunk[$i].ItemId)/permissions" }
        }
        $body = @{ requests = @($requests) } | ConvertTo-Json -Depth 5
        $response = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/$batch' -Body $body -ContentType 'application/json' -OutputType PSObject
        $wait = 0
        foreach ($answer in @($response.responses)) {
            $item = $chunk[[int]$answer.id]
            if ($answer.status -eq 200) {
                $result[$item.Key] = @($answer.body.value | Where-Object { $null -ne $_ })
            }
            elseif ($answer.status -in 429, 503, 504 -and $tries[$item.Key] -lt 5) {
                $tries[$item.Key]++
                $queue.Enqueue($item)
                $after = 5
                [void][int]::TryParse("$($answer.headers.'Retry-After')", [ref]$after)
                $wait = [Math]::Max($wait, $after)
            }
            else {
                $script:unreadable++
            }
        }
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
    }
    $result
}

$connect = @{ Scopes = @('GroupMember.Read.All', 'Sites.Read.All'); NoWelcome = $true; ErrorAction = 'Stop' }
if ($UseDeviceCode) { $connect.UseDeviceCode = $true }
Connect-MgGraph @connect

try {
    # 1. Public teams and Microsoft 365 groups. Their sites give everyone in the organization edit access.
    $publicCount = 0
    try {
        $groups = Get-GraphPaged "v1.0/groups?`$filter=groupTypes/any(c:c eq 'Unified')&`$select=id,displayName,visibility,resourceProvisioningOptions&`$top=999"
        foreach ($group in @($groups | Where-Object visibility -eq 'Public')) {
            $publicCount++
            $kind = if (@($group.resourceProvisioningOptions) -contains 'Team') { 'team' } else { 'group' }
            $owners = @(Get-GraphPaged "v1.0/groups/$($group.id)/owners?`$select=id")
            $url = ''
            try {
                $site = Invoke-MgGraphRequest -Uri "v1.0/groups/$($group.id)/sites/root?`$select=id,webUrl" -OutputType PSObject
                $publicSites["$($site.id)"] = [pscustomobject]@{ Name = $group.displayName; Kind = $kind }
                $url = $site.webUrl
            }
            catch {
                # The group's SharePoint site hasn't been created yet, so there are no files to expose.
                $url = ''
            }
            $advice = "Everyone in the company can open and edit its files. Make it private unless they all need it."
            if ($owners.Count -eq 0) { $advice += ' It has no owner, so nobody is looking after it.' }
            Add-Finding -Key "group:$($group.id)" -Type "Public $kind" -Name $group.displayName -Access 'Edit' `
                -FoundBy 'Teams and groups' -Location $url -Advice $advice
        }
    }
    catch {
        Write-Warning "Couldn't list the teams and groups: $($_.Exception.Message)"
    }

    # 2. Search, the way any employee or Copilot could find files. Search pages stop at 1000 results.
    foreach ($term in $SearchTerms) {
        $label = $term.Trim('"')
        $from = 0
        try {
            do {
                $body = @{ requests = @(@{ entityTypes = @('driveItem'); query = @{ queryString = $term }; from = $from; size = 200 }) } |
                    ConvertTo-Json -Depth 6
                $response = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/search/query' -Body $body -ContentType 'application/json' -OutputType PSObject
                $container = @(@($response.value)[0].hitsContainers)[0]
                foreach ($hit in @($container.hits | Where-Object { $_ })) {
                    $resource = $hit.resource
                    $driveId = "$($resource.parentReference.driveId)"
                    if (-not $driveId) { $script:unreadable++; continue }
                    $itemId = if ($resource.id) { "$($resource.id)" } else { "$($hit.hitId)" }
                    $candidate = Get-Candidate -DriveId $driveId -ItemId $itemId -Name $resource.name -Url $resource.webUrl -SiteId $resource.parentReference.siteId
                    if (-not $candidate.Terms.Contains($label)) { $candidate.Terms.Add($label) }
                }
                $from += 200
            } while ($container.moreResultsAvailable -and $from -lt 1000)
            if ($container.moreResultsAvailable) {
                Write-Warning "More than 1000 files match '$label'. Only the first 1000 were checked; try a more specific word."
            }
        }
        catch {
            Write-Warning "Couldn't search for '$label': $($_.Exception.Message)"
        }
    }
    $searchMatches = @($candidates.Values | Where-Object { $_.Terms.Count -gt 0 }).Count

    # 3. The document libraries of every site this account can open: every folder, and every file
    #    that was shared (or every file, with -CheckEveryFile).
    $scanned = 0
    $notShared = 0
    if (-not $SkipLibraryScan) {
        $sites = @()
        try { $sites = @(Get-GraphPaged "v1.0/sites?search=*&`$select=id,displayName,webUrl") }
        catch { Write-Warning "Couldn't list the SharePoint sites: $($_.Exception.Message)" }
        foreach ($site in $sites) {
            try {
                $drives = @(Get-GraphPaged "v1.0/sites/$($site.id)/drives?`$select=id,name,driveType,webUrl" | Where-Object driveType -eq 'documentLibrary')
                foreach ($drive in $drives) {
                    foreach ($item in Get-GraphPaged "v1.0/drives/$($drive.id)/root/delta?`$select=id,name,webUrl,root,folder,file,shared,deleted") {
                        if ($item.deleted) { continue }
                        $scanned++
                        if (-not ($item.folder -or $item.shared -or $CheckEveryFile)) { $notShared++; continue }
                        $name = if ($item.root) { "$($drive.name) (whole library)" } else { $item.name }
                        $url = if ($item.webUrl) { $item.webUrl } else { $drive.webUrl }
                        (Get-Candidate -DriveId $drive.id -ItemId $item.id -Name $name -Url $url -SiteId $site.id).Scanned = $true
                    }
                }
            }
            catch {
                Write-Warning "Couldn't scan $($site.webUrl): $($_.Exception.Message)"
            }
        }
    }

    # Matches in a public team's site are open to everyone already, so they're listed without
    # reading their permissions. Everything else is checked.
    $toRead = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $candidates.Values) {
        $public = $publicSites["$($candidate.SiteId)"]
        if ($public -and $candidate.Terms.Count -gt 0) {
            Add-Finding -Key $candidate.Key -Type 'In a public team or group' -Name $candidate.Name -Access 'Edit' `
                -FoundBy (Get-FoundBy $candidate) -Location $candidate.Url `
                -Advice "It's in $($public.Name), a public $($public.Kind), so everyone in the company can open and edit it. Move it to a private team or site, or make the $($public.Kind) private."
        }
        else {
            $toRead.Add($candidate)
        }
    }
    $permissions = if ($toRead.Count -gt 0) { Get-Permission -Items $toRead } else { @{} }

    foreach ($candidate in $toRead) {
        if (-not $permissions.ContainsKey($candidate.Key)) { continue }
        $inPublicSite = $publicSites.ContainsKey("$($candidate.SiteId)")
        foreach ($permission in $permissions[$candidate.Key]) {
            $type = Get-EveryoneType $permission
            if (-not $type) { continue }
            # The scan reports the folder a permission comes from, not every file below it.
            if ($permission.inheritedFrom -and $candidate.Terms.Count -eq 0) { continue }
            # Everyone can already open everything on a public team's site; only Anyone links add to that.
            if ($inPublicSite -and $type -ne 'Anyone link') { continue }
            $advice = $adviceFor[$type]
            if ($permission.inheritedFrom) { $advice = "It's shared through $(Get-FolderName $permission.inheritedFrom.path). $advice" }
            Add-Finding -Key $candidate.Key -Type $type -Name $candidate.Name -Access (Get-Access $permission) `
                -FoundBy (Get-FoundBy $candidate) -Location $candidate.Url -Advice $advice
        }
    }
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

$findings | ForEach-Object {
    $row = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) { $row[$property.Name] = Protect-CsvCell $property.Value }
    [pscustomobject]$row
} | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
$checked = "Checked $publicCount public team(s) and group(s) and $searchMatches file(s) that matched the search words"
if (-not $SkipLibraryScan) { $checked += ", and scanned $scanned item(s) in document libraries" }
Write-Host "$checked."
if ($script:unreadable -gt 0) {
    Write-Warning "$($script:unreadable) item(s) couldn't be read. Your account may not have access to them."
}
if ($notShared -gt 0) {
    Write-Host "$notShared file(s) that were never shared weren't checked. Add -CheckEveryFile to check them too. It's slower."
}

if ($findings.Count -gt 0) {
    $findings | Format-Table Type, Name, Access, FoundBy -Wrap | Out-String -Width 200 | Write-Host
    Write-Host "$($findings.Count) finding(s). The full list, with links and advice, is saved in $OutputPath"
}
else {
    Write-Host 'Nothing found that everyone in the company can open, within what this account can see.'
}
