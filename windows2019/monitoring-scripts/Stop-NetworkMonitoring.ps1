# Stop-NetworkMonitoring.ps1
# Stop persistent network monitoring and analyze restart-resistant data

param(
    [string]$OutputPath = "C:\NetworkMonitoring"
)

Write-Host "Stopping persistent network monitoring and analyzing results..." -ForegroundColor Green

# 1. Stop the scheduled task
Write-Host "Stopping scheduled monitoring task..." -ForegroundColor Cyan
try {
    Stop-ScheduledTask -TaskName 'PackerNetworkMonitor' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'PackerNetworkMonitor' -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Monitoring task stopped and removed" -ForegroundColor Green
} catch {
    Write-Warning "Failed to stop monitoring task"
}

# 2. Disable persistent logging
Write-Host "Disabling persistent logging..." -ForegroundColor Cyan
try {
    wevtutil sl "Microsoft-Windows-DNS-Client/Operational" /e:false /q:true
    netsh advfirewall set allprofiles logging droppedconnections disable
    netsh advfirewall set allprofiles logging allowedconnections disable
    Write-Host "Persistent logging disabled" -ForegroundColor Green
} catch {
    Write-Warning "Failed to disable some logging"
}

# Wait a moment for final data collection
Write-Host "Waiting for final data collection..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# 3. Begin analysis of persistent monitoring data
Write-Host "Analyzing persistent network monitoring data..." -ForegroundColor Green

$DataPath = "$OutputPath\Data"
$allConnections = @()
$allUrls = @()
$allProcesses = @()
$allDomains = @()

# Process persistent connection data
Write-Host "Processing connection data..." -ForegroundColor Cyan
$connectionFile = "$DataPath\connections-all.csv"
if (Test-Path $connectionFile) {
    try {
        $connections = Import-Csv -Path $connectionFile
        $allConnections = $connections
        Write-Host "Processed $($connections.Count) total connections across all restarts" -ForegroundColor Yellow
        
        # Show connections by boot session
        $bootSessions = $connections | Group-Object Boot
        Write-Host "Data collected across $($bootSessions.Count) boot sessions:" -ForegroundColor Cyan
        foreach ($session in $bootSessions) {
            Write-Host "  Boot $($session.Name): $($session.Count) connections" -ForegroundColor Yellow
        }
    } catch {
        Write-Warning "Failed to process connection data: $($_.Exception.Message)"
    }
} else {
    Write-Warning "No connection data file found"
}

# Process persistent URL data
Write-Host "Processing URL data..." -ForegroundColor Cyan
$urlFile = "$DataPath\urls-all.txt"
if (Test-Path $urlFile) {
    try {
        $urlLines = Get-Content -Path $urlFile
        $urls = $urlLines | ForEach-Object {
            if ($_ -match '^.* - (https?://[^\s]+) - .*$') {
                $matches[1]
            }
        } | Sort-Object -Unique
        $allUrls = $urls
        Write-Host "Processed $($urls.Count) unique URLs" -ForegroundColor Yellow
    } catch {
        Write-Warning "Failed to process URL data: $($_.Exception.Message)"
    }
} else {
    Write-Warning "No URL data file found"
}

# Process DNS logs
Write-Host "Processing DNS query data..." -ForegroundColor Cyan
$dnsEvents = @()
try {
    $events = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-DNS-Client/Operational'} -MaxEvents 10000 -ErrorAction SilentlyContinue
    $dnsQueries = $events | Where-Object { $_.Id -eq 3008 } | ForEach-Object {
        try {
            $xml = [xml]$_.ToXml()
            $queryName = $xml.Event.EventData.Data | Where-Object { $_.Name -eq 'QueryName' } | Select-Object -ExpandProperty '#text'
            if ($queryName) { $queryName }
        } catch { }
    } | Sort-Object -Unique
    Write-Host "Collected $($dnsQueries.Count) unique DNS queries" -ForegroundColor Yellow
    $allDomains += $dnsQueries
} catch {
    Write-Warning "Failed to process DNS events: $($_.Exception.Message)"
}

# Extract domains from URLs
Write-Host "Extracting domains from URLs..." -ForegroundColor Cyan
$domains = $allUrls | ForEach-Object {
    try {
        $uri = [System.Uri]$_
        $uri.Host
    } catch { }
} | Where-Object { $_ }

$allDomains += $domains
$uniqueDomains = $allDomains | Where-Object { $_ -and $_ -match '\.' } | Sort-Object -Unique

