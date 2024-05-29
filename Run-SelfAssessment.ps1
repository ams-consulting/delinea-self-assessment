#############################################################
# Run-SelfAssessment: Export and analyse Server Suite data  #
#############################################################

<#
.SYNOPSIS
    Run Delinea Server Suite Self Assessment.
.DESCRIPTION
    This script returns status and details of Delinea Server Suite deployment.
.PARAMETER Domain
    Specify AD Domain name.
.PARAMETER Credentials
    PSCredential object to be used for AD Authentication.
.INPUTS
None. You cannot pipe objects to Get-ScheduledTasks
.OUTPUTS
System.Object. Get-ScheduledTasks returns an object representing the Scheduled Tasks configuration details.
.Example
PS> Run-DelineaSelfAssessment -Credentials (Get-Credential)
.Link
Set-ScheduledTasks
#>

param (
	[Parameter(Mandatory = $false, HelpMessage = "Specify AD Domain name.")]
	[String]$Domain = (Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem).Domain,

	[Parameter(Mandatory = $false, HelpMessage = "Specify Domain Controller server name.")]
	[String]$Server,

	[Parameter(Mandatory = $false, HelpMessage = "PSCredential object to be used for AD Authentication.")]
	[PSCredential]$Credentials,

	[Parameter(Mandatory = $false, HelpMessage = "Run Agents diagnostics only.")]
	[Switch]$AgentsOnly    
)

### FUNCTIONS
# Write-Log
# Description: write logs output to .\log folder into eiher messages or secure logs
# Input      : take various parameters to specify log type and qualify and write message
# Output     : no output
function Write-Log([String]$Type, [String]$Process, [String]$Level, [String]$Message) {
    # Check log folder exists
    $CurrentFolder = Split-Path -Path $PSCommandPath
    $LogFolder = ("{0}\log" -f $CurrentFolder)
    if (-not (Test-Path -Path $LogFolder)) {
        # Create log folder
        New-Item -Path $CurrentFolder -Name "log" -Type Directory | Out-Null
    }
    # Determine log file from script name
    $LogFile = ("{0}\{1}.log" -f $LogFolder, $Type.ToLower())
    # Use UTC timestamp
    $Timestamp = [Datetime]::Now.ToUniversalTime().ToString('u')
    # Write event to log
    ("{0} {1} {2}[{3}] {4}" -f $Timestamp, $Domain, $Process, $Level, $Message) | Out-File -FilePath $LogFile -Append
}

# Import-Cache
# Description: read .dat cache files from .\data folder and return data from it
# Input      : cache file name to load
# Output     : data from cache file
function Import-Cache([String]$Name) {
    # Get data folder
    $CurrentFolder = Split-Path -Path $PSCommandPath
    $DataFolder = ("{0}\data" -f $CurrentFolder)
    # Remove any temporary file existing from aborted run
    $TempFile = ("{0}\{1}.tmp" -f $DataFolder, $Name)
    if (Test-Path -Path $TempFile) {
        # Find existing temporary file
        Write-Log -Type "Message" -Process "Import-Cache" -Level "WARN" -Message ("Deleting existing temporary file {0}" -f $TempFile)
        # Remove temporary file
        Remove-Item -Path $TempFile
    }
    # Check if cache file exists
    $CacheFile = ("{0}\{1}.dat" -f $DataFolder, $Name)
    if (Test-Path -Path $CacheFile) {
        Write-Log -Type "Message" -Process "Get-Zones" -Level "INFO" -Message ("Get Centrify data from File {0}" -f $CacheFile)
        # Rename cache into compressed archive
        $CompressedFile = ("{0}\{1}.zip" -f $DataFolder, $Name)
        Move-Item -Path $CacheFile -Destination $CompressedFile
        # Expand cache file
        Expand-Archive -Path $CompressedFile -DestinationPath $DataFolder
        # Rename back compressed archive into cache
        Move-Item -Path $CompressedFile -Destination $CacheFile
        # Load data from cache
        $Data = @()
        (Get-Content $TempFile) -Replace 'ObjectGuid', 'ObjectGUID' | ConvertFrom-Json | ForEach-Object {
            # Adding cache data to collection
            $Data += $_
        }
        # Remove temporary file
        Remove-Item -Path $TempFile
    } else {
        # No cache file
        $Data = $false
    }
    # Return data
    return $Data
}

# Export-Cache
# Description: either store data into temporary cache file or write .dat cache files from temporary file
# Input      : cache file name and optional data if writing temporary cache file
# Output     : no output
function Export-Cache([String]$Name, [Array]$Data) {
    # Check data folder exists
    $CurrentFolder = Split-Path -Path $PSCommandPath
    $DataFolder = ("{0}\data" -f $CurrentFolder)
    if (-not (Test-Path -Path $DataFolder)) {
        # Create data folder
        New-Item -Path $CurrentFolder -Name "data" -Type Directory | Out-Null
    }
    # Write data into temporary file, or compress into final cache file
    $TempFile = ("{0}\{1}.tmp" -f $DataFolder, $Name)
    if ($Data) {
        # Write data into temporary file
        $Data | ConvertTo-Json -Depth 3 -Compress | Out-File -FilePath $TempFile
    } else {
        # Compress temporary file
        $CompressedFile = ("{0}\{1}.zip" -f $DataFolder, $Name)
        Compress-Archive -Path $TempFile -DestinationPath $CompressedFile
        # Rename compressed file
        $CacheFile = ("{0}\{1}.dat" -f $DataFolder, $Name)
        Move-Item -Path $CompressedFile -Destination $CacheFile
        # Remove temporary file
        Remove-Item -Path $TempFile
    }
}

# Get-Zones
# Description: get all Zones from AD domain
# Input      : domain name to get Zones from
# Output     : collection of Zones from the domain
function Get-Zones([String]$Domain) {
    # Cache management
    $File = ("{0}-Zones" -f $Domain)
    # Import data from cache
    $Zones = Import-Cache -Name $File
    if (-not $Zones) {
        # Get Centrify Zones from Domain
        Write-Log -Type "Message" -Process "Get-Zones" -Level "INFO" -Message ("Get Centrify Zones from Domain {0}" -f $Domain)
        $Zones = Get-CdmZone -Domain $Domain
        if ($Zones) {
            # Export data to cache
            Write-Log -Type "Message" -Process "Get-Zones" -Level "INFO" -Message ("Export {0} Centrify Zones to File {1}" -f $Zones.Count, $File)
            Export-Cache -Name $File -Data $Zones
            # Export temporary file
            Export-Cache -Name $File
        }
        else {
            # No data found
            Write-Log -Type "Message" -Process "Get-Zones" -Level "WARN" -Message ("No Centrify Zones data found from Domain {0}" -f $Domain)
        }
    }
    # Return data
    return $Zones
}

# Get-Computers
# Description: get all Computers from a collection of Zones
# Input      : collection of Zones
# Output     : collection of Computers
function Get-Computers([Array]$Zones) {
    # Cache management
    $File = ("{0}-Computers" -f $Domain)
    # Import data from cache
    $Computers = Import-Cache -Name $File
    if (-not $Computers) {
        # Get All Computers
        $Computers = @()
        $Index = 1
        $Zones | ForEach-Object {
            # Get Centrify Computers from Domain
            Write-Log -Type "Message" -Process "Get-Computers" -Level "INFO" -Message ("Get Centrify Computers from Zone {0}" -f $_.CanonicalName)
            Write-Progress -Activity "Data import" -Status ("Get Computers from Zone {0} of {1}" -f $Index, $Zones.Count) -PercentComplete (($Index/($Zones.Count))*100) -Id 1 -ParentId 0
            $ZoneComputers = Get-CdmManagedComputer -Zone $_.DistinguishedName
            if ($ZoneComputers) {
                # Export data to temp file
                Write-Log -Type "Message" -Process "Get-Computers" -Level "INFO" -Message ("Export {0} Centrify Computers from Zone {1}" -f $Computers.Count, $_.CanonicalName)
                Export-Cache -Name $File -Data $ZoneComputers
                # Add data to array
                $Computers += $ZoneComputers
            } else {
                # No data found
                Write-Log -Type "Message" -Process "Get-Computers" -Level "WARN" -Message ("No Centrify Computers data found from Zone {0}" -f $_.CanonicalName)
            }
            # Increment Progress bar
            $Index++
        }
        # Report total exported
        if (($Computers | Measure-Object).Count -gt 0) {
            Write-Log -Type "Message" -Process "Get-Computers" -Level "INFO" -Message ("Export {0} Centrify Computers to File {1}" -f ($Computers | Measure-Object).Count, $File)
            # Export temporary file
            Export-Cache -Name $File
        } else {
            # No data found
            Write-Log -Type "Message" -Process "Get-Computers" -Level "INFO" -Message ("No Centrify Computers to export to File {0}" -f $File)
        }
    }
    # Return data
    return $Computers
}

