##############################################################################
# TASKCLUSTER_REF can be a git commit SHA, a git branch name, or a git tag name
# (i.e. for a taskcluster version number, prefix with 'v' to make it a git tag)
$TASKCLUSTER_REF = "main"
$TASKCLUSTER_REPO = "https://github.com/taskcluster/taskcluster"
##############################################################################

# Write-Log function for logging with RFC3339 format timestamps
function Write-Log {
    param (
        [string]$message
    )

    # Get the current time in RFC3339 format with UTC (Z)
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

    # Prefix the message with the timestamp and write to the host
    Write-Host "$timestamp $message"
}

# Function to call an executable, log the command and its output, capture both
# stdout and stderr, and exit powershell script if the called executable fails
# (non-zero exit code).
function Run-Executable {
    param (
        [string]$exePath,        # Path to the executable
        [string[]]$arguments     # Arguments to pass to the executable
    )

    # Even though $arguments is an array, Start-Process -ArgumentList requires
    # an escaped string rather than an array, if any argument contain spaces,
    # since it simply joins the array elements internally with a ' ' between
    # each one. Therefore escape double quotes and quote each argument if it
    # contains spaces or quotes.
    $escapedArguments = $arguments | ForEach-Object {
        $_ = $_ -replace '"', '""'  # Escape literal double quotes by doubling them
        if ($_ -match '\s' -or $_ -match '"') { "`"$_`"" } else { $_ }
    }

    # Log the command being run
    $commandString = "$exePath $($escapedArguments -join ' ')"
    Write-Log "Running command: $commandString"

    # Start-Process parameters to capture both stdout and stderr
    $startProcessParams = @{
        FilePath              = $exePath
        # RedirectStandardOutput and RedirectStandardError are not allowed to
        # be the same file
        RedirectStandardOutput = "stdout.txt"
        RedirectStandardError  = "stderr.txt"
        Wait                  = $true
        NoNewWindow           = $true
        PassThru              = $true
    }

    # ArgumentList is not allowed to be empty
    if ($escapedArguments) {
        $startProcessParams['ArgumentList'] = $escapedArguments
    }

    # Run the executable by splatting the parameters to Start-Process
    $process = Start-Process @startProcessParams

    # Read the stdout and stderr as raw text to preserve line breaks
    $stdout = Get-Content "stdout.txt" -Raw
    $stderr = Get-Content "stderr.txt" -Raw

    # Log the stdout
    Write-Log "Command output (stdout): $stdout"

    # Only log the stderr if there is any content in stderr.txt
    if ($stderr -and $stderr.Trim()) {
        Write-Log "Command error (stderr): $stderr"
    }

    # Check the exit code and exit if non-zero
    if ($process.ExitCode -ne 0) {
        throw "$commandString failed with exit code $($process.ExitCode.ToString())"
    }

    # Bizarrely, if stdout.txt is 0 bytes, $stdout will not be empty string, but null instead.
    if ($stdout -eq $null) {
        return $null
    } else {
        return $stdout.TrimEnd()
    }
}

# Utility function to download a zip file and extract it
function Expand-ZIPFile {
    param (
        [string]$file,        # Path to save the downloaded ZIP file
        [string]$destination, # Directory to extract the ZIP contents
        [string]$url          # URL to download the ZIP file from
    )

    # Download the file using Invoke-WebRequest
    Invoke-WebRequest -Uri $url -OutFile $file

    # Extract the ZIP file using Expand-Archive
    Expand-Archive -Path $file -DestinationPath $destination -Force
}

# Exit the script on any powershell command error
$ErrorActionPreference = 'Stop'

# allow powershell scripts to run
Set-ExecutionPolicy Unrestricted -Force -Scope Process

# use TLS 1.2 (see bug 1443595)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

md "C:\Install Logs"
md "C:\Downloads"

# Redirect the output (stdout and stderr) from the current powershell script to a log file
# There is a Stop-Transcript command later on in this script.
Start-Transcript -Path "C:\Install Logs\bootstrap.txt"

# capture env
Get-ChildItem Env: | Out-File "C:\Install Logs\env.txt"

# Check if the Windows Defender registry key exists
if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender")) {
    # Create the key if it doesn't exist
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft" -Name "Windows Defender" -Force
}

# Issue 681: Disable Windows Defender as it can interfere with tasks,
# degrade their performance, and e.g. prevents Generic Worker unit test
# TestAbortAfterMaxRunTime from running as intended.
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -Value 1
Write-Log "Windows Defender's DisableAntiSpyware registry setting has been set."

# Services to disable
# taken (and edited) from GitHub Actions Windows runners
# https://github.com/actions/runner-images/blob/3b976c7acb0ce875060102c0c80f655b479aa5d4/images/windows/scripts/build/Configure-System.ps1#L140-L153
$servicesToDisable = @(
    'edgeupdate',   # Microsoft Edge Update
    'edgeupdatem',  # Microsoft Edge Update
    'wuauserv',     # Windows Update
    'usosvc',       # Update Orchestrator
    'DiagTrack',    # Telemetry service
    'SysMain',      # Superfetch
    'WSearch'       # Disk indexing
) | Get-Service -ErrorAction SilentlyContinue

foreach ($service in $servicesToDisable) {
    Write-Log "Attempting to stop service: $($service.Name)"

    try {
        if ($service.CanStop) {
            Stop-Service -Name $service.Name -Force -ErrorAction Stop
            $service.WaitForStatus('Stopped', '00:01:00')
            Write-Log "$($service.Name) stopped successfully."
        } else {
            Write-Log "$($service.Name) cannot be stopped."
        }
    } catch {
        Write-Log "Failed to stop $($service.Name): $_"
    }

    # Set the service to Disabled startup type
    try {
        Set-Service -Name $service.Name -StartupType Disabled
        Write-Log "$($service.Name) has been disabled."
    } catch {
        Write-Log "Failed to disable $($service.Name): $_"
    }
}

# skip OOBE (out of box experience)
@(
    "HideEULAPage",
    "HideLocalAccountScreen",
    "HideOEMRegistrationScreen",
    "HideOnlineAccountScreens",
    "HideWirelessSetupInOOBE",
    "NetworkLocation",
    "OEMAppId",
    "ProtectYourPC",
    "SkipMachineOOBE",
    "SkipUserOOBE"
) | ForEach-Object {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" -Name $psitem -Value 1
}

# Disable scheduled tasks
# taken from GitHub Actions Windows runners
# https://github.com/actions/runner-images/blob/fbc3fb1d0f7629374c71bbbf553480dd7b6b95a5/images/windows/scripts/build/Configure-System.ps1#L106-L135
@(
    "\"
    "\Microsoft\Azure\Security\"
    "\Microsoft\VisualStudio\"
    "\Microsoft\VisualStudio\Updates\"
    "\Microsoft\Windows\Application Experience\"
    "\Microsoft\Windows\ApplicationData\"
    "\Microsoft\Windows\Autochk\"
    "\Microsoft\Windows\Chkdsk\"
    "\Microsoft\Windows\Customer Experience Improvement Program\"
    "\Microsoft\Windows\Data Integrity Scan\"
    "\Microsoft\Windows\Defrag\"
    "\Microsoft\Windows\Diagnosis\"
    "\Microsoft\Windows\DiskCleanup\"
    "\Microsoft\Windows\DiskDiagnostic\"
    "\Microsoft\Windows\Maintenance\"
    "\Microsoft\Windows\PI\"
    "\Microsoft\Windows\Power Efficiency Diagnostics\"
    "\Microsoft\Windows\Server Manager\"
    "\Microsoft\Windows\Speech\"
    "\Microsoft\Windows\UpdateOrchestrator\"
    "\Microsoft\Windows\Windows Error Reporting\"
    "\Microsoft\Windows\WindowsUpdate\"
    "\Microsoft\XblGameSave\"
) | ForEach-Object {
    Get-ScheduledTask -TaskPath $_ -ErrorAction Ignore | Disable-ScheduledTask -ErrorAction Ignore
} | Out-Null

# install chocolatey package manager
Invoke-RestMethod -Uri 'https://community.chocolatey.org/install.ps1' | Invoke-Expression

# install nssm
Expand-ZIPFile -File "C:\Downloads\nssm-2.24.zip" -Destination "C:\" -Url "https://www.nssm.cc/release/nssm-2.24.zip"

# Add taskcluster entry to the hosts file, for (old) tasks not using $TASKCLUSTER_PROXY_URL
$hostsFileLines = @(
    "",
    "# Useful for generic-worker taskcluster-proxy integration",
    "# See https://bugzilla.mozilla.org/show_bug.cgi?id=1449981#c6",
    "127.0.0.1        taskcluster"
)

# Append the lines to the hosts file
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value $hostsFileLines

# open up firewall for livelog (both PUT and GET interfaces)
New-NetFirewallRule -DisplayName "Allow livelog PUT requests" -Direction Inbound -LocalPort 60022 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "Allow livelog GET requests" -Direction Inbound -LocalPort 60023 -Protocol TCP -Action Allow

# install go
Run-Executable "choco" @("install", "-y", "golang", "--version", "1.23.6")

# install git
Run-Executable "choco" @("install", "-y", "git")

# install node
Run-Executable "choco" @("install", "-y", "nodejs", "--version", "22.13.1")

# install python
Run-Executable "choco" @("install", "-y", "python", "--version", "3.13.1")

# refresh environment variables
Import-Module $env:ChocolateyInstall\helpers\chocolateyProfile.psm1
refreshenv

md "C:\generic-worker"
md "C:\worker-runner"

# build generic-worker/livelog/start-worker/taskcluster-proxy from ${TASKCLUSTER_REF} commit / branch / tag etc
Run-Executable "git" @("clone", $TASKCLUSTER_REPO)
Set-Location taskcluster
Run-Executable "git" @("checkout", $TASKCLUSTER_REF)
$revision = Run-Executable git @("rev-parse", "HEAD")
$env:CGO_ENABLED = "0"
Run-Executable "go" @("build", "-tags", "multiuser", "-o", "C:\generic-worker\generic-worker.exe", "-ldflags", "-X main.revision=$revision", ".\workers\generic-worker")
Run-Executable "go" @("build", "-o", "C:\generic-worker\livelog.exe", ".\tools\livelog")
Run-Executable "go" @("build", "-o", "C:\generic-worker\taskcluster-proxy.exe", "-ldflags", "-X main.revision=$revision", ".\tools\taskcluster-proxy")
Run-Executable "go" @("build", "-o", "C:\worker-runner\start-worker.exe", "-ldflags", "-X main.revision=$revision", ".\tools\worker-runner\cmd\start-worker")
Run-Executable "C:\generic-worker\generic-worker.exe" @("--version")
Run-Executable "C:\generic-worker\generic-worker.exe" @("new-ed25519-keypair", "--file", "C:\generic-worker\generic-worker-ed25519-signing-key.key")

# install generic-worker, using the steps suggested in https://docs.taskcluster.net/docs/reference/workers/worker-runner/deployment#recommended-setup
$nssm = "C:\nssm-2.24\win64\nssm.exe"
Run-Executable $nssm @("install", "Generic Worker", "C:\generic-worker\generic-worker.exe")
Run-Executable $nssm @("set", "Generic Worker", "AppDirectory", "C:\generic-worker")
Run-Executable $nssm @("set", "Generic Worker", "AppParameters", "run", "--config", "C:\generic-worker\generic-worker-config.yml", "--worker-runner-protocol-pipe", "\\.\pipe\generic-worker")
Run-Executable $nssm @("set", "Generic Worker", "DisplayName", "Generic Worker")
Run-Executable $nssm @("set", "Generic Worker", "Description", "A taskcluster worker that runs on all mainstream platforms")
Run-Executable $nssm @("set", "Generic Worker", "Start", "SERVICE_DEMAND_START")
Run-Executable $nssm @("set", "Generic Worker", "Type", "SERVICE_WIN32_OWN_PROCESS")
Run-Executable $nssm @("set", "Generic Worker", "AppNoConsole", "1")
Run-Executable $nssm @("set", "Generic Worker", "AppAffinity", "All")
Run-Executable $nssm @("set", "Generic Worker", "AppStopMethodSkip", "0")
Run-Executable $nssm @("set", "Generic Worker", "AppExit", "Default", "Exit")
Run-Executable $nssm @("set", "Generic Worker", "AppRestartDelay", "0")
Run-Executable $nssm @("set", "Generic Worker", "AppStdout", "C:\generic-worker\generic-worker-service.log")
Run-Executable $nssm @("set", "Generic Worker", "AppStderr", "C:\generic-worker\generic-worker-service.log")
Run-Executable $nssm @("set", "Generic Worker", "AppRotateFiles", "0")

# install worker-runner
Run-Executable $nssm @("install", "worker-runner", "C:\worker-runner\start-worker.exe")
Run-Executable $nssm @("set", "worker-runner", "AppDirectory", "C:\worker-runner")
Run-Executable $nssm @("set", "worker-runner", "AppParameters", "C:\worker-runner\runner.yml")
Run-Executable $nssm @("set", "worker-runner", "DisplayName", "Worker Runner")
Run-Executable $nssm @("set", "worker-runner", "Description", "Interface between workers and Taskcluster services")
Run-Executable $nssm @("set", "worker-runner", "Start", "SERVICE_AUTO_START")
Run-Executable $nssm @("set", "worker-runner", "Type", "SERVICE_WIN32_OWN_PROCESS")
Run-Executable $nssm @("set", "worker-runner", "AppNoConsole", "1")
Run-Executable $nssm @("set", "worker-runner", "AppAffinity", "All")
Run-Executable $nssm @("set", "worker-runner", "AppStopMethodSkip", "0")
Run-Executable $nssm @("set", "worker-runner", "AppExit", "Default", "Exit")
Run-Executable $nssm @("set", "worker-runner", "AppRestartDelay", "0")
Run-Executable $nssm @("set", "worker-runner", "AppStdout", "C:\worker-runner\worker-runner-service.log")
Run-Executable $nssm @("set", "worker-runner", "AppStderr", "C:\worker-runner\worker-runner-service.log")
Run-Executable $nssm @("set", "worker-runner", "AppRotateFiles", "1")
Run-Executable $nssm @("set", "worker-runner", "AppRotateOnline", "1")
Run-Executable $nssm @("set", "worker-runner", "AppRotateSeconds", "3600")
Run-Executable $nssm @("set", "worker-runner", "AppRotateBytes", "0")

# configure worker-runner
Set-Content -Path C:\worker-runner\runner.yml @"
provider:
    providerType: %MY_CLOUD%
worker:
    implementation: generic-worker
    service: "Generic Worker"
    configPath: C:\generic-worker\generic-worker-config.yml
    protocolPipe: \\.\pipe\generic-worker
cacheOverRestarts: C:\generic-worker\start-worker-cache.json
"@

# workaround for https://www.cygwin.com/ml/cygwin/2015-10/msg00036.html
# see:
#   1) https://www.cygwin.com/ml/cygwin/2015-10/msg00038.html
#   2) https://cygwin.com/git/gitweb.cgi?p=cygwin-csih.git;a=blob;f=cygwin-service-installation-helper.sh;h=10ab4fb6d47803c9ffabdde51923fc2c3f0496bb;hb=7ca191bebb52ae414bb2a2e37ef22d94f2658dc7#l2884
$env:LOGONSERVER = "\\" + $env:COMPUTERNAME

# Log before stopping transcript to make sure message is included in transcript.
Write-Log "Bootstrap process completed. Shutting down..."

# Shut down, in preparation for creating an image. Stop-Computer isn't working,
# also not when specifying -AsJob, so reverting to using `shutdown` command
# instead. See:
#   * https://www.reddit.com/r/PowerShell/comments/65250s/windows_10_creators_update_stopcomputer_not/dgfofug/?st=j1o3oa29&sh=e0c29c6d
#   * https://support.microsoft.com/en-in/help/4014551/description-of-the-security-and-quality-rollup-for-the-net-framework-4
#   * https://support.microsoft.com/en-us/help/4020459
Run-Executable "shutdown" @("-s")

# Technically the transcript will be stopped here anyway, since Powershell
# stops the transcript when the script exits, but it is a useful reminder to
# the reader that there is an open transcript which will get closed here. We
# issue the Stop-Transcript after the shutdown command, because if that were to
# fail, we would want to see the output in the transcript.
Stop-Transcript
