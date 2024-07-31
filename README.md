# Delinea-SelfAssessment
Delinea Self Assessment script to use with Server Suite deployment in Active Directory. 

### Table of Contents
1. [Description](#description)
2. [Diagnostics](#diagnostics)
3. [License](#license)
4. [Setup](#setup)
5. [Contact](#contact)

## Description
This PowerShell script exports and analyses data on Delinea Server Suite deployment.

It can be executed from a Workstation or Server member of the Active Directory domain you want to assess Deline Server Suite deployment from, and only requires read access to Active Directory.

Script will collect data from Active Directory and create cache into a folder named *data* and logs into a folder named *log*.

Script will analyse data and output diagnostics on Centrify data stored in Active Directory, as well as providing a status of Centrify Agent Support status.

## Diagnostics
This script runs the diagnostics describe here after.

0. Host Diagnostics
    * Get Host information
    * Get PowerShell Module information

1. Loading data
    * Get Zones
    * Get Computers
    * Get AD computers
    * Get ComputerRoles
    * Get User profiles
    * Get Group profiles
    * Get RoleAssignments
    * Get Roles
    * Get Command Rights

2. Zones assessment
    * Count classic zones
    * Count hierarchical zones
    * Count parent zones
    * Count child zones
    * Count orphaned child zones
    * Count SFU compatible zones

3. Computers assessment
    * Count workstations computers
    * Count express mode computers
    * Count hierarchical computers
    * Count Windows computers
    * Count Zone-joined computers
    * Count Zone-only computers
    * Count orphaned computers
    * Count disabled computers
    * Count expired AD Computers

4. CentrifyDC Agents assessment
    * Get supported versions
    * Count supported agents
    * List CentrifyDC Versions

5. Identities assessment
    * Count User profiles
    * Count orphaned User profiles
    * Count Group profiles
    * Count orphaned Group profiles

6. Roles assessment
    * Count Zone's RoleAssignements
    * Count ComputerRole's RoleAssignements
    * Count Computer's RoleAssignements
    * Count orphaned RoleAssignements
    * Count AD User's RoleAssignements
    * Count AD Group's RoleAssignements
    * Count UNIX User's RoleAssignements
    * Count custom Roles
    * Count Command Rights

## License
This script is distributed under MIT license (see [LICENSE](LICENSE) file), and uses Delinea PowerShell SDK provided with Server Suite, which requires a valid Server Suite license from Delinea.

## Setup
Follow the steps below to run this script in your environment:

1. Copy the script on a Workstation or Server member of the Active Directory domain you want to assess Deline Server Suite deployment from.
*As needed, use -Domain option to target a different Active Directory domain (this domain need to be resolvable and reachable from the Workstation or Server it's executed from* 

2. Run the script from a PowerShell session opened with AD User privileges.
*As needed, use -Credential option to specify AD User account to run the script with*

3. Review output from script.
*If any error occurs, review logs under log folder to diagnose and remediate issue*

## Contact
Would you have comment or question, contact us at support@ams-consulting.uk