# Get-ADComputers
# Description: get all AD Computer accounts from a collection of Computers
# Input      : collection of Computers
# Output     : collection of AD Computer accounts
function Get-ADComputers([Array]$Computers) {
    # Cache management
    $File = ("{0}-ADComputers" -f $Domain)
    # Import data from cache
    $ADComputers = Import-Cache -Name $File
    if (-not $ADComputers) {
        # Get All AD Computers
        $ADComputers = @()
        $Index = 1
        foreach ($Computer in ($Computers | Where-Object { -not $_.IsOrphan }).Computer) {
            # Get AD Computer object
            Write-Log -Type "Message" -Process "Get-ADComputers" -Level "INFO" -Message ("Get AD Computer {0} from Domain {1}" -f $Computer.Name, $Computer.Domain)
            Write-Progress -Activity "Data import" -Status ("Get AD object from Computers {0} of {1}" -f $Index, $Computers.Count) -PercentComplete (($Index/($Computers.Count))*100) -Id 1 -ParentId 0
            try {
                if (-not [String]::IsNullOrEmpty($Credentials)) {
                    # Use given credentials
                    $ADComputer = Get-ADComputer -Identity $Computer.DistinguishedName -Properties LastLogonTimestamp -Server $Server -Credential $Credentials
                } else {
                    # Use default credentials
                    $ADComputer = Get-ADComputer -Identity $Computer.DistinguishedName -Properties LastLogonTimestamp -Server $Server
                }
            } catch {
                if ($_.Exception.Message -match "Either the target name is incorrect or the server has rejected the client credentials.") {
                    # Credentials error connecting AD domain. Breaking back to main.
                    Write-Log -Type "Secure" -Process "Get-ADComputers" -Level "ERROR" -Message ("Connection to AD Domain {0} using credentials '{1}' failed." -f $Domain, $User)
                    Break
                } else {
                    # Unhandled exception
                    Throw $_.Exception
                    Exit 1
                }
            }
            if ($ADComputer) {
                # Export data to temp file
                Export-Cache -Name $File -Data $ADComputer
                # Add data to array
                $ADComputers += $ADComputer 
            } else {
                # No data found
                Write-Log -Type "Message" -Process "Get-ADComputers" -Level "WARN" -Message ("No AD Computer data found using Identity {0}" -f $Computer.DistinguishedName)
            }
            # Increment Progress bar
            $Index++
        }
        # Report total exported
        if (($ADComputers | Measure-Object).Count -gt 0) {
            Write-Log -Type "Message" -Process "Get-ADComputers" -Level "INFO" -Message ("Export {0} AD Computers to File {1}" -f ($ADComputers | Measure-Object).Count, $File)
            # Export temporary file
            Export-Cache -Name $File
        } else {
            Write-Log -Type "Message" -Process "Get-ADComputers" -Level "INFO" -Message ("No AD Computers to export to File {0}" -f $File)
        }
    }
    # Return data
    return $ADComputers
}

# Get-ExpiredComputers
# Description: get all AD Computers that have AD password expired (above 60 days)
# Input      : collection of AD Computer accounts
# Output     : collection of AD Computer accounts
function Get-ExpiredComputers([Array]$ADComputers) {
    # Look for AD Computers that have a last logon above 60 days (Computer password is considererd expired after 30 days but can be changed by Computer before 60 days, after what secure channel connection will be broken)
    Write-Log -Type "Message" -Process "Get-ExpiredComputers" -Level "INFO" -Message ("Get AD Computers with LastLogonTimestamp value above 60 days from now")
    $ExpiredComputers = $ADComputers | Where-Object { ([DateTime]::FromFileTime($ADComputer.LastLogonTimestamp) -lt [DateTime]::Now.AddDays(-60)) }
    # Return data
    return $ExpiredComputers
}

# Get-ComputerRoles
# Description: get all ComputerRoles from a collection of Zones
# Input      : collection of Zones
# Output     : collection of ComputerRoles
function Get-ComputerRoles([Array]$Zones) {
    # Cache management
    $File = ("{0}-ComputerRoles" -f $Domain)
    # Import data from cache
    $ComputerRoles = Import-Cache -Name $File
    if (-not $ComputerRoles) {
        # Get All ComputerRoles
        $ComputerRoles = @()
        $Index = 1
        $Zones | ForEach-Object {
            # Get Centrify ComputerRoles from Domain
            Write-Log -Type "Message" -Process "Get-ComputerRoles" -Level "INFO" -Message ("Get Centrify ComputerRoles from Zone {0}" -f $_.CanonicalName)
            Write-Progress -Activity "Data import" -Status ("Get ComputerRoles from Zone {0} of {1}" -f $Index, $Zones.Count) -PercentComplete (($Index/($Zones.Count))*100) -Id 1 -ParentId 0
            $ZoneComputerRoles = Get-CdmComputerRole -Zone $_.DistinguishedName
            if ($ZoneComputerRoles) {
                # Export data to temp file
                Write-Log -Type "Message" -Process "Get-ComputerRoles" -Level "INFO" -Message ("Export {0} Centrify ComputerRoles from Zone {1}" -f $ComputerRoles.Count, $_.CanonicalName)
                Export-Cache -Name $File -Data $ZoneComputerRoles
                # Add data to array
                $ComputerRoles += $ZoneComputerRoles
            }
            else {
                # No data found
                Write-Log -Type "Message" -Process "Get-ComputerRoles" -Level "WARN" -Message ("No Centrify ComputerRoles data found from Zone {0}" -f $_.CanonicalName)
            }
            # Increment Progress bar
            $Index++
        }
        # Report total exported
        if (($ComputerRoles | Measure-Object).Count -gt 0) {
            Write-Log -Type "Message" -Process "Get-ComputerRoles" -Level "INFO" -Message ("Export {0} Centrify ComputerRoles to File {1}" -f ($ComputerRoles | Measure-Object).Count, $File)
            # Export temporary file
            Export-Cache -Name $File
        } else {
            Write-Log -Type "Message" -Process "Get-ComputerRoles" -Level "INFO" -Message ("No Centrify ComputerRoles to export to File {0}" -f $File)
        }
    }
    # Return data
    return $ComputerRoles
}


