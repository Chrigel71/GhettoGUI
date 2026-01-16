# GhettoGUI - ESXi & Proxmox Manager V8.3.4

**Professionelle Backup-Automatisierung, Replikation & Management für VMware ESXi & Proxmox VE.**

> **Status:** Stable Release
> **Version:** 8.3.4
> **System:** PowerShell (Windows 7/810/11/Server)

GhettoGUI ist eine leistungsstarke PowerShell-Anwendung, die die Verwaltung von VMware ESXi-Hosts radikal vereinfacht. Sie dient als Frontend für das bewährte `ghettoVCB`-Skript, erweitert dieses jedoch massiv um Funktionen wie **Host-zu-Host Replikation**, **Live-Restore**, **Update-Management** und ein **modernes E-Mail-Reporting**.

Es sind keine Linux- oder SSH-Kenntnisse erforderlich – alles wird über die Windows-Oberfläche gesteuert.

---

## 🚀 Highlights der Version 8.3.4

* **Universeller E-Mail Support:**
    * **NEU:** Eigener **Socket-Fallback für ESXi 6.0**. Umgeht das Problem fehlender Python-Bibliotheken (`smtplib`) und instabiler `nc`-Pipes auf älteren Hosts.
    * Unterstützung für **benutzerdefinierte Absendernamen** (Display Name).
    * HTML-Reports mit Status-Farben und detaillierten Statistiken.
* **Multi-Hypervisor:** Volle Unterstützung für **ESXi 6.0 - 8.0** und **Proxmox VE 8.0 - 9.0**.
* **Intelligente Replikation:** Automatische Erkennung von Thin-Provisioning und "Hole Punching" für effizienten Speicherplatzverbrauch.
* **Robustheit:** Automatische Korrektur von leeren Konfigurations-Variablen und erhöhtes Timeout (60s) für langsame SSH-Verbindungen.

---

## 📋 Inhaltsverzeichnis

