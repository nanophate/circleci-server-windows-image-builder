# Verify-NetworkMonitoring.ps1
# Verify network monitoring is still running after restart

param(
    [string]$OutputPath = "C:\NetworkMonitoring"
)

Write-Host "Verifying network monitoring after restart..." -ForegroundColor Cyan

# Check if scheduled task is running
$task = Get-ScheduledTask -TaskName 'PackerNetworkMonitor' -ErrorAction SilentlyContinue
if ($task) {
    $taskInfo = Get-ScheduledTaskInfo -TaskName 'PackerNetworkMonitor'
    Write-Host "Monitoring task status: $($taskInfo.LastTaskResult)" -ForegroundColor Yellow
    
    # Task result codes:
    # 0 = Success
    # 267009 = Task is currently running
    if ($taskInfo.LastTaskResult -ne 0 -and $taskInfo.LastTaskResult -ne 267009) {
        Write-Host "Restarting monitoring task..." -ForegroundColor Yellow
        Start-ScheduledTask -TaskName 'PackerNetworkMonitor'
        Start-Sleep -Seconds 5
        
        # Check again
        $taskInfo = Get-ScheduledTaskInfo -TaskName 'PackerNetworkMonitor'
        if ($taskInfo.LastTaskResult -eq 267009) {
            Write-Host "Monitoring task restarted successfully" -ForegroundColor Green
        } else {
            Write-Warning "Monitoring task may not be running properly"
        }
    } else {
        Write-Host "Monitoring task is running correctly" -ForegroundColor Green
    }
} else {
    Write-Warning "Monitoring task not found, recreating..."
    
    # Recreate the task if it's missing
    $taskAction = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File C:\NetworkMonitoring\NetworkMonitor.ps1'
    $taskTrigger = New-ScheduledTaskTrigger -AtStartup
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $taskPrincipal = New-ScheduledTaskPrincipal -UserID 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    
    try {
        Register-ScheduledTask -TaskName 'PackerNetworkMonitor' -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Principal $taskPrincipal -Force
        Start-ScheduledTask -TaskName 'PackerNetworkMonitor'
        Write-Host "Monitoring task recreated and started" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to recreate monitoring task: $($_.Exception.Message)"
    }
}

# Show monitoring status and data files
Write-Host "`nChecking monitoring data..." -ForegroundColor Cyan
$dataPath = "$OutputPath\Data"
if (Test-Path $dataPath) {
    $dataFiles = Get-ChildItem -Path $dataPath -File -ErrorAction SilentlyContinue
    if ($dataFiles) {
        Write-Host "Monitoring data files:" -ForegroundColor Green
        foreach ($file in $dataFiles) {
            $sizeKB = [math]::Round($file.Length / 1KB, 1)
            $lastWrite = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            Write-Host "  $($file.Name) - $sizeKB KB (last updated: $lastWrite)" -ForegroundColor Yellow
        }
        
        # Check if data is recent (within last 2 minutes)
        $recentFiles = $dataFiles | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) }
        if ($recentFiles) {
            Write-Host "✅ Data is being actively collected" -ForegroundColor Green
        } else {
            Write-Warning "⚠️  Data may not be actively updating"
        }
    } else {
        Write-Warning "No monitoring data found - monitoring may not be working"
    }
} else {
    Write-Warning "Monitoring data directory not found"
}

# Show current boot session info
try {
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $bootId = $bootTime.ToString("yyyyMMddHHmmss")
    $uptime = (Get-Date) - $bootTime
    Write-Host "`nCurrent boot session: $bootId" -ForegroundColor Cyan
    Write-Host "System uptime: $($uptime.Days) days, $($uptime.Hours) hours, $($uptime.Minutes) minutes" -ForegroundColor Yellow
} catch {
    Write-Warning "Could not retrieve boot information"
}

Write-Host "`nMonitoring verification complete" -ForegroundColor Green
