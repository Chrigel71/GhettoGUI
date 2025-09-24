#!/usr/bin/env python
# -*- coding: utf-8 -*-
# GhettoVCB-GUI Sendmail (ESXi 6.0–8.03 kompatibel)
# V8.0 - Chrigel & Gemini fuer GhettoGUI 7.6 24.09.2025
# - FINAL: Das Skript wurde vereinfacht. Es generiert die Liste der verarbeiteten VMs nicht mehr selbst.
#          Stattdessen sucht es nach einem dedizierten Block im Log-File und fügt diesen direkt
#          in den HTML-Bericht ein. Das Shell-Skript ist nun die alleinige Quelle der Wahrheit.
# - FIX: HTML-Pfeil durch Text-Pfeil ersetzt für maximale Kompatibilität.

from __future__ import print_function

import sys, os, argparse, socket, subprocess, time
from datetime import datetime

try: import smtplib
except Exception: smtplib = None
try: from email.mime.text import MIMEText; from email.mime.multipart import MIMEMultipart; from email.header import Header; from email.utils import formatdate; HAVE_EMAIL = True
except Exception: MIMEText = MIMEMultipart = Header = formatdate = None; HAVE_EMAIL = False
try: _basestr = basestring
except NameError: _basestr = str

def html_escape(text):
    if not isinstance(text, _basestr):
        try: text = str(text)
        except Exception: text = repr(text)
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

