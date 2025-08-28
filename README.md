# GhettoVCB GUI - Manager V6.9.8 für ESXi 6.0 - 8.0

Ein PowerShell-basiertes GUI-Tool zur umfassenden Verwaltung von `ghettoVCB.sh` auf VMware ESXi-Hosts. Dieses Tool wurde entwickelt, um die Konfiguration, Installation, Ausführung und Überwachung von Backups und Replikationen mit `ghettoVCB` drastisch zu vereinfachen und eine intuitive, zentrale Steuerungsoberfläche zu bieten.

## Features im Überblick

* **Grafische Oberfläche:** Eine übersichtliche Windows-Oberfläche zur Steuerung aller Funktionen, aufgeteilt in logische Bereiche.
* **Installation & Patching:** Installiert die offizielle Version von ghettoVCB sowie ein speziell angepasstes und getestetes Patch-Skript direkt aus der GUI. Die Installationsquelle (GitHub oder lokale Datei) ist wählbar.
* **Umfassende Backup-Konfiguration:** Detailliertes Konfigurieren von Backup-Jobs, inklusive Backup-Ziel, Rotations-Strategie, Disk-Format (`thin`, `thick`, etc.), Snapshot-Optionen und E-Mail-Benachrichtigungen.
* **Zwei Replikations-Methoden:**
    * **Direkte Replikation (Host-zu-Host):** Repliziert VMs direkt auf einen anderen ESXi-Host. Unterstützt eine "Online"-Methode (mit Temp-Klon, VM bleibt an) und eine "Offline"-Methode (VM wird für den Transfer heruntergefahren). Der temporäre Speicherort ist wählbar.
    * **Replikation via Zwischenspeicher (NAS):** Nutzt einen zentralen Speicher (z.B. NAS) als Puffer, um eine VM von einem Host zu sichern und auf einem anderen wiederherzustellen.
* **Sequenzielle Multi-VM-Jobs:** Wähle mehrere VMs aus und starte einen manuellen Replikations-Job. Die GUI arbeitet die VMs stabil nacheinander ab und sendet am Ende einen einzigen zusammenfassenden E-Mail-Bericht.
* **Zeitplanung für Backups & Replikationen:** Richten Sie per Radio-Button-Auswahl automatische, zeitgesteuerte Backups ODER Replikationen über den Cron-Dienst des ESXi-Hosts ein.
* **Detaillierte E-Mail-Berichte:** Konfigurierbare E-Mail-Benachrichtigungen, die einen übersichtlichen HTML-Bericht mit farblicher Status-Hervorhebung, Job-Details, Konfiguration, Speicherplatz-Analyse und einer Liste aller verarbeiteten VMs senden.
* **Live-Monitoring:** Anzeige des Netzwerk-Traffics einer ausgewählten physischen Netzwerkkarte (vmnic) in MB/s direkt in der GUI.
* **Integrierte SSH-Konsole:** Eine leistungsstarke Dual-Pane-SSH-Konsole zur direkten Verwaltung von Quell- und Zielhost. Inklusive Assistenten zur Einrichtung des passwortlosen SSH-Logins und zur Verwaltung von Cron-Jobs.

## Voraussetzungen

* **Windows-Betriebssystem:** Auf dem der Client mit der GUI läuft.
* **PowerShell 5.1 oder höher:** Standardmässig bei Windows 10/11 enthalten. Für volle Funktionalität wird PowerShell 7 empfohlen.
* **Posh-SSH Modul:** Wird für die SSH-Verbindungen benötigt. Wenn es nicht gefunden wird, bietet die GUI an, es automatisch für den aktuellen Benutzer zu installieren (Internetverbindung auf dem PC erforderlich).
* **Netzwerkzugriff:** Vom PC auf den/die ESXi-Host(s) (Port 22/SSH muss erreichbar sein). Für die direkte Replikation muss auch die Verbindung von Host zu Host auf Port 22 möglich sein.

## Installation & Erster Start

