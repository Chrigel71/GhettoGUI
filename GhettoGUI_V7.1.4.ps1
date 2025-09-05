# GhettoGUI_V7.1.4.ps1
#
# --- VERSION V7.1.4 (Final Stable Release by Chrigel#71)
# - FIX: Job laden lädt jetzt automatisch die VM-Liste und synchronisiert die Checkboxen korrekt.
# - NEU: Restore-Funktion zeigt Live-Fortschritt des Kopiervorgangs im Log an.
# - NEU: Sicherheitsabfrage (MessageBox) vor dem Starten eines Restore-Jobs.
# - FIX: Button "Diesen Ordner auswählen" wird jetzt in der korrekten Grösse dargestellt.
# - NEU: Abschluss-Popups für Replikation & Restore sind kontext-sensitiv und zeigen den VM-Namen an.
# - NEU: Restore-Funktion versendet jetzt ebenfalls eine detaillierte E-Mail-Benachrichtigung.
# - FIX: "Speichern"-Button im Replikations-Dialog wurde durch eine "Speichern unter..."-Funktion ersetzt.
# - FIX: Timeout für alle SSH- und SFTP-Verbindungen auf 60 Sekunden erhöht, um Probleme mit langsamen Hosts zu beheben.
# - Fix: email und Cron für ESXi 6.0
# - NEU: Restore und Hot Klone
# - NEU: Lokaler Klone mit Autostart und Cron

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
$form.Text = "GhettoGUI ESXi & GhettoVCB Manager V7.1.4"
$form.Size = New-Object System.Drawing.Size(830, 850) # Breite angepasst
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $true
$form.MinimizeBox = $true

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
        [string]$Message
    )

    $formCred = New-Object System.Windows.Forms.Form
    $formCred.Text = "Anmeldeinformationen"
    $formCred.Size = New-Object System.Drawing.Size(400, 200)
    $formCred.StartPosition = "CenterParent"
    $formCred.FormBorderStyle = 'FixedDialog'
    $formCred.MaximizeBox = $false
    $formCred.MinimizeBox = $false

    $labelMessage = New-Object System.Windows.Forms.Label
    $labelMessage.Text = $Message
    $labelMessage.Location = New-Object System.Drawing.Point(20, 20)
    $labelMessage.AutoSize = $true
    $formCred.Controls.Add($labelMessage)

    $labelUser = New-Object System.Windows.Forms.Label
    $labelUser.Text = "Benutzername:"
    $labelUser.Location = New-Object System.Drawing.Point(20, 50)
    $labelUser.AutoSize = $true
    $formCred.Controls.Add($labelUser)

    $textboxUser = New-Object System.Windows.Forms.TextBox
    $textboxUser.Text = $UserName
    $textboxUser.Location = New-Object System.Drawing.Point(150, 47)
    $textboxUser.Size = New-Object System.Drawing.Size(200, 20)
    $textboxUser.ReadOnly = $false # KORREKTUR 1: Feld editierbar machen
    $formCred.Controls.Add($textboxUser)

    $labelPassword = New-Object System.Windows.Forms.Label
    $labelPassword.Text = "Passwort:"
    $labelPassword.Location = New-Object System.Drawing.Point(20, 80)
    $labelPassword.AutoSize = $true
    $formCred.Controls.Add($labelPassword)

    $textboxPassword = New-Object System.Windows.Forms.TextBox
    $textboxPassword.Location = New-Object System.Drawing.Point(150, 77)
    $textboxPassword.Size = New-Object System.Drawing.Size(200, 20)
    $textboxPassword.UseSystemPasswordChar = $true
    $formCred.Controls.Add($textboxPassword)

    $buttonOk = New-Object System.Windows.Forms.Button
    $buttonOk.Text = "OK"
    $buttonOk.Location = New-Object System.Drawing.Point(190, 120)
    $buttonOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $formCred.AcceptButton = $buttonOk
    $formCred.Controls.Add($buttonOk)

    $buttonCancel = New-Object System.Windows.Forms.Button
    $buttonCancel.Text = "Abbrechen"
    $buttonCancel.Location = New-Object System.Drawing.Point(275, 120)
    $buttonCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $formCred.CancelButton = $buttonCancel
    $formCred.Controls.Add($buttonCancel)

    $formCred.Add_Shown({$textboxUser.Focus()})

    if ($formCred.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $securePassword = ConvertTo-SecureString $textboxPassword.Text -AsPlainText -Force
        # KORREKTUR 2: Den (eventuell geänderten) Benutzernamen aus dem Textfeld verwenden
        return New-Object System.Management.Automation.PSCredential($textboxUser.Text, $securePassword)
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
$connectButton = New-Object System.Windows.Forms.Button; $connectButton.Text = "Verbinden"; $connectButton.Location = New-Object System.Drawing.Point(($column1X + 120), $currentY_Col1); $connectButton.Size = New-Object System.Drawing.Size(85, 25)
$disconnectButton = New-Object System.Windows.Forms.Button; $disconnectButton.Text = "Trennen"; $disconnectButton.Location = New-Object System.Drawing.Point( ($connectButton.Location.X + $connectButton.Width + 5), $currentY_Col1); $disconnectButton.Size = New-Object System.Drawing.Size(85, 25); $disconnectButton.Enabled = $false
$currentY_Col1 += $connectButton.Height + 5
$buttonCheckPoshSsh = New-Object System.Windows.Forms.Button; $buttonCheckPoshSsh.Text = "Posh-SSH prüfen / Version anzeigen"; $buttonCheckPoshSsh.Location = New-Object System.Drawing.Point($column1X, $currentY_Col1); $buttonCheckPoshSsh.Size = New-Object System.Drawing.Size($column1Width, 25)
$currentY_Col1 += $buttonCheckPoshSsh.Height + 15
$groupGhettoConfig = New-Object System.Windows.Forms.GroupBox; $groupGhettoConfig.Text = "GhettoVCB Konfiguration"; $groupGhettoConfig.Location = New-Object System.Drawing.Point($column1X, $currentY_Col1); $groupGhettoConfig.Size = New-Object System.Drawing.Size(380, 405)
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
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($checkboxFixedBackupDir, "Wenn aktiviert, wird das Backup immer in denselben Ordner geschrieben und die alte Sicherung überschrieben (ohne Datums-Unterordner).")

# Jetzt, nachdem alle Controls auf dieser Zeile platziert sind, den Y-Offset für die nächste Zeile erhöhen.
$gcOffsetY += 30

$labelDiskFormat = New-Object System.Windows.Forms.Label; $labelDiskFormat.Text = "Disk Format:"; $labelDiskFormat.Location = New-Object System.Drawing.Point($gcOffsetX, ($gcOffsetY + 3)); $labelDiskFormat.AutoSize = $true
$comboboxDiskFormat = New-Object System.Windows.Forms.ComboBox; $comboboxDiskFormat.Location = New-Object System.Drawing.Point($gcControlX, $gcOffsetY); $comboboxDiskFormat.Size = New-Object System.Drawing.Size(120, 21); $comboboxDiskFormat.DropDownStyle = "DropDownList"
$comboboxDiskFormat.Items.AddRange(@("thin", "zeroedthick", "eagerzeroedthick")); if ($comboboxDiskFormat.Items.Count -gt 0) { $comboboxDiskFormat.SelectedIndex = 0 }
$gcOffsetY += 25
$checkboxSnapMem = New-Object System.Windows.Forms.CheckBox; $checkboxSnapMem.Text = "Snap Memory"; $checkboxSnapMem.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $checkboxSnapMem.AutoSize = $true; $checkboxSnapMem.Checked = $true
$checkboxSnapQuiesce = New-Object System.Windows.Forms.CheckBox; $checkboxSnapQuiesce.Text = "Snap Quiesce"; $checkboxSnapQuiesce.Location = New-Object System.Drawing.Point(([int]$checkboxSnapMem.Location.X + [int]$checkboxSnapMem.Width + 15), $gcOffsetY); $checkboxSnapQuiesce.AutoSize = $true; $checkboxSnapQuiesce.Checked = $true

# --- Gruppe für Replikations- & Klon-Buttons (NEUES LAYOUT) ---
[int]$replButtonX = 255
[int]$replButtonY = $gcOffsetY - 35
[int]$replButtonHeight = 25
[int]$replButtonSpacing = 3

$buttonReplicate = New-Object System.Windows.Forms.Button
$buttonReplicate.Text = "Replication (NAS)"
$buttonReplicate.Size = New-Object System.Drawing.Size(110, $replButtonHeight)
$buttonReplicate.Location = New-Object System.Drawing.Point($replButtonX, $replButtonY)
$buttonReplicate.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$buttonReplicate.ForeColor = [System.Drawing.Color]::DarkGreen
$toolTip.SetToolTip($buttonReplicate, "Startet die Replikation über einen zentralen Zwischenspeicher (z.B. ein NAS).")

$replButtonY += $replButtonHeight + $replButtonSpacing

$buttonDirectReplicate = New-Object System.Windows.Forms.Button
$buttonDirectReplicate.Text = "Direkte Repl. (H2H)"
$buttonDirectReplicate.Size = New-Object System.Drawing.Size(110, $replButtonHeight)
$buttonDirectReplicate.Location = New-Object System.Drawing.Point($replButtonX, $replButtonY)
$buttonDirectReplicate.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$buttonDirectReplicate.ForeColor = [System.Drawing.Color]::DarkBlue
$toolTip.SetToolTip($buttonDirectReplicate, "Startet die direkte Host-zu-Host Replikation.")

$replButtonY += $replButtonHeight + $replButtonSpacing

$buttonLocalReplicate = New-Object System.Windows.Forms.Button
$buttonLocalReplicate.Text = "Lokale Repl. (Klon)"
$buttonLocalReplicate.Size = New-Object System.Drawing.Size(110, $replButtonHeight)
$buttonLocalReplicate.Location = New-Object System.Drawing.Point($replButtonX, $replButtonY)
$buttonLocalReplicate.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$buttonLocalReplicate.ForeColor = [System.Drawing.Color]::DarkMagenta
$toolTip.SetToolTip($buttonLocalReplicate, "Startet einen lokalen Hot-Klon der ausgewählten VMs auf einen anderen Datastore dieses Hosts.")

$gcOffsetY += 30
$labelVmList = New-Object System.Windows.Forms.Label; $labelVmList.Text = "VMs (eine pro Zeile):"; $labelVmList.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $labelVmList.AutoSize = $true
$gcOffsetY += 20
$textboxVmList = New-Object System.Windows.Forms.TextBox; $textboxVmList.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $textboxVmList.Size = New-Object System.Drawing.Size(($groupGhettoConfig.Width - (2 * $gcOffsetX)), 60); $textboxVmList.Multiline = $true; $textboxVmList.ScrollBars = "Vertical"
$gcOffsetY += $textboxVmList.Height + 10
$buttonLoadVms = New-Object System.Windows.Forms.Button; $buttonLoadVms.Text = "VMs laden"; $buttonLoadVms.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $buttonLoadVms.Size = New-Object System.Drawing.Size(100, 25)
$buttonApplyVms = New-Object System.Windows.Forms.Button; $buttonApplyVms.Text = "Auswahl übernehmen"; $buttonApplyVms.Location = New-Object System.Drawing.Point(($gcOffsetX + [int]$buttonLoadVms.Width + 10), $gcOffsetY); $buttonApplyVms.Size = New-Object System.Drawing.Size(140, 25)

$buttonRestore = New-Object System.Windows.Forms.Button
$buttonRestore.Text = "Restore/Klon"
# Positioniert den Button rechts neben "Auswahl übernehmen"
$buttonRestore.Location = New-Object System.Drawing.Point(($buttonApplyVms.Right + 10), $gcOffsetY)
$buttonRestore.Size = New-Object System.Drawing.Size(100, 25)
$buttonRestore.ForeColor = [System.Drawing.Color]::DarkSlateGray
$buttonRestore.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

$gcOffsetY += $buttonLoadVms.Height + 5
$checkedListBoxVms = New-Object System.Windows.Forms.CheckedListBox; $checkedListBoxVms.DisplayMember = "DisplayName"; $checkedListBoxVms.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $checkedListBoxVms.Size = New-Object System.Drawing.Size(($groupGhettoConfig.Width - (2 * $gcOffsetX)), 80); $checkedListBoxVms.CheckOnClick = $true

$groupGhettoConfig.Controls.AddRange(@($labelGhettoPath, $textboxGhettoPath, $checkboxFixedBackupDir, $buttonBrowseGhettoPath, $labelBackupVol, $textboxBackupVol, $buttonBrowseBackupVol, $labelSubfolder, $textboxSubfolder, $labelRotation, $textboxRotation, $labelDiskFormat, $comboboxDiskFormat, $checkboxSnapMem, $checkboxSnapQuiesce, $buttonReplicate, $buttonDirectReplicate, $buttonLocalReplicate, $labelVmList, $textboxVmList, $buttonLoadVms, $buttonApplyVms, $buttonRestore, $checkedListBoxVms))

$currentY_Col1 = $groupGhettoConfig.Location.Y + $groupGhettoConfig.Height + 10
$buttonLoadGuiSettings = New-Object System.Windows.Forms.Button; $buttonLoadGuiSettings.Text = "Job laden..."; $buttonLoadGuiSettings.Location = New-Object System.Drawing.Point($column1X, $currentY_Col1); $buttonLoadGuiSettings.Size = New-Object System.Drawing.Size(185, 25); $buttonLoadGuiSettings.Enabled = $false
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
$buttonInstallGitHub = New-Object System.Windows.Forms.Button; $buttonInstallGitHub.Text = "Offizielles GhettoVCB installieren"; $buttonInstallGitHub.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $buttonInstallGitHub.Size = New-Object System.Drawing.Size(180, 25)
$buttonInstallPatchedGhetto = New-Object System.Windows.Forms.Button; $buttonInstallPatchedGhetto.Text = "GhettoVCB Patch"; $buttonInstallPatchedGhetto.Location = New-Object System.Drawing.Point( ([int]$buttonInstallGitHub.Location.X + [int]$buttonInstallGitHub.Width + 10), $currentY_Col2); $buttonInstallPatchedGhetto.Size = New-Object System.Drawing.Size(180, 25); $buttonInstallPatchedGhetto.ForeColor = [System.Drawing.Color]::Blue
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
    $buttonGitHub.Size = New-Object System.Drawing.Size(160, 30)
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
$buttonInstallSendmailPy.Size = New-Object System.Drawing.Size(160, 30)

# --- NEUER BUTTON FÜR SSH KONSOLE ---
$buttonOpenSshConsole = New-Object System.Windows.Forms.Button
$buttonOpenSshConsole.Text = "SSH-Konsole/Cron/Delete"
$buttonOpenSshConsole.Location = New-Object System.Drawing.Point( ([int]$buttonInstallSendmailPy.Location.X + [int]$buttonInstallSendmailPy.Width + 10), $currentY_Col2)
$buttonOpenSshConsole.Size = New-Object System.Drawing.Size(200, 30)
$buttonOpenSshConsole.ForeColor = [System.Drawing.Color]::DarkRed
$buttonOpenSshConsole.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$currentY_Col2 += $buttonInstallSendmailPy.Height + 10

# Block 2: Zeitplanung (komplett, platzsparend korrigiert)
$groupSchedule = New-Object System.Windows.Forms.GroupBox; $groupSchedule.Text = "Zeitplanung"; $groupSchedule.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $groupSchedule.Size = New-Object System.Drawing.Size($column2Width, 190) # Höhe reduziert
[int]$schedulesGcOffsetX = 10; [int]$schedulesGcOffsetY = 20
$labelScheduleTime = New-Object System.Windows.Forms.Label; $labelScheduleTime.Text = "Uhrzeit (HH:MM):"; $yPosLabelTime = $schedulesGcOffsetY + 3; $labelScheduleTime.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, $yPosLabelTime); $labelScheduleTime.AutoSize = $true
$textboxScheduleHour = New-Object System.Windows.Forms.TextBox; $xPosHour = $schedulesGcOffsetX + 120; $textboxScheduleHour.Location = New-Object System.Drawing.Point($xPosHour, $schedulesGcOffsetY); $textboxScheduleHour.Size = New-Object System.Drawing.Size(30, 20); $textboxScheduleHour.MaxLength = 2; $textboxScheduleHour.Text = "02"
$labelScheduleSeparator = New-Object System.Windows.Forms.Label; $labelScheduleSeparator.Text = ":"; $labelScheduleSeparator.AutoSize = $false; $labelScheduleSeparator.Size = New-Object System.Drawing.Size(8, 23); $labelScheduleSeparator.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter; $xPosSeparator = $textboxScheduleHour.Right; $labelScheduleSeparator.Location = New-Object System.Drawing.Point($xPosSeparator, $schedulesGcOffsetY)
$textboxScheduleMinute = New-Object System.Windows.Forms.TextBox; $xPosMinute = $labelScheduleSeparator.Right; $textboxScheduleMinute.Location = New-Object System.Drawing.Point($xPosMinute, $schedulesGcOffsetY); $textboxScheduleMinute.Size = New-Object System.Drawing.Size(30, 20); $textboxScheduleMinute.MaxLength = 2; $textboxScheduleMinute.Text = "00"
$schedulesGcOffsetY += 30
$labelScheduleDays = New-Object System.Windows.Forms.Label; $labelScheduleDays.Text = "Tage:"; $labelScheduleDays.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, $schedulesGcOffsetY); $labelScheduleDays.AutoSize = $true
$checkboxDays = @{}; $days = @{ "Mo" = 1; "Di" = 2; "Mi" = 3; "Do" = 4; "Fr" = 5; "Sa" = 6; "So" = 0 }; $dayCheckboxX = $schedulesGcOffsetX + 40
foreach ($day in $days.GetEnumerator() | Sort-Object Value) { $dName = $day.Name; if ($day.Value -eq 0) { $dName = "So" }; $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $dName; $cb.Tag = $day.Value; $cb.Location = New-Object System.Drawing.Point($dayCheckboxX, $schedulesGcOffsetY); $cb.AutoSize = $true; $checkboxDays[$dName] = $cb; $dayCheckboxX += 43 }
$schedulesGcOffsetY += 25

# Radio-Buttons für die Auswahl des Zeitplan-Typs (PLATZSPARENDES LAYOUT)
$radioScheduleBackup = New-Object System.Windows.Forms.RadioButton; $radioScheduleBackup.Text = "Backup planen (GhettoVCB)"; $radioScheduleBackup.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, $schedulesGcOffsetY); $radioScheduleBackup.AutoSize = $true; $radioScheduleBackup.Checked = $true
$schedulesGcOffsetY += 25
$toolTip.SetToolTip($radioScheduleBackup, "Plant ein Backup mit GhettoVCB mit den Einstellungen aus dem MainGUI.")


$radioScheduleRemoteReplication = New-Object System.Windows.Forms.RadioButton; $radioScheduleRemoteReplication.Text = "Direkte Repl. (H2H)"; $radioScheduleRemoteReplication.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, $schedulesGcOffsetY); $radioScheduleRemoteReplication.AutoSize = $true
$toolTip.SetToolTip($radioScheduleRemoteReplication, "Plant eine Host-zu-Host Replikation basierend auf den Einstellungen im 'Direkte Repl.'-Fenster.")

$radioScheduleLocalReplication = New-Object System.Windows.Forms.RadioButton; $radioScheduleLocalReplication.Text = "Lokale Repl. (Klon)";
$localReplX = $radioScheduleRemoteReplication.Location.X + 170
$radioScheduleLocalReplication.Location = New-Object System.Drawing.Point($localReplX, $schedulesGcOffsetY); $radioScheduleLocalReplication.AutoSize = $true
$toolTip.SetToolTip($radioScheduleLocalReplication, "Plant einen lokalen Hot-Klon basierend auf den Einstellungen im 'Lokale Repl.'-Fenster.")
$schedulesGcOffsetY += 30

$yPosStatusRow = $schedulesGcOffsetY
$labelUtcInfo = New-Object System.Windows.Forms.Label; $labelUtcInfo.Text = "(ESXi verwendet UTC-zeit!)"; $labelUtcInfo.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, ($yPosStatusRow + 4)); $labelUtcInfo.AutoSize = $true; $labelUtcInfo.ForeColor = [System.Drawing.Color]::DimGray
$labelEsxiTime = New-Object System.Windows.Forms.Label; $labelEsxiTime.Text = "ESXi nicht verbunden"; $labelEsxiTime.Location = New-Object System.Drawing.Point(($schedulesGcOffsetX + 155), ($yPosStatusRow + 4)); $labelEsxiTime.AutoSize = $true; $labelEsxiTime.ForeColor = [System.Drawing.Color]::Blue
$schedulesGcOffsetY += 25

$yPosButtonRow = $schedulesGcOffsetY
$buttonGetEsxiTime = New-Object System.Windows.Forms.Button; $buttonGetEsxiTime.Text = "ESXi-Zeit"; $buttonGetEsxiTime.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, $yPosButtonRow); $buttonGetEsxiTime.Size = New-Object System.Drawing.Size(110, 23)
$buttonSaveSchedule = New-Object System.Windows.Forms.Button; $buttonSaveSchedule.Text = "Zeitplan speichern"; $buttonSaveSchedule.Location = New-Object System.Drawing.Point(($buttonGetEsxiTime.Right + 10), $yPosButtonRow); $buttonSaveSchedule.Size = New-Object System.Drawing.Size(150, 23)

# Sammle alle Steuerelemente in einer Liste
$allScheduleControls = New-Object System.Collections.ArrayList
[void]$allScheduleControls.AddRange(@($labelScheduleTime, $textboxScheduleHour, $labelScheduleSeparator, $textboxScheduleMinute, $labelScheduleDays, $radioScheduleBackup, $radioScheduleRemoteReplication, $radioScheduleLocalReplication, $labelUtcInfo, $buttonSaveSchedule, $buttonGetEsxiTime, $labelEsxiTime))
[void]$allScheduleControls.AddRange($checkboxDays.Values)

# Füge alle Steuerelemente zur GroupBox hinzu
$groupSchedule.Controls.AddRange($allScheduleControls)

$currentY_Col2 = $groupSchedule.Location.Y + $groupSchedule.Height + 10

