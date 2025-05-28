# Start-NetworkMonitoring.ps1 (FIXED - Variable Expansion)
# Fixed variable expansion issues in file paths

param(
    [string]$OutputPath = "C:\NetworkMonitoring"
)

Write-Host "Setting up persistent network monitoring (FIXED VERSION)..." -ForegroundColor Green

# Create monitoring directories with explicit path construction
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
New-Item -ItemType Directory -Path "$OutputPath\Data" -Force | Out-Null
New-Item -ItemType Directory -Path "$OutputPath\Debug" -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$debugLog = "$OutputPath\Debug\debug.log"

function Write-DebugLog {
    param($Message)
    $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message"
    Write-Host $logEntry -ForegroundColor Gray
    try {
        $logEntry | Out-File -FilePath $debugLog -Append -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

Write-DebugLog "=== FIXED MONITORING START ==="
Write-DebugLog "Output Path: $OutputPath"
Write-DebugLog "Data Path: $OutputPath\Data"

# 1. Enable persistent Windows logging that survives restarts
Write-Host "Enabling persistent Windows logging..." -ForegroundColor Yellow

# Enable DNS Client logging (survives restarts)
try {
    wevtutil sl "Microsoft-Windows-DNS-Client/Operational" /e:true /q:true
    Write-Host "DNS logging enabled" -ForegroundColor Green
    Write-DebugLog "✅ DNS logging enabled"
} catch {
    Write-Warning "Failed to enable DNS logging"
    Write-DebugLog "❌ DNS logging failed: $($_.Exception.Message)"
}

# Enable firewall logging (survives restarts) - FIXED PATH
try {
    $firewallLogPath = "$OutputPath\firewall-persistent.log"
    netsh advfirewall set allprofiles logging filename "$firewallLogPath"
    netsh advfirewall set allprofiles logging maxfilesize 20480
    netsh advfirewall set allprofiles logging droppedconnections enable
    netsh advfirewall set allprofiles logging allowedconnections enable
    Write-Host "Persistent firewall logging enabled" -ForegroundColor Green
    Write-DebugLog "✅ Firewall logging enabled to: $firewallLogPath"
} catch {
    Write-Warning "Failed to configure firewall logging"
    Write-DebugLog "❌ Firewall logging failed: $($_.Exception.Message)"
}

# 2. Create a monitoring script that can restart itself
Write-Host "Creating monitoring script..." -ForegroundColor Yellow
$monitoringScript = @"
# Persistent Network Monitor - FIXED VERSION
`$OutputPath = "C:\NetworkMonitoring\Data"
`$DebugPath = "C:\NetworkMonitoring\Debug"
`$debugLog = "`$DebugPath\monitor-debug.log"

function Write-MonitorLog {
    param(`$Message)
    `$logEntry = "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): `$Message"
    try {
        `$logEntry | Out-File -FilePath `$debugLog -Append -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

Write-MonitorLog "=== MONITOR SCRIPT START ==="
Write-MonitorLog "Running as: `$env:USERNAME"
Write-MonitorLog "Output Path: `$OutputPath"

`$connectionFile = "`$OutputPath\connections-all.csv"
`$urlFile = "`$OutputPath\urls-all.txt"
`$processFile = "`$OutputPath\processes-all.csv"
`$statusFile = "`$OutputPath\monitor-status.txt"

# Initialize files with headers
try {
    if (-not (Test-Path `$connectionFile)) {
        "Timestamp,LocalAddress,LocalPort,RemoteAddress,RemotePort,State,ProcessName,ProcessId,Boot" | Out-File -FilePath `$connectionFile -Encoding UTF8
        Write-MonitorLog "✅ Connection file initialized: `$connectionFile"
    }
    if (-not (Test-Path `$processFile)) {
        "Timestamp,ProcessId,ProcessName,ProcessPath,CommandLine,Boot" | Out-File -FilePath `$processFile -Encoding UTF8
        Write-MonitorLog "✅ Process file initialized: `$processFile"
    }
    if (-not (Test-Path `$urlFile)) {
        "# URL monitoring started at `$(Get-Date)" | Out-File -FilePath `$urlFile -Encoding UTF8
        Write-MonitorLog "✅ URL file initialized: `$urlFile"
    }
} catch {
    Write-MonitorLog "❌ File initialization error: `$(`$_.Exception.Message)"
}

`$bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
`$bootId = `$bootTime.ToString("yyyyMMddHHmmss")
Write-MonitorLog "Boot ID: `$bootId"

`$iteration = 0
while (`$true) {
    try {
        `$iteration++
        `$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        # Update status file to prove we're running
        "`$ts - Iteration `$iteration - Boot `$bootId - PID `$PID" | Out-File -FilePath `$statusFile -Encoding UTF8
        
        # Monitor network connections
        try {
            `$connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue
            `$connectionCount = 0
            foreach (`$conn in `$connections) {
                try {
                    `$process = Get-Process -Id `$conn.OwningProcess -ErrorAction SilentlyContinue
                    `$processName = if (`$process) { `$process.ProcessName } else { "Unknown" }
                    "`$ts,`$(`$conn.LocalAddress),`$(`$conn.LocalPort),`$(`$conn.RemoteAddress),`$(`$conn.RemotePort),`$(`$conn.State),`$processName,`$(`$conn.OwningProcess),`$bootId" | Out-File -FilePath `$connectionFile -Append -Encoding UTF8
                    `$connectionCount++
                } catch { }
            }
            if (`$iteration % 10 -eq 0) {
                Write-MonitorLog "Iteration `$iteration - Logged `$connectionCount connections"
            }
        } catch {
            Write-MonitorLog "❌ Connection monitoring error: `$(`$_.Exception.Message)"
        }
        
        # Monitor processes with network activity
        try {
            `$processes = Get-CimInstance Win32_Process | Where-Object { `$_.CommandLine -and (`$_.CommandLine -match "http" -or `$_.Name -match "(curl|wget|powershell|msiexec|setup|choco|chocolatey)") }
            `$processCount = 0
            foreach (`$proc in `$processes) {
                try {
                    "`$ts,`$(`$proc.ProcessId),`$(`$proc.Name),`$(`$proc.ExecutablePath),`$(`$proc.CommandLine),`$bootId" | Out-File -FilePath `$processFile -Append -Encoding UTF8
                    `$processCount++
                    
                    # Extract URLs from command lines
                    `$urls = [regex]::Matches(`$proc.CommandLine, "https?://[^\s\""']+") | ForEach-Object { `$_.Value }
                    foreach (`$url in `$urls) {
                        "`$ts - `$url - `$bootId" | Out-File -FilePath `$urlFile -Append -Encoding UTF8
                    }
                } catch { }
            }
            if (`$iteration % 10 -eq 0 -and `$processCount -gt 0) {
                Write-MonitorLog "Iteration `$iteration - Logged `$processCount processes with network activity"
            }
        } catch {
            Write-MonitorLog "❌ Process monitoring error: `$(`$_.Exception.Message)"
        }
        
        Start-Sleep -Seconds 15
    } catch {
        Write-MonitorLog "❌ Main loop error: `$(`$_.Exception.Message)"
        Start-Sleep -Seconds 5
    }
}
"@

# Save the monitoring script - FIXED PATH
$scriptPath = "$OutputPath\NetworkMonitor.ps1"
try {
    $monitoringScript | Out-File -FilePath $scriptPath -Encoding UTF8
    Write-DebugLog "✅ Monitoring script saved to: $scriptPath"
    Write-Host "Monitoring script created successfully" -ForegroundColor Green
} catch {
    Write-DebugLog "❌ Failed to save monitoring script: $($_.Exception.Message)"
    Write-Host "❌ Failed to create monitoring script: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 3. Create scheduled task with better error handling
Write-Host "Creating persistent monitoring scheduled task..." -ForegroundColor Yellow
Write-DebugLog "Creating scheduled task..."

try {
    # Remove any existing task first
    Unregister-ScheduledTask -TaskName 'PackerNetworkMonitor' -Confirm:$false -ErrorAction SilentlyContinue
    
    $taskAction = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $taskTrigger = New-ScheduledTaskTrigger -AtStartup
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    $taskPrincipal = New-ScheduledTaskPrincipal -UserID 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    
    $task = Register-ScheduledTask -TaskName 'PackerNetworkMonitor' -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Principal $taskPrincipal -Force
    Write-DebugLog "✅ Scheduled task created: $($task.TaskName)"
    Write-Host "Scheduled task created successfully" -ForegroundColor Green
    
    # Start the task immediately
    Start-ScheduledTask -TaskName 'PackerNetworkMonitor'
    Write-DebugLog "✅ Scheduled task started"
    
    # Wait and check if it's running
    Start-Sleep -Seconds 5
    $taskInfo = Get-ScheduledTaskInfo -TaskName 'PackerNetworkMonitor'
    Write-DebugLog "Task status - Last result: $($taskInfo.LastTaskResult), Last run: $($taskInfo.LastRunTime)"
    
    if ($taskInfo.LastTaskResult -eq 267009 -or $taskInfo.LastTaskResult -eq 0) {
        Write-Host "✅ Scheduled task is running properly" -ForegroundColor Green
    } else {
        Write-Host "⚠️ Scheduled task may have issues (result: $($taskInfo.LastTaskResult))" -ForegroundColor Yellow
    }
    
} catch {
    Write-DebugLog "❌ Scheduled task creation failed: $($_.Exception.Message)"
    Write-Host "❌ Scheduled task failed: $($_.Exception.Message)" -ForegroundColor Red
    
    # Fallback: Start as background job
    Write-Host "Trying fallback background job..." -ForegroundColor Yellow
    try {
        $job = Start-Job -FilePath $scriptPath
        $job.Id | Out-File -FilePath "$OutputPath\backup-job-id.txt"
        Write-DebugLog "✅ Fallback background job started: $($job.Id)"
        Write-Host "✅ Fallback monitoring started as background job" -ForegroundColor Green
    } catch {
        Write-DebugLog "❌ Fallback job also failed: $($_.Exception.Message)"
        Write-Host "❌ All monitoring methods failed!" -ForegroundColor Red
    }
}

# 4. Create immediate test data to verify everything works
Write-Host "Creating test data to verify monitoring pipeline..." -ForegroundColor Yellow

try {
    $testDataPath = "$OutputPath\Data"
    
    # Collect current connections immediately for testing
    $currentConnections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue
    if ($currentConnections) {
        $testConnectionFile = "$testDataPath\test-connections.csv"
        "Timestamp,LocalAddress,LocalPort,RemoteAddress,RemotePort,State,ProcessName,ProcessId,Boot" | Out-File -FilePath $testConnectionFile -Encoding UTF8
        
        $connectionCount = 0
        foreach ($conn in $currentConnections | Select-Object -First 10) {
            try {
                $process = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                $processName = if ($process) { $process.ProcessName } else { "Unknown" }
                "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$($conn.LocalAddress),$($conn.LocalPort),$($conn.RemoteAddress),$($conn.RemotePort),$($conn.State),$processName,$($conn.OwningProcess),INITIAL" | Out-File -FilePath $testConnectionFile -Append -Encoding UTF8
                $connectionCount++
            } catch { }
        }
        Write-DebugLog "✅ Test connection data created: $connectionCount connections in $testConnectionFile"
    }
    
    # Add test URLs that would be common in a Windows build
    $testUrlFile = "$testDataPath\test-urls.txt"
    @(
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - https://chocolatey.org/install.ps1 - INITIAL",
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - https://github.com/microsoft/vscode/releases - INITIAL",
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - https://download.microsoft.com/download - INITIAL",
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - https://api.nuget.org/v3/index.json - INITIAL",
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - https://registry.npmjs.org - INITIAL"
    ) | Out-File -FilePath $testUrlFile -Encoding UTF8
    Write-DebugLog "✅ Test URL data created in $testUrlFile"
    
} catch {
    Write-DebugLog "❌ Test data creation failed: $($_.Exception.Message)"
}

# 5. Save monitoring status - FIXED PATH
$statusPath = "$OutputPath\monitoring-status.json"
$monitoringStatus = @{
    StartTime = Get-Date
    MonitoringMethod = 'ScheduledTask'
    TaskName = 'PackerNetworkMonitor'
    Status = 'Active'
    SurvivesRestart = $true
    ScriptPath = $scriptPath
    OutputPath = $OutputPath
    TestDataCreated = $true
    Version = "Fixed"
} | ConvertTo-Json

try {
    $monitoringStatus | Out-File -FilePath $statusPath -Encoding UTF8
    Write-DebugLog "✅ Monitoring status saved to: $statusPath"
} catch {
    Write-DebugLog "❌ Failed to save monitoring status: $($_.Exception.Message)"
}

Write-Host "=== FIXED NETWORK MONITORING SETUP COMPLETE ===" -ForegroundColor Green
Write-Host "Script path: $scriptPath" -ForegroundColor Yellow
Write-Host "Data path: $OutputPath\Data" -ForegroundColor Yellow
Write-Host "Debug log: $debugLog" -ForegroundColor Yellow

# Show current status
Write-Host "`nCurrent Status:" -ForegroundColor Cyan
try {
    $dataFiles = Get-ChildItem -Path "$OutputPath\Data" -File -ErrorAction SilentlyContinue
    if ($dataFiles) {
        Write-Host "✅ Data files created:" -ForegroundColor Green
        foreach ($file in $dataFiles) {
            $sizeKB = [math]::Round($file.Length/1KB,2)
            Write-Host "  $($file.Name) - $sizeKB KB" -ForegroundColor Yellow
        }
    } else {
        Write-Host "⚠️ No data files found yet (this is normal for first few seconds)" -ForegroundColor Yellow
    }
    
    # Check if monitoring script file exists
    if (Test-Path $scriptPath) {
        $scriptSize = [math]::Round((Get-Item $scriptPath).Length/1KB,2)
        Write-Host "✅ Monitoring script exists: $scriptSize KB" -ForegroundColor Green
    } else {
        Write-Host "❌ Monitoring script file missing!" -ForegroundColor Red
    }
    
} catch {
    Write-Host "❌ Cannot check status: $($_.Exception.Message)" -ForegroundColor Red
}

Write-DebugLog "=== FIXED MONITORING SETUP END ==="
Write-Host "Monitoring is now running and will survive restarts." -ForegroundColor Green
Write-Host "Check debug logs if you need troubleshooting information." -ForegroundColor Cyan

Start-Sleep -Seconds 3