# Get-UserProfiles
# Description: get all User Profiles from a collection of Zones and Computers
# Input      : collection of Zones and Computers
# Output     : collection of UserProfiles
function Get-UserProfiles([Array]$Zones, [Array]$Computers) {
    # Cache management
    $File = ("{0}-UserProfiles" -f $Domain)
    # Import data from cache
    $UserProfiles = Import-Cache -Name $File
    if (-not $UserProfiles) {
        # Get All UserProfiles
        $UserProfiles = @()
        # Process Zones
        if ($Zones) {
            $Index = 1
            $Zones | ForEach-Object {
                # Get Centrify User Profiles from Zones
                Write-Log -Type "Message" -Process "Get-UserProfiles" -Level "INFO" -Message ("Get Centrify User Profiles from Zone {0}" -f $_.CanonicalName)
                Write-Progress -Activity "Data import" -Status ("Get User Profiles from Zone {0} of {1}" -f $Index, $Zones.Count) -PercentComplete (($Index/($Zones.Count))*100) -Id 1 -ParentId 0
                $ZoneUserProfiles = Get-CdmUserProfile -Zone $_.DistinguishedName
                if ($ZoneUserProfiles) {
                    # Export data to temp file
                    Write-Log -Type "Message" -Process "Get-UserProfiles" -Level "INFO" -Message ("Export {0} Centrify User Profiles from Zone {1}" -f $ZoneUserProfiles.Count, $_.CanonicalName)
                    Export-Cache -Name $File -Data $ZoneUserProfiles
                    # Add data to array
                    $UserProfiles += $ZoneUserProfiles
                }
                else {
                    # No data found
                    Write-Log -Type "Message" -Process "Get-UserProfiles" -Level "WARN" -Message ("No Centrify User Profiles data found from Zone {0}" -f $_.CanonicalName)
                }
                # Increment Progress bar
                $Index++
            }
        }
        # Process Computers
        if ($Computers) {
            $Index = 1
            $Computers | ForEach-Object {
                # Get Centrify User Profiles from Computers
                Write-Log -Type "Message" -Process "Get-UserProfiles" -Level "INFO" -Message ("Get Centrify User Profiles from Computer {0}" -f $_.Name)
                Write-Progress -Activity "Data import" -Status ("Get User Profiles from Computer {0} of {1}" -f $Index, $Computers.Count) -PercentComplete (($Index/($Computers.Count))*100) -Id 1 -ParentId 0
                if ($Computers.IsWindows) {
                    # Cannot get profiles from Windows computer
                    Write-Log -Type "Message" -Process "Get-UserProfiles" -Level "WARN" -Message ("Skipping Centrify User Profiles from Windows Computer {0}" -f $_.Name)
                } else {
                    # Getting Computer on the fly to make sure to pass a CdmManagedComputer object to Cmdlet
                    $ComputerUserProfiles = Get-CdmUserProfile -Computer (Get-CdmManagedComputer -Zone $_.Zone.DistinguishedName -Name $_.Name)
                    if ($ComputerUserProfiles) {
                        # Export data to temp file
                        Write-Log -Type "Message" -Process "Get-UserProfiles" -Level "INFO" -Message ("Export {0} Centrify User Profiles from Computer {1}" -f $ComputerUserProfiles.Count, $_.Name)
                        Export-Cache -Name $File -Data $ComputerUserProfiles
                        # Add data to array
                        $UserProfiles += $ComputerUserProfiles
                    }
                    else {
                        # No data found
                        Write-Log -Type "Message" -Process "Get-UserProfiles" -Level "WARN" -Message ("No Centrify User Profiles data found from Computer {0}" -f $_.Name)
                    }
                }
                # Increment Progress bar
                $Index++
            }
        }
        # Report total exported
        if (($UserProfiles | Measure-Object).Count -gt 0) {
            Write-Log -Type "Message" -Process "Get-UserProfiles" -Level "INFO" -Message ("Export {0} Centrify User Profiles to File {1}" -f ($UserProfiles | Measure-Object).Count, $File)
            # Export temporary file
            Export-Cache -Name $File
        } else {
            Write-Log -Type "Message" -Process "Get-UserProfiles" -Level "INFO" -Message ("No Centrify User Profiles to export to File {0}" -f $File)
        }
    }
    # Return data
    return $UserProfiles
}

# Get-GroupProfiles
# Description: get all Group Profiles from a collection of Zones and Computers
# Input      : collection of Zones and Computers
# Output     : collection of GroupProfiles
function Get-GroupProfiles([Array]$Zones, [Array]$Computers) {
    # Cache management
    $File = ("{0}-GroupProfiles" -f $Domain)
    # Import data from cache
    $GroupProfiles = Import-Cache -Name $File
    if (-not $GroupProfiles) {
        # Get All GroupProfiles
        $GroupProfiles = @()
        # Process Zones
        if ($Zones) {
            $Index = 1
            $Zones | ForEach-Object {
                # Get Centrify Group Profiles from Zones
                Write-Log -Type "Message" -Process "Get-GroupProfiles" -Level "INFO" -Message ("Get Centrify Group Profiles from Zone {0}" -f $_.CanonicalName)
                Write-Progress -Activity "Data import" -Status ("Get Group Profiles from Zone {0} of {1}" -f $Index, $Zones.Count) -PercentComplete (($Index/($Zones.Count))*100) -Id 1 -ParentId 0
                $ZoneGroupProfiles = Get-CdmGroupProfile -Zone $_.DistinguishedName
                if ($ZoneGroupProfiles) {
                    # Export data to temp file
                    Write-Log -Type "Message" -Process "Get-GroupProfiles" -Level "INFO" -Message ("Export {0} Centrify Group Profiles from Zone {1}" -f $ZoneGroupProfiles.Count, $_.CanonicalName)
                    Export-Cache -Name $File -Data $ZoneGroupProfiles
                    # Add data to array
                    $GroupProfiles += $ZoneGroupProfiles
                }
                else {
                    # No data found
                    Write-Log -Type "Message" -Process "Get-GroupProfiles" -Level "WARN" -Message ("No Centrify Group Profiles data found from Zone {0}" -f $_.CanonicalName)
                }
                # Increment Progress bar
                $Index++
            }
        }
        # Process Computers
        if ($Computers) {
            $Index = 1
            $Computers | ForEach-Object {
                # Get Centrify Group Profiles from Computers
                Write-Log -Type "Message" -Process "Get-GroupProfiles" -Level "INFO" -Message ("Get Centrify Group Profiles from Computer {0}" -f $_.Name)
                Write-Progress -Activity "Data import" -Status ("Get Group Profiles from Computer {0} of {1}" -f $Index, $Computers.Count) -PercentComplete (($Index/($Computers.Count))*100) -Id 1 -ParentId 0
                if ($Computers.IsWindows) {
                    # Cannot get profiles from Windows computer
                    Write-Log -Type "Message" -Process "Get-GroupProfiles" -Level "WARN" -Message ("Skipping Centrify Group Profiles from Windows Computer {0}" -f $_.Name)
                } else {
                    # Getting Computer on the fly to make sure to pass a CdmManagedComputer object to Cmdlet
                    $ComputerGroupProfiles = Get-CdmGroupProfile -Computer (Get-CdmManagedComputer -Zone $_.Zone.DistinguishedName -Name $_.Name)
                    if ($ComputerGroupProfiles) {
                        # Export data to temp file
                        Write-Log -Type "Message" -Process "Get-GroupProfiles" -Level "INFO" -Message ("Export {0} Centrify Group Profiles from Computer {1}" -f $ComputerGroupProfiles.Count, $_.Name)
                        Export-Cache -Name $File -Data $ComputerGroupProfiles
                        # Add data to array
                        $GroupProfiles += $ComputerGroupProfiles
                    }
                    else {
                        # No data found
                        Write-Log -Type "Message" -Process "Get-GroupProfiles" -Level "WARN" -Message ("No Centrify Group Profiles data found from Computer {0}" -f $_.Name)
                    }
                }
                # Increment Progress bar
                $Index++
            }
        }
        # Report total exported
        if (($GroupProfiles | Measure-Object).Count -gt 0) {
            Write-Log -Type "Message" -Process "Get-UserProfiles" -Level "INFO" -Message ("Export {0} Centrify Group Profiles to File {1}" -f ($GroupProfiles | Measure-Object).Count, $File)
            # Export temporary file
            Export-Cache -Name $File
        } else {
            Write-Log -Type "Message" -Process "Get-GroupProfiles" -Level "INFO" -Message ("No Centrify Group Profiles to export to File {0}" -f $File)
        }
    }
    # Return data
    return $GroupProfiles
}