# Block 3: E-Mail Benachrichtigung
$groupEmail = New-Object System.Windows.Forms.GroupBox; $groupEmail.Text = "E-Mail Benachrichtigung"; $groupEmail.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $groupEmail.Size = New-Object System.Drawing.Size($column2Width, 261)
[int]$emailGcOffsetX = 10; [int]$emailGcOffsetY = 15; [int]$emailGcLabelWidth = 115
$checkboxEmailLog = New-Object System.Windows.Forms.CheckBox; $checkboxEmailLog.Text = "E-Mail-Benachrichtigung aktivieren"; $checkboxEmailLog.Location = New-Object System.Drawing.Point($emailGcOffsetX, $emailGcOffsetY); $checkboxEmailLog.AutoSize = $true
$emailGcOffsetY += 25
$buttonFirewallCheck = New-Object System.Windows.Forms.Button; $buttonFirewallCheck.Text = "Firewall-Check"; $buttonFirewallCheck.Location = New-Object System.Drawing.Point($emailGcOffsetX, $emailGcOffsetY); $buttonFirewallCheck.Size = New-Object System.Drawing.Size(110, 25)
$buttonTestEmail = New-Object System.Windows.Forms.Button; $buttonTestEmail.Text = "Email-Test"; $buttonTestEmail.Location = New-Object System.Drawing.Point(($buttonFirewallCheck.Right + 5), $emailGcOffsetY); $buttonTestEmail.Size = New-Object System.Drawing.Size(110, 25)
$buttonGetDebugLog = New-Object System.Windows.Forms.Button; $buttonGetDebugLog.Text = "Email-Log"; $buttonGetDebugLog.Location = New-Object System.Drawing.Point(($buttonTestEmail.Right + 5), $emailGcOffsetY); $buttonGetDebugLog.Size = New-Object System.Drawing.Size(110, 25)
$emailGcOffsetY += $buttonFirewallCheck.Height + 5
$labelEmailTo = New-Object System.Windows.Forms.Label; $labelEmailTo.Text = "Empfänger:"; $labelEmailTo.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailTo.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailTo = New-Object System.Windows.Forms.TextBox; $textboxEmailTo.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailTo.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20)
$emailGcOffsetY += 25
$labelEmailFrom = New-Object System.Windows.Forms.Label; $labelEmailFrom.Text = "Absender:"; $labelEmailFrom.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailFrom.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailFrom = New-Object System.Windows.Forms.TextBox; $textboxEmailFrom.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailFrom.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20)
$emailGcOffsetY += 25
$labelEmailServer = New-Object System.Windows.Forms.Label; $labelEmailServer.Text = "SMTP-Server:"; $labelEmailServer.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailServer.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailServer = New-Object System.Windows.Forms.TextBox; $textboxEmailServer.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailServer.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20)
$emailGcOffsetY += 25
$labelEmailPort = New-Object System.Windows.Forms.Label; $labelEmailPort.Text = "SMTP-Port:"; $labelEmailPort.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailPort.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailPort = New-Object System.Windows.Forms.TextBox; $textboxEmailPort.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailPort.Size = New-Object System.Drawing.Size(50, 20); $textboxEmailPort.Text = "25"
$emailGcOffsetY += 25
$labelEmailUser = New-Object System.Windows.Forms.Label; $labelEmailUser.Text = "Benutzername:"; $labelEmailUser.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailUser.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailUser = New-Object System.Windows.Forms.TextBox; $textboxEmailUser.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailUser.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20)
$emailGcOffsetY += 25
$labelEmailPassword = New-Object System.Windows.Forms.Label; $labelEmailPassword.Text = "Passwort:"; $labelEmailPassword.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailPassword.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailPassword = New-Object System.Windows.Forms.TextBox; $textboxEmailPassword.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailPassword.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20); $textboxEmailPassword.UseSystemPasswordChar = $true
$emailGcOffsetY += 25
$labelEmailSubject = New-Object System.Windows.Forms.Label; $labelEmailSubject.Text = "Betreff:"; $labelEmailSubject.Location = New-Object System.Drawing.Point($emailGcOffsetX, ($emailGcOffsetY + 3)); $labelEmailSubject.Size = New-Object System.Drawing.Size($emailGcLabelWidth, 20)
$textboxEmailSubject = New-Object System.Windows.Forms.TextBox; $textboxEmailSubject.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $textboxEmailSubject.Size = New-Object System.Drawing.Size(($groupEmail.Width - $emailGcLabelWidth - 25), 20); $textboxEmailSubject.Text = "Backup-Report für %h"
$emailGcOffsetY += $textboxEmailSubject.Height + 2
$labelSubjectInfo = New-Object System.Windows.Forms.Label; $labelSubjectInfo.Text = "(%h=Hostname)"; $labelSubjectInfo.Location = New-Object System.Drawing.Point(($emailGcOffsetX + $emailGcLabelWidth + 5), $emailGcOffsetY); $labelSubjectInfo.AutoSize = $true; $labelSubjectInfo.ForeColor = [System.Drawing.Color]::DimGray
$groupEmail.Controls.AddRange(@($checkboxEmailLog, $buttonFirewallCheck, $buttonTestEmail, $buttonGetDebugLog, $labelEmailTo, $textboxEmailTo, $labelEmailFrom, $textboxEmailFrom, $labelEmailServer, $textboxEmailServer, $labelEmailPort, $textboxEmailPort, $labelEmailUser, $textboxEmailUser, $labelEmailPassword, $textboxEmailPassword, $labelEmailSubject, $textboxEmailSubject, $labelSubjectInfo))
$currentY_Col2 = $groupEmail.Location.Y + $groupEmail.Height + 10
# Block 4: Backup-Aktionen
$buttonStartBackup = New-Object System.Windows.Forms.Button; $buttonStartBackup.Text = "GhettoVCB Backup jetzt starten"; $buttonStartBackup.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $buttonStartBackup.Size = New-Object System.Drawing.Size(180, 25)
$buttonCheckBackupStatus = New-Object System.Windows.Forms.Button; $buttonCheckBackupStatus.Text = "Backup-Log abrufen"; $buttonCheckBackupStatus.Location = New-Object System.Drawing.Point( ([int]$buttonStartBackup.Location.X + [int]$buttonStartBackup.Width + 10), $currentY_Col2); $buttonCheckBackupStatus.Size = New-Object System.Drawing.Size(180, 25);
$currentY_Col2 += $buttonStartBackup.Height + 5
$buttonCancelBackup = New-Object System.Windows.Forms.Button; $buttonCancelBackup.Text = "Backup abbrechen"; $buttonCancelBackup.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $buttonCancelBackup.Size = New-Object System.Drawing.Size(180, 25); $buttonCancelBackup.Enabled = $false
$buttonBrowseBackupDir = New-Object System.Windows.Forms.Button; $buttonBrowseBackupDir.Text = "Backup-Ordner Inhalt"; $buttonBrowseBackupDir.Location = New-Object System.Drawing.Point(([int]$buttonCancelBackup.Location.X + [int]$buttonCancelBackup.Width + 10), $currentY_col2); $buttonBrowseBackupDir.Size = New-Object System.Drawing.Size(180, 25)
$currentY_Col2 += $buttonCancelBackup.Height + 10

# --- Log/Output Box ---
[int]$logBoxY = [System.Math]::Max($currentY_Col1, $currentY_Col2) + 5
$outputBox = New-Object System.Windows.Forms.TextBox
$Global:outputBoxGUIRef = $outputBox
$outputBox.Location = New-Object System.Drawing.Point($column1X, $logBoxY)
$outputBox.Size = New-Object System.Drawing.Size(480, 150) # Breite auf 600px fixiert, Höhe angepasst
$outputBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$outputBox.Multiline = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.ReadOnly = $true
$outputBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# --- NEU: Netzwerk-Traffic Monitor (FINALE VERSION) ---
$groupTraffic = New-Object System.Windows.Forms.GroupBox
$groupTraffic.Text = "Netzwerk-Traffic"
$groupTraffic.Location = New-Object System.Drawing.Point(($outputBox.Right + 10), $logBoxY)
$groupTraffic.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - $outputBox.Right - 35), $outputBox.Height)
$groupTraffic.Anchor = 'Top, Bottom, Left, Right'

# Ein robustes TableLayoutPanel für eine saubere Anordnung
$trafficTable = New-Object System.Windows.Forms.TableLayoutPanel
$trafficTable.Dock = [System.Windows.Forms.DockStyle]::Fill
$trafficTable.ColumnCount = 2
$trafficTable.RowCount = 3

[void]$trafficTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$trafficTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$trafficTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$trafficTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$trafficTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

# Steuerelemente erstellen
$labelSelectNic = New-Object System.Windows.Forms.Label; $labelSelectNic.Text = "Netzwerkkarte:"; $labelSelectNic.Anchor = 'Left'; $labelSelectNic.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$comboVmnic = New-Object System.Windows.Forms.ComboBox; $comboVmnic.DropDownStyle = "DropDownList"; $comboVmnic.Dock = 'Fill'
$comboVmnic.DisplayMember = "" # WICHTIGER FIX: Verhindert den "Eigenschaft 'Text' nicht gefunden"-Fehler
$textTrafficStats = New-Object System.Windows.Forms.TextBox; $textTrafficStats.Multiline = $true; $textTrafficStats.ReadOnly = $true; $textTrafficStats.ScrollBars = "Vertical"; $textTrafficStats.Font = New-Object System.Drawing.Font("Consolas", 10); $textTrafficStats.Dock = 'Fill'

# Das Panel für die neuen MB/s-Anzeigen
$speedPanel = New-Object System.Windows.Forms.FlowLayoutPanel; $speedPanel.Dock = 'Fill'; $speedPanel.AutoSize = $true
$labelTrafficDown = New-Object System.Windows.Forms.Label; $labelTrafficDown.Text = "Down: --- MB/s"; $labelTrafficDown.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold); $labelTrafficDown.ForeColor = [System.Drawing.Color]::DarkGreen; $labelTrafficDown.AutoSize = $true; $labelTrafficDown.Margin = New-Object System.Windows.Forms.Padding(0, 5, 10, 0)
$labelTrafficUp = New-Object System.Windows.Forms.Label; $labelTrafficUp.Text = "Up:   --- MB/s"; $labelTrafficUp.Font = $labelTrafficDown.Font; $labelTrafficUp.ForeColor = [System.Drawing.Color]::Red; $labelTrafficUp.AutoSize = $true; $labelTrafficUp.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
$speedPanel.Controls.AddRange(@($labelTrafficDown, $labelTrafficUp))

# Steuerelemente der Tabelle zuweisen
$trafficTable.Controls.Add($labelSelectNic, 0, 0); $trafficTable.Controls.Add($comboVmnic, 1, 0)
$trafficTable.SetColumnSpan($textTrafficStats, 2); $trafficTable.Controls.Add($textTrafficStats, 0, 1)
$trafficTable.SetColumnSpan($speedPanel, 2); $trafficTable.Controls.Add($speedPanel, 0, 2)

# Die fertige Tabelle zur Gruppe hinzufügen
$groupTraffic.Controls.Add($trafficTable)
# --- Ende Netzwerk-Traffic Monitor ---


# Passe die Formularhöhe dynamisch an
$form.Height = $logBoxY + $outputBox.Height + 50

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

$onTrafficPollTimerTick = {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected -and $comboVmnic.SelectedItem)) { return }

    try {
        $selectedNic = $comboVmnic.SelectedItem
        $statsResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network nic stats get -n $selectedNic"
        
        if ($statsResult.ExitStatus -eq 0 -and $statsResult.Output) {
            $textTrafficStats.Text = ($statsResult.Output -join [Environment]::NewLine)
        } else {
            $textTrafficStats.Text = "Fehler beim Abrufen der Statistik.`n$($statsResult.Error -join [Environment]::NewLine)"
            return
        }
        
        $currentStats = @{}
        $statsResult.Output | ForEach-Object {
            if ($_ -match "Bytes received:\s+(\d+)") { $currentStats.Add('BytesReceived', [long]$Matches[1]) }
            if ($_ -match "Bytes sent:\s+(\d+)") { $currentStats.Add('BytesSent', [long]$Matches[1]) }
        }
        $currentStats.Add('Timestamp', (Get-Date))

        if ($null -ne $Global:lastTrafficStats) {
            $timeDiffSeconds = [Math]::Max(1, ($currentStats.Timestamp - $Global:lastTrafficStats.Timestamp).TotalSeconds)
            $bytesReceivedDiff = $currentStats.BytesReceived - $Global:lastTrafficStats.BytesReceived
            $bytesSentDiff = $currentStats.BytesSent - $Global:lastTrafficStats.BytesSent

            if ($bytesReceivedDiff -lt 0) { $bytesReceivedDiff = 0 }
            if ($bytesSentDiff -lt 0) { $bytesSentDiff = 0 }

            # HIER IST IHR PERSÖNLICHER KALIBRIERUNGSFAKTOR
            # Dieser Wert wurde experimentell ermittelt, um mit der ESXi-Anzeige übereinzustimmen.
            $divisor = 1000 * 1250 

            $downValue = ($bytesReceivedDiff / $timeDiffSeconds) / $divisor
            $upValue = ($bytesSentDiff / $timeDiffSeconds) / $divisor
            
            $labelTrafficDown.Text = "Down: {0:N2} MB/s" -f $downValue
            $labelTrafficUp.Text = "Up:   {0:N2} MB/s" -f $upValue
        }
        
        $Global:lastTrafficStats = $currentStats
    } catch {
        $textTrafficStats.Text = "FATALER FEHLER im Timer: $($_.Exception.Message)"
    }
}

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
# $buttonStartReplication.DialogResult = [System.Windows.Forms.DialogResult]::OK

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


    # 4. Den Job starten und den Timer zur Überwachung einrichten
 #   if ($Global:replicationJob -and $Global:replicationJob.State -eq 'Running') {
 #       [System.Windows.Forms.MessageBox]::Show("Es läuft bereits ein Replikations-Job.", "Fehler", "OK", "Warning")
 #       return
 #   }

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

# -- ######### # --- Definition des Direkte Replikation-Fensters --- Start #####
$directReplicationForm = New-Object System.Windows.Forms.Form
$directReplicationForm.Text = "Direkte Host-zu-Host Replikation"
$directReplicationForm.Size = New-Object System.Drawing.Size(420, 370)
$directReplicationForm.StartPosition = "CenterParent"
$directReplicationForm.FormBorderStyle = 'FixedDialog'
$directReplicationForm.MaximizeBox = $false
$directReplicationForm.MinimizeBox = $false

$drCurrentY = 20
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
$drCurrentY += 35

$groupRepMethod = New-Object System.Windows.Forms.GroupBox; $groupRepMethod.Text = "Replikationsmethode"; $groupRepMethod.Location = New-Object System.Drawing.Point(20, $drCurrentY); $groupRepMethod.Size = New-Object System.Drawing.Size(365, 50)
$radioTar = New-Object System.Windows.Forms.RadioButton; $radioTar.Text = "Repl. mit Temp (VM on)"; $radioTar.Name = "radioTar"; $radioTar.Location = New-Object System.Drawing.Point(15, 20); $radioTar.AutoSize = $true; $radioTar.Checked = $true
$radioVmkf = New-Object System.Windows.Forms.RadioButton; $radioVmkf.Text = "Repl. Stream (VM off)"; $radioVmkf.Name = "radioVmkf"; $radioVmkf.Location = New-Object System.Drawing.Point(200, 20); $radioVmkf.AutoSize = $true
$groupRepMethod.Controls.AddRange(@($radioTar, $radioVmkf))
$directReplicationForm.Controls.Add($groupRepMethod)
$drCurrentY += $groupRepMethod.Height + 15

# --- Button-Definitionen ---
$buttonSaveInPopup = New-Object System.Windows.Forms.Button; $buttonSaveInPopup.Text = "Job speichern"; $buttonSaveInPopup.Size = New-Object System.Drawing.Size(110, 25); $buttonSaveInPopup.Location = New-Object System.Drawing.Point(20, $drCurrentY)
$buttonStartDirectReplication = New-Object System.Windows.Forms.Button; $buttonStartDirectReplication.Text = "Replikation starten"; $buttonStartDirectReplication.DialogResult = [System.Windows.Forms.DialogResult]::OK; $buttonStartDirectReplication.Location = New-Object System.Drawing.Point(140, $drCurrentY); $buttonStartDirectReplication.Size = New-Object System.Drawing.Size(130, 25)
$buttonCancelDirectReplication = New-Object System.Windows.Forms.Button; $buttonCancelDirectReplication.Text = "Abbrechen"; $buttonCancelDirectReplication.Location = New-Object System.Drawing.Point(280, $drCurrentY); $buttonCancelDirectReplication.Size = New-Object System.Drawing.Size(100, 25); $buttonCancelDirectReplication.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$directReplicationForm.Controls.AddRange(@($buttonSaveInPopup, $buttonStartDirectReplication, $buttonCancelDirectReplication))
$directReplicationForm.AcceptButton = $buttonStartDirectReplication
$directReplicationForm.CancelButton = $buttonCancelDirectReplication

