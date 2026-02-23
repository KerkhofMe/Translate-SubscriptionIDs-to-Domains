# Translate SubscriptionIDs to Domains

PowerShell scripts om Azure Subscription ID's te vertalen naar hun bijbehorende tenant en domain informatie.

## Beschrijving

Deze scripts gebruiken de Azure ARM API om te achterhalen bij welke Microsoft Entra tenant een Azure Subscription hoort. Optioneel kunnen ook de tenant details (displayName, defaultDomainName) worden opgehaald via Microsoft Graph.

## Scripts

### Get-TenantFromSubscriptions.ps1
De standaard versie, compatibel met **PowerShell 5.1 en 7+**.

```powershell
# Enkele subscriptions
.\Get-TenantFromSubscriptions.ps1 -SubscriptionIds "guid1", "guid2"

# Vanuit bestand met Graph details
$subs = Get-Content .\subscriptions.txt
.\Get-TenantFromSubscriptions.ps1 -SubscriptionIds $subs -IncludeGraphDetails
```

### Get-TenantFromSubscriptions-pwsh.ps1
Snelle versie met **parallelle verwerking** (vereist PowerShell 7+).

```powershell
# Met parallelle verwerking (standaard 10 tegelijk)
$subs = Get-Content .\subscriptions.txt
.\Get-TenantFromSubscriptions-pwsh.ps1 -SubscriptionIds $subs -IncludeGraphDetails

# Met aangepaste ThrottleLimit
.\Get-TenantFromSubscriptions-pwsh.ps1 -SubscriptionIds $subs -IncludeGraphDetails -ThrottleLimit 20
```

## Parameters

| Parameter | Beschrijving |
|-----------|-------------|
| `-SubscriptionIds` | Array van Subscription GUIDs |
| `-IncludeGraphDetails` | Haalt displayName en defaultDomainName op via Microsoft Graph |
| `-ThrottleLimit` | (alleen pwsh versie) Maximum aantal parallelle requests (default: 10) |

## Vereisten

- PowerShell 5.1+ (standaard script) of PowerShell 7+ (parallelle versie)
- Azure CLI (`az`) voor Graph details (optioneel)
- Ingelogd via `az login` als je `-IncludeGraphDetails` wilt gebruiken

## Hoe het werkt

1. Het script doet een request naar de Azure ARM API zonder authenticatie
2. De API retourneert een 401 met de tenant ID in de `WWW-Authenticate` header
3. Optioneel wordt de tenant info opgehaald via Microsoft Graph

## Output

Het script geeft een object terug met:
- `SubscriptionId` - De oorspronkelijke subscription GUID
- `TenantId` - De bijbehorende tenant GUID
- `DisplayName` - Naam van de tenant (met `-IncludeGraphDetails`)
- `DefaultDomainName` - Primaire domain (met `-IncludeGraphDetails`)

## Voorbeeld output naar CSV

```powershell
$subs = Get-Content .\subscriptions.txt
$result = .\Get-TenantFromSubscriptions-pwsh.ps1 -SubscriptionIds $subs -IncludeGraphDetails
$result | Export-Csv -Path results.csv -NoTypeInformation
```

## Licentie

MIT License
