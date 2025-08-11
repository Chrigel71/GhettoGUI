# GhettoVCB GUI - Manager V6.0 für ESXi 6.5 - 8.0

Ein PowerShell-basiertes GUI-Tool zur einfachen Verwaltung von `ghettoVCB.sh` auf VMware ESXi-Hosts. Dieses Tool wurde entwickelt, um die Konfiguration, Installation und Ausführung von Backups und Replikationen mit `ghettoVCB` zu vereinfachen und eine zentrale Steuerungsoberfläche zu bieten.

## Funktionen

* **Grafische Oberfläche:** Eine übersichtliche Windows-Oberfläche zur Steuerung aller Funktionen.
* **Installation & Patching:** Installiert die offizielle Version von ghettoVCB und einen getesteten Patch direkt aus der GUI.
* **Konfiguration von Backups & Replikation:** Einfaches Erstellen und Verwalten der Konfigurationsdateien (`ghettoVCB.conf`, VM-Listen, Replikationsziele) direkt aus der Oberfläche.
* **Manuelle Backups & Replikationen:** Starten, Überwachen und Abbrechen von Backup- und Replikations-Jobs mit einem Klick.
    * **NEU:** Sequenzielle Multi-VM-Replikation zur stabilen Verarbeitung mehrerer VMs nacheinander.
* **Zeitplanung für Backups & Replikationen:** Richten Sie per Radio-Button-Auswahl automatische, zeitgesteuerte Backups ODER Replikationen über den Cron-Dienst des ESXi-Hosts ein.
* **E-Mail-Benachrichtigungen:** Konfiguration und Test von E-Mail-Benachrichtigungen für abgeschlossene Backup- oder Replikationsläufe.
* **Live-Monitoring:** Anzeige des Netzwerk-Traffics einer ausgewählten Netzwerkkarte in MB/s direkt in der GUI.
* **Integrierte SSH-Konsole:** Eine Dual-Pane-SSH-Konsole zur direkten Verwaltung von Quell- und Zielhost.

## Voraussetzungen

* **Windows-Betriebssystem:** Auf dem der Client mit der GUI läuft.
* **PowerShell 5.1 oder höher:** Standardmässig bei Windows 10/11 enthalten.
* **Posh-SSH Modul:** Wird vom Skript benötigt. Wenn es nicht gefunden wird, bietet die GUI an, es automatisch zu installieren (Internetverbindung auf dem PC erforderlich).
* **Netzwerkzugriff:** Vom PC auf den ESXi-Host (Port 22/SSH muss erreichbar sein).

## Installation der GUI

1.  Laden Sie die `GhettoGUI_V6.0.ps1`-Datei (oder die aktuelle Version) herunter.
2.  **Wichtig:** Klicken Sie mit der rechten Maustaste auf die Datei, wählen Sie "Eigenschaften" und setzen Sie unten den Haken bei "Zulassen" (Unblock), falls dieser vorhanden ist.
3.  Führen Sie das Skript aus, indem Sie mit der rechten Maustaste darauf klicken und "Mit PowerShell ausführen" wählen.

## Anleitung: Ein Backup erstellen (Der Ablauf)

1.  **Verbindung herstellen:** IP-Adresse und Benutzername eingeben und auf **"Verbinden"** klicken.
2.  **Konfiguration laden oder eingeben:** GhettoVCB-Pfad, Backup Volume, etc. festlegen.
3.  **VMs auswählen:** Auf **"VMs laden"** klicken, Haken setzen, mit **"Auswahl übernehmen"** bestätigen.
4.  **Konfiguration speichern:** Auf **"Ghetto-Konfig. speichern"** klicken, um die `ghettoVCB.conf` auf dem Host zu erstellen.
5.  **Backup starten:** Auf **"Backup jetzt starten"** klicken und im Log-Fenster überwachen.

## Anleitung: Eine Replikation durchführen

### Manuelle Replikation mehrerer VMs

1.  **Verbindung herstellen** und die zu replizierenden VMs in der Liste auswählen.
2.  Auf den Button **"Direkte Repl."** klicken.
3.  Im neuen Fenster den Ziel-Host, Ziel-Datastore und das Suffix für die replizierten VMs eintragen.
4.  Auf **"Replikation starten"** klicken. Die VMs werden nun nacheinander (sequenziell) repliziert, der Fortschritt wird im Log-Fenster angezeigt.

### Geplante Replikation einrichten

1.  **Replikationsziel konfigurieren:** Führen Sie die Schritte 1-3 der manuellen Replikation aus, um die Ziel-Informationen einzutragen.
2.  **Replikations-Job speichern:** Klicken Sie auf den Button **"Repl-Konfig speichern"**. Dies erstellt eine `replication.conf` auf dem ESXi-Host mit der Liste der ausgewählten VMs und den Ziel-Einstellungen.
3.  **Zeitplan erstellen:**
    * Gehen Sie zum "Zeitplanung"-Block.
    * Wählen Sie den Radio-Button **"Replikation planen"**.
    * Legen Sie Uhrzeit und Wochentage fest.
    * Klicken Sie auf **"Zeitplan speichern"**. Dies erstellt einen Cronjob, der die Replikation automatisch durchführt.

## Weitere Funktionen

### Sicherheit und Virenwarnung

Das Programm ist virenfrei. Windows Defender kann aufgrund des Verhaltensmusters (Herunterladen von Dateien, Aufbau von SSH-Verbindungen) einen Fehlalarm auslösen. Dies ist normal für unsignierte Administrations-Tools. Fügen Sie bei Bedarf eine Ausnahme in Windows Defender für die Skript-Datei oder den Ordner hinzu.

## Haftungsausschluss

Diese Software wird "wie besehen" ohne jegliche Gewährleistung bereitgestellt. Die Nutzung erfolgt auf eigene Gefahr.

## Lizenz

Dieses GUI-Tool ist frei verfügbar. Das zugrundeliegende `ghettoVCB.sh`-Skript unterliegt der Lizenz seines ursprünglichen Autors, William Lam.