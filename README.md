# GhettoVCB GUI - Manager V5.7

Ein PowerShell-basiertes GUI-Tool zur einfachen Verwaltung von `ghettoVCB.sh` auf VMware ESXi-Hosts. Dieses Tool wurde entwickelt, um die Konfiguration, Installation und Ausführung von Backups mit `ghettoVCB` zu vereinfachen und eine zentrale Steuerungsoberfläche zu bieten.

## Funktionen

* **Grafische Oberfläche:** Eine übersichtliche Windows-Oberfläche zur Steuerung aller ghettoVCB-Funktionen.
* **Installation von ghettoVCB:** Lädt die offizielle Version von ghettoVCB direkt von GitHub herunter und installiert sie auf dem ausgewählten ESXi-Host.
* **Installation eines Patches:** Lädt einen stabilen, getesteten Patch für die `ghettoVCB.sh` von GitHub und installiert ihn, um Kompatibilität und die E-Mail-Funktionalität zu verbessern.
* **Konfiguration:** Einfaches Erstellen und Verwalten der `ghettoVCB.conf` und der VM-Listen direkt aus der GUI.
* **Manuelles Starten von Backups:** Starten, Überwachen und Abbrechen von Backup-Jobs mit einem Klick.
* **Zeitplanung:** Einrichten von automatischen, zeitgesteuerten Backups über den Cron-Dienst des ESXi-Hosts.
* **E-Mail-Benachrichtigungen:** Konfiguration und Test von E-Mail-Benachrichtigungen für erfolgreiche oder fehlgeschlagene Backups.

## Voraussetzungen

* **Windows-Betriebssystem:** Auf dem der Client mit der GUI läuft.
* **PowerShell 5.1 oder höher:** Standardmässig bei Windows 10/11 enthalten.
* **Posh-SSH Modul:** Wird vom Skript benötigt. Wenn es nicht gefunden wird, bietet die GUI an, es automatisch zu installieren (Internetverbindung auf dem PC erforderlich).
* **Netzwerkzugriff:** Vom PC auf den ESXi-Host (Port 22/SSH muss erreichbar sein).

## Installation der GUI

1.  Laden Sie die `GhettoGUI_V5.7_FINAL.ps1`-Datei herunter.
2.  **Wichtig:** Klicken Sie mit der rechten Maustaste auf die Datei, wählen Sie "Eigenschaften" und setzen Sie unten den Haken bei "Zulassen" (Unblock), falls dieser vorhanden ist.
3.  Führen Sie das Skript aus, indem Sie mit der rechten Maustaste darauf klicken und "Mit PowerShell ausführen" wählen.

## Ersteinrichtung auf einem neuen ESXi-Host

Wenn Sie einen ESXi-Host zum ersten Mal mit diesem Tool einrichten, führen Sie die folgenden Schritte in der GUI aus, nachdem Sie sich mit dem Host verbunden haben:

1.  **GhettoVCB-Pfad festlegen:** Geben Sie im Feld "GhettoVCB-Pfad" an, wo das Skript installiert werden soll (z.B. `/vmfs/volumes/datastore1/ghettoVCB`). Der "..."-Button hilft bei der Auswahl des Datastores.
2.  **Grundinstallation:** Klicken Sie auf **"Offizielles GhettoVCB installieren"**. Dies lädt die Basisversion von GitHub auf Ihren PC und von dort auf den ESXi-Host.
3.  **Patch installieren:** Klicken Sie auf **"GhettoVCB Patch"**. Dies lädt unsere optimierte `ghettoVCB.sh`-Datei und überschreibt die Originaldatei.
4.  **Mail-Skript installieren:** Klicken Sie auf **"Modernes E-Mail-Skript installieren"**. Dies ist für die erweiterte E-Mail-Funktion notwendig.

Nach diesen drei Schritten ist der Host vollständig für Backups vorbereitet.

## Anleitung: Ein Backup erstellen (Der Ablauf)

1.  **Verbindung herstellen:** Geben Sie die IP-Adresse und den Benutzernamen (meist `root`) des ESXi-Hosts ein und klicken Sie auf **"Verbinden"**. Geben Sie im aufpoppenden Fenster das Passwort ein.

2.  **Konfiguration laden oder eingeben:**
    * **Für einen bekannten Host:** Klicken Sie auf **"Einst. f. Host laden"**, um eine zuvor gespeicherte Konfiguration zu laden.
    * **Manuell:** Füllen Sie die wichtigsten Felder aus:
        * **GhettoVCB-Pfad:** Der Pfad, in dem die Skripte auf dem Host liegen (siehe Ersteinrichtung).
        * **Backup Volume:** Der Datastore, auf dem die Backups gespeichert werden sollen.
        * (Optional) Konfigurieren Sie Rotation, Disk Format etc. nach Wunsch.

3.  **VMs auswählen:**
    * Klicken Sie auf **"VMs laden"**, um eine Liste aller verfügbaren virtuellen Maschinen vom Host abzurufen.
    * Setzen Sie in der Liste Haken bei den VMs, die Sie sichern möchten.
    * Klicken Sie auf **"Auswahl übernehmen"**. Die Namen der VMs erscheinen nun im Textfeld "VMs (eine pro Zeile)".

4.  **Konfiguration auf ESXi speichern:**
    * Klicken Sie auf **"Ghetto-Konfig. auf ESXi speichern"**. Dieser extrem wichtige Schritt erstellt die Konfigurationsdateien (`ghettoVCB.conf` und `vms_to_backup.txt`) auf dem Host, die das Backup-Skript benötigt.

5.  **Backup starten:**
    * Klicken Sie auf **"Backup jetzt starten"**. Der Backup-Prozess wird nun im Hintergrund auf dem ESXi-Host gestartet.

6.  **Backup überwachen:**
    * Das Log-Fenster unten zeigt den Fortschritt an.
    * Sie können jederzeit auf **"Backup-Log abrufen"** klicken, um den aktuellen Stand des Logs vom Host zu laden.
    * Mit **"Backup abbrechen"** können Sie einen laufenden Job zwangsweise beenden.

## Weitere Funktionen

### Zeitplanung

Über den "Zeitplanung"-Block können Sie einen automatischen Cronjob auf dem ESXi-Host einrichten. Geben Sie einfach die gewünschte Uhrzeit und die Wochentage an und klicken Sie auf **"Zeitplan speichern"**. Das Backup wird dann automatisch zu den festgelegten Zeiten ausgeführt.

### E-Mail Benachrichtigung

Wenn Sie per E-Mail über den Backup-Status informiert werden möchten, aktivieren Sie die Checkbox und füllen Sie alle SMTP-Felder aus. Mit **"Email-Test"** können Sie die Konfiguration prüfen. Damit die Mails versendet werden können, muss die `EMAIL_LOG`-Variable in der `ghettoVCB.conf` auf `1` gesetzt sein. Unsere GUI macht dies automatisch, wenn Sie die Konfiguration speichern.

## Haftungsausschluss

Diese Software wird "wie besehen" ohne jegliche Gewährleistung bereitgestellt. Die Nutzung erfolgt auf eigene Gefahr. Es wird dringend empfohlen, die Funktionalität in einer Testumgebung zu überprüfen, bevor sie in einer produktiven Umgebung eingesetzt wird.

## Lizenz

Dieses GUI-Tool ist frei verfügbar. Das zugrundeliegende `ghettoVCB.sh`-Skript unterliegt der Lizenz seines ursprünglichen Autors, William Lam.