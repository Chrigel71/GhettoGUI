# GhettoGUI_V4.7.0.ps1
#
# --- VERSION V4.7.0 ---
# - NEU: Live-Monitor für Netzwerk-Traffic direkt im GUI.
#   - Liest beim Verbinden alle vmnics des Hosts aus.
#   - Zeigt nach Auswahl einer vmnic alle 5 Sek. die aktuellen Statistiken.
# - FIX: Master-Helper-Skript (V4.6.4) mit speziellem Diagnose-Schritt
#   für vmkfstools, um die genaue Fehlermeldung zu loggen.
# - GUI-Layout angepasst für das neue Traffic-Fenster.

# Diese Zeilen MÜSSEN ganz am Anfang stehen:
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Import-Module Posh-SSH -ErrorAction Stop

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
$form.Text = "ESXi & GhettoVCB Manager V4.7.0"
$form.Size = New-Object System.Drawing.Size(830, 850) # Breite angepasst
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

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
function Ensure-PoshSshModule { if (Get-Module Posh-SSH -ListAvailable) { Import-Module Posh-SSH -ErrorAction SilentlyContinue; return $true } else { Write-GuiLog "Posh-SSH nicht gefunden. Installationsversuch..."; $confirmInstall = [System.Windows.Forms.MessageBox]::Show("Das PowerShell-Modul 'Posh-SSH' wird benötigt und scheint nicht installiert zu sein.`n`nMöchten Sie es jetzt für den aktuellen Benutzer zu installieren? (Internetverbindung erforderlich)", "Posh-SSH Installation", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question); if ($confirmInstall -eq [System.Windows.Forms.DialogResult]::Yes) { try { Write-GuiLog "Führe 'Install-Module Posh-SSH -Scope CurrentUser -Force' aus..."; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; Install-Module Posh-SSH -Scope CurrentUser -Force -Confirm:$false -ErrorAction Stop; Write-GuiLog "Posh-SSH Installation angestoßen. Importiere Modul..."; Import-Module Posh-SSH; if (Get-Module Posh-SSH) { Write-GuiLog "Posh-SSH erfolgreich installiert und geladen!"; [System.Windows.Forms.MessageBox]::Show("Posh-SSH wurde erfolgreich installiert und geladen!", "Erfolg", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information); return $true } else { Write-GuiLog "Posh-SSH konnte nicht sofort geladen werden. Bitte GUI neu starten."; return $false } } catch { Write-GuiLog "FEHLER bei Installation: $($_.Exception.Message)"; [System.Windows.Forms.MessageBox]::Show("FEHLER bei der Installation von Posh-SSH:`n$($_.Exception.Message)`n`nStelle sicher, dass Internetverbindung besteht.", "Installationsfehler", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error); return $false } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default } } else { Write-GuiLog "Installation von Posh-SSH abgebrochen."; return $false } } }


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
$groupGhettoConfig = New-Object System.Windows.Forms.GroupBox; $groupGhettoConfig.Text = "GhettoVCB Konfiguration"; $groupGhettoConfig.Location = New-Object System.Drawing.Point($column1X, $currentY_Col1); $groupGhettoConfig.Size = New-Object System.Drawing.Size($column1Width, 370)
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
$gcOffsetY += 25
$labelDiskFormat = New-Object System.Windows.Forms.Label; $labelDiskFormat.Text = "Disk Format:"; $labelDiskFormat.Location = New-Object System.Drawing.Point($gcOffsetX, ($gcOffsetY + 3)); $labelDiskFormat.AutoSize = $true
$comboboxDiskFormat = New-Object System.Windows.Forms.ComboBox; $comboboxDiskFormat.Location = New-Object System.Drawing.Point($gcControlX, $gcOffsetY); $comboboxDiskFormat.Size = New-Object System.Drawing.Size(120, 21); $comboboxDiskFormat.DropDownStyle = "DropDownList"
$comboboxDiskFormat.Items.AddRange(@("thin", "zeroedthick", "eagerzeroedthick")); if ($comboboxDiskFormat.Items.Count -gt 0) { $comboboxDiskFormat.SelectedIndex = 0 }
$gcOffsetY += 25
$checkboxSnapMem = New-Object System.Windows.Forms.CheckBox; $checkboxSnapMem.Text = "Snap Memory"; $checkboxSnapMem.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $checkboxSnapMem.AutoSize = $true; $checkboxSnapMem.Checked = $true
$checkboxSnapQuiesce = New-Object System.Windows.Forms.CheckBox; $checkboxSnapQuiesce.Text = "Snap Quiesce"; $checkboxSnapQuiesce.Location = New-Object System.Drawing.Point(([int]$checkboxSnapMem.Location.X + [int]$checkboxSnapMem.Width + 15), $gcOffsetY); $checkboxSnapQuiesce.AutoSize = $true; $checkboxSnapQuiesce.Checked = $true

$buttonReplicate = New-Object System.Windows.Forms.Button
$buttonReplicate.Text = "Replication"
$buttonReplicate.Size = New-Object System.Drawing.Size(110, 25)
# Positioniere den Button rechts neben "Snap Quiesce"
$buttonReplicate.Location = New-Object System.Drawing.Point(($checkboxSnapQuiesce.Location.X + $checkboxSnapQuiesce.Width + 25), ($gcOffsetY - 1))
$buttonReplicate.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$buttonReplicate.ForeColor = [System.Drawing.Color]::DarkGreen

# --- NEUER BUTTON FÜR DIREKTE REPLIKATION ---
$buttonDirectReplicate = New-Object System.Windows.Forms.Button
$buttonDirectReplicate.Text = "Direkte Repl."
$buttonDirectReplicate.Size = New-Object System.Drawing.Size(110, 25)
# Positionierung oberhalb des alten Replication-Buttons
$buttonDirectReplicate.Location = New-Object System.Drawing.Point(260, 115)
$buttonDirectReplicate.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$buttonDirectReplicate.ForeColor = [System.Drawing.Color]::DarkBlue

$gcOffsetY += 30
$labelVmList = New-Object System.Windows.Forms.Label; $labelVmList.Text = "VMs (eine pro Zeile):"; $labelVmList.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $labelVmList.AutoSize = $true
$gcOffsetY += 20
$textboxVmList = New-Object System.Windows.Forms.TextBox; $textboxVmList.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $textboxVmList.Size = New-Object System.Drawing.Size(($groupGhettoConfig.Width - (2 * $gcOffsetX)), 60); $textboxVmList.Multiline = $true; $textboxVmList.ScrollBars = "Vertical"
$gcOffsetY += $textboxVmList.Height + 10
$buttonLoadVms = New-Object System.Windows.Forms.Button; $buttonLoadVms.Text = "VMs laden"; $buttonLoadVms.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $buttonLoadVms.Size = New-Object System.Drawing.Size(100, 25)
$buttonApplyVms = New-Object System.Windows.Forms.Button; $buttonApplyVms.Text = "Auswahl übernehmen"; $buttonApplyVms.Location = New-Object System.Drawing.Point(($gcOffsetX + [int]$buttonLoadVms.Width + 10), $gcOffsetY); $buttonApplyVms.Size = New-Object System.Drawing.Size(140, 25)
$gcOffsetY += $buttonLoadVms.Height + 5
$checkedListBoxVms = New-Object System.Windows.Forms.CheckedListBox; $checkedListBoxVms.DisplayMember = "DisplayName"; $checkedListBoxVms.Location = New-Object System.Drawing.Point($gcOffsetX, $gcOffsetY); $checkedListBoxVms.Size = New-Object System.Drawing.Size(($groupGhettoConfig.Width - (2 * $gcOffsetX)), 75); $checkedListBoxVms.CheckOnClick = $true

# ERSETZE DIE ALTE ZEILE MIT DIESER:
$groupGhettoConfig.Controls.AddRange(@($labelGhettoPath, $textboxGhettoPath, $buttonBrowseGhettoPath, $labelBackupVol, $textboxBackupVol, $buttonBrowseBackupVol, $labelSubfolder, $textboxSubfolder, $labelRotation, $textboxRotation, $labelDiskFormat, $comboboxDiskFormat, $checkboxSnapMem, $checkboxSnapQuiesce, $buttonReplicate, $buttonDirectReplicate, $labelVmList, $textboxVmList, $buttonLoadVms, $buttonApplyVms, $checkedListBoxVms))

$currentY_Col1 = $groupGhettoConfig.Location.Y + $groupGhettoConfig.Height + 10
$buttonLoadGuiSettings = New-Object System.Windows.Forms.Button; $buttonLoadGuiSettings.Text = "Einst. Host laden"; $buttonLoadGuiSettings.Location = New-Object System.Drawing.Point($column1X, $currentY_Col1); $buttonLoadGuiSettings.Size = New-Object System.Drawing.Size(185, 25); $buttonLoadGuiSettings.Enabled = $false
$buttonSaveGuiSettings = New-Object System.Windows.Forms.Button; $buttonSaveGuiSettings.Text = "Einst. Host speichern"; $buttonSaveGuiSettings.Location = New-Object System.Drawing.Point( ($buttonLoadGuiSettings.Location.X + $buttonLoadGuiSettings.Width + 5), $currentY_Col1); $buttonSaveGuiSettings.Size = New-Object System.Drawing.Size(185, 25); $buttonSaveGuiSettings.Enabled = $false
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

# --- Button für E-Mail-Skript (verkleinert) ---
$buttonInstallSendmailPy = New-Object System.Windows.Forms.Button
$buttonInstallSendmailPy.Text = "E-Mail-Skript installieren"
$buttonInstallSendmailPy.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2)
$buttonInstallSendmailPy.Size = New-Object System.Drawing.Size(200, 30)

# --- NEUER BUTTON FÜR SSH KONSOLE ---
$buttonOpenSshConsole = New-Object System.Windows.Forms.Button
$buttonOpenSshConsole.Text = "SSH-Konsole"
$buttonOpenSshConsole.Location = New-Object System.Drawing.Point( ([int]$buttonInstallSendmailPy.Location.X + [int]$buttonInstallSendmailPy.Width + 10), $currentY_Col2)
$buttonOpenSshConsole.Size = New-Object System.Drawing.Size(120, 30)
$buttonOpenSshConsole.ForeColor = [System.Drawing.Color]::DarkRed
$buttonOpenSshConsole.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$currentY_Col2 += $buttonInstallSendmailPy.Height + 10

# Block 2: Zeitplanung
$groupSchedule = New-Object System.Windows.Forms.GroupBox; $groupSchedule.Text = "Zeitplanung"; $groupSchedule.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $groupSchedule.Size = New-Object System.Drawing.Size($column2Width, 160)
[int]$schedulesGcOffsetX = 10; [int]$schedulesGcOffsetY = 20
$labelScheduleTime = New-Object System.Windows.Forms.Label; $labelScheduleTime.Text = "Uhrzeit (HH:MM):"; $yPosLabelTime = $schedulesGcOffsetY + 3; $labelScheduleTime.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, $yPosLabelTime); $labelScheduleTime.AutoSize = $true
$textboxScheduleHour = New-Object System.Windows.Forms.TextBox; $xPosHour = $schedulesGcOffsetX + 90; $textboxScheduleHour.Location = New-Object System.Drawing.Point($xPosHour, $schedulesGcOffsetY); $textboxScheduleHour.Size = New-Object System.Drawing.Size(30, 20); $textboxScheduleHour.MaxLength = 2; $textboxScheduleHour.Text = "02"
$labelScheduleSeparator = New-Object System.Windows.Forms.Label; $labelScheduleSeparator.Text = ":"; $labelScheduleSeparator.AutoSize = $false; $labelScheduleSeparator.Size = New-Object System.Drawing.Size(8, 23); $labelScheduleSeparator.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter; $xPosSeparator = $textboxScheduleHour.Right; $labelScheduleSeparator.Location = New-Object System.Drawing.Point($xPosSeparator, $schedulesGcOffsetY)
$textboxScheduleMinute = New-Object System.Windows.Forms.TextBox; $xPosMinute = $labelScheduleSeparator.Right; $textboxScheduleMinute.Location = New-Object System.Drawing.Point($xPosMinute, $schedulesGcOffsetY); $textboxScheduleMinute.Size = New-Object System.Drawing.Size(30, 20); $textboxScheduleMinute.MaxLength = 2; $textboxScheduleMinute.Text = "00"
$schedulesGcOffsetY += 30
$labelScheduleDays = New-Object System.Windows.Forms.Label; $labelScheduleDays.Text = "Tage:"; $labelScheduleDays.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, $schedulesGcOffsetY); $labelScheduleDays.AutoSize = $true
$checkboxDays = @{}; $days = @{ "Mo" = 1; "Di" = 2; "Mi" = 3; "Do" = 4; "Fr" = 5; "Sa" = 6; "So" = 0 }; $dayCheckboxX = $schedulesGcOffsetX + 40
foreach ($day in $days.GetEnumerator() | Sort-Object Value) { $dName = $day.Name; if ($day.Value -eq 0) { $dName = "So" }; $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $dName; $cb.Tag = $day.Value; $cb.Location = New-Object System.Drawing.Point($dayCheckboxX, $schedulesGcOffsetY); $cb.AutoSize = $true; $checkboxDays[$dName] = $cb; $dayCheckboxX += 43 }
$schedulesGcOffsetY += 25
# Radio-Buttons für die Auswahl des Zeitplan-Typs
$radioScheduleBackup = New-Object System.Windows.Forms.RadioButton; $radioScheduleBackup.Text = "Backup planen"; $radioScheduleBackup.Location = New-Object System.Drawing.Point(($schedulesGcOffsetX + 40), $schedulesGcOffsetY); $radioScheduleBackup.AutoSize = $true; $radioScheduleBackup.Checked = $true
$radioScheduleReplication = New-Object System.Windows.Forms.RadioButton; $radioScheduleReplication.Text = "Replikation planen"; $radioScheduleReplication.Location = New-Object System.Drawing.Point(($radioScheduleBackup.Right + 15), $schedulesGcOffsetY); $radioScheduleReplication.AutoSize = $true
$schedulesGcOffsetY += 30
$yPosStatusRow = $schedulesGcOffsetY
$labelUtcInfo = New-Object System.Windows.Forms.Label; $labelUtcInfo.Text = "(ESXi verwendet UTC-zeit!)"; $labelUtcInfo.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, ($yPosStatusRow + 4)); $labelUtcInfo.AutoSize = $true; $labelUtcInfo.ForeColor = [System.Drawing.Color]::DimGray
$labelEsxiTime = New-Object System.Windows.Forms.Label; $labelEsxiTime.Text = "ESXi nicht verbunden"; $labelEsxiTime.Location = New-Object System.Drawing.Point(($schedulesGcOffsetX + 155), ($yPosStatusRow + 4)); $labelEsxiTime.AutoSize = $true; $labelEsxiTime.ForeColor = [System.Drawing.Color]::Blue
$schedulesGcOffsetY += 25
$yPosButtonRow = $schedulesGcOffsetY
$buttonGetEsxiTime = New-Object System.Windows.Forms.Button; $buttonGetEsxiTime.Text = "ESXi-Zeit"; $buttonGetEsxiTime.Location = New-Object System.Drawing.Point($schedulesGcOffsetX, $yPosButtonRow); $buttonGetEsxiTime.Size = New-Object System.Drawing.Size(110, 23)
$buttonSaveSchedule = New-Object System.Windows.Forms.Button; $buttonSaveSchedule.Text = "Zeitplan speichern"; $buttonSaveSchedule.Location = New-Object System.Drawing.Point(($buttonGetEsxiTime.Right + 10), $yPosButtonRow); $buttonSaveSchedule.Size = New-Object System.Drawing.Size(150, 23)

