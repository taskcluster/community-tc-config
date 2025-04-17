$TASKCLUSTER_VERSION = "v83.5.6"

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

# download generic-worker, worker-runner, livelog, and taskcluster-proxy
Invoke-WebRequest -Uri "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/generic-worker-multiuser-windows-amd64" -OutFile "C:\generic-worker\generic-worker.exe"
Invoke-WebRequest -Uri "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/start-worker-windows-amd64" -OutFile "C:\worker-runner\start-worker.exe"
Invoke-WebRequest -Uri "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/livelog-windows-amd64" -OutFile "C:\generic-worker\livelog.exe"
Invoke-WebRequest -Uri "https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/taskcluster-proxy-windows-amd64" -OutFile "C:\generic-worker\taskcluster-proxy.exe"
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

# download cygwin (not required, but useful)
Invoke-WebRequest -Uri "https://www.cygwin.com/setup-x86_64.exe" -OutFile "C:\Downloads\cygwin-setup-x86_64.exe"

# install cygwin
# complete package list: https://cygwin.com/packages/package_list.html
Run-Executable "C:\Downloads\cygwin-setup-x86_64.exe" @("--quiet-mode", "--wait", "--root", "C:\cygwin", "--site", "https://cygwin.mirror.constant.com", "--packages", "openssh,vim,curl,tar,wget,zip,unzip,diffutils,bzr")

# open up firewall for ssh daemon
New-NetFirewallRule -DisplayName "Allow SSH inbound" -Direction Inbound -LocalPort 22 -Protocol TCP -Action Allow

# workaround for https://www.cygwin.com/ml/cygwin/2015-10/msg00036.html
# see:
#   1) https://www.cygwin.com/ml/cygwin/2015-10/msg00038.html
#   2) https://cygwin.com/git/gitweb.cgi?p=cygwin-csih.git;a=blob;f=cygwin-service-installation-helper.sh;h=10ab4fb6d47803c9ffabdde51923fc2c3f0496bb;hb=7ca191bebb52ae414bb2a2e37ef22d94f2658dc7#l2884
$env:LOGONSERVER = "\\" + $env:COMPUTERNAME

# configure sshd (not required, but useful)
Run-Executable "C:\cygwin\bin\bash.exe" @("--login", "-c", "ssh-host-config -y -c 'ntsec mintty' -u 'cygwinsshd' -w 'qwe123QWE!@#'")

# start sshd
Run-Executable "net" @("start", "cygsshd")

# download bash setup script
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/petemoore/myscrapbook/master/setup.sh" -OutFile "C:\cygwin\tmp\setup.sh"

# run bash setup script
Run-Executable "C:\cygwin\bin\bash.exe" @("--login", "-c", "chmod a+x /tmp/setup.sh; /tmp/setup.sh")

# install dependencywalker (useful utility for troubleshooting, not required)
md "C:\DependencyWalker"
Expand-ZIPFile -File "C:\Downloads\depends22_x64.zip" -Destination "C:\DependencyWalker" -Url "https://dependencywalker.com/depends22_x64.zip"

# install ProcessExplorer (useful utility for troubleshooting, not required)
md "C:\ProcessExplorer"
Expand-ZIPFile -File "C:\Downloads\ProcessExplorer.zip" -Destination "C:\ProcessExplorer" -Url "https://download.sysinternals.com/files/ProcessExplorer.zip"

# install ProcessMonitor (useful utility for troubleshooting, not required)
md "C:\ProcessMonitor"
Expand-ZIPFile -File "C:\Downloads\ProcessMonitor.zip" -Destination "C:\ProcessMonitor" -Url "https://download.sysinternals.com/files/ProcessMonitor.zip"

# install Windows 10 SDK
Run-Executable "choco" @("install", "-y", "windows-sdk-10.0")

# install VisualStudio 2019 Community
Run-Executable "choco" @("install", "-y", "visualstudio2019community", "--version", "16.5.4.0", "--package-parameters", "--add Microsoft.VisualStudio.Workload.MSBuildTools;Microsoft.VisualStudio.Component.VC.160 --passive --locale en-US")
Run-Executable "choco" @("install", "-y", "visualstudio2019buildtools", "--version", "16.5.4.0", "--package-parameters", "--add Microsoft.VisualStudio.Workload.VCTools;includeRecommended --add Microsoft.VisualStudio.Component.VC.160 --add Microsoft.VisualStudio.Component.NuGet.BuildTools --add Microsoft.VisualStudio.Workload.UniversalBuildTools;includeRecommended --add Microsoft.VisualStudio.Workload.NetCoreBuildTools;includeRecommended --add Microsoft.Net.Component.4.5.TargetingPack --add Microsoft.Net.Component.4.6.TargetingPack --add Microsoft.Net.Component.4.7.TargetingPack --passive --locale en-US")

# install msys2
Run-Executable "choco" @("install", "-y", "msys2")

# refresh environment variables
refreshenv
$env:PATH = $env:PATH + ";C:\tools\msys64\usr\bin;C:\tools\msys64\mingw64\bin"

# set permanent PATH environment variable
[Environment]::SetEnvironmentVariable("PATH", [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";C:\tools\msys64\usr\bin;C:\tools\msys64\mingw64\bin", "Machine")

# update pacman
Run-Executable "pacman" @("-Syu", "--noconfirm", "--noprogressbar")

# install gcc for go race detector
Run-Executable "pacman" @("-S", "--noconfirm", "--noprogressbar", "mingw-w64-x86_64-gcc")

# clean package cache
Run-Executable "pacman" @("-Sc", "--noconfirm", "--noprogressbar")

# Check if any of the video controllers are from NVIDIA.
# Note, 0x10DE is the NVIDIA Corporation Vendor ID.
$hasNvidiaGpu = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match "^PCI\\VEN_10DE" }

if ($hasNvidiaGpu) {
    Invoke-WebRequest -Uri "https://download.microsoft.com/download/a/3/1/a3186ac9-1f9f-4351-a8e7-b5b34ea4e4ea/538.46_grid_win10_win11_server2019_server2022_dch_64bit_international_azure_swl.exe" -OutFile "C:\Downloads\nvidia_driver.exe"
    Run-Executable "C:\Downloads\nvidia_driver.exe" @("-s", "-noreboot")

    # Need to fix this CUDA installation in staging...
    # Removing from here for now...
    # https://github.com/taskcluster/community-tc-config/issues/713
    # Invoke-WebRequest -Uri "https://developer.download.nvidia.com/compute/cuda/12.6.1/local_installers/cuda_12.6.1_560.94_windows.exe" -OutFile "C:\Downloads\cuda_installer.exe"
    # Run-Executable "C:\Downloads\cuda_installer.exe" @("-s", "-noreboot")

}

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