def create_summary(log_content):
    summary = { "status": "Unbekannt", "duration": "N/A", "start_time": "N/A", "end_time": "N/A", "final_size": "N/A", "vms_processed_html_block": "", "errors": [], "warnings": [], "infos": [], "config": [], "storage_before": [], "storage_after": [], "directory_listing": [], "detailed_log": [] }
    in_config, in_storage_before, in_storage_after, in_listing, in_detailed, in_vms_block = (False, False, False, False, False, False)
    
    # Zähle die VMs für die Überschrift
    vm_count = 0
    for line in log_content.splitlines():
        if "initiate backup for" in line.lower():
            vm_count += 1

    vm_list_lines = []
    for line in log_content.splitlines():
        s = line.strip(); s_lower = s.lower()
        if "final status:" in s_lower: summary["status"] = s[s_lower.find("final status:") + len("final status:"):].replace("#", "").strip(); continue
        if "final size:" in s_lower: summary["final_size"] = s[s_lower.find("final size:") + len("final size:"):].strip(); continue
        
        # NEU: Suche nach dem Start- und End-Marker für unsere VM-Liste
        if s.startswith("--- Groessen der replizierten VMs ---"): in_vms_block = True; continue
        if s.startswith("--- Ende der VM-Verarbeitung ---"): in_vms_block = False; continue
        if in_vms_block and s: # Nur nicht-leere Zeilen hinzufügen
            vm_list_lines.append("<li>%s</li>" % html_escape(s))
            continue
            
        if "error:" in s_lower: summary["errors"].append(("Allgemein", s.split(":", 1)[-1].strip())); continue
        if s.startswith("Startzeit:") and summary["start_time"] == "N/A": summary["start_time"] = s.split(":", 1)[-1].strip(); continue
        if s.startswith("Endzeit:"): summary["end_time"] = s.split(":", 1)[-1].strip(); continue
        if s.startswith("Job-Konfiguration:"): in_config = True; continue
        if s.startswith("Speicherplatz (Vorher):"): in_config = False; in_storage_before = True; continue
        if s.startswith("Speicherplatz (Nachher):"): in_storage_before = False; in_storage_after = True; continue
        if s.startswith("--- START DES DETAILLOGS ---"): in_config=in_storage_before=in_storage_after=False; in_detailed = True; continue
        if s.startswith("--- ENDE DES DETAILLOGS ---"): in_detailed = False; continue
        if s.startswith("--- START Backup Directory Listing ---"): in_detailed = False; in_storage_after = False; in_listing = True; continue
        if s.startswith("--- END Backup Directory Listing ---"): in_listing = False; continue
        if in_config: summary["config"].append(s); continue
        if in_storage_before: summary["storage_before"].append(s); continue
        if in_storage_after: summary["storage_after"].append(s); continue
        if in_listing: summary["directory_listing"].append(line); continue
        if in_detailed: summary["detailed_log"].append(line); continue

    if vm_list_lines:
        summary["vms_processed_html_block"] = "<ul>" + "".join(vm_list_lines) + "</ul>"
    else:
        # Fallback, falls der Block nicht gefunden wird
        vms_from_initiate = []
        for line in log_content.splitlines():
            if "initiate backup for" in line.lower():
                vm_name = line[line.lower().find("initiate backup for") + len("initiate backup for"):].strip()
                if vm_name not in vms_from_initiate:
                    vms_from_initiate.append(vm_name)
        if vms_from_initiate:
            summary["vms_processed_html_block"] = "<ul>" + "".join(["<li>%s</li>" % html_escape(vm) for vm in vms_from_initiate]) + "</ul>"

    if summary["start_time"] != "N/A" and summary["end_time"] != "N/A":
        try:
            time_format = "%Y-%m-%d %H:%M:%S"; t1 = datetime.strptime(summary["start_time"].strip(), time_format); t2 = datetime.strptime(summary["end_time"].strip(), time_format)
            summary["duration"] = "%.2f Minutes" % ((t2 - t1).total_seconds() / 60.0)
        except ValueError: summary["duration"] = "Konnte nicht berechnet werden"

    status_color = "#28a745" if "OK" in summary["status"] else "#dc3545"
    parts = ["<html><head><meta charset='utf-8'><style>body{font-family:Arial,sans-serif;font-size:14px; margin:15px;}h2,h3,h4{color:#333} pre{font-family:monospace;background:#f8f8f8;padding:10px;border:1px solid #ddd;border-radius:4px;white-space:pre-wrap;word-wrap:break-word}ul{list-style-type:none;padding-left:0} li{margin-bottom:5px} li ul{margin-top:5px;margin-left:20px;list-style-type:circle}.error-vm{color:#b00020;font-weight:bold}</style></head><body>"]
    parts.append('<h2 style="color: %s;">Backup-Zusammenfassung</h2><hr>' % status_color)
    status_html = '<span style="color: %s; font-weight: bold;">%s</span>' % (status_color, html_escape(summary["status"]))
    parts.append('<p><b>Status:</b> %s</p>' % status_html)
    parts.append("<h4>Job-Details:</h4><ul><li><b>Startzeit:</b> %s</li><li><b>Endzeit:</b> %s</li><li><b>Dauer:</b> %s</li>" % (html_escape(summary["start_time"]), html_escape(summary["end_time"]), html_escape(summary["duration"])))
    if summary["final_size"] != "N/A": parts.append("<li><b>Groesse:</b> %s</li>" % html_escape(summary["final_size"]))
    parts.append("</ul><hr>")
    
    # NEU: Füge den vorformatierten HTML-Block ein
    parts.append("<h3>Verarbeitete VMs (%d)</h3>" % vm_count)
    parts.append(summary["vms_processed_html_block"] if summary["vms_processed_html_block"] else "<p>Keine.</p>")

    parts.append("<h3>Fehler (%d)</h3>" % len(summary["errors"]))
    parts.append("<ul>%s</ul>" % "".join('<li><strong class="error-vm">Kontext: %s</strong><ul><li>%s</li></ul></li>' % (html_escape(vm), html_escape(msg)) for vm, msg in summary["errors"]) if summary["errors"] else "<p>Keine.</p>")
    if summary["config"]: parts.append("<hr><h4>Konfiguration:</h4><ul>%s</ul>" % "".join("<li>%s</li>" % html_escape(i) for i in summary["config"]))
    if summary["storage_before"] or summary["storage_after"]: parts.append("<h4>Speicherplatz:</h4><pre>"); parts.append("<b>Nach dem Job:</b>\n" + "\n".join(html_escape(s) for s in summary["storage_after"]) if summary["storage_after"] else ""); parts.append("\n<b>Vor dem Job:</b>\n" + "\n".join(html_escape(s) for s in summary["storage_before"]) if summary["storage_before"] else ""); parts.append("</pre>")
    if summary["directory_listing"]: parts.append("<hr><h3>Inhalt des Ziel-Verzeichnisses</h3><pre>%s</pre>" % "\n".join(html_escape(x) for x in summary["directory_listing"]))
    if summary["detailed_log"]: parts.append("<hr><h3>Detailliertes Prozess-Log</h3><pre>%s</pre>" % "\n".join(html_escape(x) for x in summary["detailed_log"]))
    parts.append("</body></html>")
    return "\n".join(parts), bool(summary["errors"] or summary["warnings"])

