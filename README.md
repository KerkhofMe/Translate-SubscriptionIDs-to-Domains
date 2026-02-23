# Translate SubscriptionIDs to Domains

PowerShell scripts to translate Azure Subscription IDs to their corresponding tenant and domain information.

## Description

These scripts use the Azure ARM API to determine which Microsoft Entra tenant an Azure Subscription belongs to. Optionally, tenant details (displayName, defaultDomainName) can also be retrieved via Microsoft Graph.

## Scripts

### Get-TenantFromSubscriptions.ps1
The standard version, compatible with **PowerShell 5.1 and 7+**.

```powershell
# Single subscriptions
.\Get-TenantFromSubscriptions.ps1 -SubscriptionIds "guid1", "guid2"

# From file with Graph details
$subs = Get-Content .\subscriptions.txt
.\Get-TenantFromSubscriptions.ps1 -SubscriptionIds $subs -IncludeGraphDetails
```

### Get-TenantFromSubscriptions-pwsh.ps1
Fast version with **parallel processing** (requires PowerShell 7+).

```powershell
# With parallel processing (default 10 concurrent)
$subs = Get-Content .\subscriptions.txt
.\Get-TenantFromSubscriptions-pwsh.ps1 -SubscriptionIds $subs -IncludeGraphDetails

# With custom ThrottleLimit
.\Get-TenantFromSubscriptions-pwsh.ps1 -SubscriptionIds $subs -IncludeGraphDetails -ThrottleLimit 20
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-SubscriptionIds` | Array of Subscription GUIDs |
| `-IncludeGraphDetails` | Retrieves displayName and defaultDomainName via Microsoft Graph |
| `-ThrottleLimit` | (pwsh version only) Maximum number of parallel requests (default: 10) |

## Requirements

- PowerShell 5.1+ (standard script) or PowerShell 7+ (parallel version)
- Azure CLI (`az`) for Graph details (optional)
- Logged in via `az login` if you want to use `-IncludeGraphDetails`

## How it works

1. The script makes a request to the Azure ARM API without authentication
2. The API returns a 401 with the tenant ID in the `WWW-Authenticate` header
3. Optionally, tenant info is retrieved via Microsoft Graph

## Output

The script returns an object with:
- `SubscriptionId` - The original subscription GUID
- `TenantId` - The corresponding tenant GUID
- `DisplayName` - Name of the tenant (with `-IncludeGraphDetails`)
- `DefaultDomainName` - Primary domain (with `-IncludeGraphDetails`)

## Example output to CSV

```powershell
$subs = Get-Content .\subscriptions.txt
$result = .\Get-TenantFromSubscriptions-pwsh.ps1 -SubscriptionIds $subs -IncludeGraphDetails
$result | Export-Csv -Path results.csv -NoTypeInformation
```

## License

MIT License
