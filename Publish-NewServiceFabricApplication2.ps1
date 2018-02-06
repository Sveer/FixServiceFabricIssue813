function Publish-NewServiceFabricApplication
{
    <#
    .SYNOPSIS 
    Publishes a new Service Fabric application type to Service Fabric cluster.

    .DESCRIPTION
    This script registers & creates a Service Fabric application.

    .NOTES
    Connection to service fabric cluster should be established by using 'Connect-ServiceFabricCluster' before invoking this cmdlet.
    WARNING: This script creates a new Service Fabric application in the cluster. If OverwriteExistingApplication switch is provided, it deletes any existing application in the cluster with the same name.

    .PARAMETER ApplicationPackagePath
    Path to the folder containing the Service Fabric application package OR path to the zipped service fabric applciation package.

    .PARAMETER ApplicationParameterFilePath
    Path to the application parameter file which contains Application Name and application parameters to be used for the application.    

    .PARAMETER ApplicationName
    Name of Service Fabric application to be created. If value for this parameter is provided alongwith ApplicationParameterFilePath it will override the Application name specified in ApplicationParameter  file.

    .PARAMETER Action
    Action which this script performs. Available Options are Register, Create, RegisterAndCreate. Default Action is RegisterAndCreate.

    .PARAMETER ApplicationParameter
    Hashtable of the Service Fabric application parameters to be used for the application. If value for this parameter is provided, it will be merged with application parameters
    specified in ApplicationParameter file. In case a parameter is found in application parameter file and on commandline, commandline parameter will override the one specified in application parameter file.

    .PARAMETER OverwriteBehavior
    Overwrite Behavior if an application exists in the cluster with the same name. Available Options are Never, Always, SameAppTypeAndVersion. 
    Never will not remove the existing application. This is the default behavior.
    Always will remove the existing application even if its Application type and Version is different from the application being created. 
    SameAppTypeAndVersion will remove the existing application only if its Application type and Version is same as the application being created.

    .PARAMETER SkipPackageValidation
    Switch signaling whether the package should be validated or not before deployment.

    .PARAMETER CopyPackageTimeoutSec
    Timeout in seconds for copying application package to image store. Default is 600 seconds.

    .PARAMETER CompressPackage
    Switch signaling whether the package should be compressed or not before deployment.

    .EXAMPLE
    Publish-NewServiceFabricApplication -ApplicationPackagePath 'pkg\Debug' -ApplicationParameterFilePath 'Local.xml'

    Registers & Creates an application with AppParameter file containing name of application and values for parameters that are defined in the application manifest.

    Publish-NewServiceFabricApplication -ApplicationPackagePath 'pkg\Debug' -ApplicationName 'fabric:/Application1'

    Registers & Creates an application with the specified application name.

    #>

    [CmdletBinding(DefaultParameterSetName="ApplicationName")]  
    Param
    (
        [Parameter(Mandatory=$true,ParameterSetName="ApplicationParameterFilePath")]
        [Parameter(Mandatory=$true,ParameterSetName="ApplicationName")]
        [String]$ApplicationPackagePath,
    
        [Parameter(Mandatory=$true,ParameterSetName="ApplicationParameterFilePath")]
        [String]$ApplicationParameterFilePath,    

        [Parameter(Mandatory=$true,ParameterSetName="ApplicationName")]
        [Parameter(ParameterSetName="ApplicationParameterFilePath")]
        [String]$ApplicationName,

        [Parameter(ParameterSetName="ApplicationParameterFilePath")]
        [Parameter(ParameterSetName="ApplicationName")]
        [ValidateSet('Register','Create','RegisterAndCreate')]
        [String]$Action = 'RegisterAndCreate',

        [Parameter(ParameterSetName="ApplicationParameterFilePath")]
        [Parameter(ParameterSetName="ApplicationName")]
        [Hashtable]$ApplicationParameter,

        [Parameter(ParameterSetName="ApplicationParameterFilePath")]
        [Parameter(ParameterSetName="ApplicationName")]
        [ValidateSet('Never','Always','SameAppTypeAndVersion')]
        [String]$OverwriteBehavior = 'Never',

        [Parameter(ParameterSetName="ApplicationParameterFilePath")]
        [Parameter(ParameterSetName="ApplicationName")]
        [Switch]$SkipPackageValidation,

        [Parameter(ParameterSetName="ApplicationParameterFilePath")]
        [Parameter(ParameterSetName="ApplicationName")]
        [int]$CopyPackageTimeoutSec = 600,

        [Parameter(ParameterSetName="ApplicationParameterFilePath")]
        [Parameter(ParameterSetName="ApplicationName")]
        [Switch]$CompressPackage
    )


    if (!(Test-Path $ApplicationPackagePath))
    {
        $errMsg = "$ApplicationPackagePath is not found."
        throw $errMsg
    }

    # Check if the ApplicationPackagePath points to a compressed package.
    if (Test-Path $ApplicationPackagePath -PathType Leaf)
    {
        if((Get-Item $ApplicationPackagePath).Extension -eq ".sfpkg")
        {
            $AppPkgPathToUse=[io.path]::combine($env:Temp, (Get-Item $ApplicationPackagePath).BaseName)
            Expand-ToFolder $ApplicationPackagePath $AppPkgPathToUse
        }
        else
        {
            $errMsg = "$ApplicationPackagePath is not a valid Service Fabric application package"
            throw $errMsg
        }
    }
    else
    {
        $AppPkgPathToUse = $ApplicationPackagePath
    }

    if ($PSBoundParameters.ContainsKey('ApplicationParameterFilePath') -and !(Test-Path $ApplicationParameterFilePath -PathType Leaf))
    {
        $errMsg = "$ApplicationParameterFilePath is not found."
        throw $errMsg
    }

    if(!$SkipPackageValidation)
    {
        $packageValidationSuccess = (Test-ServiceFabricApplicationPackage $AppPkgPathToUse)
        if (!$packageValidationSuccess)
        {
           $errMsg = "Validation failed for package: " +  $ApplicationPackagePath
           throw $errMsg
        }
    }

    $ApplicationManifestPath = "$AppPkgPathToUse\ApplicationManifest.xml"

    try
    {
        [void](Test-ServiceFabricClusterConnection)
    }
    catch
    {
        Write-Warning "Unable to Verify connection to Service Fabric cluster."
        throw
    }    

    # If ApplicationName is not specified on command line get application name from Application Parameter file.
    if(!$ApplicationName)
    {
       $ApplicationName = Get-ApplicationNameFromApplicationParameterFile $ApplicationParameterFilePath
    }

    $names = Get-NamesFromApplicationManifest -ApplicationManifestPath $ApplicationManifestPath
    if (!$names)
    {
        Write-Warning "Unable to read Application Type and Version from application manifest file."
        return
    }

    if($Action.Equals("Register") -or $Action.Equals("RegisterAndCreate"))
    {
        # Apply OverwriteBehavior if an applciation with same name already exists.
        $app = Get-ServiceFabricApplication -ApplicationName $ApplicationName
        if ($app)
        {
            $removeApp = $false
            if($OverwriteBehavior.Equals("Never"))
            {
                $errMsg = "An application with name '$ApplicationName' already exists, its Type is '$($app.ApplicationTypeName)' and Version is '$($app.ApplicationTypeVersion)'.
                You must first remove the existing application before a new application can be deployed or provide a new name for the application."
                throw $errMsg
            }

            if($OverwriteBehavior.Equals("SameAppTypeAndVersion")) 
            {
                if($app.ApplicationTypeVersion -eq $names.ApplicationTypeVersion -and $app.ApplicationTypeName -eq $names.ApplicationTypeName)
                {
                    $removeApp = $true
                }
                else
                {
                    $errMsg = "An application with name '$ApplicationName' already exists, its Type is '$($app.ApplicationTypeName)' and Version is '$($app.ApplicationTypeVersion)'.
                    You must first remove the existing application before a new application can be deployed or provide a new name for the application."
                    throw $errMsg
                }             
            }

            if($OverwriteBehavior.Equals("Always"))
            {
                $removeApp = $true
            }            

            if($removeApp)
            {
				Write-Host "An application with name '$ApplicationName' already exists in the cluster with Application Type '$($app.ApplicationTypeName)' and Version '$($app.ApplicationTypeVersion)'. Removing it."

                try
				{
				    $app | Remove-ServiceFabricApplication -Force
			    }
				catch [System.TimeoutException]
				{
					# Catch operation timeout and continue with force remove replica.
				}

                foreach ($node in Get-ServiceFabricNode)
                {
                    [void](Get-ServiceFabricDeployedReplica -NodeName $node.NodeName -ApplicationName $ApplicationName | Remove-ServiceFabricReplica -NodeName $node.NodeName -ForceRemove)
                }

                if($OverwriteBehavior.Equals("Always"))
                {                    
                    # Unregsiter AppType and Version if there are no other applciations for the Type and Version. 
                    # It will unregister the existing application's type and version even if its different from the application being created,
                    if((Get-ServiceFabricApplication | Where-Object {$_.ApplicationTypeVersion -eq $($app.ApplicationTypeVersion) -and $_.ApplicationTypeName -eq $($app.ApplicationTypeName)}).Count -eq 0)
                    {
                        Unregister-ServiceFabricApplicationType -ApplicationTypeName $($app.ApplicationTypeName) -ApplicationTypeVersion $($app.ApplicationTypeVersion) -Force
                    }
                }
            }
        }        

        $reg = Get-ServiceFabricApplicationType -ApplicationTypeName $names.ApplicationTypeName | Where-Object  { $_.ApplicationTypeVersion -eq $names.ApplicationTypeVersion }
        if ($reg)
        {
            Write-Host 'Application Type '$names.ApplicationTypeName' and Version '$names.ApplicationTypeVersion' was already registered with Cluster, unregistering it...'
            $reg | Unregister-ServiceFabricApplicationType -Force
            if(!$?)
            {
                throw "Unregistering of existing Application Type was unsuccessful."
            }
        }

        Write-Host 'Copying application to image store... Compress: '$CompressPackage
		# Get image store connection string
        $clusterManifestText = Get-ServiceFabricClusterManifest
        $imageStoreConnectionString = Get-ImageStoreConnectionStringFromClusterManifest ([xml] $clusterManifestText)

        $applicationPackagePathInImageStore = $names.ApplicationTypeName
		
		#Write-Host "-ApplicationPackagePath $AppPkgPathToUse -ImageStoreConnectionString $imageStoreConnectionString -ApplicationPackagePathInImageStore $applicationPackagePathInImageStore #-TimeOutSec $CopyPackageTimeoutSec  -ShowProgress"
        
		#-CompressPackage:$CompressPackage
        #Copy-ServiceFabricApplicationPackage -ApplicationPackagePath $AppPkgPathToUse -ImageStoreConnectionString $imageStoreConnectionString -ApplicationPackagePathInImageStore #$applicationPackagePathInImageStore -TimeOutSec $CopyPackageTimeoutSec -ShowProgress
		Write-Host "Complete Copy-ServiceFabricApplicationPackage";
		
        if(!$?)
        {
            throw "Copying of application package to image store failed. Cannot continue with registering the application."
        }

        Write-Host 'Registering application type...'
        #Register-ServiceFabricApplicationType -ApplicationPathInImageStore $applicationPackagePathInImageStore
		Register-ServiceFabricApplicationType -ApplicationPackageDownloadUri https://account.blob.core.windows.net/upload/Package.cfpkg
		#$applicationPackagePathInImageStore
        if(!$?)
        {
            throw "Registration of application type failed."
        }

        Write-Host 'Removing application package from image store...'
        Remove-ServiceFabricApplicationPackage -ApplicationPackagePathInImageStore $applicationPackagePathInImageStore -ImageStoreConnectionString $imageStoreConnectionString
    }

    if($Action.Equals("Create") -or $Action.Equals("RegisterAndCreate"))
    {
        Write-Host 'Creating application...'

        # If application parameters file is specified read values from and merge it with parameters passed on Commandline
        if ($PSBoundParameters.ContainsKey('ApplicationParameterFilePath'))
        {
           $appParamsFromFile = Get-ApplicationParametersFromApplicationParameterFile $ApplicationParameterFilePath        
           if(!$ApplicationParameter)
            {
                $ApplicationParameter = $appParamsFromFile
            }
            else
            {
                $ApplicationParameter = Merge-Hashtables -HashTableOld $appParamsFromFile -HashTableNew $ApplicationParameter
            }    
        }
    
        New-ServiceFabricApplication -ApplicationName $ApplicationName -ApplicationTypeName $names.ApplicationTypeName -ApplicationTypeVersion $names.ApplicationTypeVersion -ApplicationParameter $ApplicationParameter
        if(!$?)
        {
            throw "Creation of application failed."
        }

        Write-Host 'Create application succeeded.'
    }
}

