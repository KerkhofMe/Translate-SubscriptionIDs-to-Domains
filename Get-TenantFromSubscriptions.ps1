<#
.SYNOPSIS
    Retrieves tenant information for Azure Subscription IDs.

.DESCRIPTION
    This script uses the ARM API to determine the tenant ID for 
    Azure subscriptions, and then retrieves tenant details via Microsoft Graph.

.PARAMETER SubscriptionIds
    Array of Subscription GUIDs to look up.

.PARAMETER IncludeGraphDetails
    If specified, also retrieves displayName and defaultDomainName via Graph.
    Requires being logged in with 'az login' or having a token.

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
    
    # Function to get tenant ID from ARM 401 response
    function Get-TenantIdFromSubscription {
        param([string]$SubscriptionId)
        
        $uri = "https://management.azure.com/subscriptions/$($SubscriptionId)?api-version=2022-12-01"
        
        try {
            # Make request without authentication - we expect a 401
            $response = Invoke-WebRequest -Uri $uri -Method Get -ErrorAction Stop
            # If we get here something unexpected happened (should not occur)
            return $null
        }
        catch {
            $response = $_.Exception.Response
            
            if ($null -eq $response) {
                Write-Warning "No response received for $SubscriptionId : $($_.Exception.Message)"
                return $null
            }
            
            $statusCode = [int]$response.StatusCode
            
            if ($statusCode -eq 401) {
                # Get WWW-Authenticate header - compatible with PS 5.1 and 7+
                $wwwAuth = $null
                
                # Try PowerShell 7+ method
                if ($response.Headers.WwwAuthenticate) {
                    $wwwAuth = $response.Headers.WwwAuthenticate.ToString()
                }
                # Fallback for PowerShell 5.1
                elseif ($response.Headers) {
                    try {
                        $wwwAuth = $response.Headers.GetValues("WWW-Authenticate") | Select-Object -First 1
                    } catch {
                        # Another alternative for PS 5.1
                        try {
                            $wwwAuth = $response.Headers["WWW-Authenticate"]
                        } catch { }
                    }
                }
                
                if ($wwwAuth -and $wwwAuth -match 'authorization_uri="https://login\.(microsoftonline\.com|windows\.net)/([^"]+)"') {
                    return $matches[2]
                }
                else {
                    Write-Warning "Could not extract tenant ID from header for $SubscriptionId"
                    return $null
                }
            }
            elseif ($statusCode -eq 404) {
                Write-Warning "Subscription $SubscriptionId not found"
                return $null
            }
            else {
                Write-Warning "Unexpected error for $SubscriptionId (status $statusCode): $($_.Exception.Message)"
                return $null
            }
        }
        return $null
    }

    # Function to retrieve tenant details via Graph (requires authentication)
    function Get-TenantDetails {
        param([string]$TenantId)
        
        try {
            # Try to get token via Azure CLI
            $token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
            
            if (-not $token) {
                Write-Warning "No Graph token available. Use 'az login' first."
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
            Write-Warning "Could not retrieve Graph details for tenant $TenantId : $($_.Exception.Message)"
            return $null
        }
    }
}

process {
    foreach ($subId in $SubscriptionIds) {
        # Validate GUID format
        $subId = $subId.Trim()
        if (-not [guid]::TryParse($subId, [ref][guid]::Empty)) {
            Write-Warning "Invalid GUID: $subId"
            continue
        }

        Write-Host "Processing: $subId" -ForegroundColor Cyan
        
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
                TenantId          = "NOT FOUND"
                DisplayName       = $null
                DefaultDomainName = $null
            })
        }
    }
}

end {
    Write-Host "`n=== RESULTS ===" -ForegroundColor Green
    $results | Format-Table -AutoSize
    
    # Export to CSV
    $csvPath = Join-Path $PSScriptRoot "tenant-lookup-results.csv"
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Results saved to: $csvPath" -ForegroundColor Yellow
    
    return $results
}