# Extract unique destinations
Write-Host "Processing unique destinations..." -ForegroundColor Cyan
$uniqueDestinations = $allConnections | 
    Where-Object { $_.RemoteAddress -and $_.RemoteAddress -ne '0.0.0.0' -and $_.RemoteAddress -ne '127.0.0.1' } |
    Group-Object RemoteAddress, RemotePort |
    ForEach-Object { 
        $group = $_.Group | Select-Object -First 1
        [PSCustomObject]@{
            RemoteAddress = $group.RemoteAddress
            RemotePort = $group.RemotePort
            ProcessName = $group.ProcessName
            Count = $_.Count
            BootSessions = ($_.Group.Boot | Sort-Object -Unique) -join ","
        }
    } | Sort-Object Count -Descending

# Categorize domains
Write-Host "Categorizing domains..." -ForegroundColor Cyan
$microsoftDomains = $uniqueDomains | Where-Object { $_ -match 'microsoft|windowsupdate|office|azure' }
$awsDomains = $uniqueDomains | Where-Object { $_ -match 'amazonaws|aws' }
$circleciDomains = $uniqueDomains | Where-Object { $_ -match 'circleci|circleimg' }
$packageMgrDomains = $uniqueDomains | Where-Object { $_ -match 'chocolatey|nuget|npmjs|pypi|github|githubusercontent' }
$cdnDomains = $uniqueDomains | Where-Object { $_ -match 'cdn|cloudflare|fastly|akamai' }
$otherDomains = $uniqueDomains | Where-Object { $_ -notmatch 'microsoft|windowsupdate|office|azure|amazonaws|aws|circleci|circleimg|chocolatey|nuget|npmjs|pypi|github|githubusercontent|cdn|cloudflare|fastly|akamai' }

# Generate Security Group rules
Write-Host "Generating Security Group rules..." -ForegroundColor Cyan
$securityGroupRules = @()
$portGroups = $uniqueDestinations | Group-Object RemotePort

foreach ($portGroup in $portGroups) {
    $port = $portGroup.Name
    if ($port -in @('80', '443', '53', '22', '3389')) {
        $addresses = $portGroup.Group.RemoteAddress | Sort-Object -Unique
        $rule = @{
            Protocol = if ($port -eq '53') { 'udp' } else { 'tcp' }
            Port = $port
            Destinations = $addresses
            Description = switch ($port) {
                '80' { 'HTTP outbound' }
                '443' { 'HTTPS outbound' }
                '53' { 'DNS queries' }
                '22' { 'SSH outbound' }
                '3389' { 'RDP outbound' }
            }
            Count = ($portGroup.Group | Measure-Object Count -Sum).Sum
        }
        $securityGroupRules += $rule
    }
}

# Create analysis results
Write-Host "Creating analysis results..." -ForegroundColor Cyan
$analysisResults = @{
    Timestamp = Get-Date
    MonitoringMethod = 'PersistentScheduledTask'
    SurvivedRestarts = $true
    Summary = @{
        TotalConnections = $allConnections.Count
        UniqueDestinations = $uniqueDestinations.Count
        UniqueDomains = $uniqueDomains.Count
        TotalUrls = $allUrls.Count
        SecurityGroupRules = $securityGroupRules.Count
        BootSessions = ($allConnections | Group-Object Boot).Count
    }
    UniqueDestinations = $uniqueDestinations
    SecurityGroupRules = $securityGroupRules
    DomainCategories = @{
        Microsoft = $microsoftDomains
        AWS = $awsDomains
        CircleCI = $circleciDomains
        PackageManagers = $packageMgrDomains
        CDN = $cdnDomains
        Other = $otherDomains
    }
}

# Save results
Write-Host "Saving analysis results..." -ForegroundColor Cyan

# Main analysis report
$analysisResults | ConvertTo-Json -Depth 10 | Out-File -FilePath "$OutputPath\network-analysis-report.json" -Encoding UTF8

# Security Group rules in AWS CLI format
$sgRulesAwsCli = $securityGroupRules | ForEach-Object {
    @{
        IpPermissions = @(
            @{
                IpProtocol = $_.Protocol
                FromPort = [int]$_.Port
                ToPort = [int]$_.Port
                IpRanges = $_.Destinations | ForEach-Object { @{ CidrIp = "$_/32"; Description = $_.Description } }
            }
        )
    }
}
$sgRulesAwsCli | ConvertTo-Json -Depth 5 | Out-File -FilePath "$OutputPath\security-group-rules.json" -Encoding UTF8

