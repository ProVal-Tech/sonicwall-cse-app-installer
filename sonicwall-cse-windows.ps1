# Run as administrator

################################################################################
# SonicWall Cloud Secure Edge Zero Touch Installation
# Confirm or update the following variables prior to running the script

# Deployment Information
# Obtain from the SonicWall Cloud Secure Edge admin console: Settings > App Deployment
$INVITE_CODE = $args[0]
$DEPLOYMENT_KEY = $args[1]
$APP_VERSION = $args[2]

# Device Registration and SonicWall Cloud Secure Edge App Configuration
# Check docs for more options and details:
# https://docs.banyansecurity.io/docs/feature-guides/manage-users-and-devices/device-managers/distribute-desktopapp/#mdm-config-json
$DEVICE_OWNERSHIP = "S"
$CA_CERTS_PREINSTALLED = $false
$SKIP_CERT_SUPPRESSION = $false
$IS_MANAGED_DEVICE = $false
$DEVICE_MANAGER_NAME = ""
$HIDE_SERVICES = $false
$DISABLE_QUIT = $false
$START_AT_BOOT = $true
$AUTO_LOGIN = $false
$HIDE_ON_START = $true
$DISABLE_AUTO_UPDATE = $false
$ALLOW_MULTIORG = $false
$ST_OVER_443 = $false

# User Information for Device Certificate
$MULTI_USER = $true

# Preview Feature: Allow App via NetFirewallRule for Windows Firewall.
$ALLOW_APP = $false


################################################################################


$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (! $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be with admin privilege"
    exit 1
}

if (!$INVITE_CODE -or !$DEPLOYMENT_KEY) {
    Write-Host "Usage: "
    Write-Host "$PSCommandPath <INVITE_CODE> <DEPLOYMENT_KEY> <APP_VERSION (optional>"
    exit 1
}

# Wrap app version check in try block to capture response anyways when request
# is returned with status_code 302 (Moved Temporarily), causing the req to fail
if (!$APP_VERSION) {
    Write-Host "Checking for latest version of app"
    try {
        # Attempt the request; -MaximumRedirection 0 forces it to "fail" on the redirect
        $resp = Invoke-WebRequest -Uri "https://www.banyanops.com/app/windows/v3/latest" -MaximumRedirection 0 -ErrorAction SilentlyContinue -UseBasicParsing
    }
    catch {
        # Capture the response from the exception even though it "failed"
        $resp = $_.Exception.Response
    }

    if ($resp) {
        $loc = $resp.Headers.Location
        if ($loc -match 'sonicwallcse-([0-9]+\.[0-9]+\.[0-9]+)\.exe') {
            $APP_VERSION = $matches[1].Trim()
        }
    }
}

Write-Host "Installing with invite code: $INVITE_CODE"
Write-Host "Installing using deploy key: *****"
Write-Host "Installing app version: $APP_VERSION"

$logged_on_user = Get-WMIObject -class Win32_ComputerSystem | Select-Object -expand UserName
Write-Host "Installing app for user: $logged_on_user"

$global_profile_dir = "C:\ProgramData"




$MY_USER = ""
$MY_EMAIL = ""
function get_user_email() {
    if (!$MULTI_USER) {
        # for a single user device, assumes you can get user and email because device is joined to an
        # Azure AD domain: https://nerdymishka.com/articles/azure-ad-domain-join-registry-keys/
        # (you may use other techniques here as well)
        $intune_info = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"
        if (Test-Path $intune_info) {
            Write-Host "Extracting user email from: $intune_info"
            $ADJoinInfo = Get-ChildItem -path $intune_info
            $ADJoinInfo = $ADJoinInfo -replace "HKEY_LOCAL_MACHINE","HKLM:"
            $ADJoinUser = Get-ItemProperty -Path $ADJoinInfo
            $script:MY_EMAIL = $ADJoinUser.UserEmail
            $script:MY_USER = $MY_EMAIL.Split("@")[0]
        }
    }
    Write-Host "Installing for user with name: $MY_USER"
    Write-Host "Installing for user with email: $MY_EMAIL"
    if (!$MY_EMAIL) {
        Write-Host "No user specified - device certificate will be issued to the default **STAGED USER**"
    }
}


