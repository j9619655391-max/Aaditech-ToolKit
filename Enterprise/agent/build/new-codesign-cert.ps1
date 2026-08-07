# new-codesign-cert.ps1 - generates the INTERNAL code-signing CA + signing cert
# for IT-Toolkit. Run ONCE on a Windows machine (or the CI runner) and keep the
# outputs safe: the PFX is the private key that signs every release.
#
# Because this is an INTERNAL tool (intranet-only), a self-signed code-signing
# cert is sufficient: you push the public CER to every client's "Trusted
# Publishers" store via GPO/Intune and Windows stops showing SmartScreen
# warnings. No purchased certificate needed.
#
# Outputs (Enterprise/agent/build/codesign/):
#   IT-Toolkit-CodeSign-CA.pfx   -> base64 this into the CODESIGN_PFX_B64 secret
#   IT-Toolkit-CodeSign-CA.cer   -> public cert; commit it and push via GPO
#   codesign-password.txt        -> the random PFX password (DO NOT COMMIT)
#
# Usage:
#   pwsh ./Enterprise/agent/build/new-codesign-cert.ps1

[CmdletBinding()]
param(
    [string]$OutDir = "$PSScriptRoot\codesign"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# Random strong password for the PFX (printed + saved to a local file).
$Password = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
$SecurePass = ConvertTo-SecureString -String $Password -Force -AsPlainText

# 1) Self-signed root with CodeSigning EKU.
$Root = New-SelfSignedCertificate `
    -Subject "CN=IT-Toolkit Internal Code-Signing CA" `
    -Type CodeSigningCert `
    -CertStoreLocation Cert:\CurrentUser\My `
    -KeyExportPolicy Exportable `
    -KeyUsage DigitalSignature `
    -TextExtension @("2.5.29.19={text}CA=true") `
    -NotAfter (Get-Date).AddYears(10)

# 2) Code-signing leaf signed by the root.
$Leaf = New-SelfSignedCertificate `
    -Subject "CN=IT-Toolkit Enterprise" `
    -Type CodeSigningCert `
    -CertStoreLocation Cert:\CurrentUser\My `
    -Signer $Root `
    -KeyExportPolicy Exportable `
    -KeyUsage DigitalSignature `
    -TextExtension @("2.5.29.19={text}CA=false") `
    -NotAfter (Get-Date).AddYears(5)

# 3) Export: PFX (private key) + CER (public).
$pfx = Join-Path $OutDir 'IT-Toolkit-CodeSign-CA.pfx'
$cer = Join-Path $OutDir 'IT-Toolkit-CodeSign-CA.cer'
Export-PfxCertificate -Cert $Leaf -FilePath $pfx -Password $SecurePass -Force | Out-Null
Export-Certificate -Cert $Leaf -FilePath $cer -Force | Out-Null
Set-Content -Path (Join-Path $OutDir 'codesign-password.txt') -Value $Password

# Clean the ephemeral leaf/root out of the local store (the PFX holds the key).
Get-ChildItem Cert:\CurrentUser\My | Where-Object {
    $_.Thumbprint -in @($Leaf.Thumbprint, $Root.Thumbprint)
} | Remove-Item -Force

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pfx))
$b64 | Set-Content -Path (Join-Path $OutDir 'codesign-pfx.b64')

Write-Host "Code-signing CA created in $OutDir"
Write-Host "  PFX:  IT-Toolkit-CodeSign-CA.pfx  (password: $Password)"
Write-Host "  CER:  IT-Toolkit-CodeSign-CA.cer"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1) Set GitHub secrets:"
Write-Host "       CODESIGN_PFX_B64      = base64 of the PFX (see codesign-pfx.b64)"
Write-Host "       CODESIGN_PFX_PASSWORD = $Password"
Write-Host "  2) Commit the .cer and push it to clients' 'Trusted Publishers' via GPO:"
Write-Host "       Computer Config > Policies > Windows Settings > Security Settings >"
Write-Host "       Public Key Policies > Trusted Publishers > Import -> IT-Toolkit-CodeSign-CA.cer"
Write-Host "  3) CI now auto-signs IT-Toolkit-Agent.exe/.msi with signtool."