# SIG # Begin signature block
# MIIdjwYJKoZIhvcNAQcCoIIdgDCCHXwCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUBLGIaWSbndX1KQi679hBRN+L
# ZwegghhTMIIEwjCCA6qgAwIBAgITMwAAAL+RbPt8GiTgIgAAAAAAvzANBgkqhkiG
# 9w0BAQUFADB3MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSEw
# HwYDVQQDExhNaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EwHhcNMTYwOTA3MTc1ODQ5
# WhcNMTgwOTA3MTc1ODQ5WjCBsjELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEMMAoGA1UECxMDQU9DMScwJQYDVQQLEx5uQ2lwaGVyIERTRSBFU046
# NTdDOC0yRDE1LTFDOEIxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNl
# cnZpY2UwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCt7X+GwPaidVcV
# TRT2yohV/L1dpTMCvf4DHlCY0GUmhEzD4Yn22q/qnqZTHDd8IlI/OHvKhWC9ksKE
# F+BgBHtUQPSg7s6+ZXy69qX64r6m7X/NYizeK31DsScLsDHnqsbnwJaNZ2C2u5hh
# cKsHvc8BaSsv/nKlr6+eg2iX2y9ai1uB1ySNeunEtdfchAr1U6Qb7AJHrXMTdKl8
# ptLov67aFU0rRRMwQJOWHR+o/gQa9v4z/f43RY2PnMRoF7Dztn6ditoQ9CgTiMdS
# MtsqFWMAQNMt5bZ8oY1hmgkSDN6FwTjVyUEE6t3KJtgX2hMHjOVqtHXQlud0GR3Z
# LtAOMbS7AgMBAAGjggEJMIIBBTAdBgNVHQ4EFgQU5GwaORrHk1i0RjZlB8QAt3kX
# nBEwHwYDVR0jBBgwFoAUIzT42VJGcArtQPt2+7MrsMM1sw8wVAYDVR0fBE0wSzBJ
# oEegRYZDaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljcm9zb2Z0VGltZVN0YW1wUENBLmNybDBYBggrBgEFBQcBAQRMMEowSAYIKwYB
# BQUHMAKGPGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljcm9z
# b2Z0VGltZVN0YW1wUENBLmNydDATBgNVHSUEDDAKBggrBgEFBQcDCDANBgkqhkiG
# 9w0BAQUFAAOCAQEAjt62jcZ+2YBqm7RKit827DRU9OKioi6HEERT0X0bL+JjUTu3
# 7k4piPcK3J/0cfktWuPjrYSuySa/NbkmlvAhQV4VpoWxipx3cZplF9HK9IH4t8AD
# YDxUI5u1xb2r24aExGIzWY+1uH92bzTKbAjuwNzTMQ1z10Kca4XXPI4HFZalXxgL
# fbjCkV3IKNspU1TILV0Dzk0tdKAwx/MoeZN1HFcB9WjzbpFnCVH+Oy/NyeJOyiNE
# 4uT/6iyHz1+XCqf2nIrV/DXXsJYKwifVlOvSJ4ZrV40MYucq3lWQuKERfXivLFXl
# dKyXQrS4eeToRPSevRisc0GBYuZczpkdeN5faDCCBgAwggPooAMCAQICEzMAAADD
# Dpun2LLc9ywAAAAAAMMwDQYJKoZIhvcNAQELBQAwfjELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2ln
# bmluZyBQQ0EgMjAxMTAeFw0xNzA4MTEyMDIwMjRaFw0xODA4MTEyMDIwMjRaMHQx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xHjAcBgNVBAMTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC
# ggEBALtX1zjRsQZ/SS2pbbNjn3q6tjohW7SYro3UpIGgxXXFLO+CQCq3gVN382MB
# CrzON4QDQENXgkvO7R+2/YBtycKRXQXH3FZZAOEM61fe/fG4kCe/dUr8dbJyWLbF
# SJszYgXRlZSlvzkirY0STUZi2jIZzqoiXFZIsW9FyWd2Yl0wiKMvKMUfUCrZhtsa
# ESWBwvT1Zy7neR314hx19E7Mx/znvwuARyn/z81psQwLYOtn5oQbm039bUc6x9nB
# YWHylRKhDQeuYyHY9Jkc/3hVge6leegggl8K2rVTGVQBVw2HkY3CfPFUhoDhYtuC
# cz4mXvBAEtI51SYDDYWIMV8KC4sCAwEAAaOCAX8wggF7MB8GA1UdJQQYMBYGCisG
# AQQBgjdMCAEGCCsGAQUFBwMDMB0GA1UdDgQWBBSnE10fIYlV6APunhc26vJUiDUZ
# rzBRBgNVHREESjBIpEYwRDEMMAoGA1UECxMDQU9DMTQwMgYDVQQFEysyMzAwMTIr
# YzgwNGI1ZWEtNDliNC00MjM4LTgzNjItZDg1MWZhMjI1NGZjMB8GA1UdIwQYMBaA
# FEhuZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93
# d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAx
# MS0wNy0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFf
# MjAxMS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEA
# TZdPNH7xcJOc49UaS5wRfmsmxKUk9N9E1CS6s2oIiZmayzHncJv/FB2wBzl/5DA7
# EyLeDsiVZ7tufvh8laSQgjeTpoPTSQLBrK1Z75G3p2YADqJMJdTc510HAsooNGU7
# OYOtlSqOyqDoCDoc/j57QEmUTY5UJQrlsccK7nE3xpteNvWnQkT7vIewDcA12SaH
# X/9n7yh094owBBGKZ8xLNWBqIefDjQeDXpurnXEfKSYJEdT1gtPSNgcpruiSbZB/
# AMmoW+7QBGX7oQ5XU8zymInznxWTyAbEY1JhAk9XSBz1+3USyrX59MJpX7uhnQ1p
# gyfrgz4dazHD7g7xxIRDh+4xnAYAMny3IIq5CCPqVrAY1LK9Few37WTTaxUCI8aK
# M4c60Zu2wJZZLKABU4QBX/J7wXqw7NTYUvZfdYFEWRY4J1O7UPNecd/311HcMdUa
# YzUql36fZjdfz1Uz77LKvCwjqkQe7vtnSLToQsMPilFYokYCYSZaGb9clOmoQHDn
# WzBMfIDUUGeipe4O6z218eV5HuH1WBlvu4lteOIgWCX/5Eiz5q/xskAEF0ZQ1Axs
# kRR97sri9ibeGzsEZ1EuD6QX90L/P5GJMfinvLPlOlLcKjN/SmSRZdhlEbbbare0
# bFL8v4txFsQsznOaoOldCMFFRaUphuwBMW1edMZWMQswggYHMIID76ADAgECAgph
# Fmg0AAAAAAAcMA0GCSqGSIb3DQEBBQUAMF8xEzARBgoJkiaJk/IsZAEZFgNjb20x
# GTAXBgoJkiaJk/IsZAEZFgltaWNyb3NvZnQxLTArBgNVBAMTJE1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eTAeFw0wNzA0MDMxMjUzMDlaFw0yMTA0
# MDMxMzAzMDlaMHcxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# ITAfBgNVBAMTGE1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQTCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAJ+hbLHf20iSKnxrLhnhveLjxZlRI1Ctzt0YTiQP
# 7tGn0UytdDAgEesH1VSVFUmUG0KSrphcMCbaAGvoe73siQcP9w4EmPCJzB/LMySH
# nfL0Zxws/HvniB3q506jocEjU8qN+kXPCdBer9CwQgSi+aZsk2fXKNxGU7CG0OUo
# Ri4nrIZPVVIM5AMs+2qQkDBuh/NZMJ36ftaXs+ghl3740hPzCLdTbVK0RZCfSABK
# R2YRJylmqJfk0waBSqL5hKcRRxQJgp+E7VV4/gGaHVAIhQAQMEbtt94jRrvELVSf
# rx54QTF3zJvfO4OToWECtR0Nsfz3m7IBziJLVP/5BcPCIAsCAwEAAaOCAaswggGn
# MA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFCM0+NlSRnAK7UD7dvuzK7DDNbMP
# MAsGA1UdDwQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADCBmAYDVR0jBIGQMIGNgBQO
# rIJgQFYnl+UlE/wq4QpTlVnkpKFjpGEwXzETMBEGCgmSJomT8ixkARkWA2NvbTEZ
# MBcGCgmSJomT8ixkARkWCW1pY3Jvc29mdDEtMCsGA1UEAxMkTWljcm9zb2Z0IFJv
# b3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5ghB5rRahSqClrUxzWPQHEy5lMFAGA1Ud
# HwRJMEcwRaBDoEGGP2h0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3By
# b2R1Y3RzL21pY3Jvc29mdHJvb3RjZXJ0LmNybDBUBggrBgEFBQcBAQRIMEYwRAYI
# KwYBBQUHMAKGOGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWlj
# cm9zb2Z0Um9vdENlcnQuY3J0MBMGA1UdJQQMMAoGCCsGAQUFBwMIMA0GCSqGSIb3
# DQEBBQUAA4ICAQAQl4rDXANENt3ptK132855UU0BsS50cVttDBOrzr57j7gu1BKi
# jG1iuFcCy04gE1CZ3XpA4le7r1iaHOEdAYasu3jyi9DsOwHu4r6PCgXIjUji8FMV
# 3U+rkuTnjWrVgMHmlPIGL4UD6ZEqJCJw+/b85HiZLg33B+JwvBhOnY5rCnKVuKE5
# nGctxVEO6mJcPxaYiyA/4gcaMvnMMUp2MT0rcgvI6nA9/4UKE9/CCmGO8Ne4F+tO
# i3/FNSteo7/rvH0LQnvUU3Ih7jDKu3hlXFsBFwoUDtLaFJj1PLlmWLMtL+f5hYbM
# UVbonXCUbKw5TNT2eb+qGHpiKe+imyk0BncaYsk9Hm0fgvALxyy7z0Oz5fnsfbXj
# pKh0NbhOxXEjEiZ2CzxSjHFaRkMUvLOzsE1nyJ9C/4B5IYCeFTBm6EISXhrIniIh
# 0EPpK+m79EjMLNTYMoBMJipIJF9a6lbvpt6Znco6b72BJ3QGEe52Ib+bgsEnVLax
# aj2JoXZhtG6hE6a/qkfwEm/9ijJssv7fUciMI8lmvZ0dhxJkAj0tr1mPuOQh5bWw
# ymO0eFQF1EEuUKyUsKV4q7OglnUa2ZKHE3UiLzKoCG6gW4wlv6DvhMoh1useT8ma
# 7kng9wFlb4kLfchpyOZu6qeXzjEp/w7FW1zYTRuh2Povnj8uVRZryROj/TCCB3ow
# ggVioAMCAQICCmEOkNIAAAAAAAMwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTExMDcwODIwNTkwOVoX
# DTI2MDcwODIxMDkwOVowfjELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKvw+nIQHC6t2G6qghBNNLry
# tlghn0IbKmvpWlCquAY4GgRJun/DDB7dN2vGEtgL8DjCmQawyDnVARQxQtOJDXlk
# h36UYCRsr55JnOloXtLfm1OyCizDr9mpK656Ca/XllnKYBoF6WZ26DJSJhIv56sI
# UM+zRLdd2MQuA3WraPPLbfM6XKEW9Ea64DhkrG5kNXimoGMPLdNAk/jj3gcN1Vx5
# pUkp5w2+oBN3vpQ97/vjK1oQH01WKKJ6cuASOrdJXtjt7UORg9l7snuGG9k+sYxd
# 6IlPhBryoS9Z5JA7La4zWMW3Pv4y07MDPbGyr5I4ftKdgCz1TlaRITUlwzluZH9T
# upwPrRkjhMv0ugOGjfdf8NBSv4yUh7zAIXQlXxgotswnKDglmDlKNs98sZKuHCOn
# qWbsYR9q4ShJnV+I4iVd0yFLPlLEtVc/JAPw0XpbL9Uj43BdD1FGd7P4AOG8rAKC
# X9vAFbO9G9RVS+c5oQ/pI0m8GLhEfEXkwcNyeuBy5yTfv0aZxe/CHFfbg43sTUkw
# p6uO3+xbn6/83bBm4sGXgXvt1u1L50kppxMopqd9Z4DmimJ4X7IvhNdXnFy/dygo
# 8e1twyiPLI9AN0/B4YVEicQJTMXUpUMvdJX3bvh4IFgsE11glZo+TzOE2rCIF96e
# TvSWsLxGoGyY0uDWiIwLAgMBAAGjggHtMIIB6TAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUSG5k5VAF04KqFzc3IrVtqMp1ApUwGQYJKwYBBAGCNxQCBAweCgBT
# AHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgw
# FoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDov
# L2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0
# MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKG
# Qmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0
# MjAxMV8yMDExXzAzXzIyLmNydDCBnwYDVR0gBIGXMIGUMIGRBgkrBgEEAYI3LgMw
# gYMwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# ZG9jcy9wcmltYXJ5Y3BzLmh0bTBABggrBgEFBQcCAjA0HjIgHQBMAGUAZwBhAGwA
# XwBwAG8AbABpAGMAeQBfAHMAdABhAHQAZQBtAGUAbgB0AC4gHTANBgkqhkiG9w0B
# AQsFAAOCAgEAZ/KGpZjgVHkaLtPYdGcimwuWEeFjkplCln3SeQyQwWVfLiw++MNy
# 0W2D/r4/6ArKO79HqaPzadtjvyI1pZddZYSQfYtGUFXYDJJ80hpLHPM8QotS0LD9
# a+M+By4pm+Y9G6XUtR13lDni6WTJRD14eiPzE32mkHSDjfTLJgJGKsKKELukqQUM
# m+1o+mgulaAqPyprWEljHwlpblqYluSD9MCP80Yr3vw70L01724lruWvJ+3Q3fMO
# r5kol5hNDj0L8giJ1h/DMhji8MUtzluetEk5CsYKwsatruWy2dsViFFFWDgycSca
# f7H0J/jeLDogaZiyWYlobm+nt3TDQAUGpgEqKD6CPxNNZgvAs0314Y9/HG8VfUWn
# duVAKmWjw11SYobDHWM2l4bf2vP48hahmifhzaWX0O5dY0HjWwechz4GdwbRBrF1
# HxS+YWG18NzGGwS+30HHDiju3mUv7Jf2oVyW2ADWoUa9WfOXpQlLSBCZgB/QACnF
# sZulP0V3HjXG0qKin3p6IvpIlR+r+0cjgPWe+L9rt0uX4ut1eBrs6jeZeRhL/9az
# I2h15q/6/IvrC4DqaTuv/DDtBEyO3991bWORPdGdVk5Pv4BXIqF4ETIheu9BCrE/
# +6jMpF3BoYibV3FWTkhFwELJm3ZbCoBIa/15n8G9bW1qyVJzEw16UM0xggSmMIIE
# ogIBATCBlTB+MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgw
# JgYDVQQDEx9NaWNyb3NvZnQgQ29kZSBTaWduaW5nIFBDQSAyMDExAhMzAAAAww6b
# p9iy3PcsAAAAAADDMAkGBSsOAwIaBQCggbowGQYJKoZIhvcNAQkDMQwGCisGAQQB
# gjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkE
# MRYEFECokcRZcc+w8hDz6ObtPZJhdRAoMFoGCisGAQQBgjcCAQwxTDBKoCSAIgBN
# AGkAYwByAG8AcwBvAGYAdAAgAFcAaQBuAGQAbwB3AHOhIoAgaHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3dpbmRvd3MwDQYJKoZIhvcNAQEBBQAEggEAjt8AHahJJWKY
# 0Tq7jPIags99iFo/y/RSWFcL43rOUS79GfEFOTeWElmS2sLmDa/KEla6qLUiyGON
# M91zt2+4MzRslaS0m3FbNN320EGZ50biA4PdlPGc9IGy+5LDZCmzb6L9EY7jniiv
# HiXUVv2GgBYQVpt0k2t4qdCNsY9KCijUSpxsKIBahFCemd8OQo5fFjeHpzm4BbPD
# lwA6ZK3v4z/ss0yR8Y1lcr0XAzEzDjDsnwH2dahNBHO3sex/mmBqpjc/SluonTum
# d83rUZj7iLi0kRSvooqzdxkw8XW/w28glMzEZe3/v9RWKoRRHhV/KpHXZQZ4DjrV
# FxHIhPd1jaGCAigwggIkBgkqhkiG9w0BCQYxggIVMIICEQIBATCBjjB3MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSEwHwYDVQQDExhNaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0ECEzMAAAC/kWz7fBok4CIAAAAAAL8wCQYFKw4DAhoF
# AKBdMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTE4
# MDEyMjIzMzQxMVowIwYJKoZIhvcNAQkEMRYEFJWq6h97tQ9k8U8XT7lOTTjyhWwK
# MA0GCSqGSIb3DQEBBQUABIIBAAK+QDpMkkkVsv7TzfH++QM2uRJi8QS6UKFeymzQ
# hiA6XTpX5KEX2I5ssBYKYT8zJ6RcKiTzMt0SrB0P1NfyGf6gDydM8JAIgH74aDhx
# KsLjcYocmIvNBJ98VVxPZ3p6Kad0RMqSmkytrSh3q6msqoRem+xYn/UNkX9amuRq
# ZKCNM9qrz43nHj0YzAGPjpWKxLqqR2Ln1j4fVuOBRtnWfSigfRpdWllDxLbRCOwI
# XTC4NwxnEhbNSSw0pTqUsB+mHFHGPWW6cKvdkq2DbcHsCy3wSi1cZwSS3gIxW56+
# XoZxUXnHiON/Aj3A/79NZPkqQ2LGscMwbbGuw9yGdxt4mUU=
# SIG # End signature block
