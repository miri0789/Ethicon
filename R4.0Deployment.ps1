$tenantId = "cfd26b50-fb8f-44cf-87b2-d5df3d15d884"
$clientId = "7febc44c-a47f-4e59-91b7-149cd8fdcefb"
$clientSecret = "sFhSwYB_xQ882v_resu_Ft~U2hNu.-84d2"
$subscriptionId = "ff0df81e-ddc5-4e0b-ba79-cfe99c1c85c3"
$region = "East US"
$envSufix = "US"
$resourceGroupName = "Bandit-Prod"
$JNJFilesFolder = "C:\Users\miriam_m\Documents\JnJ-Bandit\JnJ-Bandit\JnJ-Bandit-Front\src\assets\files"




az login
Connect-AzAccount
Set-AzContext -Subscription $subscriptionId

$virtualNetwork = Get-AzVirtualNetwork -Name "Bandit$($envSufix)-vnet"
$appServicePlan = Get-AzResource -Name "Bandit$($envSufix)-asp"

    
# ##Create research resources
# Write-Output "###Create entry point IP for researchDB nat"
# $natPublicIp = New-AzPublicIpAddress -Name "Bandit-$($envSufix)-Nat-ip" `
#                                      -ResourceGroupName $resourceGroupName `
#                                      -Location $region `
#                                      -Sku "Standard" `
#                                      -IdleTimeoutInMinutes 4 `
#                                      -AllocationMethod "static"

# Write-Output "###Create a nat gateway"
# $natGateway = New-AzNatGateway -Name "Bandit-$($envSufix)-nat" `
#                                -ResourceGroupName $resourceGroupName `
#                                -IdleTimeoutInMinutes 4 `
#                                -Sku "Standard" `
#                                -Location $region `
#                                -PublicIpAddress $natPublicIp

# Write-Output "###add vnet subject for researchDB"
# Add-AzVirtualNetworkSubnetConfig -Name "ResearchDbAppService" `
#                                 -VirtualNetwork $virtualNetwork `
#                                 -AddressPrefix "10.0.6.0/24" `
#                                 -InputObject $natGateway
# $virtualNetwork | Set-AzVirtualNetwork

# Write-Output "###Create researchDB web job"
# $researchWebApp = New-AzWebApp -Name "ResearchDBWebjob$($envSufix)" `
#     -Location $region `
#     -AppServicePlan $AppServicePlan.Name `
#     -ResourceGroupName $resourceGroupName

# az webapp vnet-integration add -g $resourceGroupName `
#                                -n "ResearchDBWebjob$($envSufix)" `
#                                --vnet $virtualNetwork.Name `
#                                --subnet "ResearchDbAppService" `
#                                --subscription $subscriptionId 

                               
# $appConfigurationName = "Bandit-$($envSufix)-config"
# $appConfigurationConnectionString = (Get-AzAppConfigurationStoreKey -Name $appConfigurationName `
#                                                                     -ResourceGroupName $resourceGroupName).ConnectionString[0]


# Write-Output "###Update config params in webjobs & functions"
# $settings = @(
#   "AppConfig=$appConfigurationConnectionString",
#   "AZURE_CLIENT_ID=$clientId",
#   "AZURE_CLIENT_SECRET=$clientSecret",
#   "AZURE_TENANT_ID=$tenantId"
# )    


# az webapp config appsettings set -g $resourceGroupName -n "ResearchDBWebjob$($envSufix)" `
#     --settings $settings --subscription $subscriptionId




$jnjFilesContainerName = "bandit$($envSufix.ToLower().Replace('-', ''))jnjfiles"
if($jnjFilesContainerName.length -ge 24){
    $jnjFilesContainerName = $jnjFilesContainerName.Substring(0,24)
}           