$buttonSaveInPopup.Add_Click({
    # Übernimmt die Logik vom Hauptfenster-Button "Job speichern unter..."
    $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveFileDialog.Title = "Job speichern unter..."
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
# -- ######### # --- Definition des Lokalen Replikations-Fensters (Mit UUID-Auswahl & Namen) --- Start #####
$localReplicationForm = New-Object System.Windows.Forms.Form
$localReplicationForm.Text = "Lokale Replikation (Hot-Klon)"
$localReplicationForm.Size = New-Object System.Drawing.Size(420, 260) # Höhe angepasst
$localReplicationForm.StartPosition = "CenterParent"
$localReplicationForm.FormBorderStyle = 'FixedDialog'
$localReplicationForm.MaximizeBox = $false
$localReplicationForm.MinimizeBox = $false

$lrCurrentY = 20
$labelLrTargetDs = New-Object System.Windows.Forms.Label; $labelLrTargetDs.Text = "Zielspeicher (auf diesem Host):"; $labelLrTargetDs.Location = New-Object System.Drawing.Point(20, ($lrCurrentY + 3)); $labelLrTargetDs.AutoSize = $true
$textboxLrTargetDs = New-Object System.Windows.Forms.TextBox; $textboxLrTargetDs.Location = New-Object System.Drawing.Point(180, $lrCurrentY); $textboxLrTargetDs.Size = New-Object System.Drawing.Size(165, 20)
$buttonBrowseLrTargetDs = New-Object System.Windows.Forms.Button; $buttonBrowseLrTargetDs.Text = "..."; $buttonBrowseLrTargetDs.Location = New-Object System.Drawing.Point(350, ($lrCurrentY - 1)); $buttonBrowseLrTargetDs.Size = New-Object System.Drawing.Size(30, 23)
$buttonBrowseLrTargetDs.Add_Click({
    $selectedPath = Show-DatastoreSelectionDialog
    if ($selectedPath) { $textboxLrTargetDs.Text = $selectedPath }
})
$localReplicationForm.Controls.AddRange(@($labelLrTargetDs, $textboxLrTargetDs, $buttonBrowseLrTargetDs))
$lrCurrentY += 35

$labelLrSuffix = New-Object System.Windows.Forms.Label; $labelLrSuffix.Text = "Suffix für VM-Name:"; $labelLrSuffix.Location = New-Object System.Drawing.Point(20, ($lrCurrentY + 3)); $labelLrSuffix.AutoSize = $true
$textboxLrSuffix = New-Object System.Windows.Forms.TextBox; $textboxLrSuffix.Location = New-Object System.Drawing.Point(180, $lrCurrentY); $textboxLrSuffix.Size = New-Object System.Drawing.Size(200, 20); $textboxLrSuffix.Text = "-LokalKlon"
$localReplicationForm.Controls.AddRange(@($labelLrSuffix, $textboxLrSuffix))
$lrCurrentY += 35

# Gruppe für die UUID/MAC-Auswahl
$groupUuidAction = New-Object System.Windows.Forms.GroupBox; $groupUuidAction.Text = "VM-Identität"; $groupUuidAction.Location = New-Object System.Drawing.Point(20, $lrCurrentY); $groupUuidAction.Size = New-Object System.Drawing.Size(365, 80)
$radioCreateUuid = New-Object System.Windows.Forms.RadioButton; $radioCreateUuid.Text = "Als 'Kopie' behandeln (Neue MAC & UUID)"; $radioCreateUuid.Location = New-Object System.Drawing.Point(15, 20); $radioCreateUuid.AutoSize = $true; $radioCreateUuid.Checked = $true
$radioCreateUuid.Name = 'radioCreateUuid' # <--- HIER IST DIE KORREKTUR
$toolTip.SetToolTip($radioCreateUuid, "Erstellt eine echte Kopie mit neuer Identität. Ideal für Test- und Entwicklungsumgebungen.")
$radioKeepUuid = New-Object System.Windows.Forms.RadioButton; $radioKeepUuid.Text = "Als 'verschoben' behandeln (MAC & UUID beibehalten)"; $radioKeepUuid.Location = New-Object System.Drawing.Point(15, 45); $radioKeepUuid.AutoSize = $true
$radioKeepUuid.Name = 'radioKeepUuid' # <--- HIER IST DIE KORREKTUR
$toolTip.SetToolTip($radioKeepUuid, "Stellt die VM 1:1 wieder her. Wichtig für Lizenzierungen und Restore-Szenarien.")
$groupUuidAction.Controls.AddRange(@($radioCreateUuid, $radioKeepUuid))
$localReplicationForm.Controls.Add($groupUuidAction)
$lrCurrentY += $groupUuidAction.Height + 15

# Button-Leiste mit "Job speichern"-Funktion
$buttonSaveLocalReplJob = New-Object System.Windows.Forms.Button; $buttonSaveLocalReplJob.Text = "Job speichern"; $buttonSaveLocalReplJob.Size = New-Object System.Drawing.Size(110, 25); $buttonSaveLocalReplJob.Location = New-Object System.Drawing.Point(20, $lrCurrentY)
$buttonStartLocalReplication = New-Object System.Windows.Forms.Button; $buttonStartLocalReplication.Text = "Klonen starten"; $buttonStartLocalReplication.DialogResult = [System.Windows.Forms.DialogResult]::OK; $buttonStartLocalReplication.Location = New-Object System.Drawing.Point(140, $lrCurrentY); $buttonStartLocalReplication.Size = New-Object System.Drawing.Size(130, 25)
$buttonCancelLocalReplication = New-Object System.Windows.Forms.Button; $buttonCancelLocalReplication.Text = "Abbrechen"; $buttonCancelLocalReplication.Location = New-Object System.Drawing.Point(280, $lrCurrentY); $buttonCancelLocalReplication.Size = New-Object System.Drawing.Size(100, 25); $buttonCancelLocalReplication.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

$localReplicationForm.Controls.AddRange(@($buttonSaveLocalReplJob, $buttonStartLocalReplication, $buttonCancelLocalReplication))
$localReplicationForm.AcceptButton = $buttonStartLocalReplication
$localReplicationForm.CancelButton = $buttonCancelLocalReplication
# -- ######### # --- Definition des Lokalen Replikations-Fensters --- Ende #####


#========================================================================================
# --- Definition des neuen Dual-Pane SSH-Konsolen-Fensters (V5 ---
#========================================================================================

$sshConsoleForm = New-Object System.Windows.Forms.Form
$sshConsoleForm.Text = "SSH Dual-Konsole & Einrichtungs-Assistent"
$sshConsoleForm.Size = New-Object System.Drawing.Size(1200, 800)
$sshConsoleForm.StartPosition = "CenterParent"
$sshConsoleForm.FormBorderStyle = 'Sizable'
$sshConsoleForm.MinimumSize = New-Object System.Drawing.Size(900, 600)

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

# -------------------- Start

# --- Unterer Bereich: ASSISTENT & CRON MANAGER (Layout mit Diagnose-Button) ---
$groupAssistant = New-Object System.Windows.Forms.GroupBox
$groupAssistant.Text = "Einrichtungs-Assistent & Cron-Job Management"
$groupAssistant.Location = New-Object System.Drawing.Point(10, 520)
$groupAssistant.Size = New-Object System.Drawing.Size(1160, 230)
$groupAssistant.Anchor = 'Bottom, Left, Right'

# --- Linke Seite: Host-zu-Host Setup ---
$groupSetup = New-Object System.Windows.Forms.GroupBox; $groupSetup.Text = "Host-zu-Host Setup"; $groupSetup.Location = New-Object System.Drawing.Point(15, 25); $groupSetup.Size = New-Object System.Drawing.Size(560, 120)
$buttonGenerateKey = New-Object System.Windows.Forms.Button; $buttonGenerateKey.Text = "1. Schlüssel & Transfer-Skript erstellen (Anleitung)"; $buttonGenerateKey.Location = New-Object System.Drawing.Point(15, 25); $buttonGenerateKey.Size = New-Object System.Drawing.Size(260, 35)
$buttonInjectKey = New-Object System.Windows.Forms.Button; $buttonInjectKey.Text = "2. Berechtigungen setzen (Anleitung)"; $buttonInjectKey.Location = New-Object System.Drawing.Point(285, 25); $buttonInjectKey.Size = New-Object System.Drawing.Size(260, 35)
$buttonTestKey = New-Object System.Windows.Forms.Button; $buttonTestKey.Text = "3. Finalen Verbindungstest durchführen"; $buttonTestKey.Location = New-Object System.Drawing.Point(15, 70); $buttonTestKey.Size = New-Object System.Drawing.Size(260, 35)
$buttonKillOrphans = New-Object System.Windows.Forms.Button; $buttonKillOrphans.Text = "Verwaiste Replikationen bereinigen mit kill (ID)"; $buttonKillOrphans.Location = New-Object System.Drawing.Point(285, 70); $buttonKillOrphans.Size = New-Object System.Drawing.Size(260, 35); $buttonKillOrphans.ForeColor = [System.Drawing.Color]::DarkRed
$groupSetup.Controls.AddRange(@($buttonGenerateKey, $buttonInjectKey, $buttonTestKey, $buttonKillOrphans))

# --- Rechte Seite: Cron Management ---
$groupCron = New-Object System.Windows.Forms.GroupBox; $groupCron.Text = "Geplante Tasks (Cron)"; $groupCron.Location = New-Object System.Drawing.Point(585, 25); $groupCron.Size = New-Object System.Drawing.Size(560, 120)
$buttonShowCronJobs = New-Object System.Windows.Forms.Button; $buttonShowCronJobs.Text = "Alle Tasks anzeigen"; $buttonShowCronJobs.Location = New-Object System.Drawing.Point(15, 25); $buttonShowCronJobs.Size = New-Object System.Drawing.Size(260, 35)
# NEUER BUTTON für die Diagnose
$buttonCronDiag = New-Object System.Windows.Forms.Button; $buttonCronDiag.Text = "Cron Diagnose-Info abrufen"; $buttonCronDiag.Location = New-Object System.Drawing.Point(285, 25); $buttonCronDiag.Size = New-Object System.Drawing.Size(260, 35); $buttonCronDiag.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$labelDeleteJob = New-Object System.Windows.Forms.Label; $labelDeleteJob.Text = "Task-Nr. zum Löschen:"; $labelDeleteJob.Location = New-Object System.Drawing.Point(15, 77); $labelDeleteJob.AutoSize = $true
$textboxJobNumber = New-Object System.Windows.Forms.TextBox; $textboxJobNumber.Location = New-Object System.Drawing.Point(160, 74); $textboxJobNumber.Size = New-Object System.Drawing.Size(50, 20)
$buttonDeleteCronJob = New-Object System.Windows.Forms.Button; $buttonDeleteCronJob.Text = "Task löschen"; $buttonDeleteCronJob.Location = New-Object System.Drawing.Point(225, 72); $buttonDeleteCronJob.Size = New-Object System.Drawing.Size(140, 25); $buttonDeleteCronJob.ForeColor = [System.Drawing.Color]::DarkRed
$buttonDeleteAllGhettoJobs = New-Object System.Windows.Forms.Button; $buttonDeleteAllGhettoJobs.Text = "Alle GhettoGUI Tasks löschen"; $buttonDeleteAllGhettoJobs.Location = New-Object System.Drawing.Point(375, 72); $buttonDeleteAllGhettoJobs.Size = New-Object System.Drawing.Size(170, 25); $buttonDeleteAllGhettoJobs.ForeColor = [System.Drawing.Color]::DarkRed
$groupCron.Controls.AddRange(@($buttonShowCronJobs, $buttonCronDiag, $labelDeleteJob, $textboxJobNumber, $buttonDeleteCronJob, $buttonDeleteAllGhettoJobs))

# Die Anleitung wird nun unterhalb der beiden Boxen platziert
$labelAssistantInfo = New-Object System.Windows.Forms.Label
$labelAssistantInfo.Text = @"
Anleitung:
Host-zu-Host Setup (links): Für die passwortlose Verbindung bei der direkten Replikation. In beiden Konsolen oben verbinden und den Buttons 1-3 folgen.
Geplante Tasks (rechts): Zeigt alle Cron-Jobs mit Zeilennummern an. Nummer in die Textbox eintragen und mit "Task löschen" entfernen.
Tipp: Die Cron-Datei liegt unter /var/spool/cron/crontabs/root. Der Dienst wird mit "crond" gestartet/neu gestartet.
"@

$labelAssistantInfo.Location = New-Object System.Drawing.Point(15, 155)
$labelAssistantInfo.Size = New-Object System.Drawing.Size(1130, 65)

$groupAssistant.Controls.AddRange(@($groupSetup, $groupCron, $labelAssistantInfo))


# ------ Schluss

# --- Fenster-Steuerelemente HINZUFÜGEN ---
$sshConsoleForm.Controls.AddRange(@(
    $groupSource,
    $groupTarget,
    $groupAssistant
))

# Fängt das Schliessen des Fensters ab und versteckt es nur
$sshConsoleForm.Add_FormClosing({
    param($sender, $e)
    $e.Cancel = $true
    $sender.Hide()
})

# --- LOGIK FÜR DAS DUAL-PANE-FENSTER ---
function Invoke-DualConsoleCommand {
    param($session, $command, $outputBox)
    if (-not ($session -and $session.Connected)) {
        $outputBox.SelectionColor = [System.Drawing.Color]::Yellow; $outputBox.AppendText("FEHLER: Keine aktive Verbindung für diese Konsole.`n"); $outputBox.SelectionColor = [System.Drawing.Color]::White; return
    }
    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $result = Invoke-SSHCommand -SSHSession $session -Command $command
        if ($result.Output) { $outputBox.AppendText(($result.Output -join "`n") + "`n") }
        if ($result.Error) {
            $outputBox.SelectionColor = [System.Drawing.Color]::Red; $outputBox.AppendText("SHELL-FEHLER:`n" + ($result.Error -join "`n") + "`n"); $outputBox.SelectionColor = [System.Drawing.Color]::White
        }
    } catch {
        $outputBox.SelectionColor = [System.Drawing.Color]::Red; $outputBox.AppendText("FATALER FEHLER: $($_.Exception.Message)`n"); $outputBox.SelectionColor = [System.Drawing.Color]::White
    } finally {
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default; $outputBox.ScrollToCaret()
    }
}

# Klick-Logik für den Haupt-Button, der das Fenster öffnet
$buttonOpenSshConsole.Add_Click({
    if ($Global:ESXiConnectedHostName) { $textboxSourceIp.Text = $Global:ESXiConnectedHostName }
    if ($Global:LastKnownTargetHost) { $textboxTargetIp.Text = $Global:LastKnownTargetHost }
    if ($sshConsoleForm.Visible) { $sshConsoleForm.Activate() } else { $sshConsoleForm.Show() }
})

# --- Linke & Rechte Konsolen-Logik ---
$buttonSourceConnect.Add_Click({
    if ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected) { $sourceConsoleOutput.AppendText("INFO: Bereits mit Quell-Host verbunden.`n"); return }
    $ip = $textboxSourceIp.Text; if ([string]::IsNullOrWhiteSpace($ip)) { [System.Windows.Forms.MessageBox]::Show("Bitte IP des Quell-Hosts eingeben."); return }
    try {
        $Global:sourceConsoleCredential = Show-CredentialPrompt -UserName "root" -Message "Passwort für Quell-Host root@$ip eingeben"
		if(-not $Global:sourceConsoleCredential) { return }
		$Global:sourceConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:sourceConsoleCredential -AcceptKey -ConnectionTimeout 60
		$groupSource.Text = "Quell-Host ($ip) - Verbunden"
        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::Lime; $sourceConsoleOutput.AppendText("INFO: Erfolgreich mit Quell-Host $ip verbunden.`n"); $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    } catch {
        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::Red; $sourceConsoleOutput.AppendText("FEHLER bei Verbindung zu $ip`: $($_.Exception.Message)`n"); $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    }
})
$buttonSourceDisconnect.Add_Click({
    if ($Global:sourceConsoleSession) { Remove-SSHSession -SSHSession $Global:sourceConsoleSession -EA 0; $Global:sourceConsoleSession = $null }
    $groupSource.Text = "Quell-Host"; $sourceConsoleOutput.AppendText("INFO: Verbindung zum Quell-Host getrennt.`n")
})
$sourceConsoleInput.Add_KeyDown({ param($sender, $e); if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $command = $sourceConsoleInput.Text; if ([string]::IsNullOrWhiteSpace($command)) { return }; $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::LawnGreen; $sourceConsoleOutput.AppendText("`n> $command`n"); $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White; $sourceConsoleInput.Clear(); Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput }})
$buttonTargetConnect.Add_Click({
    if ($Global:targetConsoleSession -and $Global:targetConsoleSession.Connected) { $targetConsoleOutput.AppendText("INFO: Bereits mit Ziel-Host verbunden.`n"); return }
    $ip = $textboxTargetIp.Text; if ([string]::IsNullOrWhiteSpace($ip)) { [System.Windows.Forms.MessageBox]::Show("Bitte IP des Ziel-Hosts eingeben."); return }
    try {
        $Global:targetConsoleCredential = Show-CredentialPrompt -UserName "root" -Message "Passwort für Ziel-Host root@$ip eingeben"
		if(-not $Global:targetConsoleCredential) { return }
        $Global:targetConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:targetConsoleCredential -AcceptKey -ConnectionTimeout 60
		$groupTarget.Text = "Ziel-Host ($ip) - Verbunden"
        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::Lime; $targetConsoleOutput.AppendText("INFO: Erfolgreich mit Ziel-Host $ip verbunden.`n"); $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    } catch {
        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::Red; $targetConsoleOutput.AppendText("FEHLER bei Verbindung zu $ip`: $($_.Exception.Message)`n"); $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    }
})
$buttonTargetDisconnect.Add_Click({
    if ($Global:targetConsoleSession) { Remove-SSHSession -SSHSession $Global:targetConsoleSession -EA 0; $Global:targetConsoleSession = $null }
    $groupTarget.Text = "Ziel-Host"; $targetConsoleOutput.AppendText("INFO: Verbindung zum Ziel-Host getrennt.`n")
})
$targetConsoleInput.Add_KeyDown({ param($sender, $e); if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $command = $targetConsoleInput.Text; if ([string]::IsNullOrWhiteSpace($command)) { return }; $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::LawnGreen; $targetConsoleOutput.AppendText("`n> $command`n"); $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White; $targetConsoleInput.Clear(); Invoke-DualConsoleCommand -session $Global:targetConsoleSession -command $command -outputBox $targetConsoleOutput }})


$buttonKillOrphans.Add_Click({
    Write-ConsoleLog $sourceConsoleOutput "--- Starte aggressives Bereinigen von Replikations-Resten ---" ([System.Drawing.Color]::Yellow)
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) {
        Write-ConsoleLog $sourceConsoleOutput "FEHLER: Keine Verbindung zum Quell-Host." ([System.Drawing.Color]::Red)
        return
    }

    try {
        # Schritt 1: Prozesse beenden
        Write-ConsoleLog $sourceConsoleOutput "-> Suche und beende laufende Replikations-Prozesse..." ([System.Drawing.Color]::Cyan)
        $findCmd = "ps -c | grep '[m]aster_replication'"
        $findResult = Invoke-SSHCommand -SSHSession $Global:sourceConsoleSession -Command $findCmd
        if ($findResult.ExitStatus -eq 0 -and $findResult.Output) {
            Write-ConsoleLog $sourceConsoleOutput "Gefundene Prozesse, die beendet werden:"
            $findResult.Output | ForEach-Object { Write-ConsoleLog $sourceConsoleOutput "  $_" }
            $killCmd = "ps -c | grep '[m]aster_replication' | awk '{print \$1}' | xargs kill -9"
            Invoke-SSHCommand -SSHSession $Global:sourceConsoleSession -Command $killCmd | Out-Null
            Write-ConsoleLog $sourceConsoleOutput "-> Kill-Befehl gesendet."
        } else {
            Write-ConsoleLog $sourceConsoleOutput "-> Keine laufenden 'master_replication'-Prozesse gefunden."
        }
        
        # Schritt 2: Temporäre Skript-Dateien löschen
        Write-ConsoleLog $sourceConsoleOutput "-> Räume temporäre Skript-Dateien in /tmp auf..." ([System.Drawing.Color]::Cyan)
        $cleanupScriptsCmd = "rm -f /tmp/master_replication_*; rm -f /tmp/launcher_*; rm -f /tmp/ghetto_pipe_error_*"
        Invoke-SSHCommand -SSHSession $Global:sourceConsoleSession -Command $cleanupScriptsCmd | Out-Null
        Write-ConsoleLog $sourceConsoleOutput "-> Temporäre Skript-Dateien gelöscht."

        # Schritt 3: Die Sperrdatei löschen
        Write-ConsoleLog $sourceConsoleOutput "-> Suche und lösche die Replikations-Sperrdatei..." ([System.Drawing.Color]::Cyan)
        $cleanupLockCmd = "rm -f /tmp/ghetto_replication.lock"
        Invoke-SSHCommand -SSHSession $Global:sourceConsoleSession -Command $cleanupLockCmd | Out-Null
        Write-ConsoleLog $sourceConsoleOutput "-> Sperrdatei /tmp/ghetto_replication.lock gelöscht."
        
        Write-ConsoleLog $sourceConsoleOutput "--- Bereinigung abgeschlossen. Das System ist bereit für eine neue Replikation. ---" ([System.Drawing.Color]::LawnGreen)

    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
    }
})


# LOGIK FÜR DIE NEUEN CRON-BUTTONS
$buttonShowCronJobs.Add_Click({
    Write-ConsoleLog $sourceConsoleOutput "--- Zeige geplante Tasks (crontab) auf Quell-Host ---" ([System.Drawing.Color]::Yellow)
    $command = 'awk ''{printf "%6d\t%s\n", NR, $0}'' /var/spool/cron/crontabs/root'
	Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput
})

# Löscht eine spezifische Zeile aus der crontab
$buttonDeleteCronJob.Add_Click({
    $lineNumber = $textboxJobNumber.Text
    if (-not ($lineNumber -match '^\d+$' -and $lineNumber -ne '0')) {
        [System.Windows.Forms.MessageBox]::Show("Bitte eine gültige Zeilennummer (größer als 0) eingeben.", "Ungültige Eingabe", "OK", "Warning"); return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show("Soll der Task in Zeile $lineNumber wirklich gelöscht werden?", "Löschen bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne 'Yes') { return }

    Write-ConsoleLog $sourceConsoleOutput "--- Lösche Task in Zeile $lineNumber ---" ([System.Drawing.Color]::Red)
    
    # KORREKTUR: Dies ist der korrekte 'sed'-Befehl, um nur EINE Zeile anhand ihrer Nummer zu löschen.
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

# --- FENSTER-STEUERELEMENTE HINZUFÜGEN (DER FEHLENDE TEIL) ---
$sshConsoleForm.Controls.AddRange(@(
    $groupSource,
    $groupTarget,
    $groupAssistant
))

# Fängt das Schliessen des Fensters ab und versteckt es nur
$sshConsoleForm.Add_FormClosing({
    param($sender, $e)
    $e.Cancel = $true
    $sender.Hide()
})

# --- LOGIK FÜR DAS DUAL-PANE-FENSTER (JETZT KORREKT GEORDNET) ---
function Invoke-DualConsoleCommand {
    param($session, $command, $outputBox)

    if (-not ($session -and $session.Connected)) {
        $outputBox.SelectionColor = [System.Drawing.Color]::Yellow
        $outputBox.AppendText("FEHLER: Keine aktive Verbindung für diese Konsole.`n")
        $outputBox.SelectionColor = [System.Drawing.Color]::White
        return
    }
    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $result = Invoke-SSHCommand -SSHSession $session -Command $command
        if ($result.Output) { $outputBox.AppendText(($result.Output -join "`n") + "`n") }
        if ($result.Error) {
            $outputBox.SelectionColor = [System.Drawing.Color]::Red
            $outputBox.AppendText("SHELL-FEHLER:`n" + ($result.Error -join "`n") + "`n")
            $outputBox.SelectionColor = [System.Drawing.Color]::White
        }
    } catch {
        $outputBox.SelectionColor = [System.Drawing.Color]::Red
        $outputBox.AppendText("FATALER FEHLER: $($_.Exception.Message)`n")
        $outputBox.SelectionColor = [System.Drawing.Color]::White
    } finally {
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $outputBox.ScrollToCaret()
    }
}

# Klick-Logik für den Haupt-Button, der das Fenster öffnet
$buttonOpenSshConsole.Add_Click({
    if ($Global:ESXiConnectedHostName) { $textboxSourceIp.Text = $Global:ESXiConnectedHostName }
    if ($Global:LastKnownTargetHost) { $textboxTargetIp.Text = $Global:LastKnownTargetHost }
    if ($sshConsoleForm.Visible) { $sshConsoleForm.Activate() } else { $sshConsoleForm.Show() }
})

# --- Linke Seite: Quell-Host Logik ---
$buttonSourceConnect.Add_Click({
    if ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected) { $sourceConsoleOutput.AppendText("INFO: Bereits mit Quell-Host verbunden.`n"); return }
    $ip = $textboxSourceIp.Text; if ([string]::IsNullOrWhiteSpace($ip)) { [System.Windows.Forms.MessageBox]::Show("Bitte IP des Quell-Hosts eingeben."); return }
    try {
        $Global:sourceConsoleCredential = Get-Credential -UserName "root" -Message "Passwort für Quell-Host root@$ip eingeben"
        if(-not $Global:sourceConsoleCredential) { return }
        $Global:sourceConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:sourceConsoleCredential -AcceptKey -ConnectionTimeout 60
		$groupSource.Text = "Quell-Host ($ip) - Verbunden"
        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::Lime; $sourceConsoleOutput.AppendText("INFO: Erfolgreich mit Quell-Host $ip verbunden.`n"); $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    } catch {
        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::Red; $sourceConsoleOutput.AppendText("FEHLER bei Verbindung zu $ip`: $($_.Exception.Message)`n"); $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    }
})
$buttonSourceDisconnect.Add_Click({
    if ($Global:sourceConsoleSession) { Remove-SSHSession -SSHSession $Global:sourceConsoleSession -EA 0; $Global:sourceConsoleSession = $null }
    $groupSource.Text = "Quell-Host"; $sourceConsoleOutput.AppendText("INFO: Verbindung zum Quell-Host getrennt.`n")
})
$sourceConsoleInput.Add_KeyDown({
    param($sender, $e); if ($e.KeyCode -eq 'Enter') {
        $e.SuppressKeyPress = $true; $command = $sourceConsoleInput.Text; if ([string]::IsNullOrWhiteSpace($command)) { return }
        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::LawnGreen; $sourceConsoleOutput.AppendText("`n> $command`n"); $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White; $sourceConsoleInput.Clear()
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput
    }
})

# --- Rechte Seite: Ziel-Host Logik ---
$buttonTargetConnect.Add_Click({
    if ($Global:targetConsoleSession -and $Global:targetConsoleSession.Connected) { $targetConsoleOutput.AppendText("INFO: Bereits mit Ziel-Host verbunden.`n"); return }
    $ip = $textboxTargetIp.Text; if ([string]::IsNullOrWhiteSpace($ip)) { [System.Windows.Forms.MessageBox]::Show("Bitte IP des Ziel-Hosts eingeben."); return }
    try {
        $Global:targetConsoleCredential = Get-Credential -UserName "root" -Message "Passwort für Ziel-Host root@$ip eingeben"
        if(-not $Global:targetConsoleCredential) { return }
        $Global:targetConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:targetConsoleCredential -AcceptKey -ConnectionTimeout 60
		$groupTarget.Text = "Ziel-Host ($ip) - Verbunden"
        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::Lime; $targetConsoleOutput.AppendText("INFO: Erfolgreich mit Ziel-Host $ip verbunden.`n"); $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    } catch {
        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::Red; $targetConsoleOutput.AppendText("FEHLER bei Verbindung zu $ip`: $($_.Exception.Message)`n"); $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    }
})
$buttonTargetDisconnect.Add_Click({
    if ($Global:targetConsoleSession) { Remove-SSHSession -SSHSession $Global:targetConsoleSession -EA 0; $Global:targetConsoleSession = $null }
    $groupTarget.Text = "Ziel-Host"; $targetConsoleOutput.AppendText("INFO: Verbindung zum Ziel-Host getrennt.`n")
})
$targetConsoleInput.Add_KeyDown({
    param($sender, $e); if ($e.KeyCode -eq 'Enter') {
        $e.SuppressKeyPress = $true; $command = $targetConsoleInput.Text; if ([string]::IsNullOrWhiteSpace($command)) { return }
        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::LawnGreen; $targetConsoleOutput.AppendText("`n> $command`n"); $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White; $targetConsoleInput.Clear()
        Invoke-DualConsoleCommand -session $Global:targetConsoleSession -command $command -outputBox $targetConsoleOutput
    }
})

# Fängt das Schliessen des Fensters ab und versteckt es nur
$sshConsoleForm.Add_FormClosing({
    param($sender, $e)
    # Verhindert das endgültige Schliessen und Zerstören des Objekts
    $e.Cancel = $true
    # Versteckt das Fenster stattdessen
    $sender.Hide()
})

# --- LOGIK FÜR DAS DUAL-PANE-FENSTER

# Hilfsfunktion, um Befehle in der jeweiligen Konsole auszuführen und anzuzeigen
function Invoke-DualConsoleCommand {
    param($session, $command, $outputBox)

    if (-not ($session -and $session.Connected)) {
        $outputBox.SelectionColor = [System.Drawing.Color]::Yellow
        $outputBox.AppendText("FEHLER: Keine aktive Verbindung für diese Konsole.`n")
        $outputBox.SelectionColor = [System.Drawing.Color]::White
        return
    }
    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $result = Invoke-SSHCommand -SSHSession $session -Command $command
        if ($result.Output) { $outputBox.AppendText(($result.Output -join "`n") + "`n") }
        if ($result.Error) {
            $outputBox.SelectionColor = [System.Drawing.Color]::Red
            $outputBox.AppendText("SHELL-FEHLER:`n" + ($result.Error -join "`n") + "`n")
            $outputBox.SelectionColor = [System.Drawing.Color]::White
        }
    } catch {
        $outputBox.SelectionColor = [System.Drawing.Color]::Red
        $outputBox.AppendText("FATALER FEHLER: $($_.Exception.Message)`n")
        $outputBox.SelectionColor = [System.Drawing.Color]::White
    } finally {
        $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $outputBox.ScrollToCaret()
    }
}

# Klick-Logik für den Haupt-Button, der das Fenster öffnet
$buttonOpenSshConsole.Add_Click({
    # Fülle die Konsolenfelder mit den Daten aus der Haupt-GUI, falls vorhanden
    if ($Global:ESXiConnectedHostName) {
        $textboxSourceIp.Text = $Global:ESXiConnectedHostName
    }
    if ($Global:LastKnownTargetHost) {
        $textboxTargetIp.Text = $Global:LastKnownTargetHost
    }

    if ($sshConsoleForm.Visible) { $sshConsoleForm.Activate() } else { $sshConsoleForm.Show() }
})

# --- Linke Seite: Quell-Host Logik ---
$buttonSourceConnect.Add_Click({
    if ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected) { $sourceConsoleOutput.AppendText("INFO: Bereits mit Quell-Host verbunden.`n"); return }
    $ip = $textboxSourceIp.Text
    if ([string]::IsNullOrWhiteSpace($ip)) { [System.Windows.Forms.MessageBox]::Show("Bitte IP des Quell-Hosts eingeben."); return }
    try {
		$Global:sourceConsoleCredential = Get-Credential -UserName "root" -Message "Passwort für Quell-Host root@$ip eingeben"
if(-not $Global:sourceConsoleCredential) { return }
$Global:sourceConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:sourceConsoleCredential -AcceptKey -ConnectionTimeout 60
		$groupSource.Text = "Quell-Host ($ip) - Verbunden"
        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::Lime
        $sourceConsoleOutput.AppendText("INFO: Erfolgreich mit Quell-Host $ip verbunden.`n")
        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    } catch {
        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::Red
        $sourceConsoleOutput.AppendText("FEHLER bei Verbindung zu $ip`: $($_.Exception.Message)`n")
        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    }
})
$buttonSourceDisconnect.Add_Click({
    if ($Global:sourceConsoleSession) { Remove-SSHSession -SSHSession $Global:sourceConsoleSession -EA 0; $Global:sourceConsoleSession = $null }
    $groupSource.Text = "Quell-Host"
    $sourceConsoleOutput.AppendText("INFO: Verbindung zum Quell-Host getrennt.`n")
})
$sourceConsoleInput.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq 'Enter') {
        $e.SuppressKeyPress = $true
        $command = $sourceConsoleInput.Text
        if ([string]::IsNullOrWhiteSpace($command)) { return }

        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::LawnGreen
        $sourceConsoleOutput.AppendText("`n> $command`n")
        $sourceConsoleOutput.SelectionColor = [System.Drawing.Color]::White
        $sourceConsoleInput.Clear()

        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput
    }
})

