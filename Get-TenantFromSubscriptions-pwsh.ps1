<#
.SYNOPSIS
    Retrieves tenant information for Azure Subscription IDs (parallel).

.DESCRIPTION
    This script uses the ARM API to determine the tenant ID for 
    Azure subscriptions, and then retrieves tenant details via Microsoft Graph.
    Processes multiple subscriptions simultaneously for speed.

.PARAMETER SubscriptionIds
    Array of Subscription GUIDs to look up.

.PARAMETER IncludeGraphDetails
    If specified, also retrieves displayName and defaultDomainName via Graph.
    Requires being logged in with 'az login' or having a token.

.PARAMETER ThrottleLimit
    Maximum number of parallel requests (default: 10).

.EXAMPLE
    .\Get-TenantFromSubscriptions-pwsh.ps1 -SubscriptionIds "guid1", "guid2", "guid3"

.EXAMPLE
    $subs = Get-Content .\subscriptions.txt
    .\Get-TenantFromSubscriptions-pwsh.ps1 -SubscriptionIds $subs -IncludeGraphDetails -ThrottleLimit 20
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeGraphDetails,

    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 10
)

begin {
    # Check PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Error "This script requires PowerShell 7+ for parallel processing. Use the standard script for older versions."
        exit 1
    }

    $allSubscriptions = [System.Collections.ArrayList]::new()
    
    # Get Graph token upfront (once) if IncludeGraphDetails is specified
    $graphToken = $null
    if ($IncludeGraphDetails) {
        Write-Host "Retrieving Graph token..." -ForegroundColor Yellow
        $graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
        if (-not $graphToken) {
            Write-Warning "No Graph token available. Use 'az login' first. Only tenant IDs will be retrieved."
        }
    }
}

process {
    foreach ($subId in $SubscriptionIds) {
        $subId = $subId.Trim()
        if ([string]::IsNullOrWhiteSpace($subId)) { continue }
        if ([guid]::TryParse($subId, [ref][guid]::Empty)) {
            [void]$allSubscriptions.Add($subId)
        }
        else {
            Write-Warning "Invalid GUID skipped: $subId"
        }
    }
}

end {
    $totalCount = $allSubscriptions.Count
    if ($totalCount -eq 0) {
        Write-Warning "No valid subscription IDs found."
        return
    }
    
    Write-Host "Processing $totalCount subscriptions with ThrottleLimit=$ThrottleLimit..." -ForegroundColor Cyan
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Parallel processing
    $results = $allSubscriptions | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $subId = $_
        $token = $using:graphToken
        $includeGraph = $using:IncludeGraphDetails
        
        # Function to get tenant ID from ARM 401 response
        function Get-TenantIdFromSubscription {
            param([string]$SubscriptionId)
            
            $uri = "https://management.azure.com/subscriptions/$($SubscriptionId)?api-version=2022-12-01"
            
            try {
                $null = Invoke-WebRequest -Uri $uri -Method Get -ErrorAction Stop
                return $null
            }
            catch {
                $response = $_.Exception.Response
                
                if ($null -eq $response) {
                    return @{ Error = "No response: $($_.Exception.Message)" }
                }
                
                $statusCode = [int]$response.StatusCode
                
                if ($statusCode -eq 401) {
                    $wwwAuth = $null
                    if ($response.Headers.WwwAuthenticate) {
                        $wwwAuth = $response.Headers.WwwAuthenticate.ToString()
                    }
                    elseif ($response.Headers) {
                        try { $wwwAuth = $response.Headers.GetValues("WWW-Authenticate") | Select-Object -First 1 } catch { }
                    }
                    
                    if ($wwwAuth -and $wwwAuth -match 'authorization_uri="https://login\.(microsoftonline\.com|windows\.net)/([^"]+)"') {
                        return @{ TenantId = $matches[2] }
                    }
                    return @{ Error = "Could not extract tenant ID" }
                }
                elseif ($statusCode -eq 404) {
                    return @{ Error = "Subscription not found" }
                }
                return @{ Error = "Status $statusCode" }
            }
        }
        
        # Function to retrieve tenant details via Graph
        function Get-TenantDetails {
            param([string]$TenantId, [string]$Token)
            
            if (-not $Token) { return $null }
            
            try {
                $headers = @{
                    "Authorization" = "Bearer $Token"
                    "Content-Type"  = "application/json"
                }
                $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/findTenantInformationByTenantId(tenantId='$TenantId')"
                $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
                
                return @{
                    DisplayName       = $response.displayName
                    DefaultDomainName = $response.defaultDomainName
                }
            }
            catch {
                return $null
            }
        }
        
        # Process subscription
        $armResult = Get-TenantIdFromSubscription -SubscriptionId $subId
        
        $result = [PSCustomObject]@{
            SubscriptionId    = $subId
            TenantId          = $null
            DisplayName       = $null
            DefaultDomainName = $null
            Error             = $null
        }
        
        if ($armResult.TenantId) {
            $result.TenantId = $armResult.TenantId
            
            if ($includeGraph -and $token) {
                $graphDetails = Get-TenantDetails -TenantId $armResult.TenantId -Token $token
                if ($graphDetails) {
                    $result.DisplayName = $graphDetails.DisplayName
                    $result.DefaultDomainName = $graphDetails.DefaultDomainName
                }
            }
        }
        else {
            $result.TenantId = "NOT FOUND"
            $result.Error = $armResult.Error
        }
        
        # Output result
        $result
    }
    
    $stopwatch.Stop()
    $elapsed = $stopwatch.Elapsed
    
    Write-Host "`n=== RESULTS ($totalCount subscriptions in $($elapsed.TotalSeconds.ToString('F1'))s) ===" -ForegroundColor Green
    $results | Select-Object SubscriptionId, TenantId, DisplayName, DefaultDomainName | Format-Table -AutoSize
    
    # Show errors separately if any
    $errors = $results | Where-Object { $_.Error }
    if ($errors) {
        Write-Host "=== ERRORS ===" -ForegroundColor Red
        $errors | Select-Object SubscriptionId, Error | Format-Table -AutoSize
    }
    
    # Export to CSV
    $csvPath = Join-Path $PSScriptRoot "tenant-lookup-results.csv"
    $results | Select-Object SubscriptionId, TenantId, DisplayName, DefaultDomainName | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Results saved to: $csvPath" -ForegroundColor Yellow
    
    return $results
}