function create_config() {
    Write-Host "Creating mdm-config json file"

    $sonicwall_cse_dir_name = "sonicwallcse"
    $global_config_dir = $global_profile_dir + "\" + $sonicwall_cse_dir_name
    $global_config_file = $global_config_dir + "\" + "mdm-config.json"

    $json = [pscustomobject]@{
        mdm_invite_code = $INVITE_CODE
        mdm_deploy_user = $MY_USER
        mdm_deploy_email = $MY_EMAIL
        mdm_device_ownership = $DEVICE_OWNERSHIP
        mdm_ca_certs_preinstalled = $CA_CERTS_PREINSTALLED
        mdm_skip_cert_suppression = $SKIP_CERT_SUPPRESSION
        mdm_present = $IS_MANAGED_DEVICE
        mdm_vendor_name = $DEVICE_MANAGER_NAME
        mdm_hide_services = $HIDE_SERVICES
        mdm_disable_quit = $DISABLE_QUIT
        mdm_start_at_boot = $START_AT_BOOT
        mdm_auto_login = $AUTO_LOGIN
        mdm_hide_on_start = $HIDE_ON_START
        mdm_disable_auto_update = $DISABLE_AUTO_UPDATE
        mdm_multi_org = $ALLOW_MULTIORG
        mdm_st_over_443 = $ST_OVER_443
    } | ConvertTo-Json

    New-Item -Path $global_profile_dir -Name $sonicwall_cse_dir_name -ItemType "directory" -Force | Out-Null
    Set-Content -Path $global_config_file -Value $json -NoNewLine
}


function download_install() {
    Write-Host "Downloading installer EXE"

    $tmp_dir_name = "sonicwallcsetemp"
    $tmp_dir = $global_profile_dir + "\" + $tmp_dir_name

    New-Item -Path $global_profile_dir -Name $tmp_dir_name -ItemType "directory" -Force | Out-Null

    $dl_file = $tmp_dir + "\" + "sonicwallcse-$APP_VERSION.exe"

    $progressPreference = 'silentlyContinue'
    Invoke-Webrequest "https://www.banyanops.com/app/releases/sonicwallcse-$APP_VERSION.exe" -outfile $dl_file -UseBasicParsing
    $progressPreference = 'Continue'

    Write-Host "Run installer"
    Start-Process -FilePath $dl_file -ArgumentList "/S" -Wait
    Start-Sleep -Seconds 3
}


function stage() {
    Write-Host "Running staged deployment"

    if (Test-Path 'C:\Program Files\SonicWall Cloud Secure Edge\resources\bin\sonicwall-cse-admin-worker.exe') {
        $ADMIN_SERVER = "sonicwall-cse-admin-worker.exe"
    } else {
        $ADMIN_SERVER = "sonicwall-cse-admin.exe"
    }

    $process = Start-Process -FilePath "C:\Program Files\SonicWall Cloud Secure Edge\resources\bin\$ADMIN_SERVER" -ArgumentList "stage --key=$DEPLOYMENT_KEY" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Write-Host "Error during staged deployment"
        exit 1
    }
    Start-Sleep -Seconds 3
    Write-Host "Staged deployment done. Have the logged_on_user start the SonicWall Cloud Secure Edge app to complete registration."
}


function create_scheduled_task($task_name) {
    Write-Host "Creating ScheduledTask $task_name for logged_on_user, so app launches upon next user login"
    $action = New-ScheduledTaskAction -Execute "C:\Program Files\SonicWall Cloud Secure Edge\SonicWall Cloud Secure Edge.exe"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $logged_on_user
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal
    Register-ScheduledTask $task_name -InputObject $task
}

function delete_scheduled_task($task_name) {
    Write-Host "Deleting ScheduledTask $task_name"
    Unregister-ScheduledTask -TaskName $task_name -Confirm:$false
}

# since Windows doesn't have "su - username", we use scheduled_task to launch SonicWall Cloud Secure Edge app as logged_on user
function start_app() {
    Write-Host "Running ScheduledTask to start the SonicWall Cloud Secure Edge app as: $logged_on_user"
    $task_name = "StartSonicWallCSETemp"
    create_scheduled_task($task_name)
    Start-ScheduledTask -TaskName $task_name
    Start-Sleep -Seconds 5
    delete_scheduled_task($task_name)
}


