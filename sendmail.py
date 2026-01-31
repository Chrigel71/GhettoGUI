#!/usr/bin/env python
# -*- coding: utf-8 -*-
# GhettoVCB-GUI Sendmail (ESXi 6.0 - 8.0 Compatible)
# V8.7.2 - Fix: Precise Size Calculation
#
# Features:
# - Full HTML Summary (Parsing of GhettoVCB Logs)
# - Übernahme der detaillierten VM-Zusammenfassung (Groesse + Speed)
# - Fix: Ignoriert falsche "Final size" Zeilen aus dem Log und rechnet selbst.
# - ESXi 6.0 Fix: NC-Priorisierung auf Port 25

from __future__ import print_function
import sys, os, argparse, socket, subprocess, time
from datetime import datetime
import re

# Standardwert
DEFAULT_DISPLAY_NAME = "ESXi Backup"

try: import smtplib
except Exception: smtplib = None

try:
    from email.mime.text import MIMEText
    from email.mime.multipart import MIMEMultipart
    from email.header import Header
    from email.utils import formatdate, formataddr
    HAVE_EMAIL = True
except Exception:
    MIMEText = MIMEMultipart = Header = formatdate = formataddr = None
    HAVE_EMAIL = False

try: _basestr = basestring
except NameError: _basestr = str

