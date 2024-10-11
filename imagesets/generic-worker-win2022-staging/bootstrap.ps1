$TASKCLUSTER_REF = "main"

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

# utility function to download a zip file and extract it
function Expand-ZIPFile($file, $destination, $url)
{
    $client.DownloadFile($url, $file)
    $zip = $shell.NameSpace($file)
    foreach($item in $zip.items())
    {
        $shell.Namespace($destination).copyhere($item)
    }
}

# Exit the script on any powershell command error
$ErrorActionPreference = 'Stop'

# allow powershell scripts to run
Set-ExecutionPolicy Unrestricted -Force -Scope Process

# use TLS 1.2 (see bug 1443595)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

md "C:\Install Logs"

# Redirect the output (stdout and stderr) from the current powershell script to a log file
# There is a Stop-Transcript command later on in this script.
Start-Transcript -Path "C:\Install Logs\bootstrap.txt"

# capture env
Get-ChildItem Env: | Out-File "C:\Install Logs\env.txt"

# needed for making http requests
$client = New-Object system.net.WebClient
$shell = New-Object -com shell.application

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
    'wuauserv',   # Windows Update
    'usosvc',     # Update Orchestrator
    'DiagTrack',  # Telemetry service
    'SysMain',    # Superfetch
    'WSearch'     # Disk indexing
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
Invoke-Expression ($client.DownloadString('https://chocolatey.org/install.ps1'))

# install nssm
Expand-ZIPFile -File "C:\nssm-2.24.zip" -Destination "C:\" -Url "http://www.nssm.cc/release/nssm-2.24.zip"

# Add taskcluster entry to the hosts file, for (old) tasks not using $TASKCLUSTER_PROXY_URL
$hostsFileLines = @(
    "",
    "# Useful for generic-worker taskcluster-proxy integration",
    "# See https://bugzilla.mozilla.org/show_bug.cgi?id=1449981#c6",
    "127.0.0.1        taskcluster"
)

# Append the lines to the hosts file
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value $hostsFileLines

# download gvim
$client.DownloadFile("http://artfiles.org/vim.org/pc/gvim80-069.exe", "C:\gvim80-069.exe")

# open up firewall for livelog (both PUT and GET interfaces)
New-NetFirewallRule -DisplayName "Allow livelog PUT requests" -Direction Inbound -LocalPort 60022 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "Allow livelog GET requests" -Direction Inbound -LocalPort 60023 -Protocol TCP -Action Allow

# install go
Expand-ZIPFile -File "C:\go1.23.1.windows-amd64.zip" -Destination "C:\" -Url "https://storage.googleapis.com/golang/go1.23.1.windows-amd64.zip"
Move-Item -Path "C:\go" -Destination "C:\goroot"