# Get-RoleAssignments
# Description: get all RoleAssignments from a collection of Zones, ComputerRoles and Computers
# Input      : collection of Zones, ComputerRoles and Computers
# Output     : collection of RoleAssignements
function Get-RoleAssignments([Array]$Zones, [Array]$ComputerRoles, [Array]$Computers) {
    # Cache management
    $File = ("{0}-RoleAssignments" -f $Domain)
    # Import data from cache
    $RoleAssignments = Import-Cache -Name $File
    if (-not $RoleAssignments) {
        # Get All RoleAssignments
        $RoleAssignments = @()
        # Process Zones
        if ($Zones) {
            $Index = 1
            $Zones | ForEach-Object {
                # Get Centrify RoleAssignments from Zones
                Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "INFO" -Message ("Get Centrify RoleAssignments from Zone {0}" -f $_.CanonicalName)
                Write-Progress -Activity "Data import" -Status ("Get RoleAssignments from Zone {0} of {1}" -f $Index, $Zones.Count) -PercentComplete (($Index/($Zones.Count))*100) -Id 1 -ParentId 0
                $ZoneRoleAssignments = Get-CdmRoleAssignment -Zone $_.DistinguishedName
                if ($ZoneRoleAssignments) {
                    # Export data to temp file
                    Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "INFO" -Message ("Export {0} Centrify RoleAssignments from Zone {1}" -f $ZoneRoleAssignments.Count, $_.CanonicalName)
                    Export-Cache -Name $File -Data $ZoneRoleAssignments
                    # Add data to array
                    $RoleAssignments += $ZoneRoleAssignments
                }
                else {
                    # No data found
                    Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "WARN" -Message ("No Centrify RoleAssignments data found from Zone {0}" -f $_.CanonicalName)
                }
                # Increment Progress bar
                $Index++
            }
        }
        # Process Computer Roles
        if ($ComputerRoles) {
            $Index = 1
            $ComputerRoles | ForEach-Object {
                # Get Centrify RoleAssignments from ComputerRoles
                Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "INFO" -Message ("Get Centrify RoleAssignments from ComputerRole {0} in Zone {1}" -f $_.Name, $_.Zone.CanonicalName)
                Write-Progress -Activity "Data import" -Status ("Get RoleAssignments from ComputerRole {0} of {1}" -f $Index, $ComputerRoles.Count) -PercentComplete (($Index/($ComputerRoles.Count))*100) -Id 1 -ParentId 0
                # Getting ComputerRole on the fly to make sure to pass a ComputerRole object to Cmdlet
                $ComputerRole = Get-CdmComputerRole -Zone $_.Zone.DistinguishedName -Name $_.Name
                if ($ComputerRole.GetType().BaseType -eq [System.Array]) {
                    # Found more than one Computer Role with the same name
                    Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "ERROR" -Message ("Centrify ComputerRole {0} is duplicated in Zone {1}" -f $_.Name, $_.Zone.CanonicalName)
                    $ComputerRole = $ComputerRole[0]
                } 
                $ComputerRoleRoleAssignments = Get-CdmRoleAssignment -ComputerRole $ComputerRole
                if ($ComputerRoleRoleAssignments) {
                    # Export data to temp file
                    Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "INFO" -Message ("Export {0} Centrify RoleAssignments from ComputerRole {1} in Zone {2}" -f $ComputerRoleRoleAssignments.Count, $_.Name, $_.Zone.CanonicalName)
                    Export-Cache -Name $File -Data $ComputerRoleRoleAssignments
                    # Add data to array
                    $RoleAssignments += $ComputerRoleRoleAssignments
                }
                else {
                    # No data found
                    Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "WARN" -Message ("No Centrify RoleAssignments data found from ComputerRole {1} in Zone {2}" -f $ComputerRoleRoleAssignments.Count, $_.Name, $_.Zone.CanonicalName)
                }
                # Increment Progress bar
                $Index++
            }
        }
        # Process Computers
        if ($Computers) {
            $Index = 1
            $Computers | ForEach-Object {
                # Get Centrify RoleAssignments from Computers
                Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "INFO" -Message ("Get Centrify RoleAssignments from Computer {0}" -f $_.Name)
                Write-Progress -Activity "Data import" -Status ("Get RoleAssignments from Computer {0} of {1}" -f $Index, $Computers.Count) -PercentComplete (($Index/($Computers.Count))*100) -Id 1 -ParentId 0
                # Getting Computer on the fly to make sure to pass a CdmManagedComputer object to Cmdlet
                $ComputerRoleAssignments = Get-CdmRoleAssignment -Computer (Get-CdmManagedComputer -Zone $_.Zone.DistinguishedName -Name $_.Name)
                if ($ComputerRoleAssignments) {
                    # Export data to temp file
                    Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "INFO" -Message ("Export {0} Centrify RoleAssignments from Computer {1}" -f $ComputerRoleAssignments.Count, $_.Name)
                    Export-Cache -Name $File -Data $ComputerRoleAssignments
                    # Add data to array
                    $RoleAssignments += $ComputerRoleAssignments
                }
                else {
                    # No data found
                    Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "WARN" -Message ("No Centrify RoleAssignments data found from Computer {0}" -f $_.Name)
                }
                # Increment Progress bar
                $Index++
            }
        }
        # Report total exported
        if (($RoleAssignments | Measure-Object).Count -gt 0) {
            Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "INFO" -Message ("Export {0} Centrify RoleAssignments to File {1}" -f ($RoleAssignments | Measure-Object).Count, $File)
            # Export temporary file
            Export-Cache -Name $File
        } else {
            Write-Log -Type "Message" -Process "Get-RoleAssignments" -Level "INFO" -Message ("No Centrify RoleAssignments to export to File {0}" -f $File)
        }
    }
    # Return data
    return $RoleAssignments
}

# Get-Roles
# Description: get all Roles from a collection of Zones
# Input      : collection of Zones
# Output     : collection of Roles
function Get-Roles([Array]$Zones) {
    # Cache management
    $File = ("{0}-Roles" -f $Domain)
    # Import data from cache
    $Roles = Import-Cache -Name $File
    if (-not $Roles) {
        # Get All GroupProfiles
        $Roles = @()
        $Index = 1
        $Zones | ForEach-Object {
            # Get Centrify Roles from Domain
            Write-Log -Type "Message" -Process "Get-Roles" -Level "INFO" -Message ("Get Centrify Roles from Zone {0}" -f $_.CanonicalName)
            Write-Progress -Activity "Data import" -Status ("Get Roles from Zone {0} of {1}" -f $Index, $Zones.Count) -PercentComplete (($Index/($Zones.Count))*100) -Id 1 -ParentId 0
            $ZoneRoles = Get-CdmRole -Zone $_.DistinguishedName
            if ($ZoneRoles) {
                # Export data to temp file
                Write-Log -Type "Message" -Process "Get-Roles" -Level "INFO" -Message ("Export {0} Centrify Roles from Zone {1}" -f $Roles.Count, $_.CanonicalName)
                Export-Cache -Name $File -Data $ZoneRoles
                # Add data to array
                $Roles += $ZoneRoles
            }
            else {
                # No data found
                Write-Log -Type "Message" -Process "Get-Roles" -Level "WARN" -Message ("No Centrify Roles data found from Zone {0}" -f $_.CanonicalName)
            }
            # Increment Progress bar
            $Index++
        }
        # Report total exported
        if (($Roles | Measure-Object).Count -gt 0) {
            Write-Log -Type "Message" -Process "Get-Roles" -Level "INFO" -Message ("Export {0} Centrify Roles to File {1}" -f ($Roles | Measure-Object).Count, $File)
            # Export temporary file
            Export-Cache -Name $File
        } else {
            Write-Log -Type "Message" -Process "Get-Roles" -Level "INFO" -Message ("No Centrify Roles to export to File {0}" -f $File)
        }
    }
    # Return data
    return $Roles
}

