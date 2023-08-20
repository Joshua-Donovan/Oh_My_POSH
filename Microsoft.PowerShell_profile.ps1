$Runspace = [runspacefactory]::CreateRunspace()
$PowerShell = [powershell]::Create()
$PowerShell.runspace = $Runspace
$Runspace.Open()

[void]$PowerShell.AddScript({
    
    # SETUP Environment for Queries
    # This example uses the PowerShell SecretStore to store / retrieve the Azure App Registration informaiton so it is not stored in plain text.
    # https://github.com/powershell/secretmanagement

    If (!(Get-Module -Name Microsoft.PowerShell.SecretStore)) {
        try {
            Import-Module -Name Microsoft.PowerShell.SecretStore
            $env:POSH_AZURE_STATUS = "Successfully Imported Microsoft.PowerShell.SecretStore"
        } Catch {
            $env:POSH_AZURE_STATUS = "Could not `"Import-Module -Name Microsoft.PowerShell.SecretStore`" error: $($error[0] | select *)"
            return
        }
    }
    try {
        $TenantId = Get-Secret -Name POSH_AZURE_TENANT_ID -Vault PWSH_PROFILE -AsPlainText
        $client_id = Get-Secret -Name POSH_AZURE_CLIENT_ID -Vault PWSH_PROFILE -AsPlainText
        $client_secret = Get-Secret -Name POSH_AZURE_CLIENT_SECRET -Vault PWSH_PROFILE
        $cred = [PsCredential]::New($client_id, $client_secret)
        $env:POSH_AZURE_STATUS = "Service Principal Credentials Configured"
    } catch {
        $env:POSH_AZURE_STATUS = "Something went wrong configuring Service Principal Credentials error: $($error[0] | select *)"
    }
    try {
        Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $TenantId -Context POSH_QUERIES
        $env:POSH_AZURE_STATUS = "Connect-AzAccount Completed"
    } catch {
        $env:POSH_AZURE_STATUS = "Connect-AzAccount Failed error: $($error[0] | select *)"
    }
    function Login()  
    {  
        $context = Get-AzContext -Name POSH_QUERIES
        if (!$context) 
        {  
            try {
                Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $TenantId -Context POSH_QUERIES
                return $true
            } catch {
                return $false
            }
        } else {
            return $true
        }
        if ((Get-AzContext).Name -ne "POSH_QUERIES")
        {
            Set-AzContext -Context $(Get-AzContext -Name POSH_QUERIES)
        }
    }  
    function Get-VMStates()
    {
        try {
            $GraphData = Search-AzGraph -Query 'resources | where type == "microsoft.compute/virtualmachines" | extend powerState = properties.extended.instanceView.powerState.displayStatus | where powerState != "VM deallocated" | project name'
        } catch {
            return "ARG Request Failed"
        }

        if ($GraphData.Count -ge 1) {
            $formattedString = "·"
            $($GraphData | Foreach-Object {$formattedString = "$formattedString 󰒋 $($_.name) 󰶼 ·"})
            return $formattedString
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
    {	
        $cost = ($Report | Measure-Object PretaxCost -Sum).Sum.ToString("##0.00")
        return $cost
    }
    function Get-AzureCostbyTag($Report, $TagName, $TagValue)
    {
        $taggedResources = $Report | Where-Object {$_.Tags -ne $null}
        if ($taggedResources)
        {
            $CostbyTagValue = ($taggedResources | Where-Object {$_.Tags[$TagName] -eq $TagValue} | Measure-Object PretaxCost -Sum).Sum.ToString("##0.000")
            return "$($TagValue): `$$CostbyTagValue"
        }
        else {
            return "No Matching Tags"
        }
    }
    $running = $true
    # do work
    do {

        if (Login) {
            $env:POSH_AZURE_STATUS = "Loop Started"
            $CostReport = Get-AzConsumptionUsageDetail
            $env:POSH_AZURE_TOTAL_COST = Get-AzureCost -Report $CostReport
            if($env:POSH_AZURE_TOTAL_COST) {
                # My chosen budget is $150.00
                $env:POSH_AZURE_TOTAL_REMAINING = $(150.00 - $env:POSH_AZURE_TOTAL_COST)
            }
            $env:POSH_AZURE_TIME_TILL_RESET = Get-DaysTillReset
            $env:POSH_AZURE_COST_SERVERS = Get-AzureCostbyTag -Report $CostReport -TagName 'app_group' -TagValue 'servers'
            $env:POSH_AZURE_COST_WEB_SERVERS = Get-AzureCostbyTag -Report $CostReport -TagName 'app_group' -TagValue 'web'
            $env:POSH_AZURE_RUNNING_SERVERS = Get-VMStates
            # Hide Status Segment after loop is running without error
            $env:POSH_AZURE_STATUS = ""
            start-sleep 300
        } else {
            $running = $false
        }
    } while ($running)
})

$AsyncObject = $PowerShell.BeginInvoke()

oh-my-posh init pwsh --config "$ENV:USERPROFILE\Documents\WindowsPowerShell\cheap-cloud-azure.omp.json" | Invoke-Expression
$env:POSH_AZURE_ENABLED = $true