def html_escape(text):
    if not isinstance(text, _basestr):
        try: text = str(text)
        except Exception: text = repr(text)
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def create_summary(log_content):
    """
    Erzeugt die HTML-Zusammenfassung mit korrekter Größenberechnung.
    """
    summary = {
        "status": "Unbekannt", "duration": "N/A", "start_time": "N/A", "end_time": "N/A",
        "final_size": "N/A", "avg_speed": "N/A",
        "vms_processed": [], "vm_report_lines": [], "errors": [], "warnings": [], "infos": [],
        "config": [], "storage_before": [], "storage_after": [], "directory_listing": [], "detailed_log": []
    }
    in_listing, in_storage_before, in_storage_after, in_config, in_detailed = (False, False, False, False, False)
    current_vm = "Allgemein"
    
    in_vm_sum = False
    vm_report_lines = []

    for line in log_content.splitlines():
        s = line.strip(); s_lower = s.lower()
        
        # Sektions-Erkennung für die Zusammenfassung (Details)
        if ('zusammenfassung der' in s_lower) or ('summary of' in s_lower) or ('backup-zusammenfassung' in s_lower):
            in_vm_sum = True; continue
        if in_vm_sum and (s.startswith('---') or 'backup duration' in s_lower or 'final status' in s_lower or s.startswith('===')):
            in_vm_sum = False; continue

        if in_vm_sum:
            # Header-Zeile überspringen
            if "VM-Name:" in s and "Groesse" in s: continue
            
            # Einträge sammeln und säubern
            if s.startswith('-') or '- ' in s:
                for entry in s.split('- '):
                    rep = entry.strip()
                    if rep.startswith('-'): rep = rep[1:].strip()
                    if rep and "VM-Name:" not in rep: vm_report_lines.append(rep)
            elif s and "VM-Name:" not in s:
                vm_report_lines.append(s)
            continue

        # Allgemeine Status-Werte
        if "final status:" in s_lower: summary["status"] = s[s_lower.find("final status:") + len("final status:"):].replace("#", "").strip(); continue
        
        # WICHTIG: Wir ignorieren "final size:" aus dem Log, da dieser Wert oft falsch ist.
        # Er wird unten manuell aus den vm_report_lines berechnet.

        if "average speed:" in s_lower:
            summary["avg_speed"] = s[s_lower.find("average speed:") + len("average speed:"):].strip()
            continue
            
        if "initiate backup for" in s_lower:
            vm = s[s_lower.find("initiate backup for") + len("initiate backup for"):].strip(); current_vm = vm
            if vm and vm not in summary["vms_processed"]: summary["vms_processed"].append(vm)
            continue

        # Logging / Fehler / Warnungen
        if "warn:" in s_lower and "smtplib not available" in s_lower:
            msg = s[s_lower.find("warn:") + len("warn:"):].strip(); summary["infos"].append(("ESXi Host", msg)); continue
        if ("warn:" in s_lower or "warning:" in s_lower) and "permanently added" not in s_lower:
            find_str = "warning:" if "warning:" in s_lower else "warn:"
            msg = s[s_lower.find(find_str) + len(find_str):].strip()
            vm_context = current_vm
            if msg.startswith("[") and "]" in msg: vm_context = msg.split(']')[0][1:]; msg = msg.split('] - ', 1)[-1]
            summary["warnings"].append((vm_context, msg)); continue
        if "error:" in s_lower:
            msg = s[s_lower.find("error:") + len("error:"):].strip()
            vm_context = current_vm
            if msg.startswith("[") and "]" in msg: vm_context = msg.split(']')[0][1:]; msg = msg.split('] - ', 1)[-1]
            summary["errors"].append((vm_context, msg)); continue

        # Zeitstempel & Blöcke
        if s.startswith("Startzeit:") and summary["start_time"] == "N/A": summary["start_time"] = s.split(":", 1)[-1].strip(); continue
        if s.startswith("Endzeit:"): summary["end_time"] = s.split(":", 1)[-1].strip(); continue
        if s.startswith("Job-Konfiguration:"): in_config = True; continue
        if s.startswith("Speicherplatz (Vorher):"): in_config = False; in_storage_before = True; continue
        if s.startswith("Speicherplatz (Nachher):"): in_storage_before = False; in_storage_after = True; continue
        if s.startswith("--- START DES DETAILLOGS ---"): in_config=in_storage_before=in_storage_after=False; in_detailed = True; continue
        if s.startswith("--- ENDE DES DETAILLOGS ---"): in_detailed = False; continue
        if s.startswith("--- START Backup Directory Listing ---"): in_detailed=in_storage_after=False; in_listing = True; continue
        if s.startswith("--- END Backup Directory Listing ---"): in_listing = False; continue
        
        if in_config: summary["config"].append(s); continue
        if in_storage_before: summary["storage_before"].append(s); continue
        if in_storage_after: summary["storage_after"].append(s); continue
        if in_listing: summary["directory_listing"].append(line); continue
        if in_detailed: summary["detailed_log"].append(line); continue

    # Dauer berechnen
    if summary["start_time"] != "N/A" and summary["end_time"] != "N/A":
        try:
            t1 = datetime.strptime(summary["start_time"].strip(), "%Y-%m-%d %H:%M:%S")
            t2 = datetime.strptime(summary["end_time"].strip(), "%Y-%m-%d %H:%M:%S")
            delta = t2 - t1; total_seconds = delta.total_seconds(); minutes, seconds = divmod(total_seconds, 60)
            summary["duration"] = "%d Minuten, %d Sekunden" % (minutes, seconds)
        except: summary["duration"] = "Konnte nicht berechnet werden"

    # EIGENE GRÖSSENBERECHNUNG (Nur aus den verarbeiteten VMs)
    if vm_report_lines:
        total_gb = 0.0
        for _rep in vm_report_lines:
            # Suche nach XX.X G oder XX.X M nach einem Doppelpunkt oder in Klammern
            m = re.search(r':\s*([0-9\.]+)\s*([GM])B?', _rep, re.IGNORECASE)
            if not m: m = re.search(r'\(([0-9\.]+)\s*([GM]B?)\)', _rep, re.IGNORECASE)
            
            if m:
                try:
                    val = float(m.group(1).replace(',', '.'))
                    unit = m.group(2).upper().replace('B','')
                    gb = val/1024.0 if unit.startswith('M') else val
                    total_gb += gb
                except: pass
        if total_gb > 0: 
            summary['final_size'] = "{:.1f} GB".format(total_gb)

    # HTML Zusammenstellung
    status_text = summary["status"].lower()
    status_color = "#28a745" if "ok" in status_text or "erfolgreich" in status_text else "#dc3545"
    
    parts = ["<html><head><meta charset='utf-8'><style>body{font-family:Arial,sans-serif;font-size:13px}h3,h4{color:#333}pre{background:#f4f4f4;padding:10px;border:1px solid #ddd;white-space:pre-wrap}.err{color:#dc3545;font-weight:bold}.wrn{color:#b06a00;font-weight:bold}</style></head><body>"]   
    parts.append('<h2 style="color: %s;">Backup-Zusammenfassung V8.7.0</h2><hr>' % status_color)
    status_html = '<span style="color: %s; font-weight: bold;">%s</span>' % (status_color, html_escape(summary["status"]))
    parts.append('<p><b>Status:</b> %s</p>' % status_html)
    parts.append("<h4>Job-Details:</h4><ul>")
    parts.append("<li><b>Startzeit:</b> %s</li>" % html_escape(summary["start_time"]))
    parts.append("<li><b>Endzeit:</b> %s</li>" % (html_escape(summary["end_time"]) if summary["end_time"] != "N/A" else "<em>Job nicht beendet</em>"))
    parts.append("<li><b>Dauer:</b> %s</li>" % html_escape(summary["duration"]))
    if summary["final_size"] != "N/A": parts.append("<li><b>Groesse:</b> %s</li>" % html_escape(summary["final_size"]))
    if summary.get("avg_speed") and summary["avg_speed"] != "N/A":
        parts.append("<li><b>Durchschnitts-Speed:</b> %s</li>" % html_escape(summary["avg_speed"]))
    parts.append("</ul><hr>")

    # VERARBEITETE VMs: Liste säubern und literale \n entfernen
    vm_list_to_show = []
    source_lines = vm_report_lines if vm_report_lines else summary["vms_processed"]
    
    for line in source_lines:
        # 1. Entferne literale "\n" Zeichenketten aus dem Text
        # 2. .strip() entfernt echte Zeilenumbrüche und Leerzeichen
        clean_line = line.replace('\\n', '').strip()
        
        if clean_line and "VM-Name:" not in clean_line:
            vm_list_to_show.append(clean_line)
    
    # --- DIESEN BLOCK ERSETZEN ---
    parts.append('<h3>Verarbeitete VMs (%d)</h3><ul>' % len(vm_report_lines))
    parts.append("".join("<li>%s</li>" % html_escape(l.strip()) for l in vm_report_lines) + "</ul>")

    ## Fehler-Ausgabe
    parts.append('<h3>Warnungen (%d)</h3>' % len(summary["warnings"]))
    if summary["warnings"]:
        parts.append('<ul>' + "".join('<li><strong class="wrn">VM: %s</strong>: %s</li>' % (html_escape(v), html_escape(m)) for v, m in summary["warnings"]) + '</ul>')
    else: parts.append('<p>Keine.</p>')

    parts.append('<h3>Fehler (%d)</h3>' % len(summary["errors"]))
    if summary["errors"]:
        parts.append('<ul>' + "".join('<li><strong class="err">VM: %s</strong>: %s</li>' % (html_escape(v), html_escape(m)) for v, m in summary["errors"]) + '</ul>')
    else: parts.append('<p>Keine.</p>')
    
    if summary["config"]: parts.append("<hr><h4>Konfiguration:</h4><ul>%s</ul>" % "".join("<li>%s</li>" % html_escape(i) for i in summary["config"]))
    if summary["storage_after"]: parts.append('<h4>Speicherplatz (Nachher):</h4><pre>%s</pre>' % "\n".join(html_escape(x) for x in summary["storage_after"]))
    if summary["directory_listing"]: parts.append('<hr><h3>Dateien:</h3><pre>%s</pre>' % "\n".join(html_escape(x) for x in summary["directory_listing"]))
    parts.append("</body></html>")
    
    return "\n".join(parts), (len(summary["errors"]) > 0 or len(summary["warnings"]) > 0)
    # --- ENDE DES ERSETZUNGS-BLOCKS ---

    # Warnungen und Fehler
    parts.append("<h3>Warnungen (%d)</h3>" % len(summary["warnings"]))
    parts.append("<ul>%s</ul>" % "".join('<li><strong class="warn-vm">VM: %s</strong><ul><li>%s</li></ul></li>' % (html_escape(vm), html_escape(msg)) for vm, msg in summary["warnings"]) if summary["warnings"] else "<p>Keine.</p>")
    parts.append("<h3>Fehler (%d)</h3>" % len(summary["errors"]))
    parts.append("<ul>%s</ul>" % "".join('<li><strong class="error-vm">VM: %s</strong><ul><li>%s</li></ul></li>' % (html_escape(vm), html_escape(msg)) for vm, msg in summary["errors"]) if summary["errors"] else "<p>Keine.</p>")
    
    # Konfiguration & Speicher
    if summary["config"]: parts.append("<hr><h4>Konfiguration:</h4><ul>%s</ul>" % "".join("<li>%s</li>" % html_escape(i) for i in summary["config"]))
    if summary["storage_before"] or summary["storage_after"]:
        parts.append("<h4>Speicherplatz:</h4><pre>")
        if summary["storage_after"]: parts.append("<b>Nach dem Job:</b>\n" + "\n".join(html_escape(s) for s in summary["storage_after"]))
        if summary["storage_before"]: parts.append("\n<b>Vor dem Job:</b>\n" + "\n".join(html_escape(s) for s in summary["storage_before"]))
        parts.append("</pre>")
    
    # Verzeichnis & Log
    if summary["directory_listing"]: parts.append("<hr><h3>Detailliertes Verzeichnis-Listing</h3><pre>%s</pre>" % "\n".join(html_escape(x) for x in summary["directory_listing"]))
    if summary["detailed_log"]: parts.append("<hr><h3>Detailliertes Prozess-Log</h3><pre>%s</pre>" % "\n".join(html_escape(x) for x in summary["detailed_log"]))
    parts.append("</body></html>")
    return "\n".join(parts), (len(summary["errors"]) > 0 or len(summary["warnings"]) > 0)