# install git
$client.DownloadFile("https://github.com/git-for-windows/git/releases/download/v2.46.2.windows.1/Git-2.46.2-64-bit.exe", "C:\Git-2.46.2-64-bit.exe")
Run-Executable "C:\Git-2.46.2-64-bit.exe" @("/VERYSILENT", "/LOG=`"C:\Install Logs\git.txt`"", "/NORESTART", "/SUPPRESSMSGBOXES")

# install node
$client.DownloadFile("https://nodejs.org/dist/v20.17.0/node-v20.17.0-x64.msi", "C:\NodeSetup.msi")
Run-Executable "msiexec" @("/i", "C:\NodeSetup.msi", "/quiet")

# install python 3.11.9
$client.DownloadFile("https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe", "C:\python-3.11.9-amd64.exe")
# issue 751: without /log <file> python fails to install on Azure workers, with exit code 1622, maybe default log location isn't writable(?)
Run-Executable "C:\python-3.11.9-amd64.exe" @("/quiet", "InstallAllUsers=1", "/log", "C:\Install Logs\python-3.11.9.txt")

# set permanent env vars
[Environment]::SetEnvironmentVariable("GOROOT", "C:\goroot", "Machine")
[Environment]::SetEnvironmentVariable("PATH", [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";C:\Program Files\Vim\vim80;C:\goroot\bin;C:\Program Files\Python311", "Machine")
[Environment]::SetEnvironmentVariable("PATHEXT", [Environment]::GetEnvironmentVariable("PATHEXT", "Machine") + ";.PY", "Machine")

# set env vars for the currently running process
$env:GOROOT  = "C:\goroot"
$env:PATH    = $env:PATH + ";C:\goroot\bin;C:\Program Files\Git\cmd;C:\Program Files\Python311"
$env:PATHEXT = $env:PATHEXT + ";.PY"

md "C:\generic-worker"
md "C:\worker-runner"

# build generic-worker/livelog/start-worker/taskcluster-proxy from ${TASKCLUSTER_REF} commit / branch / tag etc
Run-Executable "git" @("clone", "https://github.com/taskcluster/taskcluster")
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
Set-Content -Path C:\generic-worker\install.bat @"
set nssm=C:\nssm-2.24\win64\nssm.exe
%nssm% install "Generic Worker" C:\generic-worker\generic-worker.exe
%nssm% set "Generic Worker" AppDirectory C:\generic-worker
%nssm% set "Generic Worker" AppParameters run --config C:\generic-worker\generic-worker-config.yml --worker-runner-protocol-pipe \\.\pipe\generic-worker
%nssm% set "Generic Worker" DisplayName "Generic Worker"
%nssm% set "Generic Worker" Description "A taskcluster worker that runs on all mainstream platforms"
%nssm% set "Generic Worker" Start SERVICE_DEMAND_START
%nssm% set "Generic Worker" Type SERVICE_WIN32_OWN_PROCESS
%nssm% set "Generic Worker" AppNoConsole 1
%nssm% set "Generic Worker" AppAffinity All
%nssm% set "Generic Worker" AppStopMethodSkip 0
%nssm% set "Generic Worker" AppExit Default Exit
%nssm% set "Generic Worker" AppRestartDelay 0
%nssm% set "Generic Worker" AppStdout C:\generic-worker\generic-worker-service.log
%nssm% set "Generic Worker" AppStderr C:\generic-worker\generic-worker-service.log
%nssm% set "Generic Worker" AppRotateFiles 0
"@
Run-Executable "C:\generic-worker\install.bat"

# install worker-runner
Set-Content -Path C:\worker-runner\install.bat @"
set nssm=C:\nssm-2.24\win64\nssm.exe
%nssm% install worker-runner C:\worker-runner\start-worker.exe
%nssm% set worker-runner AppDirectory C:\worker-runner
%nssm% set worker-runner AppParameters C:\worker-runner\runner.yml
%nssm% set worker-runner DisplayName "Worker Runner"
%nssm% set worker-runner Description "Interface between workers and Taskcluster services"
%nssm% set worker-runner Start SERVICE_AUTO_START
%nssm% set worker-runner Type SERVICE_WIN32_OWN_PROCESS
%nssm% set worker-runner AppNoConsole 1
%nssm% set worker-runner AppAffinity All
%nssm% set worker-runner AppStopMethodSkip 0
%nssm% set worker-runner AppExit Default Exit
%nssm% set worker-runner AppRestartDelay 0
%nssm% set worker-runner AppStdout C:\worker-runner\worker-runner-service.log
%nssm% set worker-runner AppStderr C:\worker-runner\worker-runner-service.log
%nssm% set worker-runner AppRotateFiles 1
%nssm% set worker-runner AppRotateOnline 1
%nssm% set worker-runner AppRotateSeconds 3600
%nssm% set worker-runner AppRotateBytes 0
"@
Run-Executable "C:\worker-runner\install.bat"

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
$client.DownloadFile("https://www.cygwin.com/setup-x86_64.exe", "C:\cygwin-setup-x86_64.exe")

# install cygwin
# complete package list: https://cygwin.com/packages/package_list.html
Run-Executable "C:\cygwin-setup-x86_64.exe" @("--quiet-mode", "--wait", "--root", "C:\cygwin", "--site", "http://cygwin.mirror.constant.com", "--packages", "openssh,vim,curl,tar,wget,zip,unzip,diffutils,bzr")

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
$client.DownloadFile("https://raw.githubusercontent.com/petemoore/myscrapbook/master/setup.sh", "C:\cygwin\home\Administrator\setup.sh")

# run bash setup script
Run-Executable "C:\cygwin\bin\bash.exe" @("--login", "-c", "chmod a+x setup.sh; ./setup.sh")

# install dependencywalker (useful utility for troubleshooting, not required)
md "C:\DependencyWalker"
Expand-ZIPFile -File "C:\depends22_x64.zip" -Destination "C:\DependencyWalker" -Url "http://dependencywalker.com/depends22_x64.zip"

# install ProcessExplorer (useful utility for troubleshooting, not required)
md "C:\ProcessExplorer"
Expand-ZIPFile -File "C:\ProcessExplorer.zip" -Destination "C:\ProcessExplorer" -Url "https://download.sysinternals.com/files/ProcessExplorer.zip"

# install ProcessMonitor (useful utility for troubleshooting, not required)
md "C:\ProcessMonitor"
Expand-ZIPFile -File "C:\ProcessMonitor.zip" -Destination "C:\ProcessMonitor" -Url "https://download.sysinternals.com/files/ProcessMonitor.zip"

# install Windows 10 SDK
choco install -y windows-sdk-10.0

# install VisualStudio 2019 Community
choco install -y visualstudio2019community --version 16.5.4.0 --package-parameters "--add Microsoft.VisualStudio.Workload.MSBuildTools;Microsoft.VisualStudio.Component.VC.160 --passive --locale en-US"
choco install -y visualstudio2019buildtools --version 16.5.4.0 --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools;includeRecommended --add Microsoft.VisualStudio.Component.VC.160 --add Microsoft.VisualStudio.Component.NuGet.BuildTools --add Microsoft.VisualStudio.Workload.UniversalBuildTools;includeRecommended --add Microsoft.VisualStudio.Workload.NetCoreBuildTools;includeRecommended --add Microsoft.Net.Component.4.5.TargetingPack --add Microsoft.Net.Component.4.6.TargetingPack --add Microsoft.Net.Component.4.7.TargetingPack --passive --locale en-US"

# install gcc for go race detector
choco install -y mingw --version 11.2.0.07112021

# Check if any of the video controllers are from NVIDIA
# Note, 0x10DE is the NVIDIA Corporation Vendor ID
$hasNvidiaGpu = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match "^PCI\\VEN_10DE" }

if ($hasNvidiaGpu) {
    $client.DownloadFile("https://download.microsoft.com/download/a/3/1/a3186ac9-1f9f-4351-a8e7-b5b34ea4e4ea/538.46_grid_win10_win11_server2019_server2022_dch_64bit_international_azure_swl.exe", "C:\nvidia_driver.exe")
    Run-Executable "C:\nvidia_driver.exe" @("-s", "-noreboot")

    # Need to fix this CUDA installation in staging...
    # Removing from here for now...
    # https://github.com/taskcluster/community-tc-config/issues/713
    # $client.DownloadFile("https://developer.download.nvidia.com/compute/cuda/12.6.1/local_installers/cuda_12.6.1_560.94_windows.exe", "C:\cuda_installer.exe")
    # Run-Executable "C:\cuda_installer.exe" @("-s", "-noreboot")

}

# Log before stopping transcript to make sure message is included in transcript.
Write-Log "Bootstrap process completed. Shutting down..."

# This ends logging to the log file specified in the Start-Transcript command earlier on
Stop-Transcript

# now shutdown, in preparation for creating an image
# Stop-Computer isn't working, also not when specifying -AsJob, so reverting to using `shutdown` command instead
#   * https://www.reddit.com/r/PowerShell/comments/65250s/windows_10_creators_update_stopcomputer_not/dgfofug/?st=j1o3oa29&sh=e0c29c6d
#   * https://support.microsoft.com/en-in/help/4014551/description-of-the-security-and-quality-rollup-for-the-net-framework-4
#   * https://support.microsoft.com/en-us/help/4020459
shutdown -s