# Get-CommandRights
# Description: get all Command Rights from a collection of Zones
# Input      : collection of Zones
# Output     : collection of CommandRights
function Get-CommandRights([Array]$Zones) {
    # Cache management
    $File = ("{0}-CommandRights" -f $Domain)
    # Import data from cache
    $CommandRights = Import-Cache -Name $File
    if (-not $Roles) {
        # Get All CommandRights
        $CommandRights = @()
        $Index = 1
        $Zones | ForEach-Object {
            # Get Centrify Command Rights from Domain
            Write-Log -Type "Message" -Process "Get-CommandRights" -Level "INFO" -Message ("Get Centrify Command Rights from Zone {0}" -f $_.CanonicalName)
            Write-Progress -Activity "Data import" -Status ("Get Command Rights from Zone {0} of {1}" -f $Index, $Zones.Count) -PercentComplete (($Index/($Zones.Count))*100) -Id 1 -ParentId 0
            $ZoneCommandRights = Get-CdmCommandRight -Zone $_.DistinguishedName
            if ($ZoneCommandRights) {
                # Export data to temp file
                Write-Log -Type "Message" -Process "Get-CommandRights" -Level "INFO" -Message ("Export {0} Centrify Command Rights from Zone {1}" -f $CommandRights.Count, $_.CanonicalName)
                Export-Cache -Name $File -Data $ZoneCommandRights
                # Add data to array
                $CommandRights += $ZoneCommandRights
            }
            else {
                # No data found
                Write-Log -Type "Message" -Process "Get-CommandRights" -Level "WARN" -Message ("No Centrify Command Rights data found from Zone {0}" -f $_.CanonicalName)
            }
            # Increment Progress bar
            $Index++
        }
        # Report total exported
        if (($CommandRights | Measure-Object).Count -gt 0) {
            Write-Log -Type "Message" -Process "Get-CommandRights" -Level "INFO" -Message ("Export {0} Centrify Command Rights to File {1}" -f ($CommandRights | Measure-Object).Count, $File)
            # Export temporary file
            Export-Cache -Name $File
        } else {
            Write-Log -Type "Message" -Process "Get-CommandRights" -Level "INFO" -Message ("No Centrify Command Rights to export to File {0}" -f $File)
        }
    }
    # Return data
    return $CommandRights
}

### VARIABLES
# Centrify Agents support matrix showing release dates for all versions
# As per vendor support policy:
# - Core Support is 3 years from release date
# - Extended Support is 5 years from release date
# Reference: https://docs.delinea.com/online-help/server-suite/release-notes/supported-versions.htm
$DCSupportMatrix = @{
    100 = "2005-03-01"
    200 = "2005-09-01"
    300 = "2006-04-01"
    400 = "2007-10-01"
    420 = "2008-12-01"
    430 = "2009-05-01"
    440 = "2010-01-01"
    444 = "2012-05-01"
    500 = "2011-10-01"
    504 = "2012-09-01"
    505 = "2012-12-01"
    510 = "2013-01-01"
    511 = "2013-07-01"
    513 = "2014-01-01"
    520 = "2014-08-01"
    522 = "2015-02-01"
    523 = "2015-07-01"
    530 = "2015-12-01"
    531 = "2016-05-01"
    540 = "2017-02-01"
    541 = "2017-05-01"
    542 = "2017-09-01"
    543 = "2017-12-01"
    550 = "2018-04-01"
    551 = "2018-08-01"
    552 = "2018-12-01"
    553 = "2019-02-01"
    560 = "2019-08-01"
    561 = "2019-12-01"
    570 = "2020-09-01"
    571 = "2020-12-01"
    580 = "2021-07-01"
    581 = "2021-12-01"
    590 = "2022-04-01"
    591 = "2022-08-01"
    600 = "2023-03-01"
    601 = "2023-11-01"
}