1.  Laden Sie die aktuelle `GhettoGUI_V6.7.7.zip`-Datei herunter und entpacken Sie sie in einen Ordner.
2.  **Wichtig:** Klicken Sie mit der rechten Maustaste auf die `GhettoGUI_V6.7.7.ps1`-Datei, wählen Sie "Eigenschaften" und setzen Sie unten den Haken bei "Zulassen" (Unblock), falls dieser vorhanden ist.
3.  **PowerShell Ausführungsrichtlinie anpassen:** Öffnen Sie PowerShell als **Administrator** und führen Sie einmalig den folgenden Befehl aus, um das Starten von Skripten zu erlauben:
    ```powershell
    Set-ExecutionPolicy Unrestricted
    ```
4.  **Starten:** Führen Sie das Skript aus, indem Sie mit der rechten Maustaste darauf klicken und "Mit PowerShell ausführen" wählen.

---

## Bedienungsanleitung & Button-Referenz

### Bereich 1: Verbindung & Hauptkonfiguration (Oben links)

* **ESXi Host IP / Username:** Felder zur Eingabe der Verbindungsdaten für den primären ESXi-Host (Quell-Host).
* **Verbinden:** Baut eine SSH-Verbindung zum eingetragenen Host auf. Fordert zur Passworteingabe auf und aktiviert nach Erfolg die meisten anderen GUI-Funktionen.
* **Trennen:** Schliesst alle aktiven SSH-Verbindungen (zum Quell-, Ziel- und Konsolen-Host) und setzt die GUI zurück.
* **Posh-SSH prüfen / Version anzeigen:** Öffnet ein Diagnosefenster, das die installierten Versionen von PowerShell und dem Posh-SSH-Modul anzeigt. Nützlich zur Fehlersuche.

### Bereich 2: GhettoVCB Konfiguration (Backup-Einstellungen)

Hier werden die Einstellungen für **Standard-Backups** (nicht Replikationen) vorgenommen. Diese werden in der `ghettoVCB.conf` auf dem Host gespeichert.

* `GhettoVCB-Pfad`: **Wichtig!** Das Stammverzeichnis auf einem Datastore, in dem die GhettoVCB-Skripte liegen und Log-Dateien erstellt werden (z.B. `/vmfs/volumes/datastore1/ghettoVCB`). Der **"..."**-Button öffnet einen Dialog zur Auswahl eines Datastores.
* `Backup Volume`: Der Datastore, auf dem die Backup-Ordner erstellt werden sollen.
* `Unterordner`: Optionaler Unterordner im "Backup Volume" zur besseren Organisation.
* `Rotation Count`: Wie viele alte Backups pro VM aufbewahrt werden sollen, bevor das älteste gelöscht wird.
* `Festes Backup-Ziel`: Wenn aktiv, wird kein Datums-Unterordner erstellt. Jedes Backup überschreibt das vorherige am selben Ort. Nützlich für z.B. Snapshots auf SAN-Ebene.
* `Disk Format`: Wählt das Format der virtuellen Festplatten im Backup (z.B. `thin` für platzsparend).
* `Snap Memory / Snap Quiesce`: Optionen für die Snapshot-Erstellung. `Quiesce` erfordert VMware Tools und sorgt für anwendungskonsistente Snapshots.
* **VMs laden:** Füllt die untere Liste mit allen auf dem Host registrierten VMs.
* **Auswahl übernehmen:** Überträgt die Namen der in der Liste angehakten VMs in das darüberliegende Textfeld. Nur VMs in diesem Textfeld werden gesichert.
* **Einst. Host laden/speichern:** Diese Buttons speichern oder laden **alle Einstellungen der gesamten GUI** (Backup, Replikation, E-Mail etc.) in/aus einer `hostname.ghetto.json`-Datei auf Ihrem PC. Perfekt, um Konfigurationen für verschiedene Hosts zu verwalten.
* **Ghetto-Konfig. auf ESXi speichern:** Schreibt die Einstellungen aus diesem Bereich in die `ghettoVCB.conf`-Datei auf dem Host. **Muss vor jedem Backup-Lauf ausgeführt werden, wenn Änderungen gemacht wurden!**

