# GhettoVCB GUI - Manager V6.7.7 für ESXi 6.5 - 8.0

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

## Bedienungsanleitung

### Bereich 1: Verbindung & Hauptkonfiguration

Dieser Bereich (oben links) ist der Ausgangspunkt für alles.

* **ESXi Host IP / Username:** Geben Sie hier die Daten Ihres Quell-Hosts ein.
* **Verbinden:** Baut die SSH-Verbindung zum Host auf. Sie werden zur Passworteingabe aufgefordert.
* **Trennen:** Schliesst alle aktiven SSH-Verbindungen sauber.
* **Posh-SSH prüfen / Version anzeigen:** Zeigt Diagnose-Infos zu Ihrer PowerShell- und Posh-SSH-Version an.

### Bereich 2: GhettoVCB Konfiguration (Backup-Einstellungen)

Hier konfigurieren Sie die Details für **Standard-Backups**.

* **GhettoVCB-Pfad:** Der Ordner auf dem ESXi-Host, in dem die Skripte (`ghettoVCB.sh`, `sendmail.py`) liegen sollen. Der "..."-Button hilft bei der Auswahl eines Datastores.
* **Backup Volume:** Der Datastore, auf dem die Backups gespeichert werden sollen.
* **Unterordner:** Ein optionaler Unterordner innerhalb des Backup Volumes.
* **Rotation Count:** Anzahl der aufzubewahrenden Backups pro VM.
* **Festes Backup-Ziel:** Wenn aktiviert, wird immer in denselben Ordner geschrieben und die alte Sicherung überschrieben (keine Datumsstempel im Ordnernamen).
* **Disk Format:** Das Format der Backup-Festplatten (`thin`, `zeroedthick`, etc.).
* **Snap Memory / Snap Quiesce:** Optionen für die Snapshot-Erstellung.
* **VMs laden:** Lädt die Liste aller VMs vom verbundenen Host in das untere Auswahlfeld.
* **Auswahl übernehmen:** Überträgt die Namen der angehakten VMs in das Textfeld "VMs (eine pro Zeile)".
* **Einst. Host laden/speichern:** Speichert oder lädt alle Einstellungen der GUI (inkl. Replikation und E-Mail) in eine `.json`-Datei im Skript-Verzeichnis. Nützlich, wenn Sie mehrere Hosts verwalten.
* **Ghetto-Konfig. auf ESXi speichern:** Speichert die hier gemachten Einstellungen in der `ghettoVCB.conf` auf dem ESXi-Host. **Dies muss vor dem Starten eines Backups immer getan werden!**

### Bereich 3: Installation & Aktionen (Oben rechts)

* **Offizielles GhettoVCB installieren:** Startet einen Dialog, um die Basisversion von ghettoVCB von GitHub oder einer lokalen ZIP-Datei zu installieren.
* **GhettoVCB Patch:** Installiert unser angepasstes `ghettoVCB_patch.sh`-Skript. Dies ist für die erweiterten Logging-Funktionen **erforderlich**.
* **E-Mail-Skript installieren:** Installiert unsere angepasste `sendmail.py`, die für die detaillierten HTML-Berichte benötigt wird.
* **SSH-Konsole:** Öffnet das leistungsstarke Dual-Pane-SSH-Fenster.

### Bereich 4: Zeitplanung

Hier konfigurieren Sie Cron-Jobs für automatisierte Aufgaben.

* **Uhrzeit / Tage:** Legen Sie den Ausführungszeitpunkt fest.
* **Backup planen / Replikation planen:** Wählen Sie per Radio-Button, welche Aktion geplant werden soll.
* **Zeitplan speichern:** Schreibt den entsprechenden Cron-Job in die `crontab` des ESXi-Hosts.

### Bereich 5: E-Mail Benachrichtigung