# Written month names for support matrix usage
$MonthNames = @("", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" )

# List of Diagnostics sections and steps in each for writing console output
if ($AgentsOnly) {
    # Agent Diagnostics only
    $Diagnostics = @(
        @{
            "Name" = "Host Diagnostics";
            "Steps" = @(
                "Get Host information",
                "Get PowerShell Module information"
            )
        }
        @{
            "Name" = "Loading Data";
            "Steps" = @(
                "Get Zones",
                "Get Computers",
                "Get AD Computers"
            )
        }
        @{
            "Name" = "Zone Diagnostics";
            "Steps" = @(
                "Count classic zones",
                "Count hierarchical zones",
                "Count parent zones",
                "Count child zones",
                "Count orphaned child zones",
                "Count SFU compatible zones"
            )
        }
        @{
            "Name" = "Computers Diagnostics";
            "Steps" = @(
                "Count workstations computers",
                "Count express mode computers",
                "Count hierarchical computers",
                "Count Windows computers",
                "Count Zone-joined computers",
                "Count Zone-only computers"
                "Count orphaned computers",
                "Count disabled computers",
                "Count expired AD Computers"
            )
        }
        @{
            "Name" = "CentrifyDC Agents Diagnostics";
            "Steps" = @(
                "Get supported versions",
                "Count supported agents",
                "List CentrifyDC Versions"
            )
        }
    )
} else {
    # All diagnostics
    $Diagnostics = @(
        @{
            "Name" = "Host Diagnostics";
            "Steps" = @(
                "Get Host information",
                "Get PowerShell Module information"
            )
        }
        @{
            "Name" = "Loading Data";
            "Steps" = @(
                "Get Zones",
                "Get Computers",
                "Get AD Computers",
                "Get ComputerRoles",
                "Get User profiles",
                "Get Group profiles",
                "Get Role assignments",
                "Get Roles",
                "Get Command Rights"
            )
        }
        @{
            "Name" = "Zone Diagnostics";
            "Steps" = @(
                "Count classic zones",
                "Count hierarchical zones",
                "Count parent zones",
                "Count child zones",
                "Count orphaned child zones",
                "Count SFU compatible zones"
            )
        }
        @{
            "Name" = "Computers Diagnostics";
            "Steps" = @(
                "Count workstations computers",
                "Count express mode computers",
                "Count hierarchical computers",
                "Count Windows computers",
                "Count Zone-joined computers",
                "Count Zone-only computers"
                "Count orphaned computers",
                "Count disabled computers",
                "Count expired AD Computers"
            )
        }
        @{
            "Name" = "CentrifyDC Agents Diagnostics";
            "Steps" = @(
                "Get supported versions",
                "Count supported agents",
                "List CentrifyDC Versions"
            )
        }
        @{
            "Name" = "CentrifyDC Identities Diagnostics";
            "Steps" = @(
                "Count User profiles",
                "Count orphaned User profiles",
                "Count Group profiles",
                "Count orphaned Group profiles"
            )
        }
        @{
            "Name" = "CentrifyDC Access and Privileges Diagnostics";
            "Steps" = @(
                "Count Zone's RoleAssignements",
                "Count ComputerRole's RoleAssignements",
                "Count Computer's RoleAssignements",
                "Count orphaned RoleAssignements",
                "Count AD User's RoleAssignements",
                "Count AD Group's RoleAssignements",
                "Count UNIX User's RoleAssignements",
                "Count custom Roles",
                "Count Command Rights"
            )
        }
    )
}

### MAIN
# Validate that Centrify PowerShell module is present
try {
    if ((Get-Module -Name Centrify.DirectControl.PowerShell) -eq $null) {
        # This script is based on Centrify PowerShell module. Loading Module.
        Import-Module -Name Centrify.DirectControl.PowerShell
    }
} catch {
    if($_.Exception.Message -match "Import-Module : The specified module 'Centrify.DirectControl.PowerShell' was not loaded because no valid module file was found in any module directory.") {
        # Credentials error connecting AD domain. Breaking back to main.
        Write-Log -Type "Secure" -Process "Get-Module" -Level "ERROR" -Message ("This script is based on Centrify PowerShell module that was not loaded because no valid module file was found in any module directory.")
        Exit 1
    } else {
        # Unhandled exception
        Throw $_.Exception
        Exit 1
    }
}

# Set Centrify credentials if required
try {
    if (-not [String]::IsNullOrEmpty($Credentials)) {
        # Set credentials
        Set-CdmCredential -Domain $Domain -Credential $Credentials
        # User
        $User = (Get-CdmCredential -Target $Domain).User
    } else {
        # User
        $User = ("{0}@{1}" -f $env:USERNAME, $env:USERDNSDOMAIN)
    }
} catch {
    if($_.Exception.Message -match "Logon Failure: unknown user name or bad password") {
        # Credentials error connecting AD domain. Exiting.
        Write-Log -Type "Secure" -Process "Set-CdmCredential" -Level "ERROR" -Message ("Could not validate credentials {0} to connect with AD Domain {1}." -f $User, $Domain)
        Exit 1
    } else {
        # Unhandled exception
        Throw $_.Exception
        Exit 1
    }
}

# Set Centrify preferred server to use if required
try {
    if (-not [String]::IsNullOrEmpty($Server)) {
        # Set preferred server
        Set-CdmPreferredServer -Domain $Domain -Server $Server
    } else {
        # Get preferred server from setting connection to domain
        Set-CdmPreferredServer -Domain $Domain -Server $Domain
        $Server = (Get-CdmPreferredServer | Where-Object { $_.Domain -eq $Domain }).Server
    }
} catch {
    if($_.Exception.Message -match "Set-CdmPreferredServer : The server is not operational.") {
        # Server or Domain name is invalid. Exiting.
        Write-Log -Type "Message" -Process "Set-CdmPreferredServer" -Level "ERROR" -Message ("Could not find server {0} in AD Domain {1}." -f $Server, $Domain)
        Exit 1
    } elseif($_.Exception.Message -match "Set-CdmPreferredServer : The domain controller comes from another domain.") {
        # Server not from AD domain. Exiting.
        Write-Log -Type "Message" -Process "Set-CdmPreferredServer" -Level "ERROR" -Message ("Server {0} is not part of AD Domain {1}." -f $Server, $Domain)
        Exit 1
    } else {
        # Unhandled exception
        Throw $_.Exception
        Exit 1
    }
}

# Print invocation details to console
Write-Host "Delinea Self Assessment (1.0)"

# 0. Host Diagnostics
# 0.1 Get Host information
# 0.2 Get PowerShell Module information
Write-Progress -Activity "Server Suite Self Assessment" -Status ("Running diagnostic 1 of {0}" -f $Diagnostics.Count) -PercentComplete ((1/$Diagnostics.Count)*100) -Id 0
Write-Host ("`n{0}" -f $Diagnostics[0].Name)

# 0.1 Get Host information
Write-Progress -Activity $Diagnostics[0].Name -Status $Diagnostics[0].Steps[0] -PercentComplete ((1/$Diagnostics[0].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tHostname: {0}" -f (Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem).Name)
Write-Host ("`tDomain  : {0}" -f $Domain)
Write-Host ("`tServer  : {0}" -f $Server)
Write-Host ("`tUser    : {0}" -f $User)

# 0.2 Get PowerShell Module information
Write-Progress -Activity $Diagnostics[0].Name -Status $Diagnostics[0].Steps[1] -PercentComplete ((2/$Diagnostics[0].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tPSModule: {0}" -f (Get-Module -Name Centrify.DirectControl.PowerShell).Version.ToString())

# 1. Loading data
# 1.1 Get Zones
# 1.2 Get Computers
# 1.3 Get AD computers
# 1.4 Get ComputerRoles
# 1.5 Get User profiles
# 1.6 Get Group profiles
# 1.7 Get RoleAssignments
# 1.8 Get Roles
# 1.9 Get Command Rights
Write-Progress -Activity "Server Suite Self Assessment" -Status ("Running diagnostic 2 of {0}" -f $Diagnostics.Count) -PercentComplete ((2/$Diagnostics.Count)*100) -Id 0
Write-Host ("`n{0}" -f $Diagnostics[1].Name)

# 1.1 Get Zones
Write-Progress -Activity $Diagnostics[1].Name -Status $Diagnostics[1].Steps[0] -PercentComplete ((1/$Diagnostics[1].Steps.Count)*100) -Id 1 -ParentId 0
$Zones = Get-Zones -Domain $Domain
Write-Host ("`tZones         : {0}" -f $Zones.Count)

# 1.2 Get Computers
Write-Progress -Activity $Diagnostics[1].Name -Status $Diagnostics[1].Steps[1] -PercentComplete ((2/$Diagnostics[1].Steps.Count)*100) -Id 1 -ParentId 0
$Computers = Get-Computers -Zones $Zones
Write-Host ("`tComputers     : {0}" -f $Computers.Count)

# 1.3 Get AD computers
Write-Progress -Activity $Diagnostics[1].Name -Status $Diagnostics[1].Steps[2] -PercentComplete ((3/$Diagnostics[1].Steps.Count)*100) -Id 1 -ParentId 0
$ADComputers = Get-ADComputers -Computers $Computers
Write-Host ("`tADComputers   : {0}" -f $ADComputers.Count)

if (-not $AgentsOnly) {
    # 1.4 Get ComputerRoles
    Write-Progress -Activity $Diagnostics[1].Name -Status $Diagnostics[1].Steps[3] -PercentComplete ((4/$Diagnostics[1].Steps.Count)*100) -Id 1 -ParentId 0
    $ComputerRoles = Get-ComputerRoles -Zones $Zones
    Write-Host ("`tComputerRoles : {0}" -f $ComputerRoles.Count)

    # 1.5 Get User profiles
    Write-Progress -Activity $Diagnostics[1].Name -Status $Diagnostics[1].Steps[4] -PercentComplete ((5/$Diagnostics[1].Steps.Count)*100) -Id 1 -ParentId 0
    $UserProfiles = Get-UserProfiles -Zones $Zones -Computers $Computers
    Write-Host ("`tUserProfiles  : {0}" -f $UserProfiles.Count)

    # 1.6 Get Group profiles
    Write-Progress -Activity $Diagnostics[1].Name -Status $Diagnostics[1].Steps[5] -PercentComplete ((6/$Diagnostics[1].Steps.Count)*100) -Id 1 -ParentId 0
    $GroupProfiles = Get-GroupProfiles -Zones $Zones -Computers $Computers
    Write-Host ("`tGroupProfiles : {0}" -f $GroupProfiles.Count)

    # 1.7 Get RoleAssignments
    Write-Progress -Activity $Diagnostics[1].Name -Status $Diagnostics[1].Steps[6] -PercentComplete ((7/$Diagnostics[1].Steps.Count)*100) -Id 1 -ParentId 0
    $RoleAssignments = Get-RoleAssignments -Zones $Zones -ComputerRoles $ComputerRoles -Computers $Computers
    Write-Host ("`RoleAssignments: {0}" -f $RoleAssignments.Count)

    # 1.8 Get Roles
    Write-Progress -Activity $Diagnostics[1].Name -Status $Diagnostics[1].Steps[7] -PercentComplete ((8/$Diagnostics[1].Steps.Count)*100) -Id 1 -ParentId 0
    $Roles = Get-Roles -Zones $Zones
    Write-Host ("`tRoles         : {0}" -f $Roles.Count)

    # 1.9 Get Command Rights
    Write-Progress -Activity $Diagnostics[1].Name -Status $Diagnostics[1].Steps[8] -PercentComplete ((9/$Diagnostics[1].Steps.Count)*100) -Id 1 -ParentId 0
    $CommandRights = Get-CommandRights -Zones $Zones
    Write-Host ("`tCommand Rights: {0}" -f $CommandRights.Count)
}

# 2. Zones assessment
# 2.1 Count classic zones
# 2.2 Count hierarchical zones
# 2.3 Count parent zones
# 2.4 Count child zones
# 2.5 Count orphaned child zones
# 2.6 Count SFU compatible zones
Write-Progress -Activity "Server Suite Self Assessment" -Status ("Running diagnostic 3 of {0}" -f $Diagnostics.Count) -PercentComplete ((3/$Diagnostics.Count)*100) -Id 0
Write-Host ("`n{0}" -f $Diagnostics[2].Name)

# 2.1 Count classic zones
Write-Progress -Activity $Diagnostics[2].Name -Status $Diagnostics[2].Steps[0] -PercentComplete ((1/$Diagnostics[2].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tClassic zones       : {0}" -f ($Zones | Where-Object { -not $_.IsHierarchical } | Measure-Object).Count)

# 2.2 Count hierarchical zones
Write-Progress -Activity $Diagnostics[2].Name -Status $Diagnostics[2].Steps[1] -PercentComplete ((2/$Diagnostics[2].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tHierarchical zones  : {0}" -f ($Zones | Where-Object { $_.IsHierarchical } | Measure-Object).Count)

# 2.3 Count parent zones
Write-Progress -Activity $Diagnostics[2].Name -Status $Diagnostics[2].Steps[2] -PercentComplete ((3/$Diagnostics[2].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tParent zones        : {0}" -f ($Zones | Where-Object { $_.IsHierarchical -and $_.Parent -eq $null } | Measure-Object).Count)

# 2.4 Count child zones
Write-Progress -Activity $Diagnostics[2].Name -Status $Diagnostics[2].Steps[3] -PercentComplete ((4/$Diagnostics[2].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tChild zones         : {0}" -f ($Zones | Where-Object { $_.IsHierarchical -and $_.Parent -ne $null } | Measure-Object).Count)

# 2.5 Count orphaned child zones
Write-Progress -Activity $Diagnostics[2].Name -Status $Diagnostics[2].Steps[4] -PercentComplete ((5/$Diagnostics[2].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tOrphaned child zones: {0}" -f ($Zones | Where-Object { $_.IsOrphanChildZone } | Measure-Object).Count)

# 2.6 Count SFU compatible zones
Write-Progress -Activity $Diagnostics[2].Name -Status $Diagnostics[2].Steps[5] -PercentComplete ((6/$Diagnostics[2].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tSFU compatible zones: {0}" -f ($Zones | Where-Object { $_.IsSfu } | Measure-Object).Count)

# 3. Computers assessment
# 3.1 Count workstations computers
# 3.2 Count express mode computers
# 3.3 Count hierarchical computers
# 3.4 Count Windows computers
# 3.5 Count Zone-joined computers
# 3.6 Count Zone-only computers
# 3.7 Count orphaned computers
# 3.8 Count disabled computers
# 3.9 Count expired AD Computers
Write-Progress -Activity "Server Suite Self Assessment" -Status ("Running diagnostic 4 of {0}" -f $Diagnostics.Count) -PercentComplete ((4/$Diagnostics.Count)*100) -Id 0
Write-Host ("`n{0}" -f $Diagnostics[3].Name)

# 3.1 Count workstations computers
Write-Progress -Activity $Diagnostics[3].Name -Status $Diagnostics[3].Steps[0] -PercentComplete ((1/$Diagnostics[3].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tWorkstations computers: {0}" -f ($Computers | Where-Object { $_.IsWorkstationMode } | Measure-Object).Count)

# 3.2 Count express mode computers
Write-Progress -Activity $Diagnostics[3].Name -Status $Diagnostics[3].Steps[1] -PercentComplete ((2/$Diagnostics[3].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tExpress mode computers: {0}" -f ($Computers | Where-Object { $_.IsExpressMode } | Measure-Object).Count)

# 3.3 Count hierarchical computers
Write-Progress -Activity $Diagnostics[3].Name -Status $Diagnostics[3].Steps[2] -PercentComplete ((3/$Diagnostics[3].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tHierarchical computers: {0}" -f ($Computers | Where-Object { $_.IsHierarchical } | Measure-Object).Count)

# 3.4 Count Windows computers
Write-Progress -Activity $Diagnostics[3].Name -Status $Diagnostics[3].Steps[3] -PercentComplete ((4/$Diagnostics[3].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tWindows computers     : {0}" -f ($Computers | Where-Object { $_.IsWindows } | Measure-Object).Count)

# 3.5 Count Zone-joined computers
Write-Progress -Activity $Diagnostics[3].Name -Status $Diagnostics[3].Steps[4] -PercentComplete ((5/$Diagnostics[3].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tZone-joined computers : {0}" -f ($Computers | Where-Object { $_.IsJoinedToZone } | Measure-Object).Count)

# 3.6 Count Zone-only computers
Write-Progress -Activity $Diagnostics[3].Name -Status $Diagnostics[3].Steps[5] -PercentComplete ((6/$Diagnostics[3].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tZone-only computers   : {0}" -f ($Computers | Where-Object { $_.IsComputerZoneOnly } | Measure-Object).Count)

# 3.7 Count orphaned computers
Write-Progress -Activity $Diagnostics[3].Name -Status $Diagnostics[3].Steps[6] -PercentComplete ((7/$Diagnostics[3].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tOrphaned computers    : {0}" -f ($Computers | Where-Object { $_.IsOrphan } | Measure-Object).Count)

# 3.8 Count disabled computers
Write-Progress -Activity $Diagnostics[3].Name -Status $Diagnostics[3].Steps[7] -PercentComplete ((8/$Diagnostics[3].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tDisabled AD computers : {0}" -f ($Computers | Where-Object { -not $_.Computer.Enabled } | Measure-Object).Count)

# 3.9 Count expired AD Computers
Write-Progress -Activity $Diagnostics[3].Name -Status $Diagnostics[3].Steps[8] -PercentComplete ((9/$Diagnostics[3].Steps.Count)*100) -Id 1 -ParentId 0
$ExpiredComputers = Get-ExpiredComputers -ADComputers $ADComputers
Write-Host ("`tExpired AD computers  : {0}" -f ($ExpiredComputers | Measure-Object).Count)

# 4. CentrifyDC Agents assessment
# 4.1 Get supported versions
# 4.2 Count supported agents
# 4.3 List CentrifyDC Versions
Write-Progress -Activity "Server Suite Self Assessment" -Status ("Running diagnostic 5 of {0}" -f $Diagnostics.Count) -PercentComplete ((5/$Diagnostics.Count)*100) -Id 0
Write-Host ("`n{0}" -f $Diagnostics[4].Name)

# 4.1 Get supported versions
Write-Progress -Activity $Diagnostics[4].Name -Status $Diagnostics[4].Steps[0] -PercentComplete ((1/$Diagnostics[4].Steps.Count)*100) -Id 1 -ParentId 0
$LastVersionCoreSupport = (($DCSupportMatrix.GetEnumerator() | Where-Object { [datetime]$_.Value -ge [datetime]::Now.AddYears(-3) }).Name | Sort-Object)[0]
$LastVersionExtendedSupport = (($DCSupportMatrix.GetEnumerator() | Where-Object { [datetime]$_.Value -ge [datetime]::Now.AddYears(-5) }).Name | Sort-Object)[0]

# 4.2 Count supported agents
Write-Progress -Activity $Diagnostics[4].Name -Status $Diagnostics[4].Steps[1] -PercentComplete ((2/$Diagnostics[4].Steps.Count)*100) -Id 1 -ParentId 0
Write-Host ("`tAgents under Core Support    : {0}" -f ($Computers | Where-Object { $_.AgentVersion -match "^[0-9](\.[0-9]){2}-[0-9]{3}" -and [int](($_.AgentVersion -split '-')[0] -replace '\.','') -ge $LastVersionCoreSupport } | Measure-Object).Count)
Write-Host ("`tAgents under Extended Support: {0}" -f ($Computers | Where-Object { $_.AgentVersion -match "^[0-9](\.[0-9]){2}-[0-9]{3}" -and [int](($_.AgentVersion -split '-')[0] -replace '\.','') -ge $LastVersionExtendedSupport -and [int](($_.AgentVersion -split '-')[0] -replace '\.','') -lt $LastVersionCoreSupport } | Measure-Object).Count)
Write-Host ("`tAgents out of Support        : {0}" -f ($Computers | Where-Object { $_.AgentVersion -match "^[0-9](\.[0-9]){2}-[0-9]{3}" -and [int](($_.AgentVersion -split '-')[0] -replace '\.','') -lt $LastVersionExtendedSupport } | Measure-Object).Count)
Write-Host ("`tAgents with unknown version  : {0}`n" -f ($Computers | Where-Object { $_.AgentVersion -notmatch "^[0-9](\.[0-9]){2}-[0-9]{3}" } | Measure-Object).Count)

# 4.3 List CentrifyDC Versions
Write-Progress -Activity $Diagnostics[4].Name -Status $Diagnostics[4].Steps[2] -PercentComplete ((3/$Diagnostics[4].Steps.Count)*100) -Id 1 -ParentId 0
$AgentVersions = ($Computers | Where-Object { ($_.AgentVersion -match "^[0-9](\.[0-9]){2}-[0-9]{3}") } | Select-Object -Property AgentVersion).AgentVersion -Replace "CentrifyDC ", "" | Sort-Object -Unique
foreach($Version in $AgentVersions) {
    Write-Host ("`tCentrifyDC version: {0}" -f $Version)
    Write-Host ("`t`tAgents count           : {0}" -f ($Computers | Where-Object { $_.AgentVersion -match $Version } | Measure-Object).Count)
    # Get Support dates from Support matrix
    $Key = [Int](($Version -Split '-')[0] -Replace '\.', '')
    while($Key -ge 100) { 
        if($DCSupportMatrix.Contains($Key)) { 
            # Print Supported Versions details
            Write-Host ("`t`tVersion Release Date   : {0} {1}" -f $MonthNames[([DateTime]$DCSupportMatrix[$Key]).Month], ([DateTime]$DCSupportMatrix[$Key]).Year)
            Write-Host ("`t`tEnd of Core Support    : {0} {1}" -f $MonthNames[([DateTime]$DCSupportMatrix[$Key]).Month], ([DateTime]$DCSupportMatrix[$Key]).AddYears(3).Year)
            Write-Host ("`t`tEnd of Extended Support: {0} {1}" -f $MonthNames[([DateTime]$DCSupportMatrix[$Key]).Month], ([DateTime]$DCSupportMatrix[$Key]).AddYears(5).Year)
            break
        }
        $Key--
    }
}

if (-not $AgentsOnly) {
    # 5. Identities assessment
    # 5.1 Count User profiles
    # 5.2 Count orphaned User profiles
    # 5.3 Count Group profiles
    # 5.4 Count orphaned Group profiles
    Write-Progress -Activity "Server Suite Self Assessment" -Status ("Running diagnostic 6 of {0}" -f $Diagnostics.Count) -PercentComplete ((6/$Diagnostics.Count)*100) -Id 0
    Write-Host ("`n{0}" -f $Diagnostics[5].Name)

    # 5.1 Count Users profiles
    Write-Progress -Activity $Diagnostics[5].Name -Status $Diagnostics[5].Steps[0] -PercentComplete ((1/$Diagnostics[5].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tUser profiles  : {0}" -f ($UserProfiles | Where-Object { -not $_.IsOrphan } | Measure-Object).Count)

    # 5.2 Count orphaned User profiles
    Write-Progress -Activity $Diagnostics[5].Name -Status $Diagnostics[5].Steps[1] -PercentComplete ((2/$Diagnostics[5].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tOrphaned users : {0}" -f ($UserProfiles | Where-Object { $_.IsOrphan } | Measure-Object).Count)

    # 5.3 Count Group profiles
    Write-Progress -Activity $Diagnostics[5].Name -Status $Diagnostics[5].Steps[2] -PercentComplete ((3/$Diagnostics[5].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tGroup profiles : {0}" -f ($GroupProfiles | Where-Object { -not $_.IsOrphan } | Measure-Object).Count)

    # 5.4 Count orphaned Group profiles
    Write-Progress -Activity $Diagnostics[5].Name -Status $Diagnostics[5].Steps[3] -PercentComplete ((4/$Diagnostics[5].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tOrphaned groups: {0}" -f ($GroupProfiles | Where-Object { $_.IsOrphan } | Measure-Object).Count)

    # 6. Roles assessment
    # 6.1 Count Zone's RoleAssignements
    # 6.2 Count ComputerRole's RoleAssignements
    # 6.3 Count Computer's RoleAssignements
    # 6.4 Count orphaned RoleAssignements
    # 6.5 Count AD User's RoleAssignements
    # 6.6 Count AD Group's RoleAssignements
    # 6.7 Count UNIX User's RoleAssignements
    # 6.8 Count custom Roles
    # 6.9 Count Command Rights
    Write-Progress -Activity "Server Suite Self Assessment" -Status ("Running diagnostic 7 of {0}" -f $Diagnostics.Count) -PercentComplete ((7/$Diagnostics.Count)*100) -Id 0
    Write-Host ("`n{0}" -f $Diagnostics[6].Name)

    # 6.1 Count Zone's RoleAssignements
    Write-Progress -Activity $Diagnostics[6].Name -Status $Diagnostics[5].Steps[0] -PercentComplete ((1/$Diagnostics[6].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tZone's RoleAssignements        : {0}" -f ($RoleAssignments | Where-Object { $_.Zone } | Measure-Object).Count)

    # 6.2 Count ComputerRole's RoleAssignements
    Write-Progress -Activity $Diagnostics[6].Name -Status $Diagnostics[5].Steps[0] -PercentComplete ((2/$Diagnostics[6].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tComputerRole's RoleAssignements: {0}" -f ($RoleAssignments | Where-Object { $_.ComputerRole } | Measure-Object).Count)

    # 6.3 Count Computer's RoleAssignements
    Write-Progress -Activity $Diagnostics[6].Name -Status $Diagnostics[5].Steps[1] -PercentComplete ((3/$Diagnostics[6].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tComputer's RoleAssignements    : {0}" -f ($RoleAssignments | Where-Object { $_.Computer } | Measure-Object).Count)

    # 6.4 Count orphaned RoleAssignements
    Write-Progress -Activity $Diagnostics[6].Name -Status $Diagnostics[5].Steps[0] -PercentComplete ((4/$Diagnostics[6].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tOrphaned RoleAssignements      : {0}" -f ($RoleAssignments | Where-Object { $_.IsRoleOrphaned -or $_.IsTrusteeOrphaned } | Measure-Object).Count)

    # 6.5 Count AD User's RoleAssignements
    Write-Progress -Activity $Diagnostics[6].Name -Status $Diagnostics[5].Steps[0] -PercentComplete ((5/$Diagnostics[6].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tAD User's RoleAssignements     : {0}" -f ($RoleAssignments | Where-Object { $_.TrusteeType -eq "ADUser" } | Measure-Object).Count)

    # 6.6 Count AD Group's RoleAssignements
    Write-Progress -Activity $Diagnostics[6].Name -Status $Diagnostics[5].Steps[1] -PercentComplete ((6/$Diagnostics[6].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tAD Group's RoleAssignements    : {0}" -f ($RoleAssignments | Where-Object { $_.TrusteeType -eq "ADGroup" } | Measure-Object).Count)

    # 6.7 Count UNIX User's RoleAssignements
    Write-Progress -Activity $Diagnostics[6].Name -Status $Diagnostics[5].Steps[0] -PercentComplete ((7/$Diagnostics[6].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tUNIX User's RoleAssignements   : {0}" -f ($RoleAssignments | Where-Object { $_.TrusteeType -eq "LocalUnixUser" } | Measure-Object).Count)

    # 6.8 Count custom Roles
    Write-Progress -Activity $Diagnostics[6].Name -Status $Diagnostics[5].Steps[1] -PercentComplete ((8/$Diagnostics[6].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tCustom Roles (non-predefined)  : {0}" -f ($Roles| Where-Object { $_.Description -notmatch "Predefined system role" }  | Measure-Object).Count)

    # 6.9 Count Command Rights
    Write-Progress -Activity $Diagnostics[6].Name -Status $Diagnostics[5].Steps[0] -PercentComplete ((9/$Diagnostics[6].Steps.Count)*100) -Id 1 -ParentId 0
    Write-Host ("`tCommand Rights (dzdo rights)   : {0}" -f ($CommandRights | Measure-Object).Count)
}

# Ending
Write-Host "`n(C)2024 AMS Consulting UK"
### END