1.  [Voraussetzungen](#-voraussetzungen)
2.  [Installation & Start](#-installation--start)
3.  [Funktionsübersicht](#-funktionsübersicht)
    * [Backup & Scheduler](#1-backup--scheduler)
    * [Replikation (H2H)](#2-replikation-host-to-host)
    * [Restore & Recovery](#3-restore--recovery)
    * [Tools & Updates](#4-tools--updates)
4.  [Detaillierte Konfiguration](#-detaillierte-konfiguration)
5.  [Troubleshooting](#-troubleshooting)

---

## 💻 Voraussetzungen

* **Client:** Windows PC mit PowerShell 5.1 oder neuer.
* **Server:**
    * VMware ESXi: 6.0, 6.5, 6.7, 7.0, 8.0 (Free & Licensed)
    * Proxmox VE: 8.x, 9.x
* **Netzwerk:** SSH-Zugriff (Port 22) vom Client zum Server muss möglich sein.

---

## 🔧 Installation & Start

1.  Laden Sie die Datei `GhettoGUI_V8.3.4.ps1` herunter.
2.  Rechtsklick auf die Datei -> **"Mit PowerShell ausführen"**.
3.  **Wichtig beim ersten Start:**
    * Gehen Sie auf den Reiter **"Setup / Patch Host"**.
    * Klicken Sie auf **"Host Patchen & Vorbereiten"**.
    * *Dies lädt die notwendigen Skripte (`ghettoVCB.sh`, `sendmail.py` inkl. Socket-Fix) auf den Host und richtet die Firewall-Regeln für ausgehende E-Mails ein.*

> **Sicherheitshinweis:** Windows Defender kann bei unsignierten PowerShell-Skripten warnen. Dies ist ein "False Positive", da das Skript Netzwerkverbindungen aufbaut und Dateien herunterlädt. Sie können das Skript nach Prüfung des Quellcodes freigeben.

---

## 📖 Funktionsübersicht

### 1. Backup & Scheduler

Erstellen Sie Backups auf lokale Datastores oder NFS-Shares.

* **Snapshot-Handling:** Wählbar zwischen `Memory` (RAM mitsichern) und `Quiesce` (Dateisystem einfrieren).
* **Rotation:** Legen Sie fest, wie viele alte Backups behalten werden (z.B. "3").
* **Zeitplaner (Cron):**
    * Erstellen Sie Jobs für Täglich, Wöchentlich, **2-Wöchentlich** oder **Monatlich**.
    * Das GUI generiert automatisch den korrekten Cron-String und trägt ihn in die `/var/spool/cron/crontabs/root` ein.
    * Verwaltung existierender Jobs (Löschen/Anzeigen) direkt in der GUI.

### 2. Replikation (Host-to-Host)

Klonen Sie VMs direkt von einem ESXi auf einen anderen – ohne vCenter!

* **Methode: Offline (Sicher):** Fährt die VM herunter, repliziert sie und startet sie wieder. Garantiert 100% Datenkonsistenz.
* **Methode: Online (Live):** Erstellt einen temporären Klon der laufenden VM. Die Quell-VM bleibt die ganze Zeit erreichbar.
* **Methode: Via NAS:** Repliziert zuerst auf einen Zwischenspeicher (z.B. Synology/QNAP via NFS) und von dort auf den Ziel-Host. Ideal bei langsamen direkten Verbindungen.
* **Thin-Check:** Das System prüft, ob `vmkfstools` das "Thin Provisioning" beibehalten hat. Falls nicht, wird automatisch `vmkfstools -K` (Hole Punching) ausgeführt, um den Speicherplatz wieder freizugeben.

### 3. Restore & Recovery

Ein vollständiger Assistent zur Wiederherstellung:

1.  Wählen Sie den Backup-Ordner auf dem Datastore.
2.  Das Tool listet alle verfügbaren Backups auf.
3.  Klicken Sie auf **"Restore Starten"**.
4.  **Live-Log:** Verfolgen Sie den Kopiervorgang in Echtzeit im Log-Fenster (Fortschrittsanzeige).
5.  Die VM wird automatisch registriert und ist sofort startklar.

### 4. Tools & Updates

Ein "Schweizer Taschenmesser" für ESXi-Admins:

* **ESXi Updates:** Installieren Sie Patches (`.zip` Depots oder `.vib` Dateien) direkt über die GUI. Das Tool lädt die Datei hoch und führt `esxcli software vib update` aus.
* **SSH Key Manager:** Erstellt und verteilt RSA/ECDSA-Schlüsselpaare für passwortlosen Login zwischen Hosts (notwendig für automatisierte Replikation).
* **USB / Disk Wipe:** *Vorsicht!* Ein Tool zum Löschen der Partitionstabelle (`partedUtil mklabel msdos`) auf externen Datenträgern, um diese wieder nutzbar zu machen.
* **Kill Tasks:** Hängende Backup-Prozesse können per Knopfdruck beendet werden.

---

## ⚙️ Detaillierte Konfiguration

### E-Mail Einstellungen
GhettoGUI verfügt über eine eigene, hochoptimierte Python-Mail-Engine (`sendmail.py` V7.7).

* **ESXi 6.x:** Nutzt einen speziellen **Socket-Mode**, da ältere ESXi-Versionen kein modernes Python `smtplib` besitzen und `netcat` unzuverlässig ist.
* **ESXi 7.x/8.x:** Nutzt modernes Python 3 mit TLS/SSL Unterstützung.
* **Config:** Unterstützt SMTP-Auth, Port-Wahl (25/465/587) und benutzerdefinierte Absender ("Display Name").

### Disk Formate
* **Thin:** Wächst mit den Daten (Platzsparend).
* **Zeroedthick:** Reserviert den Platz, schreibt Nullen beim ersten Schreibzugriff.
* **Eagerzeroedthick:** Schreibt sofort alles mit Nullen voll (Beste Performance, dauert am längsten beim Backup).


---

## ❓ Troubleshooting / FAQ

**F: Mein Backup bricht ab mit "Snapshot error".**
A: Prüfen Sie, ob "Quiesce" aktiviert ist und ob die VMware Tools in der VM aktuell sind. Deaktivieren Sie "Quiesce" testweise.

**F: Die E-Mail kommt nicht an (ESXi 6.0).**
A: Stellen Sie sicher, dass Sie **"Patch Host"** ausgeführt haben. Die Version V8.3.4 installiert einen speziellen Fix für ESXi 6, der defekte Pipes umgeht. Prüfen Sie zudem die Firewall (Port 25/587 ausgehend).

**F: Windows Defender blockiert das Skript.**
A: Da es sich um ein unkompiliertes Admin-Skript handelt, das Netzwerkzugriff benötigt, ist dies normal. Fügen Sie eine Ausnahme hinzu oder führen Sie es in einer vertrauenswürdigen Umgebung aus.

---

## 📜 Credits & Lizenz

* **Code & GUI:** Chrigel#71 & Gemini AI
* **Core Logic:** Basiert auf `ghettoVCB` von William Lam.
* **Lizenz:** Open Source / Community Use.


*Die Nutzung erfolgt auf eigene Gefahr. Testen Sie Backups regelmäßig auf Wiederherstellbarkeit!*
