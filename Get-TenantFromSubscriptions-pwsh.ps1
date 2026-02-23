<#
.SYNOPSIS
    Haalt tenant informatie op voor Azure Subscription IDs (parallel).

.DESCRIPTION
    Dit script gebruikt de ARM API om de tenant ID te achterhalen voor 
    Azure subscriptions, en haalt vervolgens tenant details op via Microsoft Graph.
    Verwerkt meerdere subscriptions tegelijk voor snelheid.

.PARAMETER SubscriptionIds
    Array van Subscription GUIDs om op te zoeken.

.PARAMETER IncludeGraphDetails
    Indien opgegeven, haalt ook displayName en defaultDomainName op via Graph.
    Vereist dat je bent ingelogd met 'az login' of een token hebt.

.PARAMETER ThrottleLimit
    Maximum aantal parallelle requests (default: 10).

.EXAMPLE
    .\Get-TenantFromSubscriptions-Fast.ps1 -SubscriptionIds "guid1", "guid2", "guid3"

.EXAMPLE
    $subs = Get-Content .\subscriptions.txt
    .\Get-TenantFromSubscriptions-Fast.ps1 -SubscriptionIds $subs -IncludeGraphDetails -ThrottleLimit 20
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
    # Controleer PowerShell versie
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Error "Dit script vereist PowerShell 7+ voor parallelle verwerking. Gebruik het standaard script voor oudere versies."
        exit 1
    }

    $allSubscriptions = [System.Collections.ArrayList]::new()
    
    # Haal Graph token op vooraf (1x) als IncludeGraphDetails is opgegeven
    $graphToken = $null
    if ($IncludeGraphDetails) {
        Write-Host "Graph token ophalen..." -ForegroundColor Yellow
        $graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
        if (-not $graphToken) {
            Write-Warning "Geen Graph token beschikbaar. Gebruik 'az login' eerst. Alleen tenant IDs worden opgehaald."
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
            Write-Warning "Ongeldige GUID overgeslagen: $subId"
        }
    }
}

end {
    $totalCount = $allSubscriptions.Count
    if ($totalCount -eq 0) {
        Write-Warning "Geen geldige subscription IDs gevonden."
        return
    }
    
    Write-Host "Verwerken van $totalCount subscriptions met ThrottleLimit=$ThrottleLimit..." -ForegroundColor Cyan
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Parallelle verwerking
    $results = $allSubscriptions | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $subId = $_
        $token = $using:graphToken
        $includeGraph = $using:IncludeGraphDetails
        
        # Functie om tenant ID te halen uit ARM 401 response
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
                    return @{ Error = "Geen response: $($_.Exception.Message)" }
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
                    return @{ Error = "Kon tenant ID niet extraheren" }
                }
                elseif ($statusCode -eq 404) {
                    return @{ Error = "Subscription niet gevonden" }
                }
                return @{ Error = "Status $statusCode" }
            }
        }
        
        # Functie om tenant details op te halen via Graph
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
        
        # Verwerk subscription
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
            $result.TenantId = "NIET GEVONDEN"
            $result.Error = $armResult.Error
        }
        
        # Output result
        $result
    }
    
    $stopwatch.Stop()
    $elapsed = $stopwatch.Elapsed
    
    Write-Host "`n=== RESULTATEN ($totalCount subscriptions in $($elapsed.TotalSeconds.ToString('F1'))s) ===" -ForegroundColor Green
    $results | Select-Object SubscriptionId, TenantId, DisplayName, DefaultDomainName | Format-Table -AutoSize
    
    # Toon errors apart als die er zijn
    $errors = $results | Where-Object { $_.Error }
    if ($errors) {
        Write-Host "=== FOUTEN ===" -ForegroundColor Red
        $errors | Select-Object SubscriptionId, Error | Format-Table -AutoSize
    }
    
    # Exporteer naar CSV
    $csvPath = Join-Path $PSScriptRoot "tenant-lookup-results.csv"
    $results | Select-Object SubscriptionId, TenantId, DisplayName, DefaultDomainName | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Resultaten opgeslagen naar: $csvPath" -ForegroundColor Yellow
    
    return $results
}
