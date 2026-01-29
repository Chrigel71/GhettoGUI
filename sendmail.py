#!/usr/bin/env python
# -*- coding: utf-8 -*-
# GhettoVCB-GUI Sendmail (ESXi 6.0 - 8.0 Compatible)
# V7.6 - Full HTML Report + ESXi 6 Netcat Fix
#
# Features:
# - Full HTML Summary (Parsing of GhettoVCB Logs)
# - Display Name Support (-N)
# - ESXi 6.0 Fix: Prioritizes 'nc' on Port 25 to avoid OpenSSL/Broken Pipe errors

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
    Erzeugt die volle HTML-Zusammenfassung (Original V7.3 Logic).
    """
    summary = {
        "status": "Unbekannt", "duration": "N/A", "start_time": "N/A", "end_time": "N/A",
        "final_size": "N/A",
        "vms_processed": [], "vm_report_lines": [], "errors": [], "warnings": [], "infos": [],
        "config": [], "storage_before": [], "storage_after": [], "directory_listing": [], "detailed_log": []
    }
    in_listing, in_storage_before, in_storage_after, in_config, in_detailed, in_vm_summary = (False, False, False, False, False, False)
    current_vm = "Allgemein"
    
    in_vm_sum = False
    vm_report_lines = []

    for line in log_content.splitlines():
        s = line.strip(); s_lower = s.lower()
        if ('zusammenfassung der geklonten vms' in s_lower) or ('summary of cloned vms' in s_lower): in_vm_sum = True; continue
        if in_vm_sum and (s.startswith('---') or 'backup duration' in s_lower or 'final status' in s_lower): in_vm_sum = False
        if in_vm_sum:
            if s.startswith('-') or '- ' in s:
                for entry in s.split('- '):
                    rep = entry.strip()
                    if rep.startswith('-'): rep = rep[1:].strip()
                    if rep: vm_report_lines.append(rep)
            continue
        if "final status:" in s_lower: summary["status"] = s[s_lower.find("final status:") + len("final status:"):].replace("#", "").strip(); continue
        if "final size:" in s_lower: summary["final_size"] = s[s_lower.find("final size:") + len("final size:"):].strip(); continue
        if "initiate backup for" in s_lower:
            vm = s[s_lower.find("initiate backup for") + len("initiate backup for"):].strip(); current_vm = vm
            if vm and vm not in summary["vms_processed"]: summary["vms_processed"].append(vm)
            continue
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
        if s.startswith("Startzeit:") and summary["start_time"] == "N/A": summary["start_time"] = s.split(":", 1)[-1].strip(); continue
        if s.startswith("Endzeit:"): summary["end_time"] = s.split(":", 1)[-1].strip(); continue
        if s.startswith("---") and ("zusammenfassung der" in s_lower or "groessen der" in s_lower): in_config=in_storage_before=in_storage_after=in_detailed=in_listing = False; in_vm_summary = True; continue
        if s.startswith("---") and in_vm_summary: in_vm_summary = False
        if in_vm_sum and s.startswith("-"): 
             for entry in s.split('- '):
                 r = entry.strip(); 
                 if r.startswith('-'): r=r[1:].strip()
                 if r: summary["vm_report_lines"].append(r)
             continue
        if s.startswith("Job-Konfiguration:"): in_config = True; continue
        if s.startswith("Speicherplatz (Vorher):"): in_config = False; in_storage_before = True; continue
        if s.startswith("Speicherplatz (Nachher):"): in_storage_before = False; in_storage_after = True; continue
        if s.startswith("--- START DES DETAILLOGS ---"): in_config=in_storage_before=in_storage_after=in_vm_summary=False; in_detailed = True; continue
        if s.startswith("--- ENDE DES DETAILLOGS ---"): in_detailed = False; continue
        if s.startswith("--- START Backup Directory Listing ---"): in_detailed=in_storage_after=False; in_listing = True; continue
        if s.startswith("--- END Backup Directory Listing ---"): in_listing = False; continue
        if in_config: summary["config"].append(s); continue
        if in_storage_before: summary["storage_before"].append(s); continue
        if in_storage_after: summary["storage_after"].append(s); continue
        if in_listing: summary["directory_listing"].append(line); continue
        if in_detailed: summary["detailed_log"].append(line); continue

    if summary["start_time"] != "N/A" and summary["end_time"] != "N/A":
        try:
            t1 = datetime.strptime(summary["start_time"].strip(), "%Y-%m-%d %H:%M:%S")
            t2 = datetime.strptime(summary["end_time"].strip(), "%Y-%m-%d %H:%M:%S")
            delta = t2 - t1; total_seconds = delta.total_seconds(); minutes, seconds = divmod(total_seconds, 60)
            summary["duration"] = "%d Minuten, %d Sekunden" % (minutes, seconds)
        except: summary["duration"] = "Konnte nicht berechnet werden"
    
    if summary.get('final_size', 'N/A') == 'N/A' and vm_report_lines:
        import re as _re
        total_gb = 0.0
        for _rep in vm_report_lines:
            m = _re.search(r':\s*([0-9\.]+)\s*([GM])B?', _rep, _re.IGNORECASE)
            if not m: m = _re.search(r'\(([^\s\)]+)\s*([GM]B?)\)', _rep, _re.IGNORECASE) or _re.search(r'\(([^\s\)]+)\s*([GM])\)', _rep, _re.IGNORECASE)
            if m:
                try:
                    val = float(m.group(1).replace(',', '.'))
                    unit = m.group(2).upper().replace('B','')
                    gb = val/1024.0 if unit.startswith('M') else val
                    total_gb += gb
                except: pass
        if total_gb > 0: summary['final_size'] = "{} GB".format(int(round(total_gb)))

    v_pretty = []
    for _rep in vm_report_lines:
        _src = _rep.split('->',1)[0].strip() if '->' in _rep else _rep
        m = re.search(r':\s*([0-9\.]+)\s*([GM])B?', _rep, re.IGNORECASE)
        if not m: m = re.search(r'\(([^\s\)]+)\s*([GM]B?)\)', _rep, re.IGNORECASE) or re.search(r'\(([^\s\)]+)\s*([GM])\)', _rep, re.IGNORECASE)
        if m:
            try:
                _val = float(m.group(1).replace(',', '.'))
                _unit = m.group(2).upper().replace('B','')
                _gb = _val/1024.0 if _unit.startswith('M') else _val
                v_pretty.append("{} ({} GB)".format(_src.split(':')[0], int(round(_gb))))
            except: v_pretty.append(_src)
        else: v_pretty.append(_src)
    summary['vm_report_lines'] = vm_report_lines
    summary['vms_processed_pretty'] = v_pretty
    
    status_text = summary["status"].lower()
    status_color = "#28a745" if "ok" in status_text or "erfolgreich" in status_text else "#dc3545"
    
    parts = ["<html><head><meta charset='utf-8'><style>body{font-family:Arial,sans-serif;font-size:14px; margin:15px;}h2,h3,h4{color:#333} pre{font-family:monospace;background:#f8f8f8;padding:10px;border:1px solid #ddd;border-radius:4px;white-space:pre-wrap;word-wrap:break-word}ul{list-style-type:none;padding-left:0} li{margin-bottom:5px} li ul{margin-top:5px;margin-left:20px;list-style-type:circle}.error-vm{color:#b00020;font-weight:bold} .warn-vm{color:#b06a00;font-weight:bold} .info-vm{color:#00579b;font-weight:bold}</style></head><body>"]
    parts.append('<h2 style="color: %s;">Backup-Zusammenfassung</h2><hr>' % status_color)
    status_html = '<span style="color: %s; font-weight: bold;">%s</span>' % (status_color, html_escape(summary["status"]))
    parts.append('<p><b>Status:</b> %s</p>' % status_html)
    parts.append("<h4>Job-Details:</h4><ul>")
    parts.append("<li><b>Startzeit:</b> %s</li>" % html_escape(summary["start_time"]))
    parts.append("<li><b>Endzeit:</b> %s</li>" % (html_escape(summary["end_time"]) if summary["end_time"] != "N/A" else "<em>Job nicht beendet</em>"))
    parts.append("<li><b>Dauer:</b> %s</li>" % html_escape(summary["duration"]))
    if summary["final_size"] != "N/A": parts.append("<li><b>Groesse:</b> %s</li>" % html_escape(summary["final_size"]))
    parts.append("</ul><hr>")
    if summary.get("vms_processed_pretty"):
        parts.append("<h3>Verarbeitete VMs (%d)</h3>" % len(summary["vms_processed_pretty"]))
        parts.append("<ul>%s</ul>" % "".join("<li>%s</li>" % html_escape(line) for line in summary["vms_processed_pretty"]))
    elif summary.get("vms_processed"):
        parts.append("<h3>Verarbeitete VMs (%d)</h3>" % len(summary["vms_processed"]))
        parts.append("<ul>%s</ul>" % "".join("<li>%s</li>" % html_escape(vm) for vm in summary["vms_processed"]))
    else: parts.append("<h3>Verarbeitete VMs (0)</h3><p>Keine.</p>")
    parts.append("<h3>Warnungen (%d)</h3>" % len(summary["warnings"]))
    parts.append("<ul>%s</ul>" % "".join('<li><strong class="warn-vm">VM: %s</strong><ul><li>%s</li></ul></li>' % (html_escape(vm), html_escape(msg)) for vm, msg in summary["warnings"]) if summary["warnings"] else "<p>Keine.</p>")
    parts.append("<h3>Fehler (%d)</h3>" % len(summary["errors"]))
    parts.append("<ul>%s</ul>" % "".join('<li><strong class="error-vm">VM: %s</strong><ul><li>%s</li></ul></li>' % (html_escape(vm), html_escape(msg)) for vm, msg in summary["errors"]) if summary["errors"] else "<p>Keine.</p>")
    if summary["config"]: parts.append("<hr><h4>Konfiguration:</h4><ul>%s</ul>" % "".join("<li>%s</li>" % html_escape(i) for i in summary["config"]))
    if summary["storage_before"] or summary["storage_after"]: parts.append("<h4>Speicherplatz:</h4><pre>"); parts.append("<b>Nach dem Job:</b>\n" + "\n".join(html_escape(s) for s in summary["storage_after"]) if summary["storage_after"] else ""); parts.append("\n<b>Vor dem Job:</b>\n" + "\n".join(html_escape(s) for s in summary["storage_before"]) if summary["storage_before"] else ""); parts.append("</pre>")
    if summary["directory_listing"]: parts.append("<hr><h3>Detailliertes Verzeichnis-Listing</h3><pre>%s</pre>" % "\n".join(html_escape(x) for x in summary["directory_listing"]))
    if summary["detailed_log"]: parts.append("<hr><h3>Detailliertes Prozess-Log</h3><pre>%s</pre>" % "\n".join(html_escape(x) for x in summary["detailed_log"]))
    parts.append("</body></html>")
    return "\n".join(parts), (len(summary["errors"]) > 0 or len(summary["warnings"]) > 0)


def build_message(subject, html_body, to_csv, from_addr, display_name, is_important=False):
    # Versuch mit Python Email Lib (falls vorhanden)
    if HAVE_EMAIL:
        try:
            msg = MIMEMultipart()
            try:
                dn_header = Header(display_name, 'utf-8').encode()
                msg['From'] = formataddr((dn_header, from_addr))
            except: msg['From'] = from_addr
            
            msg['To'] = to_csv
            try: msg['Subject'] = Header(subject, 'utf-8')
            except: msg['Subject'] = subject
            try: msg['Date'] = formatdate(localtime=True)
            except: pass
            if is_important: msg['Importance'] = 'high'; msg['X-Priority'] = '1'; msg['X-MSMail-Priority'] = 'High'
            msg.attach(MIMEText(html_body, 'html', 'utf-8'))
            return msg.as_string()
        except: pass

    # Fallback: Manueller Header Bau
    date_hdr = time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime())
    full_from = '"%s" <%s>' % (display_name, from_addr)
    headers = []
    headers.append('From: %s' % full_from)
    headers.append('To: %s' % to_csv)
    headers.append('Subject: %s' % subject)
    headers.append('Date: %s' % date_hdr)
    if is_important: headers.append('Importance: high'); headers.append('X-Priority: 1')
    headers.append('MIME-Version: 1.0')
    headers.append('Content-Type: text/html; charset=utf-8')
    headers.append('Content-Transfer-Encoding: 8bit')
    headers.append('') 
    headers.append(html_body)
    return "\r\n".join(headers)

def _split_recipients(to_str):
    if not to_str: return []
    s = to_str.replace(',', ' ').replace(';', ' ')
    return [chunk.strip() for chunk in s.split() if chunk.strip()]

def _smtp_try_send(subject, html_body, to_csv, from_addr, display_name, host, port, user, pwd, tls_mode, auth_mode, is_important=False):
    if smtplib is None: sys.stderr.write("WARN: smtplib not available; skipping\n"); return False
    # Auf ESXi 6 meist kaputt, aber der Vollstaendigkeit halber drin
    try:
        raw = build_message(subject, html_body, to_csv, from_addr, display_name, is_important)
        server = smtplib.SMTP(host, port, timeout=30); server.ehlo()
        if tls_mode in ('auto', 'starttls'):
            try: has_tls = server.has_extn('starttls') or server.has_extn('STARTTLS')
            except: has_tls = False
            if has_tls: server.starttls(); server.ehlo()
        if user and pwd: server.login(user, pwd)
        server.sendmail(from_addr, _split_recipients(to_csv), raw)
        try: server.quit()
        except: pass
        sys.stdout.write("INFO: Email successfully sent (smtplib)\n")
        return True
    except: return False

def _openssl_fallback(subject, html_body, to_csv, from_addr, display_name, host, port, user, pwd, tls_mode, auth_mode, is_important=False):
    recipients = _split_recipients(to_csv)
    if not recipients: raise RuntimeError("No recipients.")
    
    raw_email_content = build_message(subject, html_body, to_csv, from_addr, display_name, is_important)
    
    try: import base64 as b64mod
    except: b64mod = None
    def b64(s):
        if b64mod is None: raise RuntimeError("No base64 available.")
        if not isinstance(s, _basestr): s = str(s)
        out = b64mod.b64encode(s.encode('utf-8'))
        try: return out.decode('ascii')
        except: return out

    ehlo = (socket.gethostname().split('.')[0] or 'esxi')
    commands = ["EHLO %s\r\n" % ehlo]
    
    if user and pwd:
        commands.append("AUTH LOGIN\r\n")
        commands.append("%s\r\n" % b64(user))
        commands.append("%s\r\n" % b64(pwd))
    
    commands.append("MAIL FROM:<%s>\r\n" % from_addr)
    for r in recipients: commands.append("RCPT TO:<%s>\r\n" % r)
    commands.append("DATA\r\n")
    
    if isinstance(raw_email_content, bytes):
        try: raw_email_content = raw_email_content.decode('utf-8')
        except: raw_email_content = str(raw_email_content)
    
    normalized = raw_email_content.replace('\r\n', '\n').replace('\r', '\n')
    commands.append(normalized.replace('\n', '\r\n') + "\r\n.\r\n")
    commands.append("QUIT\r\n")

    def run_interactive(cmd_list):
        p = subprocess.Popen(cmd_list, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            # Zeilenweiser Versand mit Pause für ESXi 6 Puffer-Management
            for c in commands:
                p.stdin.write(c.encode('utf-8'))
                p.stdin.flush()
                time.sleep(0.2) 
        except IOError: pass # Catch Broken Pipe
        except Exception: pass
            
        try: p.stdin.close()
        except: pass
        out = p.stdout.read()
        err = p.stderr.read()
        p.wait()
        return out, err

    # --- ESXi 6 LOGIC (NC FALLBACK) ---
    use_nc = False
    if port == 25 and tls_mode != 'ssl': use_nc = True
    
    if use_nc:
        sys.stdout.write("INFO: Port 25 on ESXi 6 -> forcing 'nc' fallback...\n")
        cmd = ['/bin/nc', host, str(port)]
    else:
        if tls_mode == 'ssl': cmd = ['/bin/openssl', 's_client', '-quiet', '-crlf', '-connect', '%s:%s' % (host, port)]
        else: cmd = ['/bin/openssl', 's_client', '-quiet', '-crlf', '-starttls', 'smtp', '-connect', '%s:%s' % (host, port)]

    out, err = run_interactive(cmd)
    out_str = str(out)
    
    if "250" in out_str or "queued" in out_str.lower() or "ok" in out_str.lower():
         sys.stdout.write("INFO: Email successfully sent (fallback)\n")
         return True
    
    # Retry nc if openssl failed
    if not use_nc and ("connect:errno" in str(err) or "handshake failure" in str(err) or "Broken pipe" in str(err)):
        sys.stderr.write("WARN: OpenSSL failed. Retrying with nc...\n")
        cmd = ['/bin/nc', host, str(port)]
        out, err = run_interactive(cmd)
        if "250" in str(out) or "queued" in str(out).lower():
             sys.stdout.write("INFO: Email successfully sent (nc fallback)\n")
             return True

    if "250" not in str(out) and "queued" not in str(out).lower():
         sys.stderr.write("DEBUG OUT: %s\n" % str(out))
         sys.stderr.write("DEBUG ERR: %s\n" % str(err))
         raise RuntimeError("SMTP conversation failed")
         
    return True

def send_email(subject, body, to_addr, from_addr, display_name, smtp_server, smtp_port_str, user, password, tls_mode, auth_mode, openssl_fallback=True, is_important=False):
    try: smtp_port = int(smtp_port_str)
    except: sys.stderr.write("ERROR: Invalid port\n"); return
    
    if _smtp_try_send(subject, body, to_addr, from_addr, display_name, smtp_server, smtp_port, user, password, tls_mode, auth_mode, is_important): return
    if openssl_fallback:
        try: _openssl_fallback(subject, body, to_addr, from_addr, display_name, smtp_server, smtp_port, user, password, tls_mode, auth_mode, is_important); return
        except Exception as e: sys.stderr.write("ERROR: Fallback failed: %s\n" % str(e))
    sys.stderr.write("ERROR: Failed to send email\n")

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
    parser.add_argument('--tls', default='auto')
    parser.add_argument('--auth', default='auto')
    parser.add_argument('--no-openssl-fallback', action='store_true')

    args = parser.parse_args()
    recipients_str = ",".join(args.recipients)

    try:
        with open(args.message_file, 'r') as f: log_content = f.read()
    except: log_content = "Log file content read error."

    email_body, is_important = create_summary(log_content)
    openssl_fb = (not args.no_openssl_fallback)
    
    send_email(args.subject, email_body, recipients_str, args.sender, args.display_name,
               args.server, args.port, args.username, args.password,
               tls_mode=args.tls, auth_mode=args.auth, openssl_fallback=openssl_fb, is_important=is_important)