def build_message(subject, html_body, to_csv, from_addr, display_name, is_important=False):
    # Optimierter Header-Bau für Outlook-Vorschau
    date_hdr = time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime())
    
    # Sicherstellen, dass der Anzeigename korrekt zitiert ist
    clean_display_name = display_name.replace('"', '')
    full_from = '"%s" <%s>' % (clean_display_name, from_addr)
    
    headers = [
        'From: %s' % full_from,
        'To: %s' % to_csv,
        'Subject: %s' % subject,
        'Date: %s' % date_hdr,
        'MIME-Version: 1.0',
        'Content-Type: text/html; charset=utf-8',
        'Content-Transfer-Encoding: 8bit'
    ]
    
    if is_important:
        headers.append('Importance: high')
        headers.append('X-Priority: 1')
        
    # Trennung zwischen Header und Body durch GENAU eine Leerzeile
    return "\r\n".join(headers) + "\r\n\r\n" + html_body

def _split_recipients(to_str):
    if not to_str: return []
    return [chunk.strip() for chunk in to_str.replace(',', ' ').replace(';', ' ').split() if chunk.strip()]

def _smtp_try_send(subject, html_body, to_csv, from_addr, display_name, host, port, user, pwd, tls_mode, auth_mode, is_important=False):
    if smtplib is None: return False
    try:
        raw = build_message(subject, html_body, to_csv, from_addr, display_name, is_important)
        server = smtplib.SMTP(host, port, timeout=30); server.ehlo()
        if tls_mode in ('auto', 'starttls'):
            try: server.starttls(); server.ehlo()
            except: pass
        if user and pwd: server.login(user, pwd)
        server.sendmail(from_addr, _split_recipients(to_csv), raw)
        server.quit()
        sys.stdout.write("INFO: Email successfully sent (smtplib)\n")
        return True
    except: return False