Write-Output "###Create a files container" 
$filesStorage = New-AzStorageAccount -ResourceGroupName $resourceGroupName `
    -AccountName $jnjFilesContainerName `
    -Location $region `
    -SkuName Standard_RAGRS

$CorsRules = (@{
        AllowedOrigins = @("*");
        AllowedMethods = @("Get")
    })
    
Set-AzStorageCORSRule -ServiceType Blob `
    -CorsRules $CorsRules `
    -Context $filesStorage.Context
        
$filesContainer = New-AzStorageContainer -Name "files" `
    -Permission Container `
    -Context $filesStorage.Context

$JNJFiles = Get-ChildItem $JNJFilesFolder -Recurse -File
$JNJFiles.ForEach{
    Set-AzStorageBlobContent -File $_.FullName `
        -Container "files" `
        -Blob "$($_.FullName.Replace("$JNJFilesFolder\",'').Replace("\","/"))" `
        -Context $filesStorage.Context -Force -AsJob 
}


az appconfig kv set `
    -n $appConfigurationName `
    --key JNJfileStorageBaseUrl `
    --value $filesContainer.BlobContainerClient.Uri -y



Write-Output "###Update an Application Gateway"


$gw = Get-AzApplicationGateway -Name "Bandit-$($envSufix)-gw" `
    -ResourceGroupName $resourceGroupName

Add-AzApplicationGatewayBackendAddressPool -ApplicationGateway $gw -Name "files-storage-backendpool" `
    -BackendFqdns "$jnjFilesContainerName.blob.core.windows.net"

$gwFilesPool = Get-AzApplicationGatewayBackendAddressPool -ApplicationGateway $gw -Name "files-storage-backendpool"


Add-AzApplicationGatewayProbeConfig -ApplicationGateway $gw -Name "files-storage-prob" `
    -Protocol Https `
    -Path "/files/en.json" `
    -Interval 30 `
    -Timeout 30 `
    -UnhealthyThreshold 3 `
    -PickHostNameFromBackendHttpSettings 

$gwProbFiles = Get-AzApplicationGatewayProbeConfig -ApplicationGateway $gw -Name "files-storage-prob"
    
Add-AzApplicationGatewayBackendHttpSetting -ApplicationGateway $gw -Name "files-settings" `
    -Port 443 `
    -Protocol Https `
    -CookieBasedAffinity Disabled `
    -RequestTimeout 3600 `
    -PickHostNameFromBackendAddress `
    -Probe $gwProbFiles

$gwFilesBackendHttp = Get-AzApplicationGatewayBackendHttpSetting -ApplicationGateway $gw -Name "files-settings"

$gwFilesMapRole = New-AzApplicationGatewayPathRuleConfig -Name 'files-storage' `
    -Paths "/files/*" `
    -BackendAddressPool $gwFilesPool `
    -BackendHttpSettings $gwFilesBackendHttp


$pathMap = Get-AzApplicationGatewayUrlPathMapConfig -ApplicationGateway $gw -Name "bandit-front-routing"


$pathRules = $pathmap.PathRules.ToArray()
$pathRules += $gwFilesMapRole


$gwServicePool = Get-AzApplicationGatewayBackendAddressPool -Name "appservice-backendpool" -ApplicationGateway $gw 
$gwAppserviceBackendHttp = Get-AzApplicationGatewayBackendHttpSetting -Name "appservice-settings"  -ApplicationGateway $gw 
$gwMaintenanceRewriteRuleSet = Get-AzApplicationGatewayRewriteRuleSet -Name "under-maintenance-rewriteset" -ApplicationGateway $gw

$gwUrlPathMap = Set-AzApplicationGatewayUrlPathMapConfig `
        -ApplicationGateway $gw `
        -Name $pathMap.Name `
        -PathRules $pathRules `
        -DefaultBackendAddressPool $gwServicePool `
        -DefaultBackendHttpSettings $gwAppserviceBackendHttp `
        -DefaultRewriteRuleSet $gwMaintenanceRewriteRuleSet




Set-AzApplicationGateway -ApplicationGateway $gw
