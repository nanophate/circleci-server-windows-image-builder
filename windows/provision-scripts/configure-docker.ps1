$registryMirror = "https://mirror.gcr.io"

# Check if Docker service is running
$dockerService = Get-Service -Name Docker -ErrorAction SilentlyContinue
if ($dockerService.Status -ne "Running") {
    Write-Host "Docker service is not running."
    exit
}

# Stop Docker service
Stop-Service -Name Docker

# Set the docker configutation
$daemonConfigPath = "C:\ProgramData\Docker\config\daemon.json"
$daemonConfig = Get-Content -Path $daemonConfigPath | ConvertFrom-Json

# Add or update registry mirror settings
$daemonConfig.registry-mirrors = @($registryMirror)

# Save the modified configuration file
$daemonConfig | ConvertTo-Json | Set-Content -Path $daemonConfigPath

# Start Docker service
Start-Service -Name Docker

Write-Host "Docker Daemon has been configured to use the registry mirror."