def _openssl_fallback(subject, html_body, to_csv, from_addr, display_name, host, port, user, pwd, tls_mode, auth_mode, is_important=False):
    recipients = _split_recipients(to_csv)
    raw_email_content = build_message(subject, html_body, to_csv, from_addr, display_name, is_important)
    
    try: import base64 as b64mod
    except: b64mod = None
    def b64(s):
        return b64mod.b64encode(s.encode('utf-8')).decode('ascii') if b64mod else s

    ehlo = socket.gethostname().split('.')[0] or 'esxi'
    commands = ["EHLO %s\r\n" % ehlo]
    if user and pwd:
        commands.extend(["AUTH LOGIN\r\n", "%s\r\n" % b64(user), "%s\r\n" % b64(pwd)])
    commands.append("MAIL FROM:<%s>\r\n" % from_addr)
    for r in recipients: commands.append("RCPT TO:<%s>\r\n" % r)
    commands.append("DATA\r\n")
    normalized = raw_email_content.replace('\r\n', '\n').replace('\r', '\n')
    commands.append(normalized.replace('\n', '\r\n') + "\r\n.\r\nQUIT\r\n")

    cmd = ['/bin/nc', host, str(port)] if (port == 25 and tls_mode != 'ssl') else \
          (['/bin/openssl', 's_client', '-quiet', '-crlf', '-connect', '%s:%s' % (host, port)] if tls_mode == 'ssl' else \
           ['/bin/openssl', 's_client', '-quiet', '-crlf', '-starttls', 'smtp', '-connect', '%s:%s' % (host, port)])

    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    for c in commands:
        p.stdin.write(c.encode('utf-8')); p.stdin.flush(); time.sleep(0.2)
    p.stdin.close(); out = str(p.stdout.read()); p.wait()
    if "250" in out or "queued" in out.lower() or "ok" in out.lower():
         sys.stdout.write("INFO: Email successfully sent (fallback)\n")
         return True
    raise RuntimeError("SMTP conversation failed")