### Bereich 3: Installation & Aktionen (Oben rechts)

* **Offizielles GhettoVCB installieren:** Lädt die offizielle Version von GitHub oder einer lokalen ZIP-Datei herunter, entpackt sie und legt sie im angegebenen "GhettoVCB-Pfad" ab.
* **GhettoVCB Patch:** Installiert unser angepasstes `ghettoVCB_patch.sh`-Skript, das für die erweiterten Logging-Funktionen für die E-Mail-Berichte **erforderlich** ist.
* **E-Mail-Skript installieren:** Installiert unsere angepasste `sendmail.py`, die für die detaillierten, farbigen HTML-Berichte benötigt wird.
* **SSH-Konsole:** Öffnet das Dual-Pane SSH-Fenster für erweiterte Verwaltungsaufgaben.

### Integrierte SSH-Konsole

Ein mächtiges Werkzeug zur direkten Verwaltung und Einrichtung.

* **Dual-Pane-Ansicht:** Links der Quell-Host, rechts der Ziel-Host. Jeder Bereich hat eigene Verbindungs-Buttons und eine Kommandozeile.
* **Einrichtungs-Assistent (Host-zu-Host Setup):** Eine Schritt-für-Schritt-Anleitung zur Einrichtung der **passwortlosen SSH-Verbindung**, die für die direkte Replikation zwingend erforderlich ist.
    * **1. Schlüssel & Transfer-Skript erstellen:** Generiert ein `.bat`-Skript auf Ihrem PC (`C:\temp\setup_keys.bat`). **Sie müssen dieses Skript manuell ausführen.** Es erstellt die SSH-Schlüssel und kopiert sie auf Ihre Hosts (fragt dabei nach den Passwörtern).
    * **2. Berechtigungen setzen:** Nachdem Schritt 1 erfolgreich war, führt dieser Button die nötigen `chmod`-Befehle auf beiden Hosts aus, um die Schlüssel zu aktivieren.
    * **3. Finalen Verbindungstest durchführen:** Führt einen Test-SSH-Befehl vom Quell- zum Ziel-Host aus. Wenn "ERFOLG!" erscheint, ist die Einrichtung abgeschlossen.
    * **Verwaiste Replikationen bereinigen:** Ein "Notfall"-Button. Er beendet alle hängengebliebenen Replikations-Prozesse und löscht temporäre Dateien und Sperrdateien (`.lock`) auf dem Host.
* **Geplante Tasks (Cron):**
    * **Alle Tasks anzeigen:** Listet den Inhalt der Cron-Tabelle des Hosts mit Zeilennummern auf.
    * **Cron Diagnose-Info abrufen:** Führt ein Diagnose-Skript aus, das den Status des Cron-Dienstes und die letzten Log-Einträge anzeigt.
    * **Task-Nr. zum Löschen:** Geben Sie hier eine Zeilennummer aus der Liste ein, um einen spezifischen Job zu löschen.
    * **Task löschen:** Löscht die ausgewählte Zeile.
    * **Alle GhettoGUI Tasks löschen:** Entfernt alle Cron-Jobs, die von GhettoGUI erstellt wurden.

---

## Downloads & Sicherheit

### Sicherheit und Virenwarnung

Das Programm ist virenfrei. Windows Defender kann aufgrund des Verhaltensmusters (Herunterladen von Dateien, Aufbau von SSH-Verbindungen) einen Fehlalarm auslösen. Dies ist normal für unsignierte Administrations-Tools. Fügen Sie bei Bedarf eine Ausnahme für die Skript-Datei hinzu.

### Haftungsausschluss

Diese Software wird "wie besehen" ohne Gewährleistung bereitgestellt. Die Nutzung erfolgt auf eigene Gefahr.

### Lizenz


Dieses GUI-Tool ist frei verfügbar. Das zugrundeliegende `ghettoVCB.sh`-Skript unterliegt der Lizenz seines ursprünglichen Autors, William Lam.

