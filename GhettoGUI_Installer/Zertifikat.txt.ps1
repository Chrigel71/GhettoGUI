New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=GhettoGUIScripts" -CertStoreLocation "Cert:\CurrentUser\My" -KeyAlgorithm RSA -KeyLength 2048


# Schritt 1: Das Zertifikat erneut in eine Variable laden (wie zuvor)
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Thumbprint -eq '5512BC3D9B736A3F53C836172A6A82CEBEA581C9' }

# Schritt 2: Den Ziel-Zertifikatsspeicher öffnen
$store = Get-Item 'Cert:\CurrentUser\Root'
$store.Open('ReadWrite')

# Schritt 3: Das Zertifikat in den Speicher für vertrauenswürdige Stammzertifikate kopieren
$store.Add($cert)
$store.Close()

# Schritt 4: Den Signierungs-Befehl erneut ausführen
Set-AuthenticodeSignature -FilePath "C:\Users\Admin\Documents\Ghetto\GhettoGUI_Installer\SourceFiles\GhettoGUI.exe" -Certificate $cert

Export-Certificate -Cert (Get-Item Cert:\CurrentUser\My\5512BC3D9B736A3F53C836172A6A82CEBEA581C9) -FilePath "C:\Users\Admin\Documents\Ghetto\GhettoGUI_Installer\SourceFiles\GhettoGUIScripts_public.cer"