#####################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved.
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
#####################################################################

<#
.Synopsis
 Perform Save/Start operations on VMs with Dynamic Memory enabled.

 Description:
  Perform Save/Start operations on VMs with Dynamic Memory enabled and make sure VMs remain stable.

   2 VMs are required for this test.

   The testParams have the format of:

      vmName=Name of a VM, enable=[yes|no], minMem= (decimal) [MB|GB|%], maxMem=(decimal) [MB|GB|%],
      startupMem=(decimal) [MB|GB|%], memWeight=(0 < decimal < 100)

   Only the vmName param is taken into consideration. This needs to appear at least twice for
   the test to start.

      Tries=(decimal)
       This controls the number of times the script tries to start the second VM. If not set, a default
       value of 3 is set.
       This is necessary because Hyper-V usually removes memory from a VM only when a second one applies pressure.
       However, the second VM can fail to start while memory is removed from the first.
       There is a 30 second timeout between tries, so 3 tries is a conservative value.

   The following is an example of a testParam for configuring Dynamic Memory

       "Tries=3;vmName=sles11x64sp3;enable=yes;minMem=512MB;maxMem=80%;startupMem=80%;memWeight=0;
       vmName=sles11x64sp3_2;enable=yes;minMem=512MB;maxMem=25%;startupMem=25%;memWeight=0"

   All scripts must return a boolean to indicate if the script completed successfully or not.

   .Parameter vmName
    Name of the VM to remove NIC from .

    .Parameter hvServer
    Name of the Hyper-V server hosting the VM.

    .Parameter testParams
    Test data for this test case

    .Example
    setupscripts\DM_SaveRestore.ps1 -vmName nameOfVM -hvServer localhost -testParams 'sshKey=KEY;ipv4=IPAddress;rootDir=path\to\dir;vmName=NameOfVM1;vmName=NameOfVM2'
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)
Set-PSDebug -Strict

#######################################################################
#
# Main script body
#
#######################################################################
#
# Check input arguments
#
if ($vmName -eq $null)
{
    "Error: VM name is null"
    return $False
}

if ($hvServer -eq $null)
{
    "Error: hvServer is null"
    return $False
}

if ($testParams -eq $null)
{
    "Error: testParams is null"
    return $False
}

# Write out test Params
$testParams

# sshKey used to authenticate ssh connection and send commands
$sshKey = $null

# IP Address of first VM
$ipv4 = $null

# Name of first VM
$vm1Name = $null

# Name of second VM
$vm2Name = $null

# number of tries
[int]$tries = 0

# default number of tries
Set-Variable defaultTries -option Constant -value 3

# change working directory to root dir
$testParams -match "RootDir=([^;]+)"
if (-not $?)
{
    "Mandatory param RootDir=Path; not found!"
    return $false
}
$rootDir = $Matches[1]

if (Test-Path $rootDir)
{
    Set-Location -Path $rootDir
    if (-not $?)
    {
        "Error: Could not change directory to $rootDir !"
        return $false
    }
    "Changed working directory to $rootDir"
}
else
{
    "Error: RootDir = $rootDir is not a valid path"
    return $false
}

# Source TCUitls.ps1 for getipv4 and other functions
if (Test-Path ".\setupScripts\TCUtils.ps1")
{
    . .\setupScripts\TCUtils.ps1
}
else
{
    "Error: Could not find setupScripts\TCUtils.ps1"
    return $false
}

# iterator for vmName= parameters. Only 2 are taken into consideration
[int]$netAdapterNameIterator = 0

$params = $testParams.Split(";")
foreach ($p in $params)
{
    $fields = $p.Split("=")

    switch ($fields[0].Trim())
    {
      "VM2NAME"       { $vm2Name = $fields[1].Trim() }
      "ipv4"    { $ipv4    = $fields[1].Trim() }
      "sshKey"  { $sshKey  = $fields[1].Trim() }
      "tries"  { $tries  = $fields[1].Trim() }
      "TC_COVERED" { $TC_COVERED = $fields[1].Trim() }
    }
}

$summaryLog = "${vmName}_summary.log"
del $summaryLog -ErrorAction SilentlyContinue
Write-Output "This script covers test case: ${TC_COVERED}" | Tee-Object -Append -file $summaryLog

if ($tries -le 0)
{
    $tries = $defaultTries
}

$vm1Name = $vmName

$vm1 = Get-VM -Name $vm1Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $vm1)
{
    "Error: VM $vm1Name does not exist" | Tee-Object -Append -file $summaryLog
    return $false
}

$vm2 = Get-VM -Name $vm2Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $vm2)
{
    "Error: VM $vm2Name does not exist" | Tee-Object -Append -file $summaryLog
    return $false
}

# sleep 1 minute for VM to start reporting demand
$sleepPeriod = 60
while ($sleepPeriod -gt 0)
{
    # get VM1's Memory
    [int64]$vm1BeforeAssigned = ($vm1.MemoryAssigned/[int64]1048576)
    [int64]$vm1BeforeDemand = ($vm1.MemoryDemand/[int64]1048576)

    if ($vm1BeforeAssigned -gt 0 -and $vm1BeforeDemand -gt 0)
    {
        break
    }

    $sleepPeriod -= 5
    Start-Sleep -s 5
}

if ($vm1BeforeAssigned -le 0)
{
    "Error: $vm1Name Assigned memory is 0" | Tee-Object -Append -file $summaryLog
    return $false
}

if ($vm1BeforeDemand -le 0)
{
    "Error: $vm1Name Memory demand is 0" | Tee-Object -Append -file $summaryLog
    return $false
}