function stop_app() {
    Write-Host "Stopping SonicWall Cloud Secure Edge app"
    Get-Process -Name "SonicWall Cloud Secure Edge" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function allow_app() {
    if ($ALLOW_APP) {
        New-NetFirewallRule `
            -DisplayName "SonicWall-CSE-App" `
            -Program "C:\Program Files\SonicWall Cloud Secure Edge\SonicWall Cloud Secure Edge.exe" `
            -Direction Outbound `
            -Action Allow `
            -Profile Public,Private,Domain
        }
}

if (($INVITE_CODE -eq "upgrade") -and ($DEPLOYMENT_KEY -eq "upgrade")) {
    Write-Host "Running upgrade flow"
    stop_app
    download_install
    start_app
} else {
    Write-Host "Running zero-touch install flow"
    stop_app
    get_user_email
    create_config
    download_install
    stage
    create_config
    allow_app
    start_app
}
# SIG # Begin signature block
# MIIlqQYJKoZIhvcNAQcCoIIlmjCCJZYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDBG0BDaywCEvxH
# QEqnxEyf0fakZyb3xnFshFq46E4qLaCCEvMwggXdMIIDxaADAgECAgh7LJvTFoAy
# mTANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjAyMTIxNzM5MzlaFw00MTAyMTIxNzM5MzlaMHwxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENv
# cnBvcmF0aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBB
# dXRob3JpdHkgUlNBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA+Q/d
# oyt9y9Aq/uxnhabnLhu6d+Hj9a+k7PpKXZHEV0drGHdrdvL9k+Q9D8IWngtmw1aU
# nheDhc5W7/IW/QBi9SIJVOhlF05BueBPRpeqG8i4bmJeabFf2yoCfvxsyvNB2O3Q
# 6Pw/YUjtsAMUHRAOSxngu07shmX/NvNeZwILnYZVYf16OO3+4hkAt2+hUGJ1dDyg
# +sglkrRueiLH+B6h47LdkTGrKx0E/6VKBDfphaQzK/3i1lU0fBmkSmjHsqjTt8qh
# k4jrwZe8jPkd2SKEJHTHBD1qqSmTzOu4W+H+XyWqNFjIwSNUnRuYEcM4nH49hmyl
# D0CGfAL0XAJPKMuucZ8POsgz/hElNer8usVgPdl8GNWyqdN1eANyIso6wx/vLOUu
# qfqeLLZRRv2vA9bqYGjqhRY2a4XpHsCz3cQk3IAqgUFtlD7I4MmBQQCeXr9/xQiY
# ohgsQkCz+W84J0tOgPQ9gUfgiHzqHM61dVxRLhwrfxpyKOcAtdF0xtfkn60Hk7ZT
# NTX8N+TD9l0WviFz3pIK+KBjaryWkmo++LxlVZve9Q2JJgT8JRqmJWnLwm3KfOJZ
# X5es6+8uyLzXG1k8K8zyGciTaydjGc/86Sb4ynGbf5P+NGeETpnr/LN4CTNwumam
# du0bc+sapQ3EIhMglFYKTixsTrH9z5wJuqIz7YcCAwEAAaNjMGEwHQYDVR0OBBYE
# FN0ECQei9Xp9UlMSkpXuOIAlDaZZMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgw
# FoAU3QQJB6L1en1SUxKSle44gCUNplkwDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3
# DQEBCwUAA4ICAQAgGBGUKfsmnRweHnBh8ZVyk3EkrWiTWI4yrxuzcAP8JSt0hZA9
# eGr0uYullzu1GJG7Hqf5QFuR+VWZrx4R0Fwdp2bjsZQHDDI5puobsHnYHZxwROOK
# 3cT5lR+KOEM/AYWlR6c9RrK85SJo93uc2Cw+CiHILTOsv8WBmTF0wXVxxb6x8CNF
# 9J1r/BljnaO8BMYYCyW7U4kPs4BQ3kXuRH+rlHhkmNP2KN2H2HBldPsOuRPrpw9h
# qTKWzN677WNMGLupQPegVG4giHF1GOp6tDRy4CMnd1y2kOqGJUCr7zMPy5+CvqIg
# +/a1LRrmwoWxdA/7yGUCpFIBR91JIsG/2OtrrH7e7GMzFbcjCI/GD41BWt2OxbmP
# 5UU/eNu60htAsf5xTT/ggaK6XrTsFeCT3QgffuFVmQsh3pOeCvvmo0m9NjD+53ey
# oHWXtS2BiBdlIPfakACfyVLMMso1fPU9D9gr1/UmbMkGNJYW6nBZGjJ5eQu2iH8P
# Ukg9v2zYokQu0U63cljTiROV/kSr+NeLG26cvCygW9VqAK9fN+HV+hALmJyG5yaP
# zvDsbopXC4DjTrLAoGNhkLpVaDd0araS25+hhiK2ZScO7LafQmDkZ8K12kELxNOL
# YRu8+h+RK9dEB166KazZxenvU0ha64DxKFghzbAGVfsnP1OQcKkEHlcnuTCCBnIw
# ggRaoAMCAQICCGQzUdPHOJ8IMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVT
# MQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NM
# IENvcnBvcmF0aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlv
# biBBdXRob3JpdHkgUlNBMB4XDTE2MDYyNDIwNDQzMFoXDTMxMDYyNDIwNDQzMFow
# eDELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9u
# MREwDwYDVQQKDAhTU0wgQ29ycDE0MDIGA1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25p
# bmcgSW50ZXJtZWRpYXRlIENBIFJTQSBSMTCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBAJ+DE3OqsMZtIcvbi3qHdNBx3I6Xcprku4g0tN2AA8YvRaR0mr8e
# D1Dqnm1485/6USapPZ3RspRXPvs5iRuRK1bvZ8vmC+MOOYzGNfSMPd0l6QGsF0J9
# WBZA3PnVKEQdlWQwYTpk8pfXc0x9eyMCbfN161U9b6otxK++dKxd/mq2/OpceekP
# Q5y1UgUP7z6xsY/QSa2m40IZVD/zLw6hy3z+E/kjOdolHLg+AEo6bzIwN2Qex651
# B9hV0hjJDoq8o1zwfAqnhYHCDq+PmVzTYCW8g1ppHCUTzXL165yAm9wsZ8TdyQmY
# 1XPrxCGj5TKOPi9SmMZgN2SMsm9KVHIYzCeH+s11omMhTLU9ZP0rpptVryZMYLS5
# XP6rQ72t0BNmUB8L0omm/9eABvHDEQIzM2EX91Yfji87aOcV8XdWSimeA9rCKyZh
# MlugVuVJKY02p/XHUqJWAyAvOHiAvfYGrkE0y5RFvZvHiRgfC7r/qa5qQJkT3e9Q
# 3wG68gTW0DHfNDheV1vIOB5W1KxIpu3/+bjBO+3CJL5EYKd3zdU9mFm0Q+qqYH3N
# wuUv8ev11CDVlzRuXQRrBRHS05KMCSdE7U81MUZ+dBkFYuyJ4+ojcJjk0S/UihMY
# RpNl5Vhz00w9J3oiP8P4o1W3+eaHguxFHsVuOnyxTrmraPebY9WRQbypAgMBAAGj
# gfswgfgwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTdBAkHovV6fVJTEpKV
# 7jiAJQ2mWTAwBggrBgEFBQcBAQQkMCIwIAYIKwYBBQUHMAGGFGh0dHA6Ly9vY3Nw
# cy5zc2wuY29tMBEGA1UdIAQKMAgwBgYEVR0gADATBgNVHSUEDDAKBggrBgEFBQcD
# AzA7BgNVHR8ENDAyMDCgLqAshipodHRwOi8vY3Jscy5zc2wuY29tL3NzbC5jb20t
# cnNhLVJvb3RDQS5jcmwwHQYDVR0OBBYEFFTC/hCVAJPNavXnwNfZsku4jwzjMA4G
# A1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOCAgEA9Q8mh3CvmaLK9dbJ8I1m
# PTmC04gj2IK/j1SEJ7bTgwfXnieJTYSOVNEg7mBD21dCPMewlfa+zOqjPY5PBsYr
# WYZ/63MbyuVAJuA9b8z2vXHGzX0OIEA51gXSr5QIv3/CUbcrtXuDIfBj2uWc4Wku
# dR1Oy2Ee9aUz3wKdFdntaZNXukZFLoC8Zb7nEj7eR/+QnBCt9laypNT61vwuvJch
# s3aD0pH6BlDRsYAogP7brQ9n7fh93NlwW3q6aLWzSmYXj+fw51fdaf68XuHVjJ8T
# u5WaFft5K4XVbT5nR24bB1z7VEUPFhEuEcOwvLVuHDNXlB7+QjRGjjFQTtszV5X6
# OOTmEturWC5Ft9kiyvRaR0ksKOhPjEI8ZGjp5kOsGZGpxxOCX/xxCje3nVB7PF33
# olKCNeS159MKb2v+jfmk19UdS+d9Ygj42desmUnbtYRBFC72LmCXU0ua/vGIenS6
# nnXp4NqnycwsO3tMCnjPlPc2YLaDPIpUy04NaCqUEXUmFOogN8zreRd2VXhxbeJJ
# ODM32+RsWccjYua8zi5US/1eAyrI3R5LcUTQdT4xYmWLKabtJOF6HYQ0f6QXfLSs
# fT81WMvDvxrdn1RWbUXlU/OIiisxo8o+UNEANOwnCMNnxlzoaL/PLhZluDxm/zuy
# lauajZ3MlPDteFB/7GRHo50wggaYMIIEgKADAgECAhBVwCSN2uOPeP7iNFdxurkC
# MA0GCSqGSIb3DQEBCwUAMHgxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQ
# MA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENvcnAxNDAyBgNVBAMMK1NT
# TC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBDQSBSU0EgUjEwHhcNMjUw
# ODExMTY0MDM4WhcNMjYwODEzMTY0MDM4WjB/MQswCQYDVQQGEwJVUzEQMA4GA1UE
# CAwHRmxvcmlkYTEaMBgGA1UEBwwRQWx0YW1vbnRlIFNwcmluZ3MxIDAeBgNVBAoM
# F1Byb3ZhbCBUZWNobm9sb2dpZXMgSW5jMSAwHgYDVQQDDBdQcm92YWwgVGVjaG5v
# bG9naWVzIEluYzCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAKr0IQn+
# /jLR4pu0N3TPJaAu31BLTo5myZZxgEqw8daUfcUC3/K20pDCwTzjIEe3Rb/5xrs5
# NQhnlCrrVslrLU2vWlWIuDzrdahSapAH66AbHc9fwsHUCdpWRKglgDoaaAo4KDYS
# yR5BkRqlS4Zc/MbH7+T4hYWrmWGd6DiuQuROdyaTLG6mu+TB7clKMSl0aakOccYl
# 23+1RNPN9QIDv3Hv6V6C6mpqPJ/z7wSnHGH/ELiGcexIGDCoWon2H9/su6nbAn/R
# FR+4iwjGeIa9a7oDFs5e6Nk0ulR/PjMHVGhxMAm1dV2Fsd2lrP1pGA15k8GWi/h+
# V6u5C1toJtnFzy8E+q45U/6zyo2PQd4HlPzw9auzy9l6X4tMtMEQD55G8TR/+VYx
# 7ruJa9VCl477XcOY99oPyaWOYiliU7NbqtYcINHNun6xyDSC3pRidNOMHkovEXmn
# 3sAEYOgDLkNo7sljfXdWd/kawVXEOtZ7WqjdKcysZEdE6MrwGRtruufFdQIDAQAB
# o4IBlTCCAZEwDAYDVR0TAQH/BAIwADAfBgNVHSMEGDAWgBRUwv4QlQCTzWr158DX
# 2bJLuI8M4zB6BggrBgEFBQcBAQRuMGwwSAYIKwYBBQUHMAKGPGh0dHA6Ly9jZXJ0
# LnNzbC5jb20vU1NMY29tLVN1YkNBLUNvZGVTaWduaW5nLVJTQS00MDk2LVIxLmNl
# cjAgBggrBgEFBQcwAYYUaHR0cDovL29jc3BzLnNzbC5jb20wUQYDVR0gBEowSDAI
# BgZngQwBBAEwPAYMKwYBBAGCqTABAwMBMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8v
# d3d3LnNzbC5jb20vcmVwb3NpdG9yeTATBgNVHSUEDDAKBggrBgEFBQcDAzBNBgNV
# HR8ERjBEMEKgQKA+hjxodHRwOi8vY3Jscy5zc2wuY29tL1NTTGNvbS1TdWJDQS1D
# b2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jcmwwHQYDVR0OBBYEFFD+6iHV3C018c3s
# o1Yy1la03bfgMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEABh47
# CluH23DIUb+EEbxAqBHOmFDZGkh9rDcspOuce8H7iDRuSfZeChrMdJMiNLQwbATh
# 0AKPVDzfXHgIiGwDjgQrPazLUJ+bZlo1enDtU2Npo0Np6WGCjswjo6Et5Xf0UL7h
# vUjeN9a/yJSpb5tQ7Tl3zZ4xGDt5k9SCj/ErGiwoZd00fJ9Il6mbGjDoW5k8RVP7
# Mw6oP1KQ/qVJfc8RZwbaI7x/ZdPGliy7CJ//Ec1ZTzIuuuU3kClHtSxwNr7VHL0k
# uo1db3JQizTmNgncJFNM6/NH86B9p9ogPROgj/di5Cd7259wCgoUr/H8uZ5JvqwN
# JYDyZwbsq4pSnAh5nk01zayn6qED9myhWNHORekEszcp3gsPAvc3VuyWhixjXMr0
# Npfxr09WmUy4mR2dNiYEUpkOckEMER8liloPF10pTRsqz5QD9/vM/XkgS0xQUfg/
# Qd2t2aid/KHKDa8PdAXtQ0GJHfxo8H3xIyuDKOs2U8XdeT+JQKdZ0MTl54dSJ1QA
# pPf1jESysT+/SS+ndS61Q9v3DDfViFEmMWUqgN6KlGvszv271a6PMyPipmsn0w6S
# T9gnT2w6XxtNZQnjiLJCMO86XjUh2NKK7o2W3l9cdR2sb5+NRSUU4n3MbA4Mlc9p
# M8GqIJ7wG4YvRAuw7ZXRPzIdwV9u0/hhGLNiLa0xghIMMIISCAIBATCBjDB4MQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmluZyBJ
# bnRlcm1lZGlhdGUgQ0EgUlNBIFIxAhBVwCSN2uOPeP7iNFdxurkCMA0GCWCGSAFl
# AwQCAQUAoIGvMBQGCisGAQQBgjcCAQwxBjAEoQKAADAZBgkqhkiG9w0BCQMxDAYK
# KwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAtBgkqhkiG
# 9w0BCTQxIDAeMA0GCWCGSAFlAwQCAQUAoQ0GCSqGSIb3DQEBCwUAMC8GCSqGSIb3
# DQEJBDEiBCBy9X45J8Q4Z1dcLBkE7wu//EjfAg57G9E7PkhrIWmmKTANBgkqhkiG
# 9w0BAQsFAASCAYB9EqTg9xt67SKvQIH62ckXhPZnD0pK23qILobzmKopfQ2QM3Dw
# lHbFd3m92O24tTnZ223UTlispYRXZtzFj6scTw58TyV+WaEeGGT6ffz7RX2+v+hK
# dSDqdzhBdHMyahnHrnczQeR155s3qx6wqyJWSbOEtMHrPtfOZDhw9jl9wdtpInKe
# niNNvgaRn/L4qldxOeY+gVSAGmT2cJGvFwq+hw4K+B92urjMkyVFgAeHMy/45ywr
# xp/HKLfNfiCzUiiFGc3D8SIQO3tMasJvLdNNhxDV1szQnhtCATelAq9RwDfY7y31
# uqjP1MngxzseNLlbma7bPnwUFXS3oLlm8eaW/Jlkszs7ejopBXsITHCrmNfe1CXG
# TovZeGoWUsZp0MVX5zFMtubCBYCC5fNsuaat654HxUuXImAE4pjIbO+ugZ2nHgbN
# rxhH54vJi5QMalMeAfr1/QR5e3aSruZfvQ+LfvZLO73xtMxizSDVT32/Xo/k0vPU
# hDlVdHAVOgKTl/Khgg8eMIIPGgYKKwYBBAGCNwMDATGCDwowgg8GBgkqhkiG9w0B
# BwKggg73MIIO8wIBAzENMAsGCWCGSAFlAwQCATB/BgsqhkiG9w0BCRABBKBwBG4w
# bAIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUDBAIBBQAEIE8/ui6w+kO9rTtf
# ShiNHaM2yHARQ2AQ5SScnU9PfHPCAghQU+NF3a7v6BgPMjAyNjA2MDIxNjE5MTBa
# MAMCAQECBgGeiSG/FqCCDAAwggT8MIIC5KADAgECAhAfaxZi0i4bbF3xwMGgYA44
# MA0GCSqGSIb3DQEBCwUAMHMxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQ
# MA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNT
# TC5jb20gVGltZXN0YW1waW5nIElzc3VpbmcgUlNBIENBIFIxMB4XDTI1MDIxODE2
# MzIwMloXDTM0MTExMjE4NTAwNVowbjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRl
# eGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEqMCgGA1UE
# AwwhU1NMLmNvbSBUaW1lc3RhbXBpbmcgVW5pdCAyMDI1IEUxMFkwEwYHKoZIzj0C
# AQYIKoZIzj0DAQcDQgAEG/tRUcdv5lWW7E9eV8Tczq2DReerx2Jz47e884JGlqVQ
# zW870D4ZHNJVWPLKAeFisHDrZcsWHWS/t77JF39pNqOCAVowggFWMB8GA1UdIwQY
# MBaAFAydECWOmqcbmYdDzwh+4b2BkPTPMFEGCCsGAQUFBwEBBEUwQzBBBggrBgEF
# BQcwAoY1aHR0cDovL2NlcnQuc3NsLmNvbS9TU0wuY29tLXRpbWVTdGFtcGluZy1J
# LVJTQS1SMS5jZXIwUQYDVR0gBEowSDA8BgwrBgEEAYKpMAEDBgEwLDAqBggrBgEF
# BQcCARYeaHR0cHM6Ly93d3cuc3NsLmNvbS9yZXBvc2l0b3J5MAgGBmeBDAEEAjAW
# BgNVHSUBAf8EDDAKBggrBgEFBQcDCDBGBgNVHR8EPzA9MDugOaA3hjVodHRwOi8v
# Y3Jscy5zc2wuY29tL1NTTC5jb20tdGltZVN0YW1waW5nLUktUlNBLVIxLmNybDAd
# BgNVHQ4EFgQUznzZwASAxSQQagnqHKslPRH9qNIwDgYDVR0PAQH/BAQDAgeAMA0G
# CSqGSIb3DQEBCwUAA4ICAQCAc3Ukhb1mU2KnTsV9j2vUsnAspOXWH/L2vUGMOAcw
# TPtTsnuYDLfYnEDUovKMIImo2S5F+EMcYUR9m2NM6u7sBAwNIOJQO8IJzeNrPmnL
# 2Ma/Ah7memQttepeED5KoLMbvX1RKKDCEeRivu/w2JehpjRe7TenQGJlmt5mWmeC
# YYH37zo33gWogXHYjlnmK67t3iPtoA5kE3F9T2MUMggYO1Z9Z4KkXRDyssT/cMcO
# XMkqzkiXeL9Wg6XutNT3fyhKvEzDDDoYMGUpfysYfG+SOAhv0xeRWCUlIMew0BkN
# 4JL+KdrEocD4KG4Hwrg7EjFrqTV754cHKlqQBjfC43vDs+U+aE3qTkh2pmfcdkez
# ZWOhHzjVn3CZU8V0YN2QFntc6Zvk5lRoq5+y+0RHRVtjYOTNqoBoi23WRz4j4VTP
# s+JXPY9TOl6CR+1FHG+s/IgvTxuUlOdsxDReuoM3SsR+5Mu/heGGcrIlpeHEJR2M
# 79xG6YzNnflBNQwi0FbLXEanSLKgVWcDJrak+xUy4Aj6zLXPGU5L2XmJLG8onyCm
# ek6COphNru7V7Jmj7gmVwaiKJHXsu2ExOsXWrra07nE6kjy3FRnqC0oa2QlXrB2P
# 69ktzApnYz3capWk6jpQGUaPHWwqxVnsAhTMlmWLg0nQzYphyt82eV5uRgqkOdKp
# bDCCBvwwggTkoAMCAQICEG1SGHCH6CNNhWAA0ICPk1YwDQYJKoZIhvcNAQELBQAw
# fDELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9u
# MRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24xMTAvBgNVBAMMKFNTTC5jb20gUm9v
# dCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBSU0EwHhcNMTkxMTEzMTg1MDA1WhcN
# MzQxMTEyMTg1MDA1WjBzMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAO
# BgNVBAcMB0hvdXN0b24xETAPBgNVBAoMCFNTTCBDb3JwMS8wLQYDVQQDDCZTU0wu
# Y29tIFRpbWVzdGFtcGluZyBJc3N1aW5nIFJTQSBDQSBSMTCCAiIwDQYJKoZIhvcN
# AQEBBQADggIPADCCAgoCggIBAK5REBPS+TwgoCCF3slQHGTJ4f3F6TT/Cn8xSOhy
# WsVeqGH98Yf3UVz7t+bQwcITsD7CY6KoGP04OskBgareubfeMKcdKwIE1YBBjKhq
# 4urwiOqxLUmVcvb2oM0wx3BnxQ3NBLu9ZkwMnjQlIY2mEwZMgDaqfZuiEa2BFzin
# Xf3kRLKlQ5oa8ne3QU0vcG4qZvphy0xxBQXayqigzN3z2HQTq6N28EOjpnA2dajG
# PtiZ9aNJeDfcDka5j3KbhBkzk4RWCjx5vP8H6DKHIIs02GHgxv/jG8JMIxWY1isG
# +IaB09livKbxlvzhNAKZK5fQmUstrpYrVo7qqXAhJtv1tUaHzrp6QpuUL9dE/bSA
# C7UKO9xhyJSA1OsYWDx/wAmBA84JzX8IJ1olJjCEmlJ2F4o6dCARKA2Zhk+EU4Lo
# gpowBReTlTW2NNwUKAW+8Cte0rhrMBZQ47Vjd92V0gEvouOTMtQJgk2QVeqGwFVw
# 8y4HSdQNa8sl8+Kay2MnyUXhLoQLFaeVaLs4SVXBOe3Ua1Gp5j3J2+8Yue1T4V5w
# rsNuocNR3frpSt4yRIG3N68Bz1qqhk+eNUyO8WpXWlg6POZOJUdm0BzzRsB8V7ks
# t8nM8joOe03KqhunBN69Ckeo8M32qo07zeveRrDwD2P4dmJLDYBflwZ1A/SQbS+H
# N+AHAgMBAAGjggGBMIIBfTASBgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaA
# FN0ECQei9Xp9UlMSkpXuOIAlDaZZMIGDBggrBgEFBQcBAQR3MHUwUQYIKwYBBQUH
# MAKGRWh0dHA6Ly93d3cuc3NsLmNvbS9yZXBvc2l0b3J5L1NTTGNvbVJvb3RDZXJ0
# aWZpY2F0aW9uQXV0aG9yaXR5UlNBLmNydDAgBggrBgEFBQcwAYYUaHR0cDovL29j
# c3BzLnNzbC5jb20wPwYDVR0gBDgwNjA0BgRVHSAAMCwwKgYIKwYBBQUHAgEWHmh0
# dHBzOi8vd3d3LnNzbC5jb20vcmVwb3NpdG9yeTATBgNVHSUEDDAKBggrBgEFBQcD
# CDA7BgNVHR8ENDAyMDCgLqAshipodHRwOi8vY3Jscy5zc2wuY29tL3NzbC5jb20t
# cnNhLVJvb3RDQS5jcmwwHQYDVR0OBBYEFAydECWOmqcbmYdDzwh+4b2BkPTPMA4G
# A1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOCAgEAkhl1DaZaQs8ZB9ny/JT6
# wJvwFelEllovcTPdUOUTe5mTdw/E+3JtV8u6ppyLRbpIHbYlMy20KJAychU6xdac
# i4BsP9oVNxSRMsEjfHKz7ARqPNdpclhYAINLjsFGMO1iUNbXiAsnF/xboNCgfeMc
# MYbLyQYkU6UMobv9isrtQZ8e0EAQNV7qXJn4W0KyuTt0P8iIv/5DdDpIUBIktDZc
# jz2KEW6B1gvvsKIM1esjYwWylAazBcQAake5pANMdSn8t1HdPKsiwuWfOguyRQaz
# AX8oXz6SlZSIok0Lis9a02vGVtdhEaB0R3HxIyNRMMKWV1yuSeUXFuoexWav3GRP
# ZC0WYb50SrW/l+wgrS8doetaMwyZon2L7ioYlIPSy1h9Dq/Q911PsSkbEZ3zrsB1
# roVnIfBu5BJp0xvQrQ/Q4LavuvCoFR7QFoypNrotbNYi2AGMZw5td4zGZtCqUTPZ
# i0BwSuRm+HRYAEMMThTwbJX/fYV1oC8mBN970yIvadIGKhh7+DmYdRJYBrL8inVF
# CZAK+YX2w1+qWEnCSPL/VTWJtSRMhQFfceDKbJC+pBNksvKzqkva0J1ZyMj1i4vD
# fSuBmbz4rfzsvvJxS+quZDdkmW6MeXevWGBXvqzdbAw+AqTVsAQUyP6tFeKZIL4S
# /fSFdl2rIx2X+KXkqx3S+EYxggJYMIICVAIBATCBhzBzMQswCQYDVQQGEwJVUzEO
# MAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAPBgNVBAoMCFNTTCBD
# b3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVzdGFtcGluZyBJc3N1aW5nIFJTQSBD
# QSBSMQIQH2sWYtIuG2xd8cDBoGAOODALBglghkgBZQMEAgGgggFhMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNjAyMTYxOTEw
# WjAoBgkqhkiG9w0BCTQxGzAZMAsGCWCGSAFlAwQCAaEKBggqhkjOPQQDAjAvBgkq
# hkiG9w0BCQQxIgQgSxnPkN47Ivd5/GQEfY/ESyFUe1vN+OrIMhzyyeiOiHswgckG
# CyqGSIb3DQEJEAIvMYG5MIG2MIGzMIGwBCBUKvmhao1yLmYRSXiK6ZTBipqu5aZc
# s0SiVJr5bHnHizCBizB3pHUwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFz
# MRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwm
# U1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEB9rFmLSLhts
# XfHAwaBgDjgwCgYIKoZIzj0EAwIERzBFAiBPxh3JnFfFacbFmmrNdsahObd7JE2/
# bWlQe/z2OpUjsAIhAJCP9qBQ9feyQHPOt8Hb1Bd/DyL8IPfqDx2UuxyvL2cO
# SIG # End signature block