* **Checkbox "aktivieren":** Schaltet den E-Mail-Versand global an oder aus.
* **Firewall-Check:** Erstellt automatisch die nötigen Firewall-Regeln auf dem ESXi-Host für ausgehenden SMTP- und SSH-Traffic.
* **Email-Test:** Speichert die Konfiguration und sendet eine Test-E-Mail mit den aktuellen Einstellungen.
* **Email-Log:** Durchsucht das letzte grosse Log nach E-Mail-relevanten Einträgen und zeigt eine gefilterte Zusammenfassung an.
* **Felder (Empfänger, Server, etc.):** Konfigurieren Sie hier Ihre SMTP-Server-Daten.

### Bereich 6: Backup-Aktionen

* **Backup jetzt starten:** Startet einen manuellen Backup-Job mit den VMs aus der Textliste und den in der `ghettoVCB.conf` gespeicherten Einstellungen.
* **Backup-Log abrufen:** Holt das letzte verfügbare Log (manuell oder geplant) und zeigt es im unteren Fenster an.
* **Backup abbrechen:** Versucht, laufende Backup-Prozesse auf dem Host zu beenden.
* **Backup-Ordner Inhalt:** Listet den Inhalt des konfigurierten Backup-Verzeichnisses auf.

---
### Anleitung: Replikation im Detail

#### A) Direkte Host-zu-Host Replikation (Blauer Button "Direkte Repl.")

Diese Methode benötigt eine **passwortlose SSH-Verbindung** vom Quell- zum Ziel-Host. Richten Sie diese zuerst über die **SSH-Konsole** ein!

1.  **Vorbereitung:** VMs in der Hauptliste auswählen.
2.  **Dialog öffnen:** Auf **"Direkte Repl."** klicken.
3.  **Ziel konfigurieren:**
    * **Ziel-Host IP / Username:** Daten des Ziel-Hosts.
    * **Zielspeicher:** Datastore auf dem Ziel-Host. Der "..."-Button verbindet sich temporär zum Ziel, um eine Liste abzurufen.
    * **Suffix:** Text, der an den Namen der replizierten VM angehängt wird (z.B., `-Replica`).
4.  **Temp-Speicher konfigurieren:**
    * **Lokalen VM-Temp verwenden:** (Standard) Der temporäre Klon wird im selben Ordner wie die Quell-VM erstellt. Benötigt freien Platz auf dem Quell-Datastore.
    * **Checkbox deaktivieren:** Erlaubt die Auswahl eines anderen Datastores auf dem **Quell-Host** als Zwischenspeicher. Ideal, wenn der Datastore der VM wenig freien Speicher hat.
5.  **Replikationsmethode wählen:**
    * **Repl. mit Temp (VM on):** Die VM bleibt online. Ein Snapshot wird erstellt, und aus diesem wird ein temporärer Klon erzeugt, der dann übertragen wird. Sicherste Methode.
    * **Repl. Stream (VM off):** Die VM wird für die Dauer des Kopiervorgangs heruntergefahren. Es wird kein temporärer Klon benötigt, die Daten werden direkt gestreamt.
6.  **Aktionen im Dialog:**
    * **Einst. speichern:** Sichert die Einstellungen im Dialog in der `.json`-Datei, ohne ihn zu schliessen.
    * **Replikation starten:** Startet den Job. Alle ausgewählten VMs werden nacheinander verarbeitet.
    * **Abbrechen:** Schliesst den Dialog.

---

## Sicherheit und Virenwarnung

Das Programm ist virenfrei. Windows Defender kann aufgrund des Verhaltensmusters (Herunterladen von Dateien aus dem Internet, Aufbau von SSH-Verbindungen, Ausführen von Befehlen auf entfernten Systemen) einen Fehlalarm (Heuristik) auslösen. Dies ist normal für unsignierte Administrations-Tools. Fügen Sie bei Bedarf eine Ausnahme in Windows Defender für die Skript-Datei oder den Ordner hinzu.

## Haftungsausschluss

Diese Software wird "wie besehen" ohne jegliche Gewährleistung bereitgestellt. Die Nutzung erfolgt auf eigene Gefahr. Der Autor übernimmt keine Haftung für Datenverlust oder andere Schäden.

## Lizenz

Dieses GUI-Tool ist frei verfügbar. Das zugrundeliegende `ghettoVCB.sh`-Skript unterliegt der Lizenz seines ursprünglichen Autors, William Lam.