# Diesen kompletten Block kopieren und die fehlerhaften Zeilen ersetzen

# 1. Erstelle eine leere Liste für die Steuerelemente
$allScheduleControls = New-Object System.Collections.ArrayList

# 2. Füge die Haupt-Steuerelemente hinzu (mit den neuen Radio-Buttons)
[void]$allScheduleControls.AddRange(@($labelScheduleTime, $textboxScheduleHour, $labelScheduleSeparator, $textboxScheduleMinute, $labelScheduleDays, $radioScheduleBackup, $radioScheduleReplication, $labelUtcInfo, $buttonSaveSchedule, $buttonGetEsxiTime, $labelEsxiTime))

# 3. Füge die Checkboxen für die Wochentage hinzu
[void]$allScheduleControls.AddRange($checkboxDays.Values)

# 4. Füge die komplette Liste aller Steuerelemente zur GroupBox "Zeitplanung" hinzu
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
$buttonStartBackup = New-Object System.Windows.Forms.Button; $buttonStartBackup.Text = "Backup jetzt starten"; $buttonStartBackup.Location = New-Object System.Drawing.Point($column2X, $currentY_Col2); $buttonStartBackup.Size = New-Object System.Drawing.Size(180, 25)
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

# Diesen kompletten Block kopieren und den alten Netzwerk-Monitor-Abschnitt ersetzen

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
            $divisor = 1000 * 750 

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
$replicationForm.Size = New-Object System.Drawing.Size(420, 260)
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

    ### HIER DIE NEUE ZEILE EINFÜGEN ###
    # Entfernt alle alten, eventuell hängengebliebenen Jobs für einen sauberen Start
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
            $sourceSession = New-SSHSession -ComputerName $p.SourceHost -Credential $p.SourceCredential -AcceptKey
            $targetSession = New-SSHSession -ComputerName $p.TargetHost -Credential $p.TargetCredential -AcceptKey
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
    if ($Global:replicationJob -and $Global:replicationJob.State -eq 'Running') {
        [System.Windows.Forms.MessageBox]::Show("Es läuft bereits ein Replikations-Job.", "Fehler", "OK", "Warning")
        return
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
# -- ######### # --- Definition des Direkte Replikation-Fensters --- Start #####

# -- Neues Replikations-Fenster (Direkt Host-zu-Host) --
$directReplicationForm = New-Object System.Windows.Forms.Form
$directReplicationForm.Text = "Direkte Host-zu-Host Replikation"
$directReplicationForm.Size = New-Object System.Drawing.Size(420, 280) # Höhe angepasst
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
$drCurrentY += 30

# --- NEU: Auswahl der Replikationsmethode ---
$groupRepMethod = New-Object System.Windows.Forms.GroupBox
$groupRepMethod.Text = "Replikationsmethode"
$groupRepMethod.Location = New-Object System.Drawing.Point(20, $drCurrentY)
$groupRepMethod.Size = New-Object System.Drawing.Size(365, 50)
$radioTar = New-Object System.Windows.Forms.RadioButton; $radioTar.Text = "TAR (stabil)"; $radioTar.Name = "radioTar"; $radioTar.Location = New-Object System.Drawing.Point(15, 20); $radioTar.AutoSize = $true; $radioTar.Checked = $true
$radioVmkf = New-Object System.Windows.Forms.RadioButton; $radioVmkf.Text = "VMKFSTOOLS (schnell)"; $radioVmkf.Name = "radioVmkf"; $radioVmkf.Location = New-Object System.Drawing.Point(180, 20); $radioVmkf.AutoSize = $true
$groupRepMethod.Controls.AddRange(@($radioTar, $radioVmkf))
$directReplicationForm.Controls.Add($groupRepMethod)
$drCurrentY += $groupRepMethod.Height + 10

$buttonStartDirectReplication = New-Object System.Windows.Forms.Button; $buttonStartDirectReplication.Text = "Replikation starten"; $buttonStartDirectReplication.DialogResult = [System.Windows.Forms.DialogResult]::OK; $buttonStartDirectReplication.Location = New-Object System.Drawing.Point(180, $drCurrentY); $buttonStartDirectReplication.Size = New-Object System.Drawing.Size(120, 25);
$buttonCancelDirectReplication = New-Object System.Windows.Forms.Button; $buttonCancelDirectReplication.Text = "Abbrechen"; $buttonCancelDirectReplication.Location = New-Object System.Drawing.Point(305, $drCurrentY); $buttonCancelDirectReplication.Size = New-Object System.Drawing.Size(75, 25); $buttonCancelDirectReplication.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$directReplicationForm.Controls.AddRange(@($buttonStartDirectReplication, $buttonCancelDirectReplication))
$directReplicationForm.AcceptButton = $buttonStartDirectReplication
$directReplicationForm.CancelButton = $buttonCancelDirectReplication

# --- Definition des neuen Dual-Pane SSH-Konsolen-Fensters (V3 mit manueller Eingabe) ---


# --- Definition des neuen Dual-Pane SSH-Konsolen-Fensters (V3 mit manueller Eingabe) ---

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
        $Global:sourceConsoleCredential = Get-Credential -UserName "root" -Message "Passwort für Quell-Host root@$ip eingeben"
        if(-not $Global:sourceConsoleCredential) { return }
        $Global:sourceConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:sourceConsoleCredential -AcceptKey
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
        $Global:targetConsoleCredential = Get-Credential -UserName "root" -Message "Passwort für Ziel-Host root@$ip eingeben"
        if(-not $Global:targetConsoleCredential) { return }
        $Global:targetConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:targetConsoleCredential -AcceptKey
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
    Write-ConsoleLog $sourceConsoleOutput "--- Suche und beende alle GhettoGUI Replikations-Prozesse (Aggressiv) ---" ([System.Drawing.Color]::Yellow)
    if (-not ($Global:sourceConsoleSession -and $Global:sourceConsoleSession.Connected)) {
        Write-ConsoleLog $sourceConsoleOutput "FEHLER: Keine Verbindung zum Quell-Host." ([System.Drawing.Color]::Red)
        return
    }
    
    # KORREKTUR: Sucht jetzt auch nach hängengebliebenen 'ssh'-Prozessen der Replikation
    $killScriptContent = @'
#!/bin/sh
PIDS_TO_KILL=$(ps | grep -E '[r]eplication_starter|[m]aster_replication|[t]ar -C|[s]sh -i /.ssh/id_ecdsa' | grep -v grep | awk '{print $1}')
if [ -n "$PIDS_TO_KILL" ]; then
    echo "Beende folgende Prozess-IDs: $PIDS_TO_KILL"
    kill -9 $PIDS_TO_KILL
    echo "Prozesse beendet."
else
    echo "Keine laufenden Replikations-Prozesse gefunden."
fi
'@

    $remoteScriptPath = "/tmp/ghetto_kill_all.sh"
    $sftpSession = $null
    try {
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -ErrorAction Stop
        Set-SFTPContent -SFTPSession $sftpSession -Path $remoteScriptPath -Value ($killScriptContent.Replace("`r`n", "`n"))
        $command = "chmod +x $remoteScriptPath && $remoteScriptPath && rm $remoteScriptPath"
        Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput
    } catch {
        Write-ConsoleLog $sourceConsoleOutput "FATALER FEHLER: $($_.Exception.Message)" ([System.Drawing.Color]::Red)
    } finally {
        if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession }
    }
})

