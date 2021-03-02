param ($installerURL, $baseStackName, $processes="WindowsConnector", $rdsType="PostgreSQL")

Write-Host "installerURL=$installerURL"
Write-Host "baseStackName=$baseStackName"
Write-Host "processes=<$processes>"

$installerFileName = $installerURL.Substring($installerURL.LastIndexOf('/'))

Invoke-WebRequest -Uri $installerURL -OutFile "$env:TEMP\$installerFileName"

# 
# - - 'unattended-install-settings.ps1'
#   - !Ref WindowsInstallerURL
#   - !Ref BaseStackName
#   - !Ref RepositoryType
#   - !Ref PyramidProcess

# given what you want to deploy, what processes do you want to exclude?
$ProcessesToExclude = @{}
$ProcessesToExclude["Router"] = "winws,winrte,winte,winimdb,winai,windesktop,windnc"
$ProcessesToExclude["WebServer"] = "winrte,winte,winrtr,winimdb,winai,windesktop,windnc"
$ProcessesToExclude["WebServerAndRouter"] = "winrte,winte,winimdb,winai,windesktop,windnc"
$ProcessesToExclude["RuntimeEngine"] = "winws,winte,winrtr,winimdb,winai,windesktop,windnc"
$ProcessesToExclude["TaskEngine"] = "winws,winrte,winrtr,winimdb,winai,windesktop,windnc"
$ProcessesToExclude["RuntimeEngineAndTaskEngine"] = "winws,winrtr,winimdb,winai,windesktop,windnc"
$ProcessesToExclude["RuntimeEngineAndAI"] = "winws,winte,winrtr,winimdb,windesktop,windnc"
$ProcessesToExclude["TaskEngineAndAI"] = "winws,winrte,winrtr,winimdb,windesktop,windnc"
$ProcessesToExclude["RuntimeAndTaskEngineAndAI"] = "winws,winrtr,winimdb,windesktop,windnc"
$ProcessesToExclude["AIServer"] = "winws,winrte,winte,winrtr,winimdb,windeskto,windnc"
$ProcessesToExclude["InMemoryDB"] = "winws,winrte,winte,winrtr,winai,windesktop,windnc"
$ProcessesToExclude["Nothing"] = "winws,winrte,winte,winrtr,winimdb,winai,windesktop,windnc"
$ProcessesToExclude["EverythingExceptInMemoryDB"] = "winimdb,windesktop"
$ProcessesToExclude["WindowsConnector"] = "winws,winrte,winte,winrtr,winimdb,winai,windesktop"
# only Everything installs the desktop
$ProcessesToExclude["Everything"] = ""


try {
  # rdsType=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseType" --region $region --output text | cut -f 7`
  $rdsType = ( Get-SSMParameter -Name /Pyramid/$baseStackName/RepositoryDatabaseType ).Value
}
catch {
  if  ( $rdsType -eq "" ) {
    $rdsType = "PostgreSQL"
  }
}


$rdsAddress = ( Get-SSMParameter -Name /Pyramid/$baseStackName/RepositoryDatabaseAddress ).Value
$rdsPort = ( Get-SSMParameter -Name /Pyramid/$baseStackName/RepositoryDatabasePort ).Value
$rdsName = ( Get-SSMParameter -Name /Pyramid/$baseStackName/RepositoryDatabaseName ).Value
$rdsUsername = ( Get-SSMParameter -Name /Pyramid/$baseStackName/RepositoryDatabaseUsername ).Value

$rdsPassword = ( Get-SECSecretValue -SecretId /Pyramid/$baseStackName/RepositoryDatabasePassword ).SecretString

$initialUsername = ( Get-SSMParameter -Name /Pyramid/$baseStackName/InitialUsername ).Value

$initialUserPassword = ( Get-SECSecretValue -SecretId /Pyramid/$baseStackName/InitialUserPassword ).SecretString

switch ( $rdsType )
{
    "PostgreSQL" {
      $databasePrefix = "postgreSql"
      $databaseLocation = "pgLocation"
      $databaseType = "0"
    }
    "MicrosoftSQLServer" {
      $databasePrefix = "mssql"
      $databaseLocation = "msLocation"
      $databaseType = "1"
    }
    default {
      Write-Host "invalid database type <$rdsType>"
      exit 1
    }
}

Write-Host "databasePrefix = <$databasePrefix>"

$disableComponentsProperty=""
if  ( -not ( "$processes" -eq "Everything") ) {
  $disableComponentsProperty="disable-components=$($ProcessesToExclude.$processes)"
}

$preamble = @"
install-location=$env:ProgramFiles\Pyramid
data-location=$env:ProgramFiles\Pyramid\repository

$disableComponentsProperty

installation-type=1
selectCurrentRepository=$databaseType
repositoryChoice=currentremote
$databaseLocation=0
initUserName=$initialUsername
initUserPassword=$initialUserPassword
"@

$iniFile = "$env:TEMP\pyramid-unattended-install.ini"
Set-Content -Path $iniFile -Value $preamble

Add-Content -Path $iniFile -Value $("{0}Host={1}" -f $databasePrefix, $rdsAddress)
Add-Content -Path $iniFile -Value $("{0}Port={1}" -f $databasePrefix, $rdsPort)
Add-Content -Path $iniFile -Value $("{0}Db={1}" -f $databasePrefix, $rdsName)
Add-Content -Path $iniFile -Value $("{0}Username={1}" -f $databasePrefix, $rdsUsername)
Add-Content -Path $iniFile -Value $("{0}UserPassword={1}" -f $databasePrefix, $rdsPassword)