# --- Rechte Seite: Ziel-Host Logik ---
$buttonTargetConnect.Add_Click({
    if ($Global:targetConsoleSession -and $Global:targetConsoleSession.Connected) { $targetConsoleOutput.AppendText("INFO: Bereits mit Ziel-Host verbunden.`n"); return }
    $ip = $textboxTargetIp.Text
    if ([string]::IsNullOrWhiteSpace($ip)) { [System.Windows.Forms.MessageBox]::Show("Bitte IP des Ziel-Hosts eingeben."); return }
    try {
        $Global:targetConsoleCredential = Get-Credential -UserName "root" -Message "Passwort für Ziel-Host root@$ip eingeben"
if(-not $Global:targetConsoleCredential) { return }
$Global:targetConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:targetConsoleCredential -AcceptKey -ConnectionTimeout 60
		$groupTarget.Text = "Ziel-Host ($ip) - Verbunden"
        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::Lime
        $targetConsoleOutput.AppendText("INFO: Erfolgreich mit Ziel-Host $ip verbunden.`n")
        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    } catch {
        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::Red
        $targetConsoleOutput.AppendText("FEHLER bei Verbindung zu $ip`: $($_.Exception.Message)`n")
        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White
    }
})
$buttonTargetDisconnect.Add_Click({
    if ($Global:targetConsoleSession) { Remove-SSHSession -SSHSession $Global:targetConsoleSession -EA 0; $Global:targetConsoleSession = $null }
    $groupTarget.Text = "Ziel-Host"
    $targetConsoleOutput.AppendText("INFO: Verbindung zum Ziel-Host getrennt.`n")
})
$targetConsoleInput.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq 'Enter') {
        $e.SuppressKeyPress = $true
        $command = $targetConsoleInput.Text
        if ([string]::IsNullOrWhiteSpace($command)) { return }

        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::LawnGreen
        $targetConsoleOutput.AppendText("`n> $command`n")
        $targetConsoleOutput.SelectionColor = [System.Drawing.Color]::White
        $targetConsoleInput.Clear()

        Invoke-DualConsoleCommand -session $Global:targetConsoleSession -command $command -outputBox $targetConsoleOutput
    }
})

# --- FINALE LOGIK FÜR DIE ASSISTENTEN-BUTTONS ---