# Domain lists
$uniqueDomains | Out-File -FilePath "$OutputPath\domain-allowlist.txt" -Encoding UTF8
$microsoftDomains | Out-File -FilePath "$OutputPath\domains-Microsoft.txt" -Encoding UTF8
$awsDomains | Out-File -FilePath "$OutputPath\domains-AWS.txt" -Encoding UTF8
$circleciDomains | Out-File -FilePath "$OutputPath\domains-CircleCI.txt" -Encoding UTF8
$packageMgrDomains | Out-File -FilePath "$OutputPath\domains-PackageManagers.txt" -Encoding UTF8
$cdnDomains | Out-File -FilePath "$OutputPath\domains-CDN.txt" -Encoding UTF8
$otherDomains | Out-File -FilePath "$OutputPath\domains-Other.txt" -Encoding UTF8

# Detailed reports
$uniqueDestinations | Export-Csv -Path "$OutputPath\unique-destinations.csv" -NoTypeInformation

# Create enhanced summary report
$summaryReport = @"
# Persistent Network Traffic Analysis Report
Generated: $(Get-Date)
Monitoring Method: Persistent Scheduled Task (Restart-Resistant)

## Summary Statistics
- Total Network Connections: $($analysisResults.Summary.TotalConnections)
- Unique Destinations: $($analysisResults.Summary.UniqueDestinations)  
- Unique Domains: $($analysisResults.Summary.UniqueDomains)
- URLs Captured: $($analysisResults.Summary.TotalUrls)
- Security Group Rules: $($analysisResults.Summary.SecurityGroupRules)
- Boot Sessions Monitored: $($analysisResults.Summary.BootSessions)

## Domain Categories
- Microsoft/Windows: $($microsoftDomains.Count) domains
- AWS: $($awsDomains.Count) domains
- CircleCI: $($circleciDomains.Count) domains  
- Package Managers: $($packageMgrDomains.Count) domains
- CDN: $($cdnDomains.Count) domains
- Other: $($otherDomains.Count) domains

## Top 10 Most Active Destinations
$($uniqueDestinations | Select-Object -First 10 | ForEach-Object { "- $($_.RemoteAddress):$($_.RemotePort) ($($_.ProcessName)) - $($_.Count) connections across boot sessions: $($_.BootSessions)" } | Out-String)

## Monitoring Notes
- Monitoring survived all Windows restarts during build
- Data collected continuously using Windows scheduled tasks
- DNS queries captured from Windows Event Log
- Firewall logs collected persistently
- Boot sessions tracked: $($analysisResults.Summary.BootSessions)

## Generated Files
- network-analysis-report.json - Complete analysis data
- security-group-rules.json - AWS Security Group rules
- domain-allowlist.txt - Complete domain allowlist
- domains-*.txt - Categorized domain lists
- unique-destinations.csv - All unique network destinations
"@

$summaryReport | Out-File -FilePath "$OutputPath\ANALYSIS-SUMMARY.md" -Encoding UTF8

Write-Host "`n=== PERSISTENT NETWORK ANALYSIS COMPLETE ===" -ForegroundColor Green
Write-Host "Summary Statistics:" -ForegroundColor Cyan
$analysisResults.Summary | Format-List

Write-Host "`nTop 5 Most Connected Destinations:" -ForegroundColor Cyan
$uniqueDestinations | Select-Object -First 5 | Format-Table RemoteAddress, RemotePort, ProcessName, Count, BootSessions -AutoSize

Write-Host "`nDomain Categories:" -ForegroundColor Cyan
Write-Host "Microsoft/Windows: $($microsoftDomains.Count)" -ForegroundColor Yellow
Write-Host "AWS: $($awsDomains.Count)" -ForegroundColor Yellow  
Write-Host "CircleCI: $($circleciDomains.Count)" -ForegroundColor Yellow
Write-Host "Package Managers: $($packageMgrDomains.Count)" -ForegroundColor Yellow
Write-Host "CDN: $($cdnDomains.Count)" -ForegroundColor Yellow
Write-Host "Other: $($otherDomains.Count)" -ForegroundColor Yellow

Write-Host "`nFiles Generated:" -ForegroundColor Cyan
Get-ChildItem -Path $OutputPath -Filter "*.json", "*.txt", "*.csv", "*.md" | 
    Select-Object Name, @{Name="Size(KB)";Expression={[math]::Round($_.Length/1KB,1)}} | 
    Format-Table -AutoSize

Write-Host "`nAnalysis complete! All files ready for download." -ForegroundColor Green
Write-Host "Output path: $OutputPath" -ForegroundColor Yellow