# LOGIK FÜR DIE NEUEN CRON-BUTTONS
$buttonShowCronJobs.Add_Click({
    Write-ConsoleLog $sourceConsoleOutput "--- Zeige geplante Tasks (crontab) auf Quell-Host ---" ([System.Drawing.Color]::Yellow)
    $command = "cat -n /var/spool/cron/crontabs/root"
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
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -ErrorAction Stop
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
        $Global:sourceConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:sourceConsoleCredential -AcceptKey
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
        $Global:targetConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:targetConsoleCredential -AcceptKey
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

# LOGIK FÜR DIE NEUEN CRON-BUTTONS
$buttonShowCronJobs.Add_Click({
    Write-ConsoleLog $sourceConsoleOutput "--- Zeige geplante Tasks (crontab) auf Quell-Host ---" ([System.Drawing.Color]::Yellow)
    $command = "cat -n /var/spool/cron/crontabs/root"
    Invoke-DualConsoleCommand -session $Global:sourceConsoleSession -command $command -outputBox $sourceConsoleOutput
})
$buttonDeleteCronJob.Add_Click({
    $lineNumber = $textboxJobNumber.Text
    if (-not ($lineNumber -match '^\d+$' -and $lineNumber -ne '0')) { [System.Windows.Forms.MessageBox]::Show("Bitte eine gültige Zeilennummer (größer als 0) eingeben."); return }
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


# Schluss -----------


# Fängt das Schliessen des Fensters ab und versteckt es nur
$sshConsoleForm.Add_FormClosing({
    param($sender, $e)
    # Verhindert das endgültige Schliessen und Zerstören des Objekts
    $e.Cancel = $true
    # Versteckt das Fenster stattdessen
    $sender.Hide()
})

# --- LOGIK FÜR DAS DUAL-PANE-FENSTER (JETZT KORREKT GEORDNET) ---

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
$Global:sourceConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:sourceConsoleCredential -AcceptKey
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
$Global:targetConsoleSession = New-SSHSession -ComputerName $ip -Credential $Global:targetConsoleCredential -AcceptKey
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
# --- LOGIK FÜR DEN FINALEN, VOM BENUTZER ENTWORFENEN PROZESS ---
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
# --- END OF BLOCK TO COPY ---
# =====================================================================================


### EVENT HANDLER ###

$connectButton.Add_Click({
    Write-GuiLog "Verbindungsaufbau zu $($textboxIp.Text)...";
    if (Ensure-PoshSshModule) {
        try {
            $ErrorActionPreference = "Stop";
            if ($Global:ESXiSession -and $Global:ESXiSession.Connected) { Write-GuiLog "Bereits eine aktive Verbindung vorhanden."; return };
            $hostnameFromTextbox = $textboxIp.Text;
            if (-not $hostnameFromTextbox) { Write-GuiLog "Fehler: Host IP erforderlich."; return };
            $username = $textboxUser.Text;
            if (-not $username) { Write-GuiLog "Fehler: Benutzername erforderlich."; return };
            $localCredential = Get-Credential -UserName $username -Message "Passwort für $username@$hostnameFromTextbox eingeben:";
            if (-not $localCredential) { Write-GuiLog "Passworteingabe abgebrochen."; return };
            $Global:ESXiSshCredential = $localCredential;
            $Global:ESXiConnectedHostName = $hostnameFromTextbox;

            $Global:ESXiSession = New-SSHSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -ErrorAction Stop -AcceptKey

            if ($Global:ESXiSession.Connected) {
                Write-GuiLog "Erfolgreich verbunden mit $($Global:ESXiConnectedHostName)!";
                
				# NEU: Netzwerk-Interfaces laden
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
            Write-GuiLog "Fehler: $($_.Exception.Message)";
            if ($Global:ESXiSession) { Remove-SSHSession -SSHSession $Global:ESXiSession -EA 0 };
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

# Diesen kompletten Block kopieren und den alten ComboBox-Handler ersetzen

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


$buttonFirewallCheck.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "FEHLER: Für den Firewall-Check muss eine Verbindung zum ESXi-Host bestehen."; return }
    Write-GuiLog "Starte E-Mail Firewall-Check..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $fwResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network firewall ruleset list | grep -i smtps"
        $ruleLine = $fwResult.Output | Where-Object { $_ -match 'smtps' } | Select-Object -First 1
        
        if ($ruleLine -and $ruleLine -match 'true$') {
            Write-GuiLog "Firewall-Check: Regel 'smtps' ist bereits AKTIV. Sehr gut!"
            [System.Windows.Forms.MessageBox]::Show("Die ESXi-Firewall-Regel für SMTP ('smtps') ist bereits aktiv.", "Firewall-Check", "OK", "Information")
        } elseif ($ruleLine -and $ruleLine -match 'false$') {
            Write-GuiLog "Firewall-Check: Regel 'smtps' ist DEAKTIVIERT. Dies blockiert E-Mails."
            $confirmEnable = [System.Windows.Forms.MessageBox]::Show("Die ESXi-Firewall-Regel für SMTP ('smtps') ist deaktiviert.`n`nSoll die Regel jetzt aktiviert werden?", "Firewall-Problem gefunden", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($confirmEnable -eq [System.Windows.Forms.DialogResult]::Yes) {
                Write-GuiLog "Aktiviere Firewall-Regel 'smtps'..."
                Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "esxcli network firewall ruleset set --enabled true --ruleset-id=smtps" | Out-Null
                Write-GuiLog "Firewall-Regel erfolgreich aktiviert!"
                [System.Windows.Forms.MessageBox]::Show("Die Firewall-Regel wurde erfolgreich aktiviert.", "Erfolg", "OK", "Information")
            } else { Write-GuiLog "Firewall-Check: Benutzer hat die Aktivierung abgelehnt." }
        } else {
            Write-GuiLog "Firewall-Check: Standard-Regel 'smtps' nicht gefunden."
            $confirmCreate = [System.Windows.Forms.MessageBox]::Show("Die Standard-Firewall-Regel für E-Mail ('smtps') wurde auf Ihrem Host nicht gefunden.`n`nMöchten Sie jetzt eine neue, benutzerdefinierte Regel namens 'GhettoVCB-GUI-SMTP' erstellen, um den E-Mail-Versand zu erlauben?", "Firewall-Regel fehlt", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($confirmCreate -eq [System.Windows.Forms.DialogResult]::Yes) {
                Create-CustomFirewallRule
            } else { Write-GuiLog "Firewall-Check: Benutzer hat die Erstellung einer neuen Regel abgelehnt." }
        }
    } catch { Write-GuiLog "FEHLER beim Firewall-Check: $($_.Exception.Message)" } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
})


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
$buttonLoadGuiSettings.Add_Click({ Load-HostGuiSettings })
$buttonSaveGuiSettings.Add_Click({ Save-HostGuiSettings })
$buttonInstallGitHub.Add_Click({ Install-GhettoVCBFromGitHub })
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

# Diesen kompletten Block kopieren und die alte Funktion des Speicher-Buttons ersetzen

$buttonSaveSchedule.Add_Click({
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte zuerst mit dem ESXi-Host verbinden.", "Fehler", "OK", "Warning"); return
    }
    if ($radioScheduleReplication.Checked -and ([string]::IsNullOrWhiteSpace($textboxDrTargetHost.Text) -or [string]::IsNullOrWhiteSpace($textboxDrTargetDs.Text))) {
        [System.Windows.Forms.MessageBox]::Show("Für eine geplante Replikation müssen Ziel-Host und Zielspeicher konfiguriert sein.", "Fehlende Konfiguration", "OK", "Warning"); return
    }
    if ($radioScheduleReplication.Checked -and $checkedListBoxVms.CheckedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Für eine geplante Replikation muss mindestens eine VM ausgewählt sein.", "Keine VM ausgewählt", "OK", "Warning"); return
    }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
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
        
        if ($radioScheduleReplication.Checked) {
            Write-GuiLog "Erstelle autarkes Replikations-Skript (v15.2 - FINAL)..."
            $cronComment = "# GhettoGUI - Scheduled Replication (ID: $jobId)"
            $remoteStarterScriptPath = "$ghettoPath/replication_starter_$jobId.sh"
            
            $replTargetHost = $textboxDrTargetHost.Text; $replTargetDatastore = $textboxDrTargetDs.Text; $replVmSuffix = $textboxDrSuffix.Text
            $replMethod = if ($directReplicationForm.Controls.Find('radioVmkf', $true)[0].Checked) { "vmkfstools" } else { "tar" }
            $vmListForScript = ($checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }) -join [Environment]::NewLine
            
            $emailEnabled = if ($checkboxEmailLog.Checked) { "1" } else { "0" }
            $emailTo = $textboxEmailTo.Text; $emailFrom = $textboxEmailFrom.Text; $emailServer = $textboxEmailServer.Text; $emailPort = $textboxEmailPort.Text
            $emailUser = $textboxEmailUser.Text; $emailPass = $textboxEmailPassword.Text
            $emailSubject = "[Replication] " + $textboxEmailSubject.Text.Replace('%h', $Global:ESXiConnectedHostName)

            $starterScriptTemplate = @'
#!/bin/sh
# GhettoGUI - AUTARKES Replikations-Skript v15.2 (tar-Fix)
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin

# ====================================================================
REPL_TARGET_HOST="__REPL_TARGET_HOST__"
REPL_TARGET_DATASTORE="__REPL_TARGET_DATASTORE__"
REPL_VM_SUFFIX="__REPL_VM_SUFFIX__"
REPL_METHOD="__REPL_METHOD__"
LOG_DIR="__GHETTO_PATH__/logs"
VM_LIST="
__VM_LIST__
"
EMAIL_ENABLED="__EMAIL_ENABLED__"
EMAIL_TO="__EMAIL_TO__"
EMAIL_FROM="__EMAIL_FROM__"
EMAIL_SERVER="__EMAIL_SERVER__"
EMAIL_PORT="__EMAIL_PORT__"
EMAIL_USER="__EMAIL_USER__"
EMAIL_PASS="__EMAIL_PASS__"
EMAIL_SUBJECT="__EMAIL_SUBJECT__"
SENDMAIL_PATH="__GHETTO_PATH__/sendmail"
# ====================================================================

RUN_LOG_FILE="$LOG_DIR/replication-run-__JOB_ID__.log"

log_action() { /bin/echo "$(/bin/date +'%Y-%m-%d %T') -- $1" >> "$RUN_LOG_FILE"; }
/bin/mkdir -p "$LOG_DIR"
/bin/echo "===================================================" > "$RUN_LOG_FILE"
log_action "Autarkes Replikations-Skript gestartet (ID: __JOB_ID__)"
log_action "Ziel: $REPL_TARGET_HOST -> $REPL_TARGET_DATASTORE, Methode: $REPL_METHOD"
/bin/echo "===================================================" >> "$RUN_LOG_FILE"

for vm in $VM_LIST; do
    SOURCE_VM_NAME="$vm"; if [ -z "$SOURCE_VM_NAME" ]; then continue; fi
    log_action "--- Verarbeitung für '$SOURCE_VM_NAME' wird gestartet ---"
    VMID=$(/bin/vim-cmd vmsvc/getallvms | /bin/grep -w "\[.*\] $SOURCE_VM_NAME/.*\.vmx" | /bin/awk '{print $1}')
    if [ -z "$VMID" ]; then log_action "FEHLER: VMID für '$SOURCE_VM_NAME' konnte nicht gefunden werden."; continue; fi
    VMX_PATH_RAW=$(/bin/vim-cmd vmsvc/get.summary $VMID | /bin/grep 'vmxPath' | /bin/sed -n 's/.*"\(.*\)".*/\1/p')
    VMX_FULL_PATH="/vmfs/volumes/$VMX_PATH_RAW"
    VMX_DIR=$(/bin/dirname "$VMX_FULL_PATH"); VMX_FILE=$(/bin/basename "$VMX_FULL_PATH")
    log_action "[1/7] VM-Details gefunden: ID=$VMID, VMX=$VMX_FULL_PATH"
    log_action "[2/7] Erstelle Snapshot..."; /bin/vim-cmd vmsvc/snapshot.create "$VMID" "ghetto_cron_repl_$(/bin/date +%s)" "" 0 0 >> "$RUN_LOG_FILE" 2>&1; if [ $? -ne 0 ]; then log_action "FEHLER: Snapshot konnte nicht erstellt werden."; continue; fi
    REPLICATED_VM_NAME="$SOURCE_VM_NAME$REPL_VM_SUFFIX"; TARGET_VM_PATH="$REPL_TARGET_DATASTORE/$REPLICATED_VM_NAME"
    log_action "[3/7] Erstelle Zielverzeichnis: $TARGET_VM_PATH"; /bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REPL_TARGET_HOST" "/bin/rm -rf \"$TARGET_VM_PATH\"; /bin/mkdir -p \"$TARGET_VM_PATH\"" >> "$RUN_LOG_FILE" 2>&1
    log_action "[4/7] Kopiere VM-Dateien via $REPL_METHOD..."; COPY_SUCCESS=0
    if [ "$REPL_METHOD" = "vmkfstools" ]; then
        TEMP_CLONE_DIR="$VMX_DIR/ghetto_clone_$(/bin/date +%s)"; /bin/mkdir -p "$TEMP_CLONE_DIR"
        /bin/grep -iE '^(scsi|ide|sata|nvme).*\.fileName' "$VMX_FULL_PATH" | while IFS= read -r line; do DISK_FILE_NAME=$(/bin/echo "$line" | /bin/sed -n 's/.*"\(.*\.vmdk\)".*/\1/p'); if [ -z "$DISK_FILE_NAME" ]; then continue; fi; SOURCE_DISK_PATH="$VMX_DIR/$DISK_FILE_NAME"; TEMP_CLONE_DISK_NAME="$DISK_FILE_NAME"; TEMP_CLONE_DISK_PATH="$TEMP_CLONE_DIR/$TEMP_CLONE_DISK_NAME"; log_action "    -> Klone lokal: $SOURCE_DISK_PATH"; /sbin/vmkfstools -i "$SOURCE_DISK_PATH" -d thin "$TEMP_CLONE_DISK_PATH" >> "$RUN_LOG_FILE" 2>&1; done
        /bin/find "$VMX_DIR" -maxdepth 1 ! -name '*.vmdk' -exec /bin/cp -p '{}' "$TEMP_CLONE_DIR/" \;;
        # KORREKTUR: Sicherer tar-Befehl in einer Sub-Shell
        log_action "  -> Übertrage Klon-Verzeichnis via tar"; (cd "$TEMP_CLONE_DIR" && /bin/tar -cf - .) | /bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REPL_TARGET_HOST" "/bin/tar -xf - -C \"$TARGET_VM_PATH\"" >> "$RUN_LOG_FILE" 2>&1 && COPY_SUCCESS=1
        /bin/rm -rf "$TEMP_CLONE_DIR"
    else
        # KORREKTUR: Sicherer tar-Befehl in einer Sub-Shell
        log_action "  -> Methode: tar"; (cd "$VMX_DIR" && /bin/tar -cf - .) | /bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REPL_TARGET_HOST" "/bin/tar -xf - -C \"$TARGET_VM_PATH\"" >> "$RUN_LOG_FILE" 2>&1 && COPY_SUCCESS=1
    fi
    log_action "[5/7] Entferne Snapshot..."; /bin/vim-cmd vmsvc/snapshot.removeall "$VMID" >> "$RUN_LOG_FILE" 2>&1
    if [ "$COPY_SUCCESS" -ne 1 ]; then log_action "FEHLER: Kopiervorgang war nicht erfolgreich. Breche für diese VM ab."; continue; fi
    log_action "[6/7] Erstelle und kopiere Umbenennungs-Skript..."; RENAME_SCRIPT_PATH="/tmp/ghetto_rename_\$\$.sh";
    /bin/cat > "\$RENAME_SCRIPT_PATH" << EOF
#!/bin/sh
set -e
cd "$TARGET_VM_PATH"
ORIG_BASENAME=\$(/bin/basename "$VMX_FILE" .vmx)
for f in "\$ORIG_BASENAME".*; do
    new_name=\$(/bin/echo "\$f" | /bin/sed "s/\$ORIG_BASENAME/$REPLICATED_VM_NAME/")
    /bin/mv -- "\$f" "\$new_name"
done
RENAMED_VMX_FILE="$REPLICATED_VM_NAME.vmx"
/bin/sed -i -e "s/displayName = .*/displayName = \\\"\$REPLICATED_VM_NAME\\\"/" -e "s/\$ORIG_BASENAME\\.vmdk/\$REPLICATED_VM_NAME.vmdk/g" -e "s/\$ORIG_BASENAME\\.nvram/\$REPLICATED_VM_NAME.nvram/g" "\$RENAMED_VMX_FILE"
EOF
    /bin/scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "\$RENAME_SCRIPT_PATH" root@"$REPL_TARGET_HOST":/tmp/ >> "$RUN_LOG_FILE" 2>&1
    /bin/rm "\$RENAME_SCRIPT_PATH"
    log_action "  -> Führe Umbenennungs-Skript aus..."; /bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REPL_TARGET_HOST" "/bin/sh /tmp/\$(/bin/basename \$RENAME_SCRIPT_PATH) && /bin/rm /tmp/\$(/bin/basename \$RENAME_SCRIPT_PATH)" >> "$RUN_LOG_FILE" 2>&1
    log_action "[7/7] Registriere VM..."; /bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REPL_TARGET_HOST" "/bin/vim-cmd solo/registervm \"$TARGET_VM_PATH/\$REPLICATED_VM_NAME.vmx\"" >> "$RUN_LOG_FILE" 2>&1
    log_action "--- Verarbeitung für '$SOURCE_VM_NAME' ERFOLGREICH ---"
done
log_action "Prüfe, ob E-Mail-Benachrichtigung gesendet werden soll..."
if [ "$EMAIL_ENABLED" = "1" ]; then
    if [ -f "$SENDMAIL_PATH" ]; then
        log_action "Sende E-Mail-Benachrichtigung an: $EMAIL_TO"
        CMD="$SENDMAIL_PATH -t \"$EMAIL_TO\" -f \"$EMAIL_FROM\" -s \"$EMAIL_SERVER:$EMAIL_PORT\" -j \"$EMAIL_SUBJECT\" -m \"$RUN_LOG_FILE\""; if [ -n "$EMAIL_USER" ]; then CMD="\$CMD -u \"\$EMAIL_USER\" -p \"\$EMAIL_PASS\""; fi
        \$CMD >> "\$RUN_LOG_FILE" 2>&1; log_action "E-Mail-Befehl ausgeführt."
    else log_action "FEHLER: sendmail-Skript unter \$SENDMAIL_PATH nicht gefunden."; fi
else log_action "E-Mail-Benachrichtigung ist deaktiviert."; fi
log_action "Scheduled Replication Run Finished"
'@
            
            $starterScriptContent = $starterScriptTemplate.Replace('__JOB_ID__', $jobId).Replace('__GHETTO_PATH__', $ghettoPath).Replace('__REPL_TARGET_HOST__', $replTargetHost).Replace('__REPL_TARGET_DATASTORE__', $replTargetDatastore).Replace('__REPL_VM_SUFFIX__', $replVmSuffix).Replace('__REPL_METHOD__', $replMethod).Replace('__VM_LIST__', $vmListForScript).Replace('__EMAIL_ENABLED__', $emailEnabled).Replace('__EMAIL_TO__', $emailTo).Replace('__EMAIL_FROM__', $emailFrom).Replace('__EMAIL_SERVER__', $emailServer).Replace('__EMAIL_PORT__', $emailPort).Replace('__EMAIL_USER__', $emailUser).Replace('__EMAIL_PASS__', $emailPass).Replace('__EMAIL_SUBJECT__', $emailSubject)
            $cronCommand = "$scheduleMinute $scheduleHour * * $selectedDays $remoteStarterScriptPath"

        } else { # Backup-Logik
            Write-GuiLog "Erstelle EINDEUTIGEN Backup-Job (ID: $jobId)..."
            $cronComment = "# GhettoGUI - Scheduled Backup (ID: $jobId)"
            Save-GhettoVCBConfig | Out-Null; $remoteGhettoConf = "$ghettoPath/ghettoVCB.conf"; $remoteVmListFile = "$ghettoPath/vms_to_backup.txt"
            $remoteGhettoScript = "$ghettoPath/ghettoVCB.sh"; $remoteLogFile = "$ghettoPath/logs/backup-run-$jobId.log"
            $remoteStarterScriptPath = "$remoteGhettoScript -f $remoteVmListFile -g $remoteGhettoConf -l $remoteLogFile"
            $cronCommand = "$scheduleMinute $scheduleHour * * $selectedDays $remoteStarterScriptPath"
        }
        
        $fullCronEntry = "$cronCommand $cronComment"
        
        if ($radioScheduleReplication.Checked) {
            $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential
            try {
                Set-SFTPContent -SFTPSession $sftpSession -Path $remoteStarterScriptPath -Value ($starterScriptContent.Replace("`r`n", "`n"))
                Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$remoteStarterScriptPath'"
            } finally {
                if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession }
            }
        }

        Write-GuiLog "Füge neuen Task zum Zeitplan hinzu: $fullCronEntry"
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "echo `"$fullCronEntry`" >> /var/spool/cron/crontabs/root"
        Write-GuiLog "Lade Cron-Dienst neu..."; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command 'kill $(cat /var/run/crond.pid) && crond'
        Write-GuiLog "Neuer Task erfolgreich zum Zeitplan hinzugefügt!"
        [System.Windows.Forms.MessageBox]::Show("Ein neuer Task wurde erfolgreich zum Zeitplan hinzugefügt.`nVerwende die SSH-Konsole, um alte Tasks bei Bedarf zu löschen.", "Erfolg", "OK", "Information")

    } catch {
        Write-GuiLog "FEHLER beim Speichern des Zeitplans: $($_.Exception.Message)"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})
# ---------------------------------------------------------------------------------

$buttonReplicate.Add_Click({
    # Vorerst öffnet der Button nur das neue Fenster.
    # Die Logik für die Replikation fügen wir im nächsten Schritt hinzu.
    $replicationForm.ShowDialog($form) | Out-Null
})


# --- Event-Handler für "..." Button im DIREKTEN Replikations-Fenster ---
$buttonBrowseDrTargetDs.Add_Click({
    # Hole Hostname und User aus den Textboxen des direkten Fensters
    $targetHost = $textboxDrTargetHost.Text
    $targetUser = $textboxDrTargetUser.Text

    # Prüfung, ob die Felder ausgefüllt sind
    if ([string]::IsNullOrWhiteSpace($targetHost) -or [string]::IsNullOrWhiteSpace($targetUser)) {
        [System.Windows.Forms.MessageBox]::Show("Bitte geben Sie zuerst die IP und den User des Ziel-Hosts an.", "Fehlende Eingabe", "OK", "Warning")
        return
    }

    # Prüfen, ob bereits eine passende Verbindung zum Ziel-Host besteht
    if (-not ($Global:TargetESXiSession -and $Global:TargetESXiSession.Connected -and $Global:TargetESXiSession.ComputerName -eq $targetHost)) {
        # Falls eine alte, unpassende Verbindung besteht, diese zuerst trennen
        if ($Global:TargetESXiSession) { Remove-SSHSession -SSHSession $Global:TargetESXiSession -ErrorAction SilentlyContinue }

        Write-GuiLog "Stelle temporäre Verbindung zum Ziel-Host $targetHost her, um Datastores zu durchsuchen..."
        try {
            # Passwort abfragen
            $targetCredential = Get-Credential -UserName $targetUser -Message "Passwort für Ziel-Host $targetUser@$targetHost eingeben:"
            if (-not $targetCredential) { Write-GuiLog "Passworteingabe für Ziel-Host abgebrochen."; return }

            # Wir speichern die Anmeldeinformationen global, damit der Replikations-Job sie später nutzen kann
            $Global:TargetESXiSshCredential = $targetCredential

            # Neue Verbindung aufbauen
            $Global:TargetESXiSession = New-SSHSession -ComputerName $targetHost -Credential $targetCredential -ErrorAction Stop -AcceptKey

            if ($Global:TargetESXiSession.Connected) {
                Write-GuiLog "Verbindung zum Ziel-Host für Datastore-Suche erfolgreich."
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

    # Den Dialog zur Datastore-Auswahl mit der Ziel-Session aufrufen
    $selectedPath = Show-DatastoreSelectionDialog -SSHSession $Global:TargetESXiSession

    # Den ausgewählten Pfad in die NEUE Textbox eintragen
    if ($selectedPath) {
        $textboxDrTargetDs.Text = $selectedPath
    }
})

# =====================================================================================

# =====================================================================================
# --- START OF Direkte Replikation BLOCK TO COPY (V1.1.3.0. ) ---
# --- TAR Replikation, zeigt den Fortschritt mit GB 
# --- vmfstools Replikation noch im Test über Lokale Temp Datei
# =====================================================================================

# =====================================================================================
# --- START BLOCK (NEUE FUNKTION) ---
# =====================================================================================
function Start-ReplicationForVM {
    param(
        [string]$VMName
    )

    Write-GuiLog "Starte nächsten Job in der Warteschlange: '$($VMName)'."
    Write-GuiLog "Verbleibend in Schlange: $($Global:ReplicationQueue.Count)."

    $uniqueId = "{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Minimum 100 -Maximum 999)
    $params = @{
        UniqueId          = $uniqueId; SourceVmName = $VMName; SourceHost = $Global:ESXiConnectedHostName;
        TargetHost        = $textboxDrTargetHost.Text; TargetDatastore = $textboxDrTargetDs.Text; Suffix = $textboxDrSuffix.Text;
        ReplicationMethod = if ($directReplicationForm.Controls.Find('radioTar', $true)[0].Checked) { "tar" } else { "vmkfstools" };
        SnapMem           = if ($checkboxSnapMem.Checked) { 1 } else { 0 }; SnapQuiesce = if ($checkboxSnapQuiesce.Checked) { 1 } else { 0 }
    }

    # Das stabile Shell-Skript aus unserer finalen Einzel-VM-Version
    $masterHelperScriptTemplate = @'
#!/bin/sh
# GhettoGUI Master Replication Helper V3.1.0 (Konsolidierungs-Fix)
set -o pipefail
# -- KONFIGURATION --
UNIQUE_ID='__UNIQUE_ID__'
SOURCE_VM_NAME='__SOURCE_VM_NAME__'
TARGET_HOST='__TARGET_HOST__'
TARGET_DATASTORE='__TARGET_DATASTORE__'
VM_SUFFIX='__VM_SUFFIX__'
REPLICATION_METHOD='__REPLICATION_METHOD__'
SNAP_MEM=__SNAP_MEM__
SNAP_QUIESCE=__SNAP_QUIESCE__
# -- GLOBALE VARIABLEN --
REPLICATED_VM_NAME="${SOURCE_VM_NAME}${VM_SUFFIX}"
LOG_FILE="/tmp/master_replication_${UNIQUE_ID}.log"
SSH_OPTIONS="-i /.ssh/id_ecdsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20"
# -- LOGGING-FUNKTION --
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') -- $1" >> ${LOG_FILE}; }
# -- TRAP für Fehler und Aufräumarbeiten --
cleanup() {
    EXIT_CODE=$?
    log "INFO: Aufräumarbeiten werden mit Exit-Code ${EXIT_CODE} ausgeführt..."
    ssh ${SSH_OPTIONS} root@${TARGET_HOST} "rm -f /tmp/ghetto_repl_${UNIQUE_ID}_done.flag" 2>/dev/null
    if [ -n "${VMID}" ]; then log "INFO: Entferne eventuellen Snapshot von VMID ${VMID}..."; vim-cmd vmsvc/snapshot.removeall ${VMID} >> ${LOG_FILE} 2>&1; fi
    log "====== MASTER REPLICATION HELPER BEENDET (ID: ${UNIQUE_ID}) ======"
}
trap cleanup EXIT
# -- HAUPTPROGRAMM --
rm -f ${LOG_FILE}
log "====== MASTER REPLICATION HELPER GESTARTET (ID: ${UNIQUE_ID}) ======"
log "VM: ${SOURCE_VM_NAME}"; log "Ziel: ${TARGET_HOST} -> ${TARGET_DATASTORE}"; log "Methode: ${REPLICATION_METHOD}"
log "[1/10] Finde VMID und VMX-Pfad..."; VM_INFO_LINE=$(vim-cmd vmsvc/getallvms | grep -w "${SOURCE_VM_NAME}"); if [ -z "${VM_INFO_LINE}" ]; then log "FEHLER: VM '${SOURCE_VM_NAME}' nicht gefunden!"; exit 1; fi; VMID=$(echo ${VM_INFO_LINE} | awk '{print $1}'); VMX_FULL_PATH=$(echo ${VM_INFO_LINE} | sed -e 's/.*\[\(.*\)\]\s*\(.*\.vmx\).*/\/vmfs\/volumes\/\1\/\2/'); VMX_DIR=$(dirname "${VMX_FULL_PATH}"); log "  -> OK: VMID=${VMID}, VMX_DIR=${VMX_DIR}";
log "[2/10] Erstelle Snapshot..."; vim-cmd vmsvc/snapshot.create ${VMID} "ghetto-repl-${UNIQUE_ID}" "GhettoGUI Replication" ${SNAP_MEM} ${SNAP_QUIESCE} >> ${LOG_FILE} 2>&1; sleep 5
log "[3/10] Erstelle Zielverzeichnis..."; TARGET_VM_PATH="${TARGET_DATASTORE}/${REPLICATED_VM_NAME}"; ssh ${SSH_OPTIONS} root@${TARGET_HOST} "rm -rf '${TARGET_VM_PATH}'; mkdir -p '${TARGET_VM_PATH}'"; if [ $? -ne 0 ]; then log "FEHLER: Konnte Zielverzeichnis auf ${TARGET_HOST} nicht erstellen!"; exit 1; fi; log "  -> OK: Zielverzeichnis bereit.";
(
    log "[4/10] Starte Datentransfer...";
    if [ "${REPLICATION_METHOD}" = "tar" ]; then
        tar -C "${VMX_DIR}" -cf - . | ssh ${SSH_OPTIONS} root@${TARGET_HOST} "tar -xf - -C '${TARGET_VM_PATH}'"
    else
        TEMP_CLONE_DIR="${VMX_DIR}/ghetto_clone_${UNIQUE_ID}"; mkdir -p "${TEMP_CLONE_DIR}";
        DISK_LIST=$(grep -iE '(\.vmdk)' "${VMX_FULL_PATH}" | grep -iE '(^scsi|^ide|^sata|^nvme)');
        for line in ${DISK_LIST}; do
            DISK_FILE_NAME=$(echo "$line" | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p'); if [ -z "${DISK_FILE_NAME}" ]; then continue; fi;
            SOURCE_DISK_PATH="${VMX_DIR}/${DISK_FILE_NAME}"; TEMP_CLONE_DISK_NAME=$(echo "${DISK_FILE_NAME}" | sed 's/-[0-9]\{6\}\.vmdk/\.vmdk/'); TEMP_CLONE_DISK_PATH="${TEMP_CLONE_DIR}/${TEMP_CLONE_DISK_NAME}";
            log "    -> Klone lokal: ${SOURCE_DISK_PATH}"; vmkfstools -i "${SOURCE_DISK_PATH}" -d thin "${TEMP_CLONE_DISK_PATH}" >> "${LOG_FILE}" 2>&1;
        done;
        cd "${VMX_DIR}" || exit; find . -maxdepth 1 ! -name '*.vmdk' -exec cp -p '{}' "${TEMP_CLONE_DIR}/" \;;
        cd "${TEMP_CLONE_DIR}" || exit; tar -cf - . | ssh ${SSH_OPTIONS} root@${TARGET_HOST} "tar -xf - -C '${TARGET_VM_PATH}'";
        rm -rf "${TEMP_CLONE_DIR}";
    fi;
    ssh ${SSH_OPTIONS} root@${TARGET_HOST} "touch /tmp/ghetto_repl_${UNIQUE_ID}_done.flag"
) &
log "[5/10] Überwache Netzwerktransfer..."; SOURCE_SIZE=$(du -sh "${VMX_DIR}" | awk '{print $1}');
while ! ssh ${SSH_OPTIONS} root@${TARGET_HOST} "[ -f /tmp/ghetto_repl_${UNIQUE_ID}_done.flag ]"; do
    progress=$(ssh ${SSH_OPTIONS} root@${TARGET_HOST} "du -sh '${TARGET_VM_PATH}' 2>/dev/null | awk '{print \$1}'");
    if [ -n "${progress}" ]; then log " -> ${progress} von ~${SOURCE_SIZE} "; fi;
    sleep 15;
done; log "  -> OK: Datentransfer erfolgreich."
log "[6/10] Lösche Snapshot..."; vim-cmd vmsvc/snapshot.removeall ${VMID} >> ${LOG_FILE} 2>&1;
log "[7/10] Passe VMX-Datei auf Ziel-Host an..."; ssh ${SSH_OPTIONS} root@${TARGET_HOST} /bin/sh << 'EOF_VMX'
set -e; cd "__TARGET_VM_PATH__";
ORIGINAL_VMX_FILE=$(find . -maxdepth 1 -name "*.vmx");
ORIGINAL_VMDK_IN_VMX=$(cat "${ORIGINAL_VMX_FILE}" | grep -iE '^scsi.*\.fileName' | sed -n 's/.*"\(.*\.vmdk\)".*/\1/p' | head -n 1)
TRANSFERRED_VMDK_ON_DISK=$(find . -maxdepth 1 -name "*.vmdk" ! -name "*-flat.vmdk")
ORIGINAL_NVRAM_FILE=$(find . -maxdepth 1 -name "*.nvram");
mv -- "${ORIGINAL_VMX_FILE}" "./__REPLICATED_VM_NAME__.vmx";
if [ -f "${ORIGINAL_NVRAM_FILE}" ]; then mv -- "${ORIGINAL_NVRAM_FILE}" "./__REPLICATED_VM_NAME__.nvram"; fi;
TARGET_VMX_FILE="./__REPLICATED_VM_NAME__.vmx"; TEMP_VMX_FILE="${TARGET_VMX_FILE}.tmp";
cat "${TARGET_VMX_FILE}" | sed \
    -e "s/displayName = .*/displayName = \"__REPLICATED_VM_NAME__\"/" \
    -e "s/nvram = .*/nvram = \"__REPLICATED_VM_NAME__.nvram\"/" \
    -e "s/\"${ORIGINAL_VMDK_IN_VMX}\"/\"${TRANSFERRED_VMDK_ON_DISK##*/}\"/" \
    -e '/snapshot\./d' -e '/\.latest/d' -e '/sched\.swap\.derivedName/d' -e '/uuid\./d' -e '/vc\.uuid/d' \
    -e '/ethernet[0-9]\+\.generatedAddress/d' -e "s/ethernet[0-9]\+\.addressType = \"vpx\"/ethernet0.addressType = \"static\"/" > "${TEMP_VMX_FILE}";
mv "${TEMP_VMX_FILE}" "${TARGET_VMX_FILE}";
EOF_VMX
log "  -> OK: VMX-Anpassung abgeschlossen."
log "[8/10] Registriere VM..."; TARGET_VMX_PATH_ON_TARGET="${TARGET_VM_PATH}/__REPLICATED_VM_NAME__.vmx";
REG_OUTPUT=$(ssh ${SSH_OPTIONS} root@${TARGET_HOST} "vim-cmd solo/registervm '${TARGET_VMX_PATH_ON_TARGET}'"); log "  -> OK: VM registriert mit ID: $REG_OUTPUT";
log "[9/10] Prüfe und führe Konsolidierung auf Ziel-VM aus..."; NEW_VMID=$(echo $REG_OUTPUT);
if [ -n "$NEW_VMID" ]; then
    NEEDS_CONSOLIDATION=$(ssh ${SSH_OPTIONS} root@${TARGET_HOST} "vim-cmd vmsvc/get.needssnapshotconsolidation ${NEW_VMID}" | tail -n 1 | tr -d "'[:space:]")
    if [ "${NEEDS_CONSOLIDATION}" = "1" ] || [ "${NEEDS_CONSOLIDATION}" = "true" ]; then
        log "  -> Konsolidierung wird benötigt. Starte Task...";
        ssh ${SSH_OPTIONS} root@${TARGET_HOST} "vim-cmd vmsvc/snapshot.consolidate ${NEW_VMID}" >> ${LOG_FILE} 2>&1
        log "  -> Konsolidierungs-Task gestartet."
    else
        log "  -> Keine Konsolidierung notwendig."
    fi
fi
log "[10/10] REPLIKATION ERFOLGREICH ABGESCHLOSSEN!";
exit 0
'@
    
    $finalMasterScript = $masterHelperScriptTemplate -replace '__UNIQUE_ID__', $params.UniqueId -replace '__SOURCE_VM_NAME__', $params.SourceVmName -replace '__TARGET_HOST__', $params.TargetHost -replace '__TARGET_DATASTORE__', $params.TargetDatastore -replace '__VM_SUFFIX__', $params.Suffix -replace '__REPLICATION_METHOD__', $params.ReplicationMethod -replace '__SNAP_MEM__', $params.SnapMem -replace '__SNAP_QUIESCE__', $params.SnapQuiesce -replace '__TARGET_VM_PATH__', "$($params.TargetDatastore)/$($params.SourceVmName)$($params.Suffix)" -replace '__REPLICATED_VM_NAME__', "$($params.SourceVmName)$($params.Suffix)"
    
    $sftpSession = $null
    try {
        $remoteHelperPath = "/tmp/master_replication_$($params.UniqueId).sh"; $launcherScriptPath = "/tmp/launcher_$($params.UniqueId).sh"
        $unixHelperScript = $finalMasterScript.Replace("`r`n", "`n"); $sftpSession = New-SFTPSession -ComputerName $params.SourceHost -Credential $Global:ESXiSshCredential -AcceptKey
        Set-SFTPContent -SFTPSession $sftpSession -Path $remoteHelperPath -Value $unixHelperScript -Encoding UTF8; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$remoteHelperPath'" | Out-Null
        $launcherContent = "#!/bin/sh`nnohup sh '$remoteHelperPath' &"; Set-SFTPContent -SFTPSession $sftpSession -Path $launcherScriptPath -Value $launcherContent -Encoding UTF8
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$launcherScriptPath'" | Out-Null
    } catch { [System.Windows.Forms.MessageBox]::Show("Fehler beim Hochladen der Skripte: $($_.Exception.Message)", "Upload-Fehler", "OK", "Error"); return } finally { if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession } }
    
    $startCommand = "sh '$launcherScriptPath'"; try { Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $startCommand -ErrorAction Stop } catch [System.Management.Automation.MethodInvocationException] { Write-GuiLog "-> INFO: Erwarteter Posh-SSH-Timeout. Das ist normal." }
    
    # --- Hier ist der Workaround mit dem Klartext-Passwort ---
    $plainTextPassword = $Global:ESXiSshCredential.GetNetworkCredential().Password
    $jobParamsForWatcher = @{ Host = $params.SourceHost; Username = $Global:ESXiSshCredential.UserName; PlainTextPassword = $plainTextPassword; RemoteLogPath = "/tmp/master_replication_$($params.UniqueId).log" }
    
    $Global:replicationJob = Start-Job -ScriptBlock { 
        param($p)
        Import-Module Posh-SSH -ErrorAction SilentlyContinue
        $securePassword = ConvertTo-SecureString $p.PlainTextPassword -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($p.Username, $securePassword)
        $watcherSession = $null
        try {
            Start-Sleep -Seconds 2
            $watcherSession = New-SSHSession -ComputerName $p.Host -Credential $cred -AcceptKey
            if (-not $watcherSession.Connected) { Write-Output "FEHLER: Watcher-Job konnte keine SSH-Verbindung herstellen."; return }
            $lastLineNumber = 0; $timeout = (Get-Date).AddHours(24)
            while ((Get-Date) -lt $timeout) {
                Start-Sleep -Seconds 5
                $checkFileCmd = "if [ -f '$($p.RemoteLogPath)' ]; then echo 'EXISTS'; fi"
                $fileExists = (Invoke-SSHCommand -SSHSession $watcherSession -Command $checkFileCmd).Output -join ''
                if ($fileExists -eq 'EXISTS') {
                    $getNewLinesCmd = "tail -n +$($lastLineNumber + 1) '$($p.RemoteLogPath)'"
                    $newLinesResult = Invoke-SSHCommand -SSHSession $watcherSession -Command $getNewLinesCmd
                    if ($newLinesResult.Output) {
                        $lines = $newLinesResult.Output
                        foreach ($line in $lines) { Write-Output "$line" }
                        $lastLineNumber += $lines.Count
                        if ($lines[-1] -match "====== MASTER REPLICATION HELPER BEENDET.*======") { break }
                    }
                }
            }
        } catch { Write-Output "FATALER FEHLER im Watcher-Job: $($_.Exception.Message)" } finally { if ($watcherSession) { Remove-SSHSession -SSHSession $watcherSession } }
    } -ArgumentList $jobParamsForWatcher
    
    Write-GuiLog "Replikations-Job für '$($VMName)' gestartet."
}
# =====================================================================================
# --- END BLOCK ---
# =====================================================================================

# =====================================================================================
# --- START BLOCK (Phase 1.6: Finaler Button und Timer) ---
# =====================================================================================

$buttonDirectReplicate.Add_Click({
    # --- Vorab-Prüfungen ---
    if ($checkedListBoxVms.CheckedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Bitte wähle mindestens eine VM für die Replikation aus.", "Keine Auswahl", "OK", "Warning"); return
    }
    if ($Global:replicationJob -and $Global:replicationJob.State -eq 'Running') {
        [System.Windows.Forms.MessageBox]::Show("Es läuft bereits ein Replikations-Prozess. Bitte warten.", "Beschäftigt", "OK", "Warning"); return
    }
    if ($Global:ReplicationQueue.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show("Die Replikations-Warteschlange ist nicht leer. Breche den Vorgang ab, um Konflikte zu vermeiden.", "Info", "OK", "Information"); return
    }

    # --- Replikations-Dialog mit TAR/VMKFSTOOLS Auswahl anzeigen ---
    $dialogResult = $directReplicationForm.ShowDialog($form)
    if ($dialogResult -ne 'OK') {
        Write-GuiLog "Direkte Replikation vom Benutzer im Dialog abgebrochen."
        return
    }

    # --- Passwortlose SSH-Verbindung prüfen ---
    Write-GuiLog "Prüfe passwortlose SSH-Verbindung von Quelle zu Ziel..."
    $testCmd = "ssh -i /.ssh/id_ecdsa -o 'StrictHostKeyChecking=no' -o 'ConnectTimeout=10' root@$($textboxDrTargetHost.Text) `"echo 'SSH_OK'`""
    $testResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $testCmd
    if (($testResult.Output -join '').Trim() -ne 'SSH_OK') {
        [System.Windows.Forms.MessageBox]::Show("Die passwortlose SSH-Verbindung vom Quell- zum Ziel-Host ist für diese Funktion zwingend erforderlich.`nBitte richte sie über die SSH-Konsole ein.", "SSH-Fehler", "OK", "Error"); return
    }
    Write-GuiLog "-> Passwortlose Verbindung ist funktionsfähig."

    # --- VMs zur Warteschlange hinzufügen ---
    [string[]]$vmsToAdd = $checkedListBoxVms.CheckedItems | ForEach-Object { $_.OriginalName }
    $Global:ReplicationQueue.AddRange($vmsToAdd)
    Write-GuiLog "$($vmsToAdd.Count) VM(s) zur Replikations-Warteschlange hinzugefügt."
    
    # --- Timer starten, um die Warteschlange abzuarbeiten ---
    if (-not $Global:replicationJobTimer.Enabled) {
        $Global:replicationJobTimer.Start()
        # Den ersten Tick sofort auslösen, um direkt zu starten
        $onReplicationJobTimerTick.Invoke()
    }
})

$onReplicationJobTimerTick = {
    # 1. Wenn ein Job läuft -> Log auslesen und warten
    if ($Global:replicationJob -and $Global:replicationJob.State -eq 'Running') {
        if ($Global:replicationJob.HasMoreData) {
            Receive-Job -Job $Global:replicationJob | ForEach-Object { Write-GuiLog "JOB: $_" }
        }
        return
    }

    # 2. Wenn der letzte Job fertig ist -> Aufräumen
    if ($Global:replicationJob) {
        Write-GuiLog "Job für vorherige VM beendet mit Status: $($Global:replicationJob.State)."
        if ($Global:replicationJob.HasMoreData) {
            Receive-Job -Job $Global:replicationJob | ForEach-Object { Write-GuiLog "JOB: $_" }
        }
        Remove-Job -Job $Global:replicationJob
        $Global:replicationJob = $null
        Write-GuiLog "=================================================================="
    }

    # 3. Wenn noch VMs in der Schlange sind -> Nächste starten
    if ($Global:ReplicationQueue.Count -gt 0) {
        $nextVm = $Global:ReplicationQueue[0]
        $Global:ReplicationQueue.RemoveAt(0)
        Start-ReplicationForVM -VMName $nextVm
    } else {
        # 4. Wenn alles fertig ist -> Timer stoppen
        $Global:replicationJobTimer.Stop()
        Write-GuiLog "Alle VMs in der Warteschlange abgearbeitet. Timer gestoppt."
        [System.Windows.Forms.MessageBox]::Show("Alle Replikations-Aufgaben abgeschlossen.", "Fertig", "OK", "Information")
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
            $Global:TargetESXiSession = New-SSHSession -ComputerName $targetHost -Credential $Global:TargetESXiSshCredential -ErrorAction Stop -AcceptKey

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


function Install-PatchedGhettoVCB {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) {
        Write-GuiLog "Fehler: Nicht mit ESXi verbunden."
        return
    }
    $ghettoPathOnESXi = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) {
        Write-GuiLog "FEHLER: Der GhettoVCB-Pfad muss im GUI gesetzt sein, um das Skript zu installieren."
        return
    }

    # NEUE LOGIK V5.7: Patch per Download vom PC aus
    $patchUrl = "https://github.com/Chrigel71/GhettoGUI/raw/refs/heads/main/ghettoVCB_patch.sh"
    $targetPathOnESXi = "$ghettoPathOnESXi/ghettoVCB.sh"

    $confirmInstall = [System.Windows.Forms.MessageBox]::Show("Dies lädt den Patch von GitHub auf DIESEN PC und lädt ihn dann zum ESXi-Host hoch. Der Host selbst benötigt keine Internetverbindung.`n`nURL: $patchUrl`n`nFortfahren?", "Installation per PC-Download", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirmInstall -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-GuiLog "Installation des Patches vom Benutzer abgebrochen."
        return
    }

    Write-GuiLog "Starte Download des Patches auf diesen PC..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $tempFile = $null
    $sftpSession = $null
    try {
        $ErrorActionPreference = "Stop"

        # Schritt 1: Patch auf lokalen PC herunterladen
        $tempFile = New-TemporaryFile
        Invoke-WebRequest -Uri $patchUrl -OutFile $tempFile.FullName -UseBasicParsing
        Write-GuiLog "Download auf PC erfolgreich: $($tempFile.FullName)"

        # Lese den Inhalt der heruntergeladenen Datei
        $scriptContent = Get-Content -Path $tempFile.FullName -Raw -Encoding UTF8

        # Schritt 2: Dateiinhalt zum ESXi-Host hochladen
        Write-GuiLog "Verbinde via SFTP, um Patch hochzuladen..."
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey

        Write-GuiLog "Lade Patch nach '$targetPathOnESXi' hoch..."
        Set-SFTPContent -SFTPSession $sftpSession -Path $targetPathOnESXi -Value $scriptContent -Encoding UTF8

        # Schritt 3: Ausführungsrechte setzen
        Write-GuiLog "Setze Ausführungsrechte (chmod +x)..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x `"$targetPathOnESXi`"" | Out-Null

        Write-GuiLog "Patch erfolgreich via PC-Download installiert!"
        [System.Windows.Forms.MessageBox]::Show("Der Patch wurde erfolgreich installiert!", "Installation erfolgreich", "OK", "Information")

    } catch {
        Write-GuiLog "FEHLER bei der Installation des Patches: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Bei der Installation ist ein Fehler aufgetreten.`n`nDetails: $($_.Exception.Message)", "Fehler", "OK", "Error")
    } finally {
        if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession -EA 0 }
        if ($tempFile -and (Test-Path $tempFile.FullName)) { Remove-Item $tempFile.FullName -Force -EA 0 }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $ErrorActionPreference = "Continue"
    }
}

function Get-SendmailDebugLog {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }
    $debugLogPath = "/tmp/ghetto_sendmail_debug.log"
    Write-GuiLog "Rufe Mail-Debug-Log von '$debugLogPath' ab..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $result = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "cat $debugLogPath"
        Write-GuiLog "--- START Mail Debug Log ---"
        if ($result.ExitStatus -eq 0 -and $result.Output) {
            $result.Output | ForEach-Object { Write-GuiLog $_ }
        } else {
            Write-GuiLog "Debug-Log nicht gefunden oder leer."
            if($result.Error){ $result.Error | ForEach-Object { Write-GuiLog "ERR: $_" } }
        }
        Write-GuiLog "--- ENDE Mail Debug Log ---"
    } catch {
        Write-GuiLog "FEHLER beim Abrufen des Debug-Logs: $($_.Exception.Message)"
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
        $testBody = "###### Final status: Test erfolgreich ######`nBackup Duration: 1 Sekunde`ninfo: Initiate backup for Test-VM"

        Write-GuiLog "Lade Test-Nachricht nach ESXi hoch..."
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey
        Set-SFTPContent -SFTPSession $sftpSession -Path $remoteTestMessagePath -Value $testBody -Encoding UTF8
        Write-GuiLog "Upload der temporären Test-Nachricht erfolgreich."

        $recipientsForCli = $emailParams.To.Split(',') | ForEach-Object { "'$($_.Trim())'" }
        $recipientsStr = $recipientsForCli -join " "

        $base_command = "$tmpScriptPath -m $remoteTestMessagePath -f `"$($emailParams.From)`" -s `"$($emailParams.Server)`" -S `"$($emailParams.Port)`" -j `"$testSubject`" "
        if (-not [string]::IsNullOrWhiteSpace($emailParams.User)) {
            $base_command += "-u `"$($emailParams.User)`" -p `"$($emailParams.Pass)`" "
        }
        $base_command += $recipientsStr

        # ### ALLERLETZTE LÖSUNG: Führe 'python' aus und übergebe das Skript ###
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
        $sftp = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey
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
    Write-GuiLog "Starte erweiterten Abbruch (inkl. Löschen)..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $backupVolPath = $textboxBackupVol.Text
        $cancelScript = @"
BACKUP_VOL_PATH='$($backupVolPath.Replace("'", "'""'"))'
WORKER_PID=\$(pgrep -f "vmkfstools.*\$BACKUP_VOL_PATH")
if [ -n "\$WORKER_PID" ]; then
    echo "INFO: Arbeiter-Prozess gefunden: \$WORKER_PID"
    WORKER_CMD=\$(ps -c | grep " \$WORKER_PID " | grep 'vmkfstools')
    DEST_VMDK_PATH=\$(echo "\$WORKER_CMD" | sed 's/.* //')
    DIR_TO_DELETE=\$(dirname "\$DEST_VMDK_PATH")
    echo "INFO: Zielordner für Löschung identifiziert: \$DIR_TO_DELETE"
else
    echo "INFO: Kein spezifischer Arbeiter-Prozess gefunden."
    DIR_TO_DELETE=""
fi
echo "INFO: Sende Abbruch-Signal an alle GhettoVCB-Prozesse..."
pkill -9 -f "vmkfstools.*ghettoVCB"
pkill -9 -f "ghettoVCB.sh"
if [ -n "\$DIR_TO_DELETE" ] && [ -d "\$DIR_TO_DELETE" ]; then
    echo "INFO: Lösche unvollständiges Backup-Verzeichnis: \$DIR_TO_DELETE"
    rm -rf "\$DIR_TO_DELETE"
    echo "INFO: Verzeichnis gelöscht."
else
    echo "INFO: Kein Verzeichnis zum Löschen gefunden oder identifiziert."
fi
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
    $confLines = @(
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
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey
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
    if (-not $Global:ESXiConnectedHostName) { Write-GuiLog "FEHLER: Nicht mit einem Host verbunden, um Einstellungen zu speichern."; return }
    $safeHostname = [System.Text.RegularExpressions.Regex]::Replace($Global:ESXiConnectedHostName, '[\\/:"*?<>|]', '_');
    $settingsFile = Join-Path -Path $Global:ScriptPath -ChildPath "$($safeHostname).ghetto.json"
    
    # Alle "normalen" Backup-Einstellungen sammeln
    $settings = @{
        EsxiIp = $textboxIp.Text; EsxiUser = $textboxUser.Text; GhettoPath = $textboxGhettoPath.Text; BackupVol = $textboxBackupVol.Text; Subfolder = $textboxSubfolder.Text; Rotation = $textboxRotation.Text;
        DiskFormat = $comboboxDiskFormat.SelectedItem; SnapMem = $checkboxSnapMem.Checked; SnapQuiesce = $checkboxSnapQuiesce.Checked; VmList = $textboxVmList.Text;
        ScheduleHour = $textboxScheduleHour.Text; ScheduleMinute = $textboxScheduleMinute.Text; ScheduleDays = @{};
        EmailLog = $checkboxEmailLog.Checked; EmailTo = $textboxEmailTo.Text; EmailFrom = $textboxEmailFrom.Text; EmailServer = $textboxEmailServer.Text; EmailPort = $textboxEmailPort.Text; EmailSubject = $textboxEmailSubject.Text;
        EmailUser = $textboxEmailUser.Text; EmailPass = $textboxEmailPassword.Text
    }
    foreach ($dayEntry in $checkboxDays.GetEnumerator()) { $settings.ScheduleDays[$dayEntry.Name] = $dayEntry.Value.Checked }
    
    # Replikations-Einstellungen hinzufügen
    $settings.Add("ReplTargetHost", $textboxDrTargetHost.Text)
    $settings.Add("ReplTargetDatastore", $textboxDrTargetDs.Text)
    $settings.Add("ReplSuffix", $textboxDrSuffix.Text)
    
    # KORREKTUR: Die if-Abfrage wird aus dem .Add()-Befehl herausgelöst, um den Parser-Fehler zu vermeiden.
    # 1. Wert in einer Variable ermitteln.
    $replMethodValue = "tar" # Standardwert ist "tar"
    if ($directReplicationForm.Controls.Find('radioVmkf', $true)[0].Checked) {
        $replMethodValue = "vmkfstools"
    }
    # 2. Die Variable zur Hashtable hinzufügen.
    $settings.Add("ReplMethod", $replMethodValue)

    try { 
        $settings | ConvertTo-Json -Depth 5 | Set-Content -Path $settingsFile -Encoding UTF8
        Write-GuiLog "GUI-Einstellungen erfolgreich in '$($settingsFile)' gespeichert."
    } catch { 
        Write-GuiLog "FEHLER beim Speichern der GUI-Einstellungen: $($_.Exception.Message)" 
    }
}

# =====================================================================================
# --- END BLOCK ---
# =====================================================================================

# =====================================================================================
# --- START BLOCK (Lade-Funktion Fix) ---
# =====================================================================================

function Load-HostGuiSettings {
    if (-not $Global:ESXiConnectedHostName) { Write-GuiLog "FEHLER: Nicht mit einem Host verbunden, um Einstellungen zu laden."; return };
    $safeHostname = [System.Text.RegularExpressions.Regex]::Replace($Global:ESXiConnectedHostName, '[\\/:"*?<>|]', '_');
    $settingsFile = Join-Path -Path $Global:ScriptPath -ChildPath "$($safeHostname).ghetto.json"
    if (Test-Path $settingsFile) {
        Write-GuiLog "Lade GUI-Einstellungen aus '$($settingsFile)'...";
        try {
            $settings = Get-Content -Path $settingsFile -Raw | ConvertFrom-Json
            
            # Bestehende Einstellungen laden
            $textboxGhettoPath.Text = $settings.GhettoPath; $textboxBackupVol.Text = $settings.BackupVol; $textboxSubfolder.Text = $settings.Subfolder; $textboxRotation.Text = $settings.Rotation
            $comboboxDiskFormat.SelectedItem = $settings.DiskFormat; $checkboxSnapMem.Checked = $settings.SnapMem; $checkboxSnapQuiesce.Checked = $settings.SnapQuiesce; $textboxVmList.Text = $settings.VmList
            $textboxScheduleHour.Text = $settings.ScheduleHour; $textboxScheduleMinute.Text = $settings.ScheduleMinute
            if ($settings.ScheduleDays) { foreach ($dayEntry in $settings.ScheduleDays.PSObject.Properties) { if ($checkboxDays.ContainsKey($dayEntry.Name)) { $checkboxDays[$dayEntry.Name].Checked = $dayEntry.Value } } }
            if ($settings.PSObject.Properties['EmailLog']) { $checkboxEmailLog.Checked = $settings.EmailLog }
            if ($settings.PSObject.Properties['EmailTo']) { $textboxEmailTo.Text = $settings.EmailTo }
            if ($settings.PSObject.Properties['EmailFrom']) { $textboxEmailFrom.Text = $settings.EmailFrom }
            if ($settings.PSObject.Properties['EmailServer']) { $textboxEmailServer.Text = $settings.EmailServer }
            if ($settings.PSObject.Properties['EmailPort']) { $textboxEmailPort.Text = $settings.EmailPort }
            if ($settings.PSObject.Properties['EmailSubject']) { $textboxEmailSubject.Text = $settings.EmailSubject }
            if ($settings.PSObject.Properties['EmailUser']) { $textboxEmailUser.Text = $settings.EmailUser }
            if ($settings.PSObject.Properties['EmailPass']) { $textboxEmailPassword.Text = $settings.EmailPass }
            if ($settings.PSObject.Properties.Name -contains 'ReplTargetHost') { $textboxDrTargetHost.Text = $settings.ReplTargetHost }
            if ($settings.PSObject.Properties.Name -contains 'ReplTargetDatastore') { $textboxDrTargetDs.Text = $settings.ReplTargetDatastore }
            if ($settings.PSObject.Properties.Name -contains 'ReplSuffix') { $textboxDrSuffix.Text = $settings.ReplSuffix }
            
            # NEU: Gespeicherte Replikationsmethode laden und den entsprechenden Radio-Button auswählen
            if ($settings.PSObject.Properties.Name -contains 'ReplMethod') {
                if ($settings.ReplMethod -eq 'vmkfstools') {
                    $directReplicationForm.Controls.Find('radioVmkf', $true)[0].Checked = $true
                } else {
                    $directReplicationForm.Controls.Find('radioTar', $true)[0].Checked = $true
                }
            }

            # Automatisch die VM-Liste vom Host abrufen
            Write-GuiLog "Rufe aktuelle VM-Liste vom Host ab..."
            Load-VMListFromESXi
            
            # Checkboxen der VMs synchronisieren
            Write-GuiLog "Synchronisiere VM-Auswahlliste basierend auf geladenen Einstellungen..."
            $loadedVmNames = $textboxVmList.Text.Split([string[]]@("`r`n","`r","`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
            for ($i = 0; $i -lt $checkedListBoxVms.Items.Count; $i++) {
                $item = $checkedListBoxVms.Items[$i]
                if ($loadedVmNames -contains $item.OriginalName) {
                    $checkedListBoxVms.SetItemChecked($i, $true)
                } else {
                    $checkedListBoxVms.SetItemChecked($i, $false)
                }
            }
            Write-GuiLog "VM-Auswahl synchronisiert."
            
            Write-GuiLog "Host-spezifische GUI-Einstellungen erfolgreich geladen."
        } catch { Write-GuiLog "FEHLER: Konnte '$($settingsFile)' nicht laden. $($_.Exception.Message)" }
    } else { Write-GuiLog "Keine Einstellungsdatei für Host '$($Global:ESXiConnectedHostName)' gefunden." }
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
function Get-BackupJobLog { if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }; $ghettoPathOnESXi = $textboxGhettoPath.Text; if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "Fehler: GhettoVCB-Pfad im GUI ist nicht gesetzt."; return }; $logFile = "'$ghettoPathOnESXi/ghettoVCB-last_manual_run.log'"; $checkFileCmd = "if [ -f $logFile ]; then echo 'EXISTS'; else echo 'NOT_EXISTS'; fi"; Write-GuiLog "Prüfe und lese Log-Datei vom Host: $logFile"; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; try { $checkResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $checkFileCmd; if (($checkResult.Output -join '') -eq 'EXISTS') { $catCmd = "cat $logFile"; $logResult = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $catCmd; Write-GuiLog "--- START GhettoVCB Log ---"; $outputBox.Clear(); $finalStatusFound = $false; if ($logResult.Output) { $logResult.Output | ForEach-Object { Write-GuiLog $_; if ($_ -match "###### Final status:") { $finalStatusFound = $true } } } else { Write-GuiLog "(Log-Datei ist leer)" }; Write-GuiLog "--- ENDE GhettoVCB Log ---"; if ($finalStatusFound -and $Global:logPollTimer.Enabled) { Write-GuiLog "Backup abgeschlossen! Automatischer Log-Abruf wird beendet."; $Global:logPollTimer.Stop(); $buttonStartBackup.Enabled = $true; $buttonCheckBackupStatus.Enabled = $true; $buttonCancelBackup.Enabled = $false } } else { Write-GuiLog "Log-Datei noch nicht vorhanden. Bitte warten Sie einen Moment nach dem Start des Backups und versuchen Sie es erneut." } } catch { Write-GuiLog "Ausnahmefehler beim Abrufen des Logs: $($_.Exception.Message)"; if ($Global:logPollTimer.Enabled) { Write-GuiLog "Automatischer Log-Abruf wegen Fehler gestoppt."; $Global:logPollTimer.Stop(); $buttonStartBackup.Enabled = $true; $buttonCheckBackupStatus.Enabled = $true; $buttonCancelBackup.Enabled = $false } } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default } }
function Browse-BackupDir { if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }; $baseBackupPath = $textboxBackupVol.Text.TrimEnd('/'); $subfolder = $textboxSubfolder.Text.Trim('/'); $fullBackupPath = if (-not [string]::IsNullOrWhiteSpace($subfolder)) { "$baseBackupPath/$subfolder" } else { $baseBackupPath }; if ([string]::IsNullOrWhiteSpace($fullBackupPath)) { Write-GuiLog "Fehler: Backup Volume Pfad ist nicht angegeben."; return }; Write-GuiLog "Frage Inhalt von '$fullBackupPath' ab (rekursiv)..."; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; try { $command = "ls -lR '$fullBackupPath'"; $result = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $command; Write-GuiLog "--- Inhalt von $fullBackupPath ---"; if ($result.ExitStatus -eq 0) { if ($result.Output) { $result.Output | ForEach-Object { Write-GuiLog $_ } } else { Write-GuiLog "(Verzeichnis ist leer)" } } else { Write-GuiLog "FEHLER beim Auslesen des Verzeichnisses (Exit Code: $($result.ExitStatus))."; if ($result.Error) { $result.Error | ForEach-Object { Write-GuiLog "ERR: $_" } } }; Write-GuiLog "--- Ende der Liste ---" } catch { Write-GuiLog "Ausnahmefehler beim Abfragen des Verzeichnisinhalts: $($_.Exception.Message)" } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default } }

# ---############ function Show-DatastoreSelectionDialog SSHSession

function Show-DatastoreSelectionDialog {
    # HIER IST DIE KORREKTUR: Die strenge Typ-Deklaration [System.Management.Automation.Runspaces.Runspace] wurde entfernt.
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
                        $volumeNameOriginal = $parts[1];
                        $type = "";
                        if ($parts.Count -ge 4) { $type = $parts[-3]; if ($type -notmatch "(VMFS|NFS)"){$type = $parts[-4]} };
                        $pathToUse = $mountPoint;
                        $displayFriendlyName = ConvertTo-DisplaySafeString -InputString $volumeNameOriginal;
                        $displayMountPoint = ConvertTo-DisplaySafeString -InputString $mountPoint;
                        $displayName = $displayMountPoint;
                        if ($type -match "NFS" -and (-not [string]::IsNullOrWhiteSpace($volumeNameOriginal)) -and $volumeNameOriginal -ne "n/a" -and $volumeNameOriginal -ne ($mountPoint -split '/')[-1] ) {
                            $displayName = "$displayFriendlyName ($displayMountPoint)"
                        } elseif (($type -match "VMFS") -and (-not [string]::IsNullOrWhiteSpace($volumeNameOriginal)) -and $volumeNameOriginal -ne "n/a" -and $volumeNameOriginal -ne ($mountPoint -split '/')[-1]) {
                            $pathToUse = "/vmfs/volumes/$volumeNameOriginal"; $displayName = "$displayFriendlyName ($displayMountPoint)"
                        };
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
function Install-GhettoVCBFromGitHub { $ghettoVCBZipUrl = "https://github.com/lamw/ghettoVCB/archive/refs/heads/master.zip"; $tempZipFileName = $null; $ErrorActionPreference = "Stop"; Write-GuiLog "Starte GhettoVCB Installation von GitHub..."; try { $tempZipFile = New-TemporaryFile; $tempZipFileName = $tempZipFile.FullName; $tempZipFile.Delete(); Write-GuiLog "Lade GhettoVCB von GitHub..."; Invoke-WebRequest -Uri $ghettoVCBZipUrl -OutFile $tempZipFileName -UseBasicParsing; Write-GuiLog "Download abgeschlossen: '$tempZipFileName'."; Execute-GhettoVCBInstallation -localZipFilePath $tempZipFileName } catch { Write-GuiLog "FEHLER beim GitHub-Download: $($_.Exception.Message)" } finally { if ($tempZipFileName -and (Test-Path $tempZipFileName)) { Write-GuiLog "Lösche temporäre ZIP-Datei: '$tempZipFileName'"; Remove-Item $tempZipFileName -Force -EA 0 }; $ErrorActionPreference = "Continue" }}
function Install-GhettoVCBFromLocalFile { Write-GuiLog "Starte GhettoVCB Installation von lokaler Datei..."; try { $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog; $openFileDialog.Title = "Lokale GhettoVCB ZIP-Datei auswählen"; $openFileDialog.Filter = "ZIP-Dateien (*.zip)|*.zip"; if ($openFileDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $localZipFilePath = $openFileDialog.FileName; Write-GuiLog "Ausgewählte Datei: '$localZipFilePath'"; Execute-GhettoVCBInstallation -localZipFilePath $localZipFilePath } else { Write-GuiLog "Keine Datei ausgewählt. Installation abgebrochen." }} catch { Write-GuiLog "FEHLER bei Auswahl der lokalen Datei: $($_.Exception.Message)" }}
function Execute-GhettoVCBInstallation { param( [Parameter(Mandatory=$true)] [string]$localZipFilePath ); if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }; if (-not $Global:ESXiConnectedHostName) { Write-GuiLog "Fehler: Hostname für SFTP/Installation nicht verfügbar."; return }; if (-not $Global:ESXiSshCredential) { Write-GuiLog "Fehler: SSH-Anmeldeinformationen für SFTP/Installation nicht gefunden."; return }; $ghettoPathOnESXi = $textboxGhettoPath.Text; if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) { Write-GuiLog "Fehler: GhettoVCB-Installationspfad nicht gesetzt."; return }; $sftpSession = $null; $ErrorActionPreference = "Stop"; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; try { Write-GuiLog "Leere/Erstelle Zielverzeichnis '$ghettoPathOnESXi'..."; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm -rf '$ghettoPathOnESXi'" -EA SilentlyContinue | Out-Null; $mkdirCommand = "mkdir -p '$ghettoPathOnESXi'"; $mkdirOutput = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $mkdirCommand; if ($mkdirOutput.ExitStatus -ne 0) { Write-GuiLog "FEHLER: Konnte '$ghettoPathOnESXi' nicht erstellen (Exit: $($mkdirOutput.ExitStatus))."; return }; Write-GuiLog "Zielverzeichnis '$ghettoPathOnESXi' erstellt."; Write-GuiLog "Erstelle SFTP-Sitzung..."; $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey -EA Stop; Write-GuiLog "SFTP-Sitzung erstellt."; $remoteZipPath = "$ghettoPathOnESXi/ghettoVCB_upload.zip"; Write-GuiLog "Lade ZIP nach '$remoteZipPath'..."; $localFileStream = $null; $remoteSftpStream = $null; try { $localFileStream = New-Object System.IO.FileStream($localZipFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read); $remoteSftpStream = New-SFTPFileStream -SFTPSession $sftpSession -Path $remoteZipPath -FileMode Create -FileAccess Write; $localFileStream.CopyTo($remoteSftpStream) } finally { if ($remoteSftpStream) { $remoteSftpStream.Close(); $remoteSftpStream.Dispose() }; if ($localFileStream) { $localFileStream.Close(); $localFileStream.Dispose() } }; Write-GuiLog "ZIP erfolgreich hochgeladen."; $extractBaseDir = $ghettoPathOnESXi; Write-GuiLog "Entpacke '$remoteZipPath' nach '$extractBaseDir'..."; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "unzip -o '$remoteZipPath' -d '$extractBaseDir'" | Out-Null; $findMasterFolderCmd = "ls -d $extractBaseDir/ghettoVCB-master*/ 2>/dev/null || ls -d $extractBaseDir/ghettoVCB-*/ 2>/dev/null || echo ''"; $masterFolderOutputObject = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $findMasterFolderCmd; $extractedMasterFolderNameOnly = $null; if ($null -ne $masterFolderOutputObject -and $null -ne $masterFolderOutputObject.Output) { $outputLinesFromLs = @($masterFolderOutputObject.Output) -join [Environment]::NewLine -split [Environment]::NewLine; $foundFullFolderPath = $outputLinesFromLs | Where-Object {$_ -like "*ghettoVCB*"} | Select-Object -First 1; if (-not [string]::IsNullOrWhiteSpace($foundFullFolderPath)) { $extractedMasterFolderNameOnly = $foundFullFolderPath.Trim().Split('/')[-1] } }; if ([string]::IsNullOrWhiteSpace($extractedMasterFolderNameOnly)) { Write-GuiLog "WARNUNG: Hauptordner nicht gefunden. Fallback 'ghettoVCB-master'."; $extractedMasterFolderNameOnly = "ghettoVCB-master" }; $extractedMainFolderFullPath = "$extractBaseDir/$extractedMasterFolderNameOnly"; Write-GuiLog "Prüfe entpackten Hauptordner: '$extractedMainFolderFullPath'."; $checkFolderExistsCmd = "if [ -d '$extractedMainFolderFullPath' ] && [ '$extractedMainFolderFullPath' != '$($ghettoPathOnESXi.TrimEnd('/'))' ]; then echo 'FOLDER_EXISTS_AND_DIFFERENT'; else echo 'FOLDER_SAME_OR_NOT_EXISTS'; fi"; $folderExistsOutput = Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command $checkFolderExistsCmd; if (($folderExistsOutput.Output -join "").Contains("FOLDER_EXISTS_AND_DIFFERENT")) { Write-GuiLog "Verschiebe Inhalte von '$extractedMainFolderFullPath'..."; $moveSourcePath = $extractedMainFolderFullPath.TrimEnd('/') + "/"; $moveDestinationPath = $ghettoPathOnESXi.TrimEnd('/') + "/"; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "mv '$moveSourcePath'* '$moveDestinationPath' && rm -rf '$extractedMainFolderFullPath'" | Out-Null; Write-GuiLog "Inhalte verschoben; '$extractedMainFolderFullPath' gelöscht." } else { Write-GuiLog "INFO: Kein separater Hauptordner zum Verschieben gefunden/nötig." }; Write-GuiLog "Setze Ausführungsrechte..."; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod +x '$ghettoPathOnESXi'/*.sh" | Out-Null; Write-GuiLog "Berechtigungen gesetzt."; Write-GuiLog "Lösche '$remoteZipPath'..."; Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "rm '$remoteZipPath'" | Out-Null; Write-GuiLog "ZIP auf ESXi gelöscht."; Write-GuiLog "GhettoVCB erfolgreich installiert/aktualisiert!" } catch { Write-GuiLog "FEHLER Installation: $($_.Exception.Message)"; if ($_.Exception.ErrorRecord -and $_.Exception.ErrorRecord.Exception) { Write-GuiLog "Details: $($_.Exception.ErrorRecord.Exception.Message)" }} finally { if ($sftpSession) { Write-GuiLog "Schließe SFTP..."; Remove-SFTPSession -SFTPSession $sftpSession -EA 0; Write-GuiLog "SFTP geschlossen." }; $form.Cursor = [System.Windows.Forms.Cursors]::Default; $ErrorActionPreference = "Continue" }}

######################################
####  function Install-CustomSendmail####
########################################

function Install-CustomSendmail {
    if (-not ($Global:ESXiSession -and $Global:ESXiSession.Connected)) { Write-GuiLog "Fehler: Nicht mit ESXi verbunden."; return }
    $ghettoPathOnESXi = $textboxGhettoPath.Text
    if ([string]::IsNullOrWhiteSpace($ghettoPathOnESXi)) {
        Write-GuiLog "FEHLER: Der GhettoVCB-Pfad muss im GUI gesetzt sein, um das E-Mail-Skript zu installieren."
        return
    }

    $sendmailUrl = "https://github.com/Chrigel71/GhettoGUI/raw/main/sendmail.py"
    $targetPathOnESXi = "$ghettoPathOnESXi/sendmail"

    $confirmInstall = [System.Windows.Forms.MessageBox]::Show("Dies lädt das 'sendmail.py' Skript von GitHub und überträgt es mit der robusten Stream-Methode zum ESXi-Host.`n`nURL: $sendmailUrl`n`nFortfahren?", "Finale Installation des E-Mail-Skripts", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirmInstall -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-GuiLog "Installation des E-Mail-Skripts vom Benutzer abgebrochen."
        return
    }

    Write-GuiLog "Starte Download des E-Mail-Skripts von GitHub (v3.5 The Streamer)..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $localTempFile = $null
    $cleanedTempFile = $null
    $sftpSession = $null
    $localFileStream = $null
    $remoteSftpStream = $null

    try {
        $ErrorActionPreference = "Stop"

        # Schritt 1: Skript auf lokalen PC herunterladen
        $localTempFile = New-TemporaryFile
        Invoke-WebRequest -Uri $sendmailUrl -OutFile $localTempFile.FullName -UseBasicParsing
        Write-GuiLog "Download auf PC erfolgreich."

        # Schritt 2: Skript bereinigen (Zeilenumbrüche, Tabs) und in eine neue temporäre Datei schreiben
        Write-GuiLog "Bereinige Skript für maximale Kompatibilität..."
        $scriptContentString = Get-Content -Path $localTempFile.FullName -Raw
        $contentWithUnixEndings = $scriptContentString.Replace("`r`n", "`n")
        $cleanContent = $contentWithUnixEndings.Replace("`t", "    ")

        $cleanedTempFile = New-TemporaryFile
        Set-Content -Path $cleanedTempFile.FullName -Value $cleanContent -Encoding UTF8 -NoNewline
        Write-GuiLog "Skript erfolgreich bereinigt."

        # Schritt 3: Bereinigte Datei via File Stream zum ESXi-Host hochladen
        Write-GuiLog "Verbinde via SFTP, um E-Mail-Skript hochzuladen..."
        $sftpSession = New-SFTPSession -ComputerName $Global:ESXiConnectedHostName -Credential $Global:ESXiSshCredential -AcceptKey

        Write-GuiLog "Übertrage bereinigtes Skript nach '$targetPathOnESXi' via Stream..."
        $localFileStream = New-Object System.IO.FileStream($cleanedTempFile.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        $remoteSftpStream = New-SFTPFileStream -SFTPSession $sftpSession -Path $targetPathOnESXi -FileMode Create -FileAccess Write
        $localFileStream.CopyTo($remoteSftpStream)

        # Schritt 4: Ausführungsrechte setzen
        Write-GuiLog "Setze Ausführungsrechte (chmod 755)..."
        Invoke-SSHCommand -SSHSession $Global:ESXiSession -Command "chmod 755 `"$targetPathOnESXi`"" | Out-Null

        Write-GuiLog "E-Mail-Skript erfolgreich via Stream installiert!"
        [System.Windows.Forms.MessageBox]::Show("Das E-Mail-Skript wurde erfolgreich via Stream-Methode installiert!", "Installation erfolgreich", "OK", "Information")

    } catch {
        Write-GuiLog "FEHLER bei der Installation des E-Mail-Skripts: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Bei der Installation ist ein Fehler aufgetreten.`n`nDetails: $($_.Exception.Message)", "Fehler", "OK", "Error")
    } finally {
        if ($remoteSftpStream) { $remoteSftpStream.Close(); $remoteSftpStream.Dispose() }
        if ($localFileStream) { $localFileStream.Close(); $localFileStream.Dispose() }
        if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession -EA 0 }
        if ($localTempFile -and (Test-Path $localTempFile.FullName)) { Remove-Item $localTempFile.FullName -Force -EA 0 }
        if ($cleanedTempFile -and (Test-Path $cleanedTempFile.FullName)) { Remove-Item $cleanedTempFile.FullName -Force -EA 0 }
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

# --- Formular Steuerelemente hinzufügen und anzeigen ---
$form.Controls.AddRange(@(
    $labelIp, $textboxIp, $labelUser, $textboxUser, $connectButton, $disconnectButton,
    $buttonCheckPoshSsh, $groupGhettoConfig, $buttonLoadGuiSettings, $buttonSaveGuiSettings,
    $saveConfigButton, $saveConfigButton, $buttonSaveReplConfig,
    $buttonInstallGitHub, $buttonInstallPatchedGhetto, $buttonInstallSendmailPy, $buttonOpenSshConsole, $groupSchedule, $groupEmail,
    $buttonStartBackup, $buttonCheckBackupStatus, $buttonCancelBackup, $buttonBrowseBackupDir,
    $outputBox,
    $groupTraffic # Das neue Traffic-Panel hinzufügen
))

# --- Formular-Events und finaler Start ---

$form.Add_FormClosing({
    # Beendet alle laufenden PowerShell-Jobs beim Schliessen
    Get-Job | Remove-Job -Force
	if ($Global:trafficPollTimer -and $Global.trafficPollTimer.Enabled) { $Global:trafficPollTimer.Stop() }
    if ($Global:logPollTimer -and $Global:logPollTimer.Enabled) { $Global:logPollTimer.Stop() }
    if ($Global:replicationJobTimer -and $Global:replicationJobTimer.Enabled) { $Global:replicationJobTimer.Stop() }

    # Schliesst alle möglichen SSH-Verbindungen
    Write-GuiLog "Schließe alle SSH-Verbindungen..."
    if ($Global:ESXiSession) { Remove-SSHSession -SSHSession $Global:ESXiSession -ErrorAction SilentlyContinue }
    if ($Global:TargetESXiSession) { Remove-SSHSession -SSHSession $Global:TargetESXiSession -ErrorAction SilentlyContinue }
    if ($Global:sourceConsoleSession) { Remove-SSHSession -SSHSession $Global:sourceConsoleSession -ErrorAction SilentlyContinue }
    if ($Global:targetConsoleSession) { Remove-SSHSession -SSHSession $Global:targetConsoleSession -ErrorAction SilentlyContinue }

    # Räumt alle temporären Setup-Dateien (inkl. ECDSA-Schlüsselpaar) auf
    Write-GuiLog "Lösche temporäre Setup-Dateien aus C:\temp..."
    $filesToDelete = @(
        "C:\temp\esxi_replication_key",
        "C:\temp\esxi_replication_key.pub",
        "C:\temp\setup_keys.bat"
    )
    foreach ($file in $filesToDelete) {
        if (Test-Path $file) {
            try { Remove-Item -Path $file -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    Write-GuiLog "Temporäre Setup-Dateien gelöscht."
    
    # KORREKTUR: Räumt die "Müll"-Dateien im Programmverzeichnis auf
    Write-GuiLog "Lösche eventuell erstellte Müll-Dateien im Programmverzeichnis..."
    $junkFiles = @('Bitte', 'Kopiere', 'Schluesselpaar', 'ECDSA-Schluesselpaar')
    foreach ($junkFile in $junkFiles) {
        $filePath = Join-Path -Path $Global:ScriptPath -ChildPath $junkFile
        if (Test-Path $filePath) {
             try { Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    Write-GuiLog "Müll-Dateien entfernt."

    # Schliesse das Konsolen-Fenster, falls es noch offen ist
    if ($sshConsoleForm -and -not $sshConsoleForm.Isdisposed) { $sshConsoleForm.Close() }
})

if (-not [System.Windows.Forms.Application]::MessageLoop) {
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
# Finale Startmeldung mit korrekter Version
Write-GuiLog "GhettoGUI V8.9.2 (Direct Replication Fix) gestartet. Bitte ESXi-Daten eingeben und verbinden."
$form.ShowDialog() | Out-Null
