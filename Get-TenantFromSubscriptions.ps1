<#
.SYNOPSIS
    Haalt tenant informatie op voor Azure Subscription IDs.

.DESCRIPTION
    Dit script gebruikt de ARM API om de tenant ID te achterhalen voor 
    Azure subscriptions, en haalt vervolgens tenant details op via Microsoft Graph.

.PARAMETER SubscriptionIds
    Array van Subscription GUIDs om op te zoeken.

.PARAMETER IncludeGraphDetails
    Indien opgegeven, haalt ook displayName en defaultDomainName op via Graph.
    Vereist dat je bent ingelogd met 'az login' of een token hebt.

.EXAMPLE
    .\Get-TenantFromSubscriptions.ps1 -SubscriptionIds "guid1", "guid2", "guid3"

.EXAMPLE
    $subs = Get-Content .\subscriptions.txt
    .\Get-TenantFromSubscriptions.ps1 -SubscriptionIds $subs -IncludeGraphDetails
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeGraphDetails
)

begin {
    $results = [System.Collections.ArrayList]::new()
    
    # Functie om tenant ID te halen uit ARM 401 response
    function Get-TenantIdFromSubscription {
        param([string]$SubscriptionId)
        
        $uri = "https://management.azure.com/subscriptions/$($SubscriptionId)?api-version=2022-12-01"
        
        try {
            # Maak request zonder authenticatie - we verwachten een 401
            $response = Invoke-WebRequest -Uri $uri -Method Get -ErrorAction Stop
            # Als we hier komen is er iets onverwachts (zou niet moeten gebeuren)
            return $null
        }
        catch {
            $response = $_.Exception.Response
            
            if ($null -eq $response) {
                Write-Warning "Geen response ontvangen voor $SubscriptionId : $($_.Exception.Message)"
                return $null
            }
            
            $statusCode = [int]$response.StatusCode
            
            if ($statusCode -eq 401) {
                # Haal WWW-Authenticate header op - compatibel met PS 5.1 en 7+
                $wwwAuth = $null
                
                # Probeer PowerShell 7+ methode
                if ($response.Headers.WwwAuthenticate) {
                    $wwwAuth = $response.Headers.WwwAuthenticate.ToString()
                }
                # Fallback voor PowerShell 5.1
                elseif ($response.Headers) {
                    try {
                        $wwwAuth = $response.Headers.GetValues("WWW-Authenticate") | Select-Object -First 1
                    } catch {
                        # Nog een alternatief voor PS 5.1
                        try {
                            $wwwAuth = $response.Headers["WWW-Authenticate"]
                        } catch { }
                    }
                }
                
                if ($wwwAuth -and $wwwAuth -match 'authorization_uri="https://login\.(microsoftonline\.com|windows\.net)/([^"]+)"') {
                    return $matches[2]
                }
                else {
                    Write-Warning "Kon tenant ID niet extraheren uit header voor $SubscriptionId"
                    return $null
                }
            }
            elseif ($statusCode -eq 404) {
                Write-Warning "Subscription $SubscriptionId niet gevonden"
                return $null
            }
            else {
                Write-Warning "Onverwachte fout voor $SubscriptionId (status $statusCode): $($_.Exception.Message)"
                return $null
            }
        }
        return $null
    }

    # Functie om tenant details op te halen via Graph (vereist authenticatie)
    function Get-TenantDetails {
        param([string]$TenantId)
        
        try {
            # Probeer token te krijgen via Azure CLI
            $token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
            
            if (-not $token) {
                Write-Warning "Geen Graph token beschikbaar. Gebruik 'az login' eerst."
                return $null
            }

            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type"  = "application/json"
            }

            $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/findTenantInformationByTenantId(tenantId='$TenantId')"
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
            
            return @{
                TenantId          = $response.tenantId
                DisplayName       = $response.displayName
                DefaultDomainName = $response.defaultDomainName
            }
        }
        catch {
            Write-Warning "Kon geen Graph details ophalen voor tenant $TenantId : $($_.Exception.Message)"
            return $null
        }
    }
}

process {
    foreach ($subId in $SubscriptionIds) {
        # Valideer GUID formaat
        $subId = $subId.Trim()
        if (-not [guid]::TryParse($subId, [ref][guid]::Empty)) {
            Write-Warning "Ongeldige GUID: $subId"
            continue
        }

        Write-Host "Verwerken: $subId" -ForegroundColor Cyan
        
        $tenantId = Get-TenantIdFromSubscription -SubscriptionId $subId
        
        if ($tenantId) {
            $result = [PSCustomObject]@{
                SubscriptionId    = $subId
                TenantId          = $tenantId
                DisplayName       = $null
                DefaultDomainName = $null
            }

            if ($IncludeGraphDetails) {
                $details = Get-TenantDetails -TenantId $tenantId
                if ($details) {
                    $result.DisplayName = $details.DisplayName
                    $result.DefaultDomainName = $details.DefaultDomainName
                }
            }

            [void]$results.Add($result)
        }
        else {
            [void]$results.Add([PSCustomObject]@{
                SubscriptionId    = $subId
                TenantId          = "NIET GEVONDEN"
                DisplayName       = $null
                DefaultDomainName = $null
            })
        }
    }
}

end {
    Write-Host "`n=== RESULTATEN ===" -ForegroundColor Green
    $results | Format-Table -AutoSize
    
    # Exporteer ook naar CSV
    $csvPath = Join-Path $PSScriptRoot "tenant-lookup-results.csv"
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Resultaten opgeslagen naar: $csvPath" -ForegroundColor Yellow
    
    return $results
}