"VM1 $vm1Name before assigned memory : $vm1BeforeAssigned"
"VM1 $vm1Name before memory demand: $vm1BeforeDemand"

#
# LIS Started VM1, so start VM2
#
$timeout = 120
StartDependencyVM $vm2Name $hvServer $tries
WaitForVMToStartKVP $vm2Name $hvServer $timeout

# sleep another 2 minute trying to get VM2's memory demand
$sleepPeriod = 120 #seconds
# get VM2's Memory
while ($sleepPeriod -gt 0)
{
    [int64]$vm2BeforeAssigned = ($vm2.MemoryAssigned/[int64]1048576)
    [int64]$vm2BeforeDemand = ($vm2.MemoryDemand/[int64]1048576)

    if ($vm2BeforeAssigned -gt 0 -and $vm2BeforeDemand -gt 0)
    {
        break
    }

    $sleepPeriod-= 5
    Start-Sleep -s 5
}

if ($vm2BeforeAssigned -le 0)
{
    "Error: $vm2Name Assigned memory is 0" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

if ($vm2BeforeDemand -le 0)
{
    "Error: $vm2Name Memory demand is 0" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

"VM2 $vm2Name before assigned memory : $vm2BeforeAssigned"
"VM2 $vm2Name before memory demand: $vm2BeforeDemand"

# Save VM2
Save-VM $vm2Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $?)
{
    "Error: Unable to save vm2 $vm2Name on $hvServer" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

Start-VM -Name $vm2Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $?)
{
    "Error: Unable to start VM2 $vm2Name after saving it" | Tee-Object -Append -file $summaryLog
    return $false
}

Start-Sleep -s 60
# get VM2's Memory
[int64]$vm2AfterAssigned = ($vm2.MemoryAssigned/[int64]1048576)
[int64]$vm2AfterDemand = ($vm2.MemoryDemand/[int64]1048576)
if ($vm2AfterAssigned -le 0)
{
    "Error: $vm2Name Assigned memory is 0 after it started from save" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

if ($vm2AfterDemand -le 0)
{
    "Error: $vm2Name Memory demand is $vm2AfterDemand after it started from save." | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

"VM2 $vm2Name after assigned memory : $vm2AfterAssigned"
"VM2 $vm2Name after memory demand: $vm2AfterDemand"

# Save VM1
Save-VM $vm1Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $?)
{
    "Error: Unable to save VM1 $vm1Name" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

Start-VM -Name $vm1Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $?)
{
    "Error: Unable to start VM1 $vm1Name after saving it" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

Start-Sleep -s 60
# get VM1's Memory
[int64]$vm1AfterAssigned = ($vm1.MemoryAssigned/[int64]1048576)
[int64]$vm1AfterDemand = ($vm1.MemoryDemand/[int64]1048576)
if ($vm1AfterAssigned -le 0)
{
    "Error: $vm1Name Assigned memory is 0 after it started from save" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

if ($vm1AfterDemand -le 0)
{
    "Error: $vm1Name Memory demand is 0 after it started from save" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

"VM1 $vm1Name after assigned memory : $vm1AfterAssigned"
"VM1 $vm1Name after memory demand: $vm1AfterDemand"
# save VM1 and VM2
Save-VM $vm1Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $?)
{
    "Error: Unable to save VM1 $vm1Name the second time" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

Save-VM $vm2Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $?)
{
    "Error: Unable to save VM2 $vm2Name the second time" | Tee-Object -Append -file $summaryLog
    Start-VM -Name $vm1Name -ComputerName $hvServer -ErrorAction SilentlyContinue
    if (-not $?)
    {
        "Warning: Unable to start VM1 $vm1Name before exiting script."
    }
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

Start-VM -Name $vm2Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $?)
{
    "Error: Unable to start VM2 $vm2Name after saving it the second time" | Tee-Object -Append -file $summaryLog
    Start-VM -Name $vm1Name -ComputerName $hvServer -ErrorAction SilentlyContinue
    {
      "Warning: Unable to start VM1 $vm1Name before exiting script."
    }
    return $false
}

Start-VM -Name $vm1Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $?)
{
    "Error: Unable to start VM1 $vm1Name after saving it the second time" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

Start-Sleep -s 60
# get VM1's Memory
[int64]$vm1EndAssigned = ($vm1.MemoryAssigned/[int64]1048576)
[int64]$vm1EndDemand = ($vm1.MemoryDemand/[int64]1048576)

if ($vm1EndAssigned -le 0)
{
    "Error: $vm1Name Assigned memory is 0 after last round of saving" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

if ($vm1EndDemand -le 0)
{
    "Error: $vm1Name Memory demand is 0 after last round of saving" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

"VM1 $vm1Name end assigned memory : $vm1EndAssigned"
"VM1 $vm1Name end memory demand: $vm1EndDemand"

# get VM2's Memory
[int64]$vm2EndAssigned = ($vm2.MemoryAssigned/[int64]1048576)
[int64]$vm2EndDemand = ($vm2.MemoryDemand/[int64]1048576)

if ($vm2EndAssigned -le 0)
{
    "Error: $vm2Name Assigned memory is 0 after last round of saving" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

if ($vm2EndDemand -le 0)
{
    "Error: $vm2Name Memory demand is 0 after last round of saving" | Tee-Object -Append -file $summaryLog
    Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
    return $false
}

"VM2 $vm2Name end assigned memory : $vm2EndAssigned"
"VM2 $vm2Name end memory demand: $vm2EndDemand"

Stop-VM -vmName $vm2Name -ComputerName $hvServer -force

write-output $true
return $true