def send_email(subject, body, to_addr, from_addr, display_name, smtp_server, smtp_port_str, user, password, tls_mode, auth_mode, openssl_fallback=True, is_important=False):
    smtp_port = int(smtp_port_str)
    if _smtp_try_send(subject, body, to_addr, from_addr, display_name, smtp_server, smtp_port, user, password, tls_mode, auth_mode, is_important): return
    if openssl_fallback:
        _openssl_fallback(subject, body, to_addr, from_addr, display_name, smtp_server, smtp_port, user, password, tls_mode, auth_mode, is_important)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('-f', dest='sender', required=True)
    parser.add_argument('-s', dest='server', required=True)
    parser.add_argument('-S', dest='port', required=True)
    parser.add_argument('-u', dest='username')
    parser.add_argument('-p', dest='password')
    parser.add_argument('-j', dest='subject', required=True)
    parser.add_argument('-m', dest='message_file', required=True)
    parser.add_argument('-N', dest='display_name', default=DEFAULT_DISPLAY_NAME)
    parser.add_argument('recipients', nargs='+')
    args = parser.parse_args()

    try:
        with open(args.message_file, 'r') as f: log_content = f.read()
    except: log_content = "Log file error."

    email_body, is_important = create_summary(log_content)
    send_email(args.subject, email_body, ",".join(args.recipients), args.sender, args.display_name,
               args.server, args.port, args.username, args.password, 'auto', 'auto', True, is_important)