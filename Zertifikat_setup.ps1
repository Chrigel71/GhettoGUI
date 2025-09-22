New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=GhettoGUIInstaller" -CertStoreLocation "Cert:\CurrentUser\My" -KeyAlgorithm RSA -KeyLength 2048


# Schritt 1: Das Zertifikat erneut in eine Variable laden (wie zuvor)
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Thumbprint -eq '9FD76B755F423DF82E2F1E9BC1C50C30CB06A6C6' }

# Schritt 2: Den Ziel-Zertifikatsspeicher öffnen
$store = Get-Item 'Cert:\CurrentUser\Root'
$store.Open('ReadWrite')

# Schritt 3: Das Zertifikat in den Speicher für vertrauenswürdige Stammzertifikate kopieren
$store.Add($cert)
$store.Close()

# Schritt 4: Den Signierungs-Befehl erneut ausführen
Set-AuthenticodeSignature -FilePath "C:\Users\Admin\Documents\Ghetto\GhettoGUI_Installer\Release\GhettoGUI-Setup-V7.5.0.0.exe" -Certificate $cert

Export-Certificate -Cert (Get-Item Cert:\CurrentUser\My\9FD76B755F423DF82E2F1E9BC1C50C30CB06A6C6) -FilePath "C:\Users\Admin\Documents\Ghetto\GhettoGUI_Installer\Release\GhettoGUIInstaller_public.cer"