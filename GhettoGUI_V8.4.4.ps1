# GhettoGUI_V8.4.4.ps1
#
# --- VERSION V8.4.4 (Final Stable Release by Gemini & Chrigel#71)
# - FIX: Job laden lädt jetzt automatisch die VM-Liste und synchronisiert die Checkboxen korrekt.
# - NEU: Restore-Funktion zeigt Live-Fortschritt des Kopiervorgangs im Log an.
# - NEU: Sicherheitsabfrage (MessageBox) vor dem Starten eines Restore-Jobs.
# - FIX: Button "Diesen Ordner auswählen" wird jetzt in der korrekten Grösse dargestellt.
# - NEU: Abschluss-Popups für Replikation & Restore sind kontext-sensitiv und zeigen den VM-Namen an.
# - NEU: Restore-Funktion versendet jetzt ebenfalls eine detaillierte E-Mail-Benachrichtigung.
# - FIX: "Speichern"-Button im Replikations-Dialog wurde durch eine "Speichern unter..."-Funktion ersetzt.
# - FIX: Timeout für alle SSH- und SFTP-Verbindungen auf 60 Sekunden erhöht, um Probleme mit langsamen Hosts zu beheben.
# - Fix: email und Cron für ESXi 6.0
# - Neu: ESXI Update .zip / .vib
# - Neu: Cron mit 2-Wöchentlich und Monthly
# - NEU: Proxmox 9.0


# Diese Zeilen MÜSSEN ganz am Anfang stehen:
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
# Import-Module Posh-SSH -ErrorAction Stop

# --- Globale Hilfsfunktion für farbige Log-Ausgaben in der SSH-Konsole ---
function Write-ConsoleLog($box, $message, $color=[System.Drawing.Color]::White) {
    if ($box -and -not $box.IsDisposed) {
        try {
            # Invoke wird benötigt, um aus einem anderen Thread sicher auf das GUI-Element zuzugreifen
            $box.Invoke([Action]{
                $box.SelectionColor = $color
                $box.AppendText("$message`n")
                $box.ScrollToCaret()
            })
        } catch {}
    }
}

# --- Globale Variablen ---
$Global:ReplicationQueue = New-Object System.Collections.Generic.List[string]
$Global:ESXiSession = $null
$Global:ESXiSshCredential = $null
$Global:ESXiConnectedHostName = $null
$Global:outputBoxGUIRef = $null
$Global:logPollTimer = $null
$Global:TargetESXiSession = $null
$Global:TargetESXiSshCredential = $null
$Global:replicationJob = $null
$Global:replicationJobTimer = $null
$Global:LastKnownTargetHost = ""
$Global:trafficPollTimer = $null # NEU für Netzwerk-Monitor
$Global:currentJobTargetName = $null # NEU für Abschlussmeldung
$Global:currentJobType = $null # NEU für Job-Typ in Abschlussmeldung
$script:replicationUseLocalTemp = $true
$script:replicationTempPath = ""
$Global:ProxmoxSession = $null
$Global:ProxmoxSshSession = $null
$Global:PinnedScrollPosition = $null # <<< NEUE ZEILE HINZUFÜGEN

# --- Robuste Skript-Pfad Ermittlung ---
if ($PSScriptRoot) {
    $Global:ScriptPath = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $Global:ScriptPath = Split-Path $MyInvocation.MyCommand.Path
} else {
    try {
        $Global:ScriptPath = Split-Path (Get-Process -Id $PID).Path -ErrorAction Stop
    } catch {
        $Global:ScriptPath = (Get-Location).Path
    }
}

# --- GUI Definition ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "GhettoGUI ESXi & GhettoVCB Manager V8.4.4 / 21.01.2026"
$form.Size = New-Object System.Drawing.Size(830, 830) # Breite angepasst
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.MinimumSize = New-Object System.Drawing.Size(100, 100)
$form.MaximumSize = New-Object System.Drawing.Size(830, 900)
$form.AutoScroll = $true # Aktiviert die AutoScroll-Funktion
$form.AutoScrollMinSize = New-Object System.Drawing.Size (810, 800) # <-- KORRIGIERTE ZEILE

$toolTip = New-Object System.Windows.Forms.ToolTip


# --- NEU: Tab-Control für ESXi und Proxmox ---
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill

$esxiTab = New-Object System.Windows.Forms.TabPage
$esxiTab.Text = "ESXi Manager 6.0-8.0"
$esxiTab.Padding = New-Object System.Windows.Forms.Padding(5)

$proxmoxTab = New-Object System.Windows.Forms.TabPage
$proxmoxTab.Text = "Proxmox Manager 9.0"
$proxmoxTab.Padding = New-Object System.Windows.Forms.Padding(10)

$tabControl.Controls.AddRange(@($esxiTab, $proxmoxTab))
# --- ENDE NEU ---

# --- Helper Funktionen ---
function Write-GuiLog ($message) {
    if ($Global:outputBoxGUIRef) {
        if ($Global:outputBoxGUIRef.IsDisposed) { return }
        try {
            $Global:outputBoxGUIRef.Invoke([Action]{
                $Global:outputBoxGUIRef.AppendText("$(Get-Date -Format 'HH:mm:ss'): $message`r`n")
                $Global:outputBoxGUIRef.ScrollToCaret()
            })
        } catch {}
    } else {
        Write-Host "$(Get-Date -Format 'HH:mm:ss'): $message"
    }
}
function ConvertTo-DisplaySafeString { param([string]$InputString); if ([string]::IsNullOrWhiteSpace($InputString)) { return $InputString }; $outputString = $InputString; $outputString = $outputString.Replace("ä", "ae").Replace("ö", "oe").Replace("ü", "ue").Replace("ß", "ss"); $outputString = $outputString.Replace("Ä", "Ae").Replace("Ö", "Oe").Replace("Ü", "Ue"); $outputString = $outputString.Replace("é", "e").Replace("è", "e").Replace("ê", "e").Replace("ë", "e"); $outputString = $outputString.Replace("É", "E").Replace("È", "E").Replace("Ê", "E").Replace("Ë", "E"); return $outputString }
function Show-VersionInfoPopup { $poshModule = Get-Module Posh-SSH -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1; if ($poshModule) { $psVersion = $PSVersionTable.PSVersion.ToString(); $poshVersion = $poshModule.Version.ToString(); $message = "PowerShell Version: $psVersion`nPosh-SSH Version: $poshVersion`nPfad: $($poshModule.ModuleBase)"; [System.Windows.Forms.MessageBox]::Show($message, "Diagnose-Info", "OK", "Information") } else { [System.Windows.Forms.MessageBox]::Show("Das Modul 'Posh-SSH' wurde nicht gefunden.", "Diagnose-Info", "OK", "Warning") }}

function Ensure-PoshSshModule {
    if (Get-Module Posh-SSH -ListAvailable) {
        Import-Module Posh-SSH -ErrorAction SilentlyContinue
        return $true
    } else {
        Write-GuiLog "Posh-SSH nicht gefunden. Biete Installation an..."
        $confirmInstall = [System.Windows.Forms.MessageBox]::Show("Das PowerShell-Modul 'Posh-SSH' wird benötigt und scheint nicht installiert zu sein.`n`nMöchten Sie es jetzt für den aktuellen Benutzer installieren? (Internetverbindung erforderlich)", "Posh-SSH Installation", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirmInstall -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                # Schritt 1: TLS 1.2 für die Verbindung zur PowerShell Gallery erzwingen
                Write-GuiLog "-> Setze Sicherheitsprotokoll auf Tls12 für Kompatibilität..."
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                # ### NEU: NuGet Provider automatisch installieren ###
                Write-GuiLog "-> Prüfe/Installiere den NuGet Package Provider..."
                if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                    Write-GuiLog "--> NuGet Provider nicht gefunden. Installiere automatisch..."
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
                    Write-GuiLog "--> NuGet Provider installiert."
                } else {
                    Write-GuiLog "--> NuGet Provider ist bereits vorhanden."
                }
                # ### ENDE NEU ###

                # Schritt 3: Posh-SSH installieren
                Write-GuiLog "Führe 'Install-Module Posh-SSH -Scope CurrentUser -Force' aus..."
                $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                Install-Module Posh-SSH -Scope CurrentUser -Force -Confirm:$false -ErrorAction Stop
                Write-GuiLog "Installation abgeschlossen. Importiere Modul..."
                Import-Module Posh-SSH
                if (Get-Module Posh-SSH) {
                    Write-GuiLog "Posh-SSH erfolgreich installiert und geladen!"
                    [System.Windows.Forms.MessageBox]::Show("Posh-SSH wurde erfolgreich installiert und geladen!", "Erfolg", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                    return $true
                } else {
                    Write-GuiLog "Posh-SSH konnte nicht sofort geladen werden. Bitte GUI neu starten."
                    return $false
                }
            } catch {
                Write-GuiLog "FEHLER bei Installation: $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("FEHLER bei der Installation von Posh-SSH:`n$($_.Exception.Message)`n`nStellen Sie sicher, dass eine Internetverbindung besteht und Sie PowerShell ggf. als Administrator ausführen.", "Installationsfehler", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                return $false
            } finally {
                $form.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        } else {
            Write-GuiLog "Installation von Posh-SSH durch Benutzer abgebrochen."
            return $false
        }
    }
}

function Show-CredentialPrompt {
    param(
        [string]$UserName,
        [string]$Message,
        [switch]$ShowReloadJobCheckbox
    )

    $formCred = New-Object System.Windows.Forms.Form
    $formCred.Text = "Anmeldeinformationen"
    # Passe die Grösse dynamisch an, je nachdem ob die Checkbox angezeigt wird
    if ($ShowReloadJobCheckbox) { $formCred.Size = New-Object System.Drawing.Size(400, 240) }
    else { $formCred.Size = New-Object System.Drawing.Size(400, 200) }
    $formCred.StartPosition = "CenterParent"
    $formCred.FormBorderStyle = 'FixedDialog'
    $formCred.MaximizeBox = $false
    $formCred.MinimizeBox = $false

    $labelMessage = New-Object System.Windows.Forms.Label; $labelMessage.Text = $Message; $labelMessage.Location = New-Object System.Drawing.Point(20, 20); $labelMessage.AutoSize = $true
    $formCred.Controls.Add($labelMessage)

    $labelUser = New-Object System.Windows.Forms.Label; $labelUser.Text = "Benutzername:"; $labelUser.Location = New-Object System.Drawing.Point(20, 50); $labelUser.AutoSize = $true
    $formCred.Controls.Add($labelUser)

    $textboxUser = New-Object System.Windows.Forms.TextBox; $textboxUser.Text = $UserName; $textboxUser.Location = New-Object System.Drawing.Point(150, 47); $textboxUser.Size = New-Object System.Drawing.Size(200, 20)
    $formCred.Controls.Add($textboxUser)

    $labelPassword = New-Object System.Windows.Forms.Label; $labelPassword.Text = "Passwort:"; $labelPassword.Location = New-Object System.Drawing.Point(20, 80); $labelPassword.AutoSize = $true
    $formCred.Controls.Add($labelPassword)

    $textboxPassword = New-Object System.Windows.Forms.TextBox; $textboxPassword.Location = New-Object System.Drawing.Point(150, 77); $textboxPassword.Size = New-Object System.Drawing.Size(200, 20); $textboxPassword.UseSystemPasswordChar = $true
    $formCred.Controls.Add($textboxPassword)

    $checkboxReloadJob = $null
    if ($ShowReloadJobCheckbox) {
        $checkboxReloadJob = New-Object System.Windows.Forms.CheckBox
        $checkboxReloadJob.Text = "Ausgewählten Job nach Verbindung laden (empfohlen)"
        $checkboxReloadJob.Location = New-Object System.Drawing.Point(20, 120)
        $checkboxReloadJob.AutoSize = $true
        $checkboxReloadJob.Checked = $true
        $formCred.Controls.Add($checkboxReloadJob)
    }

    # Passe die Y-Position der Buttons an
    $buttonYPos = if ($ShowReloadJobCheckbox) { 160 } else { 120 }
    $buttonOk = New-Object System.Windows.Forms.Button; $buttonOk.Text = "OK"; $buttonOk.Location = New-Object System.Drawing.Point(190, $buttonYPos); $buttonOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $formCred.AcceptButton = $buttonOk
    $formCred.Controls.Add($buttonOk)

    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.Location = New-Object System.Drawing.Point(275, $buttonYPos); $buttonCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $formCred.CancelButton = $buttonCancel
    $formCred.Controls.Add($buttonCancel)

    $formCred.Add_Shown({$textboxPassword.Focus()})

    if ($formCred.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $securePassword = ConvertTo-SecureString $textboxPassword.Text -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($textboxUser.Text, $securePassword)
        
        # Gib je nach Aufruf ein anderes Ergebnis zurück
        if ($ShowReloadJobCheckbox) {
            return [PSCustomObject]@{
                Credential = $credential
                ReloadJob  = $checkboxReloadJob.Checked
            }
        } else {
            return $credential
        }
    } else {
        return $null
    }
}


# --- GUI Elemente Definition ---
# --- Spalte 1 (Links) ---
[int]$column1X = 20; [int]$column1Width = 380; [int]$columnSpacing = 20;
[int]$column2X = [int]($column1X + $column1Width + $columnSpacing);
# [int]$column2Width = [int]($form.ClientSize.Width - $column2X - $column1X - 200) # Platz für Traffic-Box schaffen
[int]$column2Width = 370 # Feste Breite für die rechte Spalte
[int]$currentY = 20
[int]$currentY_Col1 = $currentY


$labelIp = New-Object System.Windows.Forms.Label; $labelIp.Text = "ESXi Host IP:"; $labelIp.Location = New-Object System.Drawing.Point($column1X, ($currentY_Col1 + 3)); $labelIp.AutoSize = $true
$textboxIp = New-Object System.Windows.Forms.TextBox; $textboxIp.Location = New-Object System.Drawing.Point(($column1X + 120), $currentY_Col1); $textboxIp.Size = New-Object System.Drawing.Size(($column1Width - 130), 20)
$currentY_Col1 += 30
$labelUser = New-Object System.Windows.Forms.Label; $labelUser.Text = "ESXi Username:"; $labelUser.Location = New-Object System.Drawing.Point($column1X, ($currentY_Col1 + 3)); $labelUser.AutoSize = $true
$textboxUser = New-Object System.Windows.Forms.TextBox; $textboxUser.Location = New-Object System.Drawing.Point(($column1X + 120), $currentY_Col1); $textboxUser.Size = New-Object System.Drawing.Size(($column1Width - 130), 20); $textboxUser.Text = "root"
$currentY_Col1 += 30

# --- NEU: Job-Auswahl ComboBox ---
$labelJobSelect = New-Object System.Windows.Forms.Label; $labelJobSelect.Text = "Gespeicherter Job:"; $labelJobSelect.Location = New-Object System.Drawing.Point($column1X, ($currentY_Col1 + 3)); $labelJobSelect.AutoSize = $true
$comboboxJobs = New-Object System.Windows.Forms.ComboBox; $comboboxJobs.Location = New-Object System.Drawing.Point(($column1X + 120), $currentY_Col1); $comboboxJobs.Size = New-Object System.Drawing.Size(($column1Width - 165), 21); $comboboxJobs.DropDownStyle = "DropDownList"
$buttonRefreshJobs = New-Object System.Windows.Forms.Button; $buttonRefreshJobs.Text = "♻"; $buttonRefreshJobs.Location = New-Object System.Drawing.Point(($comboboxJobs.Right + 5), ($currentY_Col1 - 1)); $buttonRefreshJobs.Size = New-Object System.Drawing.Size(30, 25);
$toolTip.SetToolTip($buttonRefreshJobs, "Lädt die Liste der Job-Dateien neu.")
$currentY_Col1 += 30
# --- ENDE NEU ---

$connectButton = New-Object System.Windows.Forms.Button; $connectButton.Text = "Verbinden"; $connectButton.Location = New-Object System.Drawing.Point(($column1X + 140), $currentY_Col1); $connectButton.Size = New-Object System.Drawing.Size(85, 25)
$disconnectButton = New-Object System.Windows.Forms.Button; $disconnectButton.Text = "Trennen"; $disconnectButton.Location = New-Object System.Drawing.Point( ($connectButton.Location.X + $connectButton.Width + 10), $currentY_Col1); $disconnectButton.Size = New-Object System.Drawing.Size(85, 25); $disconnectButton.Enabled = $false
$currentY_Col1 += $connectButton.Height + 5

$buttonCheckPoshSsh = New-Object System.Windows.Forms.Button; $buttonCheckPoshSsh.Text = "Posh-SSH prüfen"; $buttonCheckPoshSsh.Location = New-Object System.Drawing.Point(($column1X + 5), ($currentY_Col1 - 30)); $buttonCheckPoshSsh.Size = New-Object System.Drawing.Size(110, 25)
$currentY_Col1 += $buttonCheckPoshSsh.Height + 15

$groupGhettoConfig = New-Object System.Windows.Forms.GroupBox; $groupGhettoConfig.Text = "GhettoVCB Konfiguration"; $groupGhettoConfig.Location = New-Object System.Drawing.Point(($column1X), ($currentY_Col1 - 35)); $groupGhettoConfig.Size = New-Object System.Drawing.Size(380, 395)
[int]$gcOffsetX = 10; [int]$gcOffsetY = 20; [int]$gcLabelWidth = 110; [int]$gcControlX = [int]($gcOffsetX + $gcLabelWidth + 5); [int]$gcBrowseButtonWidth = 30; [int]$gcControlWidthForBrowse = [int]($groupGhettoConfig.Width - $gcControlX - $gcOffsetX - $gcBrowseButtonWidth - 10)
$labelGhettoPath = New-Object System.Windows.Forms.Label; $labelGhettoPath.Text = "GhettoVCB-Pfad:"; $labelGhettoPath.Location = New-Object System.Drawing.Point($gcOffsetX, ($gcOffsetY + 3)); $labelGhettoPath.AutoSize = $true
$textboxGhettoPath = New-Object System.Windows.Forms.TextBox; $textboxGhettoPath.Location = New-Object System.Drawing.Point($gcControlX, $gcOffsetY); $textboxGhettoPath.Size = New-Object System.Drawing.Size($gcControlWidthForBrowse, 20); $textboxGhettoPath.Text = ""
$buttonBrowseGhettoPath = New-Object System.Windows.Forms.Button; $buttonBrowseGhettoPath.Text = "..."; $buttonBrowseGhettoPath.Location = New-Object System.Drawing.Point(([int]$textboxGhettoPath.Location.X + [int]$textboxGhettoPath.Width + 5), $gcOffsetY); $buttonBrowseGhettoPath.Size = New-Object System.Drawing.Size($gcBrowseButtonWidth, 23)
$gcOffsetY += 25
$labelBackupVol = New-Object System.Windows.Forms.Label; $labelBackupVol.Text = "Backup Volume:"; $labelBackupVol.Location = New-Object System.Drawing.Point($gcOffsetX, ($gcOffsetY + 3)); $labelBackupVol.AutoSize = $true
$textboxBackupVol = New-Object System.Windows.Forms.TextBox; $textboxBackupVol.Location = New-Object System.Drawing.Point($gcControlX, $gcOffsetY); $textboxBackupVol.Size = New-Object System.Drawing.Size($gcControlWidthForBrowse, 20); $textboxBackupVol.Text = ""
$buttonBrowseBackupVol = New-Object System.Windows.Forms.Button; $buttonBrowseBackupVol.Text = "..."; $buttonBrowseBackupVol.Location = New-Object System.Drawing.Point(([int]$textboxBackupVol.Location.X + [int]$textboxBackupVol.Width + 5), $gcOffsetY); $buttonBrowseBackupVol.Size = New-Object System.Drawing.Size($gcBrowseButtonWidth, 23)
$gcOffsetY += 25
$labelSubfolder = New-Object System.Windows.Forms.Label; $labelSubfolder.Text = "Unterordner:"; $labelSubfolder.Location = New-Object System.Drawing.Point($gcOffsetX, ($gcOffsetY + 3)); $labelSubfolder.AutoSize = $true
$textboxSubfolder = New-Object System.Windows.Forms.TextBox; $textboxSubfolder.Location = New-Object System.Drawing.Point($gcControlX, $gcOffsetY); $textboxSubfolder.Size = New-Object System.Drawing.Size($gcControlWidthForBrowse, 20);
$gcOffsetY += 30
$labelRotation = New-Object System.Windows.Forms.Label; $labelRotation.Text = "Rotation Count:"; $labelRotation.Location = New-Object System.Drawing.Point($gcOffsetX, ($gcOffsetY + 3)); $labelRotation.AutoSize = $true
$textboxRotation = New-Object System.Windows.Forms.TextBox; $textboxRotation.Location = New-Object System.Drawing.Point($gcControlX, $gcOffsetY); $textboxRotation.Size = New-Object System.Drawing.Size(50, 20); $textboxRotation.Text = "3"

# --- NEU: Checkbox für festen Backup-Pfad (rechts daneben platziert) ---
$checkboxFixedBackupDir = New-Object System.Windows.Forms.CheckBox
$checkboxFixedBackupDir.Text = "Festes Backup-Ziel"
# Position berechnen: Rechts neben der Textbox mit etwas Abstand
$checkboxX = $textboxRotation.Location.X + $textboxRotation.Width + 15
$checkboxFixedBackupDir.Location = New-Object System.Drawing.Point($checkboxX, $gcOffsetY)
$checkboxFixedBackupDir.AutoSize = $true

# Tooltip für eine bessere Erklärung hinzufügen
$toolTip.SetToolTip($checkboxFixedBackupDir, "Wenn aktiviert, wird das Backup immer in denselben Ordner geschrieben und die alte Sicherung überschrieben (ohne Datums-Unterordner).")

# NEU: Event-Handler, um die Rotations-Textbox zu deaktivieren, wenn ein festes Ziel gewählt wird.
$checkboxFixedBackupDir.Add_CheckedChanged({
    # Wenn die Checkbox aktiviert ist, deaktiviere das Textfeld für die Rotation.
    $textboxRotation.Enabled = -not $checkboxFixedBackupDir.Checked
    # Setze den Wert zur Verdeutlichung auf 1, da ein festes Ziel immer nur eine Kopie behält.
    if ($checkboxFixedBackupDir.Checked) {
        $textboxRotation.Text = "1"
    }
})

# Jetzt, nachdem alle Controls auf dieser Zeile platziert sind, den Y-Offset für die nächste Zeile erhöhen.
$gcOffsetY += 30

$labelDiskFormat = New-Object System.Windows.Forms.Label; $labelDiskFormat.Text = "Disk Format:"; $labelDiskFormat.Location = New-Object System.Drawing.Point($gcOffsetX, ($gcOffsetY + 3)); $labelDiskFormat.AutoSize = $true
$comboboxDiskFormat = New-Object System.Windows.Forms.ComboBox; $comboboxDiskFormat.Location = New-Object System.Drawing.Point($gcControlX, $gcOffsetY); $comboboxDiskFormat.Size = New-Object System.Drawing.Size(120, 21); $comboboxDiskFormat.DropDownStyle = "DropDownList"
$comboboxDiskFormat.Items.AddRange(@("thin", "zeroedthick", "eagerzeroedthick")); if ($comboboxDiskFormat.Items.Count -gt 0) { $comboboxDiskFormat.SelectedIndex = 0 }

$gcOffsetY += 25
$checkboxSnapMem = New-Object System.Windows.Forms.CheckBox; $checkboxSnapMem.Text = "Snap Memory"; $checkboxSnapMem.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $checkboxSnapMem.AutoSize = $true; $checkboxSnapMem.Checked = $true
$checkboxSnapQuiesce = New-Object System.Windows.Forms.CheckBox; $checkboxSnapQuiesce.Text = "Snap Quiesce"; $checkboxSnapQuiesce.Location = New-Object System.Drawing.Point(([int]$checkboxSnapMem.Location.X + [int]$checkboxSnapMem.Width + 8), $gcOffsetY); $checkboxSnapQuiesce.AutoSize = $true; $checkboxSnapQuiesce.Checked = $true

# --- NEU: Checkbox für Hole Punching Deaktivierung ---
$checkboxDisablePunch = New-Object System.Windows.Forms.CheckBox
$checkboxDisablePunch.Text = "Hole Punching deakt." 
$checkboxDisablePunch.Location = New-Object System.Drawing.Point(($gcControlX - 4), ($gcOffsetY + 20))
$checkboxDisablePunch.AutoSize = $true
$checkboxDisablePunch.Checked = $true 
$toolTip.SetToolTip($checkboxDisablePunch, "Wenn aktiviert (Haken gesetzt), wird KEIN Hole Punching durchgeführt.`nDas Backup ist schneller, verbraucht aber evtl. mehr Platz.")

$buttonReplicate = New-Object System.Windows.Forms.Button
$buttonReplicate.Text = "Replication"
$buttonReplicate.Size = New-Object System.Drawing.Size(115, 25)
# Positioniere den Button rechts neben "Snap Quiesce"
$buttonReplicate.Location = New-Object System.Drawing.Point(($checkboxSnapQuiesce.Location.X + $checkboxSnapQuiesce.Width + 28), ($gcOffsetY - 8))
$buttonReplicate.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$buttonReplicate.ForeColor = [System.Drawing.Color]::DarkGreen

$buttonDownloadBackup = New-Object System.Windows.Forms.Button
$buttonDownloadBackup.Text = "Backup download"
$buttonDownloadBackup.Size = New-Object System.Drawing.Size(115, 25)
$buttonDownloadBackup.Location = New-Object System.Drawing.Point(255, 176)
$buttonDownloadBackup.ForeColor = [System.Drawing.Color]::DarkSlateBlue
$buttonDownloadBackup.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)


# --- NEUER BUTTON FÜR DIREKTE REPLIKATION ---
$buttonDirectReplicate = New-Object System.Windows.Forms.Button
$buttonDirectReplicate.Text = "Direkte Replic."
$buttonDirectReplicate.Size = New-Object System.Drawing.Size(115, 25)
# Positionierung oberhalb des alten Replication-Buttons
$buttonDirectReplicate.Location = New-Object System.Drawing.Point(255, 120)
$buttonDirectReplicate.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$buttonDirectReplicate.ForeColor = [System.Drawing.Color]::DarkBlue

$gcOffsetY += 30
$labelVmList = New-Object System.Windows.Forms.Label; $labelVmList.Text = "VMs (eine pro Zeile):"; $labelVmList.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $labelVmList.AutoSize = $true
$gcOffsetY += 20
$textboxVmList = New-Object System.Windows.Forms.TextBox; $textboxVmList.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $textboxVmList.Size = New-Object System.Drawing.Size(($groupGhettoConfig.Width - (2 * $gcOffsetX)), 60); $textboxVmList.Multiline = $true; $textboxVmList.ScrollBars = "Vertical"
$gcOffsetY += $textboxVmList.Height + 10
$buttonLoadVms = New-Object System.Windows.Forms.Button; $buttonLoadVms.Text = "VMs laden"; $buttonLoadVms.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $buttonLoadVms.Size = New-Object System.Drawing.Size(70, 25)
$buttonApplyVms = New-Object System.Windows.Forms.Button; $buttonApplyVms.Text = "Auswahl übernehmen"; $buttonApplyVms.Location = New-Object System.Drawing.Point(($gcOffsetX + [int]$buttonLoadVms.Width + 5), $gcOffsetY); $buttonApplyVms.Size = New-Object System.Drawing.Size(140, 25)

$buttonRestore = New-Object System.Windows.Forms.Button
$buttonRestore.Text = "Restore/Klon/Punch"
# Positioniert den Button rechts neben "Auswahl übernehmen"
$buttonRestore.Location = New-Object System.Drawing.Point(($buttonApplyVms.Right + 5), $gcOffsetY)
$buttonRestore.Size = New-Object System.Drawing.Size(140, 25)
$buttonRestore.ForeColor = [System.Drawing.Color]::Darkred
$buttonRestore.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)


$gcOffsetY += $buttonLoadVms.Height + 5
$checkedListBoxVms = New-Object System.Windows.Forms.CheckedListBox; $checkedListBoxVms.DisplayMember = "DisplayName"; $checkedListBoxVms.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $checkedListBoxVms.Size = New-Object System.Drawing.Size(($groupGhettoConfig.Width - (2 * $gcOffsetX)), 80); $checkedListBoxVms.CheckOnClick = $true

$groupGhettoConfig.Controls.AddRange(@($labelGhettoPath, $checkboxDisablePunch, $buttonDownloadBackup, $textboxGhettoPath, $checkboxFixedBackupDir, $buttonBrowseGhettoPath, $labelBackupVol, $textboxBackupVol, $buttonBrowseBackupVol, $labelSubfolder, $textboxSubfolder, $labelRotation, $textboxRotation, $labelDiskFormat, $comboboxDiskFormat, $checkboxSnapMem, $checkboxSnapQuiesce, $buttonReplicate, $buttonDirectReplicate, $labelVmList, $textboxVmList, $buttonLoadVms, $buttonApplyVms, $buttonRestore, $checkedListBoxVms))

$currentY_Col1 = $groupGhettoConfig.Location.Y + $groupGhettoConfig.Height + 10

# KORREKTUR: Button standardmässig aktiviert
$buttonLoadGuiSettings = New-Object System.Windows.Forms.Button; $buttonLoadGuiSettings.Text = "Job laden..."; $buttonLoadGuiSettings.Location = New-Object System.Drawing.Point($column1X, $currentY_Col1); $buttonLoadGuiSettings.Size = New-Object System.Drawing.Size(185, 25); $buttonLoadGuiSettings.Enabled = $true

$buttonSaveGuiSettings = New-Object System.Windows.Forms.Button; $buttonSaveGuiSettings.Text = "Job speichern unter..."; $buttonSaveGuiSettings.Location = New-Object System.Drawing.Point( ($buttonLoadGuiSettings.Location.X + $buttonLoadGuiSettings.Width + 5), $currentY_Col1); $buttonSaveGuiSettings.Size = New-Object System.Drawing.Size(185, 25); $buttonSaveGuiSettings.Enabled = $false
$currentY_Col1 += $buttonLoadGuiSettings.Height + 5

# =====================================================================================
# --- START BLOCK (Phase 2.1: Button Layout Fix) ---
# =====================================================================================
# Button 1 (alt, aber verkleinert)

$saveConfigButton = New-Object System.Windows.Forms.Button
$saveConfigButton.Text = "Ghetto-Konfig. auf ESXi speichern"
$saveConfigButton.Size = New-Object System.Drawing.Size(375, 25) # Breite angepasst
$saveConfigButton.Location = New-Object System.Drawing.Point($column1X, $currentY_Col1)


# =====================================================================================
# --- END BLOCK ---
# =====================================================================================

$currentY_Col1 += $saveConfigButton.Height + 15


# --- Spalte 2 (Rechts) ---
[int]$currentY_Col2 = $currentY
# Block 1: Installation
$buttonInstallGitHub = New-Object System.Windows.Forms.Button; $buttonInstallGitHub.Text = "Offizielles GhettoVCB installieren"; $buttonInstallGitHub.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $buttonInstallGitHub.Size = New-Object System.Drawing.Size(200, 25)
$buttonInstallPatchedGhetto = New-Object System.Windows.Forms.Button; $buttonInstallPatchedGhetto.Text = "GhettoVCB Patch"; $buttonInstallPatchedGhetto.Location = New-Object System.Drawing.Point( ([int]$buttonInstallGitHub.Location.X + [int]$buttonInstallGitHub.Width + 10), $currentY_Col2); $buttonInstallPatchedGhetto.Size = New-Object System.Drawing.Size(160, 25); $buttonInstallPatchedGhetto.ForeColor = [System.Drawing.Color]::Blue
$currentY_Col2 += $buttonInstallGitHub.Height + 10

# NEU: Ein Dialogfenster, um die Installationsquelle auszuwählen
function Show-InstallationSourceDialog {
    param (
        [string]$Title,
        [string]$Message
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.Size = New-Object System.Drawing.Size(400, 150)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Message
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $label.AutoSize = $true
    $dialog.Controls.Add($label)

    $buttonGitHub = New-Object System.Windows.Forms.Button
    $buttonGitHub.Text = "Von GitHub laden"
    $buttonGitHub.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $buttonGitHub.Location = New-Object System.Drawing.Point(40, 60)
    $buttonGitHub.Size = New-Object System.Drawing.Size(140, 30)
    $dialog.Controls.Add($buttonGitHub)

    $buttonLocal = New-Object System.Windows.Forms.Button
    $buttonLocal.Text = "Von lokaler Datei"
    $buttonLocal.DialogResult = [System.Windows.Forms.DialogResult]::No
    $buttonLocal.Location = New-Object System.Drawing.Point(200, 60)
    $buttonLocal.Size = New-Object System.Drawing.Size(140, 30)
    $dialog.Controls.Add($buttonLocal)
    
    $dialog.AcceptButton = $buttonGitHub
    $dialog.CancelButton = $buttonLocal

    return $dialog.ShowDialog($form)
}


# --- Button für E-Mail-Skript (verkleinert) ---
$buttonInstallSendmailPy = New-Object System.Windows.Forms.Button
$buttonInstallSendmailPy.Text = "E-Mail-Skript installieren"
$buttonInstallSendmailPy.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2)
$buttonInstallSendmailPy.Size = New-Object System.Drawing.Size(200, 30)

# --- NEUER BUTTON FÜR SSH KONSOLE ---
$buttonOpenSshConsole = New-Object System.Windows.Forms.Button
$buttonOpenSshConsole.Text = "SSH-Konsole /Cron /Del"
$buttonOpenSshConsole.Location = New-Object System.Drawing.Point( ([int]$buttonInstallSendmailPy.Location.X + [int]$buttonInstallSendmailPy.Width + 10), $currentY_Col2)
$buttonOpenSshConsole.Size = New-Object System.Drawing.Size(160, 30)
$buttonOpenSshConsole.ForeColor = [System.Drawing.Color]::DarkRed
$buttonOpenSshConsole.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$currentY_Col2 += $buttonInstallSendmailPy.Height + 10

# ---------------------------------------------------------
# Block 2: Zeitplanung

# --- FINALE VERSION V2: Ultra-kompakte Zeitplanung ---
$groupSchedule = New-Object System.Windows.Forms.GroupBox; $groupSchedule.Text = "Zeitplanung: Monat= 1.W 1-7 / 2.W 8-14 / 3.W 15-21 / 4.W 22-28 "; $groupSchedule.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $groupSchedule.Size = New-Object System.Drawing.Size($column2Width, 170) # Höhe weiter reduziert
[int]$schedulesGcOffsetX = 10
[int]$schedulesGcOffsetY = 20

# Zeile 1: Uhrzeit UND Wiederholung
$labelScheduleTime = New-Object System.Windows.Forms.Label; $labelScheduleTime.Text = "Uhrzeit (HH:MM):"; $labelScheduleTime.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, ($schedulesGcOffsetY + 3)); $labelScheduleTime.AutoSize = $true
$textboxScheduleHour = New-Object System.Windows.Forms.TextBox; $textboxScheduleHour.Location = New-Object System.Drawing.Point(110, $schedulesGcOffsetY); $textboxScheduleHour.Size = New-Object System.Drawing.Size(30, 20); $textboxScheduleHour.MaxLength = 2; $textboxScheduleHour.Text = "02"
$labelScheduleSeparator = New-Object System.Windows.Forms.Label; $labelScheduleSeparator.Text = ":"; $labelScheduleSeparator.AutoSize = $false; $labelScheduleSeparator.Size = New-Object System.Drawing.Size(8, 23); $labelScheduleSeparator.TextAlign = 'MiddleCenter'; $labelScheduleSeparator.Location = New-Object System.Drawing.Point($textboxScheduleHour.Right, $schedulesGcOffsetY)
$textboxScheduleMinute = New-Object System.Windows.Forms.TextBox; $textboxScheduleMinute.Location = New-Object System.Drawing.Point($labelScheduleSeparator.Right, $schedulesGcOffsetY); $textboxScheduleMinute.Size = New-Object System.Drawing.Size(30, 20); $textboxScheduleMinute.MaxLength = 2; $textboxScheduleMinute.Text = "00"

# Zeile 3: Neue ComboBox für Wiederholung
$labelRepeatMode = New-Object System.Windows.Forms.Label; $labelRepeatMode.Text = "Wiederholung:"; $labelRepeatMode.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, ($schedulesGcOffsetY + 3)); $labelRepeatMode.AutoSize = $true
$comboRepeatMode = New-Object System.Windows.Forms.ComboBox; $comboRepeatMode.Location = New-Object System.Drawing.Point(190, $schedulesGcOffsetY); $comboRepeatMode.Size = New-Object System.Drawing.Size(165, 21); $comboRepeatMode.DropDownStyle = "DropDownList"
$comboRepeatMode.Items.AddRange(@(
    [pscustomobject]@{Name="Jede Woche (Normal)"; Value="NORMAL"},
    [pscustomobject]@{Name="Alle 2 Wochen (gerade KW)"; Value="BIWEEKLY_EVEN"},
    [pscustomobject]@{Name="Alle 2 Wochen (ungerade KW)"; Value="BIWEEKLY_ODD"},
    [pscustomobject]@{Name="1. Woche im Monat"; Value="MONTHLY_1"},
    [pscustomobject]@{Name="2. Woche im Monat"; Value="MONTHLY_2"},
    [pscustomobject]@{Name="3. Woche im Monat"; Value="MONTHLY_3"},
    [pscustomobject]@{Name="4. Woche im Monat"; Value="MONTHLY_4"},
	[pscustomobject]@{Name="Letzte Woche im Monat (ab 22.)"; Value="MONTHLY_LAST"}
))

$comboRepeatMode.DisplayMember = "Name"
$comboRepeatMode.ValueMember = "Value"
$comboRepeatMode.SelectedIndex = 0
$schedulesGcOffsetY += 30

# Zeile 2: Tage
$labelScheduleDays = New-Object System.Windows.Forms.Label; $labelScheduleDays.Text = "Tage:"; $labelScheduleDays.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, ($schedulesGcOffsetY + 3)); $labelScheduleDays.AutoSize = $true
$checkboxDays = @{}; $days = @{ "So" = 0; "Mo" = 1; "Di" = 2; "Mi" = 3; "Do" = 4; "Fr" = 5; "Sa" = 6 }; $dayCheckboxX = $schedulesGcOffsetX + 45
foreach ($day in $days.GetEnumerator() | Sort-Object Value) { $dName = $day.Name; $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $dName; $cb.Tag = $day.Value; $cb.Location = New-Object System.Drawing.Point($dayCheckboxX, $schedulesGcOffsetY); $cb.AutoSize = $true; $checkboxDays[$dName] = $cb; $dayCheckboxX += 43 }
$schedulesGcOffsetY += 30

# Zeile 3: Job-Typ
$radioScheduleBackup = New-Object System.Windows.Forms.RadioButton; $radioScheduleBackup.Text = "GhettoVCB Backup"; $radioScheduleBackup.Location = New-Object System.Drawing.Point(($schedulesGcOffsetX + 10), $schedulesGcOffsetY); $radioScheduleBackup.AutoSize = $true; $radioScheduleBackup.Checked = $true
$radioScheduleReplication = New-Object System.Windows.Forms.RadioButton; $radioScheduleReplication.Text = "Direkte Repl. (H2H)"; $radioScheduleReplication.Location = New-Object System.Drawing.Point(($radioScheduleBackup.Right + 17), $schedulesGcOffsetY); $radioScheduleReplication.AutoSize = $true
$radioScheduleRestoreClone = New-Object System.Windows.Forms.RadioButton; $radioScheduleRestoreClone.Text = "Restore/Klon"; $radioScheduleRestoreClone.Location = New-Object System.Drawing.Point(($radioScheduleReplication.Right + 20), $schedulesGcOffsetY); $radioScheduleRestoreClone.AutoSize = $true
$schedulesGcOffsetY += 30

# Letzte Zeile: Status und Buttons
$labelUtcInfo = New-Object System.Windows.Forms.Label; $labelUtcInfo.Text = "(ESXi verwendet UTC-zeit!)"; $labelUtcInfo.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, ($schedulesGcOffsetY + 4)); $labelUtcInfo.AutoSize = $true; $labelUtcInfo.ForeColor = [System.Drawing.Color]::DimGray
$labelEsxiTime = New-Object System.Windows.Forms.Label; $labelEsxiTime.Text = "ESXi nicht verbunden"; $labelEsxiTime.Location = New-Object System.Drawing.Point(($schedulesGcOffsetX + 155), ($schedulesGcOffsetY + 4)); $labelEsxiTime.AutoSize = $true; $labelEsxiTime.ForeColor = [System.Drawing.Color]::Blue
$schedulesGcOffsetY += 25
$buttonGetEsxiTime = New-Object System.Windows.Forms.Button; $buttonGetEsxiTime.Text = "ESXi-Zeit"; $buttonGetEsxiTime.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, $schedulesGcOffsetY); $buttonGetEsxiTime.Size = New-Object System.Drawing.Size(110, 23)
$buttonSaveSchedule = New-Object System.Windows.Forms.Button; $buttonSaveSchedule.Text = "Zeitplan speichern"; $buttonSaveSchedule.Location = New-Object System.Drawing.Point(($buttonGetEsxiTime.Right + 10), $schedulesGcOffsetY); $buttonSaveSchedule.Size = New-Object System.Drawing.Size(150, 23)

# Alle Controls zur Gruppe hinzufügen
$allScheduleControls = New-Object System.Collections.ArrayList
[void]$allScheduleControls.AddRange(@($labelScheduleTime, $textboxScheduleHour, $labelScheduleSeparator, $textboxScheduleMinute, $comboRepeatMode, $labelScheduleDays, $radioScheduleBackup, $radioScheduleReplication, $radioScheduleRestoreClone, $labelUtcInfo, $buttonSaveSchedule, $buttonGetEsxiTime, $labelEsxiTime))
[void]$allScheduleControls.AddRange($checkboxDays.Values)
$groupSchedule.Controls.AddRange($allScheduleControls)
$currentY_Col2 = $groupSchedule.Location.Y + $groupSchedule.Height + 10
# --- ENDE: FINALE VERSION Zeitplanung ---

# --- ENDE: Kompakter und robuster Zeitplanungs-Block ---


# Block 3: E-Mail Benachrichtigung
$groupEmail = New-Object System.Windows.Forms.GroupBox; $groupEmail.Text = "E-Mail Benachrichtigung"; $groupEmail.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $groupEmail.Size = New-Object System.Drawing.Size($column2Width, 265)
[int]$emailGcOffsetX = 10; [int]$emailGcOffsetY = 15; [int]$emailGcLabelWidth = 115

# --- Checkbox & Buttons ---
$checkboxEmailLog = New-Object System.Windows.Forms.CheckBox; $checkboxEmailLog.Text = "E-Mail-Benachrichtigung aktivieren"; $checkboxEmailLog.Location = New-Object System.Drawing.Point($emailGcOffsetX, $emailGcOffsetY); $checkboxEmailLog.AutoSize = $true
$emailGcOffsetY += 25
$buttonFirewallCheck = New-Object System.Windows.Forms.Button; $buttonFirewallCheck.Text = "Firewall-Check"; $buttonFirewallCheck.Location = New-Object System.Drawing.Point($emailGcOffsetX, $emailGcOffsetY); $buttonFirewallCheck.Size = New-Object System.Drawing.Size(110, 25)
$buttonTestEmail = New-Object System.Windows.Forms.Button; $buttonTestEmail.Text = "Email-Test"; $buttonTestEmail.Location = New-Object System.Drawing.Point(($buttonFirewallCheck.Right + 5), $emailGcOffsetY); $buttonTestEmail.Size = New-Object System.Drawing.Size(110, 25)
$buttonGetDebugLog = New-Object System.Windows.Forms.Button; $buttonGetDebugLog.Text = "Email-Log"; $buttonGetDebugLog.Location = New-Object System.Drawing.Point(($buttonTestEmail.Right + 5), $emailGcOffsetY); $buttonGetDebugLog.Size = New-Object System.Drawing.Size(110, 25)
$emailGcOffsetY += $buttonFirewallCheck.Height + 5

# --- Empfänger ---
$labelEmailTo = New-Object System.Windows.Forms.Label; $labelEmailTo.Text = "Empfänger:"; $labelEmailTo.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailTo.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailTo = New-Object System.Windows.Forms.TextBox; $textboxEmailTo.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailTo.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20)
$emailGcOffsetY += 25

# --- Absender ---
$labelEmailFrom = New-Object System.Windows.Forms.Label; $labelEmailFrom.Text = "Absender:"; $labelEmailFrom.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailFrom.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailFrom = New-Object System.Windows.Forms.TextBox; $textboxEmailFrom.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailFrom.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20)
$emailGcOffsetY += 25

# --- Anzeigename ---
$labelEmailDisplay = New-Object System.Windows.Forms.Label; $labelEmailDisplay.Text = "Anzeigename:"; $labelEmailDisplay.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailDisplay.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailDisplay = New-Object System.Windows.Forms.TextBox; $textboxEmailDisplay.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailDisplay.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20); 
if ([string]::IsNullOrEmpty($textboxEmailDisplay.Text)) { $textboxEmailDisplay.Text = "ESXi Backup" }
$emailGcOffsetY += 25

# --- SMTP Server & Port (KOMBINIERT) ---
$labelEmailServer = New-Object System.Windows.Forms.Label; $labelEmailServer.Text = "SMTP-Server:"; $labelEmailServer.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailServer.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)

# Server Box (Breite 110)
$textboxEmailServer = New-Object System.Windows.Forms.TextBox; $textboxEmailServer.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailServer.Size = New-Object System.Drawing.Size(135, 20)

# Port Label (Feste Breite setzen, damit .Right stimmt!)
$labelEmailPort = New-Object System.Windows.Forms.Label; $labelEmailPort.Text = "Port:"; $labelEmailPort.Location = New-Object System.Drawing.Point(($textboxEmailServer.Right + 10), ($emailGcOffsetY + 3))
$labelEmailPort.AutoSize = $false
$labelEmailPort.Size = New-Object System.Drawing.Size(32, 20) # Feste kleine Breite für "Port:"

# Port Box (Direkt daneben)
$textboxEmailPort = New-Object System.Windows.Forms.TextBox; $textboxEmailPort.Location = New-Object System.Drawing.Point(($labelEmailPort.Right), $emailGcOffsetY); $textboxEmailPort.Size = New-Object System.Drawing.Size(50, 20); $textboxEmailPort.Text = "25"
$emailGcOffsetY += 25

# --- Benutzername ---
$labelEmailUser = New-Object System.Windows.Forms.Label; $labelEmailUser.Text = "Benutzername:"; $labelEmailUser.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailUser.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailUser = New-Object System.Windows.Forms.TextBox; $textboxEmailUser.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailUser.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20)
$emailGcOffsetY += 25

# --- Passwort ---
$labelEmailPassword = New-Object System.Windows.Forms.Label; $labelEmailPassword.Text = "Passwort:"; $labelEmailPassword.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailPassword.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailPassword = New-Object System.Windows.Forms.TextBox; $textboxEmailPassword.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailPassword.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20); $textboxEmailPassword.UseSystemPasswordChar = $true
$emailGcOffsetY += 25

# --- Betreff ---
$labelEmailSubject = New-Object System.Windows.Forms.Label; $labelEmailSubject.Text = "Betreff:"; $labelEmailSubject.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailSubject.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailSubject = New-Object System.Windows.Forms.TextBox; $textboxEmailSubject.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailSubject.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20); $textboxEmailSubject.Text = "Backup-Report für %h"
$emailGcOffsetY += $textboxEmailSubject.Height + 2

# --- Info Text ---
$labelSubjectInfo = New-Object System.Windows.Forms.Label; $labelSubjectInfo.Text = "(%h=Hostname)"; $labelSubjectInfo.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $labelSubjectInfo.AutoSize = $true; $labelSubjectInfo.ForeColor = [System.Drawing.Color]::DimGray

# --- Add Controls ---
$groupEmail.Controls.AddRange(@($checkboxEmailLog, $buttonFirewallCheck, $buttonTestEmail, $buttonGetDebugLog, $labelEmailTo, $textboxEmailTo, $labelEmailFrom, $textboxEmailFrom, $labelEmailDisplay, $textboxEmailDisplay, $labelEmailServer, $textboxEmailServer, $labelEmailPort, $textboxEmailPort, $labelEmailUser, $textboxEmailUser, $labelEmailPassword, $textboxEmailPassword, $labelEmailSubject, $textboxEmailSubject, $labelSubjectInfo))
$currentY_Col2 = $groupEmail.Location.Y + $groupEmail.Height + 10

# Block 4: Backup-Aktionen
$buttonStartBackup = New-Object System.Windows.Forms.Button; $buttonStartBackup.Text = "GhettoVCB Backup starten"; $buttonStartBackup.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $buttonStartBackup.Size = New-Object System.Drawing.Size(180, 25)
$buttonCheckBackupStatus = New-Object System.Windows.Forms.Button; $buttonCheckBackupStatus.Text = "Backup-Log abrufen"; $buttonCheckBackupStatus.Location = New-Object System.Drawing.Point( ([int]$buttonStartBackup.Location.X + [int]$buttonStartBackup.Width + 10), $currentY_Col2); $buttonCheckBackupStatus.Size = New-Object System.Drawing.Size(180, 25);
$currentY_Col2 += $buttonStartBackup.Height + 5
$buttonCancelBackup = New-Object System.Windows.Forms.Button; $buttonCancelBackup.Text = "GhettoVCB Backup abbrechen"; $buttonCancelBackup.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $buttonCancelBackup.Size = New-Object System.Drawing.Size(180, 25); $buttonCancelBackup.Enabled = $true
$buttonBrowseBackupDir = New-Object System.Windows.Forms.Button; $buttonBrowseBackupDir.Text = "GhettoVCB Backup-Inhalt"; $buttonBrowseBackupDir.Location = New-Object System.Drawing.Point(([int]$buttonCancelBackup.Location.X + [int]$buttonCancelBackup.Width + 10), $currentY_col2); $buttonBrowseBackupDir.Size = New-Object System.Drawing.Size(180, 25)
$currentY_Col2 += $buttonCancelBackup.Height + 10

# --- Log/Output Box ---
[int]$logBoxY = [System.Math]::Max($currentY_Col1, $currentY_Col2) + 5

# =====================================================================================
# --- START DER KORREKTUR V2 ---
# Die Höhe wird jetzt relativ zur TabPage ($esxiTab) berechnet, nicht mehr zum Formular ($form).
# =====================================================================================
$dynamicHeight = $esxiTab.ClientSize.Height - $logBoxY - 20

$outputBox = New-Object System.Windows.Forms.TextBox
$Global:outputBoxGUIRef = $outputBox
$outputBox.Location = New-Object System.Drawing.Point($column1X, $logBoxY)
# Hier wird die neue, korrekte Höhe zugewiesen
$outputBox.Size = New-Object System.Drawing.Size(450, $dynamicHeight) 
# Der Anchor sorgt dafür, dass sich die Box mit dem Fenster vergrössert/verkleinert
$outputBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$outputBox.Multiline = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.ReadOnly = $true
$outputBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# In GhettoGUI_V8.0.1.ps1

# --- NEU: Netzwerk-Traffic Monitor (FINALE VERSION mit echtem Scroll-Pin V43.9.9) ---
$groupTraffic = New-Object System.Windows.Forms.GroupBox
$groupTraffic.Text = "Netzwerk-Traffic"
$groupTraffic.Location = New-Object System.Drawing.Point(($outputBox.Right + 10), $logBoxY)
$groupTraffic.Size = New-Object System.Drawing.Size(($esxiTab.ClientSize.Width - $outputBox.Right - 35), $dynamicHeight)
$groupTraffic.Anchor = 'Top, Bottom, Left, Right'

# Ein robustes TableLayoutPanel für eine saubere Anordnung
$trafficTable = New-Object System.Windows.Forms.TableLayoutPanel
$trafficTable.Dock = [System.Windows.Forms.DockStyle]::Fill
$trafficTable.ColumnCount = 2
$trafficTable.RowCount = 4 # Von 3 auf 4 erhöht

[void]$trafficTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$trafficTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$trafficTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$trafficTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$trafficTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$trafficTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) # NEUE ZEILE für Checkbox

# Steuerelemente erstellen (unverändert)
$labelSelectNic = New-Object System.Windows.Forms.Label; $labelSelectNic.Text = "Netzwerkkarte:"; $labelSelectNic.Anchor = 'Left'; $labelSelectNic.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$comboVmnic = New-Object System.Windows.Forms.ComboBox; $comboVmnic.DropDownStyle = "DropDownList"; $comboVmnic.Dock = 'Fill'
$comboVmnic.DisplayMember = ""
$textTrafficStats = New-Object System.Windows.Forms.TextBox; $textTrafficStats.Multiline = $true; $textTrafficStats.ReadOnly = $true; $textTrafficStats.ScrollBars = "Vertical"; $textTrafficStats.Font = New-Object System.Drawing.Font("Consolas", 10); $textTrafficStats.Dock = 'Fill'

# Panel für MB/s-Anzeigen (unverändert)
$speedPanel = New-Object System.Windows.Forms.FlowLayoutPanel; $speedPanel.Dock = 'Fill'; $speedPanel.AutoSize = $true
$labelTrafficDown = New-Object System.Windows.Forms.Label; $labelTrafficDown.Text = "Down: --- MB/s"; $labelTrafficDown.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold); $labelTrafficDown.ForeColor = [System.Drawing.Color]::DarkGreen; $labelTrafficDown.AutoSize = $true; $labelTrafficDown.Margin = New-Object System.Windows.Forms.Padding(0, 5, 10, 0)
$labelTrafficUp = New-Object System.Windows.Forms.Label; $labelTrafficUp.Text = "Up:   --- MB/s"; $labelTrafficUp.Font = $labelTrafficDown.Font; $labelTrafficUp.ForeColor = [System.Drawing.Color]::Red; $labelTrafficUp.AutoSize = $true; $labelTrafficUp.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
$speedPanel.Controls.AddRange(@($labelTrafficDown, $labelTrafficUp))

# --- KORRIGIERTE Checkbox zum Fixieren der Scroll-Position ---
$checkboxPinScroll = New-Object System.Windows.Forms.CheckBox
$checkboxPinScroll.Text = "Scroll-Position fixieren (stoppt Detail-Statistik)" # <<< Neuer Text
$checkboxPinScroll.AutoSize = $true
$checkboxPinScroll.Anchor = 'Left'
$checkboxPinScroll.Margin = New-Object System.Windows.Forms.Padding(3, 5, 0, 0)
$toolTip.SetToolTip($checkboxPinScroll, "Verhindert das automatische Scrollen, indem die 'NIC statistics' nicht aktualisiert werden. MB/s-Anzeige läuft weiter.") # <<< Neuer Tooltip


# Steuerelemente der Tabelle zuweisen
$trafficTable.Controls.Add($labelSelectNic, 0, 0); $trafficTable.Controls.Add($comboVmnic, 1, 0)
$trafficTable.SetColumnSpan($textTrafficStats, 2); $trafficTable.Controls.Add($textTrafficStats, 0, 1)
$trafficTable.SetColumnSpan($speedPanel, 2); $trafficTable.Controls.Add($speedPanel, 0, 2)
$trafficTable.SetColumnSpan($checkboxPinScroll, 2); $trafficTable.Controls.Add($checkboxPinScroll, 0, 3)
$groupTraffic.Controls.Add($trafficTable)
# --- Ende Netzwerk-Traffic Monitor ---


# --- Timer für Log-Abruf ---
$Global:logPollTimer = New-Object System.Windows.Forms.Timer; $Global:logPollTimer.Interval = 10000; $onLogPollTimerTick = { Write-GuiLog "Prüfe Backup-Log (autom.)..."; Get-BackupJobLog }; $Global:logPollTimer.Add_Tick($onLogPollTimerTick)

# --- Timer für Replikations-Job-Überwachung ---
$Global:replicationJobTimer = New-Object System.Windows.Forms.Timer
$Global:replicationJobTimer.Interval = 2000 # Alle 2 Sekunden prüfen

# =====================================================================================
# --- STARTBLOCK: Finaler Netzwerk-Monitor (Kalibriert) ---
# =====================================================================================

$Global:trafficPollTimer = New-Object System.Windows.Forms.Timer
$Global:trafficPollTimer.Interval = 5000 

# In GhettoGUI_V8.0.1.ps1
# ERSETZE den gesamten $onTrafficPollTimerTick-Block (V43.9.9)

$onTrafficPollTimerTick = {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected -and $comboVmnic.SelectedItem)) { return }

    try {
        $selectedNic = $comboVmnic.SelectedItem
        $statsResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network nic stats get -n $selectedNic"
        
        $currentStats = @{}
        $statsResult.Output | ForEach-Object {
            if ($_ -match "Bytes received:\s+(\d+)") { $currentStats.Add('BytesReceived', [long]$Matches[1]) }
            if ($_ -match "Bytes sent:\s+(\d+)") { $currentStats.Add('BytesSent', [long]$Matches[1]) }
        }
        $currentStats.Add('Timestamp', (Get-Date))

        if ($null -ne $Global:lastTrafficStats) {
            # Berechnung (Tippfehler in 'lastTrafficStats' korrigiert)
            $timeDiffSeconds = [Math]::Max(1, ($currentStats.Timestamp - $Global:lastTrafficStats.Timestamp).TotalSeconds)
            $bytesReceivedDiff = $currentStats.BytesReceived - $Global:lastTrafficStats.BytesReceived
            $bytesSentDiff = $currentStats.BytesSent - $Global:lastTrafficStats.BytesSent
            if ($bytesReceivedDiff -lt 0) { $bytesReceivedDiff = 0 }
            if ($bytesSentDiff -lt 0) { $bytesSentDiff = 0 }
            $divisor = 1000 * 1250 
            $downValue = ($bytesReceivedDiff / $timeDiffSeconds) / $divisor
            $upValue = ($bytesSentDiff / $timeDiffSeconds) / $divisor
            
            # --- KORREKTUR: Selektives Update basierend auf der Checkbox ---
            
            # 1. Aktualisiere die MB/s-Labels IMMER
            if ($labelTrafficDown.IsHandleCreated) {
                $labelTrafficDown.Invoke([Action]{
                    $labelTrafficDown.Text = "Down: {0:N2} MB/s" -f $downValue
                })
            }
            if ($labelTrafficUp.IsHandleCreated) {
                 $labelTrafficUp.Invoke([Action]{
                    $labelTrafficUp.Text = "Up:   {0:N2} MB/s" -f $upValue
                })
            }

            # 2. Aktualisiere die große Statistik-Textbox NUR, wenn NICHT gepinnt ist
            if (-not $checkboxPinScroll.Checked -and $textTrafficStats.IsHandleCreated) {
                $textTrafficStats.Invoke([Action]{
                    if ($statsResult.ExitStatus -eq 0 -and $statsResult.Output) {
                        $textTrafficStats.Text = ($statsResult.Output -join [Environment]::NewLine)
                    } else {
                        $textTrafficStats.Text = "Fehler beim Abrufen der Statistik.`n$($statsResult.Error -join [Environment]::NewLine)"
                    }
                })
            }
            # --- ENDE KORREKTUR ---
        }
        
        $Global:lastTrafficStats = $currentStats
    } catch {
        # Fehlerbehandlung
        if ($textTrafficStats.IsHandleCreated) {
             $textTrafficStats.Invoke([Action]{
                $textTrafficStats.Text = "FATALER FEHLER im Timer: $($_.Exception.Message)"
             })
        }
    }
}

# ----------- trafficPollTimer.Add_Tick-----------------

$Global:trafficPollTimer.Add_Tick($onTrafficPollTimerTick)

# =====================================================================================
# --- ENDBLOCK ---
# =====================================================================================

# -- ######### # --- Definition des Replikations-Fensters --- Start #####

$replicationForm = New-Object System.Windows.Forms.Form
$replicationForm.Text = "VM Replikation"
$replicationForm.Size = New-Object System.Drawing.Size(420, 250)
$replicationForm.StartPosition = "CenterParent"
$replicationForm.FormBorderStyle = 'FixedDialog'
$replicationForm.MaximizeBox = $false
$replicationForm.MinimizeBox = $false

$repCurrentY = 20
# Ziel Host
$labelRepTargetHost = New-Object System.Windows.Forms.Label; $labelRepTargetHost.Text = "Ziel-Host IP:"; $labelRepTargetHost.Location = New-Object System.Drawing.Point(20, ($repCurrentY + 3)); $labelRepTargetHost.AutoSize = $true
$textboxRepTargetHost = New-Object System.Windows.Forms.TextBox; $textboxRepTargetHost.Location = New-Object System.Drawing.Point(180, $repCurrentY); $textboxRepTargetHost.Size = New-Object System.Drawing.Size(200, 20)
$replicationForm.Controls.Add($labelRepTargetHost); $replicationForm.Controls.Add($textboxRepTargetHost)
$repCurrentY += 30

# Ziel User
$labelRepTargetUser = New-Object System.Windows.Forms.Label; $labelRepTargetUser.Text = "Ziel-Host Username:"; $labelRepTargetUser.Location = New-Object System.Drawing.Point(20, ($repCurrentY + 3)); $labelRepTargetUser.AutoSize = $true
$textboxRepTargetUser = New-Object System.Windows.Forms.TextBox; $textboxRepTargetUser.Location = New-Object System.Drawing.Point(180, $repCurrentY); $textboxRepTargetUser.Size = New-Object System.Drawing.Size(200, 20); $textboxRepTargetUser.Text = "root"
$replicationForm.Controls.Add($labelRepTargetUser); $replicationForm.Controls.Add($textboxRepTargetUser)
$repCurrentY += 30

# Zwischenspeicher (Shared Datastore)
$labelRepSharedDs = New-Object System.Windows.Forms.Label; $labelRepSharedDs.Text = "Zwischenspeicher (NAS):"; $labelRepSharedDs.Location = New-Object System.Drawing.Point(20, ($repCurrentY + 3)); $labelRepSharedDs.AutoSize = $true
$textboxRepSharedDs = New-Object System.Windows.Forms.TextBox; $textboxRepSharedDs.Location = New-Object System.Drawing.Point(180, $repCurrentY); $textboxRepSharedDs.Size = New-Object System.Drawing.Size(165, 20)
$buttonBrowseRepSharedDs = New-Object System.Windows.Forms.Button; $buttonBrowseRepSharedDs.Text = "..."; $buttonBrowseRepSharedDs.Location = New-Object System.Drawing.Point(350, ($repCurrentY - 1)); $buttonBrowseRepSharedDs.Size = New-Object System.Drawing.Size(30, 23)
$replicationForm.Controls.AddRange(@($labelRepSharedDs, $textboxRepSharedDs, $buttonBrowseRepSharedDs))
$repCurrentY += 30

# Zielspeicher (auf Ziel-Host)
$labelRepTargetDs = New-Object System.Windows.Forms.Label; $labelRepTargetDs.Text = "Zielspeicher (auf Ziel-Host):"; $labelRepTargetDs.Location = New-Object System.Drawing.Point(20, ($repCurrentY + 3)); $labelRepTargetDs.AutoSize = $true
$textboxRepTargetDs = New-Object System.Windows.Forms.TextBox; $textboxRepTargetDs.Location = New-Object System.Drawing.Point(180, $repCurrentY); $textboxRepTargetDs.Size = New-Object System.Drawing.Size(165, 20)
$buttonBrowseRepTargetDs = New-Object System.Windows.Forms.Button; $buttonBrowseRepTargetDs.Text = "..."; $buttonBrowseRepTargetDs.Location = New-Object System.Drawing.Point(350, ($repCurrentY - 1)); $buttonBrowseRepTargetDs.Size = New-Object System.Drawing.Size(30, 23)
$replicationForm.Controls.AddRange(@($labelRepTargetDs, $textboxRepTargetDs, $buttonBrowseRepTargetDs))
$repCurrentY += 30

# Suffix
$labelRepSuffix = New-Object System.Windows.Forms.Label; $labelRepSuffix.Text = "Suffix für VM-Name:"; $labelRepSuffix.Location = New-Object System.Drawing.Point(20, ($repCurrentY + 3)); $labelRepSuffix.AutoSize = $true
$textboxRepSuffix = New-Object System.Windows.Forms.TextBox; $textboxRepSuffix.Location = New-Object System.Drawing.Point(180, $repCurrentY); $textboxRepSuffix.Size = New-Object System.Drawing.Size(200, 20); $textboxRepSuffix.Text = "-Replica"
$replicationForm.Controls.Add($labelRepSuffix); $replicationForm.Controls.Add($textboxRepSuffix)
$repCurrentY += 40

# Buttons im Replikations-Fenster
$buttonStartReplication = New-Object System.Windows.Forms.Button; $buttonStartReplication.Text = "Replikation starten"; $buttonStartReplication.Location = New-Object System.Drawing.Point(180, $repCurrentY); $buttonStartReplication.Size = New-Object System.Drawing.Size(120, 25);
# Wir setzen DialogResult NICHT, da wir das Fenster nicht sofort schliessen wollen.

### Replikations Start Butten

$buttonStartReplication.Add_Click({

    Get-Job | Remove-Job

    # 1. Bestätigung einholen
    $confirmResult = [System.Windows.Forms.MessageBox]::Show("Sind Sie sicher, dass Sie die Replikation starten möchten?`nDieser Prozess kann je nach VM-Größe einige Zeit dauern und läuft im Hintergrund weiter.", "Replikation bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    # 2. Alle benötigten Daten aus der GUI sammeln

# NEUE, KORREKTE VERSION:
$jobParams = @{
    SourceVmName            = $checkedListBoxVms.CheckedItems[0].OriginalName
    GhettoVCBPath           = $textboxGhettoPath.Text
    SharedDatastore         = $textboxRepSharedDs.Text
    TargetDatastore         = $textboxRepTargetDs.Text
    VmSuffix                = $textboxRepSuffix.Text
    # Wir übergeben die Rohdaten für die Verbindungen:
    SourceHost              = $textboxIp.Text
    SourceCredential        = $Global:ESXiSshCredential
    TargetHost              = $textboxRepTargetHost.Text
    TargetCredential        = $Global:TargetESXiSshCredential
}

# 3. Das Skript, das der Job ausführen soll (VERSION 3, Finale Korrektur)
    $scriptBlock = {
        param($p)

        $sourceSession = $null
        $targetSession = $null

        try {
            # Schritt A: Eigene SSH-Sessions für den Job aufbauen
            Write-Output "INFO: Baue SSH-Verbindungen im Hintergrund-Job auf..."
            $sourceSession = New-SSHSession -ComputerName $p.SourceHost -Credential $p.SourceCredential -AcceptKey -ConnectionTimeout 60
            $targetSession = New-SSHSession -ComputerName $p.TargetHost -Credential $p.TargetCredential -AcceptKey -ConnectionTimeout 60
            if (-not $sourceSession.Connected -or -not $targetSession.Connected) {
                throw "Konnte keine SSH-Verbindung im Hintergrund-Job herstellen."
            }
            Write-Output "INFO: SSH-Verbindungen im Job sind aktiv."

### Start Replikations Funktion

# --- START DER FINALEN "GOLDEN MASTER" FUNKTION ---
        function Start-VMReplicationInJob {
            param($params, $srcSession, $tgtSession)

            # --- Variablen-Definition ---
            $sourceVmName = $params.SourceVmName; $targetHost = $params.TargetHost; $sharedDatastore = $params.SharedDatastore
            $targetDatastore = $params.TargetDatastore; $vmSuffix = $params.VmSuffix; $ghettoVCBPath = $params.GhettoVCBPath
            $replicatedVmName = "$($sourceVmName)$($vmSuffix)"; $tempReplicationPath = "$sharedDatastore/replication-temp"
            $tempVmBackupPath = "$tempReplicationPath/$sourceVmName"; $finalVmBackupPath = "$tempVmBackupPath/$sourceVmName-active-replication"
            $targetVmPath = "$targetDatastore/$replicatedVmName"; $tempReplicationConfPath = "/tmp/ghettoVCB-replication.conf"
            $tempVmListPath = "/tmp/replication-vm-list.txt"; $tempBackupLogPath = "/tmp/replication-backup.log"

            # --- [0/8] "Schlosser": Aufräumen und Sperren brechen ---
            Write-Output "[0/8] Breche eventuelle Dateisperren und säubere Reste..."
            Write-Output "  -> Prüfe und breche Sperren auf Zwischenspeicher: '$tempReplicationPath'"
            $template = 'LSOF_PID=$(/usr/lib/vmware/bin/vmkvsitools lsof | grep ''{0}'' | awk ''{{print $1}}'' | sort -u | head -n 1); if [ -n "$LSOF_PID" ]; then echo "Lock found: PID $LSOF_PID. Killing."; kill -9 $LSOF_PID; sleep 2; else echo "No lock found."; fi; echo "Final Deletion of {0}."; rm -rf ''{0}'';'
            $forceCleanupCmd = $template -f $tempReplicationPath
            $cleanup1_result = Invoke-SSHCommand -SSHSession $srcSession -Command $forceCleanupCmd
            $cleanup1_result.Output | ForEach-Object { Write-Output "    CLEANUP_SRC: $_" }
            if ($cleanup1_result.ExitStatus -ne 0) { $cleanup1_result.Error | ForEach-Object { Write-Output "    ERR: $_" } }
            Write-Output "  -> Lösche altes Zielverzeichnis auf Ziel-Host: '$targetVmPath'"
            Invoke-SSHCommand -SSHSession $tgtSession -Command "rm -rf '$targetVmPath'" | Out-Null
            Write-Output "  -> Warte 2 Sekunden..."
            Start-Sleep -Seconds 2

            # --- Start des eigentlichen Prozesses ---
            try {
                # --- [1/8] Temporäre Konfiguration erstellen ---
                Write-Output "[1/8] Erstelle temporäre Replikations-Konfiguration..."
                $replicationConfLines = @("VM_BACKUP_VOLUME=`"$tempReplicationPath`"","VM_BACKUP_ROTATION_COUNT=1","DISK_BACKUP_FORMAT=`"thin`"","VM_BACKUP_DIR_NAMING_CONVENTION=`"active-replication`"")
                $replicationConfContent = ($replicationConfLines -join "`n") + "`n"
                $sftpSessionSrc = New-SFTPSession -ComputerName $params.SourceHost -Credential $params.SourceCredential
                Set-SFTPContent -SFTPSession $sftpSessionSrc -Path $tempReplicationConfPath -Value $replicationConfContent -Encoding UTF8 | Out-Null
                Set-SFTPContent -SFTPSession $sftpSessionSrc -Path $tempVmListPath -Value "$sourceVmName`n" -Encoding UTF8 | Out-Null
                Remove-SFTPSession -SFTPSession $sftpSessionSrc

                # --- [2/8] Backup-Prozess starten ---
                Write-Output "[2/8] Starte Backup von '$sourceVmName' im Hintergrund..."
                $backupCommand = "'$ghettoVCBPath/ghettoVCB.sh' -f $tempVmListPath -g $tempReplicationConfPath -l $tempBackupLogPath"
                $nohupCommand = "nohup $backupCommand > /dev/null 2>&1 &"
                Invoke-SSHCommand -SSHSession $srcSession -Command $nohupCommand | Out-Null

                # --- [3/8] Backup überwachen ---
                Write-Output "[3/8] Überwache Backup-Fortschritt. Jeder Punkt entspricht 15s:"
                $statusFilePath = "'$finalVmBackupPath/STATUS.ok'"
                $backupCompleted = $false; $maxWaitMinutes = 72*60; # Timeout auf 72 Stunden erhöht
                $waitedMinutes = 0
                while (-not $backupCompleted -and $waitedMinutes -lt $maxWaitMinutes) {
                    $checkFileCmd = "if [ -f $statusFilePath ]; then echo 'EXISTS'; else echo 'NOT_EXISTS'; fi"
                    $checkResult = Invoke-SSHCommand -SSHSession $srcSession -Command $checkFileCmd
                    if (($checkResult.Output -join '') -eq 'EXISTS') {
                        $backupCompleted = $true
                        Write-Output ""
                        Write-Output "   -> STATUS.ok gefunden! Backup ist erfolgreich abgeschlossen."
                    } else {
						Write-Output "   [3/8] warte (Backup läuft)..."
                        Start-Sleep -Seconds 15
                        $waitedMinutes += 0.25
                    }
                }
                if (-not $backupCompleted) { throw "Backup-Prozess hat das Zeitlimit von 48 Stunden überschritten." }
                Write-Output "Temporäres Backup erfolgreich erstellt."

                # --- [4/8] Kopiervorgang starten und überwachen ---
                Write-Output "[4/8] Kopiere VM-Daten zum Ziel-Datastore '$targetDatastore'..."
                $copyDoneFlag = "/tmp/copy_done.flag"
                $chainedCopyCommand = "cp -r '$finalVmBackupPath/.' '$targetVmPath/' && touch $copyDoneFlag"
                $nohupCopyCommand = "rm -f $copyDoneFlag; nohup sh -c ""$chainedCopyCommand"" > /tmp/replication_copy.log 2>&1 & echo $!"
                $copyPid = (Invoke-SSHCommand -SSHSession $tgtSession -Command $nohupCopyCommand).Output -join ''
                Write-Output "Kopier-Prozess gestartet. Überwache Ordnergröße (dies kann dauern):"
                $copyCompleted = $false; $waitedMinutesCopy = 0
                while (-not $copyCompleted -and $waitedMinutesCopy -lt $maxWaitMinutes) {
                    $checkFlagCmd = "if [ -f $copyDoneFlag ]; then echo 'EXISTS'; else echo 'NOT_EXISTS'; fi"
                    $checkResult = Invoke-SSHCommand -SSHSession $tgtSession -Command $checkFlagCmd
                    if (($checkResult.Output -join '') -eq 'EXISTS') {
                        $copyCompleted = $true
                        Invoke-SSHCommand -SSHSession $tgtSession -Command "rm -f $copyDoneFlag" | Out-Null
                        $finalSizeCmd = "du -sh '$targetVmPath' | awk '{print $1}'"
                        $finalSizeResult = Invoke-SSHCommand -SSHSession $tgtSession -Command $finalSizeCmd
                        Write-Output "`r   Kopieren abgeschlossen. Finale Größe: $($finalSizeResult.Output -join '')"
                    } else {
                        $sizeCheckCmd = "du -sh '$targetVmPath' | awk '{print $1}'"
                        $sizeResult = Invoke-SSHCommand -SSHSession $tgtSession -Command $sizeCheckCmd
                        $currentSize = if ($sizeResult.Output) { $sizeResult.Output -join '' } else { "0B" }
                        Write-Output -NoNewline "`r   Aktuelle Größe auf Ziel: $currentSize"
                        Start-Sleep -Seconds 15
                        $waitedMinutesCopy += 0.25
                    }
                }
                if (-not $copyCompleted) { throw "Kopier-Prozess hat das Zeitlimit überschritten." }

 # --- [5/8] Helfer-Skript erstellen (FINALE, KORREKTE VERSION) ---
                Write-Output "[5/8] Erstelle Helfer-Skript auf Ziel-Host..."

# Dies ist die finale "Detektiv"-Version des Helfer-Skripts
                $helperScriptTemplate = @'
#!/bin/sh
set -e

# Der Zielpfad und der gewünschte neue Name werden von PowerShell übergeben
TARGET_VM_PATH="{0}"
REPLICATED_VM_NAME="{1}"

echo "INFO: Wechsle in Ziel-Verzeichnis: $TARGET_VM_PATH"
cd "$TARGET_VM_PATH"

echo "INFO: Ermittle wahren Quell-Namen aus .vmx-Datei..."
# Finde die .vmx Datei (es sollte nur eine geben)
VMX_FILE=$(find . -maxdepth 1 -name "*.vmx" -print)

if [ -z "$VMX_FILE" ]; then
    echo "FEHLER: Keine .vmx-Datei im Backup-Ordner gefunden!"
    exit 1
fi

# Extrahiere den Basis-Namen (z.B. aus "./VMDS01.vmx" wird "VMDS01")
TRUE_SOURCE_BASENAME=$(basename "$VMX_FILE" .vmx)
echo "INFO: Wahrer Quell-Name ist: '$TRUE_SOURCE_BASENAME'"

echo "INFO: Benenne Dateien von '$TRUE_SOURCE_BASENAME' zu '$REPLICATED_VM_NAME' um..."
# Schleife über alle Dateien, die zum wahren Basisnamen gehören
for f in "$TRUE_SOURCE_BASENAME".*; do
    # Ersetze den wahren Basisnamen durch den neuen Namen
    new_name=$(echo "$f" | sed "s/$TRUE_SOURCE_BASENAME/$REPLICATED_VM_NAME/")
    echo "  -> Benenne um: '$f' -> '$new_name'"
    mv -- "$f" "$new_name"
done

# Der Pfad zur .vmx Datei, NACHDEM sie umbenannt wurde
RENAMED_VMX_FILE="./$REPLICATED_VM_NAME.vmx"

echo "INFO: Passe VMX-Datei an: $RENAMED_VMX_FILE..."
# Ersetze die alten Namen durch die neuen in der .vmx Datei
sed -i "s/displayName = .*/displayName = \"$REPLICATED_VM_NAME\"/" "$RENAMED_VMX_FILE"
sed -i "s/$TRUE_SOURCE_BASENAME\.vmdk/$REPLICATED_VM_NAME\.vmdk/g" "$RENAMED_VMX_FILE"
sed -i "s/$TRUE_SOURCE_BASENAME\.nvram/$REPLICATED_VM_NAME\.nvram/g" "$RENAMED_VMX_FILE"

echo "INFO: VMX-Anpassung abgeschlossen."
'@
                # Der -f Operator füllt jetzt nur noch die Platzhalter {0} und {1}
                # Die Variable $sourceVmName wird nicht mehr an das Helfer-Skript übergeben, da es sie selbst ermittelt
                $helperScriptContent = $helperScriptTemplate -f $targetVmPath, $replicatedVmName

                # Der Rest bleibt gleich: Zeilenumbrüche konvertieren und hochladen
                $remoteHelperPath = "/tmp/replication_helper.sh"
                $unixHelperScriptContent = $helperScriptContent.Replace("`r`n", "`n")
                $sftpSessionTgt = New-SFTPSession -ComputerName $params.TargetHost -Credential $params.TargetCredential
                Set-SFTPContent -SFTPSession $sftpSessionTgt -Path $remoteHelperPath -Value $unixHelperScriptContent -Encoding UTF8 | Out-Null
                Remove-SFTPSession -SFTPSession $sftpSessionTgt | Out-Null
                Start-Sleep -Seconds 1

                # --- [6/8] Helfer-Skript ausführen ---
                Write-Output "[6/8] Führe Helfer-Skript auf Ziel-Host aus..."
                $helperCmd = "chmod +x $remoteHelperPath && $remoteHelperPath"
                $helperResult = Invoke-SSHCommand -SSHSession $tgtSession -Command $helperCmd
                if ($helperResult.Error) { $helperResult.Error | ForEach-Object { Write-Output "  HELPER-ERROR: $_" } }
                $helperResult.Output | ForEach-Object { Write-Output "  HELPER: $_" }
                if ($helperResult.ExitStatus -ne 0) { throw "Fehler bei der Ausführung des Helfer-Skripts."}

                # --- [7/8] VM registrieren ---
                Write-Output "[7/8] Registriere VM auf Ziel-Host..."
                $registerCmd = "vim-cmd solo/registervm '$targetVmPath/$replicatedVmName.vmx'"
                $registerResult = Invoke-SSHCommand -SSHSession $tgtSession -Command $registerCmd
                if ($registerResult.ExitStatus -ne 0) { throw "Fehler beim Registrieren der VM." }
                Write-Output "VM erfolgreich registriert mit VMID: $($registerResult.Output)"

                # --- [8/8] Aufräumen ---
                Write-Output "[8/8] Räume temporäre Dateien auf dem Zwischenspeicher auf..."
                Invoke-SSHCommand -SSHSession $srcSession -Command "rm -rf '$tempReplicationPath'" | Out-Null
                Invoke-SSHCommand -SSHSession $tgtSession -Command "rm -f $remoteHelperPath; rm -f /tmp/replication_copy.log" | Out-Null

                Write-Output "ERFOLG: REPLIKATION ERFOLGREICH ABGESCHLOSSEN!"
            }
            catch {
                Write-Output "FEHLER: Ein Fehler ist im Replikations-Job aufgetreten: $($_.Exception.Message)"
            }
        }
        # --- ENDE DER FINALEN "GOLDEN MASTER" FUNKTION ---


### Replikations Funktion ENDE

            # Schritt C: Die Funktion innerhalb des Jobs ausführen
            Start-VMReplicationInJob -params $p -srcSession $sourceSession -tgtSession $targetSession

        }
        catch {
             Write-Output "FEHLER: Kritischer Fehler im Job: $($_.Exception.Message)"
        }
        ### KORREKTUR 3 ###
        # Der finally-Block ist jetzt korrekt an den äusseren try-Block gekoppelt
        finally {
            if ($sourceSession) { Remove-SSHSession -SSHSession $sourceSession -ErrorAction SilentlyContinue }
            if ($targetSession) { Remove-SSHSession -SSHSession $targetSession -ErrorAction SilentlyContinue }
            Write-Output "INFO: Hintergrund-Job-Sitzungen wurden bereinigt."
        }
    }


    # Job starten mit den Parametern
    $Global:replicationJob = Start-Job -ScriptBlock $scriptBlock -ArgumentList $jobParams

    # Timer zur Überwachung des Jobs starten
    $Global:replicationJobTimer.Start()

    # GUI informieren und das Replikationsfenster schliessen
    Write-GuiLog "Replikations-Job für '$($jobParams.SourceVmName)' im Hintergrund gestartet (ID: $($Global:replicationJob.Id))."
    $replicationForm.Close()
})


$buttonCancelReplication = New-Object System.Windows.Forms.Button; $buttonCancelReplication.Text = "Abbrechen"; $buttonCancelReplication.Location = New-Object System.Drawing.Point(305, $repCurrentY); $buttonCancelReplication.Size = New-Object System.Drawing.Size(75, 25); $buttonCancelReplication.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$replicationForm.Controls.AddRange(@($buttonStartReplication, $buttonCancelReplication))
$replicationForm.AcceptButton = $buttonStartReplication
$replicationForm.CancelButton = $buttonCancelReplication

# -- ######### # --- Definition des Replikations-Fensters --- Ende #####


# -- Neues Replikations-Fenster (Direkt Host-zu-Host & Schnelles Backup) --
$directReplicationForm = New-Object System.Windows.Forms.Form
$directReplicationForm.Text = "Direkte Replikation / Schnelles Backup (TAR)"
$directReplicationForm.Size = New-Object System.Drawing.Size(420, 420) # Höhe angepasst
$directReplicationForm.StartPosition = "CenterParent"
$directReplicationForm.FormBorderStyle = 'FixedDialog'
$directReplicationForm.MaximizeBox = $false
$directReplicationForm.MinimizeBox = $false

[int]$drCurrentY = 20

# --- NEU: Auswahl des Modus (Replikation oder Backup) ---
$groupDrMode = New-Object System.Windows.Forms.GroupBox
$groupDrMode.Text = "Modus auswählen"
$groupDrMode.Location = New-Object System.Drawing.Point(20, $drCurrentY)
$groupDrMode.Size = New-Object System.Drawing.Size(365, 50)
$radioModeReplication = New-Object System.Windows.Forms.RadioButton; $radioModeReplication.Text = "Replikation (Host-zu-Host)"; $radioModeReplication.Location = New-Object System.Drawing.Point(15, 20); $radioModeReplication.AutoSize = $true; $radioModeReplication.Checked = $true
$radioModeBackup = New-Object System.Windows.Forms.RadioButton; $radioModeBackup.Text = "Schnelles Backup (dieser Host)"; $radioModeBackup.Location = New-Object System.Drawing.Point(180, 20); $radioModeBackup.AutoSize = $true
$groupDrMode.Controls.AddRange(@($radioModeReplication, $radioModeBackup))
$directReplicationForm.Controls.Add($groupDrMode)
$drCurrentY += $groupDrMode.Height + 15

# --- Bestehende Felder ---
$labelDrTargetHost = New-Object System.Windows.Forms.Label; $labelDrTargetHost.Text = "Ziel-Host IP:"; $labelDrTargetHost.Location = New-Object System.Drawing.Point(20, ($drCurrentY + 3)); $labelDrTargetHost.AutoSize = $true
$textboxDrTargetHost = New-Object System.Windows.Forms.TextBox; $textboxDrTargetHost.Location = New-Object System.Drawing.Point(180, $drCurrentY); $textboxDrTargetHost.Size = New-Object System.Drawing.Size(200, 20)
$directReplicationForm.Controls.AddRange(@($labelDrTargetHost, $textboxDrTargetHost))
$drCurrentY += 30

$labelDrTargetUser = New-Object System.Windows.Forms.Label; $labelDrTargetUser.Text = "Ziel-Host Username:"; $labelDrTargetUser.Location = New-Object System.Drawing.Point(20, ($drCurrentY + 3)); $labelDrTargetUser.AutoSize = $true
$textboxDrTargetUser = New-Object System.Windows.Forms.TextBox; $textboxDrTargetUser.Location = New-Object System.Drawing.Point(180, $drCurrentY); $textboxDrTargetUser.Size = New-Object System.Drawing.Size(200, 20); $textboxDrTargetUser.Text = "root"
$directReplicationForm.Controls.AddRange(@($labelDrTargetUser, $textboxDrTargetUser))
$drCurrentY += 30

$labelDrTargetDs = New-Object System.Windows.Forms.Label; $labelDrTargetDs.Text = "Zielspeicher (auf Ziel-Host):"; $labelDrTargetDs.Location = New-Object System.Drawing.Point(20, ($drCurrentY + 3)); $labelDrTargetDs.AutoSize = $true
$textboxDrTargetDs = New-Object System.Windows.Forms.TextBox; $textboxDrTargetDs.Location = New-Object System.Drawing.Point(180, $drCurrentY); $textboxDrTargetDs.Size = New-Object System.Drawing.Size(165, 20)
$buttonBrowseDrTargetDs = New-Object System.Windows.Forms.Button; $buttonBrowseDrTargetDs.Text = "..."; $buttonBrowseDrTargetDs.Location = New-Object System.Drawing.Point(350, ($drCurrentY - 1)); $buttonBrowseDrTargetDs.Size = New-Object System.Drawing.Size(30, 23)
$directReplicationForm.Controls.AddRange(@($labelDrTargetDs, $textboxDrTargetDs, $buttonBrowseDrTargetDs))
$drCurrentY += 30

$labelDrSuffix = New-Object System.Windows.Forms.Label; $labelDrSuffix.Text = "Suffix für VM-Name:"; $labelDrSuffix.Location = New-Object System.Drawing.Point(20, ($drCurrentY + 3)); $labelDrSuffix.AutoSize = $true
$textboxDrSuffix = New-Object System.Windows.Forms.TextBox; $textboxDrSuffix.Location = New-Object System.Drawing.Point(180, $drCurrentY); $textboxDrSuffix.Size = New-Object System.Drawing.Size(200, 20); $textboxDrSuffix.Text = "-DirectReplica"
$directReplicationForm.Controls.AddRange(@($labelDrSuffix, $textboxDrSuffix))
$drCurrentY += 35

$checkboxUseLocalTemp = New-Object System.Windows.Forms.CheckBox; $checkboxUseLocalTemp.Text = "Lokalen VM-Temp verwenden (Standard)"; $checkboxUseLocalTemp.Location = New-Object System.Drawing.Point(20, $drCurrentY); $checkboxUseLocalTemp.AutoSize = $true; $checkboxUseLocalTemp.Checked = $true
$toolTip.SetToolTip($checkboxUseLocalTemp, "Wenn aktiviert, wird der temporäre Klon im Verzeichnis der Quell-VM erstellt.`nDeaktiviere dies, um einen anderen Datastore als Zwischenspeicher zu wählen.")
$directReplicationForm.Controls.Add($checkboxUseLocalTemp)
$drCurrentY += 25

$labelDrTempPath = New-Object System.Windows.Forms.Label; $labelDrTempPath.Text = "Temp. Speicher (Quelle):"; $labelDrTempPath.Location = New-Object System.Drawing.Point(20, ($drCurrentY + 3)); $labelDrTempPath.AutoSize = $true
$textboxDrTempPath = New-Object System.Windows.Forms.TextBox; $textboxDrTempPath.Location = New-Object System.Drawing.Point(180, $drCurrentY); $textboxDrTempPath.Size = New-Object System.Drawing.Size(165, 20); $textboxDrTempPath.Enabled = $false
$buttonBrowseDrTempPath = New-Object System.Windows.Forms.Button; $buttonBrowseDrTempPath.Text = "..."; $buttonBrowseDrTempPath.Location = New-Object System.Drawing.Point(350, ($drCurrentY - 1)); $buttonBrowseDrTempPath.Size = New-Object System.Drawing.Size(30, 23); $buttonBrowseDrTempPath.Enabled = $false
$directReplicationForm.Controls.AddRange(@($labelDrTempPath, $textboxDrTempPath, $buttonBrowseDrTempPath))
$drCurrentY += 45

# ----  Jobliste

function Populate-JobComboBox {
    Write-GuiLog "Suche nach gespeicherten Job-Dateien (*.json)..."
    # Merke dir das aktuell ausgewählte Element
    $previouslySelected = $comboboxJobs.SelectedItem
    
    $comboboxJobs.Items.Clear()
    $comboboxJobs.DisplayMember = "DisplayName" # Wichtig für die Anzeige

    # Füge einen Platzhalter hinzu
    $placeholder = [PSCustomObject]@{ DisplayName = "Bitte Job auswählen..."; FullPath = $null }
    [void]$comboboxJobs.Items.Add($placeholder)
    
    try {
        $jobFiles = Get-ChildItem -Path $Global:ScriptPath -Filter "*.json" -ErrorAction Stop
        if ($jobFiles) {
            foreach ($file in $jobFiles) {
                # Füge jedes File als Objekt mit Anzeige- und Pfad-Eigenschaft hinzu
                $item = [PSCustomObject]@{
                    DisplayName = $file.Name
                    FullPath    = $file.FullName
                }
                [void]$comboboxJobs.Items.Add($item)
            }
            Write-GuiLog "$($jobFiles.Count) Job(s) gefunden und geladen."
        } else {
            Write-GuiLog "Keine Job-Dateien im Skriptverzeichnis gefunden."
        }
    } catch {
        Write-GuiLog "Fehler beim Suchen nach Job-Dateien: $($_.Exception.Message)"
    }

    # Versuche, die vorherige Auswahl wiederherzustellen oder setze auf den Platzhalter
    $itemToSelect = $comboboxJobs.Items | Where-Object { $_.FullPath -eq $previouslySelected.FullPath } | Select-Object -First 1
    if ($itemToSelect) {
        $comboboxJobs.SelectedItem = $itemToSelect
    } else {
        $comboboxJobs.SelectedIndex = 0
    }
}


# --- NEU: Event Handler für die Modus-Auswahl ---
$onTarModeChanged = {
    if ($radioModeBackup.Checked) {
        $textboxDrTargetHost.Text = $textboxIp.Text # Quell-IP übernehmen
        $textboxDrTargetHost.Enabled = $false
        $labelDrTargetDs.Text = "Backup-Ziel (z.B. NFS-Share):"
        $textboxDrSuffix.Text = "-FastBackup"
    } else { # Replikations-Modus
        $textboxDrTargetHost.Enabled = $true
        $labelDrTargetDs.Text = "Zielspeicher (auf Ziel-Host):"
        $textboxDrSuffix.Text = "-DirectReplica"
    }
}
$radioModeReplication.Add_CheckedChanged($onTarModeChanged)
$radioModeBackup.Add_CheckedChanged($onTarModeChanged)

# --- Button-Definitionen ---
$buttonSaveInPopup = New-Object System.Windows.Forms.Button; $buttonSaveInPopup.Text = "Job speichern"; $buttonSaveInPopup.Size = New-Object System.Drawing.Size(140, 25); $buttonSaveInPopup.Location = New-Object System.Drawing.Point(20, $drCurrentY)
$buttonStartDirectReplication = New-Object System.Windows.Forms.Button; $buttonStartDirectReplication.Text = "Starten"; $buttonStartDirectReplication.DialogResult = [System.Windows.Forms.DialogResult]::OK; $buttonStartDirectReplication.Location = New-Object System.Drawing.Point(180, $drCurrentY); $buttonStartDirectReplication.Size = New-Object System.Drawing.Size(120, 25)
$buttonCancelDirectReplication = New-Object System.Windows.Forms.Button; $buttonCancelDirectReplication.Text = "Abbrechen"; $buttonCancelDirectReplication.Location = New-Object System.Drawing.Point(310, $drCurrentY); $buttonCancelDirectReplication.Size = New-Object System.Drawing.Size(75, 25); $buttonCancelDirectReplication.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$directReplicationForm.Controls.AddRange(@($buttonSaveInPopup, $buttonStartDirectReplication, $buttonCancelDirectReplication))
$directReplicationForm.AcceptButton = $buttonStartDirectReplication
$directReplicationForm.CancelButton = $buttonCancelDirectReplication

$buttonSaveInPopup.Add_Click({
    $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveFileDialog.Title = "Job speichern"
    $saveFileDialog.Filter = "GhettoGUI Jobs (*.json)|*.json"
    $saveFileDialog.InitialDirectory = $Global:ScriptPath
    $saveFileDialog.FileName = "$($Global:ESXiConnectedHostName)-Job.json"
    if ($saveFileDialog.ShowDialog($form) -eq 'OK') {
        Save-HostGuiSettings -FilePath $saveFileDialog.FileName
    }
})

$checkboxUseLocalTemp.Add_CheckedChanged({
    $textboxDrTempPath.Enabled = -not $checkboxUseLocalTemp.Checked
    $buttonBrowseDrTempPath.Enabled = -not $checkboxUseLocalTemp.Checked
})

$buttonBrowseDrTempPath.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Die Hauptverbindung zum Quell-Host ist nicht aktiv. Bitte im Hauptfenster verbinden.", "Fehler", "OK", "Warning")
        return
    }
    Write-GuiLog "Öffne Datastore-Auswahl für Quell-Host..."
    $selectedPath = Show-DatastoreSelectionDialog -SSHSession $Global:ESXiSession
    if ($selectedPath) {
        $textboxDrTempPath.Text = $selectedPath
        Write-GuiLog "Temporärer Pfad auf Quelle ausgewählt: $selectedPath"
    }
})

# --- FIX: Werte aus geladenem Job in das Popup übertragen ---

# 1. Temp-Pfad Checkbox setzen (aus Variable)
if ($script:replicationUseLocalTemp -ne $null) {
    $checkboxUseLocalTemp.Checked = $script:replicationUseLocalTemp
}

# 2. Temp-Pfad Text setzen (aus Variable)
if (-not [string]::IsNullOrEmpty($script:replicationTempPath)) {
    $textboxDrTempPath.Text = $script:replicationTempPath
}

# 3. Status der Felder aktualisieren (Aktiv/Inaktiv)
# Das ist wichtig, damit das Feld nicht ausgegraut bleibt, wenn "Lokal" deaktiviert ist
if ($checkboxUseLocalTemp.Checked) {
    $textboxDrTempPath.Enabled = $false
    $buttonBrowseDrTempPath.Enabled = $false
} else {
    $textboxDrTempPath.Enabled = $true
    $buttonBrowseDrTempPath.Enabled = $true
}

# ------------------------------------------------------------

# -- ######### # --- Definition des Direkte Replikation-Fensters --- Ende #####


#========================================================================================
# --- Definition des Dual-Pane SSH-Konsolen-Fensters (V6.2 - Finale, funktionierende Version) ---
#========================================================================================

$sshConsoleForm = New-Object System.Windows.Forms.Form
$sshConsoleForm.Text = "SSH Dual-Konsole & Einrichtungs-Assistent"
$sshConsoleForm.Size = New-Object System.Drawing.Size(1200, 800)
$sshConsoleForm.StartPosition = "CenterParent"
$sshConsoleForm.FormBorderStyle = 'Sizable'
$sshConsoleForm.MinimumSize = New-Object System.Drawing.Size(100, 100)

# Zwei separate, globale Variablen NUR für die Sessions dieses Fensters
$Global:sourceConsoleSession = $null
$Global:targetConsoleSession = $null

# --- Linke Seite: QUELL-HOST ---
$groupSource = New-Object System.Windows.Forms.GroupBox
$groupSource.Text = "Quell-Host"
$groupSource.Location = New-Object System.Drawing.Point(10, 10)
$groupSource.Size = New-Object System.Drawing.Size(570, 500)
$groupSource.Anchor = 'Top, Bottom, Left'

$labelSourceIp = New-Object System.Windows.Forms.Label; $labelSourceIp.Text = "IP:"; $labelSourceIp.Location = New-Object System.Drawing.Point(10, 25); $labelSourceIp.AutoSize = $true
$textboxSourceIp = New-Object System.Windows.Forms.TextBox; $textboxSourceIp.Location = New-Object System.Drawing.Point(40, 22); $textboxSourceIp.Size = New-Object System.Drawing.Size(120, 20)
$buttonSourceConnect = New-Object System.Windows.Forms.Button; $buttonSourceConnect.Text = "Verbinden"; $buttonSourceConnect.Location = New-Object System.Drawing.Point(170, 20); $buttonSourceConnect.Size = New-Object System.Drawing.Size(85, 25)
$buttonSourceDisconnect = New-Object System.Windows.Forms.Button; $buttonSourceDisconnect.Text = "Trennen"; $buttonSourceDisconnect.Location = New-Object System.Drawing.Point(260, 20); $buttonSourceDisconnect.Size = New-Object System.Drawing.Size(85, 25)
$sourceConsoleInput = New-Object System.Windows.Forms.TextBox; $sourceConsoleInput.Location = New-Object System.Drawing.Point(10, 52); $sourceConsoleInput.Size = New-Object System.Drawing.Size(550, 20); $sourceConsoleInput.Anchor = 'Top, Left, Right'; $sourceConsoleInput.Font = New-Object System.Drawing.Font("Consolas", 11); $sourceConsoleInput.BackColor = [System.Drawing.Color]::DimGray; $sourceConsoleInput.ForeColor = [System.Drawing.Color]::White
$sourceConsoleOutput = New-Object System.Windows.Forms.RichTextBox; $sourceConsoleOutput.Location = New-Object System.Drawing.Point(10, 78); $sourceConsoleOutput.Size = New-Object System.Drawing.Size(550, 412); $sourceConsoleOutput.BackColor = [System.Drawing.Color]::Black; $sourceConsoleOutput.ForeColor = [System.Drawing.Color]::White; $sourceConsoleOutput.ReadOnly = $false; $sourceConsoleOutput.Font = New-Object System.Drawing.Font("Consolas", 11); $sourceConsoleOutput.Anchor = 'Top, Bottom, Left, Right'; $sourceConsoleOutput.ScrollBars = 'ForcedVertical'
$groupSource.Controls.AddRange(@($labelSourceIp, $textboxSourceIp, $buttonSourceConnect, $buttonSourceDisconnect, $sourceConsoleInput, $sourceConsoleOutput))

# --- Rechte Seite: ZIEL-HOST ---
$groupTarget = New-Object System.Windows.Forms.GroupBox
$groupTarget.Text = "Ziel-Host"
$groupTarget.Location = New-Object System.Drawing.Point(600, 10)
$groupTarget.Size = New-Object System.Drawing.Size(570, 500)
$groupTarget.Anchor = 'Top, Bottom, Right'

$labelTargetIp = New-Object System.Windows.Forms.Label; $labelTargetIp.Text = "IP:"; $labelTargetIp.Location = New-Object System.Drawing.Point(10, 25); $labelTargetIp.AutoSize = $true
$textboxTargetIp = New-Object System.Windows.Forms.TextBox; $textboxTargetIp.Location = New-Object System.Drawing.Point(40, 22); $textboxTargetIp.Size = New-Object System.Drawing.Size(120, 20)
$buttonTargetConnect = New-Object System.Windows.Forms.Button; $buttonTargetConnect.Text = "Verbinden"; $buttonTargetConnect.Location = New-Object System.Drawing.Point(170, 20); $buttonTargetConnect.Size = New-Object System.Drawing.Size(85, 25)
$buttonTargetDisconnect = New-Object System.Windows.Forms.Button; $buttonTargetDisconnect.Text = "Trennen"; $buttonTargetDisconnect.Location = New-Object System.Drawing.Point(260, 20); $buttonTargetDisconnect.Size = New-Object System.Drawing.Size(85, 25)
$targetConsoleInput = New-Object System.Windows.Forms.TextBox; $targetConsoleInput.Location = New-Object System.Drawing.Point(10, 52); $targetConsoleInput.Size = New-Object System.Drawing.Size(550, 20); $targetConsoleInput.Anchor = 'Top, Left, Right'; $targetConsoleInput.Font = New-Object System.Drawing.Font("Consolas", 11); $targetConsoleInput.BackColor = [System.Drawing.Color]::DimGray; $targetConsoleInput.ForeColor = [System.Drawing.Color]::White
$targetConsoleOutput = New-Object System.Windows.Forms.RichTextBox; $targetConsoleOutput.Location = New-Object System.Drawing.Point(10, 78); $targetConsoleOutput.Size = New-Object System.Drawing.Size(550, 412); $targetConsoleOutput.BackColor = [System.Drawing.Color]::Black; $targetConsoleOutput.ForeColor = [System.Drawing.Color]::White; $targetConsoleOutput.ReadOnly = $false; $targetConsoleOutput.Font = New-Object System.Drawing.Font("Consolas", 11); $targetConsoleOutput.Anchor = 'Top, Bottom, Left, Right'; $targetConsoleOutput.ScrollBars = 'ForcedVertical'
$groupTarget.Controls.AddRange(@($labelTargetIp, $textboxTargetIp, $buttonTargetConnect, $buttonTargetDisconnect, $targetConsoleInput, $targetConsoleOutput))

# --- Unterer Bereich: Management-Panel ---
$groupAssistant = New-Object System.Windows.Forms.GroupBox
$groupAssistant.Text = "Host Management & Assistenten"
$groupAssistant.Location = New-Object System.Drawing.Point(10, 520)
$groupAssistant.Size = New-Object System.Drawing.Size(1160, 230)
$groupAssistant.Anchor = 'Bottom, Left, Right'

# --- Spalte 1: Host-zu-Host & Installation ---
$groupSetup = New-Object System.Windows.Forms.GroupBox; $groupSetup.Text = "Einrichtungs-Assistenten"; $groupSetup.Location = New-Object System.Drawing.Point(15, 25); $groupSetup.Size = New-Object System.Drawing.Size(370, 190)
$buttonGenerateKey = New-Object System.Windows.Forms.Button; $buttonGenerateKey.Text = "1. SSH-Schlüssel einrichten (Anleitung)"; $buttonGenerateKey.Location = New-Object System.Drawing.Point(15, 25); $buttonGenerateKey.Size = New-Object System.Drawing.Size(340, 25)
$buttonInjectKey = New-Object System.Windows.Forms.Button; $buttonInjectKey.Text = "2. Berechtigungen setzen"; $buttonInjectKey.Location = New-Object System.Drawing.Point(15, 55); $buttonInjectKey.Size = New-Object System.Drawing.Size(340, 25)
$buttonTestKey = New-Object System.Windows.Forms.Button; $buttonTestKey.Text = "3. Verbindungstest durchführen"; $buttonTestKey.Location = New-Object System.Drawing.Point(15, 85); $buttonTestKey.Size = New-Object System.Drawing.Size(340, 25)
$buttonUploadToDatastore = New-Object System.Windows.Forms.Button; $buttonUploadToDatastore.Text = "Datei auf Host hochladen..."; $buttonUploadToDatastore.Location = New-Object System.Drawing.Point(15, 120); $buttonUploadToDatastore.Size = New-Object System.Drawing.Size(340, 25); $buttonUploadToDatastore.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$buttonInstallVib = New-Object System.Windows.Forms.Button; $buttonInstallVib.Text = "VIB / Plugin installieren..."; $buttonInstallVib.Location = New-Object System.Drawing.Point(15, 150); $buttonInstallVib.Size = New-Object System.Drawing.Size(340, 25); $buttonInstallVib.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold); $buttonInstallVib.ForeColor = [System.Drawing.Color]::DarkGreen
$groupSetup.Controls.AddRange(@($buttonGenerateKey, $buttonInjectKey, $buttonTestKey, $buttonUploadToDatastore, $buttonInstallVib))

# --- Spalte 2: Host & Job Management ---
$groupManagement = New-Object System.Windows.Forms.GroupBox; $groupManagement.Text = "Host & Job Management"; $groupManagement.Location = New-Object System.Drawing.Point(395, 25); $groupManagement.Size = New-Object System.Drawing.Size(370, 190) # Höhe angepasst
$buttonMaintenanceEnter = New-Object System.Windows.Forms.Button; $buttonMaintenanceEnter.Text = "Wartungsmodus STARTEN"; $buttonMaintenanceEnter.Location = New-Object System.Drawing.Point(15, 25); $buttonMaintenanceEnter.Size = New-Object System.Drawing.Size(165, 25); $buttonMaintenanceEnter.ForeColor = [System.Drawing.Color]::DarkGoldenrod
$buttonMaintenanceExit = New-Object System.Windows.Forms.Button; $buttonMaintenanceExit.Text = "Wartungsmodus BEENDEN"; $buttonMaintenanceExit.Location = New-Object System.Drawing.Point(190, 25); $buttonMaintenanceExit.Size = New-Object System.Drawing.Size(165, 25);
$buttonRebootHost = New-Object System.Windows.Forms.Button; $buttonRebootHost.Text = "Host NEU STARTEN"; $buttonRebootHost.Location = New-Object System.Drawing.Point(15, 55); $buttonRebootHost.Size = New-Object System.Drawing.Size(340, 25); $buttonRebootHost.ForeColor = [System.Drawing.Color]::DarkRed
$buttonKillOrphans = New-Object System.Windows.Forms.Button; $buttonKillOrphans.Text = "1. Verwaiste Jobs bereinigen"; $buttonKillOrphans.Location = New-Object System.Drawing.Point(15, 85); $buttonKillOrphans.Size = New-Object System.Drawing.Size(165, 25);
$buttonConsolidatePowerCLI = New-Object System.Windows.Forms.Button; $buttonConsolidatePowerCLI.Text = "2. VMs-PowerCLI konsolidieren"; $buttonConsolidatePowerCLI.Location = New-Object System.Drawing.Point(190, 85); $buttonConsolidatePowerCLI.Size = New-Object System.Drawing.Size(165, 25); $buttonConsolidatePowerCLI.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold); $buttonConsolidatePowerCLI.ForeColor = [System.Drawing.Color]::DarkMagenta
# NEU: Zwei Buttons für einen sauberen SSH-Schlüssel-Workflow
$buttonGenerateSshKey = New-Object System.Windows.Forms.Button; $buttonGenerateSshKey.Text = "1.Schlüssel auf PC"; $buttonGenerateSshKey.Location = New-Object System.Drawing.Point(15, 120); $buttonGenerateSshKey.Size = New-Object System.Drawing.Size(165, 25);
$buttonRegisterSshKey = New-Object System.Windows.Forms.Button; $buttonRegisterSshKey.Text = "2.Schlüssel auf Host"; $buttonRegisterSshKey.Location = New-Object System.Drawing.Point(190, 120); $buttonRegisterSshKey.Size = New-Object System.Drawing.Size(165, 25);
$buttonMountUsb = New-Object System.Windows.Forms.Button; $buttonMountUsb.Text = "USB-Mount."; $buttonMountUsb.Location = New-Object System.Drawing.Point(15, 150); $buttonMountUsb.Size = New-Object System.Drawing.Size(100, 25); $buttonMountUsb.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold); $buttonMountUsb.ForeColor = [System.Drawing.Color]::DarkSlateGray
# Die zwei neuen Buttons zum Entfernen
$buttonRemoveUsbWizard = New-Object System.Windows.Forms.Button; $buttonRemoveUsbWizard.Text = "USB Dismount"; $buttonRemoveUsbWizard.Location = New-Object System.Drawing.Point(135, 150); $buttonRemoveUsbWizard.Size = New-Object System.Drawing.Size(100, 25); $buttonRemoveUsbWizard.ForeColor = [System.Drawing.Color]::DarkRed
# $buttonUnmountUsb = New-Object System.Windows.Forms.Button; $buttonUnmountUsb.Text = "USB-Dismount"; $buttonUnmountUsb.Location = New-Object System.Drawing.Point(135, 150); $buttonUnmountUsb.Size = New-Object System.Drawing.Size(100, 25); $buttonUnmountUsb.ForeColor = [System.Drawing.Color]::DarkGoldenrod
$buttonWipeUsb = New-Object System.Windows.Forms.Button; $buttonWipeUsb.Text = "USB-Wipe"; $buttonWipeUsb.Location = New-Object System.Drawing.Point(255, 150); $buttonWipeUsb.Size = New-Object System.Drawing.Size(100, 25); $buttonWipeUsb.ForeColor = [System.Drawing.Color]::DarkRed


# Diese Zeile anpassen:
$groupManagement.Controls.AddRange(@($buttonConsolidatePowerCLI, $buttonRemoveUsbWizard, $buttonUnmountUsb, $buttonMaintenanceEnter, $buttonWipeUsb, $buttonMaintenanceExit, $buttonRebootHost, $buttonKillOrphans, $buttonGenerateSshKey, $buttonRegisterSshKey, $buttonMountUsb))

# --- Spalte 3: Cron Job Management ---
$groupCron = New-Object System.Windows.Forms.GroupBox; $groupCron.Text = "Geplante Tasks (Cron)"; $groupCron.Location = New-Object System.Drawing.Point(775, 25); $groupCron.Size = New-Object System.Drawing.Size(370, 190)
$buttonShowCronJobs = New-Object System.Windows.Forms.Button; $buttonShowCronJobs.Text = "Alle Tasks anzeigen"; $buttonShowCronJobs.Location = New-Object System.Drawing.Point(15, 25); $buttonShowCronJobs.Size = New-Object System.Drawing.Size(340, 25)
$labelDeleteJob = New-Object System.Windows.Forms.Label; $labelDeleteJob.Text = "Task-Nr. zum Löschen:"; $labelDeleteJob.Location = New-Object System.Drawing.Point(15, 62); $labelDeleteJob.AutoSize = $true
$textboxJobNumber = New-Object System.Windows.Forms.TextBox; $textboxJobNumber.Location = New-Object System.Drawing.Point(160, 58); $textboxJobNumber.Size = New-Object System.Drawing.Size(50, 20)
$buttonDeleteCronJob = New-Object System.Windows.Forms.Button; $buttonDeleteCronJob.Text = "Ausgewählten Task löschen"; $buttonDeleteCronJob.Location = New-Object System.Drawing.Point(15, 85); $buttonDeleteCronJob.Size = New-Object System.Drawing.Size(340, 25); $buttonDeleteCronJob.ForeColor = [System.Drawing.Color]::DarkRed
$buttonDeleteAllGhettoJobs = New-Object System.Windows.Forms.Button; $buttonDeleteAllGhettoJobs.Text = "Alle GhettoGUI Tasks löschen"; $buttonDeleteAllGhettoJobs.Location = New-Object System.Drawing.Point(15, 120); $buttonDeleteAllGhettoJobs.Size = New-Object System.Drawing.Size(340, 25);
$buttonCronDiag = New-Object System.Windows.Forms.Button; $buttonCronDiag.Text = "Cron Diagnose-Info abrufen"; $buttonCronDiag.Location = New-Object System.Drawing.Point(15, 150); $buttonCronDiag.Size = New-Object System.Drawing.Size(340, 25);
$groupCron.Controls.AddRange(@($buttonShowCronJobs, $labelDeleteJob, $textboxJobNumber, $buttonDeleteCronJob, $buttonDeleteAllGhettoJobs, $buttonCronDiag))

$groupAssistant.Controls.AddRange(@($groupSetup, $groupManagement, $groupCron))

# --- Formular-Steuerelemente HINZUFÜGEN ---
$sshConsoleForm.Controls.AddRange(@($groupSource, $groupTarget, $groupAssistant))

# --- Hilfs- und Event-Funktionen für die SSH-Konsole ---

# Fängt das Schliessen des Fensters ab und versteckt es nur
$sshConsoleForm.Add_FormClosing({ param($sender, $e); $e.Cancel = $true; $sender.Hide() })

# Hilfsfunktion, um Befehle in der jeweiligen Konsole auszuführen und anzuzeigen

# --- NEUE Hilfsfunktion für eine benutzerfreundliche Laufwerksauswahl ---

# --- Angepasste Hilfsfunktion für eine benutzerfreundliche Laufwerksauswahl ---
function Show-DiskSelectionDialog {
    param(
        [string]$DiskListRaw
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "1. Laufwerk auswählen"
    $dialog.Size = New-Object System.Drawing.Size(550, 450)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = 'FixedDialog'

    $labelInfo = New-Object System.Windows.Forms.Label
    # KORREKTUR: Angepasster Hinweistext
    $labelInfo.Text = "Gefilterte Laufwerksliste (nur mpx.vmhba*):`nFalls Ihr Laufwerk fehlt, geben Sie vmkfstools -V Konsole ein."
    $labelInfo.Location = New-Object System.Drawing.Point(15, 15)
    $labelInfo.Size = New-Object System.Drawing.Size(500, 40) # Mehr Platz für zwei Zeilen

    $textDiskList = New-Object System.Windows.Forms.TextBox
    $textDiskList.Location = New-Object System.Drawing.Point(15, 60) # Position angepasst
    $textDiskList.Size = New-Object System.Drawing.Size(500, 230) # Größe angepasst
    $textDiskList.Multiline = $true
    $textDiskList.ScrollBars = "Vertical"
    $textDiskList.ReadOnly = $true
    $textDiskList.Font = New-Object System.Drawing.Font("Consolas", 10)
    $textDiskList.Text = $DiskListRaw

    $labelPrompt = New-Object System.Windows.Forms.Label
    $labelPrompt.Text = "Geben Sie die ID des USB-Laufwerks ein (z.B. mpx.vmhba34:C0:T0:L0):"
    $labelPrompt.Location = New-Object System.Drawing.Point(15, 305)
    $labelPrompt.AutoSize = $true

    $textInputId = New-Object System.Windows.Forms.TextBox
    $textInputId.Location = New-Object System.Drawing.Point(15, 330)
    $textInputId.Size = New-Object System.Drawing.Size(500, 20)

    $buttonOk = New-Object System.Windows.Forms.Button
    $buttonOk.Text = "OK"
    $buttonOk.Location = New-Object System.Drawing.Point(350, 370)
    $buttonOk.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $buttonCancel = New-Object System.Windows.Forms.Button
    $buttonCancel.Text = "Abbrechen"
    $buttonCancel.Location = New-Object System.Drawing.Point(440, 370)
    $buttonCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dialog.Controls.AddRange(@($labelInfo, $textDiskList, $labelPrompt, $textInputId, $buttonOk, $buttonCancel))
    $dialog.AcceptButton = $buttonOk
    $dialog.CancelButton = $buttonCancel
    $dialog.Add_Shown({$textInputId.Focus()})

    if ($dialog.ShowDialog($sshConsoleForm) -eq 'OK') {
        return $textInputId.Text
    }
    return $null
}

# -----Hilfsfunktion USB dismount --------------------------------



# Hilfsfunktion, um Befehle in der jeweiligen Konsole auszuführen und anzuzeigen (Version 2.0 mit Rückgabewert)
function Invoke-DualConsoleCommand {
    param($session, $command, $outputBox)
    
    # NEU: Initialisiere eine Ergebnisvariable
    $resultObject = $null

    if (-not ($session -and $session.Connected)) {
        $outputBox.SelectionColor = [System.Drawing.Color]::Yellow; $outputBox.AppendText("FEHLER: Keine aktive Verbindung für diese Konsole.`n"); $outputBox.SelectionColor = [System.Drawing.Color]::White; return $null
    }
    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $resultObject = Invoke-SSHCommand -SSHSession $session -Command $command
        if ($resultObject.Output) { $outputBox.AppendText(($resultObject.Output -join "`n") + "`n") }
        if ($resultObject.Error) {
            $outputBox.SelectionColor = [System.Drawing.Color]::Red; $outputBox.AppendText("SHELL-FEHLER:`n" + ($resultObject.Error -join "`n") + "`n"); $outputBox.SelectionColor = [System.Drawing.Color]::White
        }
    } catch {
        $outputBox.SelectionColor = [System.Drawing.Color]::Red; $outputBox.AppendText("FATALER FEHLER: $($_.Exception.Message)`n"); $outputBox.SelectionColor = [System.Drawing.Color]::White
        # Im Fehlerfall wird ein Objekt mit einem Fehlercode zurückgegeben
        return [pscustomobject]@{ ExitStatus = -1; Error = $_.Exception.Message }
    } finally {
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default; $outputBox.ScrollToCaret()
    }
    
    # NEU: Gebe das gesamte Ergebnisobjekt zurück
    return $resultObject
}


# Funktion zum Auswählen von Dateien auf einem Datastore (STABILISIERTE VERSION 2.0)
function Show-DatastoreFileSelectionDialog {
    param(
        [Parameter(Mandatory=$true)] [object]$SSHSession,
        [Parameter(Mandatory=$true)] [string[]]$Filter
    )
    
    $currentPath = "/vmfs/volumes"
    
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Navigiere: $currentPath"
    $dialog.Size = New-Object System.Drawing.Size(550, 400)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = 'FixedDialog'
    
    $listBox = New-Object System.Windows.Forms.ListBox; $listBox.Dock = "Fill"
    $buttonSelect = New-Object System.Windows.Forms.Button; $buttonSelect.Text = "Auswählen"; $buttonSelect.DialogResult = "OK"; $buttonSelect.Dock = "Bottom"
    
    $dialog.Controls.AddRange(@($listBox, $buttonSelect))
    $dialog.AcceptButton = $buttonSelect

    $updateListBox = {
        param($path)
        $dialog.Text = "Navigiere: $path"
        $listBox.Items.Clear()
        
        # KORRIGIERTER BEFEHL: 'ls -A' ist zuverlässiger als 'find' für die reine Inhaltsauflistung.
        $command = "ls -A '$path'"
        $result = Invoke-SSHCommand -SSHSession $SSHSession -Command $command
        
        if ($result.ExitStatus -eq 0 -and $result.Output) {
            # KORRIGIERTE VERARBEITUNG: 'ls' gibt direkt die Dateinamen aus, das Parsen wird einfacher.
            # Wir filtern leere Zeilen heraus und sortieren das Ergebnis.
            $items = $result.Output | Where-Object { $_ } | Sort-Object
            $listBox.Items.Add(".. (Eine Ebene höher)")
            $listBox.Items.AddRange($items)
        }
    }

    # Doppelklick soll dasselbe bewirken wie der "Auswählen"-Button
    $listBox.Add_DoubleClick({ $buttonSelect.PerformClick() })

    # Initialen Inhalt des Startverzeichnisses laden
    & $updateListBox -path $currentPath

    # Navigations-Schleife
    while ($true) {
        if ($dialog.ShowDialog($sshConsoleForm) -ne "OK" -or -not $listBox.SelectedItem) {
            $dialog.Dispose()
            return $null
        }
        
        $selectedItem = $listBox.SelectedItem.ToString()
        
        if ($selectedItem -eq ".. (Eine Ebene höher)") {
            # Nur eine Ebene hoch gehen, wenn wir nicht schon im Root sind
            if ($currentPath.Length -gt 15) { # Länge von "/vmfs/volumes"
                $currentPath = Split-Path -Path $currentPath
                & $updateListBox -path $currentPath
            }
            continue
        }
        
        $fullPath = "$currentPath/$selectedItem"
        
        # Prüfen, ob das ausgewählte Element ein Verzeichnis ist
        $isDirResult = Invoke-SSHCommand -SSHSession $SSHSession -Command "if [ -d '$fullPath' ]; then echo 'true'; fi"
        if (($isDirResult.Output -join '') -eq 'true') {
            # In das Verzeichnis navigieren
            $currentPath = $fullPath
            & $updateListBox -path $currentPath
            continue
        }
        
        # Prüfen, ob die Datei dem Filter entspricht
        $match = $false
        foreach ($f in $Filter) {
            if ($selectedItem -like $f) { $match = $true; break }
        }
        
        if ($match) {
            # Gültige Datei ausgewählt, Dialog schliessen und Pfad zurückgeben
            $dialog.Dispose()
            return $fullPath
        } else {
            [System.Windows.Forms.MessageBox]::Show("Bitte wählen Sie eine Datei mit einer der folgenden Endungen: $($Filter -join ', ')", "Falscher Dateityp", "OK", "Information")
        }
    }
}


# Klick-Logik für den Haupt-Button, der das Fenster öffnet
$buttonOpenSshConsole.Add_Click({
    if ($Global:ESXiConnectedHostName) { $textboxSourceIp.Text = $Global:ESXiConnectedHostName }
    if ($Global:LastKnownTargetHost) { $textboxTargetIp.Text = $Global:LastKnownTargetHost }
    if ($sshConsoleForm.Visible) { $sshConsoleForm.Activate() } else { $sshConsoleForm.Show() }
})

# --- Linke & Rechte Konsolen-Logik ---
$buttonSourceConnect.Add_Click({ if ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected) { $sourceConsoleOutput.AppendText("INFO: Bereits mit Quell-Host verbunden.`n"); return }; $ip = $textboxSourceIp.Text; if ([string]::IsNullOrWhiteSpace($ip)) { [System.Windows.Forms.MessageBox]::Show("Bitte IP des Quell-Hosts eingeben."); return }; try { $Global:sourceConsoleCredential = Show-CredentialPrompt -UserName "root" -Message "Passwort für Quell-Host root@$ip eingeben"; if(-not $Global:sourceConsoleCredential) { return }; $Global:sourceConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:sourceConsoleCredential -AcceptKey -ConnectionTimeout 60; $groupSource.Text = "Quell-Host ($ip) - Verbunden"; $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::Lime; $sourceConsoleOutput.AppendText("INFO: Erfolgreich mit Quell-Host $ip verbunden.`n"); $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White } catch { $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::Red; $sourceConsoleOutput.AppendText("FEHLER bei Verbindung zu $ip`: $($_.Exception.Message)`n"); $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White } })
$buttonSourceDisconnect.Add_Click({ if ($Global:sourceConsoleSession) { Remove-SSHSession -SSHSession $Global:sourceConsoleSession -EA 0; $Global:sourceConsoleSession = $null }; $groupSource.Text = "Quell-Host"; $sourceConsoleOutput.AppendText("INFO: Verbindung zum Quell-Host getrennt.`n") })
$sourceConsoleInput.Add_KeyDown({ param($sender, $e); if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $command = $sourceConsoleInput.Text; if ([string]::IsNullOrWhiteSpace($command)) { return }; $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::LawnGreen; $sourceConsoleOutput.AppendText("`n> $command`n"); $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White; $sourceConsoleInput.Clear(); Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput }})
$buttonTargetConnect.Add_Click({ if ($Global:targetConsoleSession -and $Global:targetConsoleSession.Connected) { $targetConsoleOutput.AppendText("INFO: Bereits mit Ziel-Host verbunden.`n"); return }; $ip = $textboxTargetIp.Text; if ([string]::IsNullOrWhiteSpace($ip)) { [System.Windows.Forms.MessageBox]::Show("Bitte IP des Ziel-Hosts eingeben."); return }; try { $Global:targetConsoleCredential = Show-CredentialPrompt -UserName "root" -Message "Passwort für Ziel-Host root@$ip eingeben"; if(-not $Global:targetConsoleCredential) { return }; $Global:targetConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:targetConsoleCredential -AcceptKey -ConnectionTimeout 60; $groupTarget.Text = "Ziel-Host ($ip) - Verbunden"; $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::Lime; $targetConsoleOutput.AppendText("INFO: Erfolgreich mit Ziel-Host $ip verbunden.`n"); $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White } catch { $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::Red; $targetConsoleOutput.AppendText("FEHLER bei Verbindung zu $ip`: $($_.Exception.Message)`n"); $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White } })
$buttonTargetDisconnect.Add_Click({ if ($Global:targetConsoleSession) { Remove-SSHSession -SSHSession $Global:targetConsoleSession -EA 0; $Global:targetConsoleSession = $null }; $groupTarget.Text = "Ziel-Host"; $targetConsoleOutput.AppendText("INFO: Verbindung zum Ziel-Host getrennt.`n") })
$targetConsoleInput.Add_KeyDown({ param($sender, $e); if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $command = $targetConsoleInput.Text; if ([string]::IsNullOrWhiteSpace($command)) { return }; $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::LawnGreen; $targetConsoleOutput.AppendText("`n> $command`n"); $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White; $targetConsoleInput.Clear(); Invoke-DualConsoleCommand -session $Global:targetConsoleSession -command $command -outputBox $targetConsoleOutput }})

# --- Logik für die Assistenten-Buttons ---
# (Die Logik für die SSH-Schlüssel und Cron-Jobs bleibt unverändert)

# Button 1: Erstellt das Transfer-Skript (mit korrigierter "Anhängen"-Logik)

$buttonGenerateKey.Add_Click({
    $sourceIp = $textboxSourceIp.Text
    $targetIp = $textboxTargetIp.Text
    if ([string]::IsNullOrWhiteSpace($sourceIp) -or [string]::IsNullOrWhiteSpace($targetIp)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst die IPs für Quelle und Ziel in die Felder oben eintragen.", "Fehlende Eingabe", "OK", "Warning"); return
    }

    Write-ConsoleLog $sourceConsoleOutput "Schritt 1: Bereite alles auf dem PC vor..." ([System.Drawing.Color]::Cyan)
    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        if (-not (Test-Path "C:\temp")) { New-Item -Path "C:\temp" -ItemType Directory | Out-Null }
        
        $keyFile = "C:\temp\esxi_replication_key"
        
        $batFileContent = @'
@echo off
cls
echo.
echo ====================================================================
echo == GhettoGUI - SSH Key Setup Skript (Teil 1: Ihr PC) ==
echo ====================================================================
echo.

REM --- SCHRITT A ---
IF NOT EXIST "{0}" GOTO GENERATE_NEW

echo.
echo ACHTUNG: Ein Schluessel existiert bereits in C:\temp.
echo.
echo [n] = Bestehenden Key BEHALTEN (fuer weitere Hosts nutzen)
echo [y] = Bestehenden Key LOESCHEN und NEU erstellen
echo.
set /p user_choice="Ihre Wahl (n/y)? "

if /I "%user_choice%"=="n" GOTO USE_EXISTING
if /I "%user_choice%"=="y" GOTO DELETE_AND_NEW

echo Ungueltige Eingabe. Abbruch.
pause
exit /b

:DELETE_AND_NEW
del "{0}"
del "{0}.pub"

:GENERATE_NEW
echo.
echo -> Generiere NEUEN ECDSA-Schluessel...
ssh-keygen -t ecdsa -f "{0}" -N ""
IF %ERRORLEVEL% NEQ 0 (
    echo. & echo FEHLER: ssh-keygen fehlgeschlagen! & pause & exit /b
)
GOTO DISTRIBUTE

:USE_EXISTING
echo.
echo -> Verwende BESTEHENDEN Schluessel.

:DISTRIBUTE
echo.
echo --- SCHRITT B: Schluessel verteilen ---
echo.

REM --- 1. Ziel-Host ---
echo 1. Ziel-Host ({1}) vorbereiten...
echo    (Falls gefragt: Passwort fuer {1} eingeben)
type "{0}.pub" | ssh -o "StrictHostKeyChecking=no" root@{1} "if [ ! -d /etc/ssh/keys-root ]; then mkdir -p /etc/ssh/keys-root; fi && cat >> /etc/ssh/keys-root/authorized_keys"
IF %ERRORLEVEL% NEQ 0 ( echo FEHLER bei Ziel-Host! & pause & exit /b )

echo.
echo --------------------------------------------------------------------
echo.

REM --- 2. Quell-Host Ordner ---
echo 2. Quell-Host ({2}) vorbereiten (Ordner erstellen)...
echo    (Falls gefragt: Passwort fuer {2} eingeben)
ssh -o "StrictHostKeyChecking=no" root@{2} "if [ ! -d /.ssh ]; then mkdir /.ssh; chmod 700 /.ssh; fi"
IF %ERRORLEVEL% NEQ 0 ( echo FEHLER bei Quell-Host Vorbereitung! & pause & exit /b )

echo.
echo --------------------------------------------------------------------
echo.

REM --- 3. Quell-Host Upload ---
echo 3. Privaten Schluessel auf Quell-Host kopieren...
echo    (Falls gefragt: Passwort fuer {2} eingeben)
scp -o "StrictHostKeyChecking=no" "{0}" root@{2}:/.ssh/id_ecdsa
IF %ERRORLEVEL% NEQ 0 ( echo FEHLER bei Quell-Host Upload! & pause & exit /b )

echo.
echo ====================================================================
echo ERFOLG! Alle Schritte abgeschlossen.
echo Kehren Sie zur GhettoGUI zurueck und klicken Sie auf Button 2.
echo.
echo Druecken Sie eine beliebige Taste zum Beenden...
pause > nul
'@ -f $keyFile, $targetIp, $sourceIp

        $batFilePath = "C:\temp\setup_keys.bat"
        Set-Content -Path $batFilePath -Value $batFileContent -Encoding Oem
        Start-Process -FilePath $batFilePath
        Write-ConsoleLog $sourceConsoleOutput " -> Setup-Skript '$batFilePath' erstellt und gestartet."

    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Fehler bei Vorbereitung", "OK", "Error")
    } finally {
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# Button 2: Führt die Konfigurationsbefehle nach Bestätigung automatisch aus
$buttonInjectKey.Add_Click({
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) { [System.Windows.Forms.MessageBox]::Show("Bitte zuerst den Quell-Host verbinden.", "Fehler", "OK", "Warning"); return }
    if (-not ($Global:targetConsoleSession -and $Global:targetConsoleSession.Connected)) { [System.Windows.Forms.MessageBox]::Show("Bitte zuerst den Ziel-Host verbinden.", "Fehler", "OK", "Warning"); return }

    # Die Befehle, die ausgeführt werden sollen
    $sourceCommands = "esxcli network firewall ruleset set --enabled true --ruleset-id=sshClient; mkdir -p /.ssh; chmod 600 /.ssh/id_ecdsa"
    $targetCommands = "chmod 600 /etc/ssh/keys-root/authorized_keys"

    # Sicherheitsabfrage vor der automatischen Ausführung
    $confirmation = [System.Windows.Forms.MessageBox]::Show(
        "Sollen die folgenden Befehle jetzt automatisch ausgeführt werden?`n`nQUELLE: `n$sourceCommands`n`nZIEL: `n$targetCommands", 
        "Schritt 2: Ausführung bestätigen", 
        [System.Windows.Forms.MessageBoxButtons]::YesNo, 
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirmation -eq 'Yes') {
        Write-ConsoleLog $sourceConsoleOutput "--- Führe Befehle auf Quell-Host automatisch aus... ---" ([System.Drawing.Color]::Yellow)
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $sourceCommands -outputBox $sourceConsoleOutput
        
        Write-ConsoleLog $targetConsoleOutput "--- Führe Befehl auf Ziel-Host automatisch aus... ---" ([System.Drawing.Color]::Yellow)
        Invoke-DualConsoleCommand -session $Global:targetConsoleSession -command $targetCommands -outputBox $targetConsoleOutput
        
        Write-ConsoleLog $sourceConsoleOutput "--- Automatisierung abgeschlossen. Bitte mit Button 3 testen. ---" ([System.Drawing.Color]::LawnGreen)
    } else {
        Write-ConsoleLog $sourceConsoleOutput "--- Automatische Ausführung abgebrochen. ---" ([System.Drawing.Color]::Gray)
    }
})


# Button 3: Führt den finalen Verbindungstest mit dem korrekten Schlüssel aus

$buttonTestKey.Add_Click({
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst den Quell-Host verbinden.", "Fehler", "OK", "Warning"); return
    }
    $targetIp = $textboxTargetIp.Text
    if ([string]::IsNullOrWhiteSpace($targetIp)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte die IP des Ziel-Hosts im rechten Feld eingeben.", "Fehler", "OK", "Warning"); return
    }

    # --- NEU: Lösche Junk-Dateien vor dem Test ---
    Write-ConsoleLog $sourceConsoleOutput "Führe Aufräumvorgang durch..." ([System.Drawing.Color]::Cyan)
    $junkFiles = @('Bitte', 'Kopiere', 'Fuege', 'Schluesselpaar', 'Ueberfluessige', 'ECDSA-Schluesselpaar', 'Verwende')
    foreach ($junkFile in $junkFiles) {
        $filePath = Join-Path -Path $Global:ScriptPath -ChildPath $junkFile
        if (Test-Path $filePath) {
            Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
            Write-ConsoleLog $sourceConsoleOutput " -> Datei '$junkFile' gelöscht." ([System.Drawing.Color]::Gray)
        }
    }
    # --- ENDE NEU ---

    Write-ConsoleLog $sourceConsoleOutput "---" ([System.Drawing.Color]::Gray)
    Write-ConsoleLog $sourceConsoleOutput "Führe finalen Verbindungstest von Quelle zu Ziel aus..." ([System.Drawing.Color]::Yellow)

    # KORREKTUR: Der ssh-Befehl verwendet jetzt den korrekten Pfad und Schlüsseltyp: /.ssh/id_ecdsa
    $testCmd = "ssh -i /.ssh/id_ecdsa -o 'StrictHostKeyChecking=no' root@$targetIp `"echo 'ERFOLG! Die Host-zu-Host Verbindung steht!'`""
    
    Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $testCmd -outputBox $sourceConsoleOutput
})


# --- NEUE UND KORRIGIERTE LOGIK FÜR DIE MANAGEMENT-BUTTONS ---

$buttonUploadToDatastore.Add_Click({
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst den Quell-Host in der Konsole verbinden.", "Fehler", "OK", "Warning"); return
    }
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.Title = "Datei für Upload auswählen"
    $openFileDialog.Filter = "Alle Installationsdateien (*.zip, *.vib)|*.zip;*.vib|Alle Dateien (*.*)|*.*"
    if ($openFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $localFilePath = $openFileDialog.FileName
        Write-ConsoleLog $sourceConsoleOutput "Zieldatastore für Upload auswählen..." ([System.Drawing.Color]::Cyan)
        # Wir rufen die allgemeine Datastore-Auswahlfunktion auf
        $targetDatastore = Show-DatastoreSelectionDialog -SSHSession $Global:sourceConsoleSession
        if ($targetDatastore) {
            $targetPath = "$($targetDatastore)/$([System.IO.Path]::GetFileName($localFilePath))"
            Write-ConsoleLog $sourceConsoleOutput "Starte Upload von '$localFilePath' nach '$targetPath'..." ([System.Drawing.Color]::Yellow)
            $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $sftp = $null; $localStream = $null; $remoteStream = $null
            try {
                # KORREKTUR: Erstelle eine neue SFTP-Session direkt mit den bekannten Anmeldedaten, anstatt die SSH-Session wiederzuverwenden.
                $sftp = New-SFTPSession -ComputerName $textboxSourceIp.Text -Credential $Global:sourceConsoleCredential -AcceptKey
                
                # ALT (FEHLERHAFTE ZEILE):
                # $sftp = New-SFTPSession -SSHSession $Global:sourceConsoleSession

                $localStream = [System.IO.File]::OpenRead($localFilePath)
                $remoteStream = New-SFTPFileStream -SFTPSession $sftp -Path $targetPath -FileMode Create -FileAccess Write
                # Streaming ist speicherschonend für grosse Dateien
                $localStream.CopyTo($remoteStream)
                Write-ConsoleLog $sourceConsoleOutput "Upload erfolgreich abgeschlossen!" ([System.Drawing.Color]::LawnGreen)
            } catch {
                Write-ConsoleLog $sourceConsoleOutput "FEHLER beim Upload: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
            } finally {
                # Wichtig: Streams und Session immer sauber schliessen
                if ($remoteStream) { $remoteStream.Close(); $remoteStream.Dispose() }
                if ($localStream) { $localStream.Close(); $localStream.Dispose() }
                if ($sftp) { Remove-SFTPSession -SFTPSession $sftp }
                $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        } else {
             Write-ConsoleLog $sourceConsoleOutput "Auswahl des Zieldastores abgebrochen." ([System.Drawing.Color]::Gray)
        }
    }
})


$buttonInstallVib.Add_Click({
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst den Quell-Host in der Konsole verbinden.", "Fehler", "OK", "Warning"); return
    }
    
    # KORREKTUR: Die gesamte Logik wird in einen try...catch-Block gehüllt, um alle Fehler abzufangen.
    try {
        Write-ConsoleLog $sourceConsoleOutput "Navigiere zum Installationspaket (.zip oder .vib)..." ([System.Drawing.Color]::Cyan)
        $rawVibPath = Show-DatastoreFileSelectionDialog -SSHSession $Global:sourceConsoleSession -Filter "*.zip", "*.vib"
        
        # KORREKTUR: Säubere den zurückgegebenen Pfad von eventuellen "Mülldaten".
        # Wir teilen den String bei Leerzeichen und nehmen das letzte Element, was der Pfad sein sollte.
        $vibPath = ($rawVibPath -split '\s+')[-1]

        if (-not $vibPath -or -not $vibPath.StartsWith("/vmfs/")) {
            Write-ConsoleLog $sourceConsoleOutput "Installation vom Benutzer abgebrochen oder ungültiger Pfad." ([System.Drawing.Color]::Gray)
            return
        }
        
        Write-ConsoleLog $sourceConsoleOutput "Ausgewählte Datei: $vibPath" ([System.Drawing.Color]::White)
        
        $rebootConfirm = [System.Windows.Forms.MessageBox]::Show("Die Installation von VIBs erfordert fast immer einen Neustart des Hosts.`n`nSoll der Host nach einer erfolgreichen Installation automatisch in den Wartungsmodus versetzt und neu gestartet werden?", "Neustart bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        
        $command = ""
        if ($vibPath.EndsWith(".zip")) {
            $command = "esxcli software component apply -d '$vibPath'"
        } elseif ($vibPath.EndsWith(".vib")) {
            $command = "esxcli software vib install -v '$vibPath'"
        } 
        
        # KORREKTUR: Prüfen, ob ein gültiger Befehl erstellt wurde.
        if ([string]::IsNullOrWhiteSpace($command)) {
             Write-ConsoleLog $sourceConsoleOutput "FEHLER: Unbekannter oder ungültiger Dateityp für '$vibPath'." ([System.Drawing.Color]::Red)
             return
        }
        
        Write-ConsoleLog $sourceConsoleOutput "Führe Installationsbefehl aus..." ([System.Drawing.Color]::Yellow)
        Write-ConsoleLog $sourceConsoleOutput "> $command" ([System.Drawing.Color]::Gray)
        
        # KORREKTUR: Fange das Ergebnis der Ausführung ab.
        $installResult = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput
        
        # KORREKTUR: Prüfe, ob die Installation erfolgreich war (ExitStatus 0).
        if ($installResult -and $installResult.ExitStatus -eq 0) {
            Write-ConsoleLog $sourceConsoleOutput "Installation erfolgreich abgeschlossen!" ([System.Drawing.Color]::LawnGreen)
            
            # Führe den Neustart nur bei Erfolg und Bestätigung aus.
            if ($rebootConfirm -eq 'Yes') {
                Write-ConsoleLog $sourceConsoleOutput "Versetze Host in den Wartungsmodus..." ([System.Drawing.Color]::Yellow)
                Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "esxcli system maintenanceMode set --enable true" -outputBox $sourceConsoleOutput
                
                Write-ConsoleLog $sourceConsoleOutput "Starte Host in 3 Sekunden neu..." ([System.Drawing.Color]::DarkRed)
                Start-Sleep -Seconds 3
                Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "reboot" -outputBox $sourceConsoleOutput
            }
        } else {
            # Bei einem Fehler wird hier abgebrochen und der Neustart-Teil wird übersprungen.
            Write-ConsoleLog $sourceConsoleOutput "FEHLER: Die Installation ist fehlgeschlagen. Der Prozess wird abgebrochen. Es erfolgt kein Neustart." ([System.Drawing.Color]::Red)
        }

    } catch {
        # Fängt alle unerwarteten Fehler im gesamten Prozess ab.
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER im Installations-Assistent: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
    }
})

$buttonMaintenanceEnter.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show("Soll der Quell-Host wirklich in den Wartungsmodus versetzt werden?`nAlle VMs müssen dafür ausgeschaltet sein.", "Bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -eq 'Yes') {
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "esxcli system maintenanceMode set --enable true" -outputBox $sourceConsoleOutput
    }
})

$buttonMaintenanceExit.Add_Click({
    Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "esxcli system maintenanceMode set --enable false" -outputBox $sourceConsoleOutput
})

$buttonRebootHost.Add_Click({
    $confirm1 = [System.Windows.Forms.MessageBox]::Show("WARNUNG: Dies wird den Host NEU STARTEN.`nSind Sie absolut sicher?", "Bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Error)
    if ($confirm1 -eq 'Yes') {
        $confirm2 = [System.Windows.Forms.MessageBox]::Show("LETZTE WARNUNG: Host wirklich neu starten?", "Endgültig bestätigen", [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Error)
        if ($confirm2 -eq 'OK') {
            Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "reboot" -outputBox $sourceConsoleOutput
        }
    }
})

# Funktion für Button 1: Schlüssel auf dem lokalen PC erstellen
$buttonGenerateSshKey.Add_Click({
    $privateKeyPath = "$($env:USERPROFILE)\.ssh\id_rsa"
    Write-ConsoleLog $sourceConsoleOutput "--- Erstelle lokalen SSH-Schlüssel... ---" ([System.Drawing.Color]::Cyan)

    if (Test-Path $privateKeyPath) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Es existiert bereits ein SSH-Schlüssel unter '$privateKeyPath'.`n`nMöchten Sie ihn wirklich überschreiben? Bestehende Verbindungen, die diesen Schlüssel nutzen, funktionieren danach nicht mehr!", "Schlüssel überschreiben?", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirm -ne 'Yes') {
            Write-ConsoleLog $sourceConsoleOutput "Vorgang vom Benutzer abgebrochen. Bestehender Schlüssel wird beibehalten." ([System.Drawing.Color]::Gray)
            return
        }
        Write-ConsoleLog $sourceConsoleOutput "WARNUNG: Bestehender Schlüssel wird überschrieben..." ([System.Drawing.Color]::Yellow)
    }

    try {
        # Der -N "" Parameter sorgt für ein leeres Passwort, -f für den Dateipfad.
        $keyGenProcess = Start-Process ssh-keygen.exe -ArgumentList "-t rsa -b 4096 -f `"$privateKeyPath`" -N `"`"" -NoNewWindow -Wait -PassThru
        if ($keyGenProcess.ExitCode -eq 0) {
            Write-ConsoleLog $sourceConsoleOutput "SUCCESS: SSH-Schlüssel wurde erfolgreich erstellt in '$privateKeyPath'." ([System.Drawing.Color]::LawnGreen)
        } else {
            Write-ConsoleLog $sourceConsoleOutput "FEHLER: ssh-keygen.exe hat einen Fehler gemeldet." ([System.Drawing.Color]::Red)
        }
    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER: Konnte ssh-keygen.exe nicht ausführen. Ist der Windows OpenSSH-Client installiert?" ([System.Drawing.Color]::Red)
    }
})

# Funktion für Button 2: Schlüssel auf dem Host hinterlegen (FINALE, KORRIGIERTE VERSION)
$buttonRegisterSshKey.Add_Click({
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst den Quell-Host in der Konsole verbinden.", "Fehler", "OK", "Warning"); return
    }

    $publicKeyPath = "$($env:USERPROFILE)\.ssh\id_rsa.pub"
    Write-ConsoleLog $sourceConsoleOutput "--- Hinterlege SSH-Schlüssel für SFTP-Download ---" ([System.Drawing.Color]::Cyan)
    
    if (-not (Test-Path $publicKeyPath)) {
        Write-ConsoleLog $sourceConsoleOutput "FEHLER: Dein öffentlicher SSH-Schlüssel wurde nicht unter '$publicKeyPath' gefunden." ([System.Drawing.Color]::Red)
        Write-ConsoleLog $sourceConsoleOutput "Bitte klicke zuerst auf '1. SSH-Schlüssel auf PC erstellen'." ([System.Drawing.Color]::Red)
        return
    }

    try {
        $publicKeyContent = Get-Content -Path $publicKeyPath -Raw
        $cleanKeyContent = ($publicKeyContent -split "`r`n|`n|`r")[0]

        # FINALE KORREKTUR: Sicherer Aufbau des Befehls durch einfache String-Verkettung, immun gegen Formatierungsfehler.
        $command = "KEY_CONTENT='" + $cleanKeyContent + "'" + @"
AUTH_KEYS_FILE="/etc/ssh/keys-root/authorized_keys"
echo "INFO: Prüfe und erstelle Verzeichnis /etc/ssh/keys-root/..."
mkdir -p /etc/ssh/keys-root
touch "${AUTH_KEYS_FILE}"
echo "INFO: Prüfe, ob Schlüssel bereits vorhanden ist..."
if grep -q -F "${KEY_CONTENT}" "${AUTH_KEYS_FILE}"; then
    echo "INFO: Dein SSH-Schlüssel ist bereits auf dem Host hinterlegt."
else
    echo "INFO: Füge neuen SSH-Schlüssel hinzu..."
    echo "${KEY_CONTENT}" >> "${AUTH_KEYS_FILE}"
    echo "INFO: Dein SSH-Schlüssel wurde erfolgreich zum Host hinzugefügt."
fi
echo "INFO: Setze korrekte Dateiberechtigungen..."
chmod 600 "${AUTH_KEYS_FILE}"
echo "INFO: Berechtigungen gesetzt."
"@
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput
        Write-ConsoleLog $sourceConsoleOutput "--- Vorgang abgeschlossen. Du kannst jetzt den 'Backup download' ohne Passwort verwenden. ---" ([System.Drawing.Color]::LawnGreen)

    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
    }
})

# (Die Logik für die restlichen Cron- und Management-Buttons bleibt unverändert)

# =====================================================================================
# --- START OF BLOCK TO COPY (Kill-Button V9 - The Atom Bomb) ---
# =====================================================================================

$buttonKillOrphans.Add_Click({
    Write-ConsoleLog $sourceConsoleOutput "--- Starte universelle Bereinigung für alle GhettoGUI-Jobs ---" ([System.Drawing.Color]::Yellow)
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) {
        Write-ConsoleLog $sourceConsoleOutput "FEHLER: Keine Verbindung zum Quell-Host." ([System.Drawing.Color]::Red)
        return
    }

    $confirmResult = [System.Windows.Forms.MessageBox]::Show(
        "WARNUNG: Dieser Vorgang wird versuchen, ALLE laufenden GhettoVCB- und Replikationsprozesse sofort und ohne Rückfrage hart zu beenden (`kill -9`)."+
        "`n`nDies kann zu Datenverlust in den gerade laufenden Kopiervorgängen führen."+
        "`n`nSind Sie sicher, dass Sie fortfahren möchten?",
        "Automatisches Beenden bestätigen",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirmResult -ne 'Yes') {
        Write-ConsoleLog $sourceConsoleOutput "Vorgang vom Benutzer abgebrochen." ([System.Drawing.Color]::Gray)
        return
    }

    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        # --- KORRIGIERTER Schritt 1: Kompatible Prozessanzeige ---
        Write-ConsoleLog $sourceConsoleOutput "`n-> 1. Suche und beende automatisch laufende GhettoGUI-Prozesse..." ([System.Drawing.Color]::Cyan)
        $killCmd = @'
# Finde zuerst die kompletten Zeilen der Prozesse
PROCESS_LINES=$(ps -c | grep -e ghettoVCB.sh -e master_replication -e ghetto_clone -e ghetto_restore -e scheduled_ | grep -v grep)

if [ -n "$PROCESS_LINES" ]; then
    echo "INFO: Folgende GhettoGUI-Prozesse werden sofort beendet:"
    # Zeige die gefundenen Zeilen direkt an
    echo "$PROCESS_LINES"
    
    # Extrahiere die PIDs aus den bereits gefundenen Zeilen
    PIDS_TO_KILL=$(echo "$PROCESS_LINES" | awk '{print $1}')
    
    echo "$PIDS_TO_KILL" | xargs kill -9
    echo "INFO: ''kill -9'' Befehl gesendet."
    sleep 2
else
    echo "INFO: Es wurden keine laufenden GhettoGUI-Jobs zum Beenden gefunden."
fi
'@
        $killCmd = $killCmd.Replace("`r`n", "`n")
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $killCmd -outputBox $sourceConsoleOutput

        # --- Die restlichen Schritte bleiben unverändert ---
        Write-ConsoleLog $sourceConsoleOutput "`n-> 2. Suche und entferne alle GhettoGUI-Snapshots..." ([System.Drawing.Color]::Cyan)
        $cleanupSnapshotsCmd = @'
VM_IDS=$(vim-cmd vmsvc/getallvms | awk '{print $1}')
for VMID in ${VM_IDS}; do
    IS_NUMERIC=$(echo "$VMID" | grep -c '^[0-9][0-9]*$')
    if [ "$IS_NUMERIC" -eq 0 ]; then
        continue
    fi
    SNAPSHOTS=$(vim-cmd vmsvc/snapshot.get ${VMID} 2>/dev/null | grep -i 'ghetto-')
    if [ -n "${SNAPSHOTS}" ]; then
        VM_NAME=$(vim-cmd vmsvc/getallvms | grep "^${VMID} " | awk '{print $2}')
        echo "INFO: Entferne Ghetto-Snapshots von VM ''${VM_NAME}'' (ID: ${VMID})..."
        vim-cmd vmsvc/snapshot.removeall ${VMID}
    fi
done
echo "INFO: Snapshot-Bereinigung abgeschlossen."
'@
        $cleanupSnapshotsCmd = $cleanupSnapshotsCmd.Replace("`r`n", "`n")
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $cleanupSnapshotsCmd -outputBox $sourceConsoleOutput

        Write-ConsoleLog $sourceConsoleOutput "`n-> 2b. Prüfe VMs auf verwaiste Delta-Disks und starte Konsolidierung..." ([System.Drawing.Color]::Cyan)
        $consolidateCmd = @'
VM_INFO=$(vim-cmd vmsvc/getallvms)
echo "${VM_INFO}" | while read -r line; do
    VMID=$(echo "$line" | awk '{print $1}')
    IS_NUMERIC=$(echo "$VMID" | grep -c '^[0-9][0-9]*$')
    if [ "$IS_NUMERIC" -eq 0 ]; then
        continue
    fi
    VMX_PATH=$(echo "$line" | sed -e 's/.*\[\(.*\)\]\s*\(.*\.vmx\).*/\/vmfs\/volumes\/\1\/\2/')
    if [ -f "${VMX_PATH}" ]; then
        grep -q -- '-0000[0-9][0-9]\.vmdk' "${VMX_PATH}"
        GREP_EXIT_CODE=$?
        if [ $GREP_EXIT_CODE -eq 0 ]; then
            VM_NAME=$(echo "$line" | awk '{print $2}')
            echo "WARNUNG: VM ''${VM_NAME}'' (ID: ${VMID}) läuft auf einer Delta-Disk und muss konsolidiert werden."
            echo "INFO: Starte Konsolidierung via ''snapshot.removeall'' für ''${VM_NAME}''..."
            vim-cmd vmsvc/snapshot.removeall ${VMID}
            echo "INFO: Konsolidierungs-Aufgabe für ''${VM_NAME}'' gestartet. Überwachen Sie den Fortschritt im vCenter/ESXi Client."
        fi
    fi
done
echo "INFO: Prüfung auf verwaiste Delta-Disks abgeschlossen."
'@
        $consolidateCmd = $consolidateCmd.Replace("`r`n", "`n")
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $consolidateCmd -outputBox $sourceConsoleOutput

        Write-ConsoleLog $sourceConsoleOutput "`n-> 3. Suche und lösche temporäre Klon-Verzeichnisse (ghetto_clone_*)..." ([System.Drawing.Color]::Cyan)
        $cleanupClonesCmd = "find /vmfs/volumes/ -type d -name 'ghetto_clone_*' -exec echo 'INFO: Lösche: {}' \; -exec rm -rf '{}' \;"
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $cleanupClonesCmd -outputBox $sourceConsoleOutput
        Write-ConsoleLog $sourceConsoleOutput "INFO: Suche nach Klon-Verzeichnissen abgeschlossen."

        Write-ConsoleLog $sourceConsoleOutput "`n-> 4. Räume alle temporären Skript- und Sperrdateien in /tmp auf..." ([System.Drawing.Color]::Cyan)
        $cleanupTmpCmd = "rm -f /tmp/*_replication_*; rm -f /tmp/*_clone_*; rm -f /tmp/*_restore_*; rm -f /tmp/launcher_*; rm -f /tmp/ghetto_pipe_error_*; rm -f /tmp/ghetto_*.lock"
        
		# KORRIGIERTER BEFEHL: Fügt die Standard GhettoVCB-Sperren hinzu
        $cleanupTmpCmd = "rm -f /tmp/*_replication_*; rm -f /tmp/*_clone_*; rm -f /tmp/*_restore_*; rm -f /tmp/launcher_*; rm -f /tmp/ghetto_pipe_error_*; rm -f /tmp/ghetto_*.lock; rm -f /var/run/ghettovcb.lock; rm -rf /tmp/ghettoVCB.work"
		
		Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $cleanupTmpCmd | Out-Null
        Write-ConsoleLog $sourceConsoleOutput "-> Temporäre Dateien gelöscht."
        
        Write-ConsoleLog $sourceConsoleOutput "`n--- Bereinigung abgeschlossen. ---" ([System.Drawing.Color]::Yellow)

    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
    } finally {
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# =====================================================================================
# --- Ende Aufräumen ---
# =====================================================================================
# --- Start PowerCLI
# ----------------------------------------------

$buttonConsolidatePowerCLI.Add_Click({
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst den Quell-Host im Hauptfenster verbinden.", "Fehler", "OK", "Warning"); return
    }
    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
        [System.Windows.Forms.MessageBox]::Show("VMware PowerCLI ist auf diesem PC nicht installiert. Bitte führen Sie 'Install-Module -Name VMware.PowerCLI' in einer Admin-PowerShell aus.", "Fehler", "OK", "Error"); return
    }

    Write-ConsoleLog $sourceConsoleOutput "--- Starte kombinierte Konsolidierungs-Prüfung ---" ([System.Drawing.Color]::Cyan)
    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    
    $vmsToConsolidate = [System.Collections.Generic.List[object]]::new()
    try {
        # --- SCHRITT 1: Finde die VMs mit der zuverlässigen Shell-Methode ---
        Write-ConsoleLog $sourceConsoleOutput "-> 1. Suche via Shell nach VMs, die auf Delta-Disks (-0000*.vmdk) laufen..."
        $findCmd = @'
VM_INFO=$(vim-cmd vmsvc/getallvms)
echo "${VM_INFO}" | while read -r line; do
    VMID=$(echo "$line" | awk '{print $1}')
    if ! echo "$VMID" | grep -q '^[0-9][0-9]*$'; then continue; fi
    VMX_PATH=$(echo "$line" | sed -e 's/.*\[\(.*\)\]\s*\(.*\.vmx\).*/\/vmfs\/volumes\/\1\/\2/')
    if grep -q -- '-0000[0-9][0-9]\.vmdk' "${VMX_PATH}"; then
        VMNAME=$(echo "$line" | awk '{print $2}')
        echo "${VMID}|${VMNAME}"
    fi
done
'@
        $findCmd = $findCmd.Replace("`r`n", "`n")
        $findResult = Invoke-SSHCommand -SSHSession $Global:sourceConsoleSession -command $findCmd
        
        if ($findResult.ExitStatus -eq 0 -and $findResult.Output) {
            $findResult.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
                $parts = $_.Split('|')
                if ($parts.Count -eq 2) {
                    $vmsToConsolidate.Add([PSCustomObject]@{ VMID = $parts[0]; Name = $parts[1] })
                }
            }
            if ($vmsToConsolidate.Count -gt 0) {
                $vmListString = $vmsToConsolidate | ForEach-Object { "$($_.Name) (ID: $($_.VMID))" } | Out-String
                Write-ConsoleLog $sourceConsoleOutput "-> Folgende VMs wurden gefunden:`n$($vmListString.Trim())" ([System.Drawing.Color]::Yellow)
            } else {
                 Write-ConsoleLog $sourceConsoleOutput "-> INFO: Keine VMs gefunden, die auf Delta-Disks laufen." ([System.Drawing.Color]::LawnGreen)
            }
        } else {
            Write-ConsoleLog $sourceConsoleOutput "-> INFO: Keine VMs gefunden, die auf Delta-Disks laufen." ([System.Drawing.Color]::LawnGreen)
        }

        # --- SCHRITT 2: Führe die Konsolidierung mit PowerCLI aus ---
        if ($vmsToConsolidate.Count -gt 0) {
            Write-ConsoleLog $sourceConsoleOutput "`n-> 2. Starte gezielte Konsolidierung via PowerCLI.                (Dies kann dauern, GUI friert ein)" ([System.Drawing.Color]::LawnGreen)
            
            Import-Module VMware.PowerCLI -ErrorAction Stop -WarningAction SilentlyContinue -InformationAction SilentlyContinue -Verbose:$false
            
            Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            
            Write-ConsoleLog $sourceConsoleOutput "--> Verbinde mit $($Global:ESXiConnectedHostName) via PowerCLI..."
            $viserver = Connect-VIServer -Server $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential
            if (-not $viserver) { throw "Verbindung via PowerCLI fehlgeschlagen." }
            Write-ConsoleLog $sourceConsoleOutput "--> Erfolgreich via PowerCLI verbunden."

            foreach ($vmEntry in $vmsToConsolidate) {
                Write-ConsoleLog $sourceConsoleOutput "----> Starte Konsolidierungs-Aufgabe für '$($vmEntry.Name)' (ID: $($vmEntry.VMID))... (Dies kann dauern, GUI friert ein)"
                $vm = Get-VM -Name $vmEntry.Name
                if ($vm) {
                    # FINALE LÖSUNG: Synchroner Aufruf, der wartet, bis er fertig ist.
                    $vm.ExtensionData.ConsolidateVMDisks()
                    Write-ConsoleLog $sourceConsoleOutput "----> Konsolidierung für '$($vmEntry.Name)' abgeschlossen." ([System.Drawing.Color]::LawnGreen)
                } else {
                    Write-ConsoleLog $sourceConsoleOutput "----> FEHLER: VM '$($vmEntry.Name)' konnte via PowerCLI nicht gefunden werden." ([System.Drawing.Color]::Red)
                }
            }
        }
        
        Write-ConsoleLog $sourceConsoleOutput "`n--- Prüfung und Konsolidierung abgeschlossen. ---" ([System.Drawing.Color]::Yellow)

    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
    } finally {
        if ($viserver) {
            Write-ConsoleLog $sourceConsoleOutput "-> Trenne PowerCLI-Verbindung..."
            Disconnect-VIServer -Server $viserver -Confirm:$false -ErrorAction SilentlyContinue -Force
        }
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})


# =====================================================================================
# --- END Powercli ---
# =====================================================================================

# =====================================================================================
# --- Start USB Mount
# ----------------------------------------------

$buttonMountUsb.Add_Click({
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst den Quell-Host in der Konsole verbinden.", "Fehler", "OK", "Warning"); return
    }

    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Write-ConsoleLog $sourceConsoleOutput "--- Starte USB-Datastore Assistent ---" ([System.Drawing.Color]::Cyan)
        Write-ConsoleLog $sourceConsoleOutput "-> Stoppe und deaktiviere USB Arbitrator Dienst..."
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "/etc/init.d/usbarbitrator stop; chkconfig usbarbitrator off" -outputBox $sourceConsoleOutput | Out-Null
        
        # KORREKTUR: Filter entfernt, um ALLE Laufwerke anzuzeigen
        Write-ConsoleLog $sourceConsoleOutput "-> Lade vollständige Liste der verfügbaren Laufwerke..."
        $listDisksResult = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "ls -lh /dev/disks" -outputBox $sourceConsoleOutput
        $diskListString = $listDisksResult.Output -join "`r`n"
        
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $diskId = Show-DiskSelectionDialog -DiskListRaw $diskListString
        if ([string]::IsNullOrWhiteSpace($diskId)) { Write-ConsoleLog $sourceConsoleOutput "Vorgang vom Benutzer abgebrochen." ([System.Drawing.Color]::Gray); return }
        $diskId = $diskId.Trim()

        $datastoreName = [Microsoft.VisualBasic.Interaction]::InputBox("Bitte geben Sie einen Namen für den neuen Datastore ein (z.B. USB-Datastore).", "2. Datastore-Namen festlegen", "USB-Datastore")
        if ([string]::IsNullOrWhiteSpace($datastoreName)) { Write-ConsoleLog $sourceConsoleOutput "Vorgang vom Benutzer abgebrochen." ([System.Drawing.Color]::Gray); return }
        $datastoreName = $datastoreName.Trim()

        $confirmMessage = "ACHTUNG - LETZTE WARNUNG!...Sind Sie absolut sicher, dass Sie fortfahren möchten?"
        $confirmResult = [System.Windows.Forms.MessageBox]::Show($confirmMessage, "Endgültig bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Error)
        if ($confirmResult -ne 'Yes') { Write-ConsoleLog $sourceConsoleOutput "Vorgang vom Benutzer abgebrochen." ([System.Drawing.Color]::Gray); return }

        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Write-ConsoleLog $sourceConsoleOutput "-> Bestätigung erhalten. Starte Vorgang..." ([System.Drawing.Color]::Yellow)
        
        $mklabelCmd = "partedUtil mklabel /dev/disks/$diskId gpt"
        $result1 = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $mklabelCmd -outputBox $sourceConsoleOutput
        if ($result1.ExitStatus -ne 0) { throw "Fehler bei der Erstellung der Partitionstabelle." }

        $commandTemplate = @'
esxcli storage core device list -d {0} | grep "Size:" | awk '{{printf "%.0f\n", $2 * 1024 * 1024 / 512 - 34}}'
'@
        $getEndSectorCmd = $commandTemplate -f $diskId
        $result2 = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $getEndSectorCmd -outputBox $sourceConsoleOutput
        if ($result2.ExitStatus -ne 0 -or -not ($result2.Output -match '^\d+$')) { throw "Fehler bei der Berechnung des Endsektors mit esxcli." }
        $endSector = $result2.Output[0].Trim()
        Write-ConsoleLog $sourceConsoleOutput "    -> Berechneter Endsektor: $endSector"

        $setptblCmd = "partedUtil setptbl /dev/disks/$diskId gpt `"1 2048 $endSector AA31E02A400F11DB9590000C2911D1B8 0`""
        $result3 = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $setptblCmd -outputBox $sourceConsoleOutput
        if ($result3.ExitStatus -ne 0) { throw "Fehler bei der Erstellung der VMFS-Partition." }

        $vmfsCmd = "vmkfstools -C vmfs6 -S '$datastoreName' /dev/disks/${diskId}:1"
        $result4 = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $vmfsCmd -outputBox $sourceConsoleOutput
        if ($result4.ExitStatus -ne 0) { throw "Fehler bei der Formatierung mit vmkfstools." }

        Write-ConsoleLog $sourceConsoleOutput "-> Vorgang erfolgreich abgeschlossen! " ([System.Drawing.Color]::LawnGreen)
		Write-ConsoleLog $sourceConsoleOutput "-> aktualisieren mit vmkfstools -V " ([System.Drawing.Color]::LawnGreen)
		Write-ConsoleLog $sourceConsoleOutput "-> esxcli storage core adapter rescan --all " ([System.Drawing.Color]::LawnGreen)
        [System.Windows.Forms.MessageBox]::Show("USB-Datastore '$datastoreName' wurde erfolgreich erstellt!", "Erfolg", "OK", "Information")

    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER im Assistent: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
    } finally {
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# =====================================================================================
# --- End USB Mount
# ----------------------------------------------

# ----------------------------------------------
# - USB dismount--------------
# ----------------------------------------------

$buttonRemoveUsbWizard.Add_Click({
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) { return }
    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    
    try {
        Write-ConsoleLog $sourceConsoleOutput "--- Starte Assistent zum Entfernen von USB-Datastores ---" ([System.Drawing.Color]::DarkRed)
        
        # KORREKTUR: Ruft die neue, dedizierte Funktion auf
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $datastoreIdentifier = Show-DatastoreSelectionDialogForRemoval -SshSession $Global:sourceConsoleSession
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        if ([string]::IsNullOrWhiteSpace($datastoreIdentifier)) {
            Write-ConsoleLog $sourceConsoleOutput "Vorgang vom Benutzer abgebrochen." ([System.Drawing.Color]::Gray); return
        }
        
        $datastoreName = ""
        $datastoreUuid = ""
        if ($datastoreIdentifier -match '([^\(]+)\s+\(.+?\/([0-9a-f\-]+)\)') {
            $datastoreName = $Matches[1].Trim()
            $datastoreUuid = $Matches[2].Trim()
        } else {
            throw "Konnte Datastore-Namen und UUID nicht aus der Auswahl extrahieren."
        }
        Write-ConsoleLog $sourceConsoleOutput "-> Ausgewählter Datastore: '$datastoreName' (UUID: $datastoreUuid)"

        # Der Rest der Funktion bleibt unverändert...
        Write-ConsoleLog $sourceConsoleOutput "--> Ermittle zugehöriges physisches Laufwerk via UUID..."
        $commandTemplate = @'
esxcli storage vmfs extent list | grep "{0}" | awk '{{print $(NF-1)}}'
'@
        $getDeviceCmd = $commandTemplate -f $datastoreUuid
        $devicePathResult = Invoke-SSHCommand -SSHSession $Global:sourceConsoleSession -Command $getDeviceCmd
        if ($devicePathResult.ExitStatus -ne 0 -or $devicePathResult.Output.Count -eq 0 -or [string]::IsNullOrWhiteSpace($devicePathResult.Output[0])) { throw "Konnte das zugrunde liegende physische Laufwerk für '$datastoreName' nicht finden." }
        $deviceWithPartition = $devicePathResult.Output[0].Trim()
        $deviceId = ($deviceWithPartition -split ':')[0..2] -join ':'
        if ([string]::IsNullOrWhiteSpace($deviceId)) { throw "Konnte die ID des physischen Laufwerks nicht aus '$deviceWithPartition' extrahieren." }
        Write-ConsoleLog $sourceConsoleOutput "    -> Physisches Laufwerk gefunden: '$deviceId'"

        Write-ConsoleLog $sourceConsoleOutput "--> Prüfe, ob der Datastore noch in Benutzung ist..."
        $lsofCmd = "lsof | grep '$datastoreName' | grep -v 'hostd\|vmkernel'"
        $lsofResult = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $lsofCmd -outputBox $sourceConsoleOutput
        if ($lsofResult.Output.Count -gt 0) { throw "Der Datastore '$datastoreName' wird noch von einem Benutzerprozess verwendet! Vorgang abgebrochen." }
        Write-ConsoleLog $sourceConsoleOutput "--> Keine blockierenden Prozesse gefunden. Fortfahren ist sicher."

        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $confirmMessage = "ACHTUNG - FINALER, DESTRUKTIVER VORGANG!...Sind Sie absolut sicher?"
        $confirmResult = [System.Windows.Forms.MessageBox]::Show($confirmMessage, "Entfernen endgültig bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Stop)
        if ($confirmResult -ne 'Yes') { Write-ConsoleLog $sourceConsoleOutput "Vorgang vom Benutzer abgebrochen." ([System.Drawing.Color]::Gray); return }
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        Write-ConsoleLog $sourceConsoleOutput "--> Schritt 1/3: Hänge Datastore '$datastoreName' aus..."
        $unmountResult = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "esxcli storage filesystem unmount -l '$datastoreName'" -outputBox $sourceConsoleOutput
        if ($unmountResult.ExitStatus -ne 0) { throw "Fehler beim Aushängen des Datastores." }

        Write-ConsoleLog $sourceConsoleOutput "--> Schritt 2/3: Lösche Partitionstabelle auf '$deviceId'..."
        $wipeCmd = "partedUtil mklabel /dev/disks/$deviceId msdos"
        $wipeResult = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $wipeCmd -outputBox $sourceConsoleOutput
        if ($wipeResult.ExitStatus -ne 0) { throw "Fehler beim Löschen der Partitionstabelle." }
        
        Write-ConsoleLog $sourceConsoleOutput "--> Schritt 3/3: Scanne Speicheradapter neu..."
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "esxcli storage core adapter rescan --all" -outputBox $sourceConsoleOutput | Out-Null

        Write-ConsoleLog $sourceConsoleOutput "-> USB-Datastore erfolgreich und sauber entfernt!" ([System.Drawing.Color]::LawnGreen)
        [System.Windows.Forms.MessageBox]::Show("Der Datastore '$datastoreName' wurde erfolgreich ausgehängt und das Laufwerk '$deviceId' bereinigt!", "Erfolg", "OK", "Information")

    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Fehler", "OK", "Error")
    } finally {
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# --------------------------------
# ---  Ende USB Dismount

# ----------------------------------------------
# USB Whipe------------
# --------------------------

# Logik für den destruktiven "Bereinigen"-Button

$buttonWipeUsb.Add_Click({
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) { return }
    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    try {
        Write-ConsoleLog $sourceConsoleOutput "--- Starte Assistent zum Bereinigen von Laufwerken ---" ([System.Drawing.Color]::DarkRed)

        # KORREKTUR: Filter entfernt, um ALLE Laufwerke anzuzeigen
        $listDisksResult = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "ls -lh /dev/disks" -outputBox $sourceConsoleOutput
        $diskListString = $listDisksResult.Output -join "`r`n"
        
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $diskToWipe = Show-DiskSelectionDialog -DiskListRaw $diskListString
        if ([string]::IsNullOrWhiteSpace($diskToWipe)) { Write-ConsoleLog $sourceConsoleOutput "Vorgang vom Benutzer abgebrochen." ([System.Drawing.Color]::Gray); return }
        $diskToWipe = $diskToWipe.Trim()
        
        $confirmMessage = "EXTREME VORSICHT - DESTRUKTIVER VORGANG!...Sind Sie absolut sicher?"
        $confirmResult = [System.Windows.Forms.MessageBox]::Show($confirmMessage, "Löschen endgültig bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Stop)
        if ($confirmResult -ne 'Yes') { Write-ConsoleLog $sourceConsoleOutput "Vorgang vom Benutzer abgebrochen." ([System.Drawing.Color]::Gray); return }
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        Write-ConsoleLog $sourceConsoleOutput "--> Lösche Partitionstabelle auf '$diskToWipe'..."
        $wipeCmd = "partedUtil mklabel /dev/disks/$diskToWipe msdos"
        $wipeResult = Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $wipeCmd -outputBox $sourceConsoleOutput
        if ($wipeResult.ExitStatus -ne 0) { throw "Fehler beim Löschen der Partitionstabelle." }
        
        Write-ConsoleLog $sourceConsoleOutput "--> Scanne Speicheradapter neu..."
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command "esxcli storage core adapter rescan --all" -outputBox $sourceConsoleOutput | Out-Null

        Write-ConsoleLog $sourceConsoleOutput "-> Laufwerk '$diskToWipe' erfolgreich bereinigt!" ([System.Drawing.Color]::LawnGreen)

    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
    } finally {
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})


# --------------------------


$buttonShowCronJobs.Add_Click({
    Write-ConsoleLog $sourceConsoleOutput "--- Zeige geplante Tasks (crontab) auf Quell-Host ---" ([System.Drawing.Color]::Yellow)
    $command = 'awk ''{printf "%6d\t%s\n", NR, $0}'' /var/spool/cron/crontabs/root'
    Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput
})

$buttonDeleteCronJob.Add_Click({
    $lineNumber = $textboxJobNumber.Text
    if (-not ($lineNumber -match '^\d+$' -and $lineNumber -ne '0')) { [System.Windows.Forms.MessageBox]::Show("Bitte eine gültige Zeilennummer (größer als 0) eingeben.", "Ungültige Eingabe", "OK", "Warning"); return }
    $confirm = [System.Windows.Forms.MessageBox]::Show("Soll der Task in Zeile $lineNumber wirklich gelöscht werden?", "Löschen bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne 'Yes') { return }
    Write-ConsoleLog $sourceConsoleOutput "--- Lösche Task in Zeile $lineNumber ---" ([System.Drawing.Color]::Red)
    $command = "sed -i '${lineNumber}d' /var/spool/cron/crontabs/root && kill `$(cat /var/run/crond.pid) && crond"
    Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput
    Start-Sleep -Seconds 1; $buttonShowCronJobs.PerformClick()
})

$buttonDeleteAllGhettoJobs.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show("Sollen wirklich ALLE von GhettoGUI erstellten Tasks (Backup und Replikation) gelöscht werden?", "Alle Löschen bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne 'Yes') { return }
    Write-ConsoleLog $sourceConsoleOutput "--- Lösche ALLE GhettoGUI Tasks ---" ([System.Drawing.Color]::Red)
    $command = "sed -i '/# GhettoGUI - /d' /var/spool/cron/crontabs/root && kill `$(cat /var/run/crond.pid) && crond"
    Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput
    Start-Sleep -Seconds 1; $buttonShowCronJobs.PerformClick()
})


# Logik für den Diagnose-Button (Finale Version)
$buttonCronDiag.Add_Click({
    Write-ConsoleLog $sourceConsoleOutput "--- Sammle Cron Diagnose-Informationen (via Skript-Upload) ---" ([System.Drawing.Color]::Aqua)
    
    $ghettoPathOnHost = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnHost)) {
        Write-ConsoleLog $sourceConsoleOutput "FEHLER: GhettoVCB-Pfad im Hauptfenster ist nicht gesetzt." ([System.Drawing.Color]::Red)
        return
    }

    # Das Shell-Skript, das wir auf den Host laden
    $diagScriptTemplate = @'
#!/bin/sh
echo "--- 1. Status des Cron-Dienstes (crond) ---"
ps | grep crond | grep -v grep
echo ""
echo "--- 2. Letzte 15 Cron-Einträge aus dem System-Log ---"
grep cron /var/log/syslog.log | tail -n 15
echo ""
echo "--- 3. Letzte 30 Zeilen der aktuellsten GhettoGUI Log-Datei ---"
latest_log=$(ls -t __GHETTO_PATH__/logs/*.log 2>/dev/null | head -n 1)
if [ -n "$latest_log" ]; then
    echo "Lese: $latest_log"
    tail -n 30 "$latest_log"
else
    echo "Keine GhettoGUI-Logdateien im Verzeichnis '__GHETTO_PATH__/logs' gefunden."
fi
'@
    $diagCommand = $diagScriptTemplate.Replace('__GHETTO_PATH__', $ghettoPathOnHost)

    $remoteScriptPath = "/tmp/ghetto_cron_diag.sh"
    $sftpSession = $null
    try {
        # Schritt 1: Das Diagnose-Skript via SFTP hochladen
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -ErrorAction Stop -AcceptKey -ConnectionTimeout 60
        Set-SFTPContent -SFTPSession $sftpSession -Path $remoteScriptPath -Value ($diagCommand.Replace("`r`n", "`n"))
        
        # Schritt 2: Das Skript ausführbar machen, ausführen und danach wieder löschen
        $command = "chmod +x $remoteScriptPath && $remoteScriptPath && rm $remoteScriptPath"
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput

    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
    } finally {
        # KORREKTUR: -SSHSession zu -SFTPSession geändert
        if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession }
    }
})


# -----------------------------------------------------
# ---- ENDE SSH-KONSOLE ----------
# -----------------------------------------------------


### EVENT HANDLER ESXI ###

$connectButton.Add_Click({
    Write-GuiLog "Verbindungsaufbau zu $($textboxIp.Text)..."
    if (Ensure-PoshSshModule) {
        try {
            $ErrorActionPreference = "Stop"
            if ($Global:ESXiSession -and $Global:ESXiSession.Connected) { Write-GuiLog "Bereits eine aktive Verbindung vorhanden."; return }
            $hostnameFromTextbox = $textboxIp.Text
            if (-not $hostnameFromTextbox) { Write-GuiLog "Fehler: Host IP erforderlich."; return }
            $username = $textboxUser.Text
            if (-not $username) { Write-GuiLog "Fehler: Benutzername erforderlich."; return }

            # KORREKTUR: Der Schalter wird hier hinzugefügt
            $promptResult = Show-CredentialPrompt -UserName $username -Message "Passwort für $username@$hostnameFromTextbox eingeben:" -ShowReloadJobCheckbox
            
            if (-not $promptResult) { Write-GuiLog "Passworteingabe abgebrochen."; return }
            
            $Global:ESXiSshCredential = $promptResult.Credential
            $Global:ESXiConnectedHostName = $hostnameFromTextbox

            $Global:ESXiSession = New-SSHSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -ErrorAction Stop -AcceptKey -ConnectionTimeout 60

            if ($Global:ESXiSession.Connected) {
                Write-GuiLog "Erfolgreich verbunden mit $($Global:ESXiConnectedHostName)!"
				
				# --- HIER DIE NEUE ZEILE EINFÜGEN ---
                $groupTraffic.Text = "Netzwerk-Traffic ($Global:ESXiConnectedHostName)"
                # --- ENDE NEUE ZEILE ---
                
				Write-GuiLog "Lade Netzwerk-Interfaces..."
                $nicsResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network nic list"
                if($nicsResult.Output) {
                    $nics = $nicsResult.Output | Select-String -Pattern '^vmnic' | ForEach-Object { ($_ -split '\s+')[0] }
                    $comboVmnic.Items.Clear(); $comboVmnic.Items.AddRange($nics)
                    if ($comboVmnic.Items.Count -gt 0) { $comboVmnic.SelectedIndex = 0 }
                    Write-GuiLog "$($nics.Count) Netzwerk-Interfaces gefunden."
                }
				
				$connectButton.Enabled = $false; $disconnectButton.Enabled = $true; $buttonSaveGuiSettings.Enabled = $true

                if ($promptResult.ReloadJob) {
                    Write-GuiLog "Lade Job-Details nach, um VM-Liste zu synchronisieren..."
                    $selectedJob = $comboboxJobs.SelectedItem
                    if ($null -ne $selectedJob -and $null -ne $selectedJob.FullPath) {
                        Load-HostGuiSettings -FilePath $selectedJob.FullPath
                    } else {
                        Write-GuiLog "-> Kein Job in der Dropdown-Liste ausgewählt, überspringe Neuladen."
                    }
                }
            }
        } catch {
            Write-GuiLog "Fehler: $($_.Exception.Message)"
            if ($Global:ESXiSession) { Remove-SSHSession -SSHSession $Global:ESXiSession -EA 0 }
            $Global:ESXiSession = $null; $Global:ESXiSshCredential = $null; $Global:ESXiConnectedHostName = $null
        } finally {
            $ErrorActionPreference = "Continue"
        }
    }
})



$disconnectButton.Add_Click({
    Write-GuiLog "Trenne alle Verbindungen...";
    try {
		if ($Global:trafficPollTimer.Enabled) { $Global:trafficPollTimer.Stop() }
        # Schliesst beide möglichen SSH-Verbindungen
        if ($Global:ESXiSession) { Remove-SSHSession -SSHSession $Global:ESXiSession -ErrorAction SilentlyContinue }
        if ($Global:TargetESXiSession) { Remove-SSHSession -SSHSession $Global:TargetESXiSession -ErrorAction SilentlyContinue }
    } catch {
        Write-GuiLog "Fehler beim Trennen aufgetreten: $($_.Exception.Message)"
    } finally {
        # Setzt alle Session-Variablen zurück
        $Global:ESXiSession = $null
        $Global:ESXiSshCredential = $null
        $Global:ESXiConnectedHostName = $null
        $Global:TargetESXiSession = $null
        $Global:TargetESXiSshCredential = $null

        # Aktualisiert den Zustand der GUI-Buttons
        $connectButton.Enabled = $true
        $disconnectButton.Enabled = $false
        # KORREKTUR: Die folgende Zeile wurde entfernt, damit der Button aktiv bleibt
        # $buttonLoadGuiSettings.Enabled = $false 
        $buttonSaveGuiSettings.Enabled = $false

        $comboVmnic.Items.Clear(); $textTrafficStats.Clear()

        # --- HIER DIE NEUE ZEILE EINFÜGEN ---
        $groupTraffic.Text = "Netzwerk-Traffic"
        # --- ENDE NEUE ZEILE ---
		
		
        Write-GuiLog "Alle aktiven Verbindungen getrennt."
    }
})

# --- Event Handler für die vmnic-ComboBox (FINALE VERSION) ---
$comboVmnic.Add_SelectedIndexChanged({
    # Timer stoppen, um den Zähler zurückzusetzen
    $Global:trafficPollTimer.Stop()
    
    # Alle Anzeigen und den Verlauf der letzten Messung zurücksetzen
    $textTrafficStats.Clear()
    $labelTrafficDown.Text = "Down: --- MB/s"
    $labelTrafficUp.Text   = "Up:   --- MB/s"
    $Global:lastTrafficStats = $null

    # Wenn ein gültiges Interface ausgewählt wurde, starte den Timer.
    if ($comboVmnic.SelectedItem) {
        $Global:trafficPollTimer.Start()
    }
})


# -------------------------------------------------------------------------------------
#  -  Start RESTORE und Klon Manuell
# -------------------------------------------------------------------------------------

# -------------------------------------------------------------------------------------
#  -  Start RESTORE
# -------------------------------------------------------------------------------------

# --- Definition des Restore/Klon-Fensters (NEUE VERSION) ---
$restoreForm = New-Object System.Windows.Forms.Form
$restoreForm.Text = "VM Wiederherstellungs- & Klon-Assistent"
$restoreForm.Size = New-Object System.Drawing.Size(550, 530) # Höhe angepasst
$restoreForm.StartPosition = "CenterParent"
$restoreForm.FormBorderStyle = 'FixedDialog'
$restoreForm.MaximizeBox = $false
$restoreForm.MinimizeBox = $false

$restoreCurrentY = 20

# --- Auswahl des Modus (Restore vs. Klon) ---
$groupRestoreMode = New-Object System.Windows.Forms.GroupBox; $groupRestoreMode.Text = "Aktion auswählen"; $groupRestoreMode.Location = New-Object System.Drawing.Point(20, $restoreCurrentY); $groupRestoreMode.Size = New-Object System.Drawing.Size(500, 100)
$radioRestoreFromBackup = New-Object System.Windows.Forms.RadioButton; $radioRestoreFromBackup.Text = "VM aus einem bestehenden Backup-Ordner wiederherstellen (Kalt-Restore)"; $radioRestoreFromBackup.Location = New-Object System.Drawing.Point(15, 25); $radioRestoreFromBackup.AutoSize = $true; $radioRestoreFromBackup.Checked = $true
$radioCloneFromVm = New-Object System.Windows.Forms.RadioButton; $radioCloneFromVm.Text = "Laufende VM als neue VM klonen (Heiss-Klon)"; $radioCloneFromVm.Location = New-Object System.Drawing.Point(15, 50); $radioCloneFromVm.AutoSize = $true
$radioHolePunch = New-Object System.Windows.Forms.RadioButton; $radioHolePunch.Text = "Speicherplatz freigeben (Hole Punching)"; $radioHolePunch.Location = New-Object System.Drawing.Point(15, 75); $radioHolePunch.AutoSize = $true
$groupRestoreMode.Controls.AddRange(@($radioRestoreFromBackup, $radioHolePunch, $radioCloneFromVm))
$restoreForm.Controls.Add($groupRestoreMode)
$restoreCurrentY += $groupRestoreMode.Height + 15

# --- Quelle (dynamisch, je nach Modus) ---
$labelRestoreSource = New-Object System.Windows.Forms.Label; $labelRestoreSource.Text = "Zu wiederherstellendes Backup:"; $labelRestoreSource.Location = New-Object System.Drawing.Point(20, ($restoreCurrentY + 3)); $labelRestoreSource.AutoSize = $true
$textboxRestoreSourcePath = New-Object System.Windows.Forms.TextBox; $textboxRestoreSourcePath.Location = New-Object System.Drawing.Point(20, ($restoreCurrentY + 25)); $textboxRestoreSourcePath.Size = New-Object System.Drawing.Size(400, 20); $textboxRestoreSourcePath.ReadOnly = $true
$buttonBrowseRestoreSource = New-Object System.Windows.Forms.Button; $buttonBrowseRestoreSource.Text = "Durchsuchen..."; $buttonBrowseRestoreSource.Location = New-Object System.Drawing.Point(430, ($restoreCurrentY + 23)); $buttonBrowseRestoreSource.Size = New-Object System.Drawing.Size(90, 25)
$restoreCurrentY += 60

# --- Ziel-Datastore ---
$labelRestoreTargetDs = New-Object System.Windows.Forms.Label; $labelRestoreTargetDs.Text = "Ziel-Datastore für die Wiederherstellung/den Klon:"; $labelRestoreTargetDs.Location = New-Object System.Drawing.Point(20, ($restoreCurrentY + 3)); $labelRestoreTargetDs.AutoSize = $true
$textboxRestoreTargetPath = New-Object System.Windows.Forms.TextBox; $textboxRestoreTargetPath.Location = New-Object System.Drawing.Point(20, ($restoreCurrentY + 25)); $textboxRestoreTargetPath.Size = New-Object System.Drawing.Size(400, 20); $textboxRestoreTargetPath.ReadOnly = $true
$buttonBrowseRestoreTarget = New-Object System.Windows.Forms.Button; $buttonBrowseRestoreTarget.Text = "Durchsuchen..."; $buttonBrowseRestoreTarget.Location = New-Object System.Drawing.Point(430, ($restoreCurrentY + 23)); $buttonBrowseRestoreTarget.Size = New-Object System.Drawing.Size(90, 25)
$restoreCurrentY += 60

# --- Neuer VM-Name ---
$labelRestoreNewVmName = New-Object System.Windows.Forms.Label; $labelRestoreNewVmName.Text = "Neuer Name für die wiederhergestellte/geklonte VM:"; $labelRestoreNewVmName.Location = New-Object System.Drawing.Point(20, ($restoreCurrentY + 3)); $labelRestoreNewVmName.AutoSize = $true
$textboxRestoreNewVmName = New-Object System.Windows.Forms.TextBox; $textboxRestoreNewVmName.Location = New-Object System.Drawing.Point(20, ($restoreCurrentY + 25)); $textboxRestoreNewVmName.Size = New-Object System.Drawing.Size(400, 20)
$restoreCurrentY += 50

# --- Optionen (MIT "EINSCHALTEN"-CHECKBOX) ---
$groupRestoreOptions = New-Object System.Windows.Forms.GroupBox; $groupRestoreOptions.Text = "Optionen"; $groupRestoreOptions.Location = New-Object System.Drawing.Point(20, $restoreCurrentY); $groupRestoreOptions.Size = New-Object System.Drawing.Size(500, 105)
$radioRestoreMoved = New-Object System.Windows.Forms.RadioButton; $radioRestoreMoved.Text = "Als 'verschoben' registrieren (behält UUID & MAC bei)"; $radioRestoreMoved.Location = New-Object System.Drawing.Point(15, 25); $radioRestoreMoved.AutoSize = $true; $radioRestoreMoved.Checked = $true
$radioRestoreCopied = New-Object System.Windows.Forms.RadioButton; $radioRestoreCopied.Text = "Als 'Kopie' registrieren (neue UUID & MAC)"; $radioRestoreCopied.Location = New-Object System.Drawing.Point(15, 50); $radioRestoreCopied.AutoSize = $true
$checkboxPowerOnAfterRestore = New-Object System.Windows.Forms.CheckBox; $checkboxPowerOnAfterRestore.Text = "VM nach dem Vorgang automatisch einschalten"; $checkboxPowerOnAfterRestore.Location = New-Object System.Drawing.Point(15, 75); $checkboxPowerOnAfterRestore.AutoSize = $true
$groupRestoreOptions.Controls.AddRange(@($radioRestoreMoved, $radioRestoreCopied, $checkboxPowerOnAfterRestore))
$restoreCurrentY += $groupRestoreOptions.Height + 15

# --- Buttons am unteren Rand ---
# NEU: Button zum Speichern der Jobeinstellungen
$buttonSaveRestoreJob = New-Object System.Windows.Forms.Button
$buttonSaveRestoreJob.Text = "Job speichern unter..."
$buttonSaveRestoreJob.Location = New-Object System.Drawing.Point(20, $restoreCurrentY)
$buttonSaveRestoreJob.Size = New-Object System.Drawing.Size(150, 25)

# Klick-Logik für den neuen Button
$buttonSaveRestoreJob.Add_Click({
    $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveFileDialog.Title = "Restore/Klon-Job speichern unter..."
    $saveFileDialog.Filter = "GhettoGUI Jobs (*.json)|*.json"
    $saveFileDialog.InitialDirectory = $Global:ScriptPath
    $saveFileDialog.FileName = "$($Global:ESXiConnectedHostName)-RestoreJob.json"
    if ($saveFileDialog.ShowDialog($form) -eq 'OK') {
        Save-HostGuiSettings -FilePath $saveFileDialog.FileName
    }
})

# KORREKTUR: Position der bestehenden Buttons angepasst
$buttonStartRestore = New-Object System.Windows.Forms.Button; $buttonStartRestore.Text = "Starten"; $buttonStartRestore.Location = New-Object System.Drawing.Point(290, $restoreCurrentY); $buttonStartRestore.Size = New-Object System.Drawing.Size(120, 25); $buttonStartRestore.DialogResult = [System.Windows.Forms.DialogResult]::OK
$buttonCancelRestore = New-Object System.Windows.Forms.Button; $buttonCancelRestore.Text = "Abbrechen"; $buttonCancelRestore.Location = New-Object System.Drawing.Point(420, $restoreCurrentY); $buttonCancelRestore.Size = New-Object System.Drawing.Size(100, 25); $buttonCancelRestore.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

# KORREKTUR: Neuen Button zur Control-Liste hinzufügen
$restoreForm.Controls.AddRange(@($labelRestoreSource, $textboxRestoreSourcePath, $buttonBrowseRestoreSource, $labelRestoreTargetDs, $textboxRestoreTargetPath, $buttonBrowseRestoreTarget, $labelRestoreNewVmName, $textboxRestoreNewVmName, $groupRestoreOptions, $buttonSaveRestoreJob, $buttonStartRestore, $buttonCancelRestore))
$restoreForm.AcceptButton = $buttonStartRestore
$restoreForm.CancelButton = $buttonCancelRestore


# --- Dynamische UI-Logik für die Radio-Buttons ---
$onRestoreModeChanged = {
    if ($radioRestoreFromBackup.Checked) {
        $labelRestoreSource.Text = "Zu wiederherstellendes Backup:"
        $textboxRestoreSourcePath.ReadOnly = $true
    } else { # $radioCloneFromVm.Checked
        $labelRestoreSource.Text = "Zu klonende Quell-VM:"
        $textboxRestoreSourcePath.ReadOnly = $false # KORREKTUR: $false
    }
}

$radioRestoreFromBackup.Add_CheckedChanged($onRestoreModeChanged)
$radioCloneFromVm.Add_CheckedChanged($onRestoreModeChanged)


# -----------------------------------------------------
# Hole Punching
# -----------------------------------------------------

$maintenanceScriptTemplate = @'
#!/bin/sh
# GhettoGUI Maintenance Helper
UNIQUE_ID='__UNIQUE_ID__'
GHETTO_PATH='__GHETTO_PATH__'
LOG_FILE="${GHETTO_PATH}/logs/maintenance_${UNIQUE_ID}.log"
VM_LIST='__VM_LIST__'

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -> $1" >> ${LOG_FILE}; sync; }

mkdir -p "${GHETTO_PATH}/logs"
echo "--- START MAINTENANCE JOB (ID: ${UNIQUE_ID}) ---" > ${LOG_FILE}
log "Modus: Hole Punching (Speicherplatzfreigabe)"
CLEAN_VM_LIST=$(echo "${VM_LIST}" | sed '/^$/d')

for VM_NAME in ${CLEAN_VM_LIST}; do
    log "--------------------------------------------------"
    log "Bearbeite VM: ${VM_NAME}"
    VM_INFO=$(vim-cmd vmsvc/getallvms | awk -v name="${VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $0; }')
    if [ -z "${VM_INFO}" ]; then log "FEHLER: VM nicht gefunden!"; continue; fi
    VMID=$(echo "${VM_INFO}" | awk '{print $1}')
    POWER_STATE=$(vim-cmd vmsvc/power.getstate ${VMID} | grep -i "Powered" | awk '{print $NF}')
    if [ "${POWER_STATE}" = "on" ]; then
        log "WARNUNG: VM ist eingeschaltet! Hole Punching uebersprungen."
        continue
    fi
    VMX_FULL_PATH=$(echo "${VM_INFO}" | sed -e 's/.*\[\(.*\)\]\s*\(.*\.vmx\).*/\/vmfs\/volumes\/\1\/\2/')
    VM_DIR=$(dirname "${VMX_FULL_PATH}")
    grep -iE 'scsi[0-9]+:[0-9]+\.fileName' "${VMX_FULL_PATH}" | while read line; do
        DISK_FILE_REL=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p')
        if [ -z "${DISK_FILE_REL}" ]; then continue; fi
        if echo "${DISK_FILE_REL}" | grep -q "^/"; then DISK_FULL_PATH="${DISK_FILE_REL}"; else DISK_FULL_PATH="${VM_DIR}/${DISK_FILE_REL}"; fi
        log "  -> Disk gefunden: $(basename "${DISK_FULL_PATH}")"
        log "     Starte vmkfstools -K (kann dauern)..."
        vmkfstools -K "${DISK_FULL_PATH}" 2>&1 | while read out; do log "     [Progress] $out"; done
        log "     Abgeschlossen."
    done
done
log "--------------------------------------------------"
log "=== WARTUNGSJOB BEENDET ==="
'@

# --- NEU: Shell-Skript-Vorlage für den MANUELLEN MULTI-VM HOT-KLON ---
$multiCloneScriptTemplate = @'
#!/bin/sh
# GhettoGUI Multi-VM Clone Helper V5.0 (Golden Master)
# - FINAL: Stops copying non-essential metadata (.vmsd, .vmxf) to prevent "Invalid State" errors.
# - FINAL: Adds a wait loop to ensure snapshot consolidation is complete before processing the next VM, preventing storage race conditions.
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin
export PATH

# Parameter
VM_LIST='
__VM_LIST__
'
NAME_TEMPLATE='__NAME_TEMPLATE__'
TARGET_DATASTORE='__TARGET_DATASTORE__'
POWER_ON='__POWER_ON__'
UUID_ACTION='create'
DISK_FORMAT='thin'
SNAP_QUIESCE='__SNAP_QUIESCE__'
UNIQUE_ID='__UNIQUE_ID__'
GHETTO_PATH='__GHETTO_PATH__'
LOG_FILE="${GHETTO_PATH}/logs/clone_${UNIQUE_ID}.log"
EMAIL_ENABLED=__EMAIL_ENABLED__
EMAIL_TO='__EMAIL_TO__'
EMAIL_FROM='__EMAIL_FROM__'
EMAIL_DISPLAY_NAME='__EMAIL_DISPLAY_NAME__'
EMAIL_SERVER='__EMAIL_SERVER__'
EMAIL_PORT='__EMAIL_PORT__'
EMAIL_USER='__EMAIL_USER__'
EMAIL_PASS='__EMAIL_PASS__'
EMAIL_SUBJECT='__EMAIL_SUBJECT__'
SENDMAIL_PATH="${GHETTO_PATH}/sendmail"
OVERALL_STATUS="OK"

# --- Logging und E-Mail Funktionen ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -> $1" >> ${LOG_FILE}; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; }
log_raw() { echo "$1" >> ${LOG_FILE}; }
VM_REPORT_LIST=""

send_email_notification() {
    DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi
    log_raw "\n--- Zusammenfassung der geklonten VMs ---"
    log_raw "${VM_REPORT_LIST}"
    log_raw "-----------------------------------------"
    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: Klonen ERFOLGREICH! ##"; else FINAL_STATUS_MSG="## Final status: FEHLER: Klonen teilweise oder komplett fehlgeschlagen! ##"; fi
    log "Bereite E-Mail vor: ${OVERALL_STATUS}"; log_raw "Backup Duration: ${DURATION_MSG}"; log_raw "${FINAL_STATUS_MSG}";
    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/[;,]/ /g');
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -N "${EMAIL_DISPLAY_NAME}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1;
    fi;
}

# --- Skriptstart ---
START_TIME=$(date +%s)
trap 'log_error "Unerwarteter, fataler Fehler. Notfall-Abbruch."; exit 1' EXIT

if [ ! -d "${GHETTO_PATH}/logs" ]; then mkdir -p "${GHETTO_PATH}/logs"; fi
rm -f ${LOG_FILE}

log "====== MULTI-VM KLON-PROZESS GESTARTET (ID: ${UNIQUE_ID}) ======"
log_raw "Startzeit: $(date '+%Y-%m-%d %H:%M:%S')"
log_raw "Job-Konfiguration:"; log_raw "  - Typ: Manueller Multi-VM Hot-Klon V8.4.4"; log_raw "  - Ziel-Datastore: ${TARGET_DATASTORE}"; log_raw "  - Namens-Vorlage: ${NAME_TEMPLATE}"; log_raw "Speicherplatz (Vorher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h "${TARGET_DATASTORE}" 2>/dev/null | grep /vmfs/)"; log_raw "--- START DES DETAILLOGS ---";

CLEAN_VM_LIST=$(echo "${VM_LIST}" | sed -e 's/\r//g' -e '/^$/d')
for SOURCE_VM_NAME in ${CLEAN_VM_LIST}; do
    log "#################### Starte Klon für VM: ${SOURCE_VM_NAME} ####################"
    log "initiate backup for ${SOURCE_VM_NAME}"

    NEW_VM_NAME=$(echo "${NAME_TEMPLATE}" | sed "s/\*/${SOURCE_VM_NAME}/g")
    log "  -> Generierter Ziel-Name: ${NEW_VM_NAME}"

    SNAPSHOT_NAME="ghetto-clone-${UNIQUE_ID}-$(echo ${SOURCE_VM_NAME} | sed 's/ //g')"
    VMID=""
    
    VM_INFO_LINE=$(/bin/vim-cmd vmsvc/getallvms | grep -v 'invalid' | awk -v name="${SOURCE_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $0; }')
    if [ -z "${VM_INFO_LINE}" ]; then log_error "Quell-VM '${SOURCE_VM_NAME}' nicht gefunden! Überspringe..."; OVERALL_STATUS="ERROR"; continue; fi
    VMID=$(echo "${VM_INFO_LINE}" | awk '{print $1}'); VMX_FULL_PATH=$(echo "${VM_INFO_LINE}" | awk '{ for(i=1; i<=NF; i++) { if ($i ~ /\.vmx$/) { gsub(/\[|\]/,"",$(i-1)); print "/vmfs/volumes/"$(i-1)"/"$i } } }'); VMX_DIR=$(dirname "${VMX_FULL_PATH}")

    TARGET_VM_PATH="${TARGET_DATASTORE}/${NEW_VM_NAME}"

    # --- START: VERBESSERTE BEREINIGUNG ---
    log "[1/7] Bereinige eventuell existierenden alten Klon..."
    OLD_VMID=$(/bin/vim-cmd vmsvc/getallvms | awk -v name="${NEW_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $1; }')
    if [ -n "${OLD_VMID}" ]; then
        log "  -> Alter Klon '${NEW_VM_NAME}' mit VMID ${OLD_VMID} gefunden. Wird entfernt..."
        /bin/vim-cmd vmsvc/power.off ${OLD_VMID} >/dev/null 2>&1 || true
        sleep 2
        /bin/vim-cmd vmsvc/unregister ${OLD_VMID} >/dev/null 2>&1
        log "  -> Alter Klon wurde deregistriert."
    fi
    # --- ENDE: VERBESSERTE BEREINIGUNG ---
	
    log "[2/7] Erstelle Zielverzeichnis..."; rm -rf "${TARGET_VM_PATH}"; mkdir -p "${TARGET_VM_PATH}";
    log "[3/7] Erstelle Snapshot..."; /bin/vim-cmd vmsvc/snapshot.create ${VMID} "${SNAPSHOT_NAME}" "GhettoGUI Multi-Clone" 0 ${SNAP_QUIESCE}; log "  -> Warte 15s..."; sleep 15;

    log "[4/7] Klone BASIS-Festplatten...";
    DISK_DEFS_ORIG=$(grep -iE '(\.vmdk)' "${VMX_FULL_PATH}" | grep -iE '(^scsi|^ide|^sata|^nvme)'); CLONE_ERROR=0;
    OLD_IFS=$IFS; IFS='
'; for line in ${DISK_DEFS_ORIG}; do
        IFS=$OLD_IFS; DISK_FILE_NAME=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p' | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/');
        if [ -z "${DISK_FILE_NAME}" ]; then continue; fi;
        if echo "${DISK_FILE_NAME}" | grep -q "^/"; then SOURCE_DISK_PATH="${DISK_FILE_NAME}"; else SOURCE_DISK_PATH="${VMX_DIR}/${DISK_FILE_NAME}"; fi;
        DEST_DISK_BASENAME=$(basename "${DISK_FILE_NAME}"); DEST_DISK_PATH="${TARGET_VM_PATH}/${DEST_DISK_BASENAME}";
        log "  -> Klone Festplatte: ${DEST_DISK_BASENAME}"; vmkfstools -i "${SOURCE_DISK_PATH}" -d ${DISK_FORMAT} "${DEST_DISK_PATH}" >> ${LOG_FILE} 2>&1;
        if [ $? -ne 0 ]; then log_error "Klonen von ${DEST_DISK_BASENAME} fehlgeschlagen!"; CLONE_ERROR=1; break; fi;
    done; IFS=$OLD_IFS;
    if [ ${CLONE_ERROR} -eq 1 ]; then OVERALL_STATUS="ERROR"; log_error "Überspringe Rest für ${SOURCE_VM_NAME}..."; /bin/vim-cmd vmsvc/snapshot.removeall ${VMID} > /dev/null 2>&1 || true; continue; fi

    log "[5/7] Kopiere essentielle Konfigurationsdateien...";
    (cd "${VMX_DIR}" && find . -maxdepth 1 \( -name "*.vmx" -o -name "*.nvram" \) -exec cp -p '{}' "${TARGET_VM_PATH}/" \;)

    log "[6/7] Passe Konfigurationsdateien an...";
    (
        cd "${TARGET_VM_PATH}"; ORIG_VMX_FILE=$(find . -maxdepth 1 -name "*.vmx"); ORIG_BASENAME=$(basename "${ORIG_VMX_FILE}" .vmx);
        for f in "${ORIG_BASENAME}"*; do
            new_name=$(echo "$f" | sed "s/^${ORIG_BASENAME}/${NEW_VM_NAME}/");
            if [ "$f" != "$new_name" ]; then mv -- "$f" "$new_name"; fi
        done;
        NEW_VMX_FILE="./${NEW_VM_NAME}.vmx";
        for vmdk_file in "${NEW_VM_NAME}"*.vmdk; do
            if ! echo "${vmdk_file}" | grep -q -- "-flat.vmdk"; then sed -i "s/${ORIG_BASENAME}/${NEW_VM_NAME}/g" "${vmdk_file}"; fi
        done;
        sed -i "s/${ORIG_BASENAME}/${NEW_VM_NAME}/g" "${NEW_VMX_FILE}";
        sed -i "s/^displayName = .*/displayName = \"${NEW_VM_NAME}\"/" "${NEW_VMX_FILE}";
        sed -i '/extendedConfigFile/d' "${NEW_VMX_FILE}"; sed -i '/vmxstats.filename/d' "${NEW_VMX_FILE}"; sed -i '/migrate.hostLog/d' "${NEW_VMX_FILE}";
        sed -i 's/-[0-9]\{6\}\.vmdk/\.vmdk/g' "${NEW_VMX_FILE}"; sed -i 's|\(fileName = "\)/.*/\(.*\.vmdk"\)|\1\2|g' "${NEW_VMX_FILE}";
        sed -i '/sched.swap.derivedName/d' "${NEW_VMX_FILE}"; sed -i '/uuid.location/d' "${NEW_VMX_FILE}"; sed -i '/uuid.bios/d' "${NEW_VMX_FILE}"; sed -i '/vc.uuid/d' "${NEW_VMX_FILE}";
        
        # --- HIER IST DIE KORREKTUR ---
        sed -i '/^uuid\.action/d' "${NEW_VMX_FILE}"; # Entferne alte Einträge
        echo "uuid.action = \"${UUID_ACTION}\"" >> "${NEW_VMX_FILE}"; # Füge neuen Eintrag hinzu
    )

    log "[7/7] Registriere Klon & entferne Snapshot...";
    REGISTER_OUTPUT=$(/bin/vim-cmd solo/registervm "${TARGET_VM_PATH}/${NEW_VM_NAME}.vmx" 2>&1); REGISTER_CODE=$?
    if [ ${REGISTER_CODE} -ne 0 ]; then
        log_error "FEHLER: VM '${NEW_VM_NAME}' konnte nicht registriert werden."; log_error "Meldung: ${REGISTER_OUTPUT}"; OVERALL_STATUS="ERROR";
    else
        NEW_VMID_CLONE=$(echo "${REGISTER_OUTPUT}"); log "  -> Klon registriert als VMID: ${NEW_VMID_CLONE}";
        if [ "${POWER_ON}" = "1" ]; then
            log "Warte 5 Sekunden..."; sleep 5; log "Schalte geklonte VM ein...";
            POWERON_OUTPUT=$(/bin/vim-cmd vmsvc/power.on "${NEW_VMID_CLONE}" 2>&1); POWERON_CODE=$?;
            if [ ${POWERON_CODE} -ne 0 ]; then
                log_error "FEHLER: VM '${NEW_VM_NAME}' konnte nicht eingeschaltet werden."; log_error "Meldung: ${POWERON_OUTPUT}"; OVERALL_STATUS="ERROR";
            fi
        fi
    fi
    log "  -> Entferne Snapshot von ${SOURCE_VM_NAME}...";
    /bin/vim-cmd vmsvc/snapshot.removeall ${VMID} >/dev/null 2>&1 || log_error "Befehl zum Entfernen des Snapshots fehlgeschlagen.";
    
    # NEUE WARTESCHLEIFE
    log "  -> Warte auf Abschluss der Snapshot-Konsolidierung...";
    MAX_SNAPSHOT_WAIT_SECONDS=1800; WAIT_INTERVAL=15; SECONDS_WAITED=0;
    while [ $SECONDS_WAITED -lt $MAX_SNAPSHOT_WAIT_SECONDS ]; do
        SNAPSHOT_COUNT=$(/bin/vim-cmd vmsvc/snapshot.get ${VMID} | wc -l);
        if [ ${SNAPSHOT_COUNT} -le 1 ]; then
            log "  -> Snapshot-Konsolidierung für ${SOURCE_VM_NAME} erfolgreich abgeschlossen.";
            break;
        fi;
        log "  -> Konsolidierung läuft noch... warte ${WAIT_INTERVAL}s...";
        sleep ${WAIT_INTERVAL}; SECONDS_WAITED=$((SECONDS_WAITED + WAIT_INTERVAL));
    done;
    if [ $SECONDS_WAITED -ge $MAX_SNAPSHOT_WAIT_SECONDS ]; then
        log_error "FEHLER: Timeout beim Warten auf Snapshot-Konsolidierung für ${SOURCE_VM_NAME}."; OVERALL_STATUS="ERROR";
    fi;

    VM_SIZE=$(du -sh "${TARGET_VM_PATH}" | awk '{print $1}');
    VM_REPORT_LIST=$(printf "%s- %s -> %s (%s)\n" "${VM_REPORT_LIST}" "${SOURCE_VM_NAME}" "${NEW_VM_NAME}" "${VM_SIZE}")
done

# --- Ende der Schleife ---
trap - EXIT
END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S'); log_raw "Endzeit: ${END_TIME_S}";
END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden"
log_raw "Speicherplatz (Nachher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h "${TARGET_DATASTORE}" 2>/dev/null | grep /vmfs/)"
send_email_notification "${DURATION_STRING}";
log "====== MULTI-VM KLON-PROZESS BEENDET (ID: ${UNIQUE_ID}) ======";
'@

# ------------------------ ENDE MULTIVM MULTIVMDK Hot Klone ----------------------

# --- NEU: Shell-Skript-Vorlage für den HEISS-KLON (V7.5.0 - Konfigurierbar) ---

# --- NEU: Shell-Skript-Vorlage für den HEISS-KLON (V7.5.1 - VMDK Name Fix) ---

$cloneScriptTemplate = @'
#!/bin/sh
# GhettoGUI Single-VM Clone Helper V50.3 (Final VMDK Name Fix)
# - FIX: VMDK files are now renamed directly during vmkfstools to prevent naming errors
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin
export PATH

# Parameter
SOURCE_VM_NAME='__SOURCE_VM_NAME__'; TARGET_DATASTORE='__TARGET_DATASTORE__'; NEW_VM_NAME='__NEW_VM_NAME__'; POWER_ON='__POWER_ON__'; UUID_ACTION='__UUID_ACTION__'; DISK_FORMAT='__DISK_FORMAT__'; SNAP_QUIESCE='__SNAP_QUIESCE__'; UNIQUE_ID='__UNIQUE_ID__'; GHETTO_PATH='__GHETTO_PATH__';
LOG_FILE="${GHETTO_PATH}/logs/clone_${UNIQUE_ID}.log"; EMAIL_ENABLED=__EMAIL_ENABLED__; EMAIL_TO='__EMAIL_TO__'; EMAIL_FROM='__EMAIL_FROM__'; EMAIL_DISPLAY_NAME='__EMAIL_DISPLAY_NAME__'; EMAIL_SERVER='__EMAIL_SERVER__'; EMAIL_PORT='__EMAIL_PORT__'; EMAIL_USER='__EMAIL_USER__'; EMAIL_PASS='__EMAIL_PASS__'; EMAIL_SUBJECT='__EMAIL_SUBJECT__'; SENDMAIL_PATH="${GHETTO_PATH}/sendmail"; OVERALL_STATUS="OK";
SNAPSHOT_NAME="ghetto-clone-${UNIQUE_ID}"; VMID="";

# --- Logging und E-Mail Funktionen ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- INFO: $1" >> ${LOG_FILE}; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; }
log_raw() { echo "$1" >> ${LOG_FILE}; }
log_warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARN: $1" >> ${LOG_FILE}; }
send_email_notification() {
    DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi;
    FINAL_SIZE=$(du -sh "${TARGET_VM_PATH}" 2>/dev/null | awk '{print $1}')
    VM_REPORT_LIST=$(printf -- "- %s: %s\n" "${NEW_VM_NAME}" "${FINAL_SIZE}")

    log_raw "\n--- Zusammenfassung der geklonten VMs ---"
    log_raw "${VM_REPORT_LIST}"
    log_raw "-----------------------------------------"
    log_raw "Final size: ${FINAL_SIZE:-N/A}"

    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: Klonen ERFOLGREICH! ##"; else FINAL_STATUS_MSG="## Final status: FEHLER: Klonen fehlgeschlagen! ##"; fi;
    log "Bereite E-Mail vor: ${OVERALL_STATUS}"; log_raw "Backup Duration: ${DURATION_MSG}"; log_raw "${FINAL_STATUS_MSG}";
    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/,/ /g');
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -N "${EMAIL_DISPLAY_NAME}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1;
    fi;
}

# --- Skriptstart ---
START_TIME=$(date +%s)
trap 'log_error "Unerwarteter, fataler Fehler."; exit 1' EXIT
mkdir -p "${GHETTO_PATH}/logs"; : > ${LOG_FILE}

# Ersetze den Wildcard '*' im Zielnamen durch den Quell-VM-Namen.
NEW_VM_NAME=$(echo "${NEW_VM_NAME}" | sed "s/\*/${SOURCE_VM_NAME}/g")

log "====== VM KLON-PROZESS GESTARTET (ID: ${UNIQUE_ID}) ======"
log_raw "Startzeit: $(date '+%Y-%m-%d %H:%M:%S')"
log_raw "Job-Konfiguration:"; log_raw "  - Typ: Lokaler Hot-Klon V8.4.4"; log_raw "  - Quelle: ${SOURCE_VM_NAME}"; log_raw "--- START DES DETAILLOGS ---"

VM_INFO_LINE=$(vim-cmd vmsvc/getallvms | grep -v 'invalid' | awk -v name="${SOURCE_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $0; }')
if [ -z "${VM_INFO_LINE}" ]; then log_error "Quell-VM '${SOURCE_VM_NAME}' nicht gefunden!"; OVERALL_STATUS="ERROR"; fi
VMID=$(echo "${VM_INFO_LINE}" | awk '{print $1}'); VMX_FULL_PATH=$(echo "${VM_INFO_LINE}" | awk '{ for(i=1; i<=NF; i++) { if ($i ~ /\.vmx$/) { gsub(/\[|\]/,"",$(i-1)); print "/vmfs/volumes/"$(i-1)"/"$i } } }'); VMX_DIR=$(dirname "${VMX_FULL_PATH}")

# --- START: VERBESSERTE BEREINIGUNG ---
log "[1/7] Bereinige eventuell existierenden alten Klon..."
OLD_VMID=$(/bin/vim-cmd vmsvc/getallvms | awk -v name="${NEW_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $1; }')
if [ -n "${OLD_VMID}" ]; then
    log "  -> Alter Klon '${NEW_VM_NAME}' mit VMID ${OLD_VMID} gefunden. Wird entfernt..."
    /bin/vim-cmd vmsvc/power.off ${OLD_VMID} >/dev/null 2>&1 || true
    sleep 2
    /bin/vim-cmd vmsvc/unregister ${OLD_VMID} >/dev/null 2>&1
    log "  -> Alter Klon wurde deregistriert."
fi
# --- ENDE: VERBESSERTE BEREINIGUNG ---

if [ "${OVERALL_STATUS}" = "OK" ]; then
    TARGET_VM_PATH="${TARGET_DATASTORE}/${NEW_VM_NAME}"; log "[2/7] Erstelle Zielverzeichnis..."; rm -rf "${TARGET_VM_PATH}"; mkdir -p "${TARGET_VM_PATH}";
    log "[3/7] Erstelle Snapshot..."; vim-cmd vmsvc/snapshot.create ${VMID} "${SNAPSHOT_NAME}" "GhettoGUI Live Clone" 0 ${SNAP_QUIESCE}; log "  -> Warte 15s..."; sleep 15;
    log "[4/7] Klone BASIS-Festplatten...";
    DISK_DEFS_ORIG=$(grep -iE '(\.vmdk)' "${VMX_FULL_PATH}" | grep -iE '(^scsi|^ide|^sata|^nvme)'); CLONE_ERROR=0;
    OLD_IFS=$IFS; IFS='
'; for line in ${DISK_DEFS_ORIG}; do
        IFS=$OLD_IFS; DISK_FILE_NAME=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p' | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/'); if [ -z "${DISK_FILE_NAME}" ]; then continue; fi;
        if echo "${DISK_FILE_NAME}" | grep -q "^/"; then SOURCE_DISK_PATH="${DISK_FILE_NAME}"; else SOURCE_DISK_PATH="${VMX_DIR}/${DISK_FILE_NAME}"; fi;
        
        # --- FIX: Dateiname beim Klonen direkt umbenennen ---
        DEST_DISK_BASENAME=$(basename "${DISK_FILE_NAME}" | sed "s/${SOURCE_VM_NAME}/${NEW_VM_NAME}/g");
        DESTINATION_DISK_PATH="${TARGET_VM_PATH}/${DEST_DISK_BASENAME}";
        
        log "  -> Klone Festplatte: ${DEST_DISK_BASENAME}"; vmkfstools -i "${SOURCE_DISK_PATH}" -d ${DISK_FORMAT} "${DESTINATION_DISK_PATH}" >> ${LOG_FILE} 2>&1;
        if [ $? -ne 0 ]; then log_error "Klonen von ${DEST_DISK_BASENAME} fehlgeschlagen!"; CLONE_ERROR=1; break; fi;
    done; IFS=$OLD_IFS;
    if [ ${CLONE_ERROR} -eq 1 ]; then log_error "Abbruch wegen Klon-Fehler."; OVERALL_STATUS="ERROR"; fi
fi

if [ "${OVERALL_STATUS}" = "OK" ]; then
    log "[5/7] Kopiere essentielle Konfigurationsdateien..."; (cd "${VMX_DIR}" && find . -maxdepth 1 \( -name "*.vmx" -o -name "*.nvram" \) -exec cp -p '{}' "${TARGET_VM_PATH}/" \;)
    log "[6/7] Passe Konfigurationsdateien an...";
    (
        cd "${TARGET_VM_PATH}"; ORIG_VMX_FILE=$(find . -maxdepth 1 -name "*.vmx"); ORIG_BASENAME=$(basename "${ORIG_VMX_FILE}" .vmx);
        for f in "${ORIG_BASENAME}"*; do
            new_name=$(echo "$f" | sed "s/^${ORIG_BASENAME}/${NEW_VM_NAME}/");
            if [ "$f" != "$new_name" ]; then mv -- "$f" "$new_name"; fi
        done;
        NEW_VMX_FILE="./${NEW_VM_NAME}.vmx";
        for vmdk_file in "${NEW_VM_NAME}"*.vmdk; do
            if ! echo "${vmdk_file}" | grep -q -- "-flat.vmdk"; then sed -i "s/${ORIG_BASENAME}/${NEW_VM_NAME}/g" "${vmdk_file}"; fi
        done;
        sed -i "s/${ORIG_BASENAME}/${NEW_VM_NAME}/g" "${NEW_VMX_FILE}";
        sed -i "s/^displayName = .*/displayName = \"${NEW_VM_NAME}\"/" "${NEW_VMX_FILE}";
        sed -i '/extendedConfigFile/d' "${NEW_VMX_FILE}"; sed -i '/vmxstats.filename/d' "${NEW_VMX_FILE}"; sed -i '/migrate.hostLog/d' "${NEW_VMX_FILE}";
        sed -i 's/-[0-9]\{6\}\.vmdk/\.vmdk/g' "${NEW_VMX_FILE}"; sed -i 's|\(fileName = "\)/.*/\(.*\.vmdk"\)|\1\2|g' "${NEW_VMX_FILE}";
        sed -i '/sched.swap.derivedName/d' "${NEW_VMX_FILE}"; sed -i '/uuid.location/d' "${NEW_VMX_FILE}"; sed -i '/uuid.bios/d' "${NEW_VMX_FILE}"; sed -i '/vc.uuid/d' "${NEW_VMX_FILE}";

        sed -i '/^uuid\.action/d' "${NEW_VMX_FILE}"; # Entferne alte Einträge
        echo "uuid.action = \"${UUID_ACTION}\"" >> "${NEW_VMX_FILE}";
    )
    
    log "[7/7] Registriere Klon...";
    REGISTER_OUTPUT=$(/bin/vim-cmd solo/registervm "${TARGET_VM_PATH}/${NEW_VM_NAME}.vmx" 2>&1); REGISTER_CODE=$?;
    if [ ${REGISTER_CODE} -ne 0 ]; then
        log_error "FEHLER: VM '${NEW_VM_NAME}' konnte nicht registriert werden."; log_error "Meldung: ${REGISTER_OUTPUT}"; OVERALL_STATUS="ERROR";
    else
        NEW_VMID_CLONE=$(echo "${REGISTER_OUTPUT}"); log "  -> Klon registriert als VMID: ${NEW_VMID_CLONE}";
        if [ "${POWER_ON}" = "1" ]; then
            log "Warte 5 Sekunden..."; sleep 5; log "Schalte geklonte VM ein...";
            POWERON_OUTPUT=$(/bin/vim-cmd vmsvc/power.on "${NEW_VMID_CLONE}" 2>&1); POWERON_CODE=$?;
            if [ ${POWERON_CODE} -ne 0 ]; then
                log_error "FEHLER: VM '${NEW_VM_NAME}' konnte nicht eingeschaltet werden."; log_error "Meldung: ${POWERON_OUTPUT}"; OVERALL_STATUS="ERROR";
            fi
        fi
    fi
fi

log "  -> Entferne Snapshot von ${SOURCE_VM_NAME}..."; /bin/vim-cmd vmsvc/snapshot.removeall ${VMID} >/dev/null 2>&1 || log_error "Snapshot konnte nicht entfernt werden.";

# --- Ende ---
trap - EXIT
END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S'); log_raw "Endzeit: ${END_TIME_S}";
END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden"
log_raw "Speicherplatz (Nachher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h "${TARGET_DATASTORE}" 2>/dev/null | grep /vmfs/)"
send_email_notification "${DURATION_STRING}";
log "====== VM KLON-PROZESS BEENDET (ID: ${UNIQUE_ID}) ======";
'@
# --- FINALE Shell-Skript-Vorlage für den LOKALEN HOT-KLON (V1.8 - Final) ---
# -- Multi VMDK Fix

$localReplicationScriptTemplate = @'
#!/bin/sh
# GhettoGUI Multi-VM Local Hot-Clone Helper V4.3.1 (VMX Path Fix)
# - FIX: Normalizes VMDK paths in the destination VMX file to be relative.
# - FIX: Handles absolute and relative paths for VMDKs on different datastores.
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin
export PATH
set -e
# Parameter
UNIQUE_ID='__UNIQUE_ID__'; TARGET_DATASTORE='__TARGET_DATASTORE__'; VM_SUFFIX='__VM_SUFFIX__'; GHETTO_PATH='__GHETTO_PATH__'; LOG_FILE="${GHETTO_PATH}/logs/local_clone_${UNIQUE_ID}.log"; SNAP_MEM=__SNAP_MEM__; SNAP_QUIESCE=__SNAP_QUIESCE__; EMAIL_ENABLED=__EMAIL_ENABLED__; EMAIL_TO='__EMAIL_TO__'; EMAIL_FROM='__EMAIL_FROM__'; EMAIL_DISPLAY_NAME='__EMAIL_DISPLAY_NAME__'; EMAIL_SERVER='__EMAIL_SERVER__'; EMAIL_PORT='__EMAIL_PORT__'; EMAIL_USER='__EMAIL_USER__'; EMAIL_PASS='__EMAIL_PASS__'; EMAIL_SUBJECT='__EMAIL_SUBJECT__'; SENDMAIL_PATH="${GHETTO_PATH}/sendmail"; VM_LIST='
__VM_LIST__
'; UUID_ACTION='__UUID_ACTION__'; OVERALL_STATUS="OK";

# --- Logging & E-Mail Funktionen ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -> $1" >> ${LOG_FILE}; }
log_raw() { echo "$1" >> ${LOG_FILE}; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; }
log_warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARN: $1" >> ${LOG_FILE}; }

send_email_notification() { 
    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: Lokaler Klon OK! ##"; else FINAL_STATUS_MSG="## Final status: FEHLER: Klonen fehlgeschlagen! ##"; fi; 
    log "Bereite E-Mail vor: ${OVERALL_STATUS}"; 
    log_raw "${FINAL_STATUS_MSG}"; 
    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then 
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/,/ /g'); 
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -N "${EMAIL_DISPLAY_NAME}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1; 
    fi; 
}

finish_job() {
    log "Alle Klone erfolgreich abgeschlossen. Erstelle Abschlussbericht..."
    END_TIME=$(date +%s); 
    END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S'); 
    DURATION=$((END_TIME - START_TIME)); 
    MINUTES=$((DURATION / 60)); 
    SECONDS=$((DURATION % 60)); 
    DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden";
    FINAL_SIZE=$(du -sh "${TARGET_DATASTORE}"/*"${VM_SUFFIX}" 2>/dev/null | tail -n 1 | awk '{print $1}') || FINAL_SIZE="N/A"

    log_raw "Endzeit: ${END_TIME_S}"
    log_raw "Backup Duration: ${DURATION_STRING}"
    log_raw "Final size: ${FINAL_SIZE:-N/A}"
    log_raw "Speicherplatz (Nachher):"
    log_raw "$(df -h "${TARGET_DATASTORE}" 2>/dev/null | tail -n 1)"
    log_raw ""
    log_raw "--- ENDE DES DETAILLOGS ---";
    
    send_email_notification; 
    log "====== LOKALER HOT-KLON PROZESS BEENDET (ID: ${UNIQUE_ID}) ======";
    exit 0
}

error_cleanup() { 
    trap - EXIT
    OVERALL_STATUS="ERROR"
    log_warn "Unerwarteter Fehler oder Abbruch. Führe Notfall-Cleanup durch."
    if [ -n "${VMID_LATEST}" ]; then 
        SNAPSHOT_EXISTS=$(/bin/vim-cmd vmsvc/snapshot.get ${VMID_LATEST} 2>/dev/null | grep "ghetto-localclone-${UNIQUE_ID}"); 
        if [ -n "${SNAPSHOT_EXISTS}" ]; then 
            log "Bereinige Snapshot auf der letzten VM ${VM_NAME_LATEST} (VMID ${VMID_LATEST})..."; 
            /bin/vim-cmd vmsvc/snapshot.removeall ${VMID_LATEST} >/dev/null 2>&1 || true; 
        fi; 
    fi; 
    send_email_notification; 
    log "====== LOKALER HOT-KLON PROZESS BEENDET (ID: ${UNIQUE_ID}) ======";
}

# --- Skriptstart ---
rm -f ${LOG_FILE}; mkdir -p "${GHETTO_PATH}/logs"; START_TIME=$(date +%s)
mkdir -p "${GHETTO_PATH}/logs"; rm -f ${LOG_FILE}
START_TIME=$(date +%s); START_TIME_S=$(date '+%Y-%m-%d %H:%M:%S'); trap error_cleanup EXIT

OVERALL_STATUS="OK"
log "====== LOKALER HOT-KLON PROZESS GESTARTET (ID: ${UNIQUE_ID}) ======"
log_raw "Job-Konfiguration:"; 
log_raw "Startzeit: ${START_TIME_S}"
log_raw "Speicherplatz (Vorher):"; log_raw "$(df -h "${TARGET_DATASTORE}" 2>/dev/null | tail -n 1)"
log_raw "--- START DES DETAILLOGS ---"; 

VMID_LATEST=""
VM_NAME_LATEST=""

for SOURCE_VM_NAME in ${VM_LIST}; do
    VM_NAME_LATEST="${SOURCE_VM_NAME}"
    log "#################### Starte Klon für VM: ${SOURCE_VM_NAME} ####################"
    log "initiate backup for ${SOURCE_VM_NAME}"
    CLONED_VM_NAME="${SOURCE_VM_NAME}${VM_SUFFIX}"; TARGET_VM_PATH="${TARGET_DATASTORE}/${CLONED_VM_NAME}"
    VM_INFO_LINE=$(vim-cmd vmsvc/getallvms | awk -v name="${SOURCE_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $0; }'); if [ -z "${VM_INFO_LINE}" ]; then log_error "[${SOURCE_VM_NAME}] - VM nicht gefunden!"; OVERALL_STATUS="ERROR"; continue; fi
    VMID=$(echo "${VM_INFO_LINE}" | awk '{print $1}'); VMX_FULL_PATH=$(echo "${VM_INFO_LINE}" | sed -e 's/.*\[\(.*\)\]\s*\(.*\.vmx\).*/\/vmfs\/volumes\/\1\/\2/'); VMX_DIR=$(dirname "${VMX_FULL_PATH}")
    VMID_LATEST="${VMID}"

    log "[0/5] Prüfe Speicherplatz auf dem Zieldatastore..."
    SOURCE_SIZE_K=$(du -sk "${VMX_DIR}" | awk '{print $1}')
    TARGET_STATS=$(stat -f -c "%a %S" "${TARGET_DATASTORE}" 2>/dev/null)
    FREE_BLOCKS=$(echo $TARGET_STATS | awk '{print $1}')
    BLOCK_SIZE=$(echo $TARGET_STATS | awk '{print $2}')
    TARGET_FREE_B=$((FREE_BLOCKS * BLOCK_SIZE))
    TARGET_FREE_K=$((TARGET_FREE_B / 1024))
    REQUIRED_K=$((SOURCE_SIZE_K * 110 / 100))
    log "  -> Benötigter Platz (VM-Grösse + 10% Puffer): ~$(echo ${REQUIRED_K} | awk '{ a=$1/1024/1024; printf "%.1f",a }') GB"
    log "  -> Verfügbarer Platz auf Zieldatastore: ~$(echo ${TARGET_FREE_K} | awk '{ a=$1/1024/1024; printf "%.1f",a }') GB"
    if [ "${TARGET_FREE_K}" -lt "${REQUIRED_K}" ]; then
        log_error "Nicht genügend Speicherplatz auf dem Zieldatastore '${TARGET_DATASTORE}'!"
        log_error "Breche Klon für '${SOURCE_VM_NAME}' ab und überspringe diese VM."
        OVERALL_STATUS="ERROR"
        continue
    fi
    log "  -> Genügend Speicherplatz vorhanden. Fahre fort."

    log "[1/5] Bereinige alten Klon..."; OLD_VMID=$(vim-cmd vmsvc/getallvms | awk -v name="${CLONED_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $1; }'); if [ -n "${OLD_VMID}" ]; then vim-cmd vmsvc/power.off ${OLD_VMID} >/dev/null 2>&1 || true; sleep 2; vim-cmd vmsvc/unregister ${OLD_VMID} >/dev/null 2>&1; fi; rm -rf "${TARGET_VM_PATH}"
    log "[2/5] Erstelle Snapshot..."; vim-cmd vmsvc/snapshot.create ${VMID} "ghetto-localclone-${UNIQUE_ID}" "GhettoGUI Local Clone" ${SNAP_MEM} ${SNAP_QUIESCE}; log "-> Warte 10s..."; sleep 10
    log "[3/5] Starte Klon der Festplatten..."; mkdir -p "${TARGET_VM_PATH}"; SOURCE_SIZE=$(du -sh "${VMX_DIR}" | awk '{print $1}'); DISK_DEFINITIONS=$(grep -iE '(\.vmdk)' "${VMX_FULL_PATH}" | grep -iE '(^scsi|^ide|^sata|^nvme)'); 
    echo "${DISK_DEFINITIONS}" | while read -r line; do 
        BASE_DISK_FILE=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p' | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/');
        if echo "${BASE_DISK_FILE}" | grep -q "^/"; then
            SOURCE_DISK_PATH="${BASE_DISK_FILE}"
        else
            SOURCE_DISK_PATH="${VMX_DIR}/${BASE_DISK_FILE}"
        fi
        DESTINATION_DISK_BASENAME=$(basename "${BASE_DISK_FILE}")
        DESTINATION_DISK_PATH="${TARGET_VM_PATH}/${DESTINATION_DISK_BASENAME}"; 
        log "  -> Klone Festplatte: ${DESTINATION_DISK_BASENAME}..."; 
        vmkfstools -i "${SOURCE_DISK_PATH}" -d thin "${DESTINATION_DISK_PATH}" > /dev/null 2>&1 & VMKF_PID=$!; 
        while kill -0 ${VMKF_PID} >/dev/null 2>&1; do 
            CURRENT_SIZE=$(du -sh "${TARGET_VM_PATH}" | awk '{print $1}'); 
            log " -> Fortschritt: ${CURRENT_SIZE} von ~${SOURCE_SIZE}"; 
            sleep 15; 
        done; 
        wait ${VMKF_PID}; 
        log "  -> Klon von ${DESTINATION_DISK_BASENAME} abgeschlossen."; 
    done
    
    log "[4/5] Kopiere & passe Konfigurationsdateien an..."; 
    (cd "${VMX_DIR}" && find . -maxdepth 1 \( -name "*.vmx" -o -name "*.nvram" -o -name "*.vmsd" \) -exec cp -p '{}' "${TARGET_VM_PATH}/" \;)

    cd "${TARGET_VM_PATH}"; ORIG_VMX_FILE=$(find . -maxdepth 1 -name "*.vmx"); RENAMED_VMX_FILE="./${CLONED_VM_NAME}.vmx"; mv "${ORIG_VMX_FILE}" "${RENAMED_VMX_FILE}";
    log "  -> Passe VMX-Inhalt an (Aktion: ${UUID_ACTION})..."; 
    sed -i "s/displayName = .*/displayName = \"${CLONED_VM_NAME}\"/" "${RENAMED_VMX_FILE}"; 
    sed -i 's/-[0-9]\{6\}\.vmdk/\.vmdk/g' "${RENAMED_VMX_FILE}"; 
    # ### NEUE KORREKTUR: Absolute Pfade für VMDKs entfernen ###
    sed -i 's|\(fileName = "\)/.*/\(.*\.vmdk"\)|\1\2|g' "${RENAMED_VMX_FILE}";
    sed -i "/sched\.swap\.derivedName/d" "${RENAMED_VMX_FILE}"; 
    if [ "${UUID_ACTION}" = "create" ]; then 
        log "    -> Entferne UUIDs und MAC-Adresse für neue Identität."; 
        sed -i "/^uuid\./d" "${RENAMED_VMX_FILE}"; 
        sed -i "/^ethernet[0-9]*.generatedAddress/d" "${RENAMED_VMX_FILE}"; 
        sed -i "/^ethernet[0-9]*.addressType/d" "${RENAMED_VMX_FILE}"; 
    else 
        log "    -> Setze 'uuid.action = keep' zur Beibehaltung der Identität."; 
        sed -i "/^uuid\./d" "${RENAMED_VMX_FILE}"; 
        echo "uuid.action = \"keep\"" >> "${RENAMED_VMX_FILE}"; 
    fi
    log "[5/5] Registriere Klon & entferne Snapshot..."; vim-cmd solo/registervm "${TARGET_VM_PATH}/${RENAMED_VMX_FILE}"; vim-cmd vmsvc/snapshot.removeall ${VMID}; log "-> Klon für ${SOURCE_VM_NAME} erfolgreich abgeschlossen."
    log "initiate backup for ${CLONED_VM_NAME}"
done

if [ "${OVERALL_STATUS}" = "OK" ]; then
    finish_job
fi
'@

# -------------------------------------------------------------------------------


# --- NEU: Shell-Skript-Vorlage für den GEPLANTEN HOT-KLON (Cron-Version) ---
# --- Fix: Multi VMDK Pfad

# --- NEU: Shell-Skript-Vorlage für den GEPLANTEN HOT-KLON (Cron-Version) ---
# --- Fix: Multi VMDK Pfad

$scheduledCloneScriptTemplate = @'
#!/bin/sh
# GhettoGUI Scheduled Clone Helper V2.0 (Logic Parity Update)
# - FINAL: Adopts the fully robust V4.0 renaming and patching logic from the manual multi-clone script. Ensures scheduled single clones are always created correctly.
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin
export PATH

# --- START: LOCK FILE MECHANISM ---
LOCK_DIR="/tmp/ghetto_job___UNIQUE_ID__.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    exit 0 # Exit silently if lock exists
fi
# Define a combined trap that runs the main cleanup/finish_job and then removes the lock.
# Note: This script uses finish_job on success, which has its own exit.
trap 'finish_job; rm -rf "${LOCK_DIR}";' EXIT HUP INT QUIT TERM
# --- END: LOCK FILE MECHANISM ---

# Parameter
SOURCE_VM_NAME='__SOURCE_VM_NAME__'; TARGET_DATASTORE='__TARGET_DATASTORE__'; NEW_VM_NAME='__NEW_VM_NAME__'; POWER_ON=__POWER_ON__; UUID_ACTION='__UUID_ACTION__'; DISK_FORMAT='__DISK_FORMAT__'; SNAP_QUIESCE='__SNAP_QUIESCE__'; UNIQUE_ID='__UNIQUE_ID__'; GHETTO_PATH='__GHETTO_PATH__'; EMAIL_ENABLED=__EMAIL_ENABLED__; EMAIL_TO='__EMAIL_TO__'; EMAIL_FROM='__EMAIL_FROM__'; EMAIL_DISPLAY_NAME='__EMAIL_DISPLAY_NAME__'; EMAIL_SERVER='__EMAIL_SERVER__'; EMAIL_PORT='__EMAIL_PORT__'; EMAIL_USER='__EMAIL_USER__'; EMAIL_PASS='__EMAIL_PASS__'; EMAIL_SUBJECT='__EMAIL_SUBJECT__'; SENDMAIL_PATH="${GHETTO_PATH}/sendmail"; OVERALL_STATUS="OK";
SNAPSHOT_NAME="ghetto-clone-${UNIQUE_ID}"; VMID=""

# Logging, send_email_notification und cleanup
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- INFO: $1" >> ${LOG_FILE}; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; }
log_raw() { echo "$1" >> ${LOG_FILE}; }
send_email_notification() { DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi; if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: Klonen ERFOLGREICH! ##"; else FINAL_STATUS_MSG="## Final status: FEHLER: Klonen fehlgeschlagen! ##"; fi; log "Bereite E-Mail vor: ${OVERALL_STATUS}"; log_raw "Backup Duration: ${DURATION_MSG}"; log_raw "${FINAL_STATUS_MSG}"; if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/,/ /g'); /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -N "${EMAIL_DISPLAY_NAME}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1; fi; }
cleanup() { EXIT_CODE=$?; trap - EXIT; if [ ${EXIT_CODE} -ne 0 ] && [ "${OVERALL_STATUS}" = "OK" ]; then OVERALL_STATUS="ERROR"; fi; log "Starte Cleanup-Routine..."; if [ -n "${VMID}" ]; then if vim-cmd vmsvc/snapshot.get ${VMID} 2>/dev/null | grep -q "${SNAPSHOT_NAME}"; then log "Entferne Snapshot '${SNAPSHOT_NAME}'..."; vim-cmd vmsvc/snapshot.removeall ${VMID} > /dev/null 2>&1 || true; fi; fi; FINAL_SIZE=$(du -sh "${TARGET_VM_PATH}" 2>/dev/null | awk '{print $1}'); log_raw "Final size: ${FINAL_SIZE:-N/A}"; log_raw "Speicherplatz (Nachher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h "${TARGET_DATASTORE}" 2>/dev/null | grep /vmfs/)"; log_raw "--- ENDE DES DETAILLOGS ---"; END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S'); log_raw "Endzeit: ${END_TIME_S}"; END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden"; send_email_notification "${DURATION_STRING}"; log "====== VM KLON-PROZESS BEENDET (ID: ${UNIQUE_ID}) ======"; exit 0; }

# --- Skriptstart ---
rm -f ${LOG_FILE}; mkdir -p "${GHETTO_PATH}/logs"; START_TIME=$(date +%s)
START_TIME=$(date +%s); trap cleanup EXIT; LOG_FILE="${GHETTO_PATH}/logs/clone_${UNIQUE_ID}.log"; rm -f ${LOG_FILE}
log "====== GEPLANTER VM KLON-PROZESS GESTARTET (ID: ${UNIQUE_ID}) ======"; log_raw "Startzeit: $(date '+%Y-%m-%d %H:%M:%S')"; log_raw "Job-Konfiguration:"; log_raw "  - Typ: Geplanter Lokaler Hot-Klon V8.4.4"; log_raw "  - Quelle: ${SOURCE_VM_NAME}"; log_raw "--- START DES DETAILLOGS ---"
VM_INFO_LINE=$(vim-cmd vmsvc/getallvms | grep -v 'invalid' | awk -v name="${SOURCE_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $0; }'); if [ -z "${VM_INFO_LINE}" ]; then log_error "Quell-VM '${SOURCE_VM_NAME}' nicht gefunden!"; exit 1; fi; VMID=$(echo "${VM_INFO_LINE}" | awk '{print $1}'); VMX_FULL_PATH=$(echo "${VM_INFO_LINE}" | awk '{ for(i=1; i<=NF; i++) { if ($i ~ /\.vmx$/) { gsub(/\[|\]/,"",$(i-1)); print "/vmfs/volumes/"$(i-1)"/"$i } } }'); VMX_DIR=$(dirname "${VMX_FULL_PATH}");

# --- START: VERBESSERTE BEREINIGUNG ---
log "[1/7] Bereinige eventuell existierenden alten Klon..."
OLD_VMID=$(/bin/vim-cmd vmsvc/getallvms | awk -v name="${NEW_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $1; }')
if [ -n "${OLD_VMID}" ]; then
    log "  -> Alter Klon '${NEW_VM_NAME}' mit VMID ${OLD_VMID} gefunden. Wird entfernt..."
    /bin/vim-cmd vmsvc/power.off ${OLD_VMID} >/dev/null 2>&1 || true
    sleep 2
    /bin/vim-cmd vmsvc/unregister ${OLD_VMID} >/dev/null 2>&1
    log "  -> Alter Klon wurde deregistriert."
fi
# --- ENDE: VERBESSERTE BEREINIGUNG ---

TARGET_VM_PATH="${TARGET_DATASTORE}/${NEW_VM_NAME}"; log "[2/7] Erstelle Zielverzeichnis..."; rm -rf "${TARGET_VM_PATH}"; mkdir -p "${TARGET_VM_PATH}";
log "[3/7] Erstelle Snapshot..."; vim-cmd vmsvc/snapshot.create ${VMID} "${SNAPSHOT_NAME}" "GhettoGUI Scheduled Clone" 0 ${SNAP_QUIESCE}; log "  -> Warte 15s..."; sleep 15;
log "[4/7] Klone BASIS-Festplatten...";
DISK_DEFS_ORIG=$(grep -iE '(\.vmdk)' "${VMX_FULL_PATH}" | grep -iE '(^scsi|^ide|^sata|^nvme)'); CLONE_ERROR=0;
OLD_IFS=$IFS; IFS='
'; for line in ${DISK_DEFS_ORIG}; do
    IFS=$OLD_IFS; DISK_FILE_NAME=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p' | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/'); if [ -z "${DISK_FILE_NAME}" ]; then continue; fi;
    if echo "${DISK_FILE_NAME}" | grep -q "^/"; then SOURCE_DISK_PATH="${DISK_FILE_NAME}"; else SOURCE_DISK_PATH="${VMX_DIR}/${DISK_FILE_NAME}"; fi;
    DEST_DISK_BASENAME=$(basename "${DISK_FILE_NAME}"); DEST_DISK_PATH="${TARGET_VM_PATH}/${DEST_DISK_BASENAME}";
    log "  -> Klone Festplatte: ${DEST_DISK_BASENAME}"; vmkfstools -i "${SOURCE_DISK_PATH}" -d ${DISK_FORMAT} "${DEST_DISK_PATH}" >> ${LOG_FILE} 2>&1;
    if [ $? -ne 0 ]; then log_error "Klonen von ${DEST_DISK_BASENAME} fehlgeschlagen!"; CLONE_ERROR=1; break; fi;
done; IFS=$OLD_IFS;
if [ ${CLONE_ERROR} -eq 1 ]; then log_error "Abbruch wegen Klon-Fehler."; exit 1; fi
log "[5/7] Kopiere Konfigurationsdateien..."; (cd "${VMX_DIR}" && find . -maxdepth 1 \( -name "*.vmx" -o -name "*.nvram" -o -name "*.vmsd" \) -exec cp -p '{}' "${TARGET_VM_PATH}/" \;)
log "[6/7] Passe Konfigurationsdateien an...";
(
    cd "${TARGET_VM_PATH}"; ORIG_VMX_FILE=$(find . -maxdepth 1 -name "*.vmx"); ORIG_BASENAME=$(basename "${ORIG_VMX_FILE}" .vmx);
    for f in "${ORIG_BASENAME}"*; do
        new_name=$(echo "$f" | sed "s/^${ORIG_BASENAME}/${NEW_VM_NAME}/");
        if [ "$f" != "$new_name" ]; then mv -- "$f" "$new_name"; fi
    done;
    NEW_VMX_FILE="./${NEW_VM_NAME}.vmx";
    for vmdk_file in "${NEW_VM_NAME}"*.vmdk; do
        if ! echo "${vmdk_file}" | grep -q -- "-flat.vmdk"; then sed -i "s/${ORIG_BASENAME}/${NEW_VM_NAME}/g" "${vmdk_file}"; fi
    done;
    sed -i "s/${ORIG_BASENAME}/${NEW_VM_NAME}/g" "${NEW_VMX_FILE}";
    sed -i "s/^displayName = .*/displayName = \"${NEW_VM_NAME}\"/" "${NEW_VMX_FILE}";
    sed -i '/extendedConfigFile/d' "${NEW_VMX_FILE}"; sed -i '/vmxstats.filename/d' "${NEW_VMX_FILE}"; sed -i '/migrate.hostLog/d' "${NEW_VMX_FILE}";
    sed -i 's/-[0-9]\{6\}\.vmdk/\.vmdk/g' "${NEW_VMX_FILE}"; sed -i 's|\(fileName = "\)/.*/\(.*\.vmdk"\)|\1\2|g' "${NEW_VMX_FILE}";
    sed -i '/sched.swap.derivedName/d' "${NEW_VMX_FILE}"; sed -i '/uuid.location/d' "${NEW_VMX_FILE}"; sed -i '/uuid.bios/d' "${NEW_VMX_FILE}"; sed -i '/vc.uuid/d' "${NEW_VMX_FILE}";
    
    # --- HIER IST DIE KORREKTUR ---
    sed -i '/^uuid\.action/d' "${NEW_VMX_FILE}"; # Entferne alte Einträge
    echo "uuid.action = \"${UUID_ACTION}\"" >> "${NEW_VMX_FILE}";
)
log "[7/7] Registriere Klon..."; NEW_VMID_CLONE=$(vim-cmd solo/registervm "${TARGET_VM_PATH}/${NEW_VM_NAME}.vmx"); log "  -> Klon registriert als VMID: ${NEW_VMID_CLONE}";
if [ "${POWER_ON}" = "1" ]; then log "Schalte geklonte VM ein..."; vim-cmd vmsvc/power.on "${NEW_VMID_CLONE}"; fi
OVERALL_STATUS="OK";
log "====== KLONEN ERFOLGREICH ABGESCHLOSSEN ======";
trap - EXIT; cleanup
'@

# --- Shell-Skript-Vorlage für den GEPLANTEN KALT-RESTORE (V1.4 - Final) ---

$scheduledRestoreScriptTemplate = @'
#!/bin/sh
# GhettoGUI Scheduled Restore Helper V1.5 (Final Email Report Fix by Gemini)
# - APPLIED: Golden Rules for Email Reporting (Total Size, VM List Format, Header Match)
# Parameter
SOURCE_PATH='__SOURCE_PATH__'
TARGET_DATASTORE='__TARGET_DATASTORE__'
NEW_VM_NAME='__NEW_VM_NAME__'
POWER_ON=__POWER_ON__
UUID_ACTION='__UUID_ACTION__'
UNIQUE_ID='__UNIQUE_ID__'
GHETTO_PATH='__GHETTO_PATH__'
EMAIL_ENABLED=__EMAIL_ENABLED__
EMAIL_TO='__EMAIL_TO__'
EMAIL_FROM='__EMAIL_FROM__'
EMAIL_DISPLAY_NAME='__EMAIL_DISPLAY_NAME__'
EMAIL_SERVER='__EMAIL_SERVER__'
EMAIL_PORT='__EMAIL_PORT__'
EMAIL_USER='__EMAIL_USER__'
EMAIL_PASS='__EMAIL_PASS__'
EMAIL_SUBJECT='__EMAIL_SUBJECT__'
SENDMAIL_PATH="${GHETTO_PATH}/sendmail"
OVERALL_STATUS="OK"

# --- START: LOCK FILE MECHANISM ---
LOCK_DIR="/tmp/ghetto_job___UNIQUE_ID__.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    exit 0 # Exit silently if lock exists
fi
# Define a combined trap that runs the main cleanup/finish_job and then removes the lock.
# Note: This script uses finish_job on success, which has its own exit.
trap 'finish_job; rm -rf "${LOCK_DIR}";' EXIT HUP INT QUIT TERM
# --- END: LOCK FILE MECHANISM ---

# Logging & Hilfsfunktionen
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- INFO: $1" >> ${LOG_FILE}; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; }
log_raw() { echo "$1" >> ${LOG_FILE}; }
send_email_notification() {
    DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi;
    FINAL_SIZE=$(du -sh "${TARGET_VM_PATH}" 2>/dev/null | awk '{print $1}')
    VM_REPORT_LIST=$(printf -- "- %s: %s\n" "${NEW_VM_NAME}" "${FINAL_SIZE}")

    log_raw "\n--- Zusammenfassung der geklonten VMs ---"
    log_raw "${VM_REPORT_LIST}"
    log_raw "-----------------------------------------"
    log_raw "Final size: ${FINAL_SIZE:-N/A}"

    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: Wiederherstellung ERFOLGREICH! ##"; else FINAL_STATUS_MSG="## Final status: FEHLER: Wiederherstellung fehlgeschlagen! ##"; fi;
    log "Bereite E-Mail vor: ${OVERALL_STATUS}"; log_raw "Backup Duration: ${DURATION_MSG}"; log_raw "${FINAL_STATUS_MSG}";
    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/,/ /g');
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -N "${EMAIL_DISPLAY_NAME}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1;
    fi;
}
cleanup() {
    EXIT_CODE=$?
    log_raw "Speicherplatz (Nachher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h "${TARGET_DATASTORE}" 2>/dev/null | grep /vmfs/)"
    log_raw "--- ENDE DES DETAILLOGS ---"; END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S'); log_raw "Endzeit: ${END_TIME_S}"; END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden";
    if [ ${EXIT_CODE} -ne 0 ] && [ "${OVERALL_STATUS}" = "OK" ]; then OVERALL_STATUS="ERROR"; fi;
    send_email_notification "${DURATION_STRING}";
    log "====== VM RESTORE-PROZESS BEENDET (ID: ${UNIQUE_ID}) ======";
}

# --- Skriptstart ---
rm -f ${LOG_FILE}; mkdir -p "${GHETTO_PATH}/logs"; START_TIME=$(date +%s)
START_TIME=$(date +%s); trap cleanup EXIT; LOG_FILE="${GHETTO_PATH}/logs/restore_${UNIQUE_ID}.log"; rm -f ${LOG_FILE}
log "====== GEPLANTER VM RESTORE-PROZESS GESTARTET (ID: ${UNIQUE_ID}) ======"
log_raw "Startzeit: $(date '+%Y-%m-%d %H:%M:%S')"
log_raw "Job-Konfiguration:"; log_raw "  - Typ: Geplante GhettoVCB Wiederherstellung V8.4.4"; log_raw "  - Quelle: ${SOURCE_PATH}"; log_raw "  - Ziel-Datastore: ${TARGET_DATASTORE}"; log_raw "  - Neuer VM-Name: ${NEW_VM_NAME}"; log_raw "  - UUID-Aktion: ${UUID_ACTION}"; log_raw "Speicherplatz (Vorher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h "${TARGET_DATASTORE}" 2>/dev/null | grep /vmfs/)"; log_raw "--- START DES DETAILLOGS ---"
TARGET_VM_PATH="${TARGET_DATASTORE}/${NEW_VM_NAME}"; log "[1/5] Erstelle Zielverzeichnis: ${TARGET_VM_PATH}"; rm -rf "${TARGET_VM_PATH}"; mkdir -p "${TARGET_VM_PATH}";
ACTUAL_SOURCE_PATH="${SOURCE_PATH}"; if [ "$(find "${SOURCE_PATH}" -maxdepth 1 -mindepth 1 -type d | wc -l)" -eq 1 ]; then ACTUAL_SOURCE_PATH=$(find "${SOURCE_PATH}" -maxdepth 1 -mindepth 1 -type d); fi
log "[2/5] Kopiere Backup-Daten von '${ACTUAL_SOURCE_PATH}'..."; cp -r "${ACTUAL_SOURCE_PATH}/." "${TARGET_VM_PATH}/"; log "  -> Kopiervorgang abgeschlossen.";
log "[3/5] Passe Konfigurationsdateien an..."; cd "${TARGET_VM_PATH}"; ORIG_VMX_FILE=$(find . -maxdepth 1 -name "*.vmx"); ORIG_BASENAME=$(basename "${ORIG_VMX_FILE}" .vmx); for f in "${ORIG_BASENAME}".*; do new_name=$(echo "$f" | sed "s/^${ORIG_BASENAME}/${NEW_VM_NAME}/"); mv -- "$f" "$new_name"; done; NEW_VMX_FILE="./${NEW_VM_NAME}.vmx"; sed -i "s/displayName = .*/displayName = \"${NEW_VM_NAME}\"/" "${NEW_VMX_FILE}"; sed -i "s/${ORIG_BASENAME}\.vmdk/${NEW_VM_NAME}\.vmdk/g" "${NEW_VMX_FILE}"; sed -i "s/${ORIG_BASENAME}\.nvram/${NEW_VM_NAME}\.nvram/g" "${NEW_VMX_FILE}"; echo "uuid.action = \"${UUID_ACTION}\"" >> "${NEW_VMX_FILE}";
log "[4/5] Registriere neue VM..."; NEW_VMID=$(vim-cmd solo/registervm "${TARGET_VM_PATH}/${NEW_VM_NAME}.vmx"); log "  -> VM erfolgreich registriert mit neuer VMID: ${NEW_VMID}";
if [ "${POWER_ON}" = "1" ]; then log "[5/5] Schalte wiederhergestellte VM ein..."; sleep 5; POWERON_OUTPUT=$(vim-cmd vmsvc/power.on "${NEW_VMID}" 2>&1); if [ $? -eq 0 ]; then log "  -> Einschalt-Befehl erfolgreich gesendet."; else log_error "FEHLER: Die VM konnte nicht eingeschaltet werden."; log_error "Host-Meldung: ${POWERON_OUTPUT}"; OVERALL_STATUS="ERROR"; fi; else log "[5/5] VM wird nicht automatisch eingeschaltet."; fi

if [ "${OVERALL_STATUS}" != "ERROR" ]; then
    OVERALL_STATUS="OK"
fi
log "====== WIEDERHERSTELLUNG ERFOLGREICH ABGESCHLOSSEN ======"
trap - EXIT; cleanup
'@
# =======================================================================
# --- NEU: Shell-Skript-Vorlage für den GEPLANTEN MULTI-VM HOT-KLON ---
# =======================================================================
# In GhettoGUI_V8.0.1.ps1

# ERSETZE den gesamten Block für $scheduledMultiCloneScriptTemplate (V43.9.20 - Finaler Klon-Fix)

$scheduledMultiCloneScriptTemplate = @'
#!/bin/sh
# GhettoGUI Scheduled Multi-VM Clone Helper V43.9.20 (Fix: Robuste Fehlererkennung)
# - FIX: Implementiert eine Fehler-Flag-Datei, um Subshell-Probleme zu umgehen und Fehler zu melden.
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin
export PATH

# --- START: LOCK FILE MECHANISM ---
LOCK_DIR="/tmp/ghetto_job___UNIQUE_ID__.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    exit 0 # Exit silently if lock exists
fi
trap 'cleanup; rm -rf "${LOCK_DIR}";' EXIT HUP INT QUIT TERM
# --- END: LOCK FILE MECHANISM ---

# Parameter
VM_LIST='
__VM_LIST__
'
NAME_TEMPLATE='__NAME_TEMPLATE__'; TARGET_DATASTORE='__TARGET_DATASTORE__'; POWER_ON='__POWER_ON__'; UUID_ACTION='__UUID_ACTION__'; DISK_FORMAT='__DISK_FORMAT__'; SNAP_QUIESCE='__SNAP_QUIESCE__'; UNIQUE_ID='__UNIQUE_ID__'; GHETTO_PATH='__GHETTO_PATH__';
LOG_FILE="${GHETTO_PATH}/logs/clone_${UNIQUE_ID}.log"; EMAIL_ENABLED=__EMAIL_ENABLED__; EMAIL_TO='__EMAIL_TO__'; EMAIL_FROM='__EMAIL_FROM__'; EMAIL_DISPLAY_NAME='__EMAIL_DISPLAY_NAME__'; EMAIL_SERVER='__EMAIL_SERVER__'; EMAIL_PORT='__EMAIL_PORT__'; EMAIL_USER='__EMAIL_USER__'; EMAIL_PASS='__EMAIL_PASS__'; EMAIL_SUBJECT='__EMAIL_SUBJECT__'; SENDMAIL_PATH="${GHETTO_PATH}/sendmail"; OVERALL_STATUS="OK";
VM_REPORT_LIST=""; TOTAL_SIZE_K=0;

# --- Logging und E-Mail Funktionen ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -> $1" >> ${LOG_FILE}; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; }
log_raw() { echo "$1" >> ${LOG_FILE}; }

send_email_notification() {
    DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi
    log_raw "\n--- Zusammenfassung der geklonten VMs ---"
    log_raw "${VM_REPORT_LIST}"
    log_raw "-----------------------------------------"
    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: Klonen ERFOLGREICH! ##"; else FINAL_STATUS_MSG="## Final status: FEHLER: Klonen teilweise oder komplett fehlgeschlagen! ##"; fi
    log "Bereite E-Mail vor: ${OVERALL_STATUS}"; log_raw "Backup Duration: ${DURATION_MSG}"; log_raw "${FINAL_STATUS_MSG}";
    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/[;,]/ /g');
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -N "${EMAIL_DISPLAY_NAME}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1;
    fi;
}

finish_job() {
    if [ -n "${TOTAL_SIZE_K}" ] && [ "${TOTAL_SIZE_K}" -gt 0 ]; then
        FINAL_SIZE=$(awk "BEGIN {printf \"%.1fG\", ${TOTAL_SIZE_K}/1024/1024}")
    else
        FINAL_SIZE="0" # KORRIGIERT: 0 anstatt N/A, wenn keine Größe summiert wurde
    fi
    log_raw "Final size: ${FINAL_SIZE}"
    
    log_raw "Speicherplatz (Nachher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h "${TARGET_DATASTORE}" 2>/dev/null | grep /vmfs/)"
    log_raw "--- ENDE DES DETAILLOGS ---"; END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S'); log_raw "Endzeit: ${END_TIME_S}"; END_TIME=$(date +%s);
    DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden"
    send_email_notification "${DURATION_STRING}";
    log "====== MULTI-VM KLON-PROZESS BEENDET (ID: ${UNIQUE_ID}) ======";
    exit 0
}

# --- Skriptstart ---
rm -f ${LOG_FILE}; mkdir -p "${GHETTO_PATH}/logs"; START_TIME=$(date +%s)
trap 'log_error "Unerwarteter, fataler Fehler. Notfall-Abbruch."; exit 1' EXIT

if [ ! -d "${GHETTO_PATH}/logs" ]; then mkdir -p "${GHETTO_PATH}/logs"; fi
rm -f ${LOG_FILE}

log "====== GEPLANTER MULTI-VM KLON-PROZESS GESTARTET (ID: ${UNIQUE_ID}) ======"
log_raw "Startzeit: $(date '+%Y-%m-%d %H:%M:%S')"
log_raw "Job-Konfiguration:"; log_raw "  - Typ: Geplanter Multi-VM Hot-Klon V8.4.4"; log_raw "  - Ziel-Datastore: ${TARGET_DATASTORE}"; log_raw "  - Namens-Vorlage: ${NAME_TEMPLATE}"; log_raw "Speicherplatz (Vorher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h "${TARGET_DATASTORE}" 2>/dev/null | grep /vmfs/)"; log_raw "--- START DES DETAILLOGS ---";

CLONE_ERROR_FLAG="/tmp/clone_err_flag_${UNIQUE_ID}.flag"
rm -f $CLONE_ERROR_FLAG

CLEAN_VM_LIST=$(echo "${VM_LIST}" | sed -e 's/\r//g' -e '/^$/d')
for SOURCE_VM_NAME in ${CLEAN_VM_LIST}; do
    log "#################### Starte Klon für VM: ${SOURCE_VM_NAME} ####################"
    log "initiate backup for ${SOURCE_VM_NAME}"

    NEW_VM_NAME=$(echo "${NAME_TEMPLATE}" | sed "s/\*/${SOURCE_VM_NAME}/g")
    log "  -> Generierter Ziel-Name: ${NEW_VM_NAME}"
    SNAPSHOT_NAME="ghetto-clone-${UNIQUE_ID}-$(echo ${SOURCE_VM_NAME} | sed 's/ //g')"
    VMID=""
    
    VM_INFO_LINE=$(/bin/vim-cmd vmsvc/getallvms | grep -v 'invalid' | awk -v name="${SOURCE_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $0; }')
    if [ -z "${VM_INFO_LINE}" ]; then log_error "Quell-VM '${SOURCE_VM_NAME}' nicht gefunden! Überspringe..."; OVERALL_STATUS="ERROR"; continue; fi
    VMID=$(echo "${VM_INFO_LINE}" | awk '{print $1}'); VMX_FULL_PATH=$(echo "${VM_INFO_LINE}" | awk '{ for(i=1; i<=NF; i++) { if ($i ~ /\.vmx$/) { gsub(/\[|\]/,"",$(i-1)); print "/vmfs/volumes/"$(i-1)"/"$i } } }'); VMX_DIR=$(dirname "${VMX_FULL_PATH}")

    TARGET_VM_PATH="${TARGET_DATASTORE}/${NEW_VM_NAME}"
	log "[1/7] Bereinige eventuell existierenden alten Klon..."
    OLD_VMID=$(/bin/vim-cmd vmsvc/getallvms | awk -v name="${NEW_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $1; }')
    if [ -n "${OLD_VMID}" ]; then
        log "  -> Alter Klon '${NEW_VM_NAME}' mit VMID ${OLD_VMID} gefunden. Wird entfernt..."
        /bin/vim-cmd vmsvc/power.off ${OLD_VMID} >/dev/null 2>&1 || true
        sleep 2
        /bin/vim-cmd vmsvc/unregister ${OLD_VMID} >/dev/null 2>&1
        log "  -> Alter Klon wurde deregistriert."
    fi
	
    log "[2/7] Erstelle Zielverzeichnis..."; rm -rf "${TARGET_VM_PATH}"; mkdir -p "${TARGET_VM_PATH}"
    log "[3/7] Erstelle Snapshot..."; /bin/vim-cmd vmsvc/snapshot.create ${VMID} "${SNAPSHOT_NAME}" "GhettoGUI Scheduled Clone" 0 ${SNAP_QUIESCE}; log "  -> Warte 15s..."; sleep 15

    log "[4/7] Klone BASIS-Festplatten...";
    DISK_DEFS_ORIG=$(grep -iE '(\.vmdk)' "${VMX_FULL_PATH}" | grep -iE '(^scsi|^ide|^sata|^nvme)'); CLONE_ERROR=0;
    OLD_IFS=$IFS; IFS='
'; for line in ${DISK_DEFS_ORIG}; do
        IFS=$OLD_IFS; # Setze IFS für Befehle zurück
        
        # Prüfe, ob Fehler-Flag schon existiert (durch vorherige Disk)
        if [ -f "$CLONE_ERROR_FLAG" ]; then break; fi
        
        DISK_FILE_NAME=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p' | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/');
        if [ -z "${DISK_FILE_NAME}" ]; then continue; fi;
        if echo "${DISK_FILE_NAME}" | grep -q "^/"; then SOURCE_DISK_PATH="${DISK_FILE_NAME}"; else SOURCE_DISK_PATH="${VMX_DIR}/${DISK_FILE_NAME}"; fi;
        DEST_DISK_BASENAME=$(basename "${DISK_FILE_NAME}"); DEST_DISK_PATH="${TARGET_VM_PATH}/${DEST_DISK_BASENAME}";
        
        log "  -> Klone Festplatte: ${DEST_DISK_BASENAME}"; vmkfstools -i "${SOURCE_DISK_PATH}" -d ${DISK_FORMAT} "${DEST_DISK_PATH}" >> ${LOG_FILE} 2>&1;
        
        if [ $? -ne 0 ]; then
            log_error "Klonen von ${DEST_DISK_BASENAME} fehlgeschlagen! (Exit Code: $?)"
            touch $CLONE_ERROR_FLAG # Fehler-Flag setzen
        fi
        
        IFS='
' # Setze IFS für den nächsten Schleifendurchlauf
    done
    IFS=$OLD_IFS # Setze IFS global zurück

    # --- KORREKTUR: Finale Fehlerprüfung ---
    if [ -f "$CLONE_ERROR_FLAG" ]; then 
        OVERALL_STATUS="ERROR"; 
        log_error "Überspringe Rest für ${SOURCE_VM_NAME} wegen Klon-Fehler. (Flag gefunden)"; 
        rm -f $CLONE_ERROR_FLAG # Flag aufräumen
        /bin/vim-cmd vmsvc/snapshot.removeall ${VMID} > /dev/null 2>&1 || true; 
        continue; 
    fi
    # --- ENDE KORREKTUR ---

    log "[5/7] Kopiere Konfigurationsdateien..."; (cd "${VMX_DIR}" && find . -maxdepth 1 \( -name "*.vmx" -o -name "*.nvram" -o -name "*.vmsd" \) -exec cp -p '{}' "${TARGET_VM_PATH}/" \;)
    log "[6/7] Passe Konfigurationsdateien an...";
    (
        cd "${TARGET_VM_PATH}"; ORIG_VMX_FILE=$(find . -maxdepth 1 -name "*.vmx"); ORIG_BASENAME=$(basename "${ORIG_VMX_FILE}" .vmx);
        for f in "${ORIG_BASENAME}"*; do
            new_name=$(echo "$f" | sed "s/^${ORIG_BASENAME}/${NEW_VM_NAME}/");
            if [ "$f" != "$new_name" ]; then mv -- "$f" "$new_name"; fi
        done;
        NEW_VMX_FILE="./${NEW_VM_NAME}.vmx";
        for vmdk_file in "${NEW_VM_NAME}"*.vmdk; do
            if ! echo "${vmdk_file}" | grep -q -- "-flat.vmdk"; then sed -i "s/${ORIG_BASENAME}/${NEW_VM_NAME}/g" "${vmdk_file}"; fi
        done;
        sed -i "s/${ORIG_BASENAME}/${NEW_VM_NAME}/g" "${NEW_VMX_FILE}";
        sed -i "s/^displayName = .*/displayName = \"${NEW_VM_NAME}\"/" "${NEW_VMX_FILE}";
        sed -i '/extendedConfigFile/d' "${NEW_VMX_FILE}"; sed -i '/vmxstats.filename/d' "${NEW_VMX_FILE}"; sed -i '/migrate.hostLog/d' "${NEW_VMX_FILE}";
        sed -i 's/-[0-9]\{6\}\.vmdk/\.vmdk/g' "${NEW_VMX_FILE}"; sed -i 's|\(fileName = "\)/.*/\(.*\.vmdk"\)|\1\2|g' "${NEW_VMX_FILE}";
        sed -i '/sched.swap.derivedName/d' "${NEW_VMX_FILE}"; sed -i '/uuid.location/d' "${NEW_VMX_FILE}"; sed -i '/uuid.bios/d' "${NEW_VMX_FILE}"; sed -i '/vc.uuid/d' "${NEW_VMX_FILE}";
        
        sed -i '/^uuid\.action/d' "${NEW_VMX_FILE}";
        echo "uuid.action = \"${UUID_ACTION}\"" >> "${NEW_VMX_FILE}";
    )
    log "[7/7] Registriere Klon & entferne Snapshot...";
    REGISTER_OUTPUT=$(/bin/vim-cmd solo/registervm "${TARGET_VM_PATH}/${NEW_VM_NAME}.vmx" 2>&1); REGISTER_CODE=$?
    if [ ${REGISTER_CODE} -ne 0 ]; then
        log_error "FEHLER: VM '${NEW_VM_NAME}' konnte nicht registriert werden."; log_error "Meldung: ${REGISTER_OUTPUT}"; OVERALL_STATUS="ERROR";
    else
        NEW_VMID_CLONE=$(echo "${REGISTER_OUTPUT}"); log "  -> Klon registriert als VMID: ${NEW_VMID_CLONE}";
        if [ "${POWER_ON}" = "1" ]; then
            log "Warte 5 Sekunden..."; sleep 5; log "Schalte geklonte VM ein...";
            POWERON_OUTPUT=$(/bin/vim-cmd vmsvc/power.on "${NEW_VMID_CLONE}" 2>&1); POWERON_CODE=$?;
            if [ ${POWERON_CODE} -ne 0 ]; then
                log_error "FEHLER: VM '${NEW_VM_NAME}' konnte nicht eingeschaltet werden."; log_error "Meldung: ${POWERON_OUTPUT}"; OVERALL_STATUS="ERROR";
            fi
        fi
    fi
    log "  -> Entferne Snapshot von ${SOURCE_VM_NAME}..."; /bin/vim-cmd vmsvc/snapshot.removeall ${VMID} >/dev/null 2>&1 || log_error "Snapshot von ${SOURCE_VM_NAME} konnte nicht entfernt werden.";
    
    # --- KORREKTUR: Größe aufsummieren ---
    VM_SIZE_K=$(du -sk "${TARGET_VM_PATH}" 2>/dev/null | awk '{print $1}')
    if [ -n "${VM_SIZE_K}" ] && [ "${VM_SIZE_K}" -gt 100 ]; then # 100K Puffer für Konfig-Dateien
        TOTAL_SIZE_K=$((TOTAL_SIZE_K + VM_SIZE_K))
        VM_SIZE_H=$(du -sh "${TARGET_VM_PATH}" | awk '{print $1}')
        NEW_LINE=$(printf -- "- %s (%s)\n" "${NEW_VM_NAME}" "${VM_SIZE_H}")
        VM_REPORT_LIST="${VM_REPORT_LIST}${NEW_LINE}"
    else
        # Bei Fehler: 132.0K anzeigen und OVERALL_STATUS auf ERROR setzen
        VM_SIZE_H="132.0K"
        NEW_LINE=$(printf -- "- %s (%s) FEHLGESCHLAGEN\n" "${NEW_VM_NAME}" "${VM_SIZE_H}")
        VM_REPORT_LIST="${VM_REPORT_LIST}${NEW_LINE}"
        OVERALL_STATUS="ERROR" # Setze Status, wenn Größe nach Registrierung noch zu klein ist
    fi
    # --- ENDE KORREKTUR ---
    
done
# --- Ende der Schleife ---
trap - EXIT
finish_job
'@

# =============================================================================
# --- Shell-Skript-Vorlage für den KALT-RESTORE (V1.2 - Final Reporting Fix)---
# =============================================================================

$restoreScriptTemplate = @'
#!/bin/sh
# GhettoGUI Cold Restore Helper V1.4 (Final Email Report Fix by Gemini)
# - APPLIED: Golden Rules for Email Reporting (Total Size, VM List Format, Header Match)
set -e

# --- START: LOCK FILE MECHANISM ---
LOCK_DIR="/tmp/ghetto_job___UNIQUE_ID__.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    exit 0 # Exit silently if lock exists
fi
# Define a combined trap that runs the main cleanup/finish_job and then removes the lock.
# Note: This script uses finish_job on success, which has its own exit.
trap 'finish_job; rm -rf "${LOCK_DIR}";' EXIT HUP INT QUIT TERM
# --- END: LOCK FILE MECHANISM ---

# Parameter
SOURCE_PATH='__SOURCE_PATH__'
TARGET_DATASTORE='__TARGET_DATASTORE__'
NEW_VM_NAME='__NEW_VM_NAME__'
POWER_ON=__POWER_ON__
UUID_ACTION='__UUID_ACTION__'
UNIQUE_ID='__UNIQUE_ID__'
GHETTO_PATH='__GHETTO_PATH__'
LOG_FILE="${GHETTO_PATH}/logs/restore_${UNIQUE_ID}.log"
EMAIL_ENABLED=__EMAIL_ENABLED__
EMAIL_TO='__EMAIL_TO__'
EMAIL_DISPLAY_NAME='__EMAIL_DISPLAY_NAME__';
EMAIL_FROM='__EMAIL_FROM__'
EMAIL_SERVER='__EMAIL_SERVER__'
EMAIL_PORT='__EMAIL_PORT__'
EMAIL_USER='__EMAIL_USER__'
EMAIL_PASS='__EMAIL_PASS__'
EMAIL_SUBJECT='__EMAIL_SUBJECT__'
SENDMAIL_PATH="${GHETTO_PATH}/sendmail"
OVERALL_STATUS="OK"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- INFO: $1" >> ${LOG_FILE}; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; }
log_raw() { echo "$1" >> ${LOG_FILE}; }

send_email_notification() {
    DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi
    FINAL_SIZE=$(du -sh "${TARGET_VM_PATH}" 2>/dev/null | awk '{print $1}')
    VM_REPORT_LIST=$(printf -- "- %s: %s\n" "${NEW_VM_NAME}" "${FINAL_SIZE}")

    log_raw "\n--- Zusammenfassung der geklonten VMs ---"
    log_raw "${VM_REPORT_LIST}"
    log_raw "-----------------------------------------"
    log_raw "Final size: ${FINAL_SIZE:-N/A}"

    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: Wiederherstellung ERFOLGREICH! ##"; else FINAL_STATUS_MSG="## Final status: FEHLER: Wiederherstellung fehlgeschlagen! ##"; fi
    log "Bereite E-Mail vor: ${OVERALL_STATUS}";
    log_raw "Backup Duration: ${DURATION_MSG}";
    log_raw "${FINAL_STATUS_MSG}";
    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/,/ /g');
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -N "${EMAIL_DISPLAY_NAME}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1;
    fi;
}

cleanup() {
    EXIT_CODE=$?
    log_raw "Speicherplatz (Nachher):"
    log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h "${TARGET_DATASTORE}" 2>/dev/null | grep /vmfs/)"
    log_raw "--- ENDE DES DETAILLOGS ---"

    END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S')
    log_raw "Endzeit: ${END_TIME_S}"
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden"
    if [ ${EXIT_CODE} -ne 0 ] && [ "${OVERALL_STATUS}" = "OK" ]; then log_error "Skript wurde unerwartet beendet. Setze Status auf ERROR."; OVERALL_STATUS="ERROR"; fi;
    send_email_notification "${DURATION_STRING}";
    log "====== VM RESTORE-PROZESS BEENDET (ID: ${UNIQUE_ID}) ======";
}

# --- Skriptstart ---
rm -f ${LOG_FILE}; mkdir -p "${GHETTO_PATH}/logs"; START_TIME=$(date +%s)
START_TIME=$(date +%s)
trap cleanup EXIT

# Log-Datei initialisieren
mkdir -p "$(dirname ${LOG_FILE})"
: > ${LOG_FILE}

log "====== VM RESTORE-PROZESS GESTARTET (ID: ${UNIQUE_ID}) ======"
log_raw "Startzeit: $(date '+%Y-%m-%d %H:%M:%S')"
log_raw "Job-Konfiguration:"
log_raw "  - Typ: GhettoVCB Wiederherstellung V8.4.4"
log_raw "  - Quelle: ${SOURCE_PATH}"
log_raw "  - Ziel-Datastore: ${TARGET_DATASTORE}"
log_raw "  - Neuer VM-Name: ${NEW_VM_NAME}"
log_raw "  - UUID-Aktion: ${UUID_ACTION}"

log_raw "Speicherplatz (Vorher):"
log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h "${TARGET_DATASTORE}" 2>/dev/null | grep /vmfs/)"
log_raw "--- START DES DETAILLOGS ---"

# Schritt 1: Zielverzeichnis erstellen
TARGET_VM_PATH="${TARGET_DATASTORE}/${NEW_VM_NAME}"
log "[1/5] Erstelle Zielverzeichnis: ${TARGET_VM_PATH}"
rm -rf "${TARGET_VM_PATH}"
mkdir -p "${TARGET_VM_PATH}"
log "  -> Zielverzeichnis ist bereit."

log "  -> Prüfe Quellpfad auf Unterverzeichnisse..."
ACTUAL_SOURCE_PATH="${SOURCE_PATH}"
SUBFOLDER_COUNT=$(find "${SOURCE_PATH}" -maxdepth 1 -mindepth 1 -type d | wc -l)
if [ "${SUBFOLDER_COUNT}" -eq 1 ]; then
    ACTUAL_SOURCE_PATH=$(find "${SOURCE_PATH}" -maxdepth 1 -mindepth 1 -type d)
    log "  -> Einzelner Backup-Unterordner gefunden, passe Quellpfad an auf: ${ACTUAL_SOURCE_PATH}"
fi

# Schritt 2: Backup-Daten kopieren mit Fortschrittsanzeige
log "[2/5] Kopiere Backup-Daten von '${ACTUAL_SOURCE_PATH}'..."
SOURCE_SIZE=$(du -sh "${ACTUAL_SOURCE_PATH}" | awk '{print $1}')
log "  -> Gesamtgröße des Backups: ${SOURCE_SIZE}"
cp -r "${ACTUAL_SOURCE_PATH}/." "${TARGET_VM_PATH}/" &
CP_PID=$!
while kill -0 ${CP_PID} >/dev/null 2>&1; do
    PROGRESS=$(du -sh "${TARGET_VM_PATH}" 2>/dev/null | awk '{print $1}')
    if [ -n "${PROGRESS}" ]; then log " -> Kopiere (${PROGRESS} von ${SOURCE_SIZE})"; fi
    sleep 5
done
wait ${CP_PID}
CP_EXIT_CODE=$?
if [ ${CP_EXIT_CODE} -ne 0 ]; then log_error "Kopiervorgang fehlgeschlagen mit Exit-Code ${CP_EXIT_CODE}!"; exit 1; fi
log "  -> Kopiervorgang erfolgreich abgeschlossen."

# Schritt 3: VMX und VMDKs anpassen
log "[3/5] Passe Konfigurationsdateien an..."
cd "${TARGET_VM_PATH}"
ORIG_VMX_FILE=$(find . -maxdepth 1 -name "*.vmx")
if [ -z "${ORIG_VMX_FILE}" ]; then log_error "Keine .vmx-Datei im Backup-Ordner gefunden!"; exit 1; fi
ORIG_BASENAME=$(basename "${ORIG_VMX_FILE}" .vmx)
log "  -> Originaler VM-Name im Backup: '${ORIG_BASENAME}'"
log "  -> Benenne Dateien um von '${ORIG_BASENAME}' zu '${NEW_VM_NAME}'..."
for f in "${ORIG_BASENAME}".*; do
    new_name=$(echo "$f" | sed "s/^${ORIG_BASENAME}/${NEW_VM_NAME}/")
    log "     - ${f} -> ${new_name}"
    mv -- "$f" "$new_name"
done
NEW_VMX_FILE="./${NEW_VM_NAME}.vmx"
log "  -> Passe Inhalt der VMX-Datei an: '${NEW_VMX_FILE}'"
sed -i "s/displayName = .*/displayName = \"${NEW_VM_NAME}\"/" "${NEW_VMX_FILE}"
sed -i "s/${ORIG_BASENAME}\.vmdk/${NEW_VM_NAME}\.vmdk/g" "${NEW_VMX_FILE}"
sed -i "s/${ORIG_BASENAME}\.nvram/${NEW_VM_NAME}\.nvram/g" "${NEW_VMX_FILE}"
sed -i 's|\(fileName = "\)/.*/\(.*\.vmdk"\)|\1\2|g' "${NEW_VMX_FILE}"
log "  -> Setze 'uuid.action = ${UUID_ACTION}'"
echo "uuid.action = \"${UUID_ACTION}\"" >> "${NEW_VMX_FILE}"

# Schritt 4: VM registrieren
log "[4/5] Registriere neue VM..."
REGISTER_OUTPUT=$(vim-cmd solo/registervm "${TARGET_VM_PATH}/${NEW_VM_NAME}.vmx")
if [ $? -ne 0 ]; then log_error "Fehler bei der Registrierung der VM!"; log_error "${REGISTER_OUTPUT}"; exit 1; fi
NEW_VMID=$(echo "${REGISTER_OUTPUT}")
log "  -> VM erfolgreich registriert mit neuer VMID: ${NEW_VMID}"

# Schritt 5: VM einschalten (optional)
if [ "${POWER_ON}" = "1" ]; then
    log "[5/5] Schalte wiederhergestellte VM ein..."
    log "  -> Warte 5 Sekunden, damit der Host den VM-Status aktualisieren kann..."
    sleep 5
    POWERON_OUTPUT=$(vim-cmd vmsvc/power.on "${NEW_VMID}" 2>&1)
    if [ $? -eq 0 ]; then
        log "  -> Einschalt-Befehl erfolgreich gesendet."
    else
        log_error "FEHLER: Die VM konnte nicht eingeschaltet werden."
        log_error "Host-Meldung: ${POWERON_OUTPUT}"
        OVERALL_STATUS="ERROR"
    fi
else
    log "[5/5] VM wird nicht automatisch eingeschaltet."
fi

log "====== WIEDERHERSTELLUNG ERFOLGREICH ABGESCHLOSSEN ======"
'@

# --- Logik für den "Restore / Klonen"-Button ---

# --- Logik für den "Restore / Klonen"-Button ---

$buttonRestore.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem ESXi-Host verbinden.", "Fehler", "OK", "Warning"); return
    }

    # --- Intelligente, nicht-destruktive Logik zum Vorbelegen der Felder ---
    $selectedVmCount = $checkedListBoxVms.CheckedItems.Count
    if ($selectedVmCount -gt 1) {
        Write-GuiLog "Multi-Klon-Modus: $selectedVmCount VMs ausgewählt. Passe Dialog an..."
        $radioCloneFromVm.Checked = $true; $textboxRestoreSourcePath.Enabled = $false; $buttonBrowseRestoreSource.Enabled = $false
        $textboxRestoreSourcePath.Text = "$selectedVmCount VMs aus der Hauptliste ausgewählt"
        $labelRestoreSource.Text = "Ausgewählte Quell-VMs:"; $labelRestoreNewVmName.Text = "Namens-Vorlage (mit * als Platzhalter):"
        if ([string]::IsNullOrWhiteSpace($textboxRestoreNewVmName.Text)) { $textboxRestoreNewVmName.Text = "Klon-*_$(Get-Date -f 'ddMMyy')" }
    } elseif ($selectedVmCount -eq 1) {
        $radioCloneFromVm.Checked = $true; $textboxRestoreSourcePath.Enabled = $false; $buttonBrowseRestoreSource.Enabled = $false
        $textboxRestoreSourcePath.Text = $checkedListBoxVms.CheckedItems[0].OriginalName
        $labelRestoreSource.Text = "Zu klonende Quell-VM:"; $labelRestoreNewVmName.Text = "Neuer Name für die geklonte VM: (* = Bestehender Name)"
        if ([string]::IsNullOrWhiteSpace($textboxRestoreNewVmName.Text)) { $textboxRestoreNewVmName.Text = "$($checkedListBoxVms.CheckedItems[0].OriginalName)-Klon" }
    } else { 
        $radioRestoreFromBackup.Checked = $true; $textboxRestoreSourcePath.Enabled = $true; $buttonBrowseRestoreSource.Enabled = $true
        $labelRestoreSource.Text = "Zu wiederherstellendes Backup:"; $labelRestoreNewVmName.Text = "Neuer Name für die wiederhergestellte/geklonte VM. KEINE SONDERZEICHEN"
    }
    
    # --- Dialog anzeigen und auf Ergebnis warten ---
    $restoreResult = $restoreForm.ShowDialog($form)
    
    # --- NEU: Komplette Logik zum Starten des Jobs wiederhergestellt ---
    if ($restoreResult -eq [System.Windows.Forms.DialogResult]::OK) {
        
        $finalScriptTemplate = $null; $params = $null; $watcherName = ""; $logPrefix = ""

        # === 1. NEUE LOGIK: HOLE PUNCHING ===
        if ($radioHolePunch.Checked) {
            $selectedVmsList = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName })
            if ($selectedVmsList.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Bitte wähle im Hauptfenster mindestens eine VM aus.", "Fehler", "OK", "Warning"); return }
            
            # Warnung
            if ([System.Windows.Forms.MessageBox]::Show("ACHTUNG: VMs müssen AUS sein!`n`nMöchtest du fortfahren?", "Wartung", "YesNo", "Warning") -ne 'Yes') { return }

            # Wir setzen Dummy-Werte für TargetDatastore und NewVmName, damit die Validierung unten nicht meckert!
            $params = @{
                VM_LIST = ($selectedVmsList -join "`n"); 
                GHETTO_PATH = $textboxGhettoPath.Text;
                UNIQUE_ID = "{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Minimum 100 -Maximum 999);
                # Dummy Werte um Validierung zu bestehen:
                TARGET_DATASTORE = "MAINTENANCE_MODE"; 
                NEW_VM_NAME = "MAINTENANCE_MODE";
                NAME_TEMPLATE = "MAINTENANCE_MODE";
                SOURCE_PATH = "MAINTENANCE_MODE";
                SOURCE_VM_NAME = "MAINTENANCE_MODE"
            }
            
            $Global:currentJobTargetName = "Wartung ($($selectedVmsList.Count) VMs)"; $Global:currentJobType = "Hole Punching"
            $finalScriptTemplate = $maintenanceScriptTemplate; $watcherName = "GhettoMaintenanceWatcher"; $logPrefix = "maintenance"

        # === 2. BESTEHENDE LOGIK: MULTI-KLON ===
        } elseif ($selectedVmCount -gt 1 -and $radioCloneFromVm.Checked) {
            # --- Logik für Multi-VM Klon ---
            if ([string]::IsNullOrWhiteSpace($comboboxDiskFormat.SelectedItem)) { [System.Windows.Forms.MessageBox]::Show("Bitte wählen Sie zuerst im Hauptfenster ein 'Disk Format' aus (z.B. thin).", "Fehlende Auswahl", "OK", "Warning"); return }
            if (-not $textboxRestoreNewVmName.Text.Contains("*")) { [System.Windows.Forms.MessageBox]::Show("Die Namens-Vorlage muss den Platzhalter '*' enthalten.", "Fehlender Platzhalter", "OK", "Warning"); return }
            
            $params = @{
                VM_LIST = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }) -join "`n"; NAME_TEMPLATE = $textboxRestoreNewVmName.Text; TARGET_DATASTORE = $textboxRestoreTargetPath.Text;
                POWER_ON = if ($checkboxPowerOnAfterRestore.Checked) { 1 } else { 0 }; UUID_ACTION = if ($radioRestoreMoved.Checked) { "keep" } else { "create" };
                DISK_FORMAT = $comboboxDiskFormat.SelectedItem.ToString(); SNAP_QUIESCE = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 };
                UNIQUE_ID = "{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Minimum 100 -Maximum 999); GHETTO_PATH = $textboxGhettoPath.Text;
                EMAIL_ENABLED = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EMAIL_TO = $textboxEmailTo.Text; EMAIL_FROM = $textboxEmailFrom.Text; EMAIL_DISPLAY_NAME = $dn; EMAIL_SERVER = $textboxEmailServer.Text; EMAIL_PORT = $textboxEmailPort.Text; EMAIL_USER = $textboxEmailUser.Text; EMAIL_PASS = $textboxEmailPassword.Text;
                EMAIL_SUBJECT = "[Multi-Klon] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName)
            }
            $Global:currentJobTargetName = "$selectedVmCount VMs"; $Global:currentJobType = "Multi-VM Klon"
            $finalScriptTemplate = $multiCloneScriptTemplate; $watcherName = "GhettoMultiCloneWatcher"; $logPrefix = "clone"
        
        # === 3. BESTEHENDE LOGIK: SINGLE KLON / RESTORE ===
        } else {
            # --- Logik für Single-VM Klon oder Restore ---
            if ($radioRestoreFromBackup.Checked) {
                $params = @{
                    SOURCE_PATH = $textboxRestoreSourcePath.Text; TARGET_DATASTORE = $textboxRestoreTargetPath.Text; NEW_VM_NAME = $textboxRestoreNewVmName.Text;
                    POWER_ON = if ($checkboxPowerOnAfterRestore.Checked) { 1 } else { 0 }; UUID_ACTION = if ($radioRestoreMoved.Checked) { "keep" } else { "create" };
                    UNIQUE_ID = "{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Minimum 100 -Maximum 999); GHETTO_PATH = $textboxGhettoPath.Text;
                    EMAIL_ENABLED = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EMAIL_TO = $textboxEmailTo.Text; EMAIL_FROM = $textboxEmailFrom.Text; EMAIL_DISPLAY_NAME = $dn; EMAIL_SERVER = $textboxEmailServer.Text; EMAIL_PORT = $textboxEmailPort.Text; EMAIL_USER = $textboxEmailUser.Text; EMAIL_PASS = $textboxEmailPassword.Text;
                    EMAIL_SUBJECT = "[Restore] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName)
                }
                $Global:currentJobTargetName = $params.NEW_VM_NAME; $Global:currentJobType = "Wiederherstellung"
                $finalScriptTemplate = $restoreScriptTemplate; $watcherName = "GhettoRestoreWatcher"; $logPrefix = "restore"
            } else {
                if ([string]::IsNullOrWhiteSpace($comboboxDiskFormat.SelectedItem)) { [System.Windows.Forms.MessageBox]::Show("Bitte wählen Sie zuerst im Hauptfenster ein 'Disk Format' aus (z.B. thin).", "Fehlende Auswahl", "OK", "Warning"); return }
                $params = @{
                    SOURCE_VM_NAME = $textboxRestoreSourcePath.Text; TARGET_DATASTORE = $textboxRestoreTargetPath.Text; NEW_VM_NAME = $textboxRestoreNewVmName.Text;
                    POWER_ON = if ($checkboxPowerOnAfterRestore.Checked) { 1 } else { 0 }; UUID_ACTION = if ($radioRestoreMoved.Checked) { "keep" } else { "create" };
                    DISK_FORMAT = $comboboxDiskFormat.SelectedItem.ToString(); SNAP_QUIESCE = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 };
                    UNIQUE_ID = "{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Minimum 100 -Maximum 999); GHETTO_PATH = $textboxGhettoPath.Text;
                    EMAIL_ENABLED = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EMAIL_TO = $textboxEmailTo.Text; EMAIL_FROM = $textboxEmailFrom.Text; EMAIL_DISPLAY_NAME = $dn; EMAIL_SERVER = $textboxEmailServer.Text; EMAIL_PORT = $textboxEmailPort.Text; EMAIL_USER = $textboxEmailUser.Text; EMAIL_PASS = $textboxEmailPassword.Text;
                    EMAIL_SUBJECT = "[Klonen] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName)
                }
                $Global:currentJobTargetName = $params.NEW_VM_NAME; $Global:currentJobType = "Klonen"
                $finalScriptTemplate = $cloneScriptTemplate; $watcherName = "GhettoCloneWatcher"; $logPrefix = "clone"
            }
        }
        
        # --- AB HIER IST WIEDER ALLES ORIGINAL ---
        # (Die Validierung unten funktioniert dank der Dummy-Werte oben auch für Hole Punching)

        if ( ($params.SOURCE_PATH -eq $null -and $params.SOURCE_VM_NAME -eq $null -and $params.VM_LIST -eq $null) -or [string]::IsNullOrWhiteSpace($params.TARGET_DATASTORE) -or ($params.NEW_VM_NAME -eq $null -and $params.NAME_TEMPLATE -eq $null) ) {
            [System.Windows.Forms.MessageBox]::Show("Bitte fülle alle benötigten Felder aus (Quelle, Ziel-Datastore und Name/Vorlage).", "Fehlende Eingaben", "OK", "Warning"); return
        }

        $remoteScriptPath = "$($params.GHETTO_PATH)/ghetto_$($logPrefix)_$($params.UNIQUE_ID).sh"; $launcherScriptPath = "$($params.GHETTO_PATH)/launcher_ghetto_$($logPrefix)_$($params.UNIQUE_ID).sh"; $remoteLogPath = "$($params.GHETTO_PATH)/logs/$($logPrefix)_$($params.UNIQUE_ID).log"
        $finalScript = $finalScriptTemplate; foreach ($key in $params.Keys) { $finalScript = $finalScript.Replace("__$($key)__", $params[$key]) }
        $sftpSession = $null
        try {
            $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -ConnectionTimeout 60
            $unixContent = ($finalScript -split "`r`n") -join "`n"; Set-SFTPContent -SFTPSession $sftpSession -Path $remoteScriptPath -Value $unixContent
            Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$remoteScriptPath'"
            $launcherContent = "#!/bin/sh`nnohup sh '$remoteScriptPath' >> '$remoteLogPath' 2>&1 &"; Set-SFTPContent -SFTPSession $sftpSession -Path $launcherScriptPath -Value $launcherContent; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$launcherScriptPath'"
        } catch { [System.Windows.Forms.MessageBox]::Show("Fehler beim Hochladen des Skripts: $($_.Exception.Message)", "Upload-Fehler", "OK", "Error"); return } finally { if ($sftpSession) { Remove-SFTPSession -SftpSession $sftpSession } }
        
        Get-Job | Where-Object { $_.Name -like 'Ghetto*' } | Remove-Job -Force
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "sh '$launcherScriptPath'"
        
        $plainTextPassword = $Global:ESXiSshCredential.GetNetworkCredential().Password; $watcherParams = @{ Host = $Global:ESXiConnectedHostName; Username = $Global:ESXiSshCredential.UserName; PlainTextPassword = $plainTextPassword; RemoteLogPath = $remoteLogPath }
        $Global:replicationJob = Start-Job -Name $watcherName -ScriptBlock { param($p)
            Import-Module Posh-SSH -ErrorAction SilentlyContinue; $securePassword = ConvertTo-SecureString $p.PlainTextPassword -AsPlainText -Force; $cred = New-Object System.Management.Automation.PSCredential($p.Username, $securePassword); $watcherSession = $null
            try {
                $watcherSession = New-SSHSession -ComputerName $p.Host -Credential $cred -AcceptKey -ConnectionTimeout 60; if (-not $watcherSession.Connected) { Write-Output "FEHLER: Watcher-Job konnte keine SSH-Verbindung herstellen."; return }
                $lastLineNumber = 0; $timeout = (Get-Date).AddHours(24)
                while ((Get-Date) -lt $timeout) {
                    Start-Sleep -Seconds 3
                    if ((Invoke-SSHCommand -SSHSession $watcherSession -Command "if [ -f '$($p.RemoteLogPath)' ]; then echo 'EXISTS'; fi").Output -join '' -eq 'EXISTS') {
                        $newLinesResult = Invoke-SSHCommand -SSHSession $watcherSession -Command "tail -n +$($lastLineNumber + 1) '$($p.RemoteLogPath)'"
                        if ($newLinesResult.Output) {
                            $lines = $newLinesResult.Output; foreach ($line in $lines) { Write-Output "$line" }; $lastLineNumber += $lines.Count
                            if ($lines[-1] -match "====== .* BEENDET ======") { break }
                        }
                    }
                }
            } catch { Write-Output "FATALER FEHLER im Watcher-Job: $($_.Exception.Message)" } finally { if ($watcherSession) { Remove-SSHSession -SSHSession $watcherSession } }
        } -ArgumentList $watcherParams
        $Global:replicationJobTimer.Start()
        Write-GuiLog "$($Global:currentJobType)-Prozess für '$($Global:currentJobTargetName)' gestartet. Log wird live überwacht."
    
    } else {
        Write-GuiLog "Vorgang vom Benutzer abgebrochen."
    }
})

# --- ENDE Klick-Event für den Haupt-Restore-Button  ---

# In GhettoGUI_V8.0.1.ps1
# ERSETZE diesen Block

$buttonBrowseRestoreSource.Add_Click({
    if ($radioRestoreFromBackup.Checked) {
        # --- Modus: Restore aus Backup-Ordner ---
        Write-GuiLog "Öffne Datastore-Auswahl für Backup-Quelle..."
        $selection = Show-DatastoreSelectionDialog -SSHSession $Global:ESXiSession
        if (-not $selection) { Write-GuiLog "Auswahl abgebrochen."; return }

        $currentPath = $selection
        if (-not $currentPath) { Write-GuiLog "Auswahl abgebrochen."; return }

        # --- KORRIGIERTE Navigations-Schleife (V5) ---
        while ($true) {
            # Rufe den Dialog auf
            $dialogOutput = Show-DirectorySelectionDialog -Title "Navigiere zum Backup-Ordner" -BasePath $currentPath -SshSession $Global:ESXiSession
            
            # Benutzer klickt "Diesen Ordner auswählen"
            if ($dialogOutput.Result -eq 'Yes') {
                $currentPath = $dialogOutput.CurrentPath # Holt den BEREINIGTEN Pfad
                $textboxRestoreSourcePath.Text = $currentPath
                Write-GuiLog "Backup-Quelle für Restore ausgewählt: $currentPath"
                
                # Versuche, VM-Namen aus Pfad abzuleiten (unverändert)
                $originalVmName = ($currentPath -split '/')[-1]
                $originalVmName = $originalVmName -replace '-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$',''
                $textboxRestoreNewVmName.Text = "$($originalVmName)-Restored"
                break # Schleife verlassen
            }
            # Benutzer klickt "Öffnen" oder doppelklickt (muss $dialogOutput.CurrentPath aktualisieren)
            elseif ($dialogOutput.Result -eq 'OK' -and $dialogOutput.SelectedItem) {
                # $currentPath wird *innerhalb* des Dialogs aktualisiert und für den nächsten Aufruf wiederverwendet
                # Die Variable $currentPath in *dieser* Funktion muss aktualisiert werden
                # $dialogOutput.CurrentPath ist der *neue* Pfad nach der Navigation
                $currentPath = $dialogOutput.CurrentPath
            }
            # Benutzer klickt "Abbrechen" oder schliesst das Fenster
            else {
                Write-GuiLog "Backup-Auswahl abgebrochen."
                break # Schleife verlassen
            }
        }
        # --- ENDE KORREKTUR ---
    } else {
        # --- Modus: Klon von laufender VM (unverändert) ---
        Write-GuiLog "Öffne VM-Auswahl zum Klonen..."
        $selectedVm = Show-VmSelectionDialog -parentForm $restoreForm
        if ($selectedVm) {
            $textboxRestoreSourcePath.Text = $selectedVm
            Write-GuiLog "Zu klonende Quell-VM ausgewählt: $selectedVm"

            if ([string]::IsNullOrWhiteSpace($textboxRestoreNewVmName.Text)) {
                $textboxRestoreNewVmName.Text = "$($selectedVm)-Klon"
            }
        }
    }
})

function Show-VmSelectionDialog {
    param(
        [object]$parentForm
    )

    $vmForm = New-Object System.Windows.Forms.Form
    $vmForm.Text = "VM zum Klonen auswählen"
    $vmForm.Size = New-Object System.Drawing.Size(450, 350)
    $vmForm.StartPosition = "CenterParent"
    $vmForm.FormBorderStyle = 'FixedDialog'

    $listBoxVms = New-Object System.Windows.Forms.ListBox
    $listBoxVms.Dock = 'Top'
    $listBoxVms.Height = 250
    $listBoxVms.Margin = New-Object System.Windows.Forms.Padding(10)

    $buttonOk = New-Object System.Windows.Forms.Button; $buttonOk.Text = "Auswählen"; $buttonOk.DialogResult = 'OK'; $buttonOk.Enabled = $false
    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.DialogResult = 'Cancel'
    
    $flowPanel = New-Object System.Windows.Forms.FlowLayoutPanel; $flowPanel.Dock = 'Bottom'; $flowPanel.FlowDirection = 'RightToLeft'; $flowPanel.Height = 40
    $flowPanel.Controls.AddRange(@($buttonCancel, $buttonOk))
    
    $vmForm.Controls.AddRange(@($listBoxVms, $flowPanel))
    $vmForm.AcceptButton = $buttonOk
    $vmForm.CancelButton = $buttonCancel

    $listBoxVms.Add_SelectedIndexChanged({ $buttonOk.Enabled = ($listBoxVms.SelectedItem -ne $null) })
    $listBoxVms.Add_DoubleClick({ if ($listBoxVms.SelectedItem) { $buttonOk.PerformClick() } })

    $vmForm.Add_Shown({
        $vmForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            # Logik zum Abrufen der VMs (vereinfacht aus Load-VMListFromESXi)
            $sshOutput = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "vim-cmd vmsvc/getallvms"
            $outputLines = if ($sshOutput.Output -is [array]) { $sshOutput.Output } else { @($sshOutput.Output -split [Environment]::NewLine) }
            $headerSkipped = $false
            foreach ($line in $outputLines) {
                if (-not $headerSkipped) { if ($line -match '^\s*Vmid\s+Name') { $headerSkipped = $true; continue }};
                $trimmedLine = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmedLine)) { continue };
                $vmName = $null
                if ($trimmedLine -match '^\s*(\d+)\s+([^\[]+?)\s+\[.+') {
                    $vmName = $Matches[2].Trim()
                }
                if ($vmName) {
                    $listBoxVms.Items.Add($vmName)
                }
            }
        } catch {
             [System.Windows.Forms.MessageBox]::Show("Fehler beim Laden der VM-Liste: $($_.Exception.Message)", "Fehler", "OK", "Error")
        } finally {
            $vmForm.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    if ($vmForm.ShowDialog($parentForm) -eq 'OK') {
        return $listBoxVms.SelectedItem
    }
    return $null
}


$buttonBrowseRestoreTarget.Add_Click({
    Write-GuiLog "Öffne Datastore-Auswahl für Restore-Ziel..."
    $selectedPath = Show-DatastoreSelectionDialog -SSHSession $Global:ESXiSession
    if ($selectedPath) {
        $textboxRestoreTargetPath.Text = $selectedPath
        Write-GuiLog "Restore-Ziel ausgewählt: $selectedPath"
    } else {
        Write-GuiLog "Auswahl des Ziels abgebrochen."
    }
})

# -------------------------------------------------------------------------------------
#  -  ENDE RESTORE
# -------------------------------------------------------------------------------------

# -----------------------------------------------------------------------------------
# -----  Manuell Lokal Restore mit WINSCP Start --------------
# -----------------------------------------------------------------------------------

# In GhettoGUI_V8.0.1.ps1
# ERSETZE diesen Block

$buttonDownloadBackup.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSshCredential)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem ESXi-Host verbinden.", "Fehler", "OK", "Warning"); return
    }

    # 1. Prüfen, ob die WinSCP-Bibliothek vorhanden ist (unverändert)
    $winscpDllPath = Join-Path $Global:ScriptPath "WinSCPnet.dll"
    if (-not (Test-Path $winscpDllPath)) {
        [System.Windows.Forms.MessageBox]::Show("Die Datei 'WinSCPnet.dll' wurde nicht im Skriptverzeichnis gefunden.`n`nBitte kopieren Sie 'WinSCP.exe' und 'WinSCPnet.dll' in denselben Ordner wie die GhettoGUI.", "WinSCP nicht gefunden", "OK", "Error")
        return
    }

    # 2. Remote-Ordner auf ESXi auswählen
    Write-GuiLog "Öffne Datastore-Auswahl für Backup-Quelle..."
    $remoteFolderPath = $null
    try {
        $currentPath = Show-DatastoreSelectionDialog -SSHSession $Global:ESXiSession # Verwende die Standard-Session
        if (-not $currentPath) { Write-GuiLog "Auswahl abgebrochen."; return }
        
        # --- KORRIGIERTE Navigations-Schleife (V5) ---
        while ($true) {
            # Rufe den Dialog auf
            $dialogOutput = Show-DirectorySelectionDialog -Title "Navigiere zum herunterzuladenden Ordner" -BasePath $currentPath -SshSession $Global:ESXiSession
            
            # Benutzer klickt "Diesen Ordner auswählen"
            if ($dialogOutput.Result -eq 'Yes') {
                $remoteFolderPath = $dialogOutput.CurrentPath # Holt den BEREINIGTEN Pfad
                break # Schleife verlassen
            }
            # Benutzer klickt "Öffnen" oder doppelklickt (aktualisiert $currentPath)
            elseif ($dialogOutput.Result -eq 'OK' -and $dialogOutput.SelectedItem) {
                $currentPath = $dialogOutput.CurrentPath
            }
            # Benutzer klickt "Abbrechen"
            else {
                Write-GuiLog "Auswahl abgebrochen.";
                return # Funktion beenden
            }
        }
        # --- ENDE KORREKTUR ---

    } catch { Write-GuiLog "FEHLER bei der Ordnerauswahl: $($_.Exception.Message)"; return }
    if (-not $remoteFolderPath) { return } # Falls Schleife ohne Auswahl verlassen wurde
    
    Write-GuiLog "Remote-Quelle für Download ausgewählt: $remoteFolderPath"

    # 3. Lokalen Zielordner auf dem PC auswählen (unverändert)
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Wählen Sie den lokalen Ordner, in den das Backup heruntergeladen werden soll"
    if ($folderBrowser.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-GuiLog "Download abgebrochen."; return
    }
    $localDestinationFolder = $folderBrowser.SelectedPath
    Write-GuiLog "Lokales Zielverzeichnis: $localDestinationFolder"

    # 4. Download mit WinSCP durchführen (unverändert)
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $session = $null
    try {
        Add-Type -Path $winscpDllPath
        # ... (Rest der WinSCP-Logik bleibt gleich) ...
        $sessionOptions = New-Object WinSCP.SessionOptions
        $sessionOptions.Protocol = [WinSCP.Protocol]::Sftp
        $sessionOptions.HostName = $Global:ESXiConnectedHostName
        $sessionOptions.UserName = $Global:ESXiSshCredential.UserName
        $sessionOptions.Password = $Global:ESXiSshCredential.GetNetworkCredential().Password
        $sessionOptions.GiveUpSecurityAndAcceptAnySshHostKey = $true
        $session = New-Object WinSCP.Session
        Write-GuiLog "Verbinde mit Host via WinSCP..."
        $session.Open($sessionOptions)
        Write-GuiLog "Verbindung erfolgreich. Beginne mit der Analyse des Ordners..."
        $form.Refresh()
        $transferOptions = New-Object WinSCP.TransferOptions
        $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary
        $remoteFiles = $session.EnumerateRemoteFiles($remoteFolderPath, "*", [WinSCP.EnumerationOptions]::AllDirectories)
        $localRootPath = Join-Path $localDestinationFolder (Split-Path $remoteFolderPath -Leaf)
        foreach ($fileInfo in $remoteFiles) {
            $relativePath = $fileInfo.FullName.Substring($remoteFolderPath.Length)
            $localPath = Join-Path $localRootPath $relativePath.TrimStart('/')
            if ($fileInfo.IsDirectory) {
                if (-not (Test-Path $localPath)) {
                    Write-GuiLog "Erstelle Verzeichnis: $localPath"
                    New-Item -ItemType Directory -Path $localPath | Out-Null
                }
            } else {
                $localParentDir = Split-Path -Path $localPath -Parent
                if (-not (Test-Path $localParentDir)) {
                    New-Item -ItemType Directory -Path $localParentDir -Force | Out-Null
                }
                $fileSizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
                Write-GuiLog "Lade Datei herunter: $($fileInfo.Name) ($($fileSizeMB) MB)"
                $form.Refresh()
                $session.GetFiles($fileInfo.FullName, $localPath, $false, $transferOptions).Check()
            }
        }
        Write-GuiLog "====== DOWNLOAD ERFOLGREICH ABGESCHLOSSEN ======"
        [System.Windows.Forms.MessageBox]::Show("Der Ordner wurde erfolgreich nach `"$localRootPath`" heruntergeladen.", "Download abgeschlossen", "OK", "Information")
    } catch {
        Write-GuiLog "FEHLER beim Download mit WinSCP: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Beim Download ist ein Fehler aufgetreten.`n`n$($_.Exception.Message)", "Download-Fehler", "OK", "Error")
    } finally {
        if ($session -and $session.Opened) { $session.Close() }
        if ($session) { $session.Dispose() }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# -----------------------------------------------------------------------------------
# -----  Manuell Lokal Restore End --------------
# -----------------------------------------------------------------------------------

# =====================================================================================
# --- STARTBLOCK  (Die Klick-Funktion des Firewall-Buttons) ---
# =====================================================================================

$buttonFirewallCheck.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Für die Firewall-Einrichtung muss eine Verbindung zum ESXi-Host bestehen.", "Fehler", "OK", "Warning"); return
    }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        # --- TEIL 1: Benutzerdefinierte SMTP-Regel erstellen und aktivieren ---
        $portToOpen = $textboxEmailPort.Text.Trim()
        if (-not ($portToOpen -match '^\d+$' -and [int]$portToOpen -gt 0 -and [int]$portToOpen -le 65535)) {
            [System.Windows.Forms.MessageBox]::Show("Bitte geben Sie einen gültigen Port (1-65535) in das SMTP-Port Feld ein.", "Ungültiger Port", "OK", "Error"); return
        }
        
        $ruleId = "ghettoGUIsmtp$($portToOpen)"
        Write-GuiLog "Erstelle/Prüfe benutzerdefinierte Firewall-Regel '$($ruleId)' für SMTP-Port $portToOpen..."

        $xmlContent = @"
<ConfigRoot>
  <service id='9999'>
    <id>$($ruleId)</id>
    <rule id='0000'>
      <direction>outbound</direction>
      <protocol>tcp</protocol>
      <porttype>dst</porttype>
      <port>$($portToOpen)</port>
    </rule>
    <enabled>true</enabled>
    <required>false</required>
  </service>
</ConfigRoot>
"@
        $remoteXmlPath = "/etc/vmware/firewall/$($ruleId).xml"
        $sftp = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
        try {
            Set-SFTPContent -SFTPSession $sftp -Path $remoteXmlPath -Value $xmlContent -Encoding UTF8
            Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network firewall refresh" | Out-Null
            Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network firewall ruleset set --enabled true --ruleset-id=$ruleId" | Out-Null
            Write-GuiLog " -> SMTP-Regel '$ruleId' für Port $portToOpen erfolgreich erstellt/aktiviert."
        } finally {
            if ($sftp) { Remove-SFTPSession -SFTPSession $sftp -ErrorAction SilentlyContinue }
        }

        # --- TEIL 2: sshClient Regel aktivieren ---
        Write-GuiLog "Prüfe/Aktiviere Firewall-Regel für direkte Replikation (sshClient)..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network firewall ruleset set --enabled true --ruleset-id=sshClient" | Out-Null
        Write-GuiLog " -> Replikations-Regel 'sshClient' ist jetzt aktiv."
        
        # --- NEUER, ROBUSTER TEIL 3: Persistenz erzwingen ---
        Write-GuiLog "-> Speichere Konfiguration für Neustart..."
        # Führt das offizielle Backup-Skript aus, um die aktuellen Konfigurationsänderungen zu sichern.
        # Die '0' als Parameter erzwingt ein Backup. '1' würde nur bei Änderungen sichern.
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "/sbin/backup.sh 0" | Out-Null
        Write-GuiLog "--> Konfiguration erfolgreich für Neustart gespeichert."

        [System.Windows.Forms.MessageBox]::Show("Die Firewall-Regeln wurden erfolgreich aktiviert UND für den Neustart gespeichert.", "Erfolg", "OK", "Information")

    } catch {
        Write-GuiLog "FEHLER beim Firewall-Setup: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Beim Firewall-Setup ist ein Fehler aufgetreten.`n`nDetails: $($_.Exception.Message)", "Fehler", "OK", "Error")
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# =====================================================================================
# --- ENDBLOCK ---
# =====================================================================================


$buttonTestEmail.Add_Click({
    if (Validate-RequiredFields -Context 'EmailTest') {
        Write-GuiLog "Speichere Konfiguration automatisch für E-Mail-Test..."
        if (Save-GhettoVCBConfig) {
            Write-GuiLog "Warte 1 Sekunde, um das Speichern der Konfiguration sicherzustellen..."
            Start-Sleep -Seconds 1
            Send-TestEmail
        }
    }
})

$buttonCheckPoshSsh.Add_Click({ if(Ensure-PoshSshModule) { Show-VersionInfoPopup } })

$buttonBrowseGhettoPath.Add_Click({
    Write-GuiLog "Öffne Datastore-Auswahl für 'GhettoVCB-Pfad'..."
    $selectedDatastorePath = Show-DatastoreSelectionDialog -SSHSession $Global:ESXiSession
    if ($selectedDatastorePath) {
        $basePath = $selectedDatastorePath.TrimEnd('/')
        $ghettoVCBFolderName = "ghettoVCB"
        $fullGhettoPath = "$basePath/$ghettoVCBFolderName"
        $textboxGhettoPath.Text = $fullGhettoPath
        Write-GuiLog "GhettoVCB-Pfad gesetzt auf: $fullGhettoPath"
    } else {
        Write-GuiLog "Auswahl abgebrochen."
    }
})

$buttonBrowseBackupVol.Add_Click({
    Write-GuiLog "Öffne Datastore-Auswahl für 'Backup Volume'..."
    $selectedPath = Show-DatastoreSelectionDialog -SSHSession $Global:ESXiSession
    if ($selectedPath) {
        $textboxBackupVol.Text = $selectedPath
        Write-GuiLog "Backup Volume ausgewählt: $selectedPath"
    } else {
        Write-GuiLog "Auswahl abgebrochen."
    }
})

$buttonBrowseBackupDir.Add_Click({ Browse-BackupDir })
$buttonLoadVms.Add_Click({ Load-VMListFromESXi })
$buttonApplyVms.Add_Click({ Apply-SelectedVMsToVmList })
$saveConfigButton.Add_Click({
    if (Validate-RequiredFields -Context 'SaveOrBackup') {
        Save-GhettoVCBConfig
    }
})

$buttonLoadGuiSettings.Add_Click({
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.Title = "Gespeicherten Job laden"
    $openFileDialog.Filter = "GhettoGUI Jobs (*.json)|*.json"
    $openFileDialog.InitialDirectory = $Global:ScriptPath
    if ($openFileDialog.ShowDialog($form) -eq 'OK') {
        Load-HostGuiSettings -FilePath $openFileDialog.FileName
    }
})

$buttonSaveGuiSettings.Add_Click({
    $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveFileDialog.Title = "Job speichern unter..."
    $saveFileDialog.Filter = "GhettoGUI Jobs (*.json)|*.json"
    $saveFileDialog.InitialDirectory = $Global:ScriptPath
    $saveFileDialog.FileName = "$($Global:ESXiConnectedHostName)-Job.json"
    if ($saveFileDialog.ShowDialog($form) -eq 'OK') {
        Save-HostGuiSettings -FilePath $saveFileDialog.FileName
    }
})

$buttonInstallGitHub.Add_Click({ Start-GhettoVCBInstallationFlow })
$buttonInstallPatchedGhetto.Add_Click({ Install-PatchedGhettoVCB })
# $buttonInstallSendmailPy.Add_Click({ Install-CustomSendmail })

# Neuer Butten sendmail PY mit Cron Anpassung
# -------------------------------------------------

$buttonInstallSendmailPy.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }
    $ghettoPathOnESXi = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "FEHLER: Der GhettoVCB-Pfad muss gesetzt sein."; return }

    # (Die Logik für die Quellauswahl bleibt gleich)
    $sendmailUrl = "https://github.com/Chrigel71/GhettoGUI/raw/main/sendmail.py"
    $targetPathSendmail = "$ghettoPathOnESXi/sendmail"
    $localSourceFilePath = $null
    $tempFile = $null
    $choice = Show-InstallationSourceDialog -Title "Quelle für E-Mail-Skript wählen" -Message "Möchten Sie das sendmail.py Skript von GitHub oder von einer lokalen Datei installieren?"
    if ($choice -eq 'Yes') { # GitHub
        try { $tempFile = New-TemporaryFile; Invoke-WebRequest -Uri $sendmailUrl -OutFile $tempFile.FullName -UseBasicParsing; $localSourceFilePath = $tempFile.FullName } 
        catch { Write-GuiLog "FEHLER beim GitHub-Download: $($_.Exception.Message)"; return }
    } elseif ($choice -eq 'No') { # Lokale Datei
        $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog; $openFileDialog.Title = "Lokale sendmail.py Datei auswählen"; $openFileDialog.Filter = "Python-Skripte (*.py)|*.py|Alle Dateien (*.*)|*.*"
        if ($openFileDialog.ShowDialog($form) -eq 'OK') { $localSourceFilePath = $openFileDialog.FileName } 
        else { Write-GuiLog "Installation abgebrochen."; return }
    } else { Write-GuiLog "Installation abgebrochen."; return }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $sftpSession = $null
    try {
        $ErrorActionPreference = "Stop"
        Write-GuiLog "Verbinde via SFTP..."
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60

        # --- Teil 1: sendmail.py installieren ---
        Write-GuiLog "Installiere E-Mail-Skript..."
        $scriptContentString = Get-Content -Path $localSourceFilePath -Raw
        $cleanContent = $scriptContentString.Replace("`r`n", "`n").Replace("`t", "    ")
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm -f `"$targetPathSendmail`"" | Out-Null
        Set-SFTPContent -SFTPSession $sftpSession -Path $targetPathSendmail -Value $cleanContent -Encoding UTF8
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x `"$targetPathSendmail`"" | Out-Null
        Write-GuiLog "-> E-Mail-Skript erfolgreich installiert!"

        # --- NEU: Teil 2: 2-Wochen-Wrapper-Skript installieren ---
        # Write-GuiLog "Installiere 2-Wochen-Helfer-Skript..."
        # $targetPathBiWeekly = "$ghettoPathOnESXi/ghettoVCB_biweekly_wrapper.sh"
        # $cleanContentBiWeekly = $biWeeklyHelperScriptContent.Replace("`r`n", "`n")
        # Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm -f `"$targetPathBiWeekly`"" | Out-Null
        # Set-SFTPContent -SFTPSession $sftpSession -Path $targetPathBiWeekly -Value $cleanContentBiWeekly -Encoding UTF8
        # Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x `"$targetPathBiWeekly`"" | Out-Null
        # Write-GuiLog "-> 2-Wochen-Helfer-Skript erfolgreich installiert!"
        # --- ENDE NEU ---

        [System.Windows.Forms.MessageBox]::Show("Email Script Sendmail.py wurden erfolgreich installiert!", "Installation erfolgreich", "OK", "Information")
    } catch {
        Write-GuiLog "FEHLER bei der Installation: $($_.Exception.Message)"
    } finally {
        if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession -EA 0 }
        if ($tempFile -and (Test-Path $tempFile.FullName)) { Remove-Item $tempFile.FullName -Force -EA 0 }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $ErrorActionPreference = "Continue"
    }
})



$buttonStartBackup.Add_Click({
    if (Validate-RequiredFields -Context 'SaveOrBackup') {
        Write-GuiLog "Speichere Konfiguration automatisch vor Backup-Start..."
        if (Save-GhettoVCBConfig) {
            Write-GuiLog "Warte 1 Sekunde, um das Speichern der Konfiguration sicherzustellen..."
            Start-Sleep -Seconds 1
            if (Start-GhettoVCBBackupJob) {
                Write-GuiLog "Starte automatischen Log-Abruf alle 10 Sekunden..."
                $buttonStartBackup.Enabled = $false
                $buttonCheckBackupStatus.Enabled = $false
                $buttonCancelBackup.Enabled = $true
                $Global:logPollTimer.Start()
            } else {
                Write-GuiLog "Backup konnte nicht gestartet werden. Automatischer Log-Abruf nicht aktiviert."
            }
        }
    }
})
$buttonCheckBackupStatus.Add_Click({ Get-BackupJobLog })
$buttonCancelBackup.Add_Click({ Stop-GhettoVCBBackupJob })
$buttonGetEsxiTime.Add_Click({ Update-ESXiTimeDisplay })
$buttonGetDebugLog.Add_Click({ Get-SendmailDebugLog })

# ---------------------------------------------------------------------------------
# Start Geplante Replikation und Backup und Klon mit CRON + 2-Weekly + Monthly
#----------------------------------------------------------------------------------

$buttonSaveSchedule.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem ESXi-Host verbinden.", "Fehler", "OK", "Warning"); return
    }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        # --- Gemeinsame Parameter ---
        $ghettoPath = $textboxGhettoPath.Text
        if ([string]::IsNullOrWhiteSpace($ghettoPath)) { throw "Der GhettoVCB-Pfad muss in der Konfiguration gesetzt sein!" }
        $scheduleHour = $textboxScheduleHour.Text.Trim()
        $scheduleMinute = $textboxScheduleMinute.Text.Trim()
        if (-not ($scheduleHour -match "^\d{1,2}$" -and $scheduleHour -ge 0 -and $scheduleHour -le 23) -or
            -not ($scheduleMinute -match "^\d{1,2}$" -and $scheduleMinute -ge 0 -and $scheduleMinute -le 59) ) {
            throw "Bitte geben Sie eine gültige Stunde (0-23) und Minute (0-59) ein."
        }
        $selectedDays = ($checkboxDays.GetEnumerator() | Where-Object { $_.Value.Checked } | ForEach-Object { $_.Value.Tag }) -join ','
        if ([string]::IsNullOrEmpty($selectedDays)) { $selectedDays = "*" }
        $jobId = (Get-Date -Format "yyyyMMdd-HHmmss")
        $cronFile = "/var/spool/cron/crontabs/root"

        # --- Display Name abrufen ---
        $dn = $textboxEmailDisplay.Text
        if ([string]::IsNullOrWhiteSpace($dn)) { $dn = "ESXi Backup" }
        # ----------------------------

        $commandToRun = ""; $cronComment = ""
        $sftp = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
        try {
            # --- Logik für die verschiedenen Job-Typen ---
            if ($radioScheduleReplication.Checked) {
                $cronComment = "# GhettoGUI - Scheduled Direct Replication (ID: $jobId)"; $remoteStarterScriptPath = "$ghettoPath/scheduled_replication_$jobId.sh"
                $commandToRun = "'$remoteStarterScriptPath'"
                
                if ([string]::IsNullOrWhiteSpace($textboxDrTargetHost.Text) -or [string]::IsNullOrWhiteSpace($textboxDrTargetDs.Text) -or $checkedListBoxVms.CheckedItems.Count -eq 0) { throw "Für eine geplante Replikation müssen Ziel-Host, Zielspeicher und mindestens eine VM konfiguriert/ausgewählt sein." }
                
                $selectedMethod = 'robust'; $tempPathForSchedule = if ($script:replicationUseLocalTemp) { "" } else { $script:replicationTempPath.TrimEnd('/') }
                
                # --- NEU: Disable Punch Wert ermitteln (1=Ja, 0=Nein) ---
                $valDisablePunch = if ($checkboxDisablePunch.Checked) { "1" } else { "0" }
                # --------------------------------------------------------

                $params = @{ 
                    UNIQUE_ID = $jobId; 
                    TARGET_HOST = $textboxDrTargetHost.Text; 
                    TARGET_DATASTORE = $textboxDrTargetDs.Text; 
                    VM_SUFFIX = $textboxDrSuffix.Text; 
                    REPLICATION_METHOD = $selectedMethod; 
                    DISK_FORMAT = $comboboxDiskFormat.SelectedItem.ToString(); 
                    DISABLE_PUNCH = $valDisablePunch; # <--- HIER EINGEFÜGT
                    TEMP_CLONE_BASE_PATH = $tempPathForSchedule; 
                    SNAP_MEM = if ($checkboxSnapMem.Checked) { 1 } else { 0 }; 
                    SNAP_QUIESCE = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 }; 
                    GHETTO_PATH = $ghettoPath; 
                    EMAIL_ENABLED = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; 
                    EMAIL_TO = $textboxEmailTo.Text; 
                    EMAIL_FROM = $textboxEmailFrom.Text; 
                    EMAIL_DISPLAY_NAME = $dn; 
                    EMAIL_SERVER = $textboxEmailServer.Text; 
                    EMAIL_PORT = $textboxEmailPort.Text; 
                    EMAIL_USER = $textboxEmailUser.Text; 
                    EMAIL_PASS = $textboxEmailPassword.Text; 
                    EMAIL_SUBJECT = "[Scheduled-Repl.] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName); 
                    VM_LIST = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }) -join "`n" 
                }
                
                $finalMasterScript = $masterHelperScriptTemplate; foreach ($key in $params.Keys) { $finalMasterScript = $finalMasterScript.Replace("__$($key)__", $params[$key]) }
                Set-SFTPContent -SFTPSession $sftp -Path $remoteStarterScriptPath -Value ($finalMasterScript.Replace("`r`n", "`n")); Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$remoteStarterScriptPath'"

            } elseif ($radioScheduleRestoreClone.Checked) {
                $selectedVmCount = $checkedListBoxVms.CheckedItems.Count; if ($selectedVmCount -eq 0) { throw "Für einen geplanten Klon/Restore-Job muss mindestens eine VM in der Hauptliste ausgewählt sein." }
                $finalMasterScript = $null; $params = @{};
                if ($radioRestoreFromBackup.Checked) {
                    $cronComment = "# GhettoGUI - Scheduled Restore (ID: $jobId)"; $remoteStarterScriptPath = "$ghettoPath/scheduled_restore_$jobId.sh"
                    $params = @{ SOURCE_PATH = $textboxRestoreSourcePath.Text; TARGET_DATASTORE = $textboxRestoreTargetPath.Text; NEW_VM_NAME = $textboxRestoreNewVmName.Text; POWER_ON = if ($checkboxPowerOnAfterRestore.Checked) { 1 } else { 0 }; UUID_ACTION = if ($radioRestoreMoved.Checked) { "keep" } else { "create" }; UNIQUE_ID = $jobId; GHETTO_PATH = $ghettoPath; EMAIL_ENABLED = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EMAIL_TO = $textboxEmailTo.Text; EMAIL_FROM = $textboxEmailFrom.Text; EMAIL_DISPLAY_NAME = $dn; EMAIL_SERVER = $textboxEmailServer.Text; EMAIL_PORT = $textboxEmailPort.Text; EMAIL_USER = $textboxEmailUser.Text; EMAIL_PASS = $textboxEmailPassword.Text; EMAIL_SUBJECT = "[Scheduled-Restore] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName) }
                    $finalMasterScript = $scheduledRestoreScriptTemplate
                } else { # Klon-Modus
                    if ($selectedVmCount -eq 1) {
                        $cronComment = "# GhettoGUI - Scheduled Single-Clone (ID: $jobId)"; $remoteStarterScriptPath = "$ghettoPath/scheduled_clone_$jobId.sh"
                        $params = @{ SOURCE_VM_NAME = $checkedListBoxVms.CheckedItems[0].OriginalName; TARGET_DATASTORE = $textboxRestoreTargetPath.Text; NEW_VM_NAME = $textboxRestoreNewVmName.Text; POWER_ON = if ($checkboxPowerOnAfterRestore.Checked) { 1 } else { 0 }; UUID_ACTION = if ($radioRestoreMoved.Checked) { "keep" } else { "create" }; DISK_FORMAT = $comboboxDiskFormat.SelectedItem.ToString(); SNAP_QUIESCE = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 }; UNIQUE_ID = $jobId; GHETTO_PATH = $ghettoPath; EMAIL_ENABLED = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EMAIL_TO = $textboxEmailTo.Text; EMAIL_FROM = $textboxEmailFrom.Text; EMAIL_DISPLAY_NAME = $dn; EMAIL_SERVER = $textboxEmailServer.Text; EMAIL_PORT = $textboxEmailPort.Text; EMAIL_USER = $textboxEmailUser.Text; EMAIL_PASS = $textboxEmailPassword.Text; EMAIL_SUBJECT = "[Scheduled-Clone] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName) }
                        $finalMasterScript = $scheduledCloneScriptTemplate
                    } else {
                        $cronComment = "# GhettoGUI - Scheduled Multi-Clone (ID: $jobId)"; $remoteStarterScriptPath = "$ghettoPath/scheduled_multiclone_$jobId.sh"
                        if (-not $textboxRestoreNewVmName.Text.Contains("*")) { throw "Für einen geplanten Multi-Klon muss im Klon/Restore-Fenster eine Namens-Vorlage mit '*' konfiguriert sein." }
                        $params = @{ VM_LIST = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }) -join "`n"; NAME_TEMPLATE = $textboxRestoreNewVmName.Text; TARGET_DATASTORE = $textboxRestoreTargetPath.Text; POWER_ON = if ($checkboxPowerOnAfterRestore.Checked) { 1 } else { 0 }; UUID_ACTION = if ($radioRestoreMoved.Checked) { "keep" } else { "create" }; DISK_FORMAT = $comboboxDiskFormat.SelectedItem.ToString(); SNAP_QUIESCE = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 }; UNIQUE_ID = $jobId; GHETTO_PATH = $ghettoPath; EMAIL_ENABLED = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EMAIL_TO = $textboxEmailTo.Text; EMAIL_FROM = $textboxEmailFrom.Text; EMAIL_DISPLAY_NAME = $dn; EMAIL_SERVER = $textboxEmailServer.Text; EMAIL_PORT = $textboxEmailPort.Text; EMAIL_USER = $textboxEmailUser.Text; EMAIL_PASS = $textboxEmailPassword.Text; EMAIL_SUBJECT = "[Scheduled-Multi-Clone] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName) }
                        $finalMasterScript = $scheduledMultiCloneScriptTemplate
                    }
                }
                foreach ($key in $params.Keys) { $finalMasterScript = $finalMasterScript.Replace("__$($key)__", $params[$key]) }
                
                $commandToRun = "'$remoteStarterScriptPath'"
                Set-SFTPContent -SFTPSession $sftp -Path $remoteStarterScriptPath -Value ($finalMasterScript.Replace("`r`n", "`n")); Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$remoteStarterScriptPath'"

            } else { # GhettoVCB Backup
                $cronComment = "# GhettoGUI - Scheduled Backup (ID: $jobId)"
                $remoteGhettoScript = "$ghettoPath/ghettoVCB.sh"; $remoteGhettoConf = "$ghettoPath/ghettoVCB-conf-$jobId.conf"; $remoteVmListFile = "$ghettoPath/vms_to_backup-$jobId.txt"
                $dateForLogCmd = '$(date +\%F)'
                $remoteLogFile = "$ghettoPath/logs/backup-run-$jobId-$dateForLogCmd.log"
                $useFixedDirValue = if ($checkboxFixedBackupDir.Checked) { 1 } else { 0 }; 
                
                $confLines = @( 
                    "USE_FIXED_BACKUP_DIR=$useFixedDirValue", 
                    "VM_BACKUP_VOLUME=`"$($textboxBackupVol.Text.TrimEnd('/'))/$($textboxSubfolder.Text.Trim('/'))`"", 
                    "VM_BACKUP_ROTATION_COUNT=$($textboxRotation.Text)", 
                    "DISK_BACKUP_FORMAT=`"$($comboboxDiskFormat.SelectedItem.ToString())`"", 
                    "VM_SNAPSHOT_MEMORY=$(if ($checkboxSnapMem.Checked) { 1 } else { 0 })", 
                    "VM_SNAPSHOT_QUIESCE=$(if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 })", 
                    "EMAIL_LOG=$(if ($checkboxEmailLog.Checked) { 1 } else { 0 })", 
                    "EMAIL_SERVER=`"$($textboxEmailServer.Text)`"", 
                    "EMAIL_SERVER_PORT=`"$($textboxEmailPort.Text)`"", 
                    "EMAIL_USER_NAME=`"$($textboxEmailUser.Text)`"", 
                    "EMAIL_USER_PASSWORD=`"$($textboxEmailPassword.Text)`"", 
                    "EMAIL_FROM=`"$($textboxEmailFrom.Text)`"", 
                    "EMAIL_DISPLAY_NAME=`"$($textboxEmailDisplay.Text)`"",
                    "EMAIL_TO=`"$($textboxEmailTo.Text)`"", 
                    "EMAIL_SUBJECT=`"$($textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName))`"", 
                    "EMAIL_BIN=`"$ghettoPath/sendmail`"" 
                ); 

                $ghettoConfContent = ($confLines -join "`n") + "`n"; $unixVmListText = ($textboxVmList.Text.Split([string[]]@("`r`n","`r","`n"), [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() }) -join "`n"; if (-not [string]::IsNullOrEmpty($unixVmListText)) { $unixVmListText += "`n" }
                Set-SFTPContent -SFTPSession $sftp -Path $remoteGhettoConf -Value $ghettoConfContent -Encoding UTF8; Set-SFTPContent -SFTPSession $sftp -Path $remoteVmListFile -Value $unixVmListText -Encoding UTF8 
                $commandToRun = "'$remoteGhettoScript' -f '$remoteVmListFile' -g '$remoteGhettoConf' -l $remoteLogFile"
            }
            
            $finalExecutableCommand = $commandToRun
            $selectedMode = $comboRepeatMode.SelectedItem.Value

            switch ($selectedMode) {
                "BIWEEKLY_EVEN" {
                    Write-GuiLog "-> 2-wöchentlicher Zeitplan (gerade KW) ausgewählt."
                    $finalExecutableCommand = 'if [ $(( $(date +\%V) % 2 )) -eq 0 ]; then ' + $commandToRun + '; fi'
                }
                "BIWEEKLY_ODD" {
                    Write-GuiLog "-> 2-wöchentlicher Zeitplan (ungerade KW) ausgewählt."
                    $finalExecutableCommand = 'if [ $(( $(date +\%V) % 2 )) -ne 0 ]; then ' + $commandToRun + '; fi'
                }
                "MONTHLY_1" {
                    Write-GuiLog "-> Monatlicher Zeitplan (1. Woche) ausgewählt."
                    $finalExecutableCommand = '[ $(date +\%d) -ge 1 -a $(date +\%d) -le 7 ] && ' + $commandToRun
                }
                "MONTHLY_2" {
                    Write-GuiLog "-> Monatlicher Zeitplan (2. Woche) ausgewählt."
                    $finalExecutableCommand = '[ $(date +\%d) -ge 8 -a $(date +\%d) -le 14 ] && ' + $commandToRun
                }
                "MONTHLY_3" {
                    Write-GuiLog "-> Monatlicher Zeitplan (3. Woche) ausgewählt."
                    $finalExecutableCommand = '[ $(date +\%d) -ge 15 -a $(date +\%d) -le 21 ] && ' + $commandToRun
                }
                "MONTHLY_4" {
                    Write-GuiLog "-> Monatlicher Zeitplan (4. Woche) ausgewählt."
                    $finalExecutableCommand = '[ $(date +\%d) -ge 22 -a $(date +\%d) -le 28 ] && ' + $commandToRun
                }
                 "MONTHLY_LAST" {
                    Write-GuiLog "-> Monatlicher Zeitplan (Letzte Woche) ausgewählt."
                    $finalExecutableCommand = '[ $(date +\%d) -ge 22 ] && ' + $commandToRun
                }
                default {
                    Write-GuiLog "-> Wöchentlicher Zeitplan ausgewählt."
                }
            }

            $cronCommand = "$scheduleMinute $scheduleHour * * $selectedDays $finalExecutableCommand $cronComment"
            
            Write-GuiLog "Füge neuen Task zum Zeitplan hinzu: $cronCommand"
            $escapedCronCommand = $cronCommand.Replace("'", "'\''")
            $fullSshCommand = "echo '$escapedCronCommand' >> '$cronFile'"
            Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $fullSshCommand

            Write-GuiLog "Lade Cron-Dienst neu...";
            Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command 'kill $(cat /var/run/crond.pid) && crond';
            Write-GuiLog "Neuer Task erfolgreich zum Zeitplan hinzugefügt!"
            [System.Windows.Forms.MessageBox]::Show("Ein neuer Task wurde erfolgreich zum Zeitplan hinzugefügt. Email Absender: '$dn'", "Erfolg", "OK", "Information")
            sleep 6
        } catch {
            Write-GuiLog "FEHLER beim Speichern des Zeitplans: $($_.Exception.Message)"
        } finally {
            if ($sftp) { Remove-SFTPSession -SFTPSession $sftp -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-GuiLog "FEHLER beim Speichern des Zeitplans: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("FEHLER beim Speichern des Zeitplans:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# ---------------------------------------------------------------------------------
# Ende Replikation und Backup planen#
#----------------------------------------------------------------------------------

# ------------------------------------------------------------------
# Dies ist die stabile Vorlage für geplante Replikationen mit vollständigem E-Mail-Reporting
# UPDATE V56.6: Support for 'Disable Hole Punching'
# - FEATURE: Checks __DISABLE_PUNCH__ variable. If '1', skips vmkfstools -K.
# - RETAINS: Cold-Copy Order Fix, Live-Log, Auto-Fallback, Auto-Cleanup.
# ------------------------------------------------------------------

$masterHelperScriptTemplate = @'
#!/bin/sh
# GhettoGUI Multi-VM Replication Helper V56.6 (Cron - Disable Punch Support)

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin
export PATH

# 1. PARAMETER
UNIQUE_ID='__UNIQUE_ID__'; TARGET_HOST='__TARGET_HOST__'; TARGET_DATASTORE='__TARGET_DATASTORE__'; VM_SUFFIX='__VM_SUFFIX__'; REPLICATION_METHOD='__REPLICATION_METHOD__'; GHETTO_PATH='__GHETTO_PATH__';
LOG_FILE="${GHETTO_PATH}/logs/master_replication_${UNIQUE_ID}_$(date '+%Y-%m-%d_%H%M%S').log";
DISK_FORMAT='__DISK_FORMAT__'; # thin, zeroedthick, or eagerzeroedthick
DISABLE_PUNCH='__DISABLE_PUNCH__'; # 1 = Skip Punching

# --- SSH CONFIGURATION ---
BASE_OPTS="-i /.ssh/id_ecdsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o Compression=no -o LogLevel=ERROR"
SSH_OPTS="-T ${BASE_OPTS}"
SCP_OPTS="${BASE_OPTS}"
# -------------------------

SNAP_MEM=__SNAP_MEM__; SNAP_QUIESCE=__SNAP_QUIESCE__; EMAIL_ENABLED=__EMAIL_ENABLED__; EMAIL_TO='__EMAIL_TO__'; EMAIL_FROM='__EMAIL_FROM__'; EMAIL_DISPLAY_NAME='__EMAIL_DISPLAY_NAME__'; EMAIL_SERVER='__EMAIL_SERVER__'; EMAIL_PORT='__EMAIL_PORT__'; EMAIL_USER='__EMAIL_USER__'; EMAIL_PASS='__EMAIL_PASS__'; EMAIL_SUBJECT='__EMAIL_SUBJECT__'; SENDMAIL_PATH="${GHETTO_PATH}/sendmail"; VM_LIST='
__VM_LIST__
'; OVERALL_STATUS="OK";
TEMP_CLONE_BASE_PATH='__TEMP_CLONE_BASE_PATH__';

# --- LOCK FILE CHECK ---
LOCK_DIR="/tmp/ghetto_job_manual_${UNIQUE_ID}.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then exit 0; fi
trap 'cleanup; rm -rf "${LOCK_DIR}";' EXIT HUP INT QUIT TERM

# --- Helpers ---
DS_SEARCH_TERM=$(basename "${TARGET_DATASTORE}")
VM_REPORT_LIST=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -> $1" >> ${LOG_FILE}; sync; }
log_raw() { echo "$1" >> ${LOG_FILE}; sync; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; sync; }

send_email_notification() {
    DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi;
    log_raw "\n--- Zusammenfassung der geklonten VMs ---"
    log_raw "${VM_REPORT_LIST}"
    log_raw "-----------------------------------------"
    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: All VMs backed up OK! ##"; else FINAL_STATUS_MSG="## Final status: ERROR: Replication failed! ##"; fi;
    log "Bereite E-Mail vor: ${OVERALL_STATUS}"; log_raw "Backup Duration: ${DURATION_MSG}"; log_raw "${FINAL_STATUS_MSG}";
    
    if [ -n "${DIRECTORY_LISTING_CONTENT}" ]; then
        log_raw "\n--- START Backup Directory Listing ---"
        log_raw "${DIRECTORY_LISTING_CONTENT}"
        log_raw "--- END Backup Directory Listing ---"
    fi

    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/,/ /g')
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -N "${EMAIL_DISPLAY_NAME}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1
    fi
}

cleanup() {
    EXIT_CODE=$?
    if [ ${EXIT_CODE} -ne 0 ] && [ "${OVERALL_STATUS}" = "OK" ]; then
        log_error "Skript wurde mit Fehlercode ${EXIT_CODE} beendet. Setze Status auf ERROR."
        OVERALL_STATUS="ERROR"
    fi
    trap - EXIT
    
    FINAL_SIZE=$(ssh ${SSH_OPTS} root@${TARGET_HOST} "du -sch ${TARGET_DATASTORE}/*${VM_SUFFIX} 2>/dev/null | grep total" | awk '{print $1}')
    if [ -z "${FINAL_SIZE}" ]; then FINAL_SIZE="N/A"; fi
    log_raw "Final size: ${FINAL_SIZE}"
    
    STORAGE_INFO=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "esxcli storage filesystem list | grep '${DS_SEARCH_TERM}' | awk '{ printf \"Total: %.2f GB | Frei: %.2f GB\", \$6/1073741824, \$7/1073741824 }'" < /dev/null)
    log_raw "Speicherplatz (Nachher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): ${STORAGE_INFO}"; 
    
    log_raw "--- ENDE DES DETAILLOGS ---"; END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S'); log_raw "Endzeit: ${END_TIME_S}"; END_TIME=$(date +%s);
    DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden"
    send_email_notification "${DURATION_STRING}";
    log "====== MULTI-VM REPLICATION HELPER BEENDET (ID: ${UNIQUE_ID}) ======";
}

# --- Skriptstart ---
rm -f ${LOG_FILE}; mkdir -p "${GHETTO_PATH}/logs"; START_TIME=$(date +%s)
trap cleanup EXIT
log "====== MULTI-VM REPLICATION HELPER GESTARTET (ID: ${UNIQUE_ID}) ======"; log_raw "Startzeit: $(date '+%Y-%m-%d %H:%M:%S')";

# --- Infos sammeln ---
SRC_HOSTNAME=$(hostname)
SRC_IP=$(esxcli network ip interface ipv4 get | grep vmk0 | awk '{print $2}')
if [ -z "${SRC_IP}" ]; then SRC_IP=$(esxcli network ip interface ipv4 get | awk 'NR>2 {print $2; exit}'); fi
TARGET_HOSTNAME=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "hostname" 2>/dev/null || echo "Unknown")
TARGET_DS_NAME=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "esxcli storage filesystem list | grep '${TARGET_DATASTORE}' | awk '{print \$2}'" 2>/dev/null || echo "${TARGET_DATASTORE}")

log_raw "Job-Konfiguration:"
log_raw "  - Typ: Geplante Replikation (H2H V8.4.4)"
log_raw "  - Methode: ${REPLICATION_METHOD}"
log_raw "  - Disk Format: ${DISK_FORMAT} (Punching: ${DISABLE_PUNCH})"
log_raw "  - Quell-Host: ${SRC_IP} (${SRC_HOSTNAME})"
log_raw "  - Ziel-Host: ${TARGET_HOST} (${TARGET_HOSTNAME})"
log_raw "  - Ziel-Datastore: ${TARGET_DS_NAME}"

STORAGE_INFO_PRE=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "esxcli storage filesystem list | grep '${DS_SEARCH_TERM}' | awk '{ printf \"Total: %.2f GB | Frei: %.2f GB\", \$6/1073741824, \$7/1073741824 }'" < /dev/null)
log_raw "Speicherplatz (Vorher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): ${STORAGE_INFO_PRE}"; 
log_raw "--- START DES DETAILLOGS ---"
sync

CLONE_ERROR_FLAG="/tmp/clone_error_manual_${UNIQUE_ID}.flag"
rm -f $CLONE_ERROR_FLAG
CLEAN_VM_LIST=$(echo "${VM_LIST}" | sed '/^$/d')

for SOURCE_VM_NAME in ${CLEAN_VM_LIST}; do
    log "#################### Starte Verarbeitung für VM: ${SOURCE_VM_NAME} ########V56.6############"
    
    REPLICATED_VM_NAME="${SOURCE_VM_NAME}${VM_SUFFIX}"
    if echo "${TARGET_DATASTORE}" | grep -q "^/vmfs/volumes"; then
        TARGET_VM_PATH="${TARGET_DATASTORE}/${REPLICATED_VM_NAME}"
    else
        TARGET_VM_PATH="/vmfs/volumes/${TARGET_DATASTORE}/${REPLICATED_VM_NAME}"
    fi

    log "initiate backup for ${SOURCE_VM_NAME}"
    VM_INFO_LINE=$(vim-cmd vmsvc/getallvms | awk -v name="${SOURCE_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $0; }'); if [ -z "${VM_INFO_LINE}" ]; then log_error "[${SOURCE_VM_NAME}] - VM nicht gefunden!"; OVERALL_STATUS="ERROR"; continue; fi
    VMID=$(echo "${VM_INFO_LINE}" | awk '{print $1}'); VMX_FULL_PATH=$(echo "${VM_INFO_LINE}" | sed -e 's/.*\[\(.*\)\]\s*\(.*\.vmx\).*/\/vmfs\/volumes\/\1\/\2/'); VMX_DIR=$(dirname "${VMX_FULL_PATH}")

    # Power State
    VM_POWER_STATE=$(vim-cmd vmsvc/power.getstate ${VMID} | grep -i "Powered" | awk '{print $NF}')
    log "INFO: VM Power State: ${VM_POWER_STATE}"
    
    # Bereinigung
    log "[1/7] Bereinige alte Replikation..."; TARGET_VMID=$(ssh ${SSH_OPTS} root@${TARGET_HOST} "vim-cmd vmsvc/getallvms | awk -v name=\"${REPLICATED_VM_NAME}\" '{print \$1}'" < /dev/null); if [ -n "${TARGET_VMID}" ]; then ssh ${SSH_OPTS} root@${TARGET_HOST} "vim-cmd vmsvc/power.off ${TARGET_VMID} >/dev/null 2>&1 || true; sleep 2; vim-cmd vmsvc/unregister ${TARGET_VMID} >/dev/null 2>&1" < /dev/null; fi
    log "[2/7] Erstelle Zielverzeichnis..."; ssh ${SSH_OPTS} root@${TARGET_HOST} "rm -rf '${TARGET_VM_PATH}'; mkdir -p '${TARGET_VM_PATH}'" < /dev/null
    sleep 2

    # Patch Script Init
    PATCH_SCRIPT="/tmp/patch_vmx_${UNIQUE_ID}.sh"
    echo "#!/bin/sh" > "${PATCH_SCRIPT}"
    echo "cd '${TARGET_VM_PATH}' || exit 1" >> "${PATCH_SCRIPT}"
    echo "RENAMED_VMX_FILE=\"./${REPLICATED_VM_NAME}.vmx\"" >> "${PATCH_SCRIPT}"
    echo "if [ ! -f \"\${RENAMED_VMX_FILE}\" ]; then echo 'FATAL: VMX File missing after Rename'; exit 1; fi" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i '/sched.swap.derivedName/d' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i '/vc.uuid/d' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i '/migrate.hostLog/d' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i 's/displayName = .*/displayName = \"${REPLICATED_VM_NAME}\"/' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i '/msg.autoAnswer/d' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i '/^uuid.action/d' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "echo 'msg.autoAnswer = \"FALSE\"' >> \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "echo 'uuid.action = \"prompt\"' >> \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"

    DISK_IDX=0
    DISK_LIST_FILE="/tmp/disk_list_${UNIQUE_ID}.txt"
    grep -iE 'scsi[0-9]+:[0-9]+\.fileName' "${VMX_FULL_PATH}" > "${DISK_LIST_FILE}"

    # --- BRANCHING ---
    if [ "${REPLICATION_METHOD}" = "robust" ] && [ "${VM_POWER_STATE}" = "on" ]; then
        # --- HOT CLONE ---
        if [ -z "${TEMP_CLONE_BASE_PATH}" ]; then TEMP_CLONE_CHECK_PATH="${VMX_DIR}"; else TEMP_CLONE_CHECK_PATH="${TEMP_CLONE_BASE_PATH}"; fi
        log "[0/7] Prüfe Speicherplatz für Temp-Klon..."
        
        # --- CLEANUP LEFTOVERS ---
        if vim-cmd vmsvc/snapshot.get ${VMID} | grep -q "ghetto-repl"; then
            log "WARNUNG: Alter Replikations-Snapshot gefunden. Führe Konsolidierung durch (kann dauern)..."
            vim-cmd vmsvc/snapshot.removeall ${VMID}
            sleep 15
            log "       -> Konsolidierung abgeschlossen."
        fi
        
        log "[4/7] Starte ONLINE Replikation (Snapshot)..."; 
        
        # --- AUTO-FALLBACK LOGIC ---
        vim-cmd vmsvc/snapshot.create ${VMID} "ghetto-repl-${UNIQUE_ID}" "Ghetto" ${SNAP_MEM} ${SNAP_QUIESCE} > /dev/null 2>&1
        SNAP_EXIT_CODE=$?
        
        if [ ${SNAP_EXIT_CODE} -ne 0 ] && [ "${SNAP_QUIESCE}" = "1" ]; then
            log "WARNUNG: Snapshot mit Quiescing fehlgeschlagen. Versuche Crash-Consistent Snapshot..."
            vim-cmd vmsvc/snapshot.create ${VMID} "ghetto-repl-${UNIQUE_ID}" "Ghetto" ${SNAP_MEM} 0 > /dev/null 2>&1
            SNAP_EXIT_CODE=$?
        fi
        
        if [ ${SNAP_EXIT_CODE} -ne 0 ]; then
            log_error "FATAL: Snapshot konnte nicht erstellt werden. Abbruch für ${SOURCE_VM_NAME}."
            OVERALL_STATUS="ERROR"
            continue
        fi
        log "INFO: Snapshot erfolgreich erstellt."
        sleep 15

        if [ -z "${TEMP_CLONE_BASE_PATH}" ]; then TEMP_CLONE_DIR="${VMX_DIR}/ghetto_clone_${UNIQUE_ID}"; else TEMP_CLONE_DIR="${TEMP_CLONE_BASE_PATH}/ghetto_clone_${UNIQUE_ID}"; fi; rm -rf "${TEMP_CLONE_DIR}"; mkdir -p "${TEMP_CLONE_DIR}"
        
        while read -r line; do
            DEVICE_ID=$(echo "$line" | awk -F. '{print $1}' | awk '{print $1}')
            VMX_DISK_PATH=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p');
            if [ -z "${VMX_DISK_PATH}" ]; then continue; fi
            VMX_DISK_PATH_BASE=$(echo "${VMX_DISK_PATH}" | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/');
            if echo "${VMX_DISK_PATH_BASE}" | grep -q "^/"; then SOURCE_DISK_PATH_FOR_CLONE="${VMX_DISK_PATH_BASE}"; else SOURCE_DISK_PATH_FOR_CLONE="${VMX_DIR}/${VMX_DISK_PATH_BASE}"; fi
            SRC_BASENAME_ONLY=$(basename "${VMX_DISK_PATH_BASE}" .vmdk)
            IDX_STR=$(printf "%02d" ${DISK_IDX})
            TARGET_FILENAME="${SRC_BASENAME_ONLY}${VM_SUFFIX}-${IDX_STR}.vmdk"
            DESTINATION_DISK_PATH="${TEMP_CLONE_DIR}/${TARGET_FILENAME}"
            
            log "  -> Processing Disk ${DISK_IDX}: ${SRC_BASENAME_ONLY}"
            log "     ...Klonen nach Temp gestartet (Lokal: ${DISK_FORMAT})..."
            VMKF_LOG="/tmp/vmkf_progress_${UNIQUE_ID}_${DISK_IDX}.log"
            
            /sbin/vmkfstools -i "${SOURCE_DISK_PATH_FOR_CLONE}" -d ${DISK_FORMAT} "${DESTINATION_DISK_PATH}" > "${VMKF_LOG}" 2>&1 &
            VMKF_PID=$!
            while kill -0 ${VMKF_PID} >/dev/null 2>&1; do
                PROGRESS_LINE=$(tr '\r' '\n' < "${VMKF_LOG}" | grep "%" | tail -n 1)
                if [ -n "${PROGRESS_LINE}" ]; then 
                    log "     ...${PROGRESS_LINE}"
                else 
                    CURRENT_CLONE_SIZE=$(du -sh "${TEMP_CLONE_DIR}" 2>/dev/null | awk '{print $1}')
                    if [ -n "${CURRENT_CLONE_SIZE}" ]; then log "Klonen: ${SOURCE_VM_NAME} ${CURRENT_CLONE_SIZE}"; fi
                fi
                sleep 30
            done
            wait ${VMKF_PID}; if [ $? -ne 0 ]; then log_error "Fehler beim Klonen von Disk ${DISK_IDX}"; OVERALL_STATUS="ERROR"; continue; fi
            rm -f "${VMKF_LOG}"
            
            log "     ...Transferieren..."
            SOURCE_SIZE_TAR=$(du -sh "${TEMP_CLONE_DIR}" | awk '{print $1}')
            ( (cd "${TEMP_CLONE_DIR}" && tar -cf - .) | ssh ${SSH_OPTS} root@${TARGET_HOST} "tar -xf - -C '${TARGET_VM_PATH}'" ) &
            TAR_PID=$!
            while kill -0 ${TAR_PID} >/dev/null 2>&1; do
                PROGRESS=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "du -sh '${TARGET_VM_PATH}' 2>/dev/null | awk '{print \$1}'")
                if [ -n "${PROGRESS}" ]; then log "Transfer: ${SOURCE_VM_NAME} ${PROGRESS} (~${SOURCE_SIZE_TAR})"; fi
                sleep 30
            done
            wait ${TAR_PID}; if [ $? -ne 0 ]; then log_error "Fehler beim Transfer von Disk ${DISK_IDX}"; OVERALL_STATUS="ERROR"; fi
            rm -rf "${TEMP_CLONE_DIR}"/*

            # --- LIVE LOG HOLE PUNCHING (HOT) ---
            if [ "${DISK_FORMAT}" = "thin" ] && [ "${DISABLE_PUNCH}" != "1" ]; then
                log "     ...Optimiere Speicherplatz auf Ziel (Hole Punching)..."
                ssh ${SSH_OPTS} root@${TARGET_HOST} "vmkfstools -K '${TARGET_VM_PATH}/${TARGET_FILENAME}'" 2>&1 | while read line; do log "        [Remote] $line"; done
            fi
            # ------------------------------------

            echo "/bin/sed -i 's|^${DEVICE_ID}.fileName.*|${DEVICE_ID}.fileName = \"${TARGET_FILENAME}\"|' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
            DISK_IDX=$((DISK_IDX+1))
        done < "${DISK_LIST_FILE}"
        rm -rf "${TEMP_CLONE_DIR}"; /bin/vim-cmd vmsvc/snapshot.removeall ${VMID}
        
        # --- LATE COPY ---
        log "[5/7] Kopiere Konfigurationsdateien (LATE + 2-STEP)..."
        VMX_FILE_NAME=$(/usr/bin/basename "${VMX_FULL_PATH}")
        VM_NVRAM_FILE=$(/bin/grep -i 'nvram' "${VMX_FULL_PATH}" | /usr/bin/awk -F '"' '{print $2}')
        
        SCP_OUT=$(scp ${SCP_OPTS} "${VMX_FULL_PATH}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${VMX_FILE_NAME}" 2>&1)
        if [ $? -ne 0 ]; then log_error "SCP VMX Failed: ${SCP_OUT}"; else log "SCP VMX OK."; fi
        
        ssh ${SSH_OPTS} root@${TARGET_HOST} "cd '${TARGET_VM_PATH}' && mv '${VMX_FILE_NAME}' '${REPLICATED_VM_NAME}.vmx'"
        
        if [ -n "${VM_NVRAM_FILE}" ]; then scp ${SCP_OPTS} "${VMX_DIR}/${VM_NVRAM_FILE}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${VM_NVRAM_FILE}" < /dev/null; fi

    elif [ "${REPLICATION_METHOD}" = "robust" ] && [ "${VM_POWER_STATE}" = "off" ]; then
        # --- COLD COPY ---
        log "[4/7] Führe COLD-COPY via SCP aus (mit Fortschritt)..."
        CLONE_ERROR=0
        while read -r line; do
            DEVICE_ID=$(echo "$line" | awk -F. '{print $1}' | awk '{print $1}')
            VMX_DISK_PATH=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p');
            if [ -z "${VMX_DISK_PATH}" ]; then continue; fi
            if echo "${VMX_DISK_PATH}" | grep -q "^/"; then SOURCE_DISK_PATH="${VMX_DISK_PATH}"; else SOURCE_DISK_PATH="${VMX_DIR}/${VMX_DISK_PATH}"; fi
            
            FLAT_FILENAME=$(grep "RW" "${SOURCE_DISK_PATH}" | grep ".vmdk" | awk '{print $4}' | sed 's/"//g')
            SOURCE_FLAT_PATH="$(dirname "${SOURCE_DISK_PATH}")/${FLAT_FILENAME}"
            if [ ! -f "${SOURCE_FLAT_PATH}" ]; then SOURCE_FLAT_PATH="${SOURCE_DISK_PATH%.*}-flat.vmdk"; fi
            if [ ! -f "${SOURCE_DISK_PATH}" ]; then log_error "VMDK nicht gefunden: ${SOURCE_DISK_PATH}"; CLONE_ERROR=1; break; fi
            
            SRC_BASENAME_ONLY=$(basename "${VMX_DISK_PATH}" .vmdk)
            IDX_STR=$(printf "%02d" ${DISK_IDX})
            TARGET_DISK_NAME="${SRC_BASENAME_ONLY}${VM_SUFFIX}-${IDX_STR}.vmdk"
            TARGET_FLAT_NAME="${SRC_BASENAME_ONLY}${VM_SUFFIX}-${IDX_STR}-flat.vmdk"
            
            log "  -> Processing ${DEVICE_ID}: ${SRC_BASENAME_ONLY}"
            scp ${SCP_OPTS} "${SOURCE_DISK_PATH}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${TARGET_DISK_NAME}" < /dev/null
            
            scp ${SCP_OPTS} -C "${SOURCE_FLAT_PATH}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${TARGET_FLAT_NAME}" < /dev/null &
            SCP_PID=$!
            while kill -0 ${SCP_PID} >/dev/null 2>&1; do
                 CURRENT_SIZE=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "du -sh '${TARGET_VM_PATH}/${TARGET_FLAT_NAME}' 2>/dev/null | awk '{print \$1}'")
                 if [ -n "${CURRENT_SIZE}" ]; then log "Cold-Copy: ${SOURCE_VM_NAME} ${CURRENT_SIZE} (~${SOURCE_SIZE_TAR})"; fi
                 sleep 15
            done
            wait ${SCP_PID}
            if [ $? -ne 0 ]; then CLONE_ERROR=1; log_error "SCP Fehler beim Kopieren der Flat-File!"; break; fi

            # --- V56.5 FIX: RENAME FLAT IN DESCRIPTOR BEFORE PUNCHING ---
            ssh -n ${SSH_OPTS} root@${TARGET_HOST} "sed -i 's/${FLAT_FILENAME}/${TARGET_FLAT_NAME}/g' '${TARGET_VM_PATH}/${TARGET_DISK_NAME}'"
            # -------------------------------------------------------------

            # --- LIVE LOG HOLE PUNCHING (COLD) ---
            if [ "${DISK_FORMAT}" = "thin" ] && [ "${DISABLE_PUNCH}" != "1" ]; then
                log "     ...Optimiere Speicherplatz auf Ziel (Hole Punching)..."
                ssh ${SSH_OPTS} root@${TARGET_HOST} "vmkfstools -K '${TARGET_VM_PATH}/${TARGET_DISK_NAME}'" 2>&1 | while read line; do log "        [Remote] $line"; done
            fi
            # -------------------------------------

            echo "/bin/sed -i 's|^${DEVICE_ID}.fileName.*|${DEVICE_ID}.fileName = \"${TARGET_DISK_NAME}\"|' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
            DISK_IDX=$((DISK_IDX+1))
        done < "${DISK_LIST_FILE}"
        if [ ${CLONE_ERROR} -ne 0 ]; then OVERALL_STATUS="ERROR"; continue; fi
        
        # --- COLD COPY FINALE ---
        log "[5/7] Kopiere Konfigurationsdateien..."
        VMX_FILE_NAME=$(/usr/bin/basename "${VMX_FULL_PATH}")
        VM_NVRAM_FILE=$(/bin/grep -i 'nvram' "${VMX_FULL_PATH}" | /usr/bin/awk -F '"' '{print $2}')
        
        # 1. Copy ORIGINAL filename
        scp ${SCP_OPTS} "${VMX_FULL_PATH}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${VMX_FILE_NAME}" < /dev/null
        # 2. Rename
        ssh ${SSH_OPTS} root@${TARGET_HOST} "cd '${TARGET_VM_PATH}' && mv '${VMX_FILE_NAME}' '${REPLICATED_VM_NAME}.vmx'"
        
        if [ -n "${VM_NVRAM_FILE}" ]; then scp ${SCP_OPTS} "${VMX_DIR}/${VM_NVRAM_FILE}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${VM_NVRAM_FILE}" < /dev/null; fi
        
    else
        log_error "FEHLER: Unbekannte Methode oder inkompatibler PowerState."
        OVERALL_STATUS="ERROR"; continue
    fi
    
    rm -f "${DISK_LIST_FILE}"

    log "[6/7] Passe Zieldateien an..."
    TARGET_PATCH_SCRIPT="${TARGET_VM_PATH}/patch_vmx.sh"
    scp ${SCP_OPTS} "${PATCH_SCRIPT}" root@${TARGET_HOST}:"${TARGET_PATCH_SCRIPT}" < /dev/null
    ssh ${SSH_OPTS} root@${TARGET_HOST} "chmod +x '${TARGET_PATCH_SCRIPT}' && '${TARGET_PATCH_SCRIPT}' && rm '${TARGET_PATCH_SCRIPT}'"
    rm -f "${PATCH_SCRIPT}"
    
    log "Warte 10 Sekunden auf Dateisystem-Update (ESXi 6 Fix)..."
    sleep 10

    log "[7/7] Registriere VM..."
    REG_OUT=$(ssh ${SSH_OPTS} root@${TARGET_HOST} "vim-cmd solo/registervm '${TARGET_VM_PATH}/${REPLICATED_VM_NAME}.vmx'" 2>&1)
    
    # --- SYNTAX FIX V56.4 ---
    if echo "${REG_OUT}" | grep -qE '^[0-9]+$'; then 
        log "  -> VM erfolgreich registriert (ID: ${REG_OUT})."
    elif echo "${REG_OUT}" | grep -q "AlreadyExists"; then 
        log "  -> INFO: VM war bereits registriert."
    else 
        log "  -> Registrierung Warnung: ${REG_OUT}"
    fi
    # ------------------------

    if [ "${VM_POWER_STATE}" = "on" ]; then log "-> Hot-Replikation abgeschlossen."; else log "-> Cold-Replikation abgeschlossen."; fi
    VM_SIZE=$(ssh ${SSH_OPTS} root@${TARGET_HOST} "du -sh '${TARGET_VM_PATH}'" < /dev/null | awk '{print $1}')
    if [ -n "${VM_SIZE}" ]; then VM_REPORT_LIST="${VM_REPORT_LIST}- ${REPLICATED_VM_NAME}: ${VM_SIZE}\n"; fi
done

if [ -n "${TARGET_VM_PATH}" ]; then
    log "Hole Verzeichnis-Listing..."
    DIRECTORY_LISTING_CONTENT=$(ssh ${SSH_OPTS} root@${TARGET_HOST} "ls -lh '${TARGET_VM_PATH}' 2>/dev/null")
fi

log "====== MULTI-VM REPLICATION HELPER BEENDET (ID: ${UNIQUE_ID}) ======"
trap - EXIT
cleanup
'@

# ---------------------------------------------------------------------
# ============ ENDE MAsterHelperScript Template-Geplante REPLIKATION ======
# ---------------------------------------------------------------------

$buttonReplicate.Add_Click({
    # Vorerst öffnet der Button nur das neue Fenster.
      $replicationForm.ShowDialog($form) | Out-Null
})


# --- Event-Handler für "..." Button im DIREKTEN Replikations-Fenster ---

$buttonBrowseDrTargetDs.Add_Click({
    $targetHost = $textboxDrTargetHost.Text
    $targetUser = $textboxDrTargetUser.Text

    if ([string]::IsNullOrWhiteSpace($targetHost) -or [string]::IsNullOrWhiteSpace($targetUser)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte geben Sie zuerst die IP und den User des Ziel-Hosts an.", "Fehlende Eingabe", "OK", "Warning")
        return
    }

    # Funktion, um den Dialog anzuzeigen (vermeidet Code-Dopplung)
    $showDialog = {
        param($session)
        $selectedPath = Show-DatastoreSelectionDialog -SSHSession $session
        if ($selectedPath) {
            $textboxDrTargetDs.Text = $selectedPath
        }
    }

    # Prüfen, ob eine passende Verbindung bereits existiert
    if ($Global:TargetESXiSession -and $Global:TargetESXiSession.Connected -and $Global:TargetESXiSession.ComputerName -eq $targetHost) {
        # Ja, Verbindung ist bereits vorhanden und korrekt. Dialog direkt anzeigen.
        & $showDialog -session $Global:TargetESXiSession
    } else {
        # Nein, wir brauchen eine neue Verbindung.
        if ($Global:TargetESXiSession) { Remove-SSHSession -SSHSession $Global:TargetESXiSession -ErrorAction SilentlyContinue }

        Write-GuiLog "Stelle Verbindung zum Ziel-Host $targetHost her, um Datastores zu durchsuchen..."
        try {
            $targetCredential = Show-CredentialPrompt -UserName $targetUser -Message "Passwort für Ziel-Host $targetUser@$targetHost eingeben:"
            if (-not $targetCredential) { Write-GuiLog "Passworteingabe für Ziel-Host abgebrochen."; return }

            $Global:TargetESXiSshCredential = $targetCredential
            $Global:TargetESXiSession = New-SSHSession -ComputerName $targetHost -Credential $targetCredential -ErrorAction Stop -AcceptKey -ConnectionTimeout 60

            if ($Global:TargetESXiSession.Connected) {
                Write-GuiLog "Verbindung zum Ziel-Host erfolgreich."
                # Verbindung wurde erfolgreich hergestellt. Dialog jetzt anzeigen.
                & $showDialog -session $Global:TargetESXiSession
            }
        }
        catch {
            Write-GuiLog "FEHLER bei der Verbindung zum Ziel-Host: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Verbindung zum Ziel-Host fehlgeschlagen.`n`n$($_.Exception.Message)", "Verbindungsfehler", "OK", "Error")
            $Global:TargetESXiSession = $null
            $Global:TargetESXiSshCredential = $null
        }
    }
})

# =====================================================================================
# --- START BLOCK (Phase 1.6: Finaler Button und Timer) ---
# =====================================================================================

$buttonDirectReplicate.Add_Click({
    # --- Vorab-Prüfungen ---
    if ($checkedListBoxVms.CheckedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Bitte wähle mindestens eine VM für die Replikation aus.", "Keine Auswahl", "OK", "Warning"); return
    }

    # Lade die aktuellen Einstellungen aus den zentralen Variablen in das Popup-Fenster
    $checkboxUseLocalTemp.Checked = $script:replicationUseLocalTemp
    $textboxDrTempPath.Text = $script:replicationTempPath

    # --- Replikations-Dialog anzeigen ---
    $dialogResult = $directReplicationForm.ShowDialog($form)
    
    # Wenn der Benutzer den Dialog schliesst, speichere die Einstellungen in die zentralen Variablen zurück
    $script:replicationUseLocalTemp = $checkboxUseLocalTemp.Checked
    $script:replicationTempPath = $textboxDrTempPath.Text

    if ($dialogResult -ne 'OK') {
        Write-GuiLog "Direkte Replikation vom Benutzer im Dialog abgebrochen."
        return
    }
    
    # Sicherheitsabfrage, wenn die Offline-Methode gewählt wurde
    if ($directReplicationForm.Controls.Find('radioVmkf', $true)[0].Checked) {
        $message = "Die ausgewählte Replikationsmethode fährt die Quell-VM(s) für die Dauer des Kopiervorgangs herunter.`n`nWollen Sie wirklich fortfahren?"
        $title = "Bestätigung: VM(s) werden heruntergefahren"
        $buttons = [System.Windows.Forms.MessageBoxButtons]::YesNo
        $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
        $confirmResult = [System.Windows.Forms.MessageBox]::Show($message, $title, $buttons, $icon)
        if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-GuiLog "Offline-Replikation vom Benutzer abgebrochen."; return
        }
    }

    # --- Passwortlose SSH-Verbindung prüfen ---
    Write-GuiLog "Prüfe passwortlose SSH-Verbindung von Quelle zu Ziel..."
    $testCmd = "ssh -i /.ssh/id_ecdsa -o 'StrictHostKeyChecking=no' -o 'ConnectTimeout=10' root@$($textboxDrTargetHost.Text) `"echo 'SSH_OK'`""
    $testResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $testCmd
    if (($testResult.Output -join '').Trim() -ne 'SSH_OK') {
        [System.Windows.Forms.MessageBox]::Show("Die passwortlose SSH-Verbindung vom Quell- zum Ziel-Host ist für diese Funktion zwingend erforderlich.`n`nBitte richte sie über die SSH-Konsole ein.", "SSH-Fehler", "OK", "Error"); return
    }
    Write-GuiLog "-> Passwortlose Verbindung ist funktionsfähig. Warte 60 sec."

    # --- START DER NEUEN LOGIK: Ein Job für alle VMs ---
    Get-Job | Where-Object { $_.Name -like 'GhettoReplWatcher' } | Remove-Job -Force
    
    $uniqueId = "{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Minimum 100 -Maximum 999)
    $selectedMethod = if ($directReplicationForm.Controls.Find('radioVmkf', $true)[0].Checked) { 'stream' } else { 'robust' }
    $tempPath = if ($checkboxUseLocalTemp.Checked) { "" } else { $textboxDrTempPath.Text.TrimEnd('/') }
    
    # Alle ausgewählten VMs in eine Liste packen
    $vmsToReplicate = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }) -join "`n"
    # NEU: Speichere die VM-Namen für die spätere Erfolgsmeldung
    $Global:currentJobTargetName = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }) -join ", "

   
    $params = @{
        UniqueId          = $uniqueId;
        VmList            = $vmsToReplicate;
        SourceHost        = $Global:ESXiConnectedHostName;
		DiskFormat        = $comboboxDiskFormat.SelectedItem.ToString();
        DisablePunch      = if ($checkboxDisablePunch.Checked) { "1" } else { "0" };
	    TargetHost        = $textboxDrTargetHost.Text; TargetDatastore = $textboxDrTargetDs.Text; Suffix = $textboxDrSuffix.Text;
        ReplicationMethod = $selectedMethod; TempPath = $tempPath;
        SnapMem           = if ($checkboxSnapMem.Checked) { 1 } else { 0 }; SnapQuiesce = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 };
        GhettoPath        = $textboxGhettoPath.Text;
        EmailEnabled      = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EmailTo = $textboxEmailTo.Text;
        EmailFrom         = $textboxEmailFrom.Text; EmailServer = $textboxEmailServer.Text; EmailPort = $textboxEmailPort.Text;
		EmailDisplayName  = $textboxEmailDisplay.Text;
        EmailUser         = $textboxEmailUser.Text; EmailPass = $textboxEmailPassword.Text;
        EmailSubject      = "[Manuell-Repl.]" + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName)
    }
#---------------------------------------------------------------------------------

#---------------------------------------------------------------------------------
# GhettoGUI Multi-VM Replication Helper - V54.24 (Manual - Disable Punch Option)
# - FEATURE: Support for 'Disable Hole Punching' checkbox (__DISABLE_PUNCH__).
# - BASE: Includes Auto-Fallback, Auto-Cleanup, Live-Log, Safe Size.
#---------------------------------------------------------------------------------

$multiVmScriptTemplate = @'
#!/bin/sh
# GhettoGUI Multi-VM Replication Helper V54.24 (Manual - Opt-Out Punching)

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin
export PATH

# 1. PARAMETER
UNIQUE_ID='__UNIQUE_ID__'; TARGET_HOST='__TARGET_HOST__'; TARGET_DATASTORE='__TARGET_DATASTORE__'; VM_SUFFIX='__VM_SUFFIX__'; REPLICATION_METHOD='__REPLICATION_METHOD__'; GHETTO_PATH='__GHETTO_PATH__';
# Disk Format & Options
DISK_FORMAT='__DISK_FORMAT__';
DISABLE_PUNCH='__DISABLE_PUNCH__'; # 1 = Skip Punching

LOG_FILE="${GHETTO_PATH}/logs/master_replication_${UNIQUE_ID}.log";

# --- SSH CONFIGURATION ---
BASE_OPTS="-i /.ssh/id_ecdsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o BatchMode=yes -o Compression=no -o LogLevel=ERROR"
SSH_OPTS="-T ${BASE_OPTS}"
SCP_OPTS="${BASE_OPTS}"
# -------------------------

SNAP_MEM=__SNAP_MEM__; SNAP_QUIESCE=__SNAP_QUIESCE__; EMAIL_ENABLED=__EMAIL_ENABLED__; EMAIL_TO='__EMAIL_TO__'; EMAIL_FROM='__EMAIL_FROM__'; EMAIL_DISPLAY_NAME='__EMAIL_DISPLAY_NAME__'; EMAIL_SERVER='__EMAIL_SERVER__'; EMAIL_PORT='__EMAIL_PORT__'; EMAIL_USER='__EMAIL_USER__'; EMAIL_PASS='__EMAIL_PASS__'; EMAIL_SUBJECT='__EMAIL_SUBJECT__'; SENDMAIL_PATH="${GHETTO_PATH}/sendmail"; VM_LIST='
__VM_LIST__
'; OVERALL_STATUS="OK";
TEMP_CLONE_BASE_PATH='__TEMP_CLONE_BASE_PATH__';

# --- LOCK FILE CHECK ---
LOCK_DIR="/tmp/ghetto_job_manual_${UNIQUE_ID}.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then exit 0; fi
trap 'cleanup; rm -rf "${LOCK_DIR}";' EXIT HUP INT QUIT TERM

# --- Helpers ---
DS_SEARCH_TERM=$(basename "${TARGET_DATASTORE}")
VM_REPORT_LIST=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -> $1" >> ${LOG_FILE}; sync; }
log_raw() { echo "$1" >> ${LOG_FILE}; sync; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; sync; }

send_email_notification() {
    DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi;
    log_raw "\n--- Zusammenfassung der geklonten VMs ---"
    log_raw "${VM_REPORT_LIST}"
    log_raw "-----------------------------------------"
    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: All VMs backed up OK! ##"; else FINAL_STATUS_MSG="## Final status: ERROR: Replication failed! ##"; fi;
    log "Bereite E-Mail vor: ${OVERALL_STATUS}"; log_raw "Backup Duration: ${DURATION_MSG}"; log_raw "${FINAL_STATUS_MSG}";
    
    if [ -n "${DIRECTORY_LISTING_CONTENT}" ]; then
        log_raw "\n--- START Backup Directory Listing ---"
        log_raw "${DIRECTORY_LISTING_CONTENT}"
        log_raw "--- END Backup Directory Listing ---"
    fi

    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/,/ /g')
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -N "${EMAIL_DISPLAY_NAME}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1
    fi
}

cleanup() {
    EXIT_CODE=$?
    if [ ${EXIT_CODE} -ne 0 ] && [ "${OVERALL_STATUS}" = "OK" ]; then
        log_error "Skript wurde mit Fehlercode ${EXIT_CODE} beendet. Setze Status auf ERROR."
        OVERALL_STATUS="ERROR"
    fi
    trap - EXIT
    
    FINAL_SIZE=$(ssh ${SSH_OPTS} root@${TARGET_HOST} "du -sch ${TARGET_DATASTORE}/*${VM_SUFFIX} 2>/dev/null | grep total" | awk '{print $1}')
    if [ -z "${FINAL_SIZE}" ]; then FINAL_SIZE="N/A"; fi
    log_raw "Final size: ${FINAL_SIZE}"
    
    STORAGE_INFO=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "esxcli storage filesystem list | grep '${DS_SEARCH_TERM}' | awk '{ printf \"Total: %.2f GB | Frei: %.2f GB\", \$6/1073741824, \$7/1073741824 }'" < /dev/null)
    log_raw "Speicherplatz (Nachher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): ${STORAGE_INFO}"; 
    
    log_raw "--- ENDE DES DETAILLOGS ---"; END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S'); log_raw "Endzeit: ${END_TIME_S}"; END_TIME=$(date +%s);
    DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden"
    send_email_notification "${DURATION_STRING}";
    log "====== MULTI-VM REPLICATION HELPER BEENDET (ID: ${UNIQUE_ID}) ======";
}

# --- Skriptstart ---
rm -f ${LOG_FILE}; mkdir -p "${GHETTO_PATH}/logs"; START_TIME=$(date +%s)
trap cleanup EXIT
log "====== MULTI-VM REPLICATION HELPER GESTARTET (ID: ${UNIQUE_ID}) ======"; log_raw "Startzeit: $(date '+%Y-%m-%d %H:%M:%S')";

# --- Connection Check ---
log "Prüfe Verbindung zu ${TARGET_HOST}..."
if ! ssh ${SSH_OPTS} root@${TARGET_HOST} "echo OK" >/dev/null 2>&1; then
    log_error "FATAL: Keine SSH-Verbindung zu ${TARGET_HOST} möglich (Check Keys/IP). Abbruch."
    OVERALL_STATUS="ERROR"
    exit 1
fi

# --- Infos sammeln ---
SRC_HOSTNAME=$(hostname)
SRC_IP=$(esxcli network ip interface ipv4 get | grep vmk0 | awk '{print $2}')
if [ -z "${SRC_IP}" ]; then SRC_IP=$(esxcli network ip interface ipv4 get | awk 'NR>2 {print $2; exit}'); fi
TARGET_HOSTNAME=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "hostname" 2>/dev/null || echo "Unknown")
TARGET_DS_NAME=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "esxcli storage filesystem list | grep '${TARGET_DATASTORE}' | awk '{print \$2}'" 2>/dev/null || echo "${TARGET_DATASTORE}")

log_raw "Job-Konfiguration:"
log_raw "  - Typ: Manuelle Replikation (H2H) V8.4.4"
log_raw "  - Methode: ${REPLICATION_METHOD}"
log_raw "  - Disk-Format: ${DISK_FORMAT} (Punching deaktiviert: ${DISABLE_PUNCH})"
log_raw "  - Quell-Host: ${SRC_IP} (${SRC_HOSTNAME})"
log_raw "  - Ziel-Host: ${TARGET_HOST} (${TARGET_HOSTNAME})"
log_raw "  - Ziel-Datastore: ${TARGET_DS_NAME}"

STORAGE_INFO_PRE=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "esxcli storage filesystem list | grep '${DS_SEARCH_TERM}' | awk '{ printf \"Total: %.2f GB | Frei: %.2f GB\", \$6/1073741824, \$7/1073741824 }'" < /dev/null)
log_raw "Speicherplatz (Vorher):"; log_raw "  - Ziel (${TARGET_DATASTORE}): ${STORAGE_INFO_PRE}"; 
log_raw "--- START DES DETAILLOGS ---"
sync

CLONE_ERROR_FLAG="/tmp/clone_error_manual_${UNIQUE_ID}.flag"
rm -f $CLONE_ERROR_FLAG
CLEAN_VM_LIST=$(echo "${VM_LIST}" | sed '/^$/d')

for SOURCE_VM_NAME in ${CLEAN_VM_LIST}; do
    log "#################### Starte Verarbeitung für VM: ${SOURCE_VM_NAME} ########V54.24############"
    
    REPLICATED_VM_NAME="${SOURCE_VM_NAME}${VM_SUFFIX}"
    if echo "${TARGET_DATASTORE}" | grep -q "^/vmfs/volumes"; then
        TARGET_VM_PATH="${TARGET_DATASTORE}/${REPLICATED_VM_NAME}"
    else
        TARGET_VM_PATH="/vmfs/volumes/${TARGET_DATASTORE}/${REPLICATED_VM_NAME}"
    fi

    log "initiate backup for ${SOURCE_VM_NAME}"
    VM_INFO_LINE=$(vim-cmd vmsvc/getallvms | awk -v name="${SOURCE_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $0; }'); if [ -z "${VM_INFO_LINE}" ]; then log_error "[${SOURCE_VM_NAME}] - VM nicht gefunden!"; OVERALL_STATUS="ERROR"; continue; fi
    VMID=$(echo "${VM_INFO_LINE}" | awk '{print $1}'); VMX_FULL_PATH=$(echo "${VM_INFO_LINE}" | sed -e 's/.*\[\(.*\)\]\s*\(.*\.vmx\).*/\/vmfs\/volumes\/\1\/\2/'); VMX_DIR=$(dirname "${VMX_FULL_PATH}")

    # Power State
    VM_POWER_STATE=$(vim-cmd vmsvc/power.getstate ${VMID} | grep -i "Powered" | awk '{print $NF}')
    log "INFO: VM Power State: ${VM_POWER_STATE}"
    
    log "[1/7] Bereinige alte Replikation..."
    REMOTE_LIST_FILE="/tmp/target_vms_${UNIQUE_ID}.txt"
    ssh ${SSH_OPTS} root@${TARGET_HOST} "vim-cmd vmsvc/getallvms" > "${REMOTE_LIST_FILE}" 2>/dev/null
    TARGET_VMID=$(awk -v name="${REPLICATED_VM_NAME}" '$2 == name {print $1}' "${REMOTE_LIST_FILE}")
    rm -f "${REMOTE_LIST_FILE}"
    
    if [ -n "${TARGET_VMID}" ] && echo "${TARGET_VMID}" | grep -qE '^[0-9]+$'; then
        log "      -> Alte VM gefunden (ID: ${TARGET_VMID}). Lösche..."
        ssh ${SSH_OPTS} root@${TARGET_HOST} "vim-cmd vmsvc/power.off ${TARGET_VMID} >/dev/null 2>&1 || true; sleep 2; vim-cmd vmsvc/unregister ${TARGET_VMID} >/dev/null 2>&1" < /dev/null
    else
        log "      -> Keine registrierte alte VM gefunden (OK)."
    fi

    log "[2/7] Erstelle Zielverzeichnis..."; ssh ${SSH_OPTS} root@${TARGET_HOST} "rm -rf '${TARGET_VM_PATH}'; mkdir -p '${TARGET_VM_PATH}'" < /dev/null
    sleep 2

    # Patch Script Init
    PATCH_SCRIPT="/tmp/patch_vmx_${UNIQUE_ID}.sh"
    echo "#!/bin/sh" > "${PATCH_SCRIPT}"
    echo "cd '${TARGET_VM_PATH}' || exit 1" >> "${PATCH_SCRIPT}"
    echo "RENAMED_VMX_FILE=\"./${REPLICATED_VM_NAME}.vmx\"" >> "${PATCH_SCRIPT}"
    echo "if [ ! -f \"\${RENAMED_VMX_FILE}\" ]; then echo 'FATAL: VMX File missing after Rename'; exit 1; fi" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i '/sched.swap.derivedName/d' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i '/vc.uuid/d' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i '/migrate.hostLog/d' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i 's/displayName = .*/displayName = \"${REPLICATED_VM_NAME}\"/' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i '/msg.autoAnswer/d' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "/bin/sed -i '/^uuid.action/d' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "echo 'msg.autoAnswer = \"FALSE\"' >> \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
    echo "echo 'uuid.action = \"prompt\"' >> \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"

    DISK_IDX=0
    DISK_LIST_FILE="/tmp/disk_list_${UNIQUE_ID}.txt"
    grep -iE 'scsi[0-9]+:[0-9]+\.fileName' "${VMX_FULL_PATH}" > "${DISK_LIST_FILE}"

    if [ "${REPLICATION_METHOD}" = "robust" ] && [ "${VM_POWER_STATE}" = "on" ]; then
        # --- HOT CLONE ---
        if [ -z "${TEMP_CLONE_BASE_PATH}" ]; then TEMP_CLONE_CHECK_PATH="${VMX_DIR}"; else TEMP_CLONE_CHECK_PATH="${TEMP_CLONE_BASE_PATH}"; fi
        log "[0/7] Prüfe Speicherplatz für Temp-Klon..."
        
        # --- CLEANUP LEFTOVERS ---
        if vim-cmd vmsvc/snapshot.get ${VMID} | grep -q "ghetto-repl"; then
            log "WARNUNG: Alter, abgebrochener Replikations-Snapshot gefunden. Führe Konsolidierung durch (kann dauern)..."
            vim-cmd vmsvc/snapshot.removeall ${VMID}
            sleep 15
            log "       -> Konsolidierung abgeschlossen."
        fi
        
        log "[4/7] Starte ONLINE Replikation (Snapshot)..."; 
        
        # --- AUTO-FALLBACK LOGIC ---
        vim-cmd vmsvc/snapshot.create ${VMID} "ghetto-repl-${UNIQUE_ID}" "Ghetto" ${SNAP_MEM} ${SNAP_QUIESCE} > /dev/null 2>&1
        SNAP_EXIT_CODE=$?
        
        if [ ${SNAP_EXIT_CODE} -ne 0 ] && [ "${SNAP_QUIESCE}" = "1" ]; then
            log "WARNUNG: Snapshot mit Quiescing fehlgeschlagen. Versuche Crash-Consistent Snapshot..."
            vim-cmd vmsvc/snapshot.create ${VMID} "ghetto-repl-${UNIQUE_ID}" "Ghetto" ${SNAP_MEM} 0 > /dev/null 2>&1
            SNAP_EXIT_CODE=$?
        fi
        
        if [ ${SNAP_EXIT_CODE} -ne 0 ]; then
            log_error "FATAL: Snapshot konnte nicht erstellt werden. Abbruch für ${SOURCE_VM_NAME}."
            OVERALL_STATUS="ERROR"
            continue
        fi
        log "INFO: Snapshot erfolgreich erstellt."
        sleep 15

        if [ -z "${TEMP_CLONE_BASE_PATH}" ]; then TEMP_CLONE_DIR="${VMX_DIR}/ghetto_clone_${UNIQUE_ID}"; else TEMP_CLONE_DIR="${TEMP_CLONE_BASE_PATH}/ghetto_clone_${UNIQUE_ID}"; fi; rm -rf "${TEMP_CLONE_DIR}"; mkdir -p "${TEMP_CLONE_DIR}"
        
        while read -r line; do
            DEVICE_ID=$(echo "$line" | awk -F. '{print $1}' | awk '{print $1}')
            VMX_DISK_PATH=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p');
            if [ -z "${VMX_DISK_PATH}" ]; then continue; fi
            VMX_DISK_PATH_BASE=$(echo "${VMX_DISK_PATH}" | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/');
            if echo "${VMX_DISK_PATH_BASE}" | grep -q "^/"; then SOURCE_DISK_PATH_FOR_CLONE="${VMX_DISK_PATH_BASE}"; else SOURCE_DISK_PATH_FOR_CLONE="${VMX_DIR}/${VMX_DISK_PATH_BASE}"; fi
            SRC_BASENAME_ONLY=$(basename "${VMX_DISK_PATH_BASE}" .vmdk)
            IDX_STR=$(printf "%02d" ${DISK_IDX})
            TARGET_FILENAME="${SRC_BASENAME_ONLY}${VM_SUFFIX}-${IDX_STR}.vmdk"
            DESTINATION_DISK_PATH="${TEMP_CLONE_DIR}/${TARGET_FILENAME}"
            
            log "  -> Processing Disk ${DISK_IDX}: ${SRC_BASENAME_ONLY}"
            log "     ...Klonen nach Temp gestartet..."
            VMKF_LOG="/tmp/vmkf_progress_${UNIQUE_ID}_${DISK_IDX}.log"
            /sbin/vmkfstools -i "${SOURCE_DISK_PATH_FOR_CLONE}" -d ${DISK_FORMAT} "${DESTINATION_DISK_PATH}" > "${VMKF_LOG}" 2>&1 &
            VMKF_PID=$!
            while kill -0 ${VMKF_PID} >/dev/null 2>&1; do
                PROGRESS_LINE=$(tr '\r' '\n' < "${VMKF_LOG}" | grep "%" | tail -n 1)
                if [ -n "${PROGRESS_LINE}" ]; then log "     ...${PROGRESS_LINE}"; else CURRENT_CLONE_SIZE=$(du -sh "${TEMP_CLONE_DIR}" 2>/dev/null | awk '{print $1}'); if [ -n "${CURRENT_CLONE_SIZE}" ]; then log " Klonen ${SOURCE_VM_NAME}: ${CURRENT_CLONE_SIZE} (~${SOURCE_SIZE_TAR}))"; fi; fi
                sleep 30
            done
            wait ${VMKF_PID}
            
            if [ $? -ne 0 ]; then 
                log_error "Fehler beim Klonen von Disk ${DISK_IDX}. Details:"
                cat "${VMKF_LOG}" | while read errline; do log_error "  [VMK-ERR] $errline"; done
                OVERALL_STATUS="ERROR"
                rm -f "${VMKF_LOG}"
                continue
            fi
            rm -f "${VMKF_LOG}"
            
            log "     ...Transferieren..."
            
            TEMP_FLAT_NAME=$(echo "${TARGET_FILENAME}" | sed 's/\.vmdk/-flat.vmdk/')
            TEMP_FLAT_PATH="${TEMP_CLONE_DIR}/${TEMP_FLAT_NAME}"
            if [ -f "${TEMP_FLAT_PATH}" ]; then SOURCE_SIZE_TAR=$(ls -lh "${TEMP_FLAT_PATH}" | awk '{print $5}'); else SOURCE_SIZE_TAR=$(du -sh "${TEMP_CLONE_DIR}" | awk '{print $1}'); fi
            
            ( (cd "${TEMP_CLONE_DIR}" && tar -cf - .) | ssh ${SSH_OPTS} root@${TARGET_HOST} "tar -xf - -C '${TARGET_VM_PATH}'" ) &
            TAR_PID=$!
            while kill -0 ${TAR_PID} >/dev/null 2>&1; do
                PROGRESS=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "du -sh '${TARGET_VM_PATH}' 2>/dev/null | awk '{print \$1}'")
                if [ -n "${PROGRESS}" ]; then log "Transfer ${SOURCE_VM_NAME}: ${PROGRESS} (Temp: ~${SOURCE_SIZE_TAR})"; fi
                sleep 30
            done
            wait ${TAR_PID}; if [ $? -ne 0 ]; then log_error "Fehler beim Transfer von Disk ${DISK_IDX}"; OVERALL_STATUS="ERROR"; fi
            rm -rf "${TEMP_CLONE_DIR}"/*

            echo "/bin/sed -i 's|^${DEVICE_ID}.fileName.*|${DEVICE_ID}.fileName = \"${TARGET_FILENAME}\"|' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
            DISK_IDX=$((DISK_IDX+1))
        done < "${DISK_LIST_FILE}"
        rm -rf "${TEMP_CLONE_DIR}"; /bin/vim-cmd vmsvc/snapshot.removeall ${VMID}
        
        log "[5/7] Kopiere Konfigurationsdateien (LATE + 2-STEP)..."
        VMX_FILE_NAME=$(/usr/bin/basename "${VMX_FULL_PATH}")
        VM_NVRAM_FILE=$(/bin/grep -i 'nvram' "${VMX_FULL_PATH}" | /usr/bin/awk -F '"' '{print $2}')
        SCP_OUT=$(scp ${SCP_OPTS} "${VMX_FULL_PATH}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${VMX_FILE_NAME}" 2>&1)
        ssh ${SSH_OPTS} root@${TARGET_HOST} "cd '${TARGET_VM_PATH}' && mv '${VMX_FILE_NAME}' '${REPLICATED_VM_NAME}.vmx'"
        if [ -n "${VM_NVRAM_FILE}" ]; then scp ${SCP_OPTS} "${VMX_DIR}/${VM_NVRAM_FILE}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${VM_NVRAM_FILE}" < /dev/null; fi

    elif [ "${REPLICATION_METHOD}" = "robust" ] && [ "${VM_POWER_STATE}" = "off" ]; then
        # --- COLD COPY ---
        log "[4/7] Führe COLD-COPY via SCP aus (mit Fortschritt)..."
        CLONE_ERROR=0
        while read -r line; do
            DEVICE_ID=$(echo "$line" | awk -F. '{print $1}' | awk '{print $1}')
            VMX_DISK_PATH=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p');
            if [ -z "${VMX_DISK_PATH}" ]; then continue; fi
            if echo "${VMX_DISK_PATH}" | grep -q "^/"; then SOURCE_DISK_PATH="${VMX_DISK_PATH}"; else SOURCE_DISK_PATH="${VMX_DIR}/${VMX_DISK_PATH}"; fi
            FLAT_FILENAME=$(grep "RW" "${SOURCE_DISK_PATH}" | grep ".vmdk" | awk '{print $4}' | sed 's/"//g')
            SOURCE_FLAT_PATH="$(dirname "${SOURCE_DISK_PATH}")/${FLAT_FILENAME}"
            if [ ! -f "${SOURCE_FLAT_PATH}" ]; then SOURCE_FLAT_PATH="${SOURCE_DISK_PATH%.*}-flat.vmdk"; fi
            if [ ! -f "${SOURCE_DISK_PATH}" ]; then log_error "VMDK nicht gefunden: ${SOURCE_DISK_PATH}"; CLONE_ERROR=1; break; fi
            
            SRC_BASENAME_ONLY=$(basename "${VMX_DISK_PATH}" .vmdk)
            IDX_STR=$(printf "%02d" ${DISK_IDX})
            TARGET_DISK_NAME="${SRC_BASENAME_ONLY}${VM_SUFFIX}-${IDX_STR}.vmdk"
            TARGET_FLAT_NAME="${SRC_BASENAME_ONLY}${VM_SUFFIX}-${IDX_STR}-flat.vmdk"
            
            if [ -f "${SOURCE_FLAT_PATH}" ]; then SOURCE_SIZE_DISPLAY=$(ls -lh "${SOURCE_FLAT_PATH}" | awk '{print $5}'); else SOURCE_SIZE_DISPLAY="N/A"; fi

            log "  -> Processing ${DEVICE_ID}: ${SRC_BASENAME_ONLY} (${SOURCE_SIZE_DISPLAY})"
            scp ${SCP_OPTS} "${SOURCE_DISK_PATH}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${TARGET_DISK_NAME}" < /dev/null
            scp ${SCP_OPTS} -C "${SOURCE_FLAT_PATH}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${TARGET_FLAT_NAME}" < /dev/null &
            SCP_PID=$!
            while kill -0 ${SCP_PID} >/dev/null 2>&1; do
                 CURRENT_SIZE=$(ssh -n ${SSH_OPTS} root@${TARGET_HOST} "du -sh '${TARGET_VM_PATH}/${TARGET_FLAT_NAME}' 2>/dev/null | awk '{print \$1}'")
                 if [ -n "${CURRENT_SIZE}" ]; then log "Cold-Copy: ${SOURCE_VM_NAME} ${CURRENT_SIZE} / ${SOURCE_SIZE_DISPLAY}"; fi
                 sleep 15
            done
            wait ${SCP_PID}
            if [ $? -ne 0 ]; then CLONE_ERROR=1; log_error "SCP Fehler beim Kopieren der Flat-File!"; break; fi

            ssh -n ${SSH_OPTS} root@${TARGET_HOST} "sed -i 's/${FLAT_FILENAME}/${TARGET_FLAT_NAME}/g' '${TARGET_VM_PATH}/${TARGET_DISK_NAME}'"
            echo "/bin/sed -i 's|^${DEVICE_ID}.fileName.*|${DEVICE_ID}.fileName = \"${TARGET_DISK_NAME}\"|' \"\${RENAMED_VMX_FILE}\"" >> "${PATCH_SCRIPT}"
            DISK_IDX=$((DISK_IDX+1))
        done < "${DISK_LIST_FILE}"
        if [ ${CLONE_ERROR} -ne 0 ]; then OVERALL_STATUS="ERROR"; continue; fi
        
        log "[5/7] Kopiere Konfigurationsdateien..."
        VMX_FILE_NAME=$(/usr/bin/basename "${VMX_FULL_PATH}")
        VM_NVRAM_FILE=$(/bin/grep -i 'nvram' "${VMX_FULL_PATH}" | /usr/bin/awk -F '"' '{print $2}')
        scp ${SCP_OPTS} "${VMX_FULL_PATH}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${VMX_FILE_NAME}" < /dev/null
        ssh ${SSH_OPTS} root@${TARGET_HOST} "cd '${TARGET_VM_PATH}' && mv '${VMX_FILE_NAME}' '${REPLICATED_VM_NAME}.vmx'"
        if [ -n "${VM_NVRAM_FILE}" ]; then scp ${SCP_OPTS} "${VMX_DIR}/${VM_NVRAM_FILE}" root@${TARGET_HOST}:"${TARGET_VM_PATH}/${VM_NVRAM_FILE}" < /dev/null; fi
        
    else
        log_error "FEHLER: Unbekannte Methode oder inkompatibler PowerState."
        OVERALL_STATUS="ERROR"; continue
    fi
    
    rm -f "${DISK_LIST_FILE}"

    log "[6/7] Passe Zieldateien an..."
    TARGET_PATCH_SCRIPT="${TARGET_VM_PATH}/patch_vmx.sh"
    scp ${SCP_OPTS} "${PATCH_SCRIPT}" root@${TARGET_HOST}:"${TARGET_PATCH_SCRIPT}" < /dev/null
    ssh ${SSH_OPTS} root@${TARGET_HOST} "chmod +x '${TARGET_PATCH_SCRIPT}' && '${TARGET_PATCH_SCRIPT}' && rm '${TARGET_PATCH_SCRIPT}'"
    rm -f "${PATCH_SCRIPT}"
    
    log "Warte 10 Sekunden auf Dateisystem-Update (ESXi 6 Fix)..."
    sleep 10
    
    # --- V54.24 OPTIONAL HOLE PUNCHING ---
    if [ "${DISK_FORMAT}" = "thin" ] && [ "${DISABLE_PUNCH}" != "1" ]; then
        log "[OPT] Starte Speicheroptimierung (Hole Punching) für alle Disks..."
        CMD_FIND="find '${TARGET_VM_PATH}' -type f -name '*.vmdk' ! -name '*-flat.vmdk' ! -name '*-delta.vmdk' ! -name '*-ctk.vmdk' ! -name '*-digest.vmdk'"
        
        ssh ${SSH_OPTS} root@${TARGET_HOST} "${CMD_FIND}" 2>/dev/null | while read DISK_FILE; do
            log "  -> Optimiere: ${DISK_FILE}"
            ssh ${SSH_OPTS} root@${TARGET_HOST} "vmkfstools -K '${DISK_FILE}'" 2>&1 | while read line; do log "     [Remote] $line"; done
        done
    fi
    # -------------------------------------

    log "[7/7] Registriere VM..."
    REG_OUT=$(ssh ${SSH_OPTS} root@${TARGET_HOST} "vim-cmd solo/registervm '${TARGET_VM_PATH}/${REPLICATED_VM_NAME}.vmx'" 2>&1)
    if echo "${REG_OUT}" | grep -qE '^[0-9]+$'; then log "  -> VM erfolgreich registriert (ID: ${REG_OUT})."; else log "  -> Registrierung Warnung: ${REG_OUT}"; fi
    if [ "${VM_POWER_STATE}" = "on" ]; then log "-> Hot-Replikation abgeschlossen."; else log "-> Cold-Replikation abgeschlossen."; fi
    VM_SIZE=$(ssh ${SSH_OPTS} root@${TARGET_HOST} "du -sh '${TARGET_VM_PATH}'" < /dev/null | awk '{print $1}')
    if [ -n "${VM_SIZE}" ]; then VM_REPORT_LIST="${VM_REPORT_LIST}- ${REPLICATED_VM_NAME}: ${VM_SIZE}\n"; fi
done

if [ -n "${TARGET_VM_PATH}" ]; then
    log "Hole Verzeichnis-Listing..."
    DIRECTORY_LISTING_CONTENT=$(ssh ${SSH_OPTS} root@${TARGET_HOST} "ls -lh '${TARGET_VM_PATH}' 2>/dev/null")
fi

log "====== MULTI-VM REPLICATION HELPER BEENDET (ID: ${UNIQUE_ID}) ======"
trap - EXIT
cleanup
'@

    $finalMasterScript = $multiVmScriptTemplate `
        -replace '__UNIQUE_ID__', $params.UniqueId `
        -replace '__VM_LIST__', $params.VmList `
        -replace '__TARGET_HOST__', $params.TargetHost `
        -replace '__TARGET_DATASTORE__', $params.TargetDatastore `
        -replace '__VM_SUFFIX__', $params.Suffix `
        -replace '__REPLICATION_METHOD__', $params.ReplicationMethod `
		-replace '__DISK_FORMAT__', $params.DiskFormat `
		-replace '__DISABLE_PUNCH__', $params.DisablePunch `
        -replace '__TEMP_CLONE_BASE_PATH__', $params.TempPath `
        -replace '__SNAP_MEM__', $params.SnapMem `
        -replace '__SNAP_QUIESCE__', $params.SnapQuiesce `
        -replace '__GHETTO_PATH__', $params.GhettoPath `
        -replace '__EMAIL_ENABLED__', $params.EmailEnabled `
        -replace '__EMAIL_TO__', $params.EmailTo `
        -replace '__EMAIL_FROM__', $params.EmailFrom `
		-replace '__EMAIL_DISPLAY_NAME__', $params.EmailDisplayName `
        -replace '__EMAIL_SERVER__', $params.EmailServer `
        -replace '__EMAIL_PORT__', $params.EmailPort `
        -replace '__EMAIL_USER__', $params.EmailUser `
        -replace '__EMAIL_PASS__', $params.EmailPass `
        -replace '__EMAIL_SUBJECT__', $params.EmailSubject
    
    $sftpSession = $null
    try {
        $remoteHelperPath = "/tmp/master_replication_$($params.UniqueId).sh"
        $launcherScriptPath = "/tmp/launcher_$($params.UniqueId).sh"
        $unixHelperScript = $finalMasterScript.Replace("`r`n", "`n")
        $sftpSession = New-SFTPSession -ComputerName $params.SourceHost -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
        Set-SFTPContent -SFTPSession $sftpSession -Path $remoteHelperPath -Value $unixHelperScript -Encoding UTF8
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$remoteHelperPath'" | Out-Null
        $launcherContent = "#!/bin/sh`nnohup sh '$remoteHelperPath' &"
        Set-SFTPContent -SFTPSession $sftpSession -Path $launcherScriptPath -Value $launcherContent -Encoding UTF8
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$launcherScriptPath'" | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Fehler beim Hochladen der Skripte: $($_.Exception.Message)", "Upload-Fehler", "OK", "Error"); return
    } finally {
        if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession }
    }

    $startCommand = "sh '$launcherScriptPath'"
    try {
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $startCommand -ErrorAction Stop
    } catch [System.Management.Automation.MethodInvocationException] {
        Write-GuiLog "-> INFO: Erwarteter Posh-SSH-Timeout. Das ist normal für Hintergrundprozesse."
    }

    $plainTextPassword = $Global:ESXiSshCredential.GetNetworkCredential().Password
    $jobParamsForWatcher = @{
        Host = $params.SourceHost; Username = $Global:ESXiSshCredential.UserName; PlainTextPassword = $plainTextPassword; RemoteLogPath = "$($params.GhettoPath)/logs/master_replication_$($params.UniqueId).log"
    }

    $Global:replicationJob = Start-Job -Name 'GhettoReplWatcher' -ScriptBlock { 
        param($p)
        Import-Module Posh-SSH -ErrorAction SilentlyContinue
        $securePassword = ConvertTo-SecureString $p.PlainTextPassword -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($p.Username, $securePassword)
        $watcherSession = $null
        try {
            Start-Sleep -Seconds 2
            $watcherSession = New-SSHSession -ComputerName $p.Host -Credential $cred -AcceptKey -ConnectionTimeout 60
            if (-not $watcherSession.Connected) { Write-Output "FEHLER: Watcher-Job konnte keine SSH-Verbindung herstellen."; return }
            $lastLineNumber = 0; $timeout = (Get-Date).AddHours(24)
            while ((Get-Date) -lt $timeout) {
                Start-Sleep -Seconds 5
                $checkFileCmd = "if [ -f '$($p.RemoteLogPath)' ]; then echo 'EXISTS'; fi"
                $fileExistsResult = Invoke-SSHCommand -SSHSession $watcherSession -Command $checkFileCmd
                $fileExists = ($fileExistsResult.Output -join '')
                if ($fileExists -eq 'EXISTS') {
                    $getNewLinesCmd = "tail -n +$($lastLineNumber + 1) '$($p.RemoteLogPath)'"
                    $newLinesResult = Invoke-SSHCommand -SSHSession $watcherSession -Command $getNewLinesCmd
                    if ($newLinesResult.Output) {
                        $lines = $newLinesResult.Output
                        foreach ($line in $lines) { Write-Output "$line" }
                        $lastLineNumber += $lines.Count
                        if ($lines[-1] -match "====== MULTI-VM REPLICATION HELPER BEENDET.*======") { break }
                    }
                }
            }
        } catch { Write-Output "FATALER FEHLER im Watcher-Job: $($_.Exception.Message)"
        } finally { if ($watcherSession) { Remove-SSHSession -SSHSession $watcherSession } }
    } -ArgumentList $jobParamsForWatcher

    $replicationJobTimer.Start()
    Write-GuiLog "Replikations-Job für $($checkedListBoxVms.CheckedItems.Count) VM(s) gestartet (ID: $($Global:replicationJob.Id)). Log wird live überwacht, warte 60 sec."
})

# --- ENDE ZU ERSETZENDER BLOCK ---

$onReplicationJobTimerTick = {
    # Wenn kein Job existiert, stoppe den Timer
    if (-not $Global:replicationJob) {
        $Global:replicationJobTimer.Stop()
        return
    }

    # Lese neue Log-Ausgaben vom laufenden Job
    if ($Global:replicationJob.HasMoreData) {
        Receive-Job -Job $Global:replicationJob | ForEach-Object { Write-GuiLog "JOB: $_" }
    }

    # Wenn der Job beendet ist, räume auf und stoppe den Timer
    if ($Global:replicationJob.State -ne 'Running') {
        Write-GuiLog "Replikations-Job beendet mit Status: $($Global:replicationJob.State)."
        if ($Global:replicationJob.HasMoreData) {
            Receive-Job -Job $Global:replicationJob | ForEach-Object { Write-GuiLog "JOB: $_" }
        }
        Remove-Job -Job $Global:replicationJob
        $Global:replicationJob = $null
        $Global:replicationJobTimer.Stop()
        Write-GuiLog "============================================="
        
		# NEU: Erstelle eine intelligente, dynamische Abschlussmeldung
        $jobTypeDisplay = if ($Global:currentJobType) { $Global:currentJobType } else { "Aufgabe" }
        $finalMessage = "$($jobTypeDisplay) erfolgreich abgeschlossen."
        if (-not [string]::IsNullOrWhiteSpace($Global:currentJobTargetName)) {
            $finalMessage = "$($jobTypeDisplay) erfolgreich abgeschlossen für:`n`n$($Global:currentJobTargetName)"
        }
        [System.Windows.Forms.MessageBox]::Show($finalMessage, "Fertig", "OK", "Information")
        
        # Setze die globalen Variablen für den nächsten Lauf zurück
        $Global:currentJobTargetName = $null
        $Global:currentJobType = $null
		
    }
}
$Global:replicationJobTimer.Add_Tick($onReplicationJobTimerTick)

# =====================================================================================
# --- END BLOCK ---
# =====================================================================================

# =====================================================================================
# Start Button Replikation mit Zwischenspeichers
# =====================================================================================


# Event Handler für den "..." Button des Zwischenspeichers (nutzt die globale Verbindung zum Quell-Host)
$buttonBrowseRepSharedDs.Add_Click({
    $selectedPath = Show-DatastoreSelectionDialog
    if ($selectedPath) {
        $textboxRepSharedDs.Text = $selectedPath
    }
})

# Event Handler für den "..." Button des Zielspeichers (baut jetzt eine dauerhafte Session auf)
$buttonBrowseRepTargetDs.Add_Click({
    $targetHost = $textboxRepTargetHost.Text
    $targetUser = $textboxRepTargetUser.Text
    if ([string]::IsNullOrWhiteSpace($targetHost) -or [string]::IsNullOrWhiteSpace($targetUser)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte geben Sie zuerst die IP und den User des Ziel-Hosts an.", "Fehlende Eingabe", "OK", "Warning")
        return
    }

    if (-not ($Global:TargetESXiSession -and $Global:TargetESXiSession.Connected)) {
        Write-GuiLog "Stelle Verbindung zum Ziel-Host $targetHost her..."
        try {
            $Global:TargetESXiSshCredential = Get-Credential -UserName $targetUser -Message "Passwort für Ziel-Host $targetUser@$targetHost eingeben:"
            if (-not $Global:TargetESXiSshCredential) { Write-GuiLog "Passworteingabe für Ziel-Host abgebrochen."; return }

            # KORREKTUR: Alle Timeout-Parameter entfernt
            $Global:TargetESXiSession = New-SSHSession -ComputerName $targetHost -Credential $Global:TargetESXiSshCredential -ErrorAction Stop -AcceptKey -ConnectionTimeout 60

            if ($Global:TargetESXiSession.Connected) {
                Write-GuiLog "Verbindung zum Ziel-Host für Datastore-Suche erfolgreich."
                # $targetIpDisplay.Text = $targetHost # <-- DIESE ZEILE HINZUFÜGEN - Objekt existiert nicht mehr
            }
        }
        catch {
            Write-GuiLog "FEHLER bei der Verbindung zum Ziel-Host: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Verbindung zum Ziel-Host fehlgeschlagen.`n`n$($_.Exception.Message)", "Verbindungsfehler", "OK", "Error")
            $Global:TargetESXiSession = $null
            $Global:TargetESXiSshCredential = $null
            return
        }
    }

    $selectedPath = Show-DatastoreSelectionDialog -SSHSession $Global:TargetESXiSession
    if ($selectedPath) {
        $textboxRepTargetDs.Text = $selectedPath
    }
})


# Füllt die Job-Liste beim Start der GUI
$form.Add_Load({
    Populate-JobComboBox
})

# Aktualisiert die Job-Liste, wenn der Refresh-Button geklickt wird
$buttonRefreshJobs.Add_Click({
    Populate-JobComboBox
})

# Lädt den ausgewählten Job, wenn sich die Auswahl in der ComboBox ändert
$comboboxJobs.Add_SelectedIndexChanged({
    $selectedJob = $comboboxJobs.SelectedItem
    # Stelle sicher, dass nicht der Platzhalter ausgewählt wurde
    if ($null -ne $selectedJob -and $null -ne $selectedJob.FullPath) {
        Load-HostGuiSettings -FilePath $selectedJob.FullPath
    }
})

### LOGIK FUNKTIONEN ###

# =====================================================================================
# START: NEUE FUNKTION FÜR DIE DIREKTE REPLIKATION (Vordergrundprozess)
# Diese Funktion wird aus dem Add_Click-Event des "Direkte Repl."-Buttons aufgerufen.
# =====================================================================================
function Start-DirectReplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceVmName,
        [Parameter(Mandatory=$true)]
        [string]$SourceHost,
        [Parameter(Mandatory=$true)]
        [Object]$SourceSession,
        [Parameter(Mandatory=$true)]
        [string]$TargetHost,
        [Parameter(Mandatory=$true)]
        [Object]$TargetSession,
        [Parameter(Mandatory=$true)]
        [string]$TargetDatastore,
        [Parameter(Mandatory=$true)]
        [string]$ReplicatedVmName,
        [Parameter(Mandatory=$true)]
        [System.Windows.Forms.Form]$FormObject
    )

    $vmId = $null
    $replicationSucceeded = $false
    $snapshotName = "ghetto-direct-repl-$(Get-Date -f 'yyyyMMddHHmmss')"
    $targetVmPath = "$($TargetDatastore)/$($ReplicatedVmName)"

    try {
        # --- [1/9] VM-Informationen abrufen ---
        Write-GuiLog "[1/9] Finde VMID und VMX-Pfad für '$SourceVmName'..."
        $FormObject.Refresh()
        $vmInfoCmd = "vim-cmd vmsvc/getallvms"
        $allVmsInfo = (Invoke-SSHCommand -SSHSession $SourceSession -Command $vmInfoCmd).Output
        # Robuste Regex, um den VM-Namen zu finden, auch wenn Leerzeichen enthalten sind
        $vmInfoLine = $allVmsInfo | Where-Object { $_ -match "\s\b$([regex]::escape($SourceVmName))\b\s+\[" } | Select-Object -First 1
        if (-not $vmInfoLine) { throw "Konnte VM '$SourceVmName' in der Liste nicht eindeutig finden." }

        $vmId = ($vmInfoLine -split '\s+')[0]
        $vmxPathMatch = [regex]::Match($vmInfoLine, '\[(.*?)\]\s*(.*\.vmx)')
        if (-not $vmxPathMatch.Success) { throw "Konnte VMX-Pfad für '$SourceVmName' nicht auslesen."}
        $datastore = $vmxPathMatch.Groups[1].Value
        $vmxFile = $vmxPathMatch.Groups[2].Value.Trim()
        $vmxPathOnHost = "/vmfs/volumes/$datastore/$vmxFile"
        Write-GuiLog "  -> VMID: $vmId"
        Write-GuiLog "  -> VMX-Pfad: $vmxPathOnHost"

        # --- [2/9] VMX-Datei lesen und Snapshot erstellen ---
        Write-GuiLog "[2/9] Lese originale VMX-Datei und erstelle Snapshot..."
        $FormObject.Refresh()
        $vmxContentBefore = (Invoke-SSHCommand -SSHSession $SourceSession -Command "cat '$vmxPathOnHost'").Output
        $originalDiskLines = $vmxContentBefore | Where-Object { $_ -match '^scsi|^ide|^sata' -and $_ -match '\.vmdk' }
        Write-GuiLog "  -> Erstelle Snapshot '$snapshotName'..."
        Invoke-SSHCommand -SSHSession $SourceSession -Command "vim-cmd vmsvc/snapshot.create $vmId '$snapshotName' 'Direkte Replikation' 0 0" | Out-Null

        # Warten, bis der Snapshot in der VMX-Datei referenziert wird
        $snapshotCreated = $false
        $snapWaitLoop = 0
        $maxSnapWait = 24 # 24 * 5s = 120 Sekunden
        while (-not $snapshotCreated -and $snapWaitLoop -lt $maxSnapWait) {
            Start-Sleep -Seconds 5
            $snapWaitLoop++
            Write-GuiLog "  -> Warte auf Snapshot... ($($snapWaitLoop * 5)s)"
            $FormObject.Refresh()
            $currentVmx = (Invoke-SSHCommand -SSHSession $SourceSession -Command "cat '$vmxPathOnHost'").Output -join ''
            if ($currentVmx -match '-00000\d+\.vmdk') {
                $snapshotCreated = $true
                Write-GuiLog "  -> Snapshot erfolgreich erstellt und in VMX-Datei sichtbar."
            }
        }
        if (-not $snapshotCreated) { throw "Snapshot-Erstellung hat das Zeitlimit überschritten." }
        $vmxContentAfter = (Invoke-SSHCommand -SSHSession $SourceSession -Command "cat '$vmxPathOnHost'").Output
        $snapshotDiskLines = $vmxContentAfter | Where-Object { $_ -match '^scsi|^ide|^sata' -and $_ -match '\.vmdk' }


        # --- [3/9] Zielordner erstellen ---
        Write-GuiLog "[3/9] Erstelle Zielordner '$targetVmPath'..."
        $FormObject.Refresh()
        $mkdirResult = Invoke-SSHCommand -SSHSession $TargetSession -Command "rm -rf '$targetVmPath'; mkdir -p '$targetVmPath'"
        if ($mkdirResult.ExitStatus -ne 0) { throw "Fehler beim Erstellen des Zielordners: $($mkdirResult.Error -join '; ')" }


        # --- [4/9] Festplatten-Transfer via "vmkfstools | ssh dd" ---
        Write-GuiLog "[4/9] Starte Übertragung der Festplatten..."
        $FormObject.Refresh()
        for ($i = 0; $i -lt $snapshotDiskLines.Count; $i++) {
            $diskIndex = $i + 1
            $snapshotDiskFileName = ($snapshotDiskLines[$i] -split '"')[1]
            $sourceDiskPath = (Split-Path -Path $vmxPathOnHost) + "/" + $snapshotDiskFileName
            $originalDiskFileName = ($originalDiskLines[$i] -split '"')[1]
            $targetDiskPath = "$targetVmPath/$originalDiskFileName"

            Write-GuiLog "  -> Übertrage Festplatte ($diskIndex/$($snapshotDiskLines.Count)): '$snapshotDiskFileName'..."
            $FormObject.Refresh()

            # Der Befehl, der auf dem Quell-Host ausgeführt wird
            $transferCommand = "vmkfstools -i `"$sourceDiskPath`" -d thin | ssh -i /.ssh/id_ecdsa -o 'StrictHostKeyChecking=no' -o 'ConnectTimeout=10' root@$TargetHost `"dd of='$targetDiskPath' bs=4M`""
            Write-GuiLog "    -> Befehl: $transferCommand"

            # Führe den Transfer-Befehl aus. Das Timeout sollte grosszügig sein.
            $transferResult = Invoke-SSHCommand -SSHSession $SourceSession -Command $transferCommand -Timeout 36000 # 10 Stunden Timeout

            if ($transferResult.ExitStatus -ne 0) {
                 throw "Fehler beim Transfer von '$snapshotDiskFileName'. Exit Code: $($transferResult.ExitStatus). Fehler: $($transferResult.Error -join '; ')"
            }
            Write-GuiLog "    -> Festplatte ($diskIndex/$($snapshotDiskLines.Count)) erfolgreich übertragen."
        }


        # --- [5/9] Angepasste VMX-Datei erstellen ---
        Write-GuiLog "[5/9] Erstelle angepasste VMX-Datei auf dem Ziel-Host..."
        $FormObject.Refresh()
        $originalVmxBasename = [System.IO.Path]::GetFileNameWithoutExtension($vmxFile)
        $newVmxContent = $vmxContentBefore -join "`n"
        # Ersetze den Anzeigenamen und alle Dateireferenzen
        $newVmxContent = $newVmxContent -replace "displayName = `"$SourceVmName`"", "displayName = `"$ReplicatedVmName`""
        $newVmxContent = $newVmxContent -replace "$originalVmxBasename.vmdk", "$ReplicatedVmName.vmdk"
        $newVmxContent = $newVmxContent -replace "$originalVmxBasename.nvram", "$ReplicatedVmName.nvram"
        # Entferne UUIDs und Snapshot-Infos, um Konflikte zu vermeiden
        $linesToRemove = 'snapshot\.|\.latest|uuid\.location|uuid\.bios|vc\.uuid|sched\.swap\.derivedName'
        $filteredLines = $newVmxContent.Split("`n") | Where-Object { $_ -notmatch $linesToRemove }
        $finalVmxContent = ($filteredLines -join "`n").Replace("'", "'""'") # Escapen für 'echo'


        # --- [6/9] VMX-Datei auf Ziel-Host schreiben ---
        Write-GuiLog "[6/9] Schreibe VMX-Datei und benenne Dateien um..."
        $FormObject.Refresh()
        $targetVmxPath = "$targetVmPath/$ReplicatedVmName.vmx"
        # Robuste Methode, um die Datei zu schreiben
        $writeVmxCommand = "cat <<'EOF' > `"$targetVmxPath`"`n$($finalVmxContent -join "`n")`nEOF"
        $writeResult = Invoke-SSHCommand -SSHSession $TargetSession -Command $writeVmxCommand
        if ($writeResult.ExitStatus -ne 0) { throw "Fehler beim Schreiben der VMX-Datei auf dem Ziel-Host." }

        # NVRAM-Datei umbenennen, falls vorhanden
        $nvramFile = $vmxContentBefore | Where-Object { $_ -match '.nvram' } | ForEach-Object { ($_ -split '"')[1] }
        if ($nvramFile) {
            Invoke-SSHCommand -SSHSession $TargetSession -Command "cp `"$targetVmPath/$nvramFile`" `"$targetVmPath/$($ReplicatedVmName).nvram`"" | Out-Null
        }


        # --- [7/9] VM auf Ziel-Host registrieren ---
        Write-GuiLog "[7/9] Registriere VM auf dem Ziel-Host..."
        $FormObject.Refresh()
        $registerCmd = "vim-cmd solo/registervm `"$targetVmxPath`""
        $registerResult = Invoke-SSHCommand -SSHSession $TargetSession -Command $registerCmd
        if ($registerResult.ExitStatus -ne 0 -or !($registerResult.Output -match '^\d+$')) {
            throw "Fehler beim Registrieren der VM: $($registerResult.Error -join '; ')"
        }
        Write-GuiLog "  -> VM erfolgreich registriert mit neuer VMID: $($registerResult.Output)"


        # --- [8/9] Aufräumen: Snapshot löschen ---
        Write-GuiLog "[8/9] Räume auf: Lösche Snapshot auf dem Quell-Host..."
        $FormObject.Refresh()
        Invoke-SSHCommand -SSHSession $SourceSession -Command "vim-cmd vmsvc/snapshot.removeall $vmId" | Out-Null
        Write-GuiLog "  -> Snapshot erfolgreich entfernt."


        # --- [9/9] Erfolg ---
        $replicationSucceeded = $true
        Write-GuiLog "[9/9] REPLIKATION ERFOLGREICH ABGESCHLOSSEN!"
        $FormObject.Refresh()
        [System.Windows.Forms.MessageBox]::Show("Die direkte Replikation wurde erfolgreich abgeschlossen!", "Erfolg", "OK", "Information")

    }
    catch {
        # --- Fehlerbehandlung ---
        Write-GuiLog "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        Write-GuiLog "FEHLER bei der direkten Replikation: $($_.Exception.Message)"
        Write-GuiLog "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        [System.Windows.Forms.MessageBox]::Show("Die Replikation ist fehlgeschlagen.`n`nFehler: $($_.Exception.Message)`n`nBitte prüfen Sie das Log für Details.", "Replikation fehlgeschlagen", "OK", "Error")

        # Versuch, den Snapshot trotzdem zu löschen
        if ($vmId) {
            try {
                Write-GuiLog "Versuche, den Snapshot trotz des Fehlers zu löschen..."
                Invoke-SSHCommand -SSHSession $SourceSession -Command "vim-cmd vmsvc/snapshot.removeall $vmId" -ErrorAction SilentlyContinue | Out-Null
                Write-GuiLog "Aufräumversuch beendet."
            } catch {}
        }
    }
}
# =====================================================================================
# ENDE: NEUE FUNKTION
# =====================================================================================


function Validate-RequiredFields {
    param(
        [string]$Context
    )

    $requiredFields = @{}
    # Definieren, welche Felder für welchen Kontext benötigt werden
    switch ($Context) {
        'SaveOrBackup' {
            $requiredFields.Add("GhettoVCB-Pfad", $textboxGhettoPath)
            $requiredFields.Add("Backup Volume", $textboxBackupVol)
            $requiredFields.Add("VM-Liste", $textboxVmList)
        }
        'EmailTest' {
            $requiredFields.Add("GhettoVCB-Pfad", $textboxGhettoPath)
            $requiredFields.Add("Empfänger", $textboxEmailTo)
            $requiredFields.Add("Absender", $textboxEmailFrom)
            $requiredFields.Add("SMTP-Server", $textboxEmailServer)
            $requiredFields.Add("SMTP-Port", $textboxEmailPort)
        }
    }

    # Überprüfe die definierten Felder
    foreach ($field in $requiredFields.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($field.Value.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Das Feld '$($field.Name)' wird für diese Aktion benötigt und darf nicht leer sein.", "Fehlende Eingabe", "OK", "Warning")
            return $false
        }
    }

    return $true
}
# ---------------------------------
# GhettoVCB Patch installieren
# ---------------------------------

# --- START ZU ERSETZENDER BLOCK ---

function Install-PatchedGhettoVCB {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }
    $ghettoPathOnESXi = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "FEHLER: Der GhettoVCB-Pfad muss im GUI gesetzt sein."; return }

    $patchUrl = "https://github.com/Chrigel71/GhettoGUI/raw/refs/heads/main/ghettoVCB_patch.sh"
    $targetPathOnESXi = "$ghettoPathOnESXi/ghettoVCB.sh"
    $localSourceFilePath = $null
    $tempFile = $null

    $choice = Show-InstallationSourceDialog -Title "Quelle für Patch wählen" -Message "Möchten Sie den GhettoVCB-Patch von GitHub oder von einer lokalen Datei installieren?"

    if ($choice -eq 'Yes') {
        Write-GuiLog "Starte Download des Patches auf diesen PC..."
        try {
            $tempFile = New-TemporaryFile
            Invoke-WebRequest -Uri $patchUrl -OutFile $tempFile.FullName -UseBasicParsing
            $localSourceFilePath = $tempFile.FullName
        } catch {
            Write-GuiLog "FEHLER beim GitHub-Download: $($_.Exception.Message)"; return
        }
    } elseif ($choice -eq 'No') {
        $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $openFileDialog.Title = "Lokale ghettoVCB_patch.sh Datei auswählen"
        $openFileDialog.Filter = "Shell-Skripte (*.sh)|*.sh|Alle Dateien (*.*)|*.*"
        if ($openFileDialog.ShowDialog($form) -eq 'OK') {
            $localSourceFilePath = $openFileDialog.FileName
        } else {
            Write-GuiLog "Installation abgebrochen."; return
        }
    } else {
        Write-GuiLog "Installation abgebrochen."; return
    }
    
    Write-GuiLog "Installiere Patch von '$localSourceFilePath'..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $sftpSession = $null
    try {
        $ErrorActionPreference = "Stop"
        $scriptContent = Get-Content -Path $localSourceFilePath -Raw -Encoding UTF8
        
        Write-GuiLog "Verbinde via SFTP, um Patch hochzuladen..."
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60

        Write-GuiLog "Lade Patch nach '$targetPathOnESXi' hoch..."
        Set-SFTPContent -SFTPSession $sftpSession -Path $targetPathOnESXi -Value $scriptContent -Encoding UTF8

        Write-GuiLog "Setze Ausführungsrechte (chmod +x)..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x `"$targetPathOnESXi`"" | Out-Null
        
        # NEU: Erstelle das 'logs' Verzeichnis, falls es nicht existiert
        Write-GuiLog "Stelle sicher, dass das Log-Verzeichnis existiert..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "mkdir -p `"$ghettoPathOnESXi/logs`"" | Out-Null

        Write-GuiLog "Patch erfolgreich installiert!"
        [System.Windows.Forms.MessageBox]::Show("Der Patch wurde erfolgreich installiert!", "Installation erfolgreich", "OK", "Information")
    } catch {
        Write-GuiLog "FEHLER bei der Installation des Patches: $($_.Exception.Message)"
    } finally {
        if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession -EA 0 }
        if ($tempFile -and (Test-Path $tempFile.FullName)) { Remove-Item $tempFile.FullName -Force -EA 0 }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $ErrorActionPreference = "Continue"
    }
}

# --- ENDE GhettoVCB Patch ---

function Get-SendmailDebugLog {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) {
        Write-GuiLog "Fehler: Nicht mit ESXi verbunden."
        return
    }
    $ghettoPathOnESXi = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) {
        Write-GuiLog "Fehler: GhettoVCB-Pfad im GUI ist nicht gesetzt."
        return
    }

    Write-GuiLog "Suche nach der aktuellsten Log-Datei und filtere nach E-Mail-Einträgen..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        # Finde die aktuellste Log-Datei (Logik wiederverwendet von Get-BackupJobLog)
        $logDir = "'$ghettoPathOnESXi/logs'"
        # Sucht nach allen .log Dateien im logs-Verzeichnis
        $findLatestLogCmd = "ls -t $logDir/*.log 2>/dev/null | head -n 1"
        $latestLogPathResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $findLatestLogCmd
        $logFile = $latestLogPathResult.Output -join ''

        if ([string]::IsNullOrWhiteSpace($logFile)) {
            Write-GuiLog "Keine Log-Dateien im Verzeichnis '$($ghettoPathOnESXi)/logs' gefunden."
            return
        }

        Write-GuiLog "Durchsuche '$logFile' nach E-Mail relevanten Einträgen..."
        
        # Erstelle den grep-Befehl, um nach mehreren Schlüsselwörtern (case-insensitive) zu suchen
        $grepCmd = "grep -i 'email\|sendmail\|subject' '$logFile'"
        $grepResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $grepCmd

        Write-GuiLog "--- START Gefiltertes E-Mail Log ---"
        if ($grepResult.ExitStatus -eq 0 -and $grepResult.Output) {
            $grepResult.Output | ForEach-Object { Write-GuiLog $_ }
        } else {
            Write-GuiLog "Keine E-Mail-spezifischen Einträge in der letzten Log-Datei gefunden."
        }
        Write-GuiLog "--- ENDE Gefiltertes E-Mail Log ---"
    } catch {
        Write-GuiLog "FEHLER beim Abrufen des E-Mail-Logs: $($_.Exception.Message)"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

############################
#### function Send-TestEmail
############################

function Send-TestEmail {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "FEHLER: Für den E-Mail-Test muss eine Verbindung zum ESXi-Host bestehen."; return }

    Write-GuiLog "Starte E-Mail-Test..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $emailParams = @{
        To = $textboxEmailTo.Text; From = $textboxEmailFrom.Text; Server = $textboxEmailServer.Text
        Port = $textboxEmailPort.Text; User = $textboxEmailUser.Text; Pass = $textboxEmailPassword.Text
    }

    # --- NEU: Display Name (Anzeigename) auslesen ---
    $dispName = $textboxEmailDisplay.Text
    if ([string]::IsNullOrWhiteSpace($dispName)) { $dispName = "ESXi Backup" }
    # ------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($emailParams.To) -or [string]::IsNullOrWhiteSpace($emailParams.From) -or [string]::IsNullOrWhiteSpace($emailParams.Server) -or [string]::IsNullOrWhiteSpace($emailParams.Port)) {
        Write-GuiLog "FEHLER: Bitte fülle alle E-Mail-Felder aus."; $form.Cursor = [System.Windows.Forms.Cursors]::Default; return
    }
    $ghettoPathOnESXi = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) {
        Write-GuiLog "FEHLER: Der GhettoVCB-Pfad muss gesetzt sein."; $form.Cursor = [System.Windows.Forms.Cursors]::Default; return
    }

    # --- KORREKTUR START (M365 Fix) ---
    # 1. Ermittle den Envelope Sender (MAIL_FROM). Für M365 MUSS dies der AUTH-USER sein.
    $mailFrom = $emailParams.From
    if (-not [string]::IsNullOrWhiteSpace($emailParams.User)) {
        # Wenn AUTH-User gesetzt ist, überschreibe den Envelope Sender mit dem AUTH-User.
        $mailFrom = $emailParams.User
        Write-GuiLog "INFO: Verwende den AUTH-Benutzer ($mailFrom) als Envelope Sender (-f) für M365-Kompatibilität."
    }
    
    # 2. Port-Variable trimmen, bevor sie verwendet wird (Behebt "Invalid port" Fehler)
    $cleanEmailPort = $emailParams.Port.Trim()
    # --- KORREKTUR ENDE ---


    $sftpSession = $null
    $remoteTestMessagePath = "/tmp/ghetto_test_mail.txt"
    try {
        $ErrorActionPreference = "Stop"
        
        # --- KORREKTUR: Dateiname OHNE .py (Server-Standard) ---
        $sourceScriptPath = "'$ghettoPathOnESXi/sendmail'"
        # -------------------------------------------------------
        
        $tmpScriptPath = "/tmp/sendmail_test_run.py"

        $testSubject = "GhettoVCB GUI - Test E-Mail von Host $($Global:ESXiConnectedHostName)"
        $testBody = "## Final status: Test erfolgreich ##`nBackup Duration: 1 Sekunde`ninfo: Initiate backup for Test-VM"

        Write-GuiLog "Lade Test-Nachricht nach ESXi hoch..."
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
        Set-SFTPContent -SFTPSession $sftpSession -Path $remoteTestMessagePath -Value $testBody -Encoding UTF8
        Write-GuiLog "Upload der temporären Test-Nachricht erfolgreich."

        $recipientsForCli = $emailParams.To.Split(',') | ForEach-Object { "'$($_.Trim())'" }
        $recipientsStr = $recipientsForCli -join " "

        # --- UPDATE: Befehl mit -N Parameter ergänzt ---
        # Aufbau: script -m message -f sender -N "Display Name" -s server -S port -j subject
        $base_command = "$tmpScriptPath -m $remoteTestMessagePath -f `"$mailFrom`" -N `"$dispName`" -s `"$($emailParams.Server)`" -S `"$cleanEmailPort`" -j `"$testSubject`" "
        
        if (-not [string]::IsNullOrWhiteSpace($emailParams.User)) {
            $base_command += "-u `"$($emailParams.User)`" -p `"$($emailParams.Pass)`" "
        }
        $base_command += $recipientsStr

        # ### Führe 'python' aus und übergebe das Skript ###
        $command = "cp $sourceScriptPath $tmpScriptPath && chmod +x $tmpScriptPath && python $base_command && rm $tmpScriptPath"

        Write-GuiLog "Führe sendmail-Skript aus (via python /tmp/)..."; Write-GuiLog "Befehl: $command"
        $result = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $command

        Write-GuiLog "--- E-Mail Test Skript-Ausgabe ---"
        if ($result.Output) { $result.Output | ForEach-Object { Write-GuiLog $_ } } else { Write-GuiLog "(Keine Ausgabe vom Skript)" }
        if ($result.Error) { $result.Error | ForEach-Object { Write-GuiLog "FEHLER (stderr): $_" } }
        Write-GuiLog "--- Ende der Ausgabe ---"

        if ($result.ExitStatus -eq 0 -and ($result.Output -join '').Contains("INFO: Email successfully sent")) {
             [System.Windows.Forms.MessageBox]::Show("Test erfolgreich! E-Mail wurde versendet.", "ERFOLG!", "OK", "Information")
        } else {
             [System.Windows.Forms.MessageBox]::Show("Test fehlgeschlagen. Prüfe Log.", "Fehler", "OK", "Warning")
        }
    } catch {
        Write-GuiLog "FATALER FEHLER beim E-Mail-Test: $($_.Exception.Message)"
    } finally {
        if ($sftpSession) {
            try { Remove-SFTPItem -SFTPSession $sftpSession -Path $remoteTestMessagePath -ErrorAction SilentlyContinue } catch {}
            Remove-SFTPSession -SFTPSession $sftpSession -ErrorAction SilentlyContinue
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $ErrorActionPreference = "Continue"
    }
}

function Create-CustomFirewallRule {
    $portToOpen = $textboxEmailPort.Text.Trim()
    if (-not ($portToOpen -match '^\d+$' -and [int]$portToOpen -gt 0 -and [int]$portToOpen -le 65535)) {
        Write-GuiLog "FEHLER: Ungültiger Port '$portToOpen' im E-Mail-Port-Feld. Kann keine Regel erstellen."
        [System.Windows.Forms.MessageBox]::Show("Bitte geben Sie einen gültigen Port (1-65535) in das SMTP-Port Feld ein, bevor Sie eine Firewall-Regel erstellen.", "Ungültiger Port", "OK", "Error")
        return
    }
    Write-GuiLog "Erstelle benutzerdefinierte Firewall-Regel für Port $portToOpen..."
    $sftp = $null
    $tempXmlPath = $null
    try {
        $ruleId = "GhettoVCB-GUI-SMTP"
        $xmlContent = @"
<ConfigRoot>
  <service id='1986'>
    <id>$($ruleId)</id>
    <rule id='0000'>
      <direction>outbound</direction>
      <protocol>tcp</protocol>
      <porttype>dst</porttype>
      <port>$($portToOpen)</port>
    </rule>
    <enabled>true</enabled>
    <required>false</required>
  </service>
</ConfigRoot>
"@
        $tempXmlPath = Join-Path $env:TEMP "ghetto_fw_rule.xml"
        Set-Content -Path $tempXmlPath -Value $xmlContent -Encoding UTF8
        Write-GuiLog "Lokale Regel-XML erstellt."
        $remoteXmlPath = "/etc/vmware/firewall/$($ruleId).xml"
        Write-GuiLog "Lade Regel nach $remoteXmlPath hoch..."
        $sftp = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
        $localFileStream = $null
        $remoteSftpStream = $null
        try {
            $localFileStream = New-Object System.IO.FileStream($tempXmlPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
            $remoteSftpStream = New-SFTPFileStream -SFTPSession $sftp -Path $remoteXmlPath -FileMode Create -FileAccess Write
            $localFileStream.CopyTo($remoteSftpStream)
        } finally {
            if ($remoteSftpStream) { $remoteSftpStream.Close(); $remoteSftpStream.Dispose() }
            if ($localFileStream) { $localFileStream.Close(); $localFileStream.Dispose() }
        }
        Write-GuiLog "Regel-XML erfolgreich hochgeladen."
        Write-GuiLog "Aktualisiere ESXi-Firewall..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network firewall refresh" | Out-Null
        Write-GuiLog "Firewall aktualisiert. Aktiviere neue Regel..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network firewall ruleset set --enabled true --ruleset-id=$ruleId" | Out-Null
        Write-GuiLog "Neue Regel '$ruleId' ist jetzt aktiv!"
        [System.Windows.Forms.MessageBox]::Show("Die neue Firewall-Regel '$ruleId' für Port $portToOpen wurde erfolgreich erstellt und aktiviert.", "Erfolg", "OK", "Information")
    } catch {
        Write-GuiLog "FEHLER bei Erstellung der Firewall-Regel: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Bei der Erstellung der Firewall-Regel ist ein Fehler aufgetreten.`n`nDetails: $($_.Exception.Message)", "Fehler", "OK", "Error")
    } finally {
        if ($sftp) { Remove-SSHSession -SFTPSession $sftp -ErrorAction SilentlyContinue }
        if ($tempXmlPath -and (Test-Path $tempXmlPath)) { Remove-Item -Path $tempXmlPath -Force -ErrorAction SilentlyContinue }
    }
}

function Stop-GhettoVCBBackupJob {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }
    Write-GuiLog "Starte intelligenten Abbruch (versuche zuerst sanft, dann hart)..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $backupVolPath = $textboxBackupVol.Text
        $cancelScript = @"
BACKUP_VOL_PATH='$($backupVolPath.Replace("'", "'""'"))'
# Finde zuerst den Zielordner, falls ein Backup läuft
WORKER_PID=\$(pgrep -f "vmkfstools.*\$BACKUP_VOL_PATH")
if [ -n "\$WORKER_PID" ]; then
    WORKER_CMD=\$(ps -c | grep " \$WORKER_PID " | grep 'vmkfstools')
    DEST_VMDK_PATH=\$(echo "\$WORKER_CMD" | sed 's/.* //')
    DIR_TO_DELETE=\$(dirname "\$DEST_VMDK_PATH")
    echo "INFO: Unvollständiges Backup-Verzeichnis identifiziert: \$DIR_TO_DELETE"
else
    echo "INFO: Kein aktiver vmkfstools-Prozess gefunden."
    DIR_TO_DELETE=""
fi

# 1. Versuche sanftes Beenden (SIGTERM), damit der Trap im Skript auslösen kann
echo "INFO: Sende sanftes Beenden-Signal (SIGTERM) an alle GhettoVCB-Prozesse..."
pkill -15 -f "ghettoVCB.sh"
pkill -15 -f "vmkfstools.*ghettoVCB"
echo "INFO: Warte 5 Sekunden, damit die Skripte sich selbst aufräumen können..."
sleep 5

# 2. Prüfe, ob Prozesse noch laufen. Wenn ja, beende sie hart.
echo "INFO: Prüfe, ob Prozesse noch laufen..."
if pgrep -f "ghettoVCB.sh" > /dev/null || pgrep -f "vmkfstools.*ghettoVCB" > /dev/null; then
    echo "WARN: Prozesse laufen immer noch. Sende hartes Kill-Signal (SIGKILL)..."
    pkill -9 -f "ghettoVCB.sh"
    pkill -9 -f "vmkfstools.*ghettoVCB"
else
    echo "INFO: Prozesse wurden erfolgreich sanft beendet."
fi

# 3. Als letzte Sicherheit: Lösche den identifizierten Ordner und die Lock-Datei
if [ -n "\$DIR_TO_DELETE" ] && [ -d "\$DIR_TO_DELETE" ]; then
    echo "INFO: Führe finale Löschung des unvollständigen Backup-Verzeichnisses durch..."
    rm -rf "\$DIR_TO_DELETE"
    echo "INFO: Verzeichnis gelöscht."
fi
rm -f /var/run/ghettovcb.lock
echo "INFO: Lock-Datei /var/run/ghettovcb.lock entfernt."
"@
        $result = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $cancelScript
        $result.Output | ForEach-Object { Write-GuiLog $_ }
        Write-GuiLog "Abbruch-Sequenz abgeschlossen."
    } catch {
        Write-GuiLog "Ausnahmefehler beim Abbrechen des Backups: $($_.Exception.Message)"
    } finally {
        if ($Global:logPollTimer.Enabled) { $Global:logPollTimer.Stop(); Write-GuiLog "Automatischer Log-Abruf gestoppt." }
        $buttonStartBackup.Enabled = $true; $buttonCheckBackupStatus.Enabled = $true; $buttonCancelBackup.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Save-GhettoVCBConfig {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return $false }

    $baseBackupPath = $textboxBackupVol.Text.TrimEnd('/'); $subfolder = $textboxSubfolder.Text.Trim('/'); $fullBackupPath = if (-not [string]::IsNullOrWhiteSpace($subfolder)) { "$baseBackupPath/$subfolder" } else { $baseBackupPath }
    $ghettoPath = $textboxGhettoPath.Text; $rotation = $textboxRotation.Text; $diskFormat = $comboboxDiskFormat.SelectedItem.ToString();
    # KORREKTUR: Die PowerShell-Variablen werden hier korrekt zugewiesen
    $snapMem = if ($checkboxSnapMem.Checked) { 1 } else { 0 }; $snapQuiesce = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 };
    $vmListText = $textboxVmList.Text
    if (-not $ghettoPath -or -not $fullBackupPath) { Write-GuiLog "Fehler: GhettoVCB-Pfad und Backup Volume/Unterordner erforderlich."; return $false }
    $emailLog = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; $emailTo = $textboxEmailTo.Text; $emailFrom = $textboxEmailFrom.Text; $emailServer = $textboxEmailServer.Text; $emailPort = $textboxEmailPort.Text;
    $emailUser = $textboxEmailUser.Text; $emailPass = $textboxEmailPassword.Text;
    $emailSubjectTemplate = $textboxEmailSubject.Text
    $emailSubject = $emailSubjectTemplate.Replace('%h', $Global:ESXiConnectedHostName)
    $emailBinPath = "'$ghettoPath/sendmail'"

	$useFixedDirValue = if ($checkboxFixedBackupDir.Checked) { 1 } else { 0 }
	$confLines = @(
		"USE_FIXED_BACKUP_DIR=$useFixedDirValue",
        "VM_BACKUP_VOLUME=""$fullBackupPath""", "VM_BACKUP_ROTATION_COUNT=$rotation", "DISK_BACKUP_FORMAT=""$diskFormat""",
        # KORREKTUR: Die korrekten Variablennamen für die .conf-Datei werden hier verwendet
        "VM_SNAPSHOT_MEMORY=$snapMem", "VM_SNAPSHOT_QUIESCE=$snapQuiesce",
        "POWER_VM_DOWN_BEFORE_BACKUP=0", "ENABLE_HARD_POWER_OFF=0", "ITER_TO_WAIT_SHUTDOWN=3", "POWER_DOWN_TIMEOUT=5", "SNAPSHOT_TIMEOUT=15", "ENABLE_COMPRESSION=0",
        "ALLOW_VMS_WITH_SNAPSHOTS_TO_BE_BACKEDUP=0", "VMDK_FILES_TO_SKIP=""""",
        "EMAIL_LOG=$emailLog", "EMAIL_SERVER=""$emailServer""", "EMAIL_SERVER_PORT=""$emailPort""",
        "EMAIL_USER_NAME=""$emailUser""", "EMAIL_USER_PASSWORD=""$emailPass""", "EMAIL_FROM=""$emailFrom""", "EMAIL_TO=""$emailTo""", "EMAIL_SUBJECT=""$emailSubject""", "EMAIL_BIN=$emailBinPath",
        "EMAIL_ERRORS_TO=""""", "EMAIL_DELAY_INTERVAL=1", "UNMOUNT_NFS=0", "NFS_SERVER=""""", "NFS_MOUNTPOINT=""""", "NFS_VM_BACKUP_DIR=""""", "WORKDIR_DEBUG=0",
        "VM_SHUTDOWN_ORDER=""""", "VM_STARTUP_ORDER="""""
    )
    $ghettoConfContent = ($confLines -join "`n") + "`n"; $remoteGhettoConfPath = "$ghettoPath/ghettoVCB.conf"; $remoteVmListPath = "$ghettoPath/vms_to_backup.txt"
    Write-GuiLog "Speichere GhettoVCB-Konfiguration nach $ghettoPath..."; $sftpSession = $null

    try {
        $ErrorActionPreference = "Stop"
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "mkdir -p '$ghettoPath' && chmod +x '$ghettoPath'" | Out-Null
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
        Set-SFTPContent -SFTPSession $sftpSession -Path $remoteGhettoConfPath -Value $ghettoConfContent -Encoding UTF8
        Write-GuiLog "ghettoVCB.conf hochgeladen."
        $unixVmListText = ($vmListText.Split([string[]]@("`r`n","`r","`n"), [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() }) -join "`n"
        if (-not [string]::IsNullOrEmpty($unixVmListText)) { $unixVmListText += "`n" }
        Set-SFTPContent -SFTPSession $sftpSession -Path $remoteVmListPath -Value $unixVmListText -Encoding UTF8
        Write-GuiLog "VM-Liste hochgeladen."
        Write-GuiLog "Konfiguration erfolgreich gespeichert!"
        return $true
    } catch {
        Write-GuiLog "Fehler beim Speichern: $($_.Exception.Message)"
        return $false
    } finally {
        if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession -EA 0 }
        $ErrorActionPreference = "Continue"
    }
}


# =====================================================================================
# --- START BLOCK (Speicher-Funktion V7.3 - Mit Display Name) ---
# =====================================================================================

function Save-HostGuiSettings {
    param(
        [string]$FilePath
    )

    if (-not $FilePath) {
        Write-GuiLog "FEHLER: Kein Dateipfad zum Speichern angegeben."; return
    }

    $settings = @{
        # GUI Version & Settings Schema
        Version             = "7.9.1"

        # Verbindung & Pfade
        EsxiIp              = $textboxIp.Text
        EsxiUser            = $textboxUser.Text
        GhettoPath          = $textboxGhettoPath.Text

        # Backup-Konfiguration
        BackupVol           = $textboxBackupVol.Text
        Subfolder           = $textboxSubfolder.Text
        Rotation            = $textboxRotation.Text
        FixedBackupDir      = $checkboxFixedBackupDir.Checked
        DiskFormat          = $comboboxDiskFormat.SelectedItem
		DisableHolePunch    = $checkboxDisablePunch.Checked
        SnapMem             = $checkboxSnapMem.Checked
        SnapQuiesce         = $checkboxSnapQuiesce.Checked
        VmList              = $textboxVmList.Text

        # Zeitplanung
        ScheduleHour        = $textboxScheduleHour.Text
        ScheduleMinute      = $textboxScheduleMinute.Text
        ScheduleDays        = @{}
        RepeatMode          = $comboRepeatMode.Text
        ScheduleType        = if ($radioScheduleReplication.Checked) { 'Replication' } elseif ($radioScheduleRestoreClone.Checked) { 'RestoreClone' } else { 'Backup' }

        # E-Mail
        EmailLog            = $checkboxEmailLog.Checked
        EmailTo             = $textboxEmailTo.Text
        EmailFrom           = $textboxEmailFrom.Text
        EmailDisplayName    = $textboxEmailDisplay.Text
        EmailServer         = $textboxEmailServer.Text
        EmailPort           = $textboxEmailPort.Text
        EmailSubject        = $textboxEmailSubject.Text
        EmailUser           = $textboxEmailUser.Text
        EmailPass           = $textboxEmailPassword.Text

        # Replikation & Klon/Restore
        ReplTargetHost      = $textboxDrTargetHost.Text
        ReplTargetDatastore = $textboxDrTargetDs.Text
        ReplSuffix          = $textboxDrSuffix.Text
        ReplUseLocalTemp    = $checkboxUseLocalTemp.Checked
        ReplTempPath        = $textboxDrTempPath.Text

        RestoreIsRestoreMode = $radioRestoreFromBackup.Checked
        RestoreSource       = $textboxRestoreSourcePath.Text
        RestoreTargetDs     = $textboxRestoreTargetPath.Text
        RestoreNewVmName    = $textboxRestoreNewVmName.Text
        RestoreUuidActionMoved = $radioRestoreMoved.Checked
        RestorePowerOn      = $checkboxPowerOnAfterRestore.Checked
    }

    foreach ($dayEntry in $checkboxDays.GetEnumerator()) {
        $settings.ScheduleDays[$dayEntry.Name] = $dayEntry.Value.Checked
    }

    try {
        $settings | ConvertTo-Json -Depth 5 | Set-Content -Path $FilePath -Encoding UTF8
        Write-GuiLog "Job-Konfiguration erfolgreich in '$FilePath' gespeichert."
        Populate-JobComboBox
    }
    catch {
        Write-GuiLog "FEHLER beim Speichern der Job-Konfiguration: $($_.Exception.Message)"
    }
}

# =====================================================================================
# --- END BLOCK ---
# =====================================================================================


# =====================================================================================
# --- START BLOCK (Lade-Funktion V7.10 - Variable Sync Fix) ---
# =====================================================================================

function Load-HostGuiSettings {
    param(
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        Write-GuiLog "FEHLER: Die Einstellungsdatei '$FilePath' wurde nicht gefunden."; return
    }

    Write-GuiLog "Lade Job-Konfiguration aus '$FilePath'..."

    try {
        $settings = Get-Content -Path $FilePath -Raw | ConvertFrom-Json

        # Lade Verbindung & Pfade
        $textboxIp.Text             = $settings.EsxiIp
        $textboxUser.Text           = $settings.EsxiUser
        $textboxGhettoPath.Text     = $settings.GhettoPath

        # Lade Backup-Konfiguration
        $textboxBackupVol.Text      = $settings.BackupVol
        $textboxSubfolder.Text      = $settings.Subfolder
        $textboxRotation.Text       = $settings.Rotation
        $checkboxFixedBackupDir.Checked = $settings.FixedBackupDir
        $comboboxDiskFormat.SelectedItem = $settings.DiskFormat
		$checkboxDisablePunch.Checked = $settings.DisableHolePunch
        $checkboxSnapMem.Checked    = $settings.SnapMem
        $checkboxSnapQuiesce.Checked = $settings.SnapQuiesce
        $textboxVmList.Text         = $settings.VmList

        # Lade Zeitplanung
        $textboxScheduleHour.Text   = $settings.ScheduleHour
        $textboxScheduleMinute.Text = $settings.ScheduleMinute

        if ($settings.ScheduleDays) {
            foreach ($dayEntry in $settings.ScheduleDays.PSObject.Properties) {
                if ($checkboxDays.ContainsKey($dayEntry.Name)) {
                    $checkboxDays[$dayEntry.Name].Checked = $dayEntry.Value
                }
            }
        }

        # Wiederholungsmodus
        if ($settings.PSObject.Properties.Name -contains 'RepeatMode') {
            $comboRepeatMode.Text = $settings.RepeatMode
        } else {
            $comboRepeatMode.SelectedIndex = 0
        }

        # Job-Typ
        switch ($settings.ScheduleType) {
            'Replication'  { $radioScheduleReplication.Checked = $true }
            'RestoreClone' { $radioScheduleRestoreClone.Checked = $true }
            default        { $radioScheduleBackup.Checked = $true }
        }

        # Lade E-Mail-Einstellungen
        $checkboxEmailLog.Checked   = $settings.EmailLog
        $textboxEmailTo.Text        = $settings.EmailTo
        $textboxEmailFrom.Text      = $settings.EmailFrom
        
        if (-not [string]::IsNullOrWhiteSpace($settings.EmailDisplayName)) {
            $textboxEmailDisplay.Text = $settings.EmailDisplayName
        } else {
            $textboxEmailDisplay.Text = "ESXi Backup"
        }

        $textboxEmailServer.Text    = $settings.EmailServer
        $textboxEmailPort.Text      = $settings.EmailPort
        $textboxEmailSubject.Text   = $settings.EmailSubject
        $textboxEmailUser.Text      = $settings.EmailUser
        $textboxEmailPassword.Text  = $settings.EmailPass

        # --- FIX V7.10: GUI & VARIABLE SYNC ---
        $textboxDrTargetHost.Text   = $settings.ReplTargetHost
        $textboxDrTargetDs.Text     = $settings.ReplTargetDatastore
        $textboxDrSuffix.Text       = $settings.ReplSuffix
        
        # DEBUG
        $dbgTempPath = $settings.ReplTempPath
        $dbgUseLocal = $settings.ReplUseLocalTemp
        Write-GuiLog "DEBUG: JSON TempPath='$dbgTempPath', UseLocal='$dbgUseLocal'"
        
        # 1. Variable laden
        $shouldUseLocal = $false
        if ($settings.ReplUseLocalTemp -eq $true) { $shouldUseLocal = $true }
        $script:replicationUseLocalTemp = $shouldUseLocal
        
        # 2. Checkbox setzen
        $checkboxUseLocalTemp.Checked = $shouldUseLocal
        
        # 3. GUI Events verarbeiten
        [System.Windows.Forms.Application]::DoEvents()
        
        # 4. Textfeld und Variablen setzen
        if (-not $shouldUseLocal) {
            $textboxDrTempPath.Enabled = $true
            $buttonBrowseDrTempPath.Enabled = $true
            
            if ($settings.ReplTempPath) {
                # A) Setze Textfeld
                $textboxDrTempPath.Text = [string]$settings.ReplTempPath
                
                # B) WICHTIG: Setze auch die vermuteten Skript-Variablen!
                # Damit der Button beim Öffnen den Wert nicht mit "leer" überschreibt.
                $script:drTempPath = [string]$settings.ReplTempPath
                $script:replicationTempPath = [string]$settings.ReplTempPath
            }
        } else {
            $textboxDrTempPath.Enabled = $false
            $buttonBrowseDrTempPath.Enabled = $false
        }
        # ------------------------------------------------------

        $radioRestoreFromBackup.Checked = $settings.RestoreIsRestoreMode
        $textboxRestoreSourcePath.Text = $settings.RestoreSource
        $textboxRestoreTargetPath.Text = $settings.RestoreTargetDs
        $textboxRestoreNewVmName.Text = $settings.RestoreNewVmName
        $radioRestoreMoved.Checked  = $settings.RestoreUuidActionMoved
        $checkboxPowerOnAfterRestore.Checked = $settings.RestorePowerOn

        # VM-Liste synchronisieren (falls verbunden)
        if ($Global:ESXiSession -and $Global:ESXiSession.Connected) {
            Write-GuiLog "Lade aktuelle VM-Liste vom Host, um die Auswahl zu synchronisieren..."
            Load-VMListFromESXi
            
            Write-GuiLog "Synchronisiere VM-Auswahlliste basierend auf geladenem Job..."
            $loadedVmNames = $textboxVmList.Text.Split([string[]]@("`r`n","`r","`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
            
            for ($i = 0; $i -lt $checkedListBoxVms.Items.Count; $i++) {
                $item = $checkedListBoxVms.Items[$i]
                $checkedListBoxVms.SetItemChecked($i, ($loadedVmNames -contains $item.OriginalName))
            }
            Write-GuiLog "VM-Auswahl synchronisiert."
        } else {
            Write-GuiLog "Keine Host-Verbindung aktiv. VM-Auswahl konnte nicht synchronisiert werden."
        }

        Write-GuiLog "Job-Konfiguration erfolgreich geladen."
    }
    catch {
        Write-GuiLog "FEHLER: Konnte Job-Datei '$FilePath' nicht laden oder parsen. $($_.Exception.Message)"
    }
}

# =====================================================================================
# --- END BLOCK ---
# =====================================================================================


# ---------------------------------------------------
# --- Shell-Skript-Vorlage für den 2-wöchentlichen Cron-Job ---
# ----------------------------------------------------------------

$biWeeklyHelperScriptContent = @'
#!/bin/sh
# GhettoGUI Bi-Weekly Wrapper v1.0

# Ermittle die aktuelle Kalenderwoche des Jahres (ISO 8601 Standard, z.B. 41, 42)
WEEK_NUMBER=$(date +%V)

# Prüfe, ob die Wochennummer gerade ist (Rest bei Teilung durch 2 ist 0)
if [ $(expr $WEEK_NUMBER % 2) -eq 0 ]; then
    # Es ist eine gerade Woche -> Führe den übergebenen Befehl aus
    # "$@" ist eine spezielle Variable, die alle an das Skript übergebenen Argumente als Befehl ausführt
    "$@"
else
    # Es ist eine ungerade Woche -> Tue nichts und beende das Skript
    exit 0
fi
'@

# =====================================================================================


# In GhettoGUI_V8.0.1.36.ps1
# ERSETZE den gesamten Block function Start-GhettoVCBBackupJob

function Start-GhettoVCBBackupJob {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return $false };
    $ghettoPathOnESXi = $textboxGhettoPath.Text;
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "Fehler: GhettoVCB-Pfad im GUI ist nicht gesetzt."; return $false };

    $jobStarted = $false;
    $ghettoScript = "'$ghettoPathOnESXi/ghettoVCB.sh'";
    $ghettoConfigFile = "'$ghettoPathOnESXi/ghettoVCB.conf'";
    $ghettoVmListFile = "'$ghettoPathOnESXi/vms_to_backup.txt'";
    
    # --- KORRIGIERT: Log-Datei wird jetzt im /logs Unterordner gespeichert ---
    $logFile = "'$ghettoPathOnESXi/logs/ghettoVCB-last_manual_run.log'";
    $backupCommand = "$ghettoScript -g $ghettoConfigFile -f $ghettoVmListFile -l $logFile";
    $nohupCommand = "nohup $backupCommand >> $logFile 2>&1 &";
    
    Write-GuiLog "Starte Backup-Prozess auf ESXi im Hintergrund...";
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor;
    try {
        Write-GuiLog "Säubere eventuell vorhandenes temporäres Verzeichnis...";
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm -rf /tmp/ghettoVCB.work" | Out-Null;
        
        # KORRIGIERT: Löscht die Log-Datei im neuen Pfad, damit sie neu geschrieben wird.
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm -f $logFile" | Out-Null;
        
        # KORREKTUR: Stelle sicher, dass der logs-Ordner existiert (für die VMX-Pfade)
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "mkdir -p '$ghettoPathOnESXi/logs'" | Out-Null
        
        $result = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $nohupCommand;
        if ($result.ExitStatus -eq 0) {
            Write-GuiLog "Backup erfolgreich im Hintergrund gestartet. Der Prozess läuft nun eigenständig auf dem Host.";
            $jobStarted = $true
        } else {
            Write-GuiLog "FEHLER beim Starten des Backup-Prozesses (Exit Code: $($result.ExitStatus)).";
            if ($result.Error) { $result.Error | ForEach-Object { Write-GuiLog "ERR: $_" } }
        }
    } catch {
        Write-GuiLog "Ausnahmefehler beim Starten des Backups: $($_.Exception.Message)"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    };
    return $jobStarted
}

# In GhettoGUI_V8.0.1.36.ps1
# ERSETZE den gesamten Block function Get-BackupJobLog

function Get-BackupJobLog {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }
    $ghettoPathOnESXi = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "Fehler: GhettoVCB-Pfad im GUI ist nicht gesetzt."; return }

    # NEU: Finde die aktuellste Log-Datei von einem geplanten oder manuellen Lauf
    $logDir = "'$ghettoPathOnESXi/logs'"
    
    # KORRIGIERT: Sucht nach dem festen manuellen Log und den dateibasierten Logs im /logs-Ordner
    $findLatestLogCmd = "ls -t $logDir/ghettoVCB-last_manual_run.log $logDir/*.log 2>/dev/null | head -n 1"
    
    Write-GuiLog "Suche nach der aktuellsten Log-Datei im Verzeichnis $logDir..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $latestLogPathResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $findLatestLogCmd
        $logFile = $latestLogPathResult.Output -join ''

        if ([string]::IsNullOrWhiteSpace($logFile)) {
            Write-GuiLog "Keine passende Log-Datei gefunden. Bitte warten Sie einen Moment nach dem Start des Backups."
            return
        }

        Write-GuiLog "Lese Log-Datei vom Host: '$logFile'"
        $catCmd = "cat '$logFile'"
        $logResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $catCmd
        
        Write-GuiLog "--- START GhettoVCB Log ($([System.IO.Path]::GetFileName($logFile))) ---"
        $outputBox.Clear()
        $finalStatusFound = $false
        if ($logResult.Output) {
            $logResult.Output | ForEach-Object { Write-GuiLog $_; if ($_ -match "## Final status:") { $finalStatusFound = $true } }
        } else {
            Write-GuiLog "(Log-Datei ist leer)"
        }
        Write-GuiLog "--- ENDE GhettoVCB Log ---"

        if ($finalStatusFound -and $Global:logPollTimer.Enabled) {
            Write-GuiLog "Backup abgeschlossen! Automatischer Log-Abruf wird beendet."
            $Global:logPollTimer.Stop()
            $buttonStartBackup.Enabled = $true
            $buttonCheckBackupStatus.Enabled = $true
            $buttonCancelBackup.Enabled = $false
        }
    } catch {
        Write-GuiLog "Ausnahmefehler beim Abrufen des Logs: $($_.Exception.Message)"
        if ($Global:logPollTimer.Enabled) {
            Write-GuiLog "Automatischer Log-Abruf wegen Fehler gestoppt."
            $Global:logPollTimer.Stop()
            $buttonStartBackup.Enabled = $true; $buttonCheckBackupStatus.Enabled = $true; $buttonCancelBackup.Enabled = $false
        }
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}


function Browse-BackupDir { if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }; $baseBackupPath = $textboxBackupVol.Text.TrimEnd('/'); $subfolder = $textboxSubfolder.Text.Trim('/'); $fullBackupPath = if (-not [string]::IsNullOrWhiteSpace($subfolder)) { "$baseBackupPath/$subfolder" } else { $baseBackupPath }; if ([string]::IsNullOrWhiteSpace($fullBackupPath)) { Write-GuiLog "Fehler: Backup Volume Pfad ist nicht angegeben."; return }; Write-GuiLog "Frage Inhalt von '$fullBackupPath' ab (rekursiv)..."; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; try { $command = "ls -lR '$fullBackupPath'"; $result = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $command; Write-GuiLog "--- Inhalt von $fullBackupPath ---"; if ($result.ExitStatus -eq 0) { if ($result.Output) { $result.Output | ForEach-Object { Write-GuiLog $_ } } else { Write-GuiLog "(Verzeichnis ist leer)" } } else { Write-GuiLog "FEHLER beim Auslesen des Verzeichnisses (Exit Code: $($result.ExitStatus))."; if ($result.Error) { $result.Error | ForEach-Object { Write-GuiLog "ERR: $_" } } }; Write-GuiLog "--- Ende der Liste ---" } catch { Write-GuiLog "Ausnahmefehler beim Abfragen des Verzeichnisinhalts: $($_.Exception.Message)" } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default } }

# ---############ function Show-DatastoreSelectionDialog SSHSession

function Show-DatastoreSelectionDialog {
    param(
        $SSHSession = $Global:ESXiSession
    )

    $datastoreForm = New-Object System.Windows.Forms.Form; $datastoreForm.Text = "Datastore auswählen"; $datastoreForm.Size = New-Object System.Drawing.Size(500, 350); $datastoreForm.StartPosition = "CenterParent"; $datastoreForm.FormBorderStyle = 'FixedDialog'; $datastoreForm.MaximizeBox = $false; $datastoreForm.MinimizeBox = $false; $datastoreForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $datastoreForm.Tag = $null; $labelInfoDs = New-Object System.Windows.Forms.Label; $labelInfoDs.Text = "Verfügbare VMFS-Datastores:"; $labelInfoDs.Location = New-Object System.Drawing.Point(10, 10); $labelInfoDs.AutoSize = $true; $datastoreForm.Controls.Add($labelInfoDs); $listBoxDatastores = New-Object System.Windows.Forms.ListBox; $listBoxDatastores.Location = New-Object System.Drawing.Point(10, 35); $listBoxDatastores.Size = New-Object System.Drawing.Size(465, 220); $listBoxDatastores.DisplayMember = "DisplayName"; $datastoreForm.Controls.Add($listBoxDatastores); $buttonOkDs = New-Object System.Windows.Forms.Button; $buttonOkDs.Text = "Auswählen"; $buttonOkDs.Location = New-Object System.Drawing.Point( ([int]$listBoxDatastores.Left + [int]$listBoxDatastores.Width - 170), 270); $buttonOkDs.Size = New-Object System.Drawing.Size(80, 25); $buttonOkDs.DialogResult = [System.Windows.Forms.DialogResult]::OK; $buttonOkDs.Enabled = $false; $buttonOkDs.Add_Click({ if ($listBoxDatastores.SelectedItem) { $datastoreForm.Tag = $listBoxDatastores.SelectedItem.PathToUse }; $datastoreForm.Close() }); $datastoreForm.Controls.Add($buttonOkDs); $datastoreForm.AcceptButton = $buttonOkDs; $buttonCancelDs = New-Object System.Windows.Forms.Button; $buttonCancelDs.Text = "Abbrechen"; $buttonCancelDs.Location = New-Object System.Drawing.Point( ([int]$listBoxDatastores.Left + [int]$listBoxDatastores.Width - 80), 270); $buttonCancelDs.Size = New-Object System.Drawing.Size(80, 25); $buttonCancelDs.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $datastoreForm.Controls.Add($buttonCancelDs); $datastoreForm.CancelButton = $buttonCancelDs; $listBoxDatastores.Add_SelectedIndexChanged({ $buttonOkDs.Enabled = ($listBoxDatastores.SelectedItem -ne $null) }); $listBoxDatastores.Add_DoubleClick({ if ($listBoxDatastores.SelectedItem) { $buttonOkDs.PerformClick() } });

    $datastoreForm.Add_Shown({
        Write-GuiLog "Lade Datastore-Liste...";
        $datastoreForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor;
        $listBoxDatastores.Items.Clear();
        try {
            if (-not ($SSHSession -and $SSHSession.Connected)) {
                [System.Windows.Forms.MessageBox]::Show($datastoreForm, "Keine aktive ESXi-Verbindung zum Abrufen der Datastores.", "Fehler", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error); $datastoreForm.Close(); return
            };
            $sshOutput = Invoke-SSHCommand -SSHSession $SSHSession -Command "esxcli storage filesystem list";
            $outputLines = if ($sshOutput.Output -is [array]) { $sshOutput.Output } else { @($sshOutput.Output -split [Environment]::NewLine) };
            $headerSkippedDs = $false;
            foreach ($line in $outputLines) {
                if (-not $headerSkippedDs) { if ($line -match "Mount Point\s+Volume Name") { $headerSkippedDs = $true }; continue };
                if ($line -match "^/vmfs/volumes/" -and ($line -match "(VMFS-L|VMFS-5|VMFS-6|NFS)" )) {
                    $parts = $line -split '\s+' | Where-Object {$_};
                    if ($parts.Count -ge 2) {
                        $mountPoint = $parts[0];
                        $volumeName = $parts[1];
                        
                        # ### KORRIGIERTE LOGIK ###
                        # PathToUse ist IMMER der zuverlässige Mount Point (mit UUID)
                        $pathToUse = $mountPoint
                        
                        # DisplayName ist der freundliche Name für den Benutzer
                        $displayName = $volumeName
                        
                        # Wenn sich der Anzeigename vom Mount-Point-Namen unterscheidet, zeige beides an.
                        if ($volumeName -ne ($mountPoint -split '/')[-1]) {
                           $displayName = "$volumeName ($mountPoint)"
                        }

                        $listBoxDatastores.Items.Add([PSCustomObject]@{ DisplayName = $displayName; PathToUse = $pathToUse })
                    }
                }
            };
            Write-GuiLog "$($listBoxDatastores.Items.Count) Datastores gefunden."
        } catch {
            Write-GuiLog "Fehler Datastore-Liste: $($_.Exception.Message)";
            [System.Windows.Forms.MessageBox]::Show($datastoreForm, "Fehler Datastore-Liste: $($_.Exception.Message)", "Fehler", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } finally {
            $datastoreForm.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    });

    $dialogResult = $datastoreForm.ShowDialog($form);
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) { return $datastoreForm.Tag } else { return $null }
}

# -#### function Show-DatastoreSelectionDialog SSH

# ----------------------------------------------

function Show-DatastoreSelectionDialogForRemoval {
    param(
        [object]$SshSession
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Datastore zum Entfernen auswählen, zum aktualisieren: vmkfstools -V "
    $dialog.Size = New-Object System.Drawing.Size(550, 450)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = 'FixedDialog'

    $labelInfo = New-Object System.Windows.Forms.Label; $labelInfo.Text = "Verfügbare Datastores:"; $labelInfo.Location = New-Object System.Drawing.Point(15, 15); $labelInfo.AutoSize = $true
    
    $listbox = New-Object System.Windows.Forms.ListBox; $listbox.Location = New-Object System.Drawing.Point(15, 40); $listbox.Size = New-Object System.Drawing.Size(500, 300); $listbox.Font = New-Object System.Drawing.Font("Consolas", 10)

    $buttonOk = New-Object System.Windows.Forms.Button; $buttonOk.Text = "Auswählen"; $buttonOk.Location = New-Object System.Drawing.Point(350, 360); $buttonOk.DialogResult = [System.Windows.Forms.DialogResult]::OK; $buttonOk.Enabled = $false
    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.Location = New-Object System.Drawing.Point(440, 360); $buttonCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dialog.Controls.AddRange(@($labelInfo, $listbox, $buttonOk, $buttonCancel))
    $dialog.AcceptButton = $buttonOk; $dialog.CancelButton = $buttonCancel
    $listbox.Add_SelectedIndexChanged({ $buttonOk.Enabled = ($listbox.SelectedItem -ne $null) })
    $dialog.Add_Shown({
        $dialog.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $result = Invoke-SSHCommand -SSHSession $SshSession -Command "esxcli storage filesystem list"
            if ($result.ExitStatus -eq 0 -and $result.Output.Count -gt 2) {
                $displayItems = $result.Output | Select-Object -Skip 2 | ForEach-Object {
                    $line = $_
                    if ($line -match '^\s*(/vmfs/volumes/([0-9a-f\-]+))\s+(.+?)\s+') {
                        $mountPoint = $Matches[1].Trim()
                        $volumeName = $Matches[3].Trim()
                        "$volumeName ($mountPoint)"
                    }
                }
                $listbox.Items.AddRange(($displayItems | Where-Object {$_}))
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Fehler beim Laden der Datastore-Liste: $($_.Exception.Message)", "Fehler", "OK", "Error")
        } finally {
            $dialog.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    if ($dialog.ShowDialog($sshConsoleForm) -eq 'OK') {
        return $listbox.SelectedItem
    }
    return $null
}
# ------------------------------------


function Load-VMListFromESXi { if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }; Write-GuiLog "Lade VM-Liste von ESXi..."; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; $checkedListBoxVms.Items.Clear(); try { $sshOutput = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "vim-cmd vmsvc/getallvms"; $outputLines = if ($sshOutput.Output -is [array]) { $sshOutput.Output } else { @($sshOutput.Output -split [Environment]::NewLine) }; $headerSkippedVmLoad = $false; foreach ($line in $outputLines) { $trimmedLine = $line.Trim(); if (-not $headerSkippedVmLoad) { if ($trimmedLine -match '^\s*Vmid\s+Name') { $headerSkippedVmLoad = $true; continue }}; if ([string]::IsNullOrWhiteSpace($trimmedLine)) { continue }; $originalVmName = $null; if ($trimmedLine -match '^\s*(\d+)\s+([^\[]+?)\s+\[.+') { $originalVmName = $Matches[2].Trim() } elseif ($trimmedLine -match '^\s*(\d+)\s+(.+?)\s+\S+\.vmx') { $originalVmName = $matches[2].Trim() } else { $parts = $trimmedLine -split '\s+' | Where-Object {$_}; if ($parts.Count -ge 2 -and $parts[0] -match '^\d+$') { $originalVmName = $parts[1]; if ($parts.Count -gt 2) { for ($i = 2; $i -lt $parts.Count; $i++) { if ($parts[$i].StartsWith("[")) { break }; $originalVmName += " " + $parts[$i] }}}}; if (-not [string]::IsNullOrWhiteSpace($originalVmName)) { $displayVmName = ConvertTo-DisplaySafeString -InputString $originalVmName; $checkedListBoxVms.Items.Add([PSCustomObject]@{ OriginalName = $originalVmName; DisplayName = $displayVmName }, $false) }}; Write-GuiLog "$($checkedListBoxVms.Items.Count) VMs zur Auswahl geladen." } catch { Write-GuiLog "Fehler beim Laden der VM-Liste: $($_.Exception.Message)" } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }}
function Apply-SelectedVMsToVmList { $selectedOriginalVms = $checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }; $textboxVmList.Text = $selectedOriginalVms -join [Environment]::NewLine; Write-GuiLog "$($selectedOriginalVms.Count) VM(s) in die Backup-Liste übernommen."}
# function Install-GhettoVCBFromGitHub { $ghettoVCBZipUrl = "https://github.com/lamw/ghettoVCB/archive/refs/heads/master.zip"; $tempZipFileName = $null; $ErrorActionPreference = "Stop"; Write-GuiLog "Starte GhettoVCB Installation von GitHub..."; try { $tempZipFile = New-TemporaryFile; $tempZipFileName = $tempZipFile.FullName; $tempZipFile.Delete(); Write-GuiLog "Lade GhettoVCB von GitHub..."; Invoke-WebRequest -Uri $ghettoVCBZipUrl -OutFile $tempZipFileName -UseBasicParsing; Write-GuiLog "Download abgeschlossen: '$tempZipFileName'."; Execute-GhettoVCBInstallation -localZipFilePath $tempZipFileName } catch { Write-GuiLog "FEHLER beim GitHub-Download: $($_.Exception.Message)" } finally { if ($tempZipFileName -and (Test-Path $tempZipFileName)) { Write-GuiLog "Lösche temporäre ZIP-Datei: '$tempZipFileName'"; Remove-Item $tempZipFileName -Force -EA 0 }; $ErrorActionPreference = "Continue" }}

function Start-GhettoVCBInstallationFlow {
    $choice = Show-InstallationSourceDialog -Title "Quelle für GhettoVCB wählen" -Message "Möchten Sie GhettoVCB von GitHub oder von einer lokalen ZIP-Datei installieren?"
    
    if ($choice -eq 'Yes') {
        Install-GhettoVCBFromGitHub
    }
    elseif ($choice -eq 'No') {
        Install-GhettoVCBFromLocalFile
    }
    
}

# ANGEPASST: Die bestehende GitHub-Funktion
function Install-GhettoVCBFromGitHub {
    $ghettoVCBZipUrl = "https://github.com/lamw/ghettoVCB/archive/refs/heads/master.zip"
    $tempZipFileName = $null
    $ErrorActionPreference = "Stop"
    Write-GuiLog "Starte GhettoVCB Installation von GitHub..."
    try {
        $tempZipFile = New-TemporaryFile
        $tempZipFileName = $tempZipFile.FullName
        $tempZipFile.Delete()
        Write-GuiLog "Lade GhettoVCB von GitHub..."
        Invoke-WebRequest -Uri $ghettoVCBZipUrl -OutFile $tempZipFileName -UseBasicParsing
        Write-GuiLog "Download abgeschlossen: '$tempZipFileName'."
        Execute-GhettoVCBInstallation -localZipFilePath $tempZipFileName
    Write-GuiLog "Original GhettoVCB erfolgreich installiert"
        [System.Windows.Forms.MessageBox]::Show("Original GhettoVCB erfolgreich installiert", "Installation erfolgreich", "OK", "Information")
    } catch {
        Write-GuiLog "FEHLER bei der Installation: $($_.Exception.Message)"
    } finally {
        if ($tempZipFileName -and (Test-Path $tempZipFileName)) {
            Write-GuiLog "Lösche temporäre ZIP-Datei: '$tempZipFileName'"
            Remove-Item $tempZipFileName -Force -EA 0
        }
        $ErrorActionPreference = "Continue"
    }
}

# NEU: Die Funktion für die Installation von einer lokalen Datei
function Install-GhettoVCBFromLocalFile {
    Write-GuiLog "Starte GhettoVCB Installation von lokaler Datei..."
    try {
        $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $openFileDialog.Title = "Lokale GhettoVCB ZIP-Datei auswählen"
        $openFileDialog.Filter = "ZIP-Dateien (*.zip)|*.zip"
        if ($openFileDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $localZipFilePath = $openFileDialog.FileName
            Write-GuiLog "Ausgewählte Datei: '$localZipFilePath'"
            Execute-GhettoVCBInstallation -localZipFilePath $localZipFilePath
        } else {
            Write-GuiLog "Keine Datei ausgewählt. Installation abgebrochen."
        }
    } catch {
        Write-GuiLog "FEHLER bei Auswahl der lokalen Datei: $($_.Exception.Message)"
    }
}

function Install-GhettoVCBFromLocalFile { Write-GuiLog "Starte GhettoVCB Installation von lokaler Datei..."; try { $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog; $openFileDialog.Title = "Lokale GhettoVCB ZIP-Datei auswählen"; $openFileDialog.Filter = "ZIP-Dateien (*.zip)|*.zip"; if ($openFileDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $localZipFilePath = $openFileDialog.FileName; Write-GuiLog "Ausgewählte Datei: '$localZipFilePath'"; Execute-GhettoVCBInstallation -localZipFilePath $localZipFilePath } else { Write-GuiLog "Keine Datei ausgewählt. Installation abgebrochen." }} catch { Write-GuiLog "FEHLER bei Auswahl der lokalen Datei: $($_.Exception.Message)" }}
function Execute-GhettoVCBInstallation { param( [Parameter(Mandatory=$true)] [string]$localZipFilePath ); if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }; if (-not $Global:ESXiConnectedHostName) { Write-GuiLog "Fehler: Hostname für SFTP/Installation nicht verfügbar."; return }; if (-not $Global:ESXiSshCredential) { Write-GuiLog "Fehler: SSH-Anmeldeinformationen für SFTP/Installation nicht gefunden."; return }; $ghettoPathOnESXi = $textboxGhettoPath.Text; if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "Fehler: GhettoVCB-Installationspfad nicht gesetzt."; return }; $sftpSession = $null; $ErrorActionPreference = "Stop"; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; try { Write-GuiLog "Leere/Erstelle Zielverzeichnis '$ghettoPathOnESXi'..."; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm -rf '$ghettoPathOnESXi'" -EA SilentlyContinue | Out-Null; $mkdirCommand = "mkdir -p '$ghettoPathOnESXi'"; $mkdirOutput = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $mkdirCommand; if ($mkdirOutput.ExitStatus -ne 0) { Write-GuiLog "FEHLER: Konnte '$ghettoPathOnESXi' nicht erstellen (Exit: $($mkdirOutput.ExitStatus))."; return }; Write-GuiLog "Zielverzeichnis '$ghettoPathOnESXi' erstellt."; Write-GuiLog "Erstelle SFTP-Sitzung..."; $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -EA Stop -ConnectionTimeout 60; Write-GuiLog "SFTP-Sitzung erstellt."; $remoteZipPath = "$ghettoPathOnESXi/ghettoVCB_upload.zip"; Write-GuiLog "Lade ZIP nach '$remoteZipPath'..."; $localFileStream = $null; $remoteSftpStream = $null; try { $localFileStream = New-Object System.IO.FileStream($localZipFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read); $remoteSftpStream = New-SFTPFileStream -SFTPSession $sftpSession -Path $remoteZipPath -FileMode Create -FileAccess Write; $localFileStream.CopyTo($remoteSftpStream) } finally { if ($remoteSftpStream) { $remoteSftpStream.Close(); $remoteSftpStream.Dispose() }; if ($localFileStream) { $localFileStream.Close(); $localFileStream.Dispose() } }; Write-GuiLog "ZIP erfolgreich hochgeladen."; $extractBaseDir = $ghettoPathOnESXi; Write-GuiLog "Entpacke '$remoteZipPath' nach '$extractBaseDir'..."; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "unzip -o '$remoteZipPath' -d '$extractBaseDir'" | Out-Null; $findMasterFolderCmd = "ls -d $extractBaseDir/ghettoVCB-master*/ 2>/dev/null || ls -d $extractBaseDir/ghettoVCB-*/ 2>/dev/null || echo ''"; $masterFolderOutputObject = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $findMasterFolderCmd; $extractedMasterFolderNameOnly = $null; if ($null -ne $masterFolderOutputObject -and $null -ne $masterFolderOutputObject.Output) { $outputLinesFromLs = @($masterFolderOutputObject.Output) -join [Environment]::NewLine -split [Environment]::NewLine; $foundFullFolderPath = $outputLinesFromLs | Where-Object {$_ -like "*ghettoVCB*"} | Select-Object -First 1; if (-not [string]::IsNullOrWhiteSpace($foundFullFolderPath)) { $extractedMasterFolderNameOnly = $foundFullFolderPath.Trim().Split('/')[-1] } }; if ([string]::IsNullOrWhiteSpace($extractedMasterFolderNameOnly)) { Write-GuiLog "WARNUNG: Hauptordner nicht gefunden. Fallback 'ghettoVCB-master'."; $extractedMasterFolderNameOnly = "ghettoVCB-master" }; $extractedMainFolderFullPath = "$extractBaseDir/$extractedMasterFolderNameOnly"; Write-GuiLog "Prüfe entpackten Hauptordner: '$extractedMainFolderFullPath'."; $checkFolderExistsCmd = "if [ -d '$extractedMainFolderFullPath' ] && [ '$extractedMainFolderFullPath' != '$($ghettoPathOnESXi.TrimEnd('/'))' ]; then echo 'FOLDER_EXISTS_AND_DIFFERENT'; else echo 'FOLDER_SAME_OR_NOT_EXISTS'; fi"; $folderExistsOutput = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $checkFolderExistsCmd; if (($folderExistsOutput.Output -join "").Contains("FOLDER_EXISTS_AND_DIFFERENT")) { Write-GuiLog "Verschiebe Inhalte von '$extractedMainFolderFullPath'..."; $moveSourcePath = $extractedMainFolderFullPath.TrimEnd('/') + "/"; $moveDestinationPath = $ghettoPathOnESXi.TrimEnd('/') + "/"; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "mv '$moveSourcePath'* '$moveDestinationPath' && rm -rf '$extractedMainFolderFullPath'" | Out-Null; Write-GuiLog "Inhalte verschoben; '$extractedMainFolderFullPath' gelöscht." } else { Write-GuiLog "INFO: Kein separater Hauptordner zum Verschieben gefunden/nötig." }; Write-GuiLog "Setze Ausführungsrechte..."; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$ghettoPathOnESXi'/*.sh" | Out-Null; Write-GuiLog "Berechtigungen gesetzt."; Write-GuiLog "Lösche '$remoteZipPath'..."; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm '$remoteZipPath'" | Out-Null; Write-GuiLog "ZIP auf ESXi gelöscht."; Write-GuiLog "GhettoVCB erfolgreich installiert/aktualisiert!" } catch { Write-GuiLog "FEHLER Installation: $($_.Exception.Message)"; if ($_.Exception.ErrorRecord -and $_.Exception.ErrorRecord.Exception) { Write-GuiLog "Details: $($_.Exception.ErrorRecord.Exception.Message)" }} finally { if ($sftpSession) { Write-GuiLog "Schließe SFTP..."; Remove-SFTPSession -SFTPSession $sftpSession -EA 0; Write-GuiLog "SFTP geschlossen." }; $form.Cursor = [System.Windows.Forms.Cursors]::Default; $ErrorActionPreference = "Continue" }}

######################################
####  function Install-CustomSendmail####
########################################

function Install-CustomSendmail {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }
    $ghettoPathOnESXi = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "FEHLER: Der GhettoVCB-Pfad muss gesetzt sein."; return }
    
    $sendmailUrl = "https://github.com/Chrigel71/GhettoGUI/raw/main/sendmail.py"
    $targetPathOnESXi = "$ghettoPathOnESXi/sendmail"
    $localSourceFilePath = $null
    $tempFile = $null

    $choice = Show-InstallationSourceDialog -Title "Quelle für E-Mail-Skript wählen" -Message "Möchten Sie das sendmail.py Skript von GitHub oder von einer lokalen Datei installieren?"

    if ($choice -eq 'Yes') {
        Write-GuiLog "Starte Download des E-Mail-Skripts..."
        try {
            $tempFile = New-TemporaryFile
            Invoke-WebRequest -Uri $sendmailUrl -OutFile $tempFile.FullName -UseBasicParsing
            $localSourceFilePath = $tempFile.FullName
        } catch {
            Write-GuiLog "FEHLER beim GitHub-Download: $($_.Exception.Message)"; return
        }
    } elseif ($choice -eq 'No') {
        $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $openFileDialog.Title = "Lokale sendmail.py Datei auswählen"
        $openFileDialog.Filter = "Python-Skripte (*.py)|*.py|Alle Dateien (*.*)|*.*"
        if ($openFileDialog.ShowDialog($form) -eq 'OK') {
            $localSourceFilePath = $openFileDialog.FileName
        } else {
            Write-GuiLog "Installation abgebrochen."; return
        }
    } else {
        Write-GuiLog "Installation abgebrochen."; return
    }

    Write-GuiLog "Installiere E-Mail-Skript von '$localSourceFilePath'..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $sftpSession = $null
    try {
        $ErrorActionPreference = "Stop"
        $scriptContentString = Get-Content -Path $localSourceFilePath -Raw
        $contentWithUnixEndings = $scriptContentString.Replace("`r`n", "`n")
        $cleanContent = $contentWithUnixEndings.Replace("`t", "    ")

        Write-GuiLog "Verbinde via SFTP..."
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60

        # NEU: Lösche die alte Datei zuerst, um ein sauberes Überschreiben zu garantieren
        Write-GuiLog "Lösche eventuell vorhandene alte 'sendmail'-Datei auf dem Host..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm -f `"$targetPathOnESXi`"" | Out-Null

        Write-GuiLog "Übertrage Skript nach '$targetPathOnESXi'..."
        Set-SFTPContent -SFTPSession $sftpSession -Path $targetPathOnESXi -Value $cleanContent -Encoding UTF8

        Write-GuiLog "Setze Ausführungsrechte (chmod +x)..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x `"$targetPathOnESXi`"" | Out-Null

        Write-GuiLog "E-Mail-Skript erfolgreich installiert!"
        [System.Windows.Forms.MessageBox]::Show("Das E-Mail-Skript wurde erfolgreich installiert!", "Installation erfolgreich", "OK", "Information")
    } catch {
        Write-GuiLog "FEHLER bei der Installation: $($_.Exception.Message)"
    } finally {
        if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession -EA 0 }
        if ($tempFile -and (Test-Path $tempFile.FullName)) { Remove-Item $tempFile.FullName -Force -EA 0 }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $ErrorActionPreference = "Continue"
    }
}

################################
########## Ende Custom Mail
###############################


function Set-GhettoVCBSchedule {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }; $ghettoPathOnESXi = $textboxGhettoPath.Text; if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "FEHLER: GhettoVCB-Pfad ist nicht gesetzt."; return }; $ghettoConfigFile = "$ghettoPathOnESXi/ghettoVCB.conf"; $ghettoVmListFile = "$ghettoPathOnESXi/vms_to_backup.txt"; $ghettoScript = "$ghettoPathOnESXi/ghettoVCB.sh"; $cronLogFileFixed = "$ghettoPathOnESXi/ghettoVCB-scheduled.log"; $scheduleHour = $textboxScheduleHour.Text.Trim(); $scheduleMinute = $textboxScheduleMinute.Text.Trim(); if (-not ($scheduleHour -match "^\d{1,2}$" -and [int]$scheduleHour -ge 0 -and [int]$scheduleHour -le 23) -or -not ($scheduleMinute -match "^\d{1,2}$" -and [int]$scheduleMinute -ge 0 -and [int]$scheduleMinute -le 59) ) { Write-GuiLog "FEHLER: Ungültige Eingabe für Stunde oder Minute."; return }; $selectedDays = @(); foreach ($cb in $checkboxDays.Values) { if ($cb.Checked) { $selectedDays += $cb.Tag }}; $dayOfWeekString = if ($selectedDays.Count -eq 7 -or $checkboxScheduleAll.Checked) { "*" } elseif ($selectedDays.Count -gt 0) { ($selectedDays | Sort-Object) -join "," } else { $null }; if (-not $dayOfWeekString) { Write-GuiLog "Keine Tage für den Zeitplan ausgewählt. Zeitplan wird deaktiviert."; $isScheduleEnabled = $false } else { $isScheduleEnabled = $true }; $cronJobCommand = "'$ghettoScript' -g '$ghettoConfigFile' -f '$ghettoVmListFile' -l '$cronLogFileFixed'"; $cronComment = "# GhettoVCB-GUI-Scheduled-Backup"; Write-GuiLog "Aktualisiere Cronjob auf ESXi..."; $ErrorActionPreference = "Stop"; try { $removeCronCmd = "sed -i '\@$($cronComment)@d' /var/spool/cron/crontabs/root"; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $removeCronCmd | Out-Null; Write-GuiLog "Alter Cronjob (falls vorhanden) entfernt."; if ($isScheduleEnabled) { $cronEntry = "$scheduleMinute $scheduleHour * * $dayOfWeekString $cronJobCommand $cronComment"; $escapedCronEntry = $cronEntry.Replace("'", "'""'"); $addCmd = "echo '$escapedCronEntry' >> /var/spool/cron/crontabs/root"; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $addCmd | Out-Null; Write-GuiLog "Neuer Cronjob hinzugefügt: $scheduleMinute $scheduleHour * * $dayOfWeekString" } else { Write-GuiLog "Zeitplan ist deaktiviert." }; $reloadCrondCmd = 'kill $(cat /var/run/crond.pid) && crond'; $reloadOutput = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $reloadCrondCmd; if ($reloadOutput.ExitStatus -eq 0) { Write-GuiLog "Cron-Dienst auf ESXi neu geladen." } else { Write-GuiLog "FEHLER Cron-Dienst Neuladen (Exit: $($reloadOutput.ExitStatus))."; if (-not [string]::IsNullOrWhiteSpace($reloadOutput.Error)) { Write-GuiLog "crond (stderr): $($reloadOutput.Error -join [Environment]::NewLine)"}; if (-not [string]::IsNullOrWhiteSpace($reloadOutput.Output)) { Write-GuiLog "crond (stdout): $($reloadOutput.Output -join [Environment]::NewLine)"}}; Write-GuiLog "Zeitplan erfolgreich aktualisiert." } catch { Write-GuiLog "FEHLER Zeitplan: $($_.Exception.Message)" } finally { $ErrorActionPreference = "Continue" }}

function Update-ESXiTimeDisplay {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { 
        Write-GuiLog "Fehler: Nicht mit ESXi verbunden, um Zeit abzufragen."
        $labelEsxiTime.Text = "ESXi nicht verbunden"
        return 
    }
    Write-GuiLog "Frage ESXi-Zeit (UTC) ab..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        # KORREKTUR: Formatierung des 'date'-Befehls mit Tabulator (\t) für mehr Abstand
        $dateOutput = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "date -u +'%T  %Z     %a %b %d %Y'"
        
        if ($dateOutput.ExitStatus -eq 0 -and $dateOutput.Output) {
            $esxiTimeString = ($dateOutput.Output -join " ").Trim()
            Write-GuiLog "ESXi-Zeit (UTC) empfangen: $esxiTimeString"
            $labelEsxiTime.Text = $esxiTimeString
        } else {
            Write-GuiLog "Fehler beim Abfragen der ESXi-Zeit. Exit: $($dateOutput.ExitStatus)"
            if($dateOutput.Error){ Write-GuiLog "ESXi-Zeit Fehler (stderr): $($dateOutput.Error -join [Environment]::NewLine)" }
            $labelEsxiTime.Text = "Fehler bei Abfrage"
        }
    } catch {
        Write-GuiLog "Ausnahmefehler beim Abfragen der ESXi-Zeit: $($_.Exception.Message)"
        $labelEsxiTime.Text = "Ausnahmefehler"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

#  --- Logik Funktion Restore Start --------

# In GhettoGUI_V8.0.1.ps1
# ERSETZE die komplette Funktion Show-DirectorySelectionDialog (V43.9.7 - Finale Version)

function Show-DirectorySelectionDialog {
    param(
        [string]$Title = "Verzeichnis auswählen",
        [string]$BasePath = "/mnt", # Standard für Proxmox
        [Parameter(Mandatory=$true)]
        [object]$SshSession
    )
    $selectionDialog = New-Object System.Windows.Forms.Form; $selectionDialog.Text = $Title; $selectionDialog.Size = New-Object System.Drawing.Size(450, 350); $selectionDialog.StartPosition = "CenterParent"; $selectionDialog.FormBorderStyle = 'FixedDialog'; $selectionDialog.Tag = $null

    # --- GUI-Elemente (unverändert) ---
    $listBox = New-Object System.Windows.Forms.ListBox; $listBox.Dock = 'Top'; $listBox.Height = 250; $listBox.Margin = New-Object System.Windows.Forms.Padding(10)
    $buttonOpen = New-Object System.Windows.Forms.Button; $buttonOpen.Text = "Öffnen"; $buttonOpen.DialogResult = 'OK'; $buttonOpen.Enabled = $false
    $buttonSelectCurrent = New-Object System.Windows.Forms.Button; $buttonSelectCurrent.Text = "Diesen Ordner auswählen"; $buttonSelectCurrent.DialogResult = 'Yes'; $buttonSelectCurrent.Size = New-Object System.Drawing.Size(160, 25)
    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.DialogResult = 'Cancel'
    $flowPanel = New-Object System.Windows.Forms.FlowLayoutPanel; $flowPanel.Dock = 'Bottom'; $flowPanel.FlowDirection = 'RightToLeft'; $flowPanel.Height = 40
    $flowPanel.Controls.AddRange(@($buttonCancel, $buttonOpen, $buttonSelectCurrent))
    $selectionDialog.Controls.AddRange(@($listBox, $flowPanel))
    $selectionDialog.AcceptButton = $buttonOpen; $selectionDialog.CancelButton = $buttonCancel
    $listBox.Add_SelectedIndexChanged({ $buttonOpen.Enabled = ($listBox.SelectedItem -ne $null) }) # Korrigiert
    $listBox.Add_DoubleClick({ if ($listBox.SelectedItem) { $buttonOpen.PerformClick() } })
    # --- Ende GUI-Elemente ---

    # Hilfsfunktion zum Aktualisieren der ListBox
    $updateListBox = {
        param([string]$currentPath)
        $selectionDialog.Text = "Navigiere: $currentPath"
        $listBox.Items.Clear()
        $selectionDialog.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            # --- KORREKTUR (V43.9.7): 'ls -Fp' (universell) statt 'find' ---
            # 1. 'ls -Fp': Listet mit Indikatoren ('/' für Verzeichnisse, '@' für Links etc.)
            #    -F fügt Indikatoren hinzu
            #    -p fügt '/' bei Verzeichnissen hinzu (doppelt hält besser)
            $command = "ls -Fp '$currentPath'"
            # --- ENDE KORREKTUR ---

            $result = Invoke-SSHCommand -SSHSession $SshSession -Command $command -ErrorAction SilentlyContinue

            $listBox.Items.Add(".. (Eine Ebene höher)")
            if ($result.ExitStatus -eq 0 -and $result.Output) {
                # Strenge Filterung (unverändert, fängt "0 0 0" ab)
                $items = $result.Output | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[a-zA-Z0-9_.\-]' } | Sort-Object
                if ($items) {
                    $listBox.Items.AddRange($items)
                }
            } elseif ($result.Error) {
               $logMessage = "Fehler beim Lesen von '{0}' (ls -Fp): {1}" -f $currentPath, ($result.Error -join '; ')
               Write-GuiLog $logMessage
            }
        } catch {
            $errorMessage = $_.Exception.Message
            $logMessage = "Ausnahmefehler beim Lesen von '{0}' (ls -Fp): {1}" -f $currentPath, $errorMessage
            Write-GuiLog $logMessage
        } finally {
            $selectionDialog.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    } # Ende $updateListBox

    # Initialen Inhalt laden
    $currentDirectory = $BasePath.Trim()
    & $updateListBox -currentPath $currentDirectory

    # Navigationslogik
    $finalSelectedPath = $null
    while ($true) {
        $dialogResult = $selectionDialog.ShowDialog($form)
        $selectedItem = $listBox.SelectedItem

        if ($dialogResult -eq 'Yes') {
            # Benutzer klickt "Diesen Ordner auswählen"
            $cleanedPath = $currentDirectory -replace '^[0\s\\]+', ''
            if (-not [string]::IsNullOrWhiteSpace($cleanedPath) -and -not $cleanedPath.StartsWith("/")) {
                $cleanedPath = "/$cleanedPath"
            }
            $finalSelectedPath = $cleanedPath
            break
        } elseif ($dialogResult -eq 'OK' -and $selectedItem) {
            # Navigation
            $itemText = $selectedItem.ToString()
            if ($itemText -eq ".. (Eine Ebene höher)") {
                # Gehe eine Ebene höher
                if ($currentDirectory -ne "/" -and $currentDirectory.Contains("/")) {
                    $parentPath = Split-Path -Path $currentDirectory -Parent
                    if ([string]::IsNullOrWhiteSpace($parentPath)) { $currentDirectory = "/" } else { $currentDirectory = $parentPath }
                    & $updateListBox -currentPath $currentDirectory # Liste aktualisieren
                }
            } elseif ($itemText.EndsWith("/")) {
                # --- KORREKTUR (V43.9.7): Nur navigieren, wenn es ein Verzeichnis ist (endet mit '/') ---
                $dirName = $itemText.TrimEnd('/')
                if ($currentDirectory -eq "/") { $currentDirectory = "/$dirName" } else { $currentDirectory = "$currentDirectory/$dirName".Replace('//','/') }
                & $updateListBox -currentPath $currentDirectory # Liste aktualisieren
            }
            # WENN ES EINE DATEI IST (endet nicht mit '/'), passiert bei "Öffnen" nichts.
            # (Das $dialogResult-Objekt wird in den aufrufenden Funktionen (V5-Logik) korrekt behandelt)
        } else {
            # Abbruch
            $finalSelectedPath = $null
            break
        }
    } # Ende while

    $selectionDialog.Dispose()
    # WICHTIG: Gib ein Objekt zurück, das die aufrufende Logik erwartet
    return @{ Result = $dialogResult; SelectedItem = $selectedItem; CurrentPath = $finalSelectedPath }
}

#  --- Logik Funktion Restore Ende  -------

# --- NEU: Alle ESXi-Controls in den ESXi-Tab einfügen ---
$esxiControls = @(
    $labelJobSelect, $comboboxJobs, $buttonRefreshJobs,
    $labelIp, $textboxIp, $labelUser, $textboxUser, $connectButton, $disconnectButton,
    $buttonCheckPoshSsh, $groupGhettoConfig, $buttonLoadGuiSettings, $buttonSaveGuiSettings,
    $saveConfigButton,
    $buttonInstallGitHub, $buttonInstallPatchedGhetto, $buttonInstallSendmailPy, $buttonOpenSshConsole, $groupSchedule, $groupEmail,
    $buttonStartBackup, $buttonCheckBackupStatus, $buttonCancelBackup, $buttonBrowseBackupDir,
    $outputBox,
    $groupTraffic
)
$esxiTab.Controls.AddRange($esxiControls)
$form.Controls.Add($tabControl)

# ======================================================================================================================

# --------------------------------------------
#  ---- PROXMOX ---------------------------
# --------------------------------------------
# =====================================================================================
# --- START: Kompletter Proxmox-Codeblock (V17 - Neues Layout & Vorbereitung für Zeitplan/E-Mail) ---
# =====================================================================================

# --- Schritt 1: Globale Variablen und Timer für Proxmox definieren ---
$Global:ProxmoxSession = $null
$Global:ProxmoxActiveTasks = New-Object System.Collections.Generic.List[object]
$Global:ProxmoxTaskPollTimer = New-Object System.Windows.Forms.Timer
$Global:ProxmoxTaskPollTimer.Interval = 5000

# --- Schritt 2: Alle benötigten API- und Hilfs-Funktionen definieren ---
function Get-ProxmoxTicket { param([string]$PveHost, [string]$Username, [string]$Password); add-type @"
    using System.Net; using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy { public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; } }
"@; [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy; [System.Net.ServicePointManager]::SecurityProtocol = 'Tls12'; $apiUrl = "https://$($PveHost):8006/api2/json/access/ticket"; $body = @{ username = $Username; password = $Password } | ConvertTo-Json; try { return (Invoke-RestMethod -Uri $apiUrl -Method Post -Body $body -ContentType "application/json").data } catch { throw "Fehler bei der Authentifizierung an der Proxmox API: $($_.Exception.Message)" } }

# In GhettoGUI_V8.0.1.36.ps1

function Invoke-ProxmoxApiRequest {
    param(
        [string]$Path,
        [string]$Method = "GET",
        [hashtable]$Body = $null
    )
    if (-not $Global:ProxmoxSession) { throw "Keine aktive Proxmox-Sitzung." }
    $apiUrl = "$($Global:ProxmoxSession.BaseUrl)$($Path)"
    $headers = @{ "CSRFPreventionToken" = $Global:ProxmoxSession.CSRFPreventionToken }
    $cookie = New-Object System.Net.Cookie; $cookie.Name = "PVEAuthCookie"; $cookie.Value = $Global:ProxmoxSession.Ticket; $cookie.Domain = $Global:ProxmoxSession.Host;
    $requestParams = @{ Uri = $apiUrl; Method = $Method; Headers = $headers; WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession }
    $requestParams.WebSession.Cookies.Add($cookie)
    if ($Body) {
        # Konvertiere das Hashtable in JSON. -Depth 5 ist meist ausreichend.
        $requestParams.Body = ($Body | ConvertTo-Json -Depth 5)
        $requestParams.ContentType = "application/json"
        # Optional: Logge den gesendeten JSON-Body zum Debuggen
        # Write-ProxmoxLog "DEBUG: Sending JSON Body: $($requestParams.Body)"
    }
    try {
        # Führe den API-Request aus
        return (Invoke-RestMethod @requestParams).data
    } catch [System.Net.WebException] {
        # --- NEU: Detaillierte Fehlerbehandlung für WebExceptions ---
        $errorMessage = $_.Exception.Message
        $responseBody = "(Antwort-Body konnte nicht gelesen werden)" # Standardwert
        if ($_.Exception.Response) {
             $statusCode = $_.Exception.Response.StatusCode
             $statusDescription = $_.Exception.Response.StatusDescription
             try {
                # Versuche, den Antwort-Body zu lesen
                $responseStream = $_.Exception.Response.GetResponseStream()
                if ($responseStream) {
                    # Mit UTF8-Encoding lesen
                    $reader = New-Object System.IO.StreamReader($responseStream, [System.Text.Encoding]::UTF8)
                    $responseBody = $reader.ReadToEnd()
                    $reader.Close()
                    $responseStream.Close()
                }
             } catch {
                # Nichts tun, Standardwert bleibt
             }
             # Füge Status und Body zur Fehlermeldung hinzu
             $errorMessage = "API Status: $statusCode ($statusDescription)`nAPI Antwort: $responseBody" # Überschreibe ursprüngliche Meldung
        }
        # Schreibe den detaillierten Fehler ins Proxmox Log
        Write-ProxmoxLog "FEHLER API Request ($Path): $errorMessage"
        # Werfe den Fehler weiter, damit die aufrufende Funktion ihn fängt (mit der detaillierten Meldung)
        throw "Fehler bei der API-Anfrage an '$($Path)': $errorMessage"
        # --- ENDE NEU ---
    } catch {
        # Allgemeine Fehler (z.B. Verbindungsfehler)
        Write-ProxmoxLog "FEHLER API Request ($Path): $($_.Exception.Message)"
        throw "Fehler bei der API-Anfrage an '$($Path)': $($_.Exception.Message)"
    }
}

function Get-ProxmoxTaskStatus { param([string]$NodeName, [string]$TaskID); $encodedTaskID = [System.Web.HttpUtility]::UrlEncode($TaskID); return Invoke-ProxmoxApiRequest -Path "/nodes/$NodeName/tasks/$encodedTaskID/status" }

function New-ProxmoxBackupJob {
    param(
        [hashtable]$JobSettings
    )
    # Führt einen POST-Request aus, um einen neuen Backup-Job zu erstellen
    return Invoke-ProxmoxApiRequest -Path "/cluster/backup" -Method POST -Body $JobSettings
}

function Write-ProxmoxLog { param([string]$Message); if ($textboxProxmoxLog -and -not $textboxProxmoxLog.IsDisposed) { $textboxProxmoxLog.Invoke([Action]{ $textboxProxmoxLog.AppendText("$(Get-Date -Format 'HH:mm:ss'): $Message`r`n"); $textboxProxmoxLog.ScrollToCaret() }) } }
function Get-ProxmoxTaskLog { param([string]$NodeName, [string]$TaskID, [int]$StartLine = 0); $encodedTaskID = [System.Web.HttpUtility]::UrlEncode($TaskID); return Invoke-ProxmoxApiRequest -Path "/nodes/$NodeName/tasks/$encodedTaskID/log?start=$StartLine&limit=500" }

function Show-ProxmoxStorageSelectionDialog {
    param($parentForm)
    $storageForm = New-Object System.Windows.Forms.Form; $storageForm.Text = "Backup Storage auswählen"; $storageForm.Size = New-Object System.Drawing.Size(450, 300); $storageForm.StartPosition = "CenterParent"; $storageForm.FormBorderStyle = 'FixedDialog';
    $listBoxStorages = New-Object System.Windows.Forms.ListBox; $listBoxStorages.Dock = 'Fill'; $listBoxStorages.DisplayMember = "DisplayName"
    $buttonOk = New-Object System.Windows.Forms.Button; $buttonOk.Text = "Auswählen"; $buttonOk.DialogResult = 'OK'; $buttonOk.Dock = 'Bottom';
    $storageForm.Controls.AddRange(@($listBoxStorages, $buttonOk)); $storageForm.AcceptButton = $buttonOk;
    $storageForm.Add_Shown({
        $storageForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $storages = Invoke-ProxmoxApiRequest -Path "/storage"
            if ($storages) {
                # ==========================================================
                # KORREKTUR: Der Filter ist hier definitiv entfernt.
                # Es werden alle Storages mit ihren Infos angezeigt.
                # ==========================================================
                foreach ($storage in $storages) {
                    $item = [PSCustomObject]@{
                        DisplayName = "$($storage.storage) (Typ: $($storage.type), Inhalt: $($storage.content))"
                        StorageName = $storage.storage
                    }
                    $listBoxStorages.Items.Add($item)
                }
                if ($listBoxStorages.Items.Count -eq 0) {
                    [System.Windows.Forms.MessageBox]::Show("Die API hat eine leere Liste von Storages zurückgegeben.", "Keine Storages gefunden", "OK", "Warning")
                }
            } else {
                [System.Windows.Forms.MessageBox]::Show("Die Proxmox API hat keine Daten für die Storages zurückgegeben.", "Leere Antwort", "OK", "Error")
            }
        } catch { [System.Windows.Forms.MessageBox]::Show("Fehler beim Laden der Storage-Liste: $($_.Exception.Message)", "API Fehler", "OK", "Error") } 
        finally { $storageForm.Cursor = [System.Windows.Forms.Cursors]::Default }
    });
    if ($storageForm.ShowDialog($parentForm) -eq 'OK' -and $listBoxStorages.SelectedItem) {
        return $listBoxStorages.SelectedItem.StorageName
    }
    return $null
}

# In GhettoGUI_V8.0.1.36.ps1 (z.B. nach der Funktion Show-ProxmoxStorageSelectionDialog)

function Show-ProxmoxStorageTypeSelectionDialog {
    param($parentForm)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Speichertyp auswählen"
    $dialog.Size = New-Object System.Drawing.Size(350, 230) # Höhe angepasst
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.Tag = $null # Hier speichern wir den ausgewählten Typ

    $labelInfo = New-Object System.Windows.Forms.Label
    $labelInfo.Text = "Welchen Typ von Speicher möchten Sie hinzufügen?"
    $labelInfo.Location = New-Object System.Drawing.Point(20, 20)
    $labelInfo.AutoSize = $true

    $radioLvm = New-Object System.Windows.Forms.RadioButton; $radioLvm.Text = "LVM (Neues Volume erstellen)"; $radioLvm.Tag = 'lvm'; $radioLvm.Location = New-Object System.Drawing.Point(30, 50); $radioLvm.AutoSize = $true; $radioLvm.Checked = $true
    $radioDir = New-Object System.Windows.Forms.RadioButton; $radioDir.Text = "Verzeichnis (Lokaler Pfad)"; $radioDir.Tag = 'dir'; $radioDir.Location = New-Object System.Drawing.Point(30, 75); $radioDir.AutoSize = $true
    $radioNfs = New-Object System.Windows.Forms.RadioButton; $radioNfs.Text = "NFS Share"; $radioNfs.Tag = 'nfs'; $radioNfs.Location = New-Object System.Drawing.Point(30, 100); $radioNfs.AutoSize = $true
    $radioCifs = New-Object System.Windows.Forms.RadioButton; $radioCifs.Text = "CIFS/SMB Share"; $radioCifs.Tag = 'cifs'; $radioCifs.Location = New-Object System.Drawing.Point(30, 125); $radioCifs.AutoSize = $true

    $buttonOk = New-Object System.Windows.Forms.Button; $buttonOk.Text = "Weiter"; $buttonOk.Location = New-Object System.Drawing.Point(140, 160); $buttonOk.DialogResult = 'OK'
    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.Location = New-Object System.Drawing.Point(230, 160); $buttonCancel.DialogResult = 'Cancel'

    $dialog.Controls.AddRange(@($labelInfo, $radioLvm, $radioDir, $radioNfs, $radioCifs, $buttonOk, $buttonCancel))
    $dialog.AcceptButton = $buttonOk
    $dialog.CancelButton = $buttonCancel

    # Speichere den ausgewählten Tag beim Klick auf OK
    $buttonOk.Add_Click({
        $selectedRadio = $dialog.Controls | Where-Object { $_ -is [System.Windows.Forms.RadioButton] -and $_.Checked } | Select-Object -First 1
        if ($selectedRadio) {
            $dialog.Tag = $selectedRadio.Tag
        }
    })

    if ($dialog.ShowDialog($parentForm) -eq 'OK') {
        return $dialog.Tag
    }
    return $null
}

function Show-ProxmoxDirectoryStorageSelectionDialog {
    param($parentForm)
    $dialog = New-Object System.Windows.Forms.Form; $dialog.Text = "Zu löschenden Backup-Speicher auswählen"; $dialog.Size = New-Object System.Drawing.Size(450, 300); $dialog.StartPosition = "CenterParent"; $dialog.FormBorderStyle = 'FixedDialog';
    $listBox = New-Object System.Windows.Forms.ListBox; $listBox.Dock = 'Fill'; $listBox.DisplayMember = "DisplayName"
    $buttonOk = New-Object System.Windows.Forms.Button; $buttonOk.Text = "Auswählen"; $buttonOk.DialogResult = 'OK'; $buttonOk.Dock = 'Bottom';
    $dialog.Controls.AddRange(@($listBox, $buttonOk)); $dialog.AcceptButton = $buttonOk;
    $dialog.Add_Shown({
        try {
            # Frage alle Storages ab und filtere nach Typ "dir"
            $storages = Invoke-ProxmoxApiRequest -Path "/storage" | Where-Object { $_.type -eq 'dir' }
            if ($storages) {
                foreach ($storage in $storages) {
                    $item = [PSCustomObject]@{
                        DisplayName = "$($storage.storage) (Pfad: $($storage.path))"
                        StorageObject = $storage # Wir speichern das ganze Objekt
                    }
                    $listBox.Items.Add($item)
                }
            }
        } catch {}
    });
    if ($dialog.ShowDialog($parentForm) -eq 'OK' -and $listBox.SelectedItem) {
        return $listBox.SelectedItem.StorageObject
    }
    return $null
}

# In GhettoGUI_V8.0.1.36.ps1
# Ersetze die Funktion Start-ProxmoxStorageWizard durch diese

# In GhettoGUI_V8.0.1.36.ps1
# Ersetze die Funktion Start-ProxmoxLvmStorageWizard durch diese VEREINFACHTE Version
# In GhettoGUI_V8.0.1.x.ps1
# Ersetze die Funktion Start-ProxmoxLvmStorageWizard durch diese WIEDERHERGESTELLTE Version

function Start-ProxmoxLvmStorageWizard {
    param($parentForm)
    # SSH-Verbindung prüfen
    if (-not ($Global:ProxmoxSshSession -and $Global:ProxmoxSshSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Für diesen Assistenten wird eine SSH-Verbindung benötigt...", "SSH-Verbindung fehlt", "OK", "Warning");
        return
    }

    $wizardForm = New-Object System.Windows.Forms.Form
    $wizardForm.Text = "Assistent: Neuen LVM Speicher für Disk-Images erstellen"
    $wizardForm.Size = New-Object System.Drawing.Size(450, 280) # Höhe wieder reduziert
    $wizardForm.StartPosition = "CenterParent"; $wizardForm.FormBorderStyle = 'FixedDialog';

    # --- LVM-Auswahl (Punkte 1-4) ---
    $labelVg = New-Object System.Windows.Forms.Label; $labelVg.Text = "1. Auf welcher Festplatte (VG):"; $labelVg.Location = New-Object System.Drawing.Point(20, 23); $labelVg.AutoSize = $true; $comboVg = New-Object System.Windows.Forms.ComboBox; $comboVg.Location = New-Object System.Drawing.Point(220, 20); $comboVg.Size = New-Object System.Drawing.Size(180, 21); $comboVg.DropDownStyle = "DropDownList"; $comboVg.DisplayMember = "DisplayName";
    $labelLvName = New-Object System.Windows.Forms.Label; $labelLvName.Text = "2. Name für das Volume (LV):"; $labelLvName.Location = New-Object System.Drawing.Point(20, 53); $labelLvName.AutoSize = $true; $textLvName = New-Object System.Windows.Forms.TextBox; $textLvName.Location = New-Object System.Drawing.Point(220, 50); $textLvName.Size = New-Object System.Drawing.Size(180, 20); $textLvName.Text = "lvm_storage";
    $labelLvSize = New-Object System.Windows.Forms.Label; $labelLvSize.Text = "3. Grösse in Gigabyte (GB):"; $labelLvSize.Location = New-Object System.Drawing.Point(20, 83); $labelLvSize.AutoSize = $true; $numericLvSize = New-Object System.Windows.Forms.NumericUpDown; $numericLvSize.Location = New-Object System.Drawing.Point(220, 80); $numericLvSize.Size = New-Object System.Drawing.Size(80, 20); $numericLvSize.Minimum = 10; $numericLvSize.Maximum = 10000; $numericLvSize.Value = 100; # GRÖSSE IST WIEDER DA
    $labelStorageId = New-Object System.Windows.Forms.Label; $labelStorageId.Text = "4. Name in Proxmox-GUI (ID):"; $labelStorageId.Location = New-Object System.Drawing.Point(20, 113); $labelStorageId.AutoSize = $true; $textStorageId = New-Object System.Windows.Forms.TextBox; $textStorageId.Location = New-Object System.Drawing.Point(220, 110); $textStorageId.Size = New-Object System.Drawing.Size(180, 20); $textStorageId.Text = "LVM-Storage";

    # --- Hinweis ---
    $labelContentInfo = New-Object System.Windows.Forms.Label
    $labelContentInfo.Text = "Hinweis: Standard-LVM Speicher wird automatisch für 'Disk-Images' konfiguriert."
    $labelContentInfo.Location = New-Object System.Drawing.Point(20, 145)
    $labelContentInfo.Size = New-Object System.Drawing.Size(380, 30)
    $labelContentInfo.ForeColor = [System.Drawing.Color]::DimGray

    # Buttons
    $buttonCreate = New-Object System.Windows.Forms.Button; $buttonCreate.Text = "Erstellen"; $buttonCreate.Location = New-Object System.Drawing.Point(220, 190); $buttonCreate.Size = New-Object System.Drawing.Size(85, 25); $buttonCreate.DialogResult = 'OK';
    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.Location = New-Object System.Drawing.Point(315, 190); $buttonCancel.Size = New-Object System.Drawing.Size(85, 25); $buttonCancel.DialogResult = 'Cancel';

    $wizardForm.Controls.AddRange(@($labelVg, $comboVg, $labelLvName, $textLvName, $labelLvSize, $numericLvSize, $labelStorageId, $textStorageId, $labelContentInfo, $buttonCreate, $buttonCancel));
    $wizardForm.AcceptButton = $buttonCreate # Korrektur
    $wizardForm.CancelButton = $buttonCancel # Korrektur
    $wizardForm.Add_Shown({ # Lade VGs (unverändert)
        $wizardForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; try { $vgsResult = Invoke-SSHCommand -SSHSession $Global:ProxmoxSshSession -Command "vgs --noheadings -o vg_name,vg_free --units g"; if ($vgsResult.ExitStatus -ne 0) { throw "Konnte Volume Groups nicht abfragen." }; foreach ($line in $vgsResult.Output | Where-Object { $_ -match '\S' }) { $parts = $line.Trim() -split '\s+'; $vgName = $parts[0]; $vgFree = [math]::Floor([double]($parts[1] -replace 'g','')); $comboVg.Items.Add([PSCustomObject]@{ DisplayName = "$vgName ($vgFree GB frei)"; Name = $vgName; FreeSpace = $vgFree }) }; if ($comboVg.Items.Count -gt 0) { $comboVg.SelectedIndex = 0 } } catch { [System.Windows.Forms.MessageBox]::Show("Fehler beim Laden der Festplatten-Gruppen: $($_.Exception.Message)", "Fehler", "OK", "Error"); $wizardForm.Close() } finally { $wizardForm.Cursor = [System.Windows.Forms.Cursors]::Default }
    });

    if ($wizardForm.ShowDialog($parentForm) -eq 'OK') {
        $selectedVg = $comboVg.SelectedItem; $lvName = $textLvName.Text -replace '[^a-zA-Z0-9_-]', ''; $lvSize = $numericLvSize.Value; $storageId = $textStorageId.Text -replace '[^a-zA-Z0-9_-]', '';

        # Prüfung angepasst (nur die 4 Felder)
        if (-not $selectedVg -or [string]::IsNullOrWhiteSpace($lvName) -or [string]::IsNullOrWhiteSpace($storageId)) {
            [System.Windows.Forms.MessageBox]::Show("Bitte alle Felder ausfüllen.", "Fehlende Eingabe", "OK", "Warning"); return
        }
        # Restliche Prüfungen (Größe, Bestätigung)
        if ($lvSize -gt $selectedVg.FreeSpace) { [System.Windows.Forms.MessageBox]::Show("Die angegebene Grösse ($lvSize GB) ist grösser als der verfügbare Speicherplatz ($($selectedVg.FreeSpace) GB).", "Nicht genügend Speicher", "OK", "Warning"); return }
        $confirmMsg = "ACHTUNG: Dieser Vorgang wird ein neues Logical Volume erstellen. Sind Sie absolut sicher?`n`nVG: $($selectedVg.Name)`nNeues LV: $lvName ($lvSize GB)";
        if ([System.Windows.Forms.MessageBox]::Show($confirmMsg, "Endgültige Bestätigung", "YesNo", "Warning") -ne 'Yes') { Write-ProxmoxLog "Erstellung des LVM-Speichers vom Benutzer abgebrochen."; return }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; try {
            $vgName = $selectedVg.Name;
            Write-ProxmoxLog "-> Erstelle Logical Volume '$lvName' mit ${lvSize}G..."; Invoke-SSHCommand -SSHSession $Global:ProxmoxSshSession -Command "lvcreate -y -n $lvName -L ${lvSize}G $vgName" | Out-Null
            Write-ProxmoxLog "-> Füge LVM-Speicher zur Proxmox-Konfiguration hinzu (ID: $storageId)...";
            # API-Aufruf mit festem Content 'images'
            Invoke-ProxmoxApiRequest -Path "/storage" -Method POST -Body @{
                storage = $storageId
                type = 'lvm'
                vgname = $vgName
                content = 'images' # Fest für Disk Images
            } | Out-Null
            Write-ProxmoxLog "SUCCESS: Neuer LVM-Speicher '$storageId' wurde erfolgreich erstellt und ist einsatzbereit!"; [System.Windows.Forms.MessageBox]::Show("Der neue LVM-Speicher wurde erfolgreich erstellt!", "Erfolg", "OK", "Information")
        } catch { Write-ProxmoxLog "FEHLER beim Erstellen des Speichers: $($_.Exception.Message)"; [System.Windows.Forms.MessageBox]::Show("Ein Fehler ist aufgetreten: $($_.Exception.Message)", "Fehler", "OK", "Error") }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    }
}
# In GhettoGUI_V8.0.1.36.ps1 (z.B. nach der LVM-Wizard-Funktion)


# In GhettoGUI_V8.0.1.x.ps1
# Passe die Funktion Start-ProxmoxDirectoryStorageWizard an

# In GhettoGUI_V8.0.1.x.ps1
# Komplette Funktion Start-ProxmoxDirectoryStorageWizard mit korrigierter Control-Addition

function Start-ProxmoxDirectoryStorageWizard {
    param($parentForm)
    # API- und SSH-Verbindung prüfen
    if (-not $Global:ProxmoxSession) {
        [System.Windows.Forms.MessageBox]::Show("Für diesen Assistenten wird eine API-Verbindung benötigt.", "Keine Verbindung", "OK", "Warning"); return
    }
    if (-not ($Global:ProxmoxSshSession -and $Global:ProxmoxSshSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Für diesen Assistenten wird eine SSH-Verbindung benötigt (wird bei API-Verbindung mit aufgebaut).", "SSH-Verbindung fehlt", "OK", "Warning"); return
    }

    $wizardForm = New-Object System.Windows.Forms.Form
    $wizardForm.Text = "Assistent: Lokales Verzeichnis als Speicher hinzufügen"
    $wizardForm.Size = New-Object System.Drawing.Size(450, 360)
    $wizardForm.StartPosition = "CenterParent"; $wizardForm.FormBorderStyle = 'FixedDialog';

    # --- Eingabefelder ---
    $labelStorageId = New-Object System.Windows.Forms.Label; $labelStorageId.Text = "1. Name in Proxmox-GUI (ID):"; $labelStorageId.Location = New-Object System.Drawing.Point(20, 23); $labelStorageId.AutoSize = $true;
    $textStorageId = New-Object System.Windows.Forms.TextBox; $textStorageId.Location = New-Object System.Drawing.Point(220, 20); $textStorageId.Size = New-Object System.Drawing.Size(180, 20); $textStorageId.Text = "Local-Directory";
    $labelPath = New-Object System.Windows.Forms.Label; $labelPath.Text = "2. Pfad auf Proxmox Host:"; $labelPath.Location = New-Object System.Drawing.Point(20, 53); $labelPath.AutoSize = $true;
    $textPath = New-Object System.Windows.Forms.TextBox; $textPath.Location = New-Object System.Drawing.Point(220, 50); $textPath.Size = New-Object System.Drawing.Size(145, 20); $textPath.Text = "/mnt/local_storage"; # Breite reduziert
    $buttonBrowseMountPoint = New-Object System.Windows.Forms.Button; $buttonBrowseMountPoint.Text = "..."; $buttonBrowseMountPoint.Location = New-Object System.Drawing.Point(370, 48); $buttonBrowseMountPoint.Size = New-Object System.Drawing.Size(30, 25);
    $toolTip.SetToolTip($buttonBrowseMountPoint, "Mountpunkt als Basis auswählen")

    # --- Auswahl der Inhaltstypen ---
    $groupContent = New-Object System.Windows.Forms.GroupBox; $groupContent.Text = "3. Erlaubte Inhaltstypen"; $groupContent.Location = New-Object System.Drawing.Point(20, 85); $groupContent.Size = New-Object System.Drawing.Size(380, 145)
    $contentCheckboxes = @{}
    $contentTypes = @(
        @{Name='Disk-Images'; Value='images'}, @{Name='ISO-Images'; Value='iso'}, @{Name='Container'; Value='rootdir'},
        @{Name='Backups'; Value='backup'}, @{Name='Container-Templates'; Value='vztmpl'}, @{Name='Snippets'; Value='snippets'}
    )
    $chkY = 20; $chkX = 15; $colWidth = 180
    foreach ($type in $contentTypes) {
        $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = $type.Name; $chk.Tag = $type.Value; $chk.Location = New-Object System.Drawing.Point($chkX, $chkY); $chk.AutoSize = $true
        $chk.Checked = $true # Standard: Alles auswählen
        $contentCheckboxes[$type.Value] = $chk
        $groupContent.Controls.Add($chk) # Checkboxen zur Gruppe hinzufügen
        $chkY += 25
        if ($chkY -gt 110) { $chkY = 20; $chkX += $colWidth }
    }

    # Buttons
    $buttonCreate = New-Object System.Windows.Forms.Button; $buttonCreate.Text = "Hinzufügen"; $buttonCreate.Location = New-Object System.Drawing.Point(220, 280); $buttonCreate.Size = New-Object System.Drawing.Size(85, 25); $buttonCreate.DialogResult = 'OK';
    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.Location = New-Object System.Drawing.Point(315, 280); $buttonCancel.Size = New-Object System.Drawing.Size(85, 25); $buttonCancel.DialogResult = 'Cancel';

    # --- KORREKTUR: Stelle sicher, dass ALLE Elemente zum Formular hinzugefügt werden ---
    $wizardForm.Controls.AddRange(@(
        $labelStorageId, $textStorageId,
        $labelPath, $textPath, $buttonBrowseMountPoint, # Mountpoint-Button hinzugefügt
        $groupContent, # Die GroupBox für Inhaltstypen hinzugefügt
        $buttonCreate, $buttonCancel
    ))
    # --- ENDE KORREKTUR ---

    $wizardForm.AcceptButton = $buttonCreate
    $wizardForm.CancelButton = $buttonCancel

    # Klick-Event für den Mountpoint-Browse-Button
    $buttonBrowseMountPoint.Add_Click({
        $startPath = if ([string]::IsNullOrWhiteSpace($textPath.Text) -or -not $textPath.Text.StartsWith("/")) { "/mnt" } else { $textPath.Text }
        $selectedMountPoint = Show-ProxmoxMountPointSelectionDialog -parentForm $wizardForm -sshSession $Global:ProxmoxSshSession
        if ($selectedMountPoint) {
            if ($selectedMountPoint -eq "/") { $textPath.Text = "/" } else { $textPath.Text = $selectedMountPoint.TrimEnd('/') + "/" }
            $textPath.Focus()
            $textPath.Select($textPath.Text.Length, 0)
            Write-ProxmoxLog "Mountpunkt '$selectedMountPoint' als Basis für Pfad ausgewählt."
        } else {
            Write-ProxmoxLog "Mountpunkt-Auswahl abgebrochen."
        }
    })

    # Logik für den "Hinzufügen"-Button
    if ($wizardForm.ShowDialog($parentForm) -eq 'OK') {
        $storageId = $textStorageId.Text -replace '[^a-zA-Z0-9_-]', ''; $path = $textPath.Text.Trim();
        $selectedContent = ($contentCheckboxes.GetEnumerator() | Where-Object { $_.Value.Checked } | ForEach-Object { $_.Value.Tag } | Sort-Object) -join ','
        if ([string]::IsNullOrWhiteSpace($storageId) -or [string]::IsNullOrWhiteSpace($path) -or -not $path.StartsWith("/") -or [string]::IsNullOrWhiteSpace($selectedContent) -or $path -eq "/") {
            [System.Windows.Forms.MessageBox]::Show("Bitte alle Felder ausfüllen (gültiger absoluter Pfad, nicht nur '/'!) und mindestens einen Inhaltstypen auswählen.", "Fehlende Eingabe", "OK", "Warning"); return
        }
        $confirmMsg = "Soll das Verzeichnis '$path' erstellt (falls nicht vorhanden) und als Speicher '$storageId' hinzugefügt werden?";
        if ([System.Windows.Forms.MessageBox]::Show($confirmMsg, "Bestätigung", "YesNo", "Question") -ne 'Yes') { Write-ProxmoxLog "Hinzufügen des Verzeichnis-Speichers vom Benutzer abgebrochen."; return }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; try {
            Write-ProxmoxLog "-> Erstelle Verzeichnis '$path' auf Host (falls nicht vorhanden)...";
            Invoke-SSHCommand -SSHSession $Global:ProxmoxSshSession -Command "mkdir -p '$path'" | Out-Null
            Write-ProxmoxLog "-> Füge Verzeichnis-Speicher zur Proxmox-Konfiguration hinzu (ID: $storageId)...";
            Invoke-ProxmoxApiRequest -Path "/storage" -Method POST -Body @{
                storage = $storageId; type = 'dir'; path = $path; content = $selectedContent
            } | Out-Null
            Write-ProxmoxLog "SUCCESS: Neuer Verzeichnis-Speicher '$storageId' wurde erfolgreich hinzugefügt!"; [System.Windows.Forms.MessageBox]::Show("Der neue Verzeichnis-Speicher wurde erfolgreich hinzugefügt!", "Erfolg", "OK", "Information")
        } catch { Write-ProxmoxLog "FEHLER beim Hinzufügen des Speichers: $($_.Exception.Message)"; [System.Windows.Forms.MessageBox]::Show("Ein Fehler ist aufgetreten: $($_.Exception.Message)", "Fehler", "OK", "Error") }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    }
}

# In GhettoGUI_V8.0.1.x.ps1 (z.B. nach der DirectoryStorageWizard-Funktion)

function Show-ProxmoxMountPointSelectionDialog {
    param(
        [Parameter(Mandatory=$true)]
        [object]$parentForm,
        [Parameter(Mandatory=$true)]
        [object]$sshSession
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Mountpunkt auswählen"
    $dialog.Size = New-Object System.Drawing.Size(450, 300)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = 'FixedDialog'

    $labelInfo = New-Object System.Windows.Forms.Label; $labelInfo.Text = "Wähle einen Mountpunkt als Basis für den Speicherpfad:"; $labelInfo.Location = New-Object System.Drawing.Point(15, 15); $labelInfo.AutoSize = $true

    $listBox = New-Object System.Windows.Forms.ListBox; $listBox.Location = New-Object System.Drawing.Point(15, 40); $listBox.Size = New-Object System.Drawing.Size(400, 180);

    $buttonOk = New-Object System.Windows.Forms.Button; $buttonOk.Text = "Auswählen"; $buttonOk.Location = New-Object System.Drawing.Point(245, 230); $buttonOk.DialogResult = [System.Windows.Forms.DialogResult]::OK; $buttonOk.Enabled = $false
    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.Location = New-Object System.Drawing.Point(335, 230); $buttonCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dialog.Controls.AddRange(@($labelInfo, $listBox, $buttonOk, $buttonCancel))
    $dialog.AcceptButton = $buttonOk; $dialog.CancelButton = $buttonCancel
    $listBox.Add_SelectedIndexChanged({ $buttonOk.Enabled = ($listBox.SelectedItem -ne $null) })
    $listBox.Add_DoubleClick({ if ($listBox.SelectedItem) { $buttonOk.PerformClick() } }) # Hinzugefügt

    $dialog.Add_Shown({
        $dialog.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            # Befehl zum Auflisten relevanter Mountpunkte (Root, /mnt/*, /var/lib/vz/*)
            # findmnt ist oft besser als df; -l für Listenformat, -n ohne Header, -o TARGET nur Mountpunkt
            # grep filtert die relevantesten raus
            $command = "findmnt -l -n -o TARGET | grep -E '^(/mnt/|/$|/var/lib/vz)'"
            $result = Invoke-SSHCommand -SSHSession $sshSession -Command $command -ErrorAction SilentlyContinue

            if ($result.ExitStatus -eq 0 -and $result.Output) {
                # Füge nur eindeutige, nicht-leere Pfade hinzu und sortiere sie
                $mountPoints = $result.Output | Where-Object { $_ -match '\S' } | Select-Object -Unique | Sort-Object
                $listBox.Items.AddRange($mountPoints)
                if ($listBox.Items.Count -eq 0) {
                     [System.Windows.Forms.MessageBox]::Show("Keine relevanten Mountpunkte (/ oder /mnt/* oder /var/lib/vz/*) gefunden.", "Keine Mountpunkte", "OK", "Information")
                }
            } else {
                 [System.Windows.Forms.MessageBox]::Show("Fehler beim Abrufen der Mountpunkte vom Host.`n$($result.Error -join "`n")", "SSH Fehler", "OK", "Warning")
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Fehler beim Laden der Mountpunkt-Liste: $($_.Exception.Message)", "Fehler", "OK", "Error")
        } finally {
            $dialog.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    if ($dialog.ShowDialog($parentForm) -eq 'OK' -and $listBox.SelectedItem) {
        return $listBox.SelectedItem.ToString() # Gibt den ausgewählten Pfad zurück
    }
    return $null # Bei Abbruch
}

function Start-ProxmoxNfsStorageWizard { # <<< Optional: Name angepasst
    param($parentForm)
    # API-Verbindung prüfen
    if (-not $Global:ProxmoxSession) {
        [System.Windows.Forms.MessageBox]::Show("Für diesen Assistenten wird eine API-Verbindung benötigt.", "Keine Verbindung", "OK", "Warning"); return
    }

    $wizardForm = New-Object System.Windows.Forms.Form
    $wizardForm.Text = "Assistent: NFS-Share als Speicher hinzufügen" # Titel angepasst
    $wizardForm.Size = New-Object System.Drawing.Size(450, 420) # Mehr Höhe
    $wizardForm.StartPosition = "CenterParent"; $wizardForm.FormBorderStyle = 'FixedDialog';

    # --- Eingabefelder (Punkte 1-3) ---
    $labelServer = New-Object System.Windows.Forms.Label; $labelServer.Text = "1. NFS Server IP / Hostname:"; $labelServer.Location = New-Object System.Drawing.Point(20, 23); $labelServer.AutoSize = $true
    $textServer = New-Object System.Windows.Forms.TextBox; $textServer.Location = New-Object System.Drawing.Point(220, 20); $textServer.Size = New-Object System.Drawing.Size(180, 20)
    $labelExport = New-Object System.Windows.Forms.Label; $labelExport.Text = "2. Server-Pfad (Export):"; $labelExport.Location = New-Object System.Drawing.Point(20, 53); $labelExport.AutoSize = $true
    $textExport = New-Object System.Windows.Forms.TextBox; $textExport.Location = New-Object System.Drawing.Point(220, 50); $textExport.Size = New-Object System.Drawing.Size(180, 20); $textExport.Text = "/export/storage" # Beispiel
    $labelStorageId = New-Object System.Windows.Forms.Label; $labelStorageId.Text = "3. Name in Proxmox-GUI (ID):"; $labelStorageId.Location = New-Object System.Drawing.Point(20, 83); $labelStorageId.AutoSize = $true
    $textStorageId = New-Object System.Windows.Forms.TextBox; $textStorageId.Location = New-Object System.Drawing.Point(220, 80); $textStorageId.Size = New-Object System.Drawing.Size(180, 20); $textStorageId.Text = "NFS-Storage" # Beispiel

    # --- NEU: Auswahl der Inhaltstypen (kopiert) ---
    $groupContent = New-Object System.Windows.Forms.GroupBox; $groupContent.Text = "4. Erlaubte Inhaltstypen"; $groupContent.Location = New-Object System.Drawing.Point(20, 115); $groupContent.Size = New-Object System.Drawing.Size(380, 145)
    $contentCheckboxes = @{}
    $contentTypes = @( # Alle Typen erlaubt für NFS
        @{Name='Disk-Images'; Value='images'}, @{Name='ISO-Images'; Value='iso'}, @{Name='Container'; Value='rootdir'},
        @{Name='Backups'; Value='backup'}, @{Name='Container-Templates'; Value='vztmpl'}, @{Name='Snippets'; Value='snippets'}
    )
    $chkY = 20; $chkX = 15; $colWidth = 180
    foreach ($type in $contentTypes) {
        $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = $type.Name; $chk.Tag = $type.Value; $chk.Location = New-Object System.Drawing.Point($chkX, $chkY); $chk.AutoSize = $true
        # Standard: Nur Backups für NFS
        if ($type.Value -eq 'backup') { $chk.Checked = $true }
        $contentCheckboxes[$type.Value] = $chk
        $groupContent.Controls.Add($chk)
        $chkY += 25
        if ($chkY -gt 110) { $chkY = 20; $chkX += $colWidth }
    }
    # --- ENDE NEU ---

    # Buttons (Position angepasst)
    $buttonCreate = New-Object System.Windows.Forms.Button; $buttonCreate.Text = "Hinzufügen"; $buttonCreate.Location = New-Object System.Drawing.Point(215, 340); $buttonCreate.Size = New-Object System.Drawing.Size(90, 25); $buttonCreate.DialogResult = 'OK'
    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.Location = New-Object System.Drawing.Point(315, 340); $buttonCancel.Size = New-Object System.Drawing.Size(85, 25); $buttonCancel.DialogResult = 'Cancel'

    $wizardForm.Controls.AddRange(@($labelServer, $textServer, $labelExport, $textExport, $labelStorageId, $textStorageId, $groupContent, $buttonCreate, $buttonCancel))

    if ($wizardForm.ShowDialog($parentForm) -eq 'OK') {
        $server = $textServer.Text; $export = $textExport.Text; $storageId = $textStorageId.Text -replace '[^a-zA-Z0-9_-]', '';
        # NEU: Ausgewählte Inhaltstypen sammeln
        $selectedContent = ($contentCheckboxes.GetEnumerator() | Where-Object { $_.Value.Checked } | ForEach-Object { $_.Value.Tag } | Sort-Object) -join ','
        if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($export) -or [string]::IsNullOrWhiteSpace($storageId) -or [string]::IsNullOrWhiteSpace($selectedContent)) {
            [System.Windows.Forms.MessageBox]::Show("Bitte alle Felder ausfüllen und mindestens einen Inhaltstypen auswählen.", "Fehlende Eingabe", "OK", "Warning"); return
        }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Write-ProxmoxLog "-> Füge NFS-Speicher '$storageId' zur Proxmox-Konfiguration hinzu (erzwinge NFSv3)..."
            # API-Aufruf mit Content
            Invoke-ProxmoxApiRequest -Path "/storage" -Method POST -Body @{
                storage = $storageId
                type = 'nfs'
                server = $server
                export = $export
                content = $selectedContent # <<< Hinzugefügt
                options = 'vers=3'         # <<< Beibehalten
            } | Out-Null

            Write-ProxmoxLog "SUCCESS: Neuer NFS-Speicher '$storageId' wurde erfolgreich hinzugefügt!"
            [System.Windows.Forms.MessageBox]::Show("Der neue NFS-Speicher wurde erfolgreich hinzugefügt und gemountet.", "Erfolg", "OK", "Information")

        } catch {
            Write-ProxmoxLog "FEHLER beim Hinzufügen des NFS-Speichers: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Ein Fehler ist aufgetreten: $($_.Exception.Message)", "Fehler", "OK", "Error")
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }
}

# In GhettoGUI_V8.0.1.36.ps1 (z.B. nach der NFS-Wizard-Funktion)


function Start-ProxmoxNfsWizard {
    param($parentForm)

    # --- Fenster-Definition ---
    $wizardForm = New-Object System.Windows.Forms.Form; $wizardForm.Text = "Assistent: NFS-Share als Backup-Speicher hinzufügen"; $wizardForm.Size = New-Object System.Drawing.Size(450, 220); $wizardForm.StartPosition = "CenterParent"; $wizardForm.FormBorderStyle = 'FixedDialog';

    # --- Steuerelemente ---
    $labelServer = New-Object System.Windows.Forms.Label; $labelServer.Text = "1. NFS Server IP / Hostname:"; $labelServer.Location = New-Object System.Drawing.Point(20, 23); $labelServer.AutoSize = $true
    $textServer = New-Object System.Windows.Forms.TextBox; $textServer.Location = New-Object System.Drawing.Point(220, 20); $textServer.Size = New-Object System.Drawing.Size(180, 20)
    $labelExport = New-Object System.Windows.Forms.Label; $labelExport.Text = "2. Server-Pfad (Export):"; $labelExport.Location = New-Object System.Drawing.Point(20, 53); $labelExport.AutoSize = $true
    $textExport = New-Object System.Windows.Forms.TextBox; $textExport.Location = New-Object System.Drawing.Point(220, 50); $textExport.Size = New-Object System.Drawing.Size(180, 20); $textExport.Text = "/export/backup"
    $labelStorageId = New-Object System.Windows.Forms.Label; $labelStorageId.Text = "3. Name in Proxmox-GUI (ID):"; $labelStorageId.Location = New-Object System.Drawing.Point(20, 83); $labelStorageId.AutoSize = $true
    $textStorageId = New-Object System.Windows.Forms.TextBox; $textStorageId.Location = New-Object System.Drawing.Point(220, 80); $textStorageId.Size = New-Object System.Drawing.Size(180, 20); $textStorageId.Text = "NFS-Backup"
    $buttonCreate = New-Object System.Windows.Forms.Button; $buttonCreate.Text = "Hinzufügen"; $buttonCreate.Location = New-Object System.Drawing.Point(215, 140); $buttonCreate.Size = New-Object System.Drawing.Size(90, 25); $buttonCreate.DialogResult = 'OK'
    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.Location = New-Object System.Drawing.Point(315, 140); $buttonCancel.Size = New-Object System.Drawing.Size(85, 25); $buttonCancel.DialogResult = 'Cancel'
    $wizardForm.Controls.AddRange(@($labelServer, $textServer, $labelExport, $textExport, $labelStorageId, $textStorageId, $buttonCreate, $buttonCancel))

    # --- Logik beim Klick auf "Hinzufügen" ---
    if ($wizardForm.ShowDialog($parentForm) -eq 'OK') {
        $server = $textServer.Text; $export = $textExport.Text; $storageId = $textStorageId.Text -replace '[^a-zA-Z0-9_-]', '';
        if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($export) -or [string]::IsNullOrWhiteSpace($storageId)) {
            [System.Windows.Forms.MessageBox]::Show("Bitte alle Felder ausfüllen.", "Fehlende Eingabe", "OK", "Warning"); return
        }
        
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Write-ProxmoxLog "-> Füge NFS-Speicher '$storageId' zur Proxmox-Konfiguration hinzu (erzwinge NFSv3)..."
            Invoke-ProxmoxApiRequest -Path "/storage" -Method POST -Body @{
                storage = $storageId
                type = 'nfs'
                server = $server
                export = $export
                content = 'backup'
                # ==========================================================
                # HIER IST DIE KORREKTUR: Wir weisen Proxmox an, NFSv3 zu verwenden.
                # ==========================================================
                options = 'vers=3'
            } | Out-Null

            Write-ProxmoxLog "SUCCESS: Neuer NFS-Speicher '$storageId' wurde erfolgreich hinzugefügt!"
            [System.Windows.Forms.MessageBox]::Show("Der neue NFS-Speicher wurde erfolgreich hinzugefügt und gemountet.", "Erfolg", "OK", "Information")

        } catch {
            Write-ProxmoxLog "FEHLER beim Hinzufügen des NFS-Speichers: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Ein Fehler ist aufgetreten: $($_.Exception.Message)", "Fehler", "OK", "Error")
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }
}


function Start-ProxmoxCifsStorageWizard {
    param($parentForm)
    # API-Verbindung prüfen
    if (-not $Global:ProxmoxSession) {
        [System.Windows.Forms.MessageBox]::Show("Für diesen Assistenten wird eine API-Verbindung benötigt.", "Keine Verbindung", "OK", "Warning"); return
    }

    $wizardForm = New-Object System.Windows.Forms.Form
    $wizardForm.Text = "Assistent: CIFS/SMB Share als Speicher hinzufügen"
    $wizardForm.Size = New-Object System.Drawing.Size(450, 480) # Mehr Höhe für User/Pass
    $wizardForm.StartPosition = "CenterParent"; $wizardForm.FormBorderStyle = 'FixedDialog';

    # --- Eingabefelder (Punkte 1-5) ---
    $currentY = 20
    $labelStorageId = New-Object System.Windows.Forms.Label; $labelStorageId.Text = "1. Name in Proxmox-GUI (ID):"; $labelStorageId.Location = New-Object System.Drawing.Point(20, ($currentY + 3)); $labelStorageId.AutoSize = $true;
    $textStorageId = New-Object System.Windows.Forms.TextBox; $textStorageId.Location = New-Object System.Drawing.Point(220, $currentY); $textStorageId.Size = New-Object System.Drawing.Size(180, 20); $textStorageId.Text = "CIFS-Storage"; $currentY += 30
    $labelServer = New-Object System.Windows.Forms.Label; $labelServer.Text = "2. CIFS Server IP / Hostname:"; $labelServer.Location = New-Object System.Drawing.Point(20, ($currentY + 3)); $labelServer.AutoSize = $true
    $textServer = New-Object System.Windows.Forms.TextBox; $textServer.Location = New-Object System.Drawing.Point(220, $currentY); $textServer.Size = New-Object System.Drawing.Size(180, 20); $currentY += 30
    $labelShare = New-Object System.Windows.Forms.Label; $labelShare.Text = "3. Freigabename (Share):"; $labelShare.Location = New-Object System.Drawing.Point(20, ($currentY + 3)); $labelShare.AutoSize = $true
    $textShare = New-Object System.Windows.Forms.TextBox; $textShare.Location = New-Object System.Drawing.Point(220, $currentY); $textShare.Size = New-Object System.Drawing.Size(180, 20); $textShare.Text = "backup_share"; $currentY += 30 # Beispiel
    $labelUsername = New-Object System.Windows.Forms.Label; $labelUsername.Text = "4. Benutzername (optional):"; $labelUsername.Location = New-Object System.Drawing.Point(20, ($currentY + 3)); $labelUsername.AutoSize = $true
    $textUsername = New-Object System.Windows.Forms.TextBox; $textUsername.Location = New-Object System.Drawing.Point(220, $currentY); $textUsername.Size = New-Object System.Drawing.Size(180, 20); $currentY += 30
    $labelPassword = New-Object System.Windows.Forms.Label; $labelPassword.Text = "5. Passwort (optional):"; $labelPassword.Location = New-Object System.Drawing.Point(20, ($currentY + 3)); $labelPassword.AutoSize = $true
    $textPassword = New-Object System.Windows.Forms.TextBox; $textPassword.Location = New-Object System.Drawing.Point(220, $currentY); $textPassword.Size = New-Object System.Drawing.Size(180, 20); $textPassword.UseSystemPasswordChar = $true; $currentY += 35

    # --- Auswahl der Inhaltstypen (kopiert) ---
    $groupContent = New-Object System.Windows.Forms.GroupBox; $groupContent.Text = "6. Erlaubte Inhaltstypen"; $groupContent.Location = New-Object System.Drawing.Point(20, $currentY); $groupContent.Size = New-Object System.Drawing.Size(380, 145)
    $contentCheckboxes = @{}
    $contentTypes = @( # Alle Typen erlaubt für CIFS
        @{Name='Disk-Images'; Value='images'}, @{Name='ISO-Images'; Value='iso'}, @{Name='Container'; Value='rootdir'},
        @{Name='Backups'; Value='backup'}, @{Name='Container-Templates'; Value='vztmpl'}, @{Name='Snippets'; Value='snippets'}
    )
    $chkY = 20; $chkX = 15; $colWidth = 180
    foreach ($type in $contentTypes) {
        $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = $type.Name; $chk.Tag = $type.Value; $chk.Location = New-Object System.Drawing.Point($chkX, $chkY); $chk.AutoSize = $true
        # Standard: Nur Backups für CIFS
        if ($type.Value -eq 'backup') { $chk.Checked = $true }
        $contentCheckboxes[$type.Value] = $chk
        $groupContent.Controls.Add($chk)
        $chkY += 25
        if ($chkY -gt 110) { $chkY = 20; $chkX += $colWidth }
    }
    $currentY += $groupContent.Height + 15
    # --- ENDE Inhaltstypen ---

    # Buttons (Position angepasst)
    $buttonCreate = New-Object System.Windows.Forms.Button; $buttonCreate.Text = "Hinzufügen"; $buttonCreate.Location = New-Object System.Drawing.Point(215, $currentY); $buttonCreate.Size = New-Object System.Drawing.Size(90, 25); $buttonCreate.DialogResult = 'OK'
    $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.Location = New-Object System.Drawing.Point(315, $currentY); $buttonCancel.Size = New-Object System.Drawing.Size(85, 25); $buttonCancel.DialogResult = 'Cancel'

    $wizardForm.Controls.AddRange(@($labelStorageId, $textStorageId, $labelServer, $textServer, $labelShare, $textShare, $labelUsername, $textUsername, $labelPassword, $textPassword, $groupContent, $buttonCreate, $buttonCancel))

    if ($wizardForm.ShowDialog($parentForm) -eq 'OK') {
        $storageId = $textStorageId.Text -replace '[^a-zA-Z0-9_-]', ''; $server = $textServer.Text; $share = $textShare.Text;
        $username = $textUsername.Text; $password = $textPassword.Text;
        # Ausgewählte Inhaltstypen sammeln
        $selectedContent = ($contentCheckboxes.GetEnumerator() | Where-Object { $_.Value.Checked } | ForEach-Object { $_.Value.Tag } | Sort-Object) -join ','
        if ([string]::IsNullOrWhiteSpace($storageId) -or [string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($share) -or [string]::IsNullOrWhiteSpace($selectedContent)) {
            [System.Windows.Forms.MessageBox]::Show("Bitte mindestens Speicher-ID, Server, Freigabe ausfüllen und einen Inhaltstypen auswählen.", "Fehlende Eingabe", "OK", "Warning"); return
        }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Write-ProxmoxLog "-> Füge CIFS/SMB-Speicher '$storageId' zur Proxmox-Konfiguration hinzu..."
            # API-Parameter zusammenstellen
            $apiParams = @{
                storage = $storageId
                type = 'cifs'
                server = $server
                share = $share
                content = $selectedContent
                # Optional: Weitere Optionen wie 'domain', 'smbversion' etc. könnten hier gesetzt werden
            }
            # Username und Passwort nur hinzufügen, wenn angegeben
            if (-not [string]::IsNullOrWhiteSpace($username)) { $apiParams.Add('username', $username) }
            if (-not [string]::IsNullOrWhiteSpace($password)) { $apiParams.Add('password', $password) }

            # API-Aufruf
            Invoke-ProxmoxApiRequest -Path "/storage" -Method POST -Body $apiParams | Out-Null

            Write-ProxmoxLog "SUCCESS: Neuer CIFS/SMB-Speicher '$storageId' wurde erfolgreich hinzugefügt!"
            [System.Windows.Forms.MessageBox]::Show("Der neue CIFS/SMB-Speicher wurde erfolgreich hinzugefügt und gemountet.", "Erfolg", "OK", "Information")

        } catch {
            Write-ProxmoxLog "FEHLER beim Hinzufügen des CIFS/SMB-Speichers: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Ein Fehler ist aufgetreten: $($_.Exception.Message)", "Fehler", "OK", "Error")
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }
}



function Show-ProxmoxBackupSelectionDialog {
    param($parentForm, $Storage)
    $dialog = New-Object System.Windows.Forms.Form; $dialog.Text = "Backup zum Wiederherstellen auswählen"; $dialog.Size = New-Object System.Drawing.Size(550, 400); $dialog.StartPosition = "CenterParent"; $dialog.FormBorderStyle = 'FixedDialog';
    $listBox = New-Object System.Windows.Forms.ListBox; $listBox.Dock = 'Fill'; $listBox.DisplayMember = "DisplayName"
    $buttonOk = New-Object System.Windows.Forms.Button; $buttonOk.Text = "Auswählen"; $buttonOk.DialogResult = 'OK'; $buttonOk.Dock = 'Bottom';
    $dialog.Controls.AddRange(@($listBox, $buttonOk)); $dialog.AcceptButton = $buttonOk;
    $dialog.Add_Shown({
        try {
            # Finde den ersten verfügbaren Node im Cluster.
            $nodes = Invoke-ProxmoxApiRequest -Path "/nodes"
            if (-not $nodes) { throw "Konnte keine Nodes im Cluster finden." }
            $nodeName = $nodes[0].node
            if (-not $nodeName) { throw "Konnte den Namen des Nodes nicht aus der API-Antwort lesen." }

            # Frage den Inhalt über den Node-spezifischen Pfad ab.
            $contentList = Invoke-ProxmoxApiRequest -Path "/nodes/$nodeName/storage/$Storage/content"
            
            if ($contentList) {
                # ==========================================================
                # HIER IST DIE KORREKTUR: Der fehlerhafte Filter wurde entfernt.
                # ==========================================================
                foreach ($item in $contentList) {
                    # Konvertiere die Unix-Zeit in ein lesbares Datum
                    $backupDate = Get-Date -Date "1970-01-01 00:00:00" -Hour 0 | ForEach-Object { $_.AddSeconds($item.ctime) }
                    
                    $backupItem = [PSCustomObject]@{
                        DisplayName = "VM $($item.vmid) - $($item.volid) ($($backupDate.ToString('dd.MM.yyyy HH:mm')))"
                        VolumeId = $item.volid
                    }
                    $listBox.Items.Add($backupItem)
                }
            }

            if ($listBox.Items.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("Auf dem Storage '$Storage' wurden keine Inhalte (Backups, ISOs, etc.) gefunden.", "Speicher ist leer", "OK", "Information")
            }

        } catch {
            [System.Windows.Forms.MessageBox]::Show("Fehler beim Laden der Backup-Liste: $($_.Exception.Message)", "API Fehler", "OK", "Error")
        }
    });
    if ($dialog.ShowDialog($parentForm) -eq 'OK' -and $listBox.SelectedItem) {
        return $listBox.SelectedItem.VolumeId
    }
    return $null
}

function Show-ProxmoxRestoreWizardDialog {
    param($parentForm, $Storage)
    
    # Backup-Auswahl
    $backupToRestore = Show-ProxmoxBackupSelectionDialog -parentForm $parentForm -Storage $Storage
    if (-not $backupToRestore) { return $null }

    # Ziel-Speicher Auswahl
    $targetStorage = Show-ProxmoxStorageSelectionDialog -parentForm $parentForm
    if (-not $targetStorage) { return $null }

    # Neue VM-ID Abfrage
    $newVmId = [Microsoft.VisualBasic.Interaction]::InputBox("Geben Sie eine neue, freie VM-ID für die wiederhergestellte VM ein:", "Neue VM-ID festlegen")
    if (-not ($newVmId -match '^\d+$')) { return $null }

    # Gib alle gesammelten Informationen zurück
    return [PSCustomObject]@{
        BackupFile = $backupToRestore
        TargetStorage = $targetStorage
        NewVmId = $newVmId
    }
}

# In GhettoGUI_V8.0.1.36.ps1
# Ersetze die GESAMTE Funktion Start-ProxmoxRestoreWizard durch diese neue Version:

# In GhettoGUI_V8.0.1.36.ps1
# Ersetze die GESAMTE Funktion Start-ProxmoxRestoreWizard erneut durch diese Version:

function Start-ProxmoxRestoreWizard {
    param(
        [object]$parentForm, # Typ zu object geändert
        [string]$SourceStorage # Der Storage-Name, wo das Backup liegt
    )

    # 1. Alle Informationen über das Dialogfenster sammeln (unverändert)
    $wizardResult = Show-ProxmoxRestoreWizardDialog -parentForm $parentForm -Storage $SourceStorage
    if (-not $wizardResult) { Write-ProxmoxLog "Restore vom Benutzer abgebrochen."; return }

    # 2. API-Aufruf vorbereiten und ausführen
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Write-ProxmoxLog "-> Starte Restore von '$($wizardResult.BackupFile)' als neue VM '$($wizardResult.NewVmId)' auf Storage '$($wizardResult.TargetStorage)' via Proxmox API (Methode: VM erstellen)..."

        # Finde den Node-Namen (wir nehmen den ersten verfügbaren Node)
        $nodes = Invoke-ProxmoxApiRequest -Path "/nodes"
        if (-not $nodes) { throw "Konnte keine Nodes im Cluster finden." }
        $nodeName = $nodes[0].node
        if (-not $nodeName) { throw "Konnte den Namen des Nodes nicht aus der API-Antwort lesen." }

        # Parameter für den API-Aufruf zusammenstellen
        # WICHTIG: Der Parameter heißt 'archive', nicht 'volume'
        $apiParams = @{
            vmid = $wizardResult.NewVmId          # Die neue Ziel-VMID
            storage = $wizardResult.TargetStorage # Der Ziel-Storage
            archive = $wizardResult.BackupFile    # Das Backup-Archiv (Volume-ID)
            # Optional können hier weitere Parameter gesetzt werden,
            # um Einstellungen aus dem Backup zu überschreiben, z.B.:
            # cores = 2
            # memory = 4096
        }

        # API-Aufruf zum Starten des Restore-Tasks über den VM-Erstellungs-Endpunkt
        # Der Pfad ist jetzt /nodes/{node}/qemu
        $restoreTaskID = Invoke-ProxmoxApiRequest -Path "/nodes/$nodeName/qemu" -Method POST -Body $apiParams

        if ($restoreTaskID) {
            Write-ProxmoxLog "--> Restore-Task erfolgreich über API gestartet: $restoreTaskID"

            # Task-Objekt für den Timer erstellen (unverändert, TaskType ist 'api')
            $restoreTaskForTimer = [pscustomobject]@{
                TaskType  = 'api'
                ID        = $restoreTaskID
                Node      = $nodeName
                VMName    = "Restore-VM-$($wizardResult.NewVmId)"
                LinesRead = 0
            }

            # Task zur globalen Liste hinzufügen
            $Global:ProxmoxActiveTasks.Add($restoreTaskForTimer)

            # Timer starten, falls er nicht schon läuft
            if (-not $Global:ProxmoxTaskPollTimer.Enabled) { $Global:ProxmoxTaskPollTimer.Start() }
        } else {
             Write-ProxmoxLog "FEHLER: Der Restore-Task konnte nicht über die API gestartet werden (keine Task-ID zurückgegeben)."
             [System.Windows.Forms.MessageBox]::Show("Der Restore-Task konnte nicht gestartet werden.", "API Fehler", "OK", "Error")
        }

    } catch {
        # Detailliertere Fehlermeldung bei API-Fehler
        $errorMessage = $_.Exception.Message
        if ($_.Exception.Response) {
             $statusCode = $_.Exception.Response.StatusCode
             $statusDescription = $_.Exception.Response.StatusDescription
             $responseBody = $_.Exception.Response.GetResponseStream() | ForEach-Object { (New-Object System.IO.StreamReader($_)).ReadToEnd() }
             $errorMessage += "`n`nAPI Status: $statusCode ($statusDescription)`nAPI Antwort: $responseBody"
        }
        Write-ProxmoxLog "FEHLER beim Starten des Restores via API: $errorMessage"
        [System.Windows.Forms.MessageBox]::Show("Ein Fehler ist aufgetreten: $errorMessage", "Fehler", "OK", "Error")
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

# In GhettoGUI_V8.0.1.36.ps1

function Invoke-ProxmoxSshBackgroundTask {
    param(
        [string]$Command,
        [string]$VmName
    )
    $logId = "ghettogui_task_$(Get-Random)"
    $logPath = "/tmp/$logId.log"
    # NEU: Pfade für Marker-Dateien definieren
    $doneMarker = "$logPath.done"
    $errorMarker = "$logPath.error"

    # NEU: Befehl um Marker-Erstellung erweitert
    # && touch $doneMarker wird bei Erfolg ausgeführt
    # || touch $errorMarker wird bei Fehler ausgeführt
    $fullCommand = "nohup sh -c ""$Command && touch $doneMarker || touch $errorMarker"" > $logPath 2>&1 &"

    # Führe den modifizierten Befehl aus
    Invoke-SSHCommand -SSHSession $Global:ProxmoxSshSession -Command $fullCommand

    # Gib die Informationen ZUSÄTZLICH mit den Marker-Pfaden zurück
    return [PSCustomObject]@{
        ID = $logId
        LogPath = $logPath
        DoneMarker = $doneMarker       # << NEU
        ErrorMarker = $errorMarker     # << NEU
        Node = ($Global:ProxmoxSession.Host -split '\.')[0]
        VMName = $VmName
        LinesRead = 0
        ProcessIdentifier = ($Command -split ' ')[1]
    }
}

# --- Schritt 3: Alle GUI-Elemente für den Proxmox-Tab im 2-Spalten-Layout erstellen ---
[int]$pveCol1X = 20; [int]$pveCol1Width = 380; [int]$pveCol2X = $pveCol1X + $pveCol1Width + 20; [int]$pveCol2Width = 370;
[int]$currentY_pve_Col1 = 20; [int]$currentY_pve_Col2 = 20

# --- Linke Spalte ---
$groupPveConnection = New-Object System.Windows.Forms.GroupBox; $groupPveConnection.Text = "Verbindung"; $groupPveConnection.Location = New-Object System.Drawing.Point($pveCol1X, $currentY_pve_Col1); $groupPveConnection.Size = New-Object System.Drawing.Size($pveCol1Width, 130)
$labelProxmoxIp = New-Object System.Windows.Forms.Label; $labelProxmoxIp.Text = "Proxmox Host IP:"; $labelProxmoxIp.Location = New-Object System.Drawing.Point(15, 33); $labelProxmoxIp.AutoSize = $true
$textboxProxmoxIp = New-Object System.Windows.Forms.TextBox; $textboxProxmoxIp.Location = New-Object System.Drawing.Point(135, 30); $textboxProxmoxIp.Size = New-Object System.Drawing.Size(220, 20)
$labelProxmoxUser = New-Object System.Windows.Forms.Label; $labelProxmoxUser.Text = "Proxmox User:"; $labelProxmoxUser.Location = New-Object System.Drawing.Point(15, 63); $labelProxmoxUser.AutoSize = $true
$textboxProxmoxUser = New-Object System.Windows.Forms.TextBox; $textboxProxmoxUser.Location = New-Object System.Drawing.Point(135, 60); $textboxProxmoxUser.Size = New-Object System.Drawing.Size(220, 20); $textboxProxmoxUser.Text = "root@pam"
$buttonProxmoxConnect = New-Object System.Windows.Forms.Button; $buttonProxmoxConnect.Text = "Verbinden (API)"; $buttonProxmoxConnect.Location = New-Object System.Drawing.Point(205, 90); $buttonProxmoxConnect.Size = New-Object System.Drawing.Size(150, 25)
$groupPveConnection.Controls.AddRange(@($labelProxmoxIp, $textboxProxmoxIp, $labelProxmoxUser, $textboxProxmoxUser, $buttonProxmoxConnect))
$currentY_pve_Col1 += $groupPveConnection.Height + 10

$groupPveBackup = New-Object System.Windows.Forms.GroupBox; $groupPveBackup.Text = "Backup-Steuerung"; $groupPveBackup.Location = New-Object System.Drawing.Point($pveCol1X, $currentY_pve_Col1); $groupPveBackup.Size = New-Object System.Drawing.Size($pveCol1Width, 320)
$checkedListBoxProxmoxVms = New-Object System.Windows.Forms.CheckedListBox; $checkedListBoxProxmoxVms.Location = New-Object System.Drawing.Point(15, 30); $checkedListBoxProxmoxVms.Size = New-Object System.Drawing.Size(350, 200); $checkedListBoxProxmoxVms.CheckOnClick = $true
$labelProxmoxStorage = New-Object System.Windows.Forms.Label; $labelProxmoxStorage.Text = "Backup Storage:"; $labelProxmoxStorage.Location = New-Object System.Drawing.Point(15, 243); $labelProxmoxStorage.AutoSize = $true
$textboxProxmoxStorage = New-Object System.Windows.Forms.TextBox; $textboxProxmoxStorage.Location = New-Object System.Drawing.Point(135, 240); $textboxProxmoxStorage.Size = New-Object System.Drawing.Size(150, 20); $textboxProxmoxStorage.Text = "local"
$buttonBrowseProxmoxStorage = New-Object System.Windows.Forms.Button; $buttonBrowseProxmoxStorage.Text = "..."; $buttonBrowseProxmoxStorage.Location = New-Object System.Drawing.Point(290, 238); $buttonBrowseProxmoxStorage.Size = New-Object System.Drawing.Size(30, 25)

# --- Position der Buttons angepasst ---
$buttonProxmoxBackup = New-Object System.Windows.Forms.Button; $buttonProxmoxBackup.Text = "Backup starten"; $buttonProxmoxBackup.Location = New-Object System.Drawing.Point(15, 275); $buttonProxmoxBackup.Size = New-Object System.Drawing.Size(170, 25)

# --- NEUER "RESTORE"-BUTTON ---
$buttonProxmoxRestore = New-Object System.Windows.Forms.Button
$buttonProxmoxRestore.Text = "VM Backup restore"
$buttonProxmoxRestore.Location = New-Object System.Drawing.Point(195, 275) # Positioniert rechts neben dem Backup-Button
$buttonProxmoxRestore.Size = New-Object System.Drawing.Size(170, 25)
$buttonProxmoxRestore.ForeColor = [System.Drawing.Color]::DarkGreen
# --- ENDE NEUER BUTTON ---

$groupPveBackup.Controls.AddRange(@($checkedListBoxProxmoxVms, $labelProxmoxStorage, $textboxProxmoxStorage, $buttonBrowseProxmoxStorage, $buttonProxmoxBackup, $buttonProxmoxRestore))
$currentY_pve_Col1 += $groupPveBackup.Height

# --- Rechte Spalte ---
$groupPveSetup = New-Object System.Windows.Forms.GroupBox; $groupPveSetup.Text = "Storage Management"; $groupPveSetup.Location = New-Object System.Drawing.Point($pveCol2X, $currentY_pve_Col2); $groupPveSetup.Size = New-Object System.Drawing.Size($pveCol2Width, 160) # Höhe von 70 auf 110 erhöht
# $buttonSetupStorage = New-Object System.Windows.Forms.Button; $buttonSetupStorage.Text = "Neuen LVM Backup-Speicher einrichten..."; $buttonSetupStorage.Location = New-Object System.Drawing.Point(15, 25); $buttonSetupStorage.Size = New-Object System.Drawing.Size(340, 25)

# NEUER Button und Event:
$buttonAddStorage = New-Object System.Windows.Forms.Button # Neuer Name für die Variable
$buttonAddStorage.Text = "Neuen Speicher hinzufügen..."      # Neuer Text
$buttonAddStorage.Location = New-Object System.Drawing.Point(15, 25) # Position bleibt gleich
$buttonAddStorage.Size = New-Object System.Drawing.Size(340, 25)     # Größe bleibt gleich


$buttonAddStorage.Add_Click({
    # Vorab-Prüfung für API-Verbindung
    if (-not $Global:ProxmoxSession) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem Proxmox-Host verbinden.", "Keine Verbindung", "OK", "Warning");
        return
    }
    # NEU: Zeige den Auswahldialog
    $selectedType = Show-ProxmoxStorageTypeSelectionDialog -parentForm $form
    if (-not $selectedType) {
        Write-ProxmoxLog "Hinzufügen von neuem Speicher abgebrochen."
        return
    }

    Write-ProxmoxLog "Ausgewählter Speichertyp: $selectedType. Starte Assistent..."

    # Rufe den entsprechenden Assistenten auf
    switch ($selectedType) {
        'lvm' {
            Start-ProxmoxLvmStorageWizard -parentForm $form # Angepasste LVM-Funktion
        }
        'dir' {
            Start-ProxmoxDirectoryStorageWizard -parentForm $form # NEUE Funktion
        }
        'nfs' {
            Start-ProxmoxNfsStorageWizard -parentForm $form # Angepasste NFS-Funktion
        }
        'cifs' {
            Start-ProxmoxCifsStorageWizard -parentForm $form # NEUE Funktion
        }
        default {
            Write-ProxmoxLog "Unbekannter Speichertyp ausgewählt: $selectedType"
        }
    }
})

# --- NEUER "LÖSCHEN"-BUTTON ---
$buttonDeleteStorage = New-Object System.Windows.Forms.Button
$buttonDeleteStorage.Text = "Backup-Speicher löschen..."
$buttonDeleteStorage.Location = New-Object System.Drawing.Point(15, 60) # Positioniert unter dem ersten Button
$buttonDeleteStorage.Size = New-Object System.Drawing.Size(340, 25)
$buttonDeleteStorage.ForeColor = [System.Drawing.Color]::DarkRed # Rote Schrift als Warnung
# --- ENDE NEUER BUTTON ---

# --- NEUER "NFS MOUNT"-BUTTON ---
$buttonMountNfs = New-Object System.Windows.Forms.Button
$buttonMountNfs.Text = "NFS-Share als Backup-Speicher mounten..."
$buttonMountNfs.Location = New-Object System.Drawing.Point(15, 90) # Positioniert unter dem ersten Button
$buttonMountNfs.Size = New-Object System.Drawing.Size(340, 25)
# --- ENDE NEUER BUTTON ---

$groupPveSetup.Controls.AddRange(@($buttonAddStorage, $buttonDeleteStorage, $buttonMountNfs))
# $groupPveSetup.Controls.AddRange(@($buttonSetupStorage, $buttonDeleteStorage, $buttonMountNfs)) # Beide Buttons zur Gruppe hinzufügen
$currentY_pve_Col2 += $groupPveSetup.Height + 10

# --- Zeitplanungs-Box ---
$groupPveSchedule = New-Object System.Windows.Forms.GroupBox; $groupPveSchedule.Text = "Zeitplanung"; $groupPveSchedule.Location = New-Object System.Drawing.Point($pveCol2X, $currentY_pve_Col2); $groupPveSchedule.Size = New-Object System.Drawing.Size($pveCol2Width, 180);
$pveGcOffsetX = 10; $pveGcOffsetY = 20;
$labelPveScheduleTime = New-Object System.Windows.Forms.Label; $labelPveScheduleTime.Text = "Uhrzeit (HH:MM):"; $labelPveScheduleTime.Location = New-Object System.Drawing.Point($pveGcOffsetX, ($pveGcOffsetY + 3)); $labelPveScheduleTime.AutoSize = $true
$textboxPveScheduleHour = New-Object System.Windows.Forms.TextBox; $textboxPveScheduleHour.Location = New-Object System.Drawing.Point(110, $pveGcOffsetY); $textboxPveScheduleHour.Size = New-Object System.Drawing.Size(30, 20); $textboxPveScheduleHour.MaxLength = 2; $textboxPveScheduleHour.Text = "02"
$labelPveScheduleSeparator = New-Object System.Windows.Forms.Label; $labelPveScheduleSeparator.Text = ":"; $labelPveScheduleSeparator.AutoSize = $false; $labelPveScheduleSeparator.Size = New-Object System.Drawing.Size(8, 23); $labelPveScheduleSeparator.TextAlign = 'MiddleCenter'; $labelPveScheduleSeparator.Location = New-Object System.Drawing.Point($textboxPveScheduleHour.Right, $pveGcOffsetY)
$textboxPveScheduleMinute = New-Object System.Windows.Forms.TextBox; $textboxPveScheduleMinute.Location = New-Object System.Drawing.Point($labelPveScheduleSeparator.Right, $pveGcOffsetY); $textboxPveScheduleMinute.Size = New-Object System.Drawing.Size(30, 20); $textboxPveScheduleMinute.MaxLength = 2; $textboxPveScheduleMinute.Text = "00"

$pveGcOffsetY += 30 # Gehe zur nächsten Zeile für die Tage
$labelPveScheduleDays = New-Object System.Windows.Forms.Label; $labelPveScheduleDays.Text = "Tage:"; $labelPveScheduleDays.Location = New-Object System.Drawing.Point($pveGcOffsetX, ($pveGcOffsetY + 3)); $labelPveScheduleDays.AutoSize = $true
$checkboxPveDays = @{}

# KORREKTUR: Verwende englische Abkürzungen für die Tags
$days = @{ "So" = "sun"; "Mo" = "mon"; "Di" = "tue"; "Mi" = "wed"; "Do" = "thu"; "Fr" = "fri"; "Sa" = "sat" }

$dayPveCheckboxX = $pveGcOffsetX + 45
# Sortiere nach der Standardreihenfolge So(0) bis Sa(6) zum Anzeigen
$dayOrder = @{ "sun"=0; "mon"=1; "tue"=2; "wed"=3; "thu"=4; "fri"=5; "sat"=6 }
foreach ($dayEntry in $days.GetEnumerator() | Sort-Object { $dayOrder[$_.Value] }) {
    $displayName = $dayEntry.Name # Angezeigter Text (Deutsch)
    $tagValue = $dayEntry.Value   # Tag-Wert (Englisch für API)
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $displayName
    $cb.Tag = $tagValue # Setze den englischen Tag
    $cb.Location = New-Object System.Drawing.Point($dayPveCheckboxX, $pveGcOffsetY)
    $cb.AutoSize = $true
    $checkboxPveDays[$displayName] = $cb # Speichere unter deutschem Namen (optional)
    $dayPveCheckboxX += 43
}
$pveGcOffsetY += 30 # Nächste Zeile nach den Checkboxen

$buttonSavePveSchedule = New-Object System.Windows.Forms.Button; $buttonSavePveSchedule.Text = "Zeitplan in Proxmox speichern"; $buttonSavePveSchedule.Location = New-Object System.Drawing.Point(($groupPveSchedule.Width - 215), ($pveGcOffsetY + 40)); $buttonSavePveSchedule.Size = New-Object System.Drawing.Size(200, 25)
$groupPveSchedule.Controls.AddRange(@($labelPveScheduleTime, $textboxPveScheduleHour, $labelPveScheduleSeparator, $textboxPveScheduleMinute, $labelPveScheduleDays, $buttonSavePveSchedule))
$groupPveSchedule.Controls.AddRange($checkboxPveDays.Values)
$currentY_pve_Col2 += $groupPveSchedule.Height + 10

# --- NEU: E-Mail Box ---
$groupPveEmail = New-Object System.Windows.Forms.GroupBox; $groupPveEmail.Text = "E-Mail Benachrichtigung"; $groupPveEmail.Location = New-Object System.Drawing.Point($pveCol2X, $currentY_pve_Col2); $groupPveEmail.Size = New-Object System.Drawing.Size($pveCol2Width, 90);
$pveEmailGcOffsetY = 20
$labelPveEmailTo = New-Object System.Windows.Forms.Label; $labelPveEmailTo.Text = "Senden an:"; $labelPveEmailTo.Location = New-Object System.Drawing.Point(15, ($pveEmailGcOffsetY + 3)); $labelPveEmailTo.AutoSize = $true
$textboxPveEmailTo = New-Object System.Windows.Forms.TextBox; $textboxPveEmailTo.Location = New-Object System.Drawing.Point(100, $pveEmailGcOffsetY); $textboxPveEmailTo.Size = New-Object System.Drawing.Size(250, 20)
$labelPveEmailInfo = New-Object System.Windows.Forms.Label; $labelPveEmailInfo.Text = "(SMTP-Server muss in Proxmox unter`nDatacenter->Notifications konfiguriert sein)"; $labelPveEmailInfo.Location = New-Object System.Drawing.Point(100, ($pveEmailGcOffsetY + 25)); $labelPveEmailInfo.Size = New-Object System.Drawing.Size(250, 35); $labelPveEmailInfo.ForeColor = [System.Drawing.Color]::DimGray
$groupPveEmail.Controls.AddRange(@($labelPveEmailTo, $textboxPveEmailTo, $labelPveEmailInfo))
$currentY_pve_Col2 += $groupPveEmail.Height

# --- Unterer Bereich (Log) ---
$groupProxmoxLog = New-Object System.Windows.Forms.GroupBox; $groupProxmoxLog.Text = "Proxmox Aktivitäts-Log"
$logBoxYProxmox = [System.Math]::Max($currentY_pve_Col1, $currentY_pve_Col2) + 10
$groupProxmoxLog.Location = New-Object System.Drawing.Point($pveCol1X, $logBoxYProxmox)
$dynamicHeightProxmox = $proxmoxTab.ClientSize.Height - $logBoxYProxmox - 20
$groupProxmoxLog.Size = New-Object System.Drawing.Size(($proxmoxTab.ClientSize.Width - 40), $dynamicHeightProxmox)
$groupProxmoxLog.Anchor = 'Top, Left, Right, Bottom'
$textboxProxmoxLog = New-Object System.Windows.Forms.TextBox; $textboxProxmoxLog.Dock = [System.Windows.Forms.DockStyle]::Fill; $textboxProxmoxLog.Multiline = $true; $textboxProxmoxLog.ScrollBars = "Vertical"; $textboxProxmoxLog.ReadOnly = $true; $textboxProxmoxLog.Font = New-Object System.Drawing.Font("Consolas", 10); $groupProxmoxLog.Controls.Add($textboxProxmoxLog)

# --- Schritt 4: Alle erstellten Elemente zum Proxmox-Tab hinzufügen ---
$proxmoxTab.Controls.AddRange(@( $groupPveConnection, $groupPveBackup, $groupPveSetup, $groupPveSchedule, $groupPveEmail, $groupProxmoxLog ))


$buttonDeleteStorage.Add_Click({
    # --- Vorab-Prüfungen ---
    if (-not $Global:ProxmoxSession) { [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem Proxmox-Host verbinden.", "Keine Verbindung", "OK", "Warning"); return }
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { [System.Windows.Forms.MessageBox]::Show("Für diesen Assistenten wird eine SSH-Verbindung benötigt. Bitte zuerst im ESXi-Tab verbinden.", "SSH-Verbindung fehlt", "OK", "Warning"); return }

    # 1. Benutzer den zu löschenden Speicher auswählen lassen
    $storageToDelete = Show-ProxmoxDirectoryStorageSelectionDialog -parentForm $form
    if (-not $storageToDelete) { Write-ProxmoxLog "Löschvorgang vom Benutzer abgebrochen."; return }

    $storageId = $storageToDelete.storage
    $mountPoint = $storageToDelete.path

    # 2. FINALE, unmissverständliche Warnung
    $confirmMsg = "EXTREME VORSICHT! Sie sind dabei, den Speicher '$storageId' und alle darauf befindlichen Daten unwiderruflich zu löschen.`n`nDieser Vorgang wird:`n1. Den Speicher aus Proxmox entfernen.`n2. Das darunterliegende Laufwerk aushängen.`n3. Den Eintrag für den Neustart entfernen.`n4. Das Logical Volume auf der Festplatte löschen.`n`nSind Sie absolut sicher?"
    if ([System.Windows.Forms.MessageBox]::Show($confirmMsg, "Endgültige Bestätigung - DATENVERLUST!", "YesNo", "Error") -ne 'Yes') {
        Write-ProxmoxLog "Löschvorgang vom Benutzer abgebrochen."; return
    }

    # 3. Der automatisierte Löschprozess
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Write-ProxmoxLog "Starte Löschvorgang für Speicher '$storageId'..."
        
        # Schritt A: Finde das zugrunde liegende LVM-Laufwerk
        Write-ProxmoxLog "-> Finde zugrunde liegendes LVM-Volume für '$mountPoint'..."
        $sourceDeviceResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "findmnt -n -o SOURCE $mountPoint"
        $sourceDevice = ($sourceDeviceResult.Output -join '').Trim()
        if (-not ($sourceDevice -like "/dev/mapper/*")) { throw "Konnte kein gültiges LVM-Laufwerk für '$mountPoint' finden." }
        Write-ProxmoxLog "--> LVM-Volume gefunden: $sourceDevice"

        # Schritt B: Speicher aus Proxmox API entfernen
        Write-ProxmoxLog "-> Entferne Speicher '$storageId' aus der Proxmox-Konfiguration..."
        Invoke-ProxmoxApiRequest -Path "/storage/$storageId" -Method DELETE | Out-Null
        
        # Schritt C: Laufwerk aushängen (unmount)
        Write-ProxmoxLog "-> Hänge Laufwerk '$mountPoint' aus..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "umount -f $mountPoint" | Out-Null

        # Schritt D: Eintrag aus /etc/fstab entfernen
        Write-ProxmoxLog "-> Entferne Neustart-Eintrag aus /etc/fstab..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "sed -i '\#$mountPoint#d' /etc/fstab" | Out-Null

        # Schritt E: LVM-Volume deaktivieren und löschen
        Write-ProxmoxLog "-> Deaktiviere und lösche LVM-Volume '$sourceDevice'..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "lvchange -an $sourceDevice" | Out-Null
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "lvremove -y $sourceDevice" | Out-Null
        
        Write-ProxmoxLog "SUCCESS: Der Speicher '$storageId' und das zugehörige LVM-Volume wurden erfolgreich und vollständig entfernt!"
        [System.Windows.Forms.MessageBox]::Show("Der Speicher wurde erfolgreich entfernt.", "Erfolg", "OK", "Information")

    } catch {
        Write-ProxmoxLog "FEHLER beim Löschen des Speichers: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Ein Fehler ist aufgetreten: $($_.Exception.Message)", "Fehler", "OK", "Error")
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# --- Klick-Event für den "Zeitplan speichern"-Button ---


# In GhettoGUI_V8.0.1.36.ps1

$buttonSavePveSchedule.Add_Click({
    # --- Vorab-Prüfungen ---
    if (-not $Global:ProxmoxSession) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem Proxmox-Host verbinden.", "Keine Verbindung", "OK", "Warning");
        return
    }

    # Ausgewählte VMs/Container sammeln
    $selectedItems = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $checkedListBoxProxmoxVms.Items.Count; $i++) {
        if ($checkedListBoxProxmoxVms.GetItemChecked($i)) {
            [void]$selectedItems.Add($checkedListBoxProxmoxVms.Items[$i])
        }
    }
    if ($selectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Bitte mindestens eine VM oder einen Container für den Zeitplan auswählen.", "Keine Auswahl", "OK", "Warning");
        return
    }

    # --- 1. Eingaben aus der GUI sammeln ---
    $storage = $textboxProxmoxStorage.Text
    if ([string]::IsNullOrWhiteSpace($storage)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte den Namen des Backup-Storages angeben.", "Fehlende Eingabe", "OK", "Warning");
        return
    }
    $hour = $textboxPveScheduleHour.Text
    $minute = $textboxPveScheduleMinute.Text
    # Validierung für Stunde/Minute (optional, aber empfohlen)
    if (-not ($hour -match '^\d{1,2}$' -and $hour -ge 0 -and $hour -le 23) -or
        -not ($minute -match '^\d{1,2}$' -and $minute -ge 0 -and $minute -le 59)) {
         [System.Windows.Forms.MessageBox]::Show("Bitte eine gültige Uhrzeit (HH:MM) eingeben.", "Ungültige Zeit", "OK", "Warning");
         return
    }

    $emailTo = $textboxPveEmailTo.Text

    # Tage der Woche sammeln (verwende die Tags: mon, tue, etc.)
    $selectedDays = ($checkboxPveDays.GetEnumerator() | Where-Object { $_.Value.Checked } | ForEach-Object { $_.Value.Tag }) -join ',' # Tags sind bereits korrekt: mon, tue, ...
    if ([string]::IsNullOrEmpty($selectedDays)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte mindestens einen Tag für den Zeitplan auswählen.", "Keine Auswahl", "OK", "Warning");
        return
    }

    # VM-IDs explizit als Array von Strings sammeln
    $vmIdArray = $selectedItems | ForEach-Object {
        $match = [regex]::Match($_, "^(\d+)")
        if ($match.Success) { $match.Groups[1].Value } # Gibt die ID als String zurück
    } | Where-Object { $_ } # Filtere leere Einträge heraus

    # Prüfen, ob IDs gefunden wurden
    if ($vmIdArray.Count -eq 0) {
        # Diese Exception wird vom äußeren try/catch gefangen
        throw "Konnte keine gültigen VM-IDs aus der Auswahl extrahieren."
    }

    Write-ProxmoxLog "Erstelle Backup-Job in Proxmox..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor # Cursor auf Warten setzen
    try {
        # Hash-Tabelle mit den KORREKTEN Job-Parametern für /cluster/backup erstellen
        $jobParams = @{
            storage = $storage                # OK: Backup-Ziel-Storage
            dow = $selectedDays               # KORRIGIERT: Tage als Komma-Liste (z.B. "mon,tue,fri")
            starttime = "$($hour):$($minute)" # KORRIGIERT: Startzeit als HH:MM (z.B. "02:00")
            vmid = ($vmIdArray -join ',')     # KORRIGIERT: VMIDs als kommaseparierten String
            mode = 'snapshot'                 # OK: Backup-Modus
            compress = 'zstd'                 # OK: Komprimierung
            enabled = 1                       # KORRIGIERT: Als Integer 1 für "aktiviert"
        }

        # E-Mail nur hinzufügen, wenn eine Adresse eingegeben wurde
        if (-not [string]::IsNullOrWhiteSpace($emailTo)) {
            $jobParams.Add('mailto', $emailTo)
            $jobParams.Add('mailnotification', 'always') # OK
        }

        # --- 3. API-Aufruf ---
        Write-ProxmoxLog "Sende API Request zum Erstellen des Backup-Jobs..."

        # Logge den exakten JSON-Body, der gesendet wird
        $jsonBodyForLog = $jobParams | ConvertTo-Json -Depth 5 -Compress # Compress für kürzere Log-Ausgabe
        Write-ProxmoxLog "DEBUG: JSON Body: $jsonBodyForLog"

        # Rufe die (erweiterte) Funktion auf, die den API-Request macht
        New-ProxmoxBackupJob -JobSettings $jobParams

        Write-ProxmoxLog "SUCCESS: Geplanter Backup-Job wurde erfolgreich in Proxmox erstellt!"
        [System.Windows.Forms.MessageBox]::Show("Der geplante Backup-Job wurde erfolgreich in der Proxmox-Weboberfläche unter 'Rechenzentrum -> Backup' erstellt.", "Erfolg", "OK", "Information")

    } catch {
        # Fehlerbehandlung bleibt gleich, nutzt die erweiterte Fehlermeldung aus Invoke-ProxmoxApiRequest
        Write-ProxmoxLog "FEHLER beim Erstellen des Backup-Jobs: $($_.Exception.Message)" # Loggt die detaillierte Meldung
        [System.Windows.Forms.MessageBox]::Show("Ein Fehler ist aufgetreten: $($_.Exception.Message)", "Fehler", "OK", "Error")
    } finally {
         $form.Cursor = [System.Windows.Forms.Cursors]::Default # Cursor zurücksetzen
    }

}) # Ende $buttonSavePveSchedule.Add_Click


# --- Schritt 5: Alle Klick-Funktionen (Event Handler) definieren ---
$buttonProxmoxConnect.Add_Click({
    $proxmoxHost = $textboxProxmoxIp.Text
    $userApi = $textboxProxmoxUser.Text
    if ([string]::IsNullOrWhiteSpace($proxmoxHost) -or [string]::IsNullOrWhiteSpace($userApi)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte Host-IP und User eingeben.", "Fehlende Eingabe", "OK", "Warning"); return
    }
    $passwordDialog = [Microsoft.VisualBasic.Interaction]::InputBox("Passwort für $userApi eingeben:", "Proxmox Passwort")
    if ([string]::IsNullOrWhiteSpace($passwordDialog)) { return }

    Write-ProxmoxLog "Verbinde mit Proxmox API auf $proxmoxHost..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        # --- TEIL 1: API-Verbindung herstellen (wie bisher) ---
        $ticketData = Get-ProxmoxTicket -PveHost $proxmoxHost -Username $userApi -Password $passwordDialog
        $Global:ProxmoxSession = @{ Host = $proxmoxHost; BaseUrl = "https://$($proxmoxHost):8006/api2/json"; Ticket = $ticketData.ticket; CSRFPreventionToken = $ticketData.CSRFPreventionToken }
        Write-ProxmoxLog "-> API-Verbindung erfolgreich!"

        # --- TEIL 2 (NEU): SSH-Verbindung herstellen ---
        Write-ProxmoxLog "Stelle zusätzliche SSH-Verbindung her..."
        # Leite den SSH-Benutzernamen ab (z.B. "root" aus "root@pam")
        $userSsh = ($userApi -split '@')[0]
        $securePassword = ConvertTo-SecureString $passwordDialog -AsPlainText -Force
        $sshCredential = New-Object System.Management.Automation.PSCredential($userSsh, $securePassword)
        
        # Schliesse alte Proxmox SSH-Sitzung, falls vorhanden
        if ($Global:ProxmoxSshSession) { Remove-SSHSession -SSHSession $Global:ProxmoxSshSession -ErrorAction SilentlyContinue }
        
        $Global:ProxmoxSshSession = New-SSHSession -ComputerName $proxmoxHost -Credential $sshCredential -AcceptKey -ConnectionTimeout 60
        if ($Global:ProxmoxSshSession.Connected) {
            Write-ProxmoxLog "-> SSH-Verbindung erfolgreich!"
        } else {
            throw "Die SSH-Verbindung ist fehlgeschlagen."
        }
        
        # --- TEIL 3: VMs laden (wie bisher) ---
        Write-ProxmoxLog "Lade VM-Liste..."
        $checkedListBoxProxmoxVms.Items.Clear()
        $nodes = Invoke-ProxmoxApiRequest -Path "/nodes"
        # ... (Rest der Funktion bleibt gleich) ...
        if (-not $nodes) { throw "Konnte keine Nodes auf dem Proxmox-Host finden." }
        foreach ($node in $nodes) {
            $nodeName = $node.node
            Write-ProxmoxLog "-> Lade VMs und Container von Node '$nodeName'..."
            $vms = Invoke-ProxmoxApiRequest -Path "/nodes/$($nodeName)/qemu"
            $containers = Invoke-ProxmoxApiRequest -Path "/nodes/$($nodeName)/lxc"
            if ($vms) { $vms | ForEach-Object { $checkedListBoxProxmoxVms.Items.Add("$($_.vmid) (VM on '$($nodeName)'): $($_.name)", $false) } }
            if ($containers) { $containers | ForEach-Object { $checkedListBoxProxmoxVms.Items.Add("$($_.vmid) (CT on '$($nodeName)'): $($_.name)", $false) } }
        }
        Write-ProxmoxLog "$($checkedListBoxProxmoxVms.Items.Count) VMs und Container auf allen Nodes gefunden."

    } catch {
        Write-ProxmoxLog "FEHLER bei der Verbindung: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Verbindung fehlgeschlagen:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
        # Alles zurücksetzen bei Fehler
        $Global:ProxmoxSession = $null
        if ($Global:ProxmoxSshSession) { Remove-SSHSession -SSHSession $Global:ProxmoxSshSession -ErrorAction SilentlyContinue }
        $Global:ProxmoxSshSession = $null
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})


$buttonBrowseProxmoxStorage.Add_Click({ if (-not $Global:ProxmoxSession) { [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem Proxmox-Host verbinden.", "Keine Verbindung", "OK", "Warning"); return }; $selectedStorage = Show-ProxmoxStorageSelectionDialog -parentForm $form; if ($selectedStorage) { $textboxProxmoxStorage.Text = $selectedStorage; Write-ProxmoxLog "Proxmox Backup-Storage ausgewählt: $selectedStorage" } })

$buttonProxmoxBackup.Add_Click({
    if (-not $Global:ProxmoxSession) { [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem Proxmox-Host verbinden.", "Keine Verbindung", "OK", "Warning"); return }
    $selectedItems = New-Object System.Collections.ArrayList; for ($i = 0; $i -lt $checkedListBoxProxmoxVms.Items.Count; $i++) { if ($checkedListBoxProxmoxVms.GetItemChecked($i)) { [void]$selectedItems.Add($checkedListBoxProxmoxVms.Items[$i]) } }; if ($selectedItems.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Bitte mindestens eine VM oder einen Container für das Backup auswählen.", "Keine Auswahl", "OK", "Warning"); return }; $storage = $textboxProxmoxStorage.Text; if ([string]::IsNullOrWhiteSpace($storage)) { [System.Windows.Forms.MessageBox]::Show("Bitte den Namen des Backup-Storages angeben.", "Fehlende Eingabe", "OK", "Warning"); return }; $buttonProxmoxBackup.Enabled = $false; Write-ProxmoxLog "INFO: Starte Proxmox-Backup-Jobs...";
    foreach ($item in $selectedItems) {
        $match = [regex]::Match($item, "^(\d+)\s\(.+\s'(.*?)'.*\)"); if ($match.Success) {
            $vmid = $match.Groups[1].Value; $nodeName = $match.Groups[2].Value; $vmName = ($item -split ': ')[-1]; Write-ProxmoxLog "-> Starte Backup für '$vmName' (VMID $vmid auf Node '$nodeName')...";
            try {
                $backupTaskID = Invoke-ProxmoxApiRequest -Path "/nodes/$nodeName/vzdump" -Method POST -Body @{ vmid = $vmid; storage = $storage; mode = 'snapshot'; compress = 'zstd'; }; if ($backupTaskID) {
                    Write-ProxmoxLog "--> Task erfolgreich gestartet: $backupTaskID";
                    # --- HIER IST DIE ANPASSUNG ---
                    # Der Zähler wird jetzt direkt hier initialisiert
                    $Global:ProxmoxActiveTasks.Add([pscustomobject]@{ 
                        TaskType = 'api'; 
                        ID = $backupTaskID; 
                        Node = $nodeName; 
                        VMName = $vmName;
                        LinesRead = 0 # <<<<<<<<<<<<<<<< HIER INITIALISIERT!
                    })
                } else { Write-ProxmoxLog "--> FEHLER: Der Backup-Task konnte nicht gestartet werden." }
            } catch { Write-ProxmoxLog "--> FEHLER beim Starten des Backups für '$vmid': $($_.Exception.Message)" }
        } else { Write-ProxmoxLog "--> FEHLER: Konnte VMID und Node aus dem Eintrag '$item' nicht auslesen." }
    }; if (-not $Global:ProxmoxTaskPollTimer.Enabled -and $Global:ProxmoxActiveTasks.Count -gt 0) { $Global:ProxmoxTaskPollTimer.Start(); Write-ProxmoxLog "INFO: Task-Überwachung gestartet." } else { $buttonProxmoxBackup.Enabled = $true }
})

# In GhettoGUI_V8.0.1.36.ps1

$onProxmoxTaskPollTimerTick = {
    # Stoppt den Timer, wenn keine Tasks mehr aktiv sind
    if ($Global:ProxmoxActiveTasks.Count -eq 0) {
        $Global:ProxmoxTaskPollTimer.Stop()
        Write-ProxmoxLog "INFO: Keine aktiven Tasks mehr. Überwachung gestoppt."
        # Stelle sicher, dass der Button existiert und nicht disposed ist, bevor darauf zugegriffen wird
        if ($buttonProxmoxBackup -and -not $buttonProxmoxBackup.IsDisposed) {
            # Sicherer Zugriff auf das GUI-Element aus dem Timer-Thread
            $buttonProxmoxBackup.Invoke([Action]{ $buttonProxmoxBackup.Enabled = $true })
        }
        return
    }

    # Erstellt eine Kopie der Liste für die sichere Iteration
    $tasksToCheck = $Global:ProxmoxActiveTasks.ToArray()

    # Geht jeden aktiven Task durch
    foreach ($task in $tasksToCheck) {
        try {
            # Stellt sicher, dass der Zeilenzähler existiert
            if (-not $task.PSObject.Properties.Name -contains 'LinesRead') {
                $task | Add-Member -MemberType NoteProperty -Name 'LinesRead' -Value 0
            }

            # Unterscheidet den Task-Typ
            if ($task.TaskType -eq 'ssh') {
                # --- SSH-basierter Task (z.B. Restore) ---

                # 1. Lese neue Log-Zeilen für die Live-Anzeige
                # Stellt sicher, dass LinesRead existiert (sicherheitshalber)
                if (-not $task.PSObject.Properties.Name -contains 'LinesRead') {
                    $task | Add-Member -MemberType NoteProperty -Name 'LinesRead' -Value 0
                }
                $getNewLinesCmd = "tail -n +$($task.LinesRead + 1) '$($task.LogPath)'"
                # Führe Befehl aus, fange Fehler leise ab (z.B. wenn Log-Datei noch nicht existiert)
                $logResult = Invoke-SSHCommand -SSHSession $Global:ProxmoxSshSession -Command $getNewLinesCmd -ErrorAction SilentlyContinue

                if ($logResult.Output) {
                    $lineCount = 0
                    foreach ($line in $logResult.Output) {
                        # Passe die Log-Ausgabe an, um den Task-Typ anzuzeigen
                        $logPrefix = if ($task.VMName -like 'Restore*') { 'RESTORE' } else { 'SSH' }
                        Write-ProxmoxLog "  $logPrefix ($($task.VMName)): $line"
                        $lineCount++
                    }
                    # Nur erhöhen, wenn Zeilen gelesen wurden
                    if ($lineCount -gt 0) {
                        $task.LinesRead += $lineCount
                    }
                }

                # 2. Prüfe auf Abschluss-Marker-Dateien
                # Stellt sicher, dass die Marker-Pfade im Objekt existieren
                $doneMarkerPath = $task.PSObject.Properties['DoneMarker'] | Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue
                $errorMarkerPath = $task.PSObject.Properties['ErrorMarker'] | Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue

                # Nur prüfen, wenn die Pfade bekannt sind
                if ($doneMarkerPath -and $errorMarkerPath) {
                    $checkDoneCmd = "if [ -f '$doneMarkerPath' ]; then echo 'DONE'; fi"
                    $checkErrorCmd = "if [ -f '$errorMarkerPath' ]; then echo 'ERROR'; fi"

                    # Prüfe zuerst auf Fehler-Marker
                    $errorResult = Invoke-SSHCommand -SSHSession $Global:ProxmoxSshSession -Command $checkErrorCmd -ErrorAction SilentlyContinue
                    $doneResult = $null # Initialisiere doneResult

                    $jobFinished = $false
                    $finalStatus = "unbekannt"

                    if (($errorResult.Output -join '') -eq 'ERROR') {
                        $jobFinished = $true
                        $finalStatus = "ERROR"
                    } else {
                        # Nur wenn kein Fehler-Marker da ist, nach Erfolgs-Marker suchen
                        $doneResult = Invoke-SSHCommand -SSHSession $Global:ProxmoxSshSession -Command $checkDoneCmd -ErrorAction SilentlyContinue
                        if (($doneResult.Output -join '') -eq 'DONE') {
                            $jobFinished = $true
                            $finalStatus = "OK"
                        }
                    }

                    # Nur wenn eine Marker-Datei gefunden wurde, den Task beenden
                    if ($jobFinished) {
                         $logPrefix = if ($task.VMName -like 'Restore*') { 'Restore' } else { 'SSH-Task' }
                         Write-ProxmoxLog "FERTIG: $logPrefix für '$($task.VMName)' abgeschlossen. Status: $finalStatus"
                         # Log- und Marker-Dateien auf dem Server aufräumen
                         $cleanupCmd = "rm -f '$($task.LogPath)' '$doneMarkerPath' '$errorMarkerPath'"
                         Invoke-SSHCommand -SSHSession $Global:ProxmoxSshSession -Command $cleanupCmd -ErrorAction SilentlyContinue | Out-Null
                         # Task aus der Überwachungsliste entfernen
                         # Verwende eine Thread-sichere Methode zum Entfernen aus der Original-Liste
                         [System.Collections.Generic.List[object]]$Global:ProxmoxActiveTasks.Remove($task)

                    }
                    # Wenn keine Marker-Datei gefunden wurde, läuft der Job noch -> Timer läuft weiter
                } else {
                    # Fallback oder Fehlermeldung, falls Marker-Pfade fehlen
                     Write-ProxmoxLog "WARNUNG: Marker-Pfade für SSH-Task '$($task.ID)' nicht gefunden. Kann Endstatus nicht prüfen."
                     # Task entfernen, um Endlosschleife zu verhindern
                     [System.Collections.Generic.List[object]]$Global:ProxmoxActiveTasks.Remove($task)
                }

            }
            elseif ($task.TaskType -eq 'api') {
                # --- API-basierter Backup-Task (Dieser Teil bleibt unverändert) ---
                $taskLog = Get-ProxmoxTaskLog -NodeName $task.Node -TaskID $task.ID -StartLine $task.LinesRead -ErrorAction SilentlyContinue
                if ($taskLog) {
                    $lineCount = 0;
                    # Stelle sicher, dass $taskLog eine Sammlung ist, auch wenn nur ein Element zurückkommt
                    $logEntries = @($taskLog)
                    foreach ($line in $logEntries) {
                        # Prüfe, ob die Eigenschaft 't' existiert, bevor darauf zugegriffen wird
                        if ($line.PSObject.Properties['t']) {
                           Write-ProxmoxLog "  BACKUP ($($task.VMName)): $($line.t)";
                           $lineCount++
                        }
                     };
                     # Nur erhöhen, wenn Zeilen gelesen wurden
                     if ($lineCount -gt 0) {
                         $task.LinesRead += $lineCount
                     }
                }

                # Status abfragen
                $status = Get-ProxmoxTaskStatus -NodeName $task.Node -TaskID $task.ID -ErrorAction SilentlyContinue
                # Prüfe, ob Status erfolgreich abgefragt wurde UND der Status 'stopped' ist
                if ($status -and $status.status -eq 'stopped') {
                    Write-ProxmoxLog "FERTIG: Backup für '$($task.VMName)' beendet. Status: $($status.exitstatus)"
                    # Verwende eine Thread-sichere Methode zum Entfernen aus der Original-Liste
                    [System.Collections.Generic.List[object]]$Global:ProxmoxActiveTasks.Remove($task)
                }
                # Wenn Status nicht abgefragt werden konnte oder nicht 'stopped' ist, läuft der Timer weiter
            }
            else {
                # Fallback für unbekannte Tasks
                Write-ProxmoxLog "WARNUNG: Task ohne gültigen 'TaskType' gefunden ($($task.ID)). Task wird entfernt."
                # Verwende eine Thread-sichere Methode zum Entfernen aus der Original-Liste
                [System.Collections.Generic.List[object]]$Global:ProxmoxActiveTasks.Remove($task)
            }

        } catch {
            # Allgemeine Fehlerbehandlung
            Write-ProxmoxLog "FEHLER bei der Statusabfrage für Task '$($task.ID)': $($_.Exception.Message)"
            # Verwende eine Thread-sichere Methode zum Entfernen aus der Original-Liste bei Fehler
             try {
                [System.Collections.Generic.List[object]]$Global:ProxmoxActiveTasks.Remove($task)
             } catch {
                Write-ProxmoxLog "Zusätzlicher Fehler beim Entfernen des Tasks '$($task.ID)' nach Fehler."
             }
        }
    }
}

$Global:ProxmoxTaskPollTimer.Add_Tick($onProxmoxTaskPollTimerTick)
# $buttonSetupStorage.Add_Click({ Start-ProxmoxStorageWizard -parentForm $form })

$buttonMountNfs.Add_Click({
    if (-not $Global:ProxmoxSession) { [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem Proxmox-Host verbinden.", "Keine Verbindung", "OK", "Warning"); return }
    Start-ProxmoxNfsWizard -parentForm $form
})

$buttonProxmoxRestore.Add_Click({
    if (-not $Global:ProxmoxSession) { [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem Proxmox-Host verbinden.", "Keine Verbindung", "OK", "Warning"); return }
    $storage = $textboxProxmoxStorage.Text
    if ([string]::IsNullOrWhiteSpace($storage)) { [System.Windows.Forms.MessageBox]::Show("Bitte zuerst einen Backup-Storage auswählen, der die Quelldateien enthält.", "Kein Quell-Storage", "OK", "Warning"); return }
    
    # Ruft unseren neuen, kompletten Assistenten auf
    Start-ProxmoxRestoreWizard -parentForm $form -SourceStorage $storage
})

# =====================================================================================
# --- ENDE: Kompletter Proxmox-Codeblock ---
# =====================================================================================
# ======================================================================================================================
# --- Formular-Events und finaler Start ---

$form.Add_FormClosing({
    # Beendet alle laufenden PowerShell-Jobs beim Schliessen
    Get-Job | Remove-Job -Force
	if ($Global:trafficPollTimer -and $Global.trafficPollTimer.Enabled) { $Global:trafficPollTimer.Stop() }
    if ($Global:logPollTimer -and $Global:logPollTimer.Enabled) { $Global:logPollTimer.Stop() }
    if ($Global:replicationJobTimer -and $Global:replicationJobTimer.Enabled) { $Global:replicationJobTimer.Stop() }

    # NEU: Schliesst ALLE möglichen SSH-Verbindungen
    Write-GuiLog "Schließe alle SSH-Verbindungen..."
    if ($Global:ESXiSession) { Remove-SSHSession -SSHSession $Global:ESXiSession -ErrorAction SilentlyContinue }
    if ($Global:TargetESXiSession) { Remove-SSHSession -SSHSession $Global:TargetESXiSession -ErrorAction SilentlyContinue }
    if ($Global:sourceConsoleSession) { Remove-SSHSession -SSHSession $Global:sourceConsoleSession -ErrorAction SilentlyContinue }
    if ($Global:targetConsoleSession) { Remove-SSHSession -SSHSession $Global:targetConsoleSession -ErrorAction SilentlyContinue }

    # --- HIER DEN NEUEN AUFRÄUM-CODE EINFÜGEN ---
    Write-GuiLog "Lösche temporäre Setup-Dateien aus C:\temp..."
    $filesToDelete = @(
        "C:\temp\esxi_key_final*",
        "C:\temp\esxi_key_auto*",
        "C:\temp\ghetto_key_setup*",
        "C:\temp\setup_keys.bat"
    )
    foreach ($file in $filesToDelete) {
        if (Test-Path $file) {
            Remove-Item -Path $file -Force -ErrorAction SilentlyContinue
        }
    }
    Write-GuiLog "Temporäre Dateien gelöscht."
    # --- ENDE DES NEUEN CODES ---

    # --- HIER DEN NEUEN AUFRÄUM-CODE EINFÜGEN ---
    Write-GuiLog "Lösche eventuell erstellte Müll-Dateien im Programmverzeichnis..."
    $junkFiles = @('Bitte', 'Kopiere', 'Fuege', 'Schluesselpaar', 'Ueberfluessige', 'ECDSA-Schluesselpaar', 'Verwende')
    foreach ($junkFile in $junkFiles) {
        $filePath = Join-Path -Path $Global:ScriptPath -ChildPath $junkFile
        if (Test-Path $filePath) {
            Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
        }
    }


    # Schliesse das Konsolen-Fenster, falls es noch offen ist
    if ($sshConsoleForm -and -not $sshConsoleForm.IsDisposed) { $sshConsoleForm.Close() }
})

if (-not [System.Windows.Forms.Application]::MessageLoop) {
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
# Finale Startmeldung mit korrekter Version
Write-GuiLog "GhettoGUI V7.3.6, 12.09.2025 Bitte ESXi-Daten eingeben und verbinden."
$form.ShowDialog() | Out-Null