# Button 1: Erstellt den korrekten ECDSA-Schlüssel und das Transfer-Skript
$buttonGenerateKey.Add_Click({
    $sourceIp = $textboxSourceIp.Text
    $targetIp = $textboxTargetIp.Text
    if ([string]::IsNullOrWhiteSpace($sourceIp) -or [string]::IsNullOrWhiteSpace($targetIp)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst die IPs für Quelle und Ziel in die Felder oben eintragen.", "Fehlende Eingabe", "OK", "Warning"); return
    }

    Write-ConsoleLog $sourceConsoleOutput "Schritt 1: Bereite alles auf dem PC vor..." ([System.Drawing.Color]::Cyan)
    $sshConsoleForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        # Temporäres Verzeichnis sicherstellen
        if (-not (Test-Path "C:\temp")) { New-Item -Path "C:\temp" -ItemType Directory | Out-Null }
        
        $keyFile = "C:\temp\esxi_replication_key"
        
        # KORREKTUR: Erstellt jetzt einen ECDSA-Schlüssel und kopiert die Dateien an die richtigen Orte.
        $batFileContent = @"
@echo off
cls
echo.
echo ====================================================================
echo == GhettoGUI - SSH Key Setup Skript (Teil 1: Ihr PC) ==
echo ====================================================================
echo.
echo --- SCHRITT A: Korrekten ECDSA-Schluessel auf diesem PC erstellen ---
echo    (Wenn nach einer Passphrase gefragt wird, einfach Enter druecken fuer keine)
ssh-keygen -t ecdsa -f "$keyFile"
IF %ERRORLEVEL% NEQ 0 (
    echo. & echo FEHLER: ssh-keygen fehlgeschlagen. Ist der OpenSSH-Client installiert? & pause & exit /b
)
echo. & echo -> ECDSA-Schluesselpaar erfolgreich in C:\temp erstellt. & echo.

echo.
echo --- SCHRITT B: Schluessel auf ESXi-Hosts kopieren ---
echo.
echo -> Kopiere oeffentlichen Schluessel auf ZIEL-HOST ($targetIp)...
echo    ==> Bitte gib jetzt das root-Passwort fuer $targetIp ein:
scp -o "StrictHostKeyChecking=no" `"$keyFile`.pub`" root@$targetIp`:/etc/ssh/keys-root/authorized_keys
IF %ERRORLEVEL% NEQ 0 (
    echo. & echo FEHLER: Kopiervorgang zum Ziel-Host fehlgeschlagen. Passwort falsch? & pause & exit /b
)
echo.
echo -> Kopiere privaten Schluessel auf QUELL-HOST ($sourceIp)...
echo    ==> Bitte gib jetzt das root-Passwort fuer $sourceIp ein:
scp -o "StrictHostKeyChecking=no" `"$keyFile`" root@$sourceIp`:/.ssh/id_ecdsa
IF %ERRORLEVEL% NEQ 0 (
    echo. & echo FEHLER: Kopiervorgang zum Quell-Host fehlgeschlagen. Passwort falsch oder Ordner /.ssh fehlt? & pause & exit /b
)
echo.
echo --------------------------------------------------------------------
echo.
echo ERFOLG! Alle Dateien erfolgreich uebertragen!
echo.
echo Der naechste Schritt ist, im GhettoGUI auf Button 2 zu klicken,
echo um die Berechtigungen auf den Hosts zu setzen.
echo.
echo Druecken Sie eine beliebige Taste, um dieses Fenster zu schliessen...
pause > nul
"@
        $batFilePath = "C:\temp\setup_keys.bat"
        Set-Content -Path $batFilePath -Value $batFileContent -Encoding Oem
        Start-Process -FilePath $batFilePath
        Write-ConsoleLog $sourceConsoleOutput " -> Setup-Skript '$batFilePath' erstellt und gestartet."
        Write-ConsoleLog $sourceConsoleOutput " -> Bitte folge den Anweisungen im neuen schwarzen Konsolen-Fenster."

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

    Write-ConsoleLog $sourceConsoleOutput "---" ([System.Drawing.Color]::Gray)
    Write-ConsoleLog $sourceConsoleOutput "Führe finalen Verbindungstest von Quelle zu Ziel aus..." ([System.Drawing.Color]::Yellow)

    # KORREKTUR: Der ssh-Befehl verwendet jetzt den korrekten Pfad und Schlüsseltyp: /.ssh/id_ecdsa
    $testCmd = "ssh -i /.ssh/id_ecdsa -o 'StrictHostKeyChecking=no' root@$targetIp `"echo 'ERFOLG! Die Host-zu-Host Verbindung steht!'`""
    
    Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $testCmd -outputBox $sourceConsoleOutput
})

# =====================================================================================
# --- START OF BLOCK TO COPY (Kill-Button V8 - The Atom Bomb) ---
# =====================================================================================
$buttonKillOrphans.Add_Click({
    Write-ConsoleLog $sourceConsoleOutput "--- Suche und beende verwaiste Replikations-Prozesse (One-Liner Methode) ---" ([System.Drawing.Color]::Yellow)
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) {
        Write-ConsoleLog $sourceConsoleOutput "FEHLER: Keine Verbindung zum Quell-Host." ([System.Drawing.Color]::Red)
        return
    }

    try {
        # Zuerst anzeigen, was wir finden
        $findCmd = "ps -c | grep '[m]aster_replication'"
        $findResult = Invoke-SSHCommand -SSHSession $Global:sourceConsoleSession -Command $findCmd
        if ($findResult.ExitStatus -eq 0 -and $findResult.Output) {
            Write-ConsoleLog $sourceConsoleOutput "Gefundene Prozesse, die beendet werden:" ([System.Drawing.Color]::Cyan)
            $findResult.Output | ForEach-Object { Write-ConsoleLog $sourceConsoleOutput "  $_" ([System.Drawing.Color]::Cyan) }
        } else {
            Write-ConsoleLog $sourceConsoleOutput "Keine laufenden 'master_replication'-Prozesse gefunden." ([System.Drawing.Color]::LawnGreen)
            # Trotzdem versuchen, die Dateien zu löschen
        }

        # Der atomare Kill-Befehl
        $killCmd = "ps -c | grep '[m]aster_replication' | awk '{print \$1}' | xargs kill -9"
        Invoke-SSHCommand -SSHSession $Global:sourceConsoleSession -Command $killCmd | Out-Null
        
        Write-ConsoleLog $sourceConsoleOutput "Kill-Befehl gesendet. Prüfe Ergebnis in 1 Sekunde..."
        Start-Sleep -Seconds 1

        # Erneute Suche, um zu verifizieren
        $checkResult = Invoke-SSHCommand -SSHSession $Global:sourceConsoleSession -Command $findCmd
        if (-not $checkResult.Output) {
            Write-ConsoleLog $sourceConsoleOutput "Alle Prozesse erfolgreich beendet." ([System.Drawing.Color]::LawnGreen)
        } else {
            Write-ConsoleLog $sourceConsoleOutput "FEHLER: Einige Prozesse laufen immer noch:" ([System.Drawing.Color]::Red)
            $checkResult.Output | ForEach-Object { Write-ConsoleLog $sourceConsoleOutput "  $_" ([System.Drawing.Color]::Red) }
        }
        
        # Finale Aufräumarbeiten
        Write-ConsoleLog $sourceConsoleOutput "--- Räume temporäre Skript-Dateien in /tmp auf ---" ([System.Drawing.Color]::Yellow)
        $cleanupCmd = "rm -f /tmp/master_replication_*; rm -f /tmp/launcher_*; rm -f /tmp/ghetto_pipe_error_*"
        Invoke-SSHCommand -SSHSession $Global:sourceConsoleSession -Command $cleanupCmd | Out-Null
        Write-ConsoleLog $sourceConsoleOutput "Temporäre Skript- und Log-Dateien gelöscht."

    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
    }
})

# =====================================================================================
# --- END SSH-Konsole
# =====================================================================================



### EVENT HANDLER ###

$connectButton.Add_Click({
    Write-GuiLog "Verbindungsaufbau zu $($textboxIp.Text)..."
    if (Ensure-PoshSshModule) { # Prüft/installiert Posh-SSH, bevor es weitergeht
        try {
            $ErrorActionPreference = "Stop"
            if ($Global:ESXiSession -and $Global:ESXiSession.Connected) { Write-GuiLog "Bereits eine aktive Verbindung vorhanden."; return }
            $hostnameFromTextbox = $textboxIp.Text
            if (-not $hostnameFromTextbox) { Write-GuiLog "Fehler: Host IP erforderlich."; return }
            $username = $textboxUser.Text
            if (-not $username) { Write-GuiLog "Fehler: Benutzername erforderlich."; return }
            $localCredential = Show-CredentialPrompt -UserName $username -Message "Passwort für $username@$hostnameFromTextbox eingeben:"
			
			if (-not $localCredential) { Write-GuiLog "Passworteingabe abgebrochen."; return }
            $Global:ESXiSshCredential = $localCredential
            $Global:ESXiConnectedHostName = $hostnameFromTextbox

            $Global:ESXiSession = New-SSHSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -ErrorAction Stop -AcceptKey -ConnectionTimeout 60

            if ($Global:ESXiSession.Connected) {
                Write-GuiLog "Erfolgreich verbunden mit $($Global:ESXiConnectedHostName)!"
                
				Write-GuiLog "Lade Netzwerk-Interfaces..."
                $nicsResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network nic list"
                if($nicsResult.Output) {
                    $nics = $nicsResult.Output | Select-String -Pattern '^vmnic' | ForEach-Object { ($_ -split '\s+')[0] }
                    $comboVmnic.Items.Clear()
                    $comboVmnic.Items.AddRange($nics)
                    if ($comboVmnic.Items.Count -gt 0) {
                        $comboVmnic.SelectedIndex = 0
                    }
                    Write-GuiLog "$($nics.Count) Netzwerk-Interfaces gefunden."
                }
				
				$connectButton.Enabled = $false; $disconnectButton.Enabled = $true; $buttonLoadGuiSettings.Enabled = $true; $buttonSaveGuiSettings.Enabled = $true
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
        $buttonLoadGuiSettings.Enabled = $false
        $buttonSaveGuiSettings.Enabled = $false

$comboVmnic.Items.Clear(); $textTrafficStats.Clear()

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

$buttonSaveLocalReplJob.Add_Click({
    $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveFileDialog.Title = "Lokalen Klon-Job speichern unter..."
    $saveFileDialog.Filter = "GhettoGUI Jobs (*.json)|*.json"
    $saveFileDialog.InitialDirectory = $Global:ScriptPath
    $saveFileDialog.FileName = "$($Global:ESXiConnectedHostName)-Job-LocalClone.json"
    if ($saveFileDialog.ShowDialog($form) -eq 'OK') {
        Save-HostGuiSettings -FilePath $saveFileDialog.FileName
    }
})

# -------------------------------------------------------------------------------------
#  -  Start RESTORE
# -------------------------------------------------------------------------------------

# --- Definition des Restore/Klon-Fensters (NEUE VERSION) ---
$restoreForm = New-Object System.Windows.Forms.Form
$restoreForm.Text = "VM Wiederherstellungs- & Klon-Assistent"
$restoreForm.Size = New-Object System.Drawing.Size(550, 510) # Höhe angepasst
$restoreForm.StartPosition = "CenterParent"
$restoreForm.FormBorderStyle = 'FixedDialog'
$restoreForm.MaximizeBox = $false
$restoreForm.MinimizeBox = $false

$restoreCurrentY = 20

# --- Auswahl des Modus (Restore vs. Klon) ---
$groupRestoreMode = New-Object System.Windows.Forms.GroupBox; $groupRestoreMode.Text = "Aktion auswählen"; $groupRestoreMode.Location = New-Object System.Drawing.Point(20, $restoreCurrentY); $groupRestoreMode.Size = New-Object System.Drawing.Size(500, 80)
$radioRestoreFromBackup = New-Object System.Windows.Forms.RadioButton; $radioRestoreFromBackup.Text = "VM aus einem bestehenden Backup-Ordner wiederherstellen (Kalt-Restore)"; $radioRestoreFromBackup.Location = New-Object System.Drawing.Point(15, 25); $radioRestoreFromBackup.AutoSize = $true; $radioRestoreFromBackup.Checked = $true
$radioCloneFromVm = New-Object System.Windows.Forms.RadioButton; $radioCloneFromVm.Text = "Laufende VM als neue VM klonen (Heiss-Klon)"; $radioCloneFromVm.Location = New-Object System.Drawing.Point(15, 50); $radioCloneFromVm.AutoSize = $true
$groupRestoreMode.Controls.AddRange(@($radioRestoreFromBackup, $radioCloneFromVm))
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
$buttonStartRestore = New-Object System.Windows.Forms.Button; $buttonStartRestore.Text = "Starten"; $buttonStartRestore.Location = New-Object System.Drawing.Point(230, $restoreCurrentY); $buttonStartRestore.Size = New-Object System.Drawing.Size(170, 25); $buttonStartRestore.DialogResult = [System.Windows.Forms.DialogResult]::OK
$buttonCancelRestore = New-Object System.Windows.Forms.Button; $buttonCancelRestore.Text = "Abbrechen"; $buttonCancelRestore.Location = New-Object System.Drawing.Point(410, $restoreCurrentY); $buttonCancelRestore.Size = New-Object System.Drawing.Size(100, 25); $buttonCancelRestore.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$restoreForm.Controls.AddRange(@($labelRestoreSource, $textboxRestoreSourcePath, $buttonBrowseRestoreSource, $labelRestoreTargetDs, $textboxRestoreTargetPath, $buttonBrowseRestoreTarget, $labelRestoreNewVmName, $textboxRestoreNewVmName, $groupRestoreOptions, $buttonStartRestore, $buttonCancelRestore))
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



# --- NEU: Shell-Skript-Vorlage für den HEISS-KLON (Version 7, Finale Klon-Fixes) ---
$cloneScriptTemplate = @'
#!/bin/sh
# GhettoGUI Multi-VM Clone Helper V46.0 (Final Clone Fixes)
# - FIX: Copies only necessary files (.vmx, .nvram, .vmsd), ignoring locked .vswp/.lck files.
# - FIX: No longer removes the ethernet*.generatedAddress line from the .vmx file, which resolves the power-on error.
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin
export PATH

set -e
# Parameter
SOURCE_VM_NAME='__SOURCE_VM_NAME__'
TARGET_DATASTORE='__TARGET_DATASTORE__'
NEW_VM_NAME='__NEW_VM_NAME__'
POWER_ON=__POWER_ON__
UUID_ACTION='__UUID_ACTION__'
UNIQUE_ID='__UNIQUE_ID__'
LOG_FILE="/tmp/ghetto_clone_${UNIQUE_ID}.log"
# E-Mail Parameter
GHETTO_PATH='__GHETTO_PATH__'
EMAIL_ENABLED=__EMAIL_ENABLED__
EMAIL_TO='__EMAIL_TO__'
EMAIL_FROM='__EMAIL_FROM__'
EMAIL_SERVER='__EMAIL_SERVER__'
EMAIL_PORT='__EMAIL_PORT__'
EMAIL_USER='__EMAIL_USER__'
EMAIL_PASS='__EMAIL_PASS__'
EMAIL_SUBJECT='__EMAIL_SUBJECT__'
SENDMAIL_PATH="${GHETTO_PATH}/sendmail"
OVERALL_STATUS="ERROR"

# --- Variablen für den Klon-Prozess ---
SNAPSHOT_NAME="ghetto-clone-${UNIQUE_ID}"
VMID=""

# --- Logging und E-Mail Funktionen ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- INFO: $1" >> ${LOG_FILE}; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; }
log_raw() { echo "$1" >> ${LOG_FILE}; }
log_warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARN: $1" >> ${LOG_FILE}; }

send_email_notification() {
    DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi
    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: Klonen ERFOLGREICH! ##"; else FINAL_STATUS_MSG="## Final status: FEHLER: Klonen fehlgeschlagen! ##"; fi
    log "Bereite E-Mail vor: ${OVERALL_STATUS}";
    log_raw "Clone Duration: ${DURATION_MSG}";
    log_raw "${FINAL_STATUS_MSG}";
    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/,/ /g');
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1;
    fi;
}

cleanup() {
    EXIT_CODE=$?
    log "Starte Cleanup-Routine..."
    if [ -n "${VMID}" ]; then
        if vim-cmd vmsvc/snapshot.get ${VMID} 2>/dev/null | grep -q "${SNAPSHOT_NAME}"; then
            log "Entferne Snapshot '${SNAPSHOT_NAME}' von Quell-VM..."
            vim-cmd vmsvc/snapshot.removeall ${VMID} > /dev/null 2>&1 || log_warn "Konnte Snapshot nicht automatisch entfernen."
        fi
    fi

    log_raw "--- ENDE DES DETAILLOGS ---"
    END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S')
    log_raw "Endzeit: ${END_TIME_S}"
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden"
    if [ ${EXIT_CODE} -ne 0 ] && [ "${OVERALL_STATUS}" != "OK" ]; then log_error "Skript wurde unerwartet beendet. Status bleibt 'ERROR'."; fi;
    send_email_notification "${DURATION_STRING}";
    log "====== VM KLON-PROZESS BEENDET (ID: ${UNIQUE_ID}) ======";
}

# --- Skriptstart ---
START_TIME=$(date +%s)
trap cleanup EXIT

log "====== VM KLON-PROZESS GESTARTET (GhettoVCB-Methode / ID: ${UNIQUE_ID}) ======"
# ... (log job config)

# Schritt 1: Finde die Quell-VM und ihre Pfade
log "[1/6] Suche Quell-VM '${SOURCE_VM_NAME}'..."
VM_INFO_LINE=$(vim-cmd vmsvc/getallvms | grep -v 'invalid' | awk -v name="${SOURCE_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $0; }')
if [ -z "${VM_INFO_LINE}" ]; then log_error "Quell-VM '${SOURCE_VM_NAME}' nicht gefunden!"; exit 1; fi
VMID=$(echo "${VM_INFO_LINE}" | awk '{print $1}')
VMX_FULL_PATH=$(echo "${VM_INFO_LINE}" | awk '{ for(i=1; i<=NF; i++) { if ($i ~ /\.vmx$/) { gsub(/\[|\]/,"",$(i-1)); print "/vmfs/volumes/"$(i-1)"/"$i } } }')
VMX_DIR=$(dirname "${VMX_FULL_PATH}")
log "  -> VMID gefunden: ${VMID}"
log "  -> VM-Pfad: ${VMX_DIR}"
# ... (log storage space)
log_raw "--- START DES DETAILLOGS ---"

# Schritt 2: Zielverzeichnis erstellen
TARGET_VM_PATH="${TARGET_DATASTORE}/${NEW_VM_NAME}"
log "[2/6] Erstelle Zielverzeichnis: ${TARGET_VM_PATH}"
rm -rf "${TARGET_VM_PATH}"
mkdir -p "${TARGET_VM_PATH}"

# Schritt 3: Snapshot erstellen UND darauf warten
log "[3/6] Erstelle Snapshot '${SNAPSHOT_NAME}' für die laufende VM..."
vim-cmd vmsvc/snapshot.create ${VMID} "${SNAPSHOT_NAME}" "GhettoGUI Live Clone" 0 0
log "  -> Snapshot-Befehl gesendet. Warte jetzt aktiv, bis der Snapshot im System sichtbar ist..."
ATTEMPTS=0
MAX_ATTEMPTS=24
SNAPSHOT_VISIBLE=0
while [ ${ATTEMPTS} -lt ${MAX_ATTEMPTS} ]; do
    if vim-cmd vmsvc/snapshot.get ${VMID} | grep -q "${SNAPSHOT_NAME}"; then
        log "  -> Snapshot ist nach $((ATTEMPTS * 5)) Sekunden sichtbar."
        SNAPSHOT_VISIBLE=1
        break
    fi
    sleep 5
    ATTEMPTS=$((ATTEMPTS + 1))
done

if [ ${SNAPSHOT_VISIBLE} -eq 0 ]; then
    log_error "Snapshot wurde nach ${MAX_ATTEMPTS} Versuchen nicht im System sichtbar. Breche ab."
    exit 1
fi

log "  -> Gebe dem Storage-System 15 Sekunden extra Zeit, um die Dateisperren zu stabilisieren..."
sleep 15

# Schritt 4: Klone die BASIS-Festplatten direkt zum Zielort
log "[4/6] Klone BASIS-Festplatten direkt zum Zielort (mit %-Anzeige)..."
DISK_DEFINITIONS=$(grep -iE '(\.vmdk)' "${VMX_FULL_PATH}" | grep -iE '(^scsi|^ide|^sata|^nvme)')
OLD_IFS=$IFS; IFS='
'; for line in ${DISK_DEFINITIONS}; do
    IFS=$OLD_IFS;
    DISK_FILE_NAME=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p')
    if [ -z "${DISK_FILE_NAME}" ]; then continue; fi
    
    BASE_DISK_NAME=$(basename "${DISK_FILE_NAME}" | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/')
    SOURCE_DISK_PATH="${VMX_DIR}/${BASE_DISK_NAME}"
    DESTINATION_DISK_PATH="${TARGET_VM_PATH}/${BASE_DISK_NAME}"

    log "  -> Klone Festplatte: ${SOURCE_DISK_PATH} nach ${DESTINATION_DISK_PATH}"
    if ! vmkfstools -i "${SOURCE_DISK_PATH}" -d thin "${DESTINATION_DISK_PATH}" >> ${LOG_FILE} 2>&1; then
        log_error "Klonen von Festplatte ${BASE_DISK_NAME} fehlgeschlagen!"
        exit 1
    fi
    log "  -> Klonen der Festplatte ${BASE_DISK_NAME} erfolgreich."
IFS='
'; done; IFS=$OLD_IFS

# Schritt 5: Kopiere restliche VM-Dateien und passe sie an
log "[5/6] Kopiere und passe Konfigurationsdateien an..."
# KORREKTUR: Kopiere nur die benötigten Dateien und ignoriere gesperrte Systemdateien
(cd "${VMX_DIR}" && find . -maxdepth 1 \( -name "*.vmx" -o -name "*.nvram" -o -name "*.vmsd" \) -exec cp -p '{}' "${TARGET_VM_PATH}/" \;)
(
cd "${TARGET_VM_PATH}"
ORIG_VMX_FILE=$(find . -maxdepth 1 -name "*.vmx")
ORIG_BASENAME=$(basename "${ORIG_VMX_FILE}" .vmx)
if [ "${ORIG_BASENAME}" != "${NEW_VM_NAME}" ]; then
    log "  -> Benenne Dateien um von '${ORIG_BASENAME}' zu '${NEW_VM_NAME}'..."
    for f in "${ORIG_BASENAME}".*; do
        new_name=$(echo "$f" | sed "s/^${ORIG_BASENAME}/${NEW_VM_NAME}/")
        mv -- "$f" "$new_name"
    done
fi
NEW_VMX_FILE="./${NEW_VM_NAME}.vmx"
log "  -> Passe Inhalt der VMX-Datei an..."
sed -i 's/-[0-9]\{6\}\.vmdk/\.vmdk/g' "${NEW_VMX_FILE}"
sed -i "s/displayName = .*/displayName = \"${NEW_VM_NAME}\"/" "${NEW_VMX_FILE}"
sed -i "s/${ORIG_BASENAME}\.vmdk/${NEW_VM_NAME}\.vmdk/g" "${NEW_VMX_FILE}"
sed -i "s/${ORIG_BASENAME}\.nvram/${NEW_VM_NAME}\.nvram/g" "${NEW_VMX_FILE}"
sed -i '/sched.swap.derivedName/d' "${NEW_VMX_FILE}"
sed -i '/uuid.location/d' "${NEW_VMX_FILE}"
sed -i '/uuid.bios/d' "${NEW_VMX_FILE}"
sed -i '/vc.uuid/d' "${NEW_VMX_FILE}"
# KORREKTUR: Diese Zeile, die die MAC-Adresse entfernt, wird gelöscht
# sed -i '/ethernet[0-9]*.generatedAddress/d' "${NEW_VMX_FILE}"
log "  -> Setze 'uuid.action = ${UUID_ACTION}'"
echo "uuid.action = \"${UUID_ACTION}\"" >> "${NEW_VMX_FILE}"
)

# Schritt 6: Registriere den Klon
log "[6/6] Registriere neue VM '${NEW_VM_NAME}'..."
REGISTER_OUTPUT=$(vim-cmd solo/registervm "${TARGET_VM_PATH}/${NEW_VM_NAME}.vmx")
NEW_VMID_CLONE=$(echo "${REGISTER_OUTPUT}")
log "  -> Klon erfolgreich registriert mit VMID: ${NEW_VMID_CLONE}"

if [ "${POWER_ON}" = "1" ]; then
    log "Schalte geklonte VM ein..."
    vim-cmd vmsvc/power.on "${NEW_VMID_CLONE}"
fi
# ... (log storage space after)
OVERALL_STATUS="OK"
log "====== KLONEN ERFOLGREICH ABGESCHLOSSEN ======"
'@

# --- FINALE Shell-Skript-Vorlage für den LOKALEN HOT-KLON (V1.8 - Final) ---

$localReplicationScriptTemplate = @'
#!/bin/sh
# GhettoGUI Multi-VM Local Hot-Clone Helper V4.3 (Final Log Fix)
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin
export PATH
set -e
# Parameter
UNIQUE_ID='__UNIQUE_ID__'; TARGET_DATASTORE='__TARGET_DATASTORE__'; VM_SUFFIX='__VM_SUFFIX__'; GHETTO_PATH='__GHETTO_PATH__'; LOG_FILE="${GHETTO_PATH}/logs/local_clone_${UNIQUE_ID}.log"; SNAP_MEM=__SNAP_MEM__; SNAP_QUIESCE=__SNAP_QUIESCE__; EMAIL_ENABLED=__EMAIL_ENABLED__; EMAIL_TO='__EMAIL_TO__'; EMAIL_FROM='__EMAIL_FROM__'; EMAIL_SERVER='__EMAIL_SERVER__'; EMAIL_PORT='__EMAIL_PORT__'; EMAIL_USER='__EMAIL_USER__'; EMAIL_PASS='__EMAIL_PASS__'; EMAIL_SUBJECT='__EMAIL_SUBJECT__'; SENDMAIL_PATH="${GHETTO_PATH}/sendmail"; VM_LIST='
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
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1; 
    fi; 
}

# Funktion für den erfolgreichen Abschluss
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

# Funktion nur für den Fehlerfall (Notfall-Cleanup)
error_cleanup() { 
    trap - EXIT
    OVERALL_STATUS="ERROR"
    # FIX: Die störende Warn-Meldung wurde entfernt.
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
    echo "${DISK_DEFINITIONS}" | while read -r line; do BASE_DISK_FILE=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p' | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/'); SOURCE_DISK_PATH="${VMX_DIR}/${BASE_DISK_FILE}"; DESTINATION_DISK_PATH="${TARGET_VM_PATH}/${BASE_DISK_FILE}"; log "  -> Klone Festplatte: ${BASE_DISK_FILE}..."; vmkfstools -i "${SOURCE_DISK_PATH}" -d thin "${DESTINATION_DISK_PATH}" > /dev/null 2>&1 & VMKF_PID=$!; while kill -0 ${VMKF_PID} >/dev/null 2>&1; do CURRENT_SIZE=$(du -sh "${TARGET_VM_PATH}" | awk '{print $1}'); log "-> Transfer: ${CURRENT_SIZE} von ~${SOURCE_SIZE}"; sleep 15; done; wait ${VMKF_PID}; log "  -> Klon von ${BASE_DISK_FILE} abgeschlossen."; done
    
    log "[4/5] Kopiere & passe Konfigurationsdateien an..."; 
    (cd "${VMX_DIR}" && find . -maxdepth 1 \( -name "*.vmx" -o -name "*.nvram" -o -name "*.vmsd" \) -exec cp -p '{}' "${TARGET_VM_PATH}/" \;)

    cd "${TARGET_VM_PATH}"; ORIG_VMX_FILE=$(find . -maxdepth 1 -name "*.vmx"); RENAMED_VMX_FILE="./${CLONED_VM_NAME}.vmx"; mv "${ORIG_VMX_FILE}" "${RENAMED_VMX_FILE}";
    log "  -> Passe VMX-Inhalt an (Aktion: ${UUID_ACTION})..."; sed -i "s/displayName = .*/displayName = \"${CLONED_VM_NAME}\"/" "${RENAMED_VMX_FILE}"; sed -i 's/-[0-9]\{6\}\.vmdk/\.vmdk/g' "${RENAMED_VMX_FILE}"; sed -i "/sched\.swap\.derivedName/d" "${RENAMED_VMX_FILE}"; if [ "${UUID_ACTION}" = "create" ]; then log "    -> Entferne UUIDs und MAC-Adresse für neue Identität."; sed -i "/^uuid\./d" "${RENAMED_VMX_FILE}"; sed -i "/^ethernet[0-9]*.generatedAddress/d" "${RENAMED_VMX_FILE}"; sed -i "/^ethernet[0-9]*.addressType/d" "${RENAMED_VMX_FILE}"; else log "    -> Setze 'uuid.action = keep' zur Beibehaltung der Identität."; sed -i "/^uuid\./d" "${RENAMED_VMX_FILE}"; echo "uuid.action = \"keep\"" >> "${RENAMED_VMX_FILE}"; fi
    log "[5/5] Registriere Klon & entferne Snapshot..."; vim-cmd solo/registervm "${TARGET_VM_PATH}/${RENAMED_VMX_FILE}"; vim-cmd vmsvc/snapshot.removeall ${VMID}; log "-> Klon für ${SOURCE_VM_NAME} erfolgreich abgeschlossen."
done

if [ "${OVERALL_STATUS}" = "OK" ]; then
    finish_job
fi
'@

# --- Shell-Skript-Vorlage für den KALT-RESTORE ---

$restoreScriptTemplate = @'
#!/bin/sh
set -e
# Parameter
SOURCE_PATH='__SOURCE_PATH__'
TARGET_DATASTORE='__TARGET_DATASTORE__'
NEW_VM_NAME='__NEW_VM_NAME__'
POWER_ON=__POWER_ON__
UUID_ACTION='__UUID_ACTION__'
UNIQUE_ID='__UNIQUE_ID__'
LOG_FILE="/tmp/ghetto_restore_${UNIQUE_ID}.log"
GHETTO_PATH='__GHETTO_PATH__'
EMAIL_ENABLED=__EMAIL_ENABLED__
EMAIL_TO='__EMAIL_TO__'
EMAIL_FROM='__EMAIL_FROM__'
EMAIL_SERVER='__EMAIL_SERVER__'
EMAIL_PORT='__EMAIL_PORT__'
EMAIL_USER='__EMAIL_USER__'
EMAIL_PASS='__EMAIL_PASS__'
EMAIL_SUBJECT='__EMAIL_SUBJECT__'
SENDMAIL_PATH="${GHETTO_PATH}/sendmail"
OVERALL_STATUS="ERROR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -INFO: $1" >> ${LOG_FILE}; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; }
log_raw() { echo "$1" >> ${LOG_FILE}; }

send_email_notification() {
    DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi
    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: Wiederherstellung ERFOLGREICH! ##"; else FINAL_STATUS_MSG="## Final status: FEHLER: Wiederherstellung fehlgeschlagen! ##"; fi
    log "Bereite E-Mail vor: ${OVERALL_STATUS}";
    log_raw "Backup Duration: ${DURATION_MSG}";
    log_raw "${FINAL_STATUS_MSG}";
    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/,/ /g');
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1;
    fi;
}

cleanup() {
    EXIT_CODE=$?
    log_raw "--- ENDE DES DETAILLOGS ---"
    END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S')
    log_raw "Endzeit: ${END_TIME_S}"
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden"
    if [ ${EXIT_CODE} -ne 0 ] && [ "${OVERALL_STATUS}" != "OK" ]; then log_error "Skript wurde unerwartet beendet. Status bleibt 'ERROR'."; fi;
    send_email_notification "${DURATION_STRING}";
    log "====== VM RESTORE-PROZESS BEENDET (ID: ${UNIQUE_ID}) ======";
}

# --- Skriptstart ---
START_TIME=$(date +%s)
trap cleanup EXIT

log "====== VM RESTORE-PROZESS GESTARTET (ID: ${UNIQUE_ID}) ======"
log_raw "Startzeit: $(date '+%Y-%m-%d %H:%M:%S')"
log_raw "Job-Konfiguration:"
log_raw "  - Typ: GhettoVCB Wiederherstellung"
log_raw "  - Quelle: ${SOURCE_PATH}"
log_raw "  - Ziel-Datastore: ${TARGET_DATASTORE}"
log_raw "  - Neuer VM-Name: ${NEW_VM_NAME}"
log_raw "  - UUID-Aktion: ${UUID_ACTION}"

log_raw "Speicherplatz (Vorher):"
log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h '${TARGET_DATASTORE}' 2>/dev/null | tail -n 1)"
log_raw "--- START DES DETAILLOGS ---"

# Schritt 1: Zielverzeichnis erstellen
TARGET_VM_PATH="${TARGET_DATASTORE}/${NEW_VM_NAME}"
log "[1/5] Erstelle Zielverzeichnis: ${TARGET_VM_PATH}"
log "  -> (DEBUG) Lösche altes Verzeichnis (falls vorhanden)..."
rm -rf "${TARGET_VM_PATH}"
log "  -> (DEBUG) Erstelle neues, leeres Verzeichnis..."
mkdir -p "${TARGET_VM_PATH}"
log "  -> (DEBUG) Zielverzeichnis ist bereit."

# Finde den eigentlichen Backup-Ordner
log "  -> (DEBUG) Prüfe Quellpfad auf Unterverzeichnisse..."
ACTUAL_SOURCE_PATH="${SOURCE_PATH}"
SUBFOLDER_COUNT=$(find "${SOURCE_PATH}" -maxdepth 1 -mindepth 1 -type d | wc -l)
log "  -> (DEBUG) ${SUBFOLDER_COUNT} Unterverzeichnis(se) gefunden."
if [ "${SUBFOLDER_COUNT}" -eq 1 ]; then
    ACTUAL_SOURCE_PATH=$(find "${SOURCE_PATH}" -maxdepth 1 -mindepth 1 -type d)
    log "  -> Einzelner Backup-Unterordner gefunden, passe Quellpfad an auf: ${ACTUAL_SOURCE_PATH}"
fi
log "  -> (DEBUG) Finaler Quellpfad: ${ACTUAL_SOURCE_PATH}"

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
    vim-cmd vmsvc/power.on "${NEW_VMID}"
    log "  -> Einschalt-Befehl gesendet."
else
    log "[5/5] VM wird nicht automatisch eingeschaltet."
fi

log_raw "Speicherplatz (Nachher):"
log_raw "  - Ziel (${TARGET_DATASTORE}): $(df -h '${TARGET_DATASTORE}' 2>/dev/null | tail -n 1)"

OVERALL_STATUS="OK"
log "====== WIEDERHERSTELLUNG ERFOLGREICH ABGESCHLOSSEN ======"
'@

# --- Logik für den "Restore / Klonen"-Button ---

$buttonRestore.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem ESXi-Host verbinden.", "Fehler", "OK", "Warning"); return
    }
    
    # Setze das Formular auf den Standardzustand zurück
    $radioRestoreFromBackup.Checked = $true
    $textboxRestoreSourcePath.Text = ""
    $textboxRestoreTargetPath.Text = ""
    $textboxRestoreNewVmName.Text = ""
    $radioRestoreMoved.Checked = $true
    $checkboxPowerOnAfterRestore.Checked = $false

    # Öffnet das Restore/Klon-Fenster
    $restoreResult = $restoreForm.ShowDialog($form)
    
    if ($restoreResult -eq [System.Windows.Forms.DialogResult]::OK) {

        # Unterscheide zwischen den beiden Modi
        if ($radioRestoreFromBackup.Checked) {
            # --- MODUS: RESTORE AUS BACKUP ---
            $params = @{
                SOURCE_PATH      = $textboxRestoreSourcePath.Text
                TARGET_DATASTORE = $textboxRestoreTargetPath.Text
                NEW_VM_NAME       = $textboxRestoreNewVmName.Text
                POWER_ON         = if ($checkboxPowerOnAfterRestore.Checked) { 1 } else { 0 }
                UUID_ACTION      = if ($radioRestoreMoved.Checked) { "keep" } else { "create" }
                UNIQUE_ID        = "{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Minimum 100 -Maximum 999)
                GHETTO_PATH      = $textboxGhettoPath.Text
                EMAIL_ENABLED    = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EMAIL_TO = $textboxEmailTo.Text; EMAIL_FROM = $textboxEmailFrom.Text; EMAIL_SERVER = $textboxEmailServer.Text; EMAIL_PORT = $textboxEmailPort.Text; EMAIL_USER = $textboxEmailUser.Text; EMAIL_PASS = $textboxEmailPassword.Text
                EMAIL_SUBJECT    = "[Restore] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName)
            }
            $Global:currentJobTargetName = $params.NEW_VM_NAME
            $Global:currentJobType = "Wiederherstellung"
            $confirmMessage = "Bist Du sicher, dass Du die Wiederherstellung starten möchtest?`n`n- Quelle: $($params.SOURCE_PATH)`n- Ziel: $($params.TARGET_DATASTORE)`n- Neuer Name: $($params.NEW_VM_NAME)"
            $finalScriptTemplate = $restoreScriptTemplate
            $watcherName = "GhettoRestoreWatcher"
            $logPrefix = "ghetto_restore"
            
        } else {
            # --- MODUS: KLONEN VON LAUFENDER VM ---
            $params = @{
                SOURCE_VM_NAME    = $textboxRestoreSourcePath.Text
                TARGET_DATASTORE = $textboxRestoreTargetPath.Text
                NEW_VM_NAME       = $textboxRestoreNewVmName.Text
                POWER_ON         = if ($checkboxPowerOnAfterRestore.Checked) { 1 } else { 0 }
                UUID_ACTION      = if ($radioRestoreMoved.Checked) { "keep" } else { "create" }
                UNIQUE_ID        = "{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Minimum 100 -Maximum 999)
                GHETTO_PATH      = $textboxGhettoPath.Text
                EMAIL_ENABLED    = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EMAIL_TO = $textboxEmailTo.Text; EMAIL_FROM = $textboxEmailFrom.Text; EMAIL_SERVER = $textboxEmailServer.Text; EMAIL_PORT = $textboxEmailPort.Text; EMAIL_USER = $textboxEmailUser.Text; EMAIL_PASS = $textboxEmailPassword.Text
                EMAIL_SUBJECT    = "[Klonen] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName)
            }
            $Global:currentJobTargetName = $params.NEW_VM_NAME
            $Global:currentJobType = "Klonen"
            $confirmMessage = "Bist Du sicher, dass Du den Klon-Vorgang starten möchtest?`n`n- Quell-VM: $($params.SOURCE_VM_NAME)`n- Ziel: $($params.TARGET_DATASTORE)`n- Neuer Name: $($params.NEW_VM_NAME)"
            $finalScriptTemplate = $cloneScriptTemplate
            $watcherName = "GhettoCloneWatcher"
            $logPrefix = "ghetto_clone"
        }

        # Gemeinsame Logik für beide Modi
        $confirmResult = [System.Windows.Forms.MessageBox]::Show($confirmMessage, "Vorgang bestätigen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) { Write-GuiLog "Vorgang vom Benutzer abgebrochen."; return }
        
        if (([string]::IsNullOrWhiteSpace($params.SOURCE_PATH) -and [string]::IsNullOrWhiteSpace($params.SOURCE_VM_NAME)) -or [string]::IsNullOrWhiteSpace($params.TARGET_DATASTORE) -or [string]::IsNullOrWhiteSpace($params.NEW_VM_NAME)) {
            [System.Windows.Forms.MessageBox]::Show("Bitte fülle alle Felder aus: Quelle, Ziel-Datastore und Neuer VM-Name.", "Fehlende Eingaben", "OK", "Warning"); return
        }

        # KORRIGIERTE LOGIK: Ersetze die Platzhalter im ausgewählten Skript-Template
        $finalScript = $finalScriptTemplate
        foreach ($key in $params.Keys) {
            $placeholder = "__$($key)__" # Verwende den Key direkt, ohne ToUpper()
            $finalScript = $finalScript.Replace($placeholder, $params[$key])
        }
        
        # Lade Skript hoch und starte den Job
        $remoteScriptPath = "/tmp/$($logPrefix)_$($params.UNIQUE_ID).sh"
        $launcherScriptPath = "/tmp/launcher_$($logPrefix)_$($params.UNIQUE_ID).sh"
        $remoteLogPath = "/tmp/$($logPrefix)_$($params.UNIQUE_ID).log"
        $sftpSession = $null
        try {
            $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -ConnectionTimeout 60
            Set-SFTPContent -SFTPSession $sftpSession -Path $remoteScriptPath -Value ($finalScript.Replace("`r`n", "`n"))
            Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$remoteScriptPath'"
            
            $launcherContent = "#!/bin/sh`nnohup sh '$remoteScriptPath' >> '$remoteLogPath' 2>&1 &"

            Set-SFTPContent -SFTPSession $sftpSession -Path $launcherScriptPath -Value $launcherContent
            Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$launcherScriptPath'"
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Fehler beim Hochladen des Skripts: $($_.Exception.Message)", "Upload-Fehler", "OK", "Error"); return
        } finally {
            if ($sftpSession) { Remove-SFTPSession -SftpSession $sftpSession }
        }

        Get-Job | Where-Object { $_.Name -like 'Ghetto*' } | Remove-Job -Force
        $startCommand = "sh '$launcherScriptPath'"
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $startCommand

        $watcherParams = @{
            Host = $Global:ESXiConnectedHostName; Credential = $Global:ESXiSshCredential; RemoteLogPath = $remoteLogPath
        }
        $Global:replicationJob = Start-Job -Name $watcherName -ScriptBlock { 
            param($p)
            Import-Module Posh-SSH -ErrorAction SilentlyContinue
            $watcherSession = New-SSHSession -ComputerName $p.Host -Credential $p.Credential -AcceptKey -ConnectionTimeout 60
            if (-not $watcherSession.Connected) { Write-Output "FEHLER: Watcher-Job konnte keine SSH-Verbindung herstellen."; return }
            $lastLineNumber = 0; $timeout = (Get-Date).AddHours(24)
            while ((Get-Date) -lt $timeout) {
                Start-Sleep -Seconds 3
                $checkFileCmd = "if [ -f '$($p.RemoteLogPath)' ]; then echo 'EXISTS'; fi"
                if ((Invoke-SSHCommand -SSHSession $watcherSession -Command $checkFileCmd).Output -join '' -eq 'EXISTS') {
                    $getNewLinesCmd = "tail -n +$($lastLineNumber + 1) '$($p.RemoteLogPath)'"
                    $newLinesResult = Invoke-SSHCommand -SSHSession $watcherSession -Command $getNewLinesCmd
                    if ($newLinesResult.Output) {
                        $lines = $newLinesResult.Output
                        foreach ($line in $lines) { Write-Output "$line" }
                        $lastLineNumber += $lines.Count
                        if ($lines[-1] -match "====== (VM RESTORE-PROZESS|VM KLON-PROZESS) BEENDET ======") { break }
                    }
                }
            }
            Remove-SSHSession -SSHSession $watcherSession
        } -ArgumentList $watcherParams

        $Global:replicationJobTimer.Start()
        Write-GuiLog "$($Global:currentJobType)-Prozess für '$($params.NEW_VM_NAME)' gestartet. Log wird live überwacht."
    } else {
        Write-GuiLog "Vorgang vom Benutzer abgebrochen."
    }
})

    
 # --- ENDE Klick-Event für den Haupt-Restore-Button  ---

