$Runspace = [runspacefactory]::CreateRunspace()
$PowerShell = [powershell]::Create()
$PowerShell.runspace = $Runspace
$Runspace.Open()

[void]$PowerShell.AddScript({
    $ErrorActionPreference = "Stop"
    If (!(Get-Module -Name Microsoft.PowerShell.SecretStore)) {
        try {
            Import-Module -Name Microsoft.PowerShell.SecretStore
        } Catch {
            $env:POSH_AZURE_STATUS = "Could not `"Import-Module -Name Microsoft.PowerShell.SecretStore`" error: $($error[0] | Select-Object *)"
            return
        }
    }
    try {
        $TenantId = Get-Secret -Name POSH_AZURE_TENANT_ID -Vault PWSH_PROFILE -AsPlainText
        $SubscriptionId = Get-Secret -Name POSH_AZURE_SUBSCRIPTION_ID -Vault PWSH_PROFILE -AsPlainText
        $client_id = Get-Secret -Name POSH_AZURE_CLIENT_ID -Vault PWSH_PROFILE -AsPlainText
        $client_secret = Get-Secret -Name POSH_AZURE_CLIENT_SECRET -Vault PWSH_PROFILE
        $cred = [PsCredential]::New($client_id, $client_secret)
        $env:POSH_AZURE_STATUS = "Starting"
    } catch {
        $env:POSH_AZURE_STATUS = "Something went wrong configuring Service Principal Credentials error: $($error[0] | Select-Object *)"
        return
    }
    function Get-VMStates()
    {
        try {
            $jobs = Get-Job | Where-Object {$_.Name -eq "GETVMSTATES"}
            if ($jobs) {
                $jobs | Remove-Job -Force
            }
            $jobValue = Start-Job -Name GETVMSTATES -ArgumentList @($cred, $SubscriptionId, $TenantId) -ScriptBlock {
                $null = Connect-AzAccount -ContextName POSH_QUERIES_JOB -ServicePrincipal -Credential $args[0] -SubscriptionId $args[1] -Tenant $args[2] -SkipContextPopulation -Force
                $GraphData = Search-AzGraph -Query 'resources | where type == "microsoft.compute/virtualmachines" | extend powerState = properties.extended.instanceView.powerState.displayStatus | where powerState != "VM deallocated" | project name'
                Remove-AzContext -Name POSH_QUERIES_JOB -Force
                if ($GraphData.Count -ge 1) {
                    $formattedString = "·"
                    $($GraphData | Foreach-Object {$formattedString = "$formattedString 󰒋 $($_.name) 󰶼 ·"})
                    return $formattedString
                } else {
                    return
                }
            } | Wait-Job | Receive-Job
        } catch {
            return "ARG Request Failed error: $($error[0] | Select-Object *)"
        }
        $jobs = Get-Job | Where-Object {$_.Name -eq "GETVMSTATES"}
        if ($jobs) {
            $jobs | Remove-Job -Force
        }
        if($jobValue) {
            return $jobValue
        } else {
            return
        }
    }
    function Get-AzureCostReport
    {
        try {
            $jobs = Get-Job | Where-Object {$_.Name -eq "GETAZURECOSTREPORT"}
            if ($jobs) {
                $jobs | Remove-Job -Force
            }
            $jobValue = Start-Job -Name GETAZURECOSTREPORT -ArgumentList @($cred, $SubscriptionId, $TenantId) -ScriptBlock {
                $null = Connect-AzAccount -ContextName POSH_QUERIES_BILLING_JOB -ServicePrincipal -Credential $args[0] -SubscriptionId $args[1] -Tenant $args[2] -SkipContextPopulation -Force
                $Data = Get-AzConsumptionUsageDetail
                Remove-AzContext -Name POSH_QUERIES_BILLING_JOB -Force
                if ($Data.Count -ge 1) {
                    return $Data
                } else {
                    return
                }
            } | Wait-Job | Receive-Job
        } catch {
            return "Get-AzConsumptionUsageDetail: $($error[0] | Select-Object *)"
        }
        $jobs = Get-Job | Where-Object {$_.Name -eq "GETAZURECOSTREPORT"}
        if ($jobs) {
            $jobs | Remove-Job -Force
        }
        if($jobValue) {
            return $jobValue
        } else {
            return
        } 
    }
    function Get-DaysTillReset()
    {
        $today = Get-Date
        $reset = (Get-Date (Get-Date $today -Day 1 ).AddMonths(1) -Day 15)
        return "$(($reset - $today).Days)"
    }
    function Get-AzureCost($Report)
    {	try {
            $cost = ($Report | Measure-Object PretaxCost -Sum).Sum.ToString("##0.00")
        } catch {
            $env:POSH_AZURE_STATUS = "Get-AzureCost Failed: $($error[0] | Select-Object *)"
            return "$($TagValue): Error Finding Tags"
        }
        return $cost
    }
    function Get-AzureCostbyTag($Report, $TagName, $TagValue)
    {
        $taggedResources = $Report | Where-Object {$null -ne $_.Tags}
        if ($taggedResources)
        {
            try {
                $FilteredResources = $taggedResources | Where-Object {$_.Tags[$TagName] -eq $TagValue}
            } catch {
                $env:POSH_AZURE_STATUS = "FilteredResources error: $($error[0] | Select-Object *)"
                return "$($TagValue): Error Finding Tags"
            }
            if ($FilteredResources.Count -gt 0) {
                try {
                    $CostbyTagValue = ($FilteredResources | Measure-Object PretaxCost -Sum).Sum.ToString("##0.000")
                } catch {
                    $env:POSH_AZURE_STATUS = "CostbyTagValue error: $($error[0] | Select-Object *)"
                    return "$($TagValue): Cost Calculation Error"
                }
            } else {
                return "$($TagValue): No Matched Resources"
            }
            if ($CostbyTagValue) {
                return "$($TagValue): `$$CostbyTagValue"
            } else {
                return "Issue Calculating Cost"
            }
        } else {
            return "No Tagged Resources"
        }
    }

    function Get-AzureCostTop3($Report) {
        try {
            $returnArray = New-Object System.Collections.ArrayList
            ($Report | Group-Object -Property InstanceId) `
            | Foreach-Object {
                    $instanceId = $null;
                    $currSum = $null;
                    $returnObj = New-Object PSCustomObject
                    $InstanceName = ($_.Group.InstanceName.ToLower() | Select-Object -Unique);
                    if ($InstanceName.Count > 1)
                    {
                        $InstanceName = $InstanceName[0]
                    }
                    $currSum = $_.Group | Measure-Object PretaxCost -Sum 
                    $returnObj | Add-Member -MemberType NoteProperty -Name 'Name' -Value $InstanceName;
                    $returnObj | Add-Member -MemberType NoteProperty -Name 'Sum' -Value $currSum.Sum;
                    Write-Host $returnObj
                    $null = $returnArray.Add($returnObj)
                }
            $top3 = $returnArray | Sort-Object Sum -Descending | Select-Object -First 3
            $formattedString = ""
            $($top3 | Foreach-Object {$formattedString = "$formattedString $($_.Name):`$$($_.Sum.ToString('##0.000')) ·"})
            return $formattedString
        } catch {
            $env:POSH_AZURE_STATUS = "Top3 Spenders error: $($error[0] | Select-Object *)"
        }
    }

    $firstRun = $true
    # do work
    do {
            if ($firstRun) {
                $env:POSH_AZURE_STATUS = "Loop Started"
            }
            Try {
                $CostReport = Get-AzureCostReport
                if ($firstRun) {
                    $env:POSH_AZURE_STATUS = "Got Consumption Details"
                }
            } Catch {
                $env:POSH_AZURE_STATUS = "Error getting Consumption Details error: $($error[0] | Select-Object *)"
            }
            $env:POSH_AZURE_TOTAL_COST = Get-AzureCost -Report $CostReport
            if($env:POSH_AZURE_TOTAL_COST) {
                # My chosen budget is $150.00
                $env:POSH_AZURE_TOTAL_REMAINING = $(150.00 - $env:POSH_AZURE_TOTAL_COST)
            }
            if ($CostReport){
                $env:POSH_MONITORED_AZURE_SUBSCRIPTION = "$($CostReport[0].SubscriptionName)"
            }
            if ($CostReport){
                $env:POSH_AZURE_BIG_SPENDERS = Get-AzureCostTop3 -Report $CostReport
            }
            $env:POSH_AZURE_TIME_TILL_RESET = Get-DaysTillReset
            $env:POSH_AZURE_COST_SERVERS = Get-AzureCostbyTag -Report $CostReport -TagName 'app_group' -TagValue 'servers'
            $env:POSH_AZURE_COST_WEB_SERVERS = Get-AzureCostbyTag -Report $CostReport -TagName 'app_group' -TagValue 'web'
            $env:POSH_AZURE_RUNNING_SERVERS = Get-VMStates
            # Hide Status Segment after loop is running without error
            $env:POSH_AZURE_STATUS = ""
            $firstRun = $false
            start-sleep 300
    } while ($true)
    $env:POSH_AZURE_STATUS = "Exited Query Loop"
})

$AsyncObject = $PowerShell.BeginInvoke()

# Checks for correct userprofile path
if (Test-Path "$ENV:OneDrive\Documents\WindowsPowerShell\cheap-cloud-azure.omp.json")
{
    $configPath = "$ENV:OneDrive\Documents\WindowsPowerShell\cheap-cloud-azure.omp.json"
} else {
    $configPath = "$ENV:USERPROFILE\Documents\WindowsPowerShell\cheap-cloud-azure.omp.json"
}

oh-my-posh init pwsh --config $configPath | Invoke-Expression
$env:POSH_AZURE_ENABLED = $true