# Der Rest der Datei (build_message, etc.) bleibt unverändert
def build_message(subject, html_body, to_csv, from_addr, is_important=False):
    try: body_decoded = html_body.decode('utf-8', 'replace') if isinstance(html_body, bytes) else html_body
    except NameError: body_decoded = html_body
    if HAVE_EMAIL:
        try:
            msg = MIMEMultipart(); msg['From'] = from_addr; msg['To'] = to_csv; msg['Subject'] = Header(subject, 'utf-8'); msg['Date'] = formatdate(localtime=True)
            if is_important: msg['Importance'] = 'high'; msg['X-Priority'] = '1'; msg['X-MSMail-Priority'] = 'High'
            msg.attach(MIMEText(body_decoded, 'html', 'utf-8')); return msg.as_string()
        except Exception: pass
    date_hdr = time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime())
    headers = ['From: %s' % from_addr, 'To: %s' % to_csv, 'Subject: %s' % subject, 'Date: %s' % date_hdr]
    if is_important: headers.extend(['Importance: high', 'X-Priority: 1', 'X-MSMail-Priority: High'])
    headers.extend(['MIME-Version: 1.0', 'Content-Type: text/html; charset=utf-8', '', body_decoded]); return "\r\n".join(headers)
def _split_recipients(to_str):
    if not to_str: return []
    return [chunk.strip() for chunk in to_str.replace(',', ' ').replace(';', ' ').split() if chunk.strip()]
def _smtp_try_send(subject, html_body, to_csv, from_addr, host, port, user, pwd, tls_mode, auth_mode, is_important=False):
    if smtplib is None: sys.stderr.write("WARN: smtplib not available...\n"); return False
    raw = build_message(subject, html_body, to_csv, from_addr, is_important)
    server = None
    try:
        if tls_mode == 'ssl': server = smtplib.SMTP_SSL(host, port, timeout=30)
        else:
            server = smtplib.SMTP(host, port, timeout=30)
            if tls_mode in ('auto', 'starttls') and 'starttls' in server.esmtp_features: server.starttls()
        server.ehlo()
        if bool(user and pwd): server.login(user, pwd)
        server.sendmail(from_addr, _split_recipients(to_csv), raw)
        server.quit(); sys.stdout.write("INFO: Email successfully sent to %s\n" % to_csv); return True
    except Exception as e:
        if server:
            try: server.quit()
            except Exception: pass
        sys.stderr.write("WARN: smtplib path failed: %s\n" % str(e)); return False