$buttonBrowseRestoreSource.Add_Click({
    if ($radioRestoreFromBackup.Checked) {
        # --- Modus: Restore aus Backup-Ordner ---
        Write-GuiLog "Öffne Datastore-Auswahl für Backup-Quelle..."
        $currentPath = Show-DatastoreSelectionDialog
        if (-not $currentPath) { Write-GuiLog "Auswahl abgebrochen."; return }

        while ($true) {
            $dialogOutput = Show-DirectorySelectionDialog -Title "Navigiere zum Backup-Ordner" -BasePath $currentPath -SshSession $Global:ESXiSession
            
            if ($dialogOutput.Result -eq 'Yes') {
                $textboxRestoreSourcePath.Text = $currentPath
                Write-GuiLog "Backup-Quelle für Restore ausgewählt: $currentPath"
                
                $originalVmName = ($currentPath -split '/')[-1]
                $originalVmName = $originalVmName -replace '-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$',''
                $textboxRestoreNewVmName.Text = "$($originalVmName)-Restored"
                break
            }
            elseif ($dialogOutput.Result -eq 'OK') {
                $selectedItem = $dialogOutput.SelectedItem
                if ($selectedItem -eq ".. (Eine Ebene höher)") {
                    if ($currentPath.Length -gt 15) { $currentPath = Split-Path -Path $currentPath }
                } else {
                    $currentPath = "$currentPath/$selectedItem"
                }
            }
            else {
                Write-GuiLog "Backup-Auswahl abgebrochen."
                break
            }
        }
    } else {
        # --- Modus: Klon von laufender VM ---
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
    $targetDatastore = Show-DatastoreSelectionDialog
    if ($targetDatastore) {
        $textboxRestoreTargetPath.Text = $targetDatastore
        Write-GuiLog "Restore-Ziel ausgewählt: $targetDatastore"
    } else {
        Write-GuiLog "Auswahl des Ziels abgebrochen."
    }
})

# -------------------------------------------------------------------------------------
#  -  ENDE RESTORE
# -------------------------------------------------------------------------------------

$buttonLocalReplicate.Add_Click({
    if ($checkedListBoxVms.CheckedItems.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Bitte wähle mindestens eine VM für den lokalen Klon aus.", "Keine Auswahl", "OK", "Warning"); return }
# if ($Global:replicationJob -and $Global:replicationJob.State -eq 'Running') { [System.Windows.Forms.MessageBox]::Show("Es läuft bereits ein anderer Prozess. Bitte warten.", "Beschäftigt", "OK", "Warning"); return }

    # Rufe den Dialog nur einmal auf
    $dialogResult = $localReplicationForm.ShowDialog($form)
    
    # Prüfe das Ergebnis und starte dann den Job
    if ($dialogResult -ne 'OK') { 
        Write-GuiLog "Lokaler Klon vom Benutzer abgebrochen."; 
        return 
    }
    
    # Werte aus dem Dialog zwischenspeichern
    $hiddenLrTargetDs.Text = $textboxLrTargetDs.Text
    $hiddenLrSuffix.Text = $textboxLrSuffix.Text
    $hiddenLrUuidAction.Text = if ($radioKeepUuid.Checked) { 'keep' } else { 'create' }

    # Interne Funktion, die den Job tatsächlich startet
    $startLocalCloneJob = {
        Get-Job | Where-Object { $_.Name -like 'Ghetto*' } | Remove-Job -Force
        $uniqueId = "{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Minimum 100 -Maximum 999)
        $vmsToReplicate = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }) -join "`n"
        $Global:currentJobTargetName = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }) -join ", "
        $Global:currentJobType = "Lokaler Klon"
        
        $params = @{
            UNIQUE_ID         = $uniqueId; VM_LIST = $vmsToReplicate;
            TARGET_DATASTORE  = $textboxLrTargetDs.Text; VM_SUFFIX = $textboxLrSuffix.Text;
            SNAP_MEM          = if ($checkboxSnapMem.Checked) { 1 } else { 0 }; SNAP_QUIESCE = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 };
            GHETTO_PATH       = $textboxGhettoPath.Text;
            EMAIL_ENABLED     = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EMAIL_TO = $textboxEmailTo.Text;
            EMAIL_FROM        = $textboxEmailFrom.Text; EMAIL_SERVER = $textboxEmailServer.Text; EMAIL_PORT = $textboxEmailPort.Text;
            EMAIL_USER        = $textboxEmailUser.Text; EMAIL_PASS = $textboxEmailPassword.Text;
            EMAIL_SUBJECT     = "[Lokaler-Klon] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName);
            UUID_ACTION       = if ($localReplicationForm.Controls.Find('radioKeepUuid', $true)[0].Checked) { 'keep' } else { 'create' }
        }

        $finalScript = $localReplicationScriptTemplate
        foreach ($key in $params.Keys) { $finalScript = $finalScript.Replace("__$($key.ToUpper())__", $params[$key]) }
        
        $remoteScriptPath = "/tmp/local_clone_$($uniqueId).sh"
        
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
        try {
            Set-SFTPContent -SFTPSession $sftpSession -Path $remoteScriptPath -Value ($finalScript.Replace("`r`n", "`n"))
            Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$remoteScriptPath'"
        } finally {
            if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession }
        }

        $startCommand = "nohup sh '$remoteScriptPath' &"
        
        # --- HIER IST DIE KORREKTUR ---
        # Fange den erwarteten Timeout-Fehler ab
        try {
            Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $startCommand -ErrorAction Stop
        } catch [System.Management.Automation.MethodInvocationException] {
            Write-GuiLog "-> INFO: Erwarteter Posh-SSH-Timeout. Das ist normal für Hintergrundprozesse."
        }
        # --- ENDE DER KORREKTUR ---

        $watcherParams = @{
            Host = $Global:ESXiConnectedHostName; Credential = $Global:ESXiSshCredential; RemoteLogPath = "$($params.GHETTO_PATH)/logs/local_clone_$($uniqueId).log"
        }
        $Global:replicationJob = Start-Job -Name 'GhettoCloneWatcher' -ScriptBlock { 
            param($p)
            Import-Module Posh-SSH -ErrorAction SilentlyContinue
            $watcherSession = New-SSHSession -ComputerName $p.Host -Credential $p.Credential -AcceptKey -ConnectionTimeout 60
            if (-not $watcherSession.Connected) { Write-Output "FEHLER: Watcher-Job konnte keine SSH-Verbindung herstellen."; return }
            $lastLineNumber = 0; $timeout = (Get-Date).AddHours(24)
            while ((Get-Date) -lt $timeout) {
                Start-Sleep -Seconds 4
                $checkFileCmd = "if [ -f '$($p.RemoteLogPath)' ]; then echo 'EXISTS'; fi"
                if ((Invoke-SSHCommand -SSHSession $watcherSession -Command $checkFileCmd).Output -join '' -eq 'EXISTS') {
                    $getNewLinesCmd = "tail -n +$($lastLineNumber + 1) '$($p.RemoteLogPath)'"
                    $newLinesResult = Invoke-SSHCommand -SSHSession $watcherSession -Command $getNewLinesCmd
                    if ($newLinesResult.Output) {
                        $lines = $newLinesResult.Output
                        foreach ($line in $lines) { Write-Output $line }
                        $lastLineNumber += $lines.Count
                        if ($lines[-1] -match "^====== LOKALER HOT-KLON PROZESS BEENDET") {
                            break
                        }
                    }
                }
            }
            Remove-SSHSession -SSHSession $watcherSession
        } -ArgumentList $watcherParams
        $Global:replicationJobTimer.Start()
        Write-GuiLog "Lokaler Klon-Prozess für $($checkedListBoxVms.CheckedItems.Count) VM(s) gestartet. Log wird live überwacht."
    }

    # Haupt-Ausführungs-Logik
    try {
        & $startLocalCloneJob
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Fehler beim Starten des Skripts: $($_.Exception.Message)", "Fehler", "OK", "Error");
    }
})

# =====================================================================================
# --- STARTBLOCK  (Die Klick-Funktion des Firewall-Buttons) ---
# =====================================================================================
$buttonFirewallCheck.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Für die Firewall-Einrichtung muss eine Verbindung zum ESXi-Host bestehen.", "Fehler", "OK", "Warning"); return
    }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        # --- TEIL 1: Benutzerdefinierte SMTP-Regel für E-Mail (mit dynamischem Namen) ---
        $portToOpen = $textboxEmailPort.Text.Trim()
        if (-not ($portToOpen -match '^\d+$' -and [int]$portToOpen -gt 0 -and [int]$portToOpen -le 65535)) {
            [System.Windows.Forms.MessageBox]::Show("Bitte geben Sie einen gültigen Port (1-65535) in das SMTP-Port Feld ein.", "Ungültiger Port", "OK", "Error")
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            return
        }
        
        # --- NEU: Dynamischer Regelname ---
        $ruleId = "ghettoGUIsmtp$($portToOpen)"
        Write-GuiLog "Erstelle/Prüfe benutzerdefinierte Firewall-Regel '$($ruleId)' für SMTP-Port $portToOpen..."

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

        # --- TEIL 2: Robuste Aktivierung der SSH-Client-Regel ---
        Write-GuiLog "Prüfe/Aktiviere Firewall-Regel für direkte Replikation (sshClient)..."
        $replRuleId = "sshClient"
        $enableResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network firewall ruleset set --enabled true --ruleset-id=$replRuleId"
        if ($enableResult.ExitStatus -eq 0) {
            Write-GuiLog " -> Replikations-Regel '$replRuleId' ist jetzt aktiv."
        } else {
            Write-GuiLog " -> FEHLER beim Aktivieren der Regel '$replRuleId'."
        }
        [System.Windows.Forms.MessageBox]::Show("Die Firewall-Prüfung und -Einrichtung wurde abgeschlossen.", "Firewall-Check abgeschlossen", "OK", "Information")
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
$buttonBrowseGhettoPath.Add_Click({ $selectedDatastorePath = Show-DatastoreSelectionDialog; if ($selectedDatastorePath) { $basePath = $selectedDatastorePath.TrimEnd('/'); $ghettoVCBFolderName = "ghettoVCB"; $fullGhettoPath = "$basePath/$ghettoVCBFolderName"; $textboxGhettoPath.Text = $fullGhettoPath; Write-GuiLog "GhettoVCB-Pfad: $fullGhettoPath" } })
$buttonBrowseBackupVol.Add_Click({ $selectedPath = Show-DatastoreSelectionDialog; if ($selectedPath) { $textboxBackupVol.Text = $selectedPath; Write-GuiLog "Backup Volume: $selectedPath" }})
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
$buttonInstallSendmailPy.Add_Click({ Install-CustomSendmail })
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
# Start Geplante Replikation und Backup mit CRON
#----------------------------------------------------------------------------------