def _openssl_fallback(subject, html_body, to_csv, from_addr, host, port, user, pwd, tls_mode, auth_mode, is_important=False):
    def run_interactive_cmd(cmd, command_list):
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.5)
        for command in command_list: p.stdin.write(command.encode('utf-8')); p.stdin.flush(); time.sleep(0.3)
        p.stdin.close(); p.wait()
    recipients = _split_recipients(to_csv)
    if not recipients: raise RuntimeError("No recipients.")
    raw_email_content = build_message(subject, html_body, to_csv, from_addr, is_important)
    try: import base64 as b64mod
    except Exception: b64mod = None
    def b64(s):
        if b64mod is None: raise RuntimeError("No base64 available for AUTH.")
        return b64mod.b64encode(s.encode('utf-8')).decode('ascii')
    ehlo = (socket.gethostname().split('.')[0] or 'esxi')
    commands = ["EHLO %s\r\n" % ehlo]
    if bool(user and pwd): commands.extend(["AUTH LOGIN\r\n", "%s\r\n" % b64(user), "%s\r\n" % b64(pwd)])
    commands.append("MAIL FROM:<%s>\r\n" % from_addr)
    for r in recipients: commands.append("RCPT TO:<%s>\r\n" % r)
    commands.append("DATA\r\n")
    commands.append(raw_email_content.replace('\r\n', '\n').replace('\r', '\n').replace('\n', '\r\n') + "\r\n.\r\n")
    commands.append("QUIT\r\n")
    if port == 25 and tls_mode != 'ssl':
        try: run_interactive_cmd(['/bin/nc', host, str(port)], commands); sys.stdout.write("INFO: Email sent via 'nc'.\n"); return True
        except Exception as nc_e: sys.stderr.write("WARN: 'nc' fallback failed: %s.\n" % str(nc_e))
    tls_mode = (tls_mode or 'auto').lower()
    if tls_mode in ('auto', 'starttls'): cmd = ['/bin/openssl', 's_client', '-quiet', '-crlf', '-starttls', 'smtp', '-connect', '%s:%s' % (host, port)]
    elif tls_mode == 'ssl': cmd = ['/bin/openssl', 's_client', '-quiet', '-crlf', '-connect', '%s:%s' % (host, port)]
    else: raise RuntimeError("Unsupported TLS mode for openssl.")
    run_interactive_cmd(cmd, commands); sys.stdout.write("INFO: Email sent via openssl.\n"); return True
def send_email(subject, body, to_addr, from_addr, smtp_server, smtp_port_str, user, password, tls_mode, auth_mode, openssl_fallback=True, is_important=False):
    try: smtp_port = int(smtp_port_str)
    except ValueError: sys.stderr.write("ERROR: Invalid port: %s\n" % smtp_port_str); return
    if _smtp_try_send(subject, body, to_addr, from_addr, smtp_server, smtp_port, user, password, tls_mode, auth_mode, is_important): return
    if openssl_fallback:
        try:
            if _openssl_fallback(subject, body, to_addr, from_addr, smtp_server, smtp_port, user, password, tls_mode, auth_mode, is_important): return
        except Exception as e: sys.stderr.write("ERROR: Fallback method failed: %s\n" % str(e))
    sys.stderr.write("ERROR: Failed to send email (no usable transport)\n")
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='GhettoVCB Custom Sendmail Script (ESXi 6.0 compatible).')
    parser.add_argument('-f', dest='sender', required=True); parser.add_argument('-s', dest='server', required=True); parser.add_argument('-S', dest='port', required=True)
    parser.add_argument('-u', dest='username'); parser.add_argument('-p', dest='password'); parser.add_argument('-j', dest='subject', required=True); parser.add_argument('-m', dest='message_file', required=True)
    parser.add_argument('recipients', nargs='+'); parser.add_argument('--tls', choices=['auto', 'starttls', 'ssl', 'none'], default='auto')
    parser.add_argument('--auth', choices=['auto', 'login', 'plain', 'none'], default='auto'); parser.add_argument('--no-openssl-fallback', action='store_true', help='disable automatic openssl fallback')
    args = parser.parse_args(); recipients_str = ",".join(args.recipients)
    try:
        with open(args.message_file, 'r') as f: log_content = f.read()
    except Exception as e: sys.stderr.write("ERROR: Failed to read message file %s: %s\n" % (args.message_file, str(e))); sys.exit(1)
    email_body, is_important = create_summary(log_content)
    openssl_fb = (not args.no_openssl_fallback)
    send_email(args.subject, email_body, recipients_str, args.sender, args.server, args.port, args.username, args.password, tls_mode=args.tls, auth_mode=args.auth, openssl_fallback=openssl_fb, is_important=is_important)