$buttonSaveSchedule.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem ESXi-Host verbinden.", "Fehler", "OK", "Warning"); return
    }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $ghettoPath = $textboxGhettoPath.Text; if ([string]::IsNullOrWhiteSpace($ghettoPath)) { throw "Der GhettoVCB-Pfad muss gesetzt sein!" }
        $scheduleHour = $textboxScheduleHour.Text.Trim(); $scheduleMinute = $textboxScheduleMinute.Text.Trim()
        if (-not ($scheduleHour -match "^\d{1,2}$" -and $scheduleHour -ge 0 -and $scheduleHour -le 23) -or -not ($scheduleMinute -match "^\d{1,2}$" -and $scheduleMinute -ge 0 -and $scheduleMinute -le 59) ) { throw "Ungültige Zeitangabe." }
        $selectedDays = ($checkboxDays.GetEnumerator() | Where-Object { $_.Value.Checked } | ForEach-Object { $_.Value.Tag }) -join ','; if ([string]::IsNullOrEmpty($selectedDays)) { $selectedDays = "*" }
        
        $jobId = (Get-Date -Format "yyyyMMdd-HHmmss")
        $cronCommand = ""
        $cronComment = ""

        if ($radioScheduleRemoteReplication.Checked) {
            Write-GuiLog "Erstelle Skript für geplante entfernte Replikation (ID: $jobId)..."
            $cronComment = "# GhettoGUI - Scheduled Direct Replication (ID: $jobId)"
            $remoteStarterScriptPath = "$ghettoPath/scheduled_replication_$jobId.sh"
            
            $selectedMethod = if ($directReplicationForm.Controls.Find('radioVmkf', $true)[0].Checked) { 'stream' } else { 'robust' }
            $tempPathForSchedule = if ($checkboxUseLocalTemp.Checked) { "" } else { $textboxDrTempPath.Text.TrimEnd('/') }

            $params = @{
                UniqueId          = $jobId;
                TargetHost        = $textboxDrTargetHost.Text; TargetDatastore = $textboxDrTargetDs.Text; Suffix = $textboxDrSuffix.Text;
                ReplicationMethod = $selectedMethod;
                TempPath          = $tempPathForSchedule;
                SnapMem           = if ($checkboxSnapMem.Checked) { 1 } else { 0 }; SnapQuiesce = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 };
                GhettoPath        = $textboxGhettoPath.Text;
                EmailEnabled      = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EmailTo = $textboxEmailTo.Text;
                EmailFrom         = $textboxEmailFrom.Text; EmailServer = $textboxEmailServer.Text; EmailPort = $textboxEmailPort.Text;
                EmailUser         = $textboxEmailUser.Text; EmailPass = $textboxEmailPassword.Text;
                EmailSubject      = "[Scheduled-H2H-Repl] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName);
                VmList            = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }) -join "`n";
                TEMP_CLONE_BASE_PATH = $tempPathForSchedule
            }

            $finalScript = $multiVmScriptTemplate -replace '__UNIQUE_ID__', $params.UniqueId -replace '__VM_LIST__', $params.VmList -replace '__TARGET_HOST__', $params.TargetHost -replace '__TARGET_DATASTORE__', $params.TargetDatastore -replace '__VM_SUFFIX__', $params.Suffix -replace '__REPLICATION_METHOD__', $params.ReplicationMethod -replace '__TEMP_CLONE_BASE_PATH__', $params.TEMP_CLONE_BASE_PATH -replace '__SNAP_MEM__', $params.SnapMem -replace '__SNAP_QUIESCE__', $params.SnapQuiesce -replace '__GHETTO_PATH__', $params.GhettoPath -replace '__EMAIL_ENABLED__', $params.EmailEnabled -replace '__EMAIL_TO__', $params.EmailTo -replace '__EMAIL_FROM__', $params.EmailFrom -replace '__EMAIL_SERVER__', $params.EmailServer -replace '__EMAIL_PORT__', $params.EmailPort -replace '__EMAIL_USER__', $params.EmailUser -replace '__EMAIL_PASS__', $params.EmailPass -replace '__EMAIL_SUBJECT__', $params.EmailSubject

            $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
            try { Set-SFTPContent -SFTPSession $sftpSession -Path $remoteStarterScriptPath -Value ($finalScript.Replace("`r`n", "`n")); Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$remoteStarterScriptPath'" } finally { if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession } }
            $cronCommand = "$scheduleMinute $scheduleHour * * $selectedDays '$remoteStarterScriptPath'"

        } elseif ($radioScheduleLocalReplication.Checked) {
            Write-GuiLog "Erstelle Skript für geplante lokale Replikation (ID: $jobId)..."
            $cronComment = "# GhettoGUI - Scheduled Local Replication (ID: $jobId)"
            $remoteStarterScriptPath = "$ghettoPath/scheduled_local_clone_$jobId.sh"

            $params = @{
                UNIQUE_ID         = $jobId; VM_LIST = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }) -join "`n";
                TARGET_DATASTORE  = $textboxLrTargetDs.Text; VM_SUFFIX = $textboxLrSuffix.Text;
                UUID_ACTION       = if ($localReplicationForm.Controls.Find('radioKeepUuid', $true)[0].Checked) { 'keep' } else { 'create' };
                GHETTO_PATH       = $textboxGhettoPath.Text; SNAP_MEM = if ($checkboxSnapMem.Checked) { 1 } else { 0 }; SNAP_QUIESCE = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 };
                EMAIL_ENABLED     = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EMAIL_TO = $textboxEmailTo.Text;
                EMAIL_FROM        = $textboxEmailFrom.Text; EMAIL_SERVER = $textboxEmailServer.Text; EMAIL_PORT = $textboxEmailPort.Text;
                EMAIL_USER        = $textboxEmailUser.Text; EMAIL_PASS = $textboxEmailPassword.Text;
                EMAIL_SUBJECT     = "[Scheduled-Local-Clone] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName)
            }
            
            $finalScript = $localReplicationScriptTemplate -replace '__UNIQUE_ID__', $params.UNIQUE_ID -replace '__VM_LIST__', $params.VM_LIST -replace '__TARGET_DATASTORE__', $params.TARGET_DATASTORE -replace '__VM_SUFFIX__', $params.VM_SUFFIX -replace '__UUID_ACTION__', $params.UUID_ACTION -replace '__GHETTO_PATH__', $params.GHETTO_PATH -replace '__SNAP_MEM__', $params.SNAP_MEM -replace '__SNAP_QUIESCE__', $params.SNAP_QUIESCE -replace '__EMAIL_ENABLED__', $params.EMAIL_ENABLED -replace '__EMAIL_TO__', $params.EMAIL_TO -replace '__EMAIL_FROM__', $params.EMAIL_FROM -replace '__EMAIL_SERVER__', $params.EMAIL_SERVER -replace '__EMAIL_PORT__', $params.EMAIL_PORT -replace '__EMAIL_USER__', $params.EMAIL_USER -replace '__EMAIL_PASS__', $params.EMAIL_PASS -replace '__EMAIL_SUBJECT__', $params.EMAIL_SUBJECT

            $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
            try { Set-SFTPContent -SFTPSession $sftpSession -Path $remoteStarterScriptPath -Value ($finalScript.Replace("`r`n", "`n")); Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$remoteStarterScriptPath'" } finally { if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession } }
            $cronCommand = "$scheduleMinute $scheduleHour * * $selectedDays '$remoteStarterScriptPath'"

        } else {
            # --- Logik nur für Standard-Backup (unverändert) ---
            Write-GuiLog "Erstelle Backup-Job (ID: $jobId)..."
            $cronComment = "# GhettoGUI - Scheduled Backup (ID: $jobId)"
            $remoteGhettoConf = "$ghettoPath/ghettoVCB-conf-$jobId.conf"
            $remoteVmListFile = "$ghettoPath/vms_to_backup-$jobId.txt"
            $remoteLogFile = "$ghettoPath/logs/backup-run-$jobId.log"
            $remoteGhettoScript = "$ghettoPath/ghettoVCB.sh"
            $confLines = @( "VM_BACKUP_VOLUME=`"$($textboxBackupVol.Text.TrimEnd('/'))/$($textboxSubfolder.Text.Trim('/'))`"", "VM_BACKUP_ROTATION_COUNT=$($textboxRotation.Text)", "DISK_BACKUP_FORMAT=`"$($comboboxDiskFormat.SelectedItem.ToString())`"")
            $ghettoConfContent = ($confLines -join "`n") + "`n"
            $unixVmListText = ($textboxVmList.Text.Split([string[]]@("`r`n","`r","`n"), [System.StringSplitOptions]::RemoveEmptyEntries) -join "`n") + "`n"
            $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
            try { Set-SFTPContent -SFTPSession $sftpSession -Path $remoteGhettoConf -Value $ghettoConfContent -Encoding UTF8; Set-SFTPContent -SFTPSession $sftpSession -Path $remoteVmListFile -Value $unixVmListText -Encoding UTF8 } finally { if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession } }
            $cronCommand = "$scheduleMinute $scheduleHour * * $selectedDays '$remoteGhettoScript' -f '$remoteVmListFile' -g '$remoteGhettoConf' -l '$remoteLogFile'"
        }
        
        $fullCronEntry = "$cronCommand $cronComment"
        Write-GuiLog "Füge neuen Task zum Zeitplan hinzu: $fullCronEntry"
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "echo `"$fullCronEntry`" >> /var/spool/cron/crontabs/root"
        Write-GuiLog "Lade Cron-Dienst neu..."; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command 'kill $(cat /var/run/crond.pid) && crond'
        [System.Windows.Forms.MessageBox]::Show("Ein neuer Task wurde erfolgreich zum Zeitplan hinzugefügt.", "Erfolg", "OK", "Information")
    } catch { 
        Write-GuiLog "FEHLER beim Speichern des Zeitplans: $($_.Exception.Message)" 
    } finally { 
        $form.Cursor = [System.Windows.Forms.Cursors]::Default 
    }
})

# ---------------------------------------------------------------------------------
# Ende Replikation und Backup planen#
#----------------------------------------------------------------------------------

$buttonReplicate.Add_Click({
    # Vorerst öffnet der Button nur das neue Fenster.
    # Die Logik für die Replikation fügen wir im nächsten Schritt hinzu.
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

# 
# =====================================================================================
# --- START BLOCK (Phase 1.6: Finaler Button und Timer) ---
# =====================================================================================

$buttonDirectReplicate.Add_Click({
    if ($checkedListBoxVms.CheckedItems.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Bitte wähle mindestens eine VM für die Replikation aus.", "Keine Auswahl", "OK", "Warning"); return }
#   if ($Global:replicationJob -and $Global:replicationJob.State -eq 'Running') { [System.Windows.Forms.MessageBox]::Show("Es läuft bereits ein anderer Prozess. Bitte warten.", "Beschäftigt", "OK", "Warning"); return }

    $dialogResult = $directReplicationForm.ShowDialog($form)
    
    if ($dialogResult -eq 'OK') {
        $hiddenDrTargetHost.Text = $textboxDrTargetHost.Text
        $hiddenDrTargetDs.Text = $textboxDrTargetDs.Text
        $hiddenDrSuffix.Text = $textboxDrSuffix.Text
        $hiddenDrUseLocalTemp.Text = $checkboxUseLocalTemp.Checked.ToString()
        $hiddenDrTempPath.Text = $textboxDrTempPath.Text
        $hiddenDrMethod.Text = if ($radioVmkf.Checked) { 'vmkfstools' } else { 'tar' }
    }
    
    
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
    $Global:currentJobType = "Direkte Replikation"
   
    $params = @{
        UniqueId          = $uniqueId;
        VmList            = $vmsToReplicate;
        SourceHost        = $Global:ESXiConnectedHostName;
        TargetHost        = $textboxDrTargetHost.Text; TargetDatastore = $textboxDrTargetDs.Text; Suffix = $textboxDrSuffix.Text;
        ReplicationMethod = $selectedMethod; TempPath = $tempPath;
        SnapMem           = if ($checkboxSnapMem.Checked) { 1 } else { 0 }; SnapQuiesce = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 };
        GhettoPath        = $textboxGhettoPath.Text;
        EmailEnabled      = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; EmailTo = $textboxEmailTo.Text;
        EmailFrom         = $textboxEmailFrom.Text; EmailServer = $textboxEmailServer.Text; EmailPort = $textboxEmailPort.Text;
        EmailUser         = $textboxEmailUser.Text; EmailPass = $textboxEmailPassword.Text;
        EmailSubject      = "[Direct-Replication] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName)
    }

    # Das ist die Skript-Vorlage aus deiner funktionierenden 7.1.0-Version

$multiVmScriptTemplate = @'
#!/bin/sh
# GhettoGUI Multi-VM Replication Helper V40.9 (ESXi 6.0 Compatibility Fix)
# - REMOVED: "set -o pipefail" which is not supported on older ESXi 6.0 shells.
# - ADDED: Cleanup-Routine entfernt bei Fehlern nun auch das temporäre Klon-Verzeichnis.
# - ADDED: PATH definition for cron compatibility
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin
export PATH

set -e
# Parameter
UNIQUE_ID='__UNIQUE_ID__'; TARGET_HOST='__TARGET_HOST__'; TARGET_DATASTORE='__TARGET_DATASTORE__'; VM_SUFFIX='__VM_SUFFIX__'; REPLICATION_METHOD='__REPLICATION_METHOD__'; GHETTO_PATH='__GHETTO_PATH__'; LOG_FILE="${GHETTO_PATH}/logs/master_replication_${UNIQUE_ID}.log"; SSH_OPTIONS="-T -i /.ssh/id_ecdsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o Compression=no"; SNAP_MEM=__SNAP_MEM__; SNAP_QUIESCE=__SNAP_QUIESCE__; EMAIL_ENABLED=__EMAIL_ENABLED__; EMAIL_TO='__EMAIL_TO__'; EMAIL_FROM='__EMAIL_FROM__'; EMAIL_SERVER='__EMAIL_SERVER__'; EMAIL_PORT='__EMAIL_PORT__'; EMAIL_USER='__EMAIL_USER__'; EMAIL_PASS='__EMAIL_PASS__'; EMAIL_SUBJECT='__EMAIL_SUBJECT__'; SENDMAIL_PATH="${GHETTO_PATH}/sendmail"; VM_LIST='
__VM_LIST__
# '; OVERALL_STATUS="ERROR"; DIRECTORY_LISTING_CONTENT=""; LOCK_FILE="/tmp/ghetto_replication.lock"; TEMP_CLONE_BASE_PATH='__TEMP_CLONE_BASE_PATH__';
TEMP_CLONE_DIR="" # Wichtig: Variable global definieren

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -> $1" >> ${LOG_FILE}; }
log_raw() { echo "$1" >> ${LOG_FILE}; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- ERROR: $1" >> ${LOG_FILE}; }
log_warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- WARN: $1" >> ${LOG_FILE}; }

send_email_notification() {
    DURATION_MSG="$1"; if [ -z "${DURATION_MSG}" ]; then DURATION_MSG="N/A"; fi
    log_raw "--- START Backup Directory Listing ---"; if [ "${OVERALL_STATUS}" = "OK" ]; then echo "${DIRECTORY_LISTING_CONTENT}" >> ${LOG_FILE}; fi; log_raw "--- END Backup Directory Listing ---";
    if [ "${OVERALL_STATUS}" = "OK" ]; then FINAL_STATUS_MSG="## Final status: All VMs backed up OK! ##"; else FINAL_STATUS_MSG="## Final status: ERROR: Replication failed! ##"; fi
    log "Bereite E-Mail vor: ${OVERALL_STATUS}";
    log_raw "Backup Duration: ${DURATION_MSG}";
    log_raw "${FINAL_STATUS_MSG}";
    if [ "${EMAIL_ENABLED}" = "1" ] && [ -f "${SENDMAIL_PATH}" ]; then
        RECIPIENTS=$(echo "${EMAIL_TO}" | sed 's/,/ /g');
        /bin/python ${SENDMAIL_PATH} -f "${EMAIL_FROM}" -s "${EMAIL_SERVER}" -S "${EMAIL_PORT}" -j "${EMAIL_SUBJECT} - ${FINAL_STATUS_MSG}" -m "${LOG_FILE}" -u "${EMAIL_USER}" -p "${EMAIL_PASS}" ${RECIPIENTS} >> ${LOG_FILE} 2>&1;
    fi;
}

cleanup() {
    EXIT_CODE=$?

    if [ "${EXIT_CODE}" -ne 0 ]; then
        log_warn "FEHLER erkannt (Exit Code: ${EXIT_CODE}). Starte erweiterte Aufräumarbeiten..."
    fi

    # Garantierte Snapshot-Entfernung bei Fehlern
    if [ -n "${VMID}" ] && [ "${REPLICATION_METHOD}" = "robust" ]; then
        SNAPSHOT_EXISTS=$(/bin/vim-cmd vmsvc/snapshot.get ${VMID} 2>/dev/null | grep "ghetto-repl-${UNIQUE_ID}")
        if [ -n "${SNAPSHOT_EXISTS}" ]; then
            log_warn "Bereinige Snapshot auf Quell-VM ${SOURCE_VM_NAME} (VMID ${VMID})..."
            /bin/vim-cmd vmsvc/snapshot.removeall ${VMID} >/dev/null 2>&1
        fi
    fi

    # Entferne temporäres Klon-Verzeichnis bei Fehlern
    if [ "${EXIT_CODE}" -ne 0 ] && [ -n "${TEMP_CLONE_DIR}" ] && [ -d "${TEMP_CLONE_DIR}" ]; then
        log_warn "Entferne unvollständiges temporäres Klon-Verzeichnis: ${TEMP_CLONE_DIR}"
        rm -rf "${TEMP_CLONE_DIR}"
    fi

    log_raw "--- ENDE DES DETAILLOGS ---"
    END_TIME_S=$(date '+%Y-%m-%d %H:%M:%S')
    log_raw "Endzeit: ${END_TIME_S}"
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME)); MINUTES=$((DURATION / 60)); SECONDS=$((DURATION % 60)); DURATION_STRING="${MINUTES} Minuten, ${SECONDS} Sekunden"
    if [ ${EXIT_CODE} -ne 0 ] && [ "${OVERALL_STATUS}" != "OK" ]; then log_error "Skript wurde unerwartet beendet. Status bleibt 'ERROR'."; fi;
    send_email_notification "${DURATION_STRING}";
    rm -f "${LOCK_FILE}";
    log "====== MULTI-VM REPLICATION HELPER BEENDET (ID: ${UNIQUE_ID}) ======";
}

# --- Skriptstart ---
mkdir -p "${GHETTO_PATH}/logs"; rm -f ${LOG_FILE}
START_TIME=$(date +%s)
START_TIME_S=$(date '+%Y-%m-%d %H:%M:%S')
trap cleanup EXIT
log "====== MULTI-VM REPLICATION HELPER GESTARTET (ID: ${UNIQUE_ID}) ======"
if [ -f "${LOCK_FILE}" ]; then log_error "Sperrdatei ${LOCK_FILE} existiert. Breche ab."; exit 1; else echo "Manuelle Replikation gestartet von PID $$ am $(date)" > "${LOCK_FILE}"; fi

log_raw "Startzeit: ${START_TIME_S}"
log_raw "Job-Konfiguration:"
log_raw "  - Methode: ${REPLICATION_METHOD}"
log_raw "  - Temp-Pfad: ${TEMP_CLONE_BASE_PATH:-Lokales VM-Verzeichnis}"
log_raw "  - VM-Suffix: ${VM_SUFFIX}"

TARGET_DATASTORE_PATH_RAW=$(echo "${TARGET_DATASTORE}" | sed 's/\/vmfs\/volumes\///')
TARGET_DATASTORE_PATH="/vmfs/volumes/${TARGET_DATASTORE_PATH_RAW}"

log_raw "Speicherplatz (Vorher):"
log_raw "  - Ziel (${TARGET_DATASTORE_PATH}): $(ssh ${SSH_OPTIONS} root@${TARGET_HOST} "df -h '${TARGET_DATASTORE_PATH}' 2>/dev/null | tail -n 1")"

log_raw "--- START DES DETAILLOGS ---"
VMID="" # Wichtig: VMID ausserhalb der Schleife initialisieren

for SOURCE_VM_NAME in ${VM_LIST}; do
    log "#################### Starte Verarbeitung für VM: ${SOURCE_VM_NAME} ####################"
    log "Initiate backup for ${SOURCE_VM_NAME}"
    REPLICATED_VM_NAME="${SOURCE_VM_NAME}${VM_SUFFIX}"; TARGET_VM_PATH="${TARGET_DATASTORE}/${REPLICATED_VM_NAME}"
    VM_INFO_LINE=$(/bin/vim-cmd vmsvc/getallvms | awk -v name="${SOURCE_VM_NAME}" '{ n=split($0, a, "\\["); vm=a[1]; sub(/^[0-9]+[ \t]+/, "", vm); sub(/[ \t]+$/, "", vm); if (vm == name) print $0; }')
    if [ -z "${VM_INFO_LINE}" ]; then log_error "[${SOURCE_VM_NAME}] - VM nicht gefunden! Überspringe..."; continue; fi
    VMID=$(echo "${VM_INFO_LINE}" | awk '{print $1}'); VMX_FULL_PATH=$(echo "${VM_INFO_LINE}" | sed -e 's/.*\[\(.*\)\]\s*\(.*\.vmx\).*/\/vmfs\/volumes\/\1\/\2/'); VMX_DIR=$(dirname "${VMX_FULL_PATH}")
    
    SOURCE_DATASTORE_PATH=$(dirname "${VMX_DIR}")
    log_raw "  - Quelle (${SOURCE_DATASTORE_PATH}): $(df -h '${SOURCE_DATASTORE_PATH}' 2>/dev/null | tail -n 1)"

    log "[1/9] Prüfe und bereinige eventuell vorhandene alte Replikation auf dem Ziel-Host..."
    TARGET_VMID=$(ssh ${SSH_OPTIONS} root@${TARGET_HOST} "/bin/vim-cmd vmsvc/getallvms | awk -v name=\"${REPLICATED_VM_NAME}\" '{ n=split(\$0, a, \"\\[\"); vm=a[1]; sub(/^[0-9]+[ \t]+/, \"\", vm); sub(/[ \t]+$/, \"\", vm); if (vm == name) print \$1; }'")
    if [ -n "${TARGET_VMID}" ]; then
        log "  -> Alte Replikation '${REPLICATED_VM_NAME}' gefunden (VMID: ${TARGET_VMID})."
        log "  -> Schalte alte Replikation aus (falls an)..."
        ssh ${SSH_OPTIONS} root@${TARGET_HOST} "/bin/vim-cmd vmsvc/power.off ${TARGET_VMID} >/dev/null 2>&1 || true"
        sleep 5
        log "  -> Deregistriere alte Replikation..."
        ssh ${SSH_OPTIONS} root@${TARGET_HOST} "/bin/vim-cmd vmsvc/unregister ${TARGET_VMID} >/dev/null 2>&1"
        log "  -> Alte VM-Registrierung entfernt."
    else
        log "  -> Keine alte Replikation mit Namen '${REPLICATED_VM_NAME}' auf dem Ziel-Host registriert. Fahre fort."
    fi

    log "[2/9] Bereinige altes Verzeichnis und erstelle Zielverzeichnis..."; ssh ${SSH_OPTIONS} root@${TARGET_HOST} "rm -rf '${TARGET_VM_PATH}'; mkdir -p '${TARGET_VM_PATH}'"

    if [ "${REPLICATION_METHOD}" = "robust" ]; then
        log "[3/9] Starte ONLINE Replikation (mit Temp Klon)..."
        log "[4/9] Erstelle Snapshot..."; /bin/vim-cmd vmsvc/snapshot.create ${VMID} "ghetto-repl-${UNIQUE_ID}" "GhettoGUI Replication" ${SNAP_MEM} ${SNAP_QUIESCE}; log "Warte 10 Sekunden..."; sleep 10
        if [ -z "${TEMP_CLONE_BASE_PATH}" ]; then TEMP_CLONE_DIR="${VMX_DIR}/ghetto_clone_${UNIQUE_ID}_${SOURCE_VM_NAME}"; else TEMP_CLONE_DIR="${TEMP_CLONE_BASE_PATH}/ghetto_clone_${UNIQUE_ID}_${SOURCE_VM_NAME}"; fi; mkdir -p "${TEMP_CLONE_DIR}";
        DISK_DEFINITIONS=$(grep -iE '(\.vmdk)' "${VMX_FULL_PATH}" | grep -iE '(^scsi|^ide|^sata|^nvme)'); OLD_IFS=$IFS; IFS='
'; for line in ${DISK_DEFINITIONS}; do
            IFS=$OLD_IFS; DISK_FILE_NAME=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p'); if [ -z "${DISK_FILE_NAME}" ]; then continue; fi
            ORIGINAL_DISK_BASENAME=$(echo "${DISK_FILE_NAME}" | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/'); SOURCE_DISK_PATH="${VMX_DIR}/${ORIGINAL_DISK_BASENAME}"; TEMP_DESTINATION_DISK_PATH="${TEMP_CLONE_DIR}/${ORIGINAL_DISK_BASENAME}";
            log "    -> Klone (Basis-Disk): ${SOURCE_DISK_PATH}"; /sbin/vmkfstools -i "${SOURCE_DISK_PATH}" -d thin "${TEMP_DESTINATION_DISK_PATH}" >> ${LOG_FILE} 2>&1 &
            VMKF_PID=$!; log "      -> Klon-Prozess gestartet mit PID: ${VMKF_PID}."; while kill -0 ${VMKF_PID} >/dev/null 2>&1; do if [ -f "${TEMP_DESTINATION_DISK_PATH}" ]; then log "-> Klon: $(du -h "${TEMP_DESTINATION_DISK_PATH}" | awk '{print $1}')"; fi; sleep 15; done; wait ${VMKF_PID}; CLONE_EXIT_CODE=$?; if [ ${CLONE_EXIT_CODE} -ne 0 ]; then log_error "[${SOURCE_VM_NAME}] - Klonen fehlgeschlagen!"; exit 1; fi
        IFS='
'; done; IFS=$OLD_IFS
        (cd "${VMX_DIR}" && find . -maxdepth 1 ! -name '*.vmdk' -exec cp -p '{}' "${TEMP_CLONE_DIR}/" \;)
        log "[5/9] Starte TAR-Transfer..."; SOURCE_SIZE=$(du -sh "${TEMP_CLONE_DIR}" | awk '{print $1}'); log "  -> Gesamtgröße: ~${SOURCE_SIZE}";
        ( (cd "${TEMP_CLONE_DIR}" && tar -cf - .) | ssh ${SSH_OPTIONS} root@${TARGET_HOST} "tar -xf - -C '${TARGET_VM_PATH}'" ) &
        TAR_PID=$!; log "  -> Transferprozess gestartet mit PID: ${TAR_PID}."; while kill -0 ${TAR_PID} >/dev/null 2>&1; do PROGRESS=$(ssh ${SSH_OPTIONS} root@${TARGET_HOST} "du -sh '${TARGET_VM_PATH}' 2>/dev/null | awk '{print \$1}'"); if [ -n "${PROGRESS}" ]; then log "->${SOURCE_VM_NAME}->: ${PROGRESS} von ~${SOURCE_SIZE}"; fi; sleep 30; done; wait ${TAR_PID}; TRANSFER_EXIT_CODE=$?; if [ ${TRANSFER_EXIT_CODE} -ne 0 ]; then log_error "[${SOURCE_VM_NAME}] - TAR-Transfer fehlgeschlagen!"; exit 1; fi; rm -rf "${TEMP_CLONE_DIR}"
    else
        log "[3/9] Starte OFFLINE Replikation (Stream via TAR)..."; POWER_STATE_BEFORE_BACKUP="unknown"; if vim-cmd vmsvc/power.getstate ${VMID} | grep -q "Powered on"; then
            log "[4/9] Fahre VM '${SOURCE_VM_NAME}' herunter..."; POWER_STATE_BEFORE_BACKUP="on"; vim-cmd vmsvc/power.shutdown ${VMID}; ATTEMPTS=0; MAX_ATTEMPTS=10
            while vim-cmd vmsvc/power.getstate ${VMID} | grep -q "Powered on"; do if [ ${ATTEMPTS} -ge ${MAX_ATTEMPTS} ]; then log_error "[${SOURCE_VM_NAME}] - VM konnte nicht heruntergefahren werden."; vim-cmd vmsvc/power.on ${VMID}; continue 2; fi; log "  -> Warte auf Shutdown..."; sleep 30; ATTEMPTS=$((ATTEMPTS + 1)); done; fi
        log "[5/9] Starte TAR-Stream..."; SOURCE_SIZE=$(du -sh "${VMX_DIR}" | awk '{print $1}'); (cd "${VMX_DIR}" && tar -cf - .) | ssh ${SSH_OPTIONS} root@${TARGET_HOST} "tar -xf - -C '${TARGET_VM_PATH}'" &
        TAR_PID=$!; while kill -0 ${TAR_PID} >/dev/null 2>&1; do PROGRESS=$(ssh ${SSH_OPTIONS} root@${TARGET_HOST} "du -sh '${TARGET_VM_PATH}' 2>/dev/null | awk '{print \$1}'"); if [ -n "${PROGRESS}" ]; then log "-> Transfer: ${PROGRESS} von ~${SOURCE_SIZE}"; fi; sleep 30; done; wait ${TAR_PID}; TRANSFER_EXIT_CODE=$?; if [ ${TRANSFER_EXIT_CODE} -ne 0 ]; then log_error "[${SOURCE_VM_NAME}] - TAR-Transfer fehlgeschlagen!"; exit 1; fi
    fi
    log "[6/9] Passe Zieldateien an..."; ssh ${SSH_OPTIONS} root@${TARGET_HOST} "set -e; cd '${TARGET_VM_PATH}'; ORIG_VMX_FILE=\$(find . -maxdepth 1 -name \"*.vmx\"); RENAMED_VMX_FILE=\"./${REPLICATED_VM_NAME}.vmx\"; mv \"\${ORIG_VMX_FILE}\" \"\${RENAMED_VMX_FILE}\"; sed -i -e \"s/^displayName = .*/displayName = \\\"${REPLICATED_VM_NAME}\\\"/\" \"\${RENAMED_VMX_FILE}\"; sed -i 's/-[0-9]\{6\}\.vmdk/\.vmdk/g' \"\${RENAMED_VMX_FILE}\"; sed -i '/^sched\\.swap\\.derivedName/d' \"\${RENAMED_VMX_FILE}\"" >> ${LOG_FILE} 2>&1
    
    log "[7/9] Registriere VM..."; 
    TARGET_VMX_PATH_ON_TARGET="${TARGET_VM_PATH}/${REPLICATED_VM_NAME}.vmx"; 
    REG_CMD="/bin/vim-cmd solo/registervm '${TARGET_VMX_PATH_ON_TARGET}'"
    REG_OUTPUT=$(ssh ${SSH_OPTIONS} root@${TARGET_HOST} "${REG_CMD}" 2>&1)
    REG_EXIT_CODE=$?

    if [ ${REG_EXIT_CODE} -eq 0 ]; then
        log "  -> OK: VM erfolgreich registriert als VMID ${REG_OUTPUT}."
    else
        log_error "[${SOURCE_VM_NAME}] - VM-Registrierung fehlgeschlagen! Exit Code: ${REG_EXIT_CODE}"
        log_error "Fehlermeldung: ${REG_OUTPUT}"
        exit 1
    fi

    if [ "${REPLICATION_METHOD}" = "robust" ]; then log "[8/9] Lösche Snapshot..."; /bin/vim-cmd vmsvc/snapshot.removeall ${VMID}; fi
    if [ "${REPLICATION_METHOD}" != "robust" ] && [ "${POWER_STATE_BEFORE_BACKUP}" = "on" ]; then log "[8/9] Starte Quell-VM wieder..."; vim-cmd vmsvc/power.on ${VMID}; fi
    if LISTING_CMD_OUTPUT=$(ssh ${SSH_OPTIONS} root@${TARGET_HOST} "ls -lR '${TARGET_VM_PATH}'" 2>/dev/null); then DIRECTORY_LISTING_CONTENT="${DIRECTORY_LISTING_CONTENT}
--- VM: ${REPLICATED_VM_NAME} ---
${LISTING_CMD_OUTPUT}"; fi
    log "###### Verarbeitung für VM ${SOURCE_VM_NAME} erfolgreich abgeschlossen."
done
OVERALL_STATUS="OK"
'@

    $finalMasterScript = $multiVmScriptTemplate.Replace('__UNIQUE_ID__', $params.UniqueId).Replace('__VM_LIST__', $params.VmList).Replace('__TARGET_HOST__', $params.TargetHost).Replace('__TARGET_DATASTORE__', $params.TargetDatastore).Replace('__VM_SUFFIX__', $params.Suffix).Replace('__REPLICATION_METHOD__', $params.ReplicationMethod).Replace('__TEMP_CLONE_BASE_PATH__', $params.TempPath).Replace('__SNAP_MEM__', $params.SnapMem).Replace('__SNAP_QUIESCE__', $params.SnapQuiesce).Replace('__GHETTO_PATH__', $params.GhettoPath).Replace('__EMAIL_ENABLED__', $params.EmailEnabled).Replace('__EMAIL_TO__', $params.EmailTo).Replace('__EMAIL_FROM__', $params.EmailFrom).Replace('__EMAIL_SERVER__', $params.EmailServer).Replace('__EMAIL_PORT__', $params.EmailPort).Replace('__EMAIL_USER__', $params.EmailUser).Replace('__EMAIL_PASS__', $params.EmailPass).Replace('__EMAIL_SUBJECT__', $params.EmailSubject)
    
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
    Write-GuiLog "Replikations-Job für $($checkedListBoxVms.CheckedItems.Count) VM(s) gestartet (ID: $($Global:replicationJob.Id)). Log wird live überwacht."
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
        Write-GuiLog "=================================================================="
        
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

    if ([string]::IsNullOrWhiteSpace($emailParams.To) -or [string]::IsNullOrWhiteSpace($emailParams.From) -or [string]::IsNullOrWhiteSpace($emailParams.Server) -or [string]::IsNullOrWhiteSpace($emailParams.Port)) {
        Write-GuiLog "FEHLER: Bitte fülle alle E-Mail-Felder aus."; $form.Cursor = [System.Windows.Forms.Cursors]::Default; return
    }
    $ghettoPathOnESXi = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) {
        Write-GuiLog "FEHLER: Der GhettoVCB-Pfad muss gesetzt sein."; $form.Cursor = [System.Windows.Forms.Cursors]::Default; return
    }

    $sftpSession = $null
    $remoteTestMessagePath = "/tmp/ghetto_test_mail.txt"
    try {
        $ErrorActionPreference = "Stop"
        $sourceScriptPath = "'$ghettoPathOnESXi/sendmail'"
        $tmpScriptPath = "/tmp/sendmail_test_run"

        $testSubject = "GhettoVCB GUI - Test E-Mail von Host $($Global:ESXiConnectedHostName)"
        $testBody = "## Final status: Test erfolgreich ##`nBackup Duration: 1 Sekunde`ninfo: Initiate backup for Test-VM"

        Write-GuiLog "Lade Test-Nachricht nach ESXi hoch..."
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -ConnectionTimeout 60
        Set-SFTPContent -SFTPSession $sftpSession -Path $remoteTestMessagePath -Value $testBody -Encoding UTF8
        Write-GuiLog "Upload der temporären Test-Nachricht erfolgreich."

        $recipientsForCli = $emailParams.To.Split(',') | ForEach-Object { "'$($_.Trim())'" }
        $recipientsStr = $recipientsForCli -join " "

        $base_command = "$tmpScriptPath -m $remoteTestMessagePath -f `"$($emailParams.From)`" -s `"$($emailParams.Server)`" -S `"$($emailParams.Port)`" -j `"$testSubject`" "
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

################################
##### Ende testmail
#########################


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
    # Die Prüfung am Anfang bleibt gleich
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return $false }

    # Die Variablendefinitionen bleiben gleich
    $baseBackupPath = $textboxBackupVol.Text.TrimEnd('/'); $subfolder = $textboxSubfolder.Text.Trim('/'); $fullBackupPath = if (-not [string]::IsNullOrWhiteSpace($subfolder)) { "$baseBackupPath/$subfolder" } else { $baseBackupPath }
    $ghettoPath = $textboxGhettoPath.Text; $rotation = $textboxRotation.Text; $diskFormat = $comboboxDiskFormat.SelectedItem.ToString(); $snapMem = if ($checkboxSnapMem.Checked) { 1 } else { 0 }; $snapQuiesce = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 }; $vmListText = $textboxVmList.Text
    if (-not $ghettoPath -or -not $fullBackupPath) { Write-GuiLog "Fehler: GhettoVCB-Pfad und Backup Volume/Unterordner erforderlich."; return $false }
    $emailLog = if ($checkboxEmailLog.Checked) { 1 } else { 0 }; $emailTo = $textboxEmailTo.Text; $emailFrom = $textboxEmailFrom.Text; $emailServer = $textboxEmailServer.Text; $emailPort = $textboxEmailPort.Text;
    $emailUser = $textboxEmailUser.Text; $emailPass = $textboxEmailPassword.Text;
    $emailSubjectTemplate = $textboxEmailSubject.Text
    $emailSubject = $emailSubjectTemplate.Replace('%h', $Global:ESXiConnectedHostName)
    $emailBinPath = "'$ghettoPath/sendmail'"

    # Die confLines bleiben gleich
	$useFixedDirValue = if ($checkboxFixedBackupDir.Checked) { 1 } else { 0 }
	$confLines = @(
		"USE_FIXED_BACKUP_DIR=$useFixedDirValue", # NEUE ZEILE
        "VM_BACKUP_VOLUME=""$fullBackupPath""", "VM_BACKUP_ROTATION_COUNT=$rotation", "DISK_BACKUP_FORMAT=""$diskFormat""", "SNAPSHOT_MEMORY=$snapMem", "SNAPSHOT_QUIESCE=$snapQuiesce",
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

        # HIER IST DIE ERGÄNZUNG: Erfolgsmeldung zurückgeben
        return $true

    } catch {
        Write-GuiLog "Fehler beim Speichern: $($_.Exception.Message)"
        # HIER IST DIE ERGÄNZUNG: Fehlermeldung zurückgeben
        return $false
    } finally {
        if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession -EA 0 }
        $ErrorActionPreference = "Continue"
    }
}

# =====================================================================================
# --- START BLOCK (Phase 2: Erweiterte Speicher-Funktion) ---
# =====================================================================================

function Save-HostGuiSettings {
    param(
        [string]$FilePath
    )
    if (-not $FilePath) { Write-GuiLog "FEHLER: Kein Dateipfad zum Speichern angegeben."; return }

    $scheduleTypeToSave = 'Backup'
    if ($radioScheduleRemoteReplication.Checked) { $scheduleTypeToSave = 'RemoteReplication' } 
    elseif ($radioScheduleLocalReplication.Checked) { $scheduleTypeToSave = 'LocalReplication' }

    $settings = @{
        EsxiIp = $textboxIp.Text; EsxiUser = $textboxUser.Text; GhettoPath = $textboxGhettoPath.Text; BackupVol = $textboxBackupVol.Text; Subfolder = $textboxSubfolder.Text; Rotation = $textboxRotation.Text;
        DiskFormat = $comboboxDiskFormat.SelectedItem; SnapMem = $checkboxSnapMem.Checked; FixedBackupDir = $checkboxFixedBackupDir.Checked; SnapQuiesce = $checkboxSnapQuiesce.Checked; VmList = $textboxVmList.Text;
        ScheduleHour = $textboxScheduleHour.Text; ScheduleMinute = $textboxScheduleMinute.Text; ScheduleDays = @{};
        ScheduleType = $scheduleTypeToSave;
        EmailLog = $checkboxEmailLog.Checked; EmailTo = $textboxEmailTo.Text; EmailFrom = $textboxEmailFrom.Text; EmailServer = $textboxEmailServer.Text; EmailPort = $textboxEmailPort.Text; EmailSubject = $textboxEmailSubject.Text;
        EmailUser = $textboxEmailUser.Text; EmailPass = $textboxEmailPassword.Text;
        ReplTargetHost = $textboxDrTargetHost.Text; ReplTargetDatastore = $textboxDrTargetDs.Text; ReplSuffix = $textboxDrSuffix.Text;
        ReplUseLocalTemp = $checkboxUseLocalTemp.Checked; ReplTempPath = $textboxDrTempPath.Text;
        ReplMethod = if ($radioVmkf.Checked) { 'vmkfstools' } else { 'tar' };
        
        # --- KORREKTUR: Fehlende Einstellungen für Lokalen Klon hinzugefügt ---
        LocalReplTargetDatastore = $textboxLrTargetDs.Text;
        LocalReplSuffix = $textboxLrSuffix.Text;
        LocalReplUuidAction = if ($radioKeepUuid.Checked) { 'keep' } else { 'create' };
    }
    foreach ($dayEntry in $checkboxDays.GetEnumerator()) { $settings.ScheduleDays[$dayEntry.Name] = $dayEntry.Value.Checked }

    try {
        $jsonOutput = $settings | ConvertTo-Json -Depth 5
        $cleanJson = $jsonOutput -replace ',(?=\s*})', ''
        $cleanJson | Set-Content -Path $FilePath -Encoding UTF8
        Write-GuiLog "Job-Konfiguration erfolgreich in '$FilePath' gespeichert."
    } catch {
        Write-GuiLog "FEHLER beim Speichern der Job-Konfiguration: $($_.Exception.Message)"
    }
}

# =====================================================================================
# --- END BLOCK ---
# =====================================================================================

# =====================================================================================
# --- START BLOCK (Lade-Funktion Fix) ---
# =====================================================================================

function Load-HostGuiSettings {
    param(
        [string]$FilePath
    )
    if (-not (Test-Path $FilePath)) { Write-GuiLog "FEHLER: Die Einstellungsdatei '$FilePath' wurde nicht gefunden."; return }
    Write-GuiLog "Lade Job-Konfiguration aus '$FilePath'..."
    try {
        $settings = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
        
        $textboxIp.Text = $settings.EsxiIp; $textboxUser.Text = $settings.EsxiUser; $textboxGhettoPath.Text = $settings.GhettoPath; $textboxBackupVol.Text = $settings.BackupVol; $textboxSubfolder.Text = $settings.Subfolder; $textboxRotation.Text = $settings.Rotation; $comboboxDiskFormat.SelectedItem = $settings.DiskFormat; $checkboxSnapMem.Checked = $settings.SnapMem; $checkboxSnapQuiesce.Checked = $settings.SnapQuiesce; $textboxVmList.Text = $settings.VmList
        if ($settings.PSObject.Properties.Name -contains 'FixedBackupDir') { $checkboxFixedBackupDir.Checked = $settings.FixedBackupDir }
        $textboxScheduleHour.Text = $settings.ScheduleHour; $textboxScheduleMinute.Text = $settings.ScheduleMinute
        if ($settings.ScheduleDays) { foreach ($dayEntry in $settings.ScheduleDays.PSObject.Properties) { if ($checkboxDays.ContainsKey($dayEntry.Name)) { $checkboxDays[$dayEntry.Name].Checked = $dayEntry.Value } } }
        if ($settings.PSObject.Properties.Name -contains 'ScheduleType') { if ($settings.ScheduleType -eq 'RemoteReplication') { $radioScheduleRemoteReplication.Checked = $true } elseif ($settings.ScheduleType -eq 'LocalReplication') { $radioScheduleLocalReplication.Checked = $true } else { $radioScheduleBackup.Checked = $true } } else { $radioScheduleBackup.Checked = $true }
        if ($settings.PSObject.Properties['EmailLog']) { $checkboxEmailLog.Checked = $settings.EmailLog }; if ($settings.PSObject.Properties['EmailTo']) { $textboxEmailTo.Text = $settings.EmailTo }; if ($settings.PSObject.Properties['EmailFrom']) { $textboxEmailFrom.Text = $settings.EmailFrom }; if ($settings.PSObject.Properties['EmailServer']) { $textboxEmailServer.Text = $settings.EmailServer }; if ($settings.PSObject.Properties['EmailPort']) { $textboxEmailPort.Text = $settings.EmailPort }; if ($settings.PSObject.Properties['EmailSubject']) { $textboxEmailSubject.Text = $settings.EmailSubject }; if ($settings.PSObject.Properties['EmailUser']) { $textboxEmailUser.Text = $settings.EmailUser }; if ($settings.PSObject.Properties['EmailPass']) { $textboxEmailPassword.Text = $settings.EmailPass }

        # Lade Einstellungen für die direkte Replikation
        if ($settings.PSObject.Properties.Name -contains 'ReplTargetHost') { $textboxDrTargetHost.Text = $settings.ReplTargetHost; $hiddenDrTargetHost.Text = $settings.ReplTargetHost }
        if ($settings.PSObject.Properties.Name -contains 'ReplTargetDatastore') { $textboxDrTargetDs.Text = $settings.ReplTargetDatastore; $hiddenDrTargetDs.Text = $settings.ReplTargetDatastore }
        if ($settings.PSObject.Properties.Name -contains 'ReplSuffix') { $textboxDrSuffix.Text = $settings.ReplSuffix; $hiddenDrSuffix.Text = $settings.ReplSuffix }
        if ($settings.PSObject.Properties.Name -contains 'ReplUseLocalTemp') { $checkboxUseLocalTemp.Checked = $settings.ReplUseLocalTemp; $hiddenDrUseLocalTemp.Text = $settings.ReplUseLocalTemp.ToString() } else { $checkboxUseLocalTemp.Checked = $true; $hiddenDrUseLocalTemp.Text = $true.ToString() }
        if ($settings.PSObject.Properties.Name -contains 'ReplTempPath') { $textboxDrTempPath.Text = $settings.ReplTempPath; $hiddenDrTempPath.Text = $settings.ReplTempPath }
        $textboxDrTempPath.Enabled = -not $checkboxUseLocalTemp.Checked; $buttonBrowseDrTempPath.Enabled = -not $checkboxUseLocalTemp.Checked
        if ($settings.PSObject.Properties.Name -contains 'ReplMethod') { if ($settings.ReplMethod -eq 'vmkfstools') { $radioVmkf.Checked = $true; $hiddenDrMethod.Text = 'vmkfstools' } else { $radioTar.Checked = $true; $hiddenDrMethod.Text = 'tar' } } else { $radioTar.Checked = $true; $hiddenDrMethod.Text = 'tar' }
        
        # --- KORREKTUR: Lade die spezifischen Einstellungen für den Lokalen Klon ---
        if ($settings.PSObject.Properties.Name -contains 'LocalReplTargetDatastore') { $textboxLrTargetDs.Text = $settings.LocalReplTargetDatastore; $hiddenLrTargetDs.Text = $settings.LocalReplTargetDatastore }
        if ($settings.PSObject.Properties.Name -contains 'LocalReplSuffix') { $textboxLrSuffix.Text = $settings.LocalReplSuffix; $hiddenLrSuffix.Text = $settings.LocalReplSuffix }
        if ($settings.PSObject.Properties.Name -contains 'LocalReplUuidAction') { if ($settings.LocalReplUuidAction -eq 'keep') { $radioKeepUuid.Checked = $true; $hiddenLrUuidAction.Text = 'keep' } else { $radioCreateUuid.Checked = $true; $hiddenLrUuidAction.Text = 'create' } } else { $radioCreateUuid.Checked = $true; $hiddenLrUuidAction.Text = 'create' }

        # --- KORREKTUR: Stelle sicher, dass die VM-Liste synchronisiert wird ---
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
    } catch { 
        Write-GuiLog "FEHLER: Konnte Job-Datei '$FilePath' nicht laden oder parsen. $($_.Exception.Message)" 
    }
}

# =====================================================================================
# --- END BLOCK ---
# =====================================================================================


function Start-GhettoVCBBackupJob {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return $false };
    $ghettoPathOnESXi = $textboxGhettoPath.Text;
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "Fehler: GhettoVCB-Pfad im GUI ist nicht gesetzt."; return $false };

    $jobStarted = $false;
    $ghettoScript = "'$ghettoPathOnESXi/ghettoVCB.sh'";
    $ghettoConfigFile = "'$ghettoPathOnESXi/ghettoVCB.conf'";
    $ghettoVmListFile = "'$ghettoPathOnESXi/vms_to_backup.txt'";

    $logFile = "'$ghettoPathOnESXi/ghettoVCB-last_manual_run.log'";
    $backupCommand = "$ghettoScript -g $ghettoConfigFile -f $ghettoVmListFile -l $logFile";
    $nohupCommand = "nohup $backupCommand >> $logFile 2>&1 &";

    Write-GuiLog "Starte Backup-Prozess auf ESXi im Hintergrund...";
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor;
    try {
        Write-GuiLog "Säubere eventuell vorhandenes temporäres Verzeichnis...";
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm -rf /tmp/ghettoVCB.work" | Out-Null;
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm -f $logFile" | Out-Null;
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

function Get-BackupJobLog {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }
    $ghettoPathOnESXi = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "Fehler: GhettoVCB-Pfad im GUI ist nicht gesetzt."; return }

    # NEU: Finde die aktuellste Log-Datei von einem geplanten oder manuellen Lauf
    $logDir = "'$ghettoPathOnESXi/logs'"
    $findLatestLogCmd = "ls -t $logDir/*.log $logDir/ghettoVCB-last_manual_run.log 2>/dev/null | head -n 1"
    
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
                        # $mountPoint ist der ZUVERLÄSSIGE Pfad mit der UUID
                        $mountPoint = $parts[0];
                        $volumeNameOriginal = $parts[1];
                        
                        # Wir verwenden IMMER den MountPoint für die Aktionen
                        $pathToUse = $mountPoint; 
                        
                        # Für die Anzeige im GUI erstellen wir einen freundlicheren Namen
                        $displayName = $volumeNameOriginal
                        if ($volumeNameOriginal -ne ($mountPoint -split '/')[-1] ) {
                            $displayName = "$volumeNameOriginal ($($mountPoint.Split('/')[-1]))"
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
    } catch {
        Write-GuiLog "FEHLER beim GitHub-Download: $($_.Exception.Message)"
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
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden, um Zeit abzufragen."; $labelEsxiTime.Text = "ESXi nicht verbunden"; return }; Write-GuiLog "Frage ESXi-Zeit (UTC) ab..."; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; try { $dateOutput = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "date -u"; if ($dateOutput.ExitStatus -eq 0 -and $dateOutput.Output) { $esxiTimeString = ($dateOutput.Output -join " ").Trim(); Write-GuiLog "ESXi-Zeit (UTC) empfangen: $esxiTimeString"; $labelEsxiTime.Text = $esxiTimeString } else { Write-GuiLog "Fehler beim Abfragen der ESXi-Zeit. Exit: $($dateOutput.ExitStatus)"; if($dateOutput.Error){ Write-GuiLog "ESXi-Zeit Fehler (stderr): $($dateOutput.Error -join [Environment]::NewLine)" }; $labelEsxiTime.Text = "Fehler bei Abfrage" }} catch { Write-GuiLog "Ausnahmefehler beim Abfragen der ESXi-Zeit: $($_.Exception.Message)"; $labelEsxiTime.Text = "Ausnahmefehler" } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }}

#  --- Logik Funktion Restore Start --------

function Show-DirectorySelectionDialog {
    param(
        [string]$Title,
        [string]$BasePath,
        [object]$SshSession
    )
    $selectionDialog = New-Object System.Windows.Forms.Form; $selectionDialog.Text = $Title; $selectionDialog.Size = New-Object System.Drawing.Size(450, 350); $selectionDialog.StartPosition = "CenterParent"; $selectionDialog.FormBorderStyle = 'FixedDialog'; $selectionDialog.Tag = $null
    
    $listBox = New-Object System.Windows.Forms.ListBox; $listBox.Dock = 'Top'; $listBox.Height = 250; $listBox.Margin = New-Object System.Windows.Forms.Padding(10)
    
    # NEU: Button-Panel für flexible Steuerung
    $buttonOpen = New-Object System.Windows.Forms.Button; $buttonOpen.Text = "Öffnen"; $buttonOpen.DialogResult = 'OK'; $buttonOpen.Enabled = $false
        $buttonSelectCurrent = New-Object System.Windows.Forms.Button; $buttonSelectCurrent.Text = "Diesen Ordner auswählen"; $buttonSelectCurrent.DialogResult = 'Yes' # Spezieller DialogResult für diese Aktion
        $buttonSelectCurrent.AutoSize = $true # NEU: Button-Grösse automatisch anpassen
        $buttonCancel = New-Object System.Windows.Forms.Button; $buttonCancel.Text = "Abbrechen"; $buttonCancel.DialogResult = 'Cancel'
	
	
    $flowPanel = New-Object System.Windows.Forms.FlowLayoutPanel; $flowPanel.Dock = 'Bottom'; $flowPanel.FlowDirection = 'RightToLeft'; $flowPanel.Height = 40
    $flowPanel.Controls.AddRange(@($buttonCancel, $buttonOpen, $buttonSelectCurrent))
    
    $selectionDialog.Controls.AddRange(@($listBox, $flowPanel))
    $selectionDialog.AcceptButton = $buttonOpen; $selectionDialog.CancelButton = $buttonCancel

    $listBox.Add_SelectedIndexChanged({ $buttonOpen.Enabled = ($listBox.SelectedItem -ne $null) })
    $listBox.Add_DoubleClick({ if ($listBox.SelectedItem) { $buttonOpen.PerformClick() } })

    $selectionDialog.Add_Shown({
        $selectionDialog.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            # Wir fügen einen ".." Eintrag hinzu, um eine Ebene nach oben zu navigieren
            $command = "if [ -d ""$BasePath"" ]; then ls ""$BasePath""; fi"
            $result = Invoke-SSHCommand -SSHSession $SshSession -Command $command
            if ($result.ExitStatus -eq 0) {
                $listBox.Items.Add(".. (Eine Ebene höher)")
                if ($result.Output) {
                    $listBox.Items.AddRange(($result.Output | Where-Object { $_ }))
                }
            } else {
                [System.Windows.Forms.MessageBox]::Show("Konnte das Verzeichnis nicht lesen.`n$($result.Error -join "`n")", "Fehler", "OK", "Warning")
                $selectionDialog.Close()
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Fehler beim Abrufen der Verzeichnisliste: $($_.Exception.Message)", "Fehler", "OK", "Error")
            $selectionDialog.Close()
        } finally {
            $selectionDialog.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # Wir geben das Ergebnis und das ausgewählte Item zurück
    $dialogResult = $selectionDialog.ShowDialog($form)
    return @{ Result = $dialogResult; SelectedItem = $listBox.SelectedItem }
}

#  --- Logik Funktion Restore Ende  -------

# --- Unsichtbare Labels als globaler Cache für alle Replikations-Einstellungen ---
$hiddenDrTargetHost = New-Object System.Windows.Forms.Label; $hiddenDrTargetHost.Visible = $false
$hiddenDrTargetDs = New-Object System.Windows.Forms.Label; $hiddenDrTargetDs.Visible = $false
$hiddenDrSuffix = New-Object System.Windows.Forms.Label; $hiddenDrSuffix.Visible = $false
$hiddenDrUseLocalTemp = New-Object System.Windows.Forms.Label; $hiddenDrUseLocalTemp.Visible = $false
$hiddenDrTempPath = New-Object System.Windows.Forms.Label; $hiddenDrTempPath.Visible = $false
$hiddenDrMethod = New-Object System.Windows.Forms.Label; $hiddenDrMethod.Visible = $false
$hiddenLrTargetDs = New-Object System.Windows.Forms.Label; $hiddenLrTargetDs.Visible = $false
$hiddenLrSuffix = New-Object System.Windows.Forms.Label; $hiddenLrSuffix.Visible = $false
$hiddenLrUuidAction = New-Object System.Windows.Forms.Label; $hiddenLrUuidAction.Visible = $false

# --- Formular Steuerelemente hinzufügen und anzeigen ---
$form.Controls.AddRange(@(
    $labelIp, $textboxIp, $labelUser, $textboxUser, $connectButton, $disconnectButton,
    $buttonCheckPoshSsh, $groupGhettoConfig, $buttonLoadGuiSettings, $buttonSaveGuiSettings,
    $saveConfigButton, $buttonInstallGitHub, $buttonInstallPatchedGhetto, $buttonInstallSendmailPy, $buttonOpenSshConsole, $groupSchedule, $groupEmail,
    $buttonStartBackup, $buttonCheckBackupStatus, $buttonCancelBackup, $buttonBrowseBackupDir,
    $outputBox, $groupTraffic,
    # HIER DIE NEUEN, UNSICHTBAREN FELDER HINZUFÜGEN:
    $hiddenDrTargetHost, $hiddenDrTargetDs, $hiddenDrSuffix, $hiddenDrUseLocalTemp, $hiddenDrTempPath, $hiddenDrMethod, $hiddenLrTargetDs, $hiddenLrSuffix, $hiddenLrUuidAction
))

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
    $junkFiles = @('Bitte', 'Kopiere', 'Schluesselpaar', 'Ueberfluessige')
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
Write-GuiLog "GhettoGUI V6.8.5 (Direct Replication Fix) gestartet. Bitte ESXi-Daten eingeben und verbinden."
$form.ShowDialog() | Out-Null
