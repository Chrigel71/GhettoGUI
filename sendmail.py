#!/usr/bin/env python
# -*- coding: utf-8 -*-
# GhettoVCB-GUI Sendmail (ESXi 6.0–8.03 kompatibel)
# V5 - Chrigel & Gemini
# - FIX: Verwendet jetzt absolute Pfade (/bin/nc, /bin/openssl), um in der
#   minimalistischen cron-Umgebung von ESXi zuverlässig zu funktionieren.
# - FIX: Sendet Befehle interaktiv (Zeile für Zeile mit Pausen), um Kompatibilität
#   mit dem 'nc' (netcat) Befehl auf ESXi 6.0 sicherzustellen.

from __future__ import print_function

import sys, os, argparse, socket, subprocess, time

# smtplib kann auf ESXi 6.0 fehlen
try:
    import smtplib
except Exception:
    smtplib = None

# email.mime kann auf ESXi 6.0 fehlen
try:
    from email.mime.text import MIMEText
    from email.mime.multipart import MIMEMultipart
    from email.header import Header
    from email.utils import formatdate
    HAVE_EMAIL = True
except Exception:
    MIMEText = MIMEMultipart = Header = formatdate = None
    HAVE_EMAIL = False

# Python2/3 Kompatibilität
try:
    _basestr = basestring  # py2
except NameError:
    _basestr = str         # py3


def html_escape(text):
    if not isinstance(text, _basestr):
        try:
            text = str(text)
        except Exception:
            text = repr(text)
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

def create_summary(log_content):
    """
    Erzeugt eine universelle HTML-Zusammenfassung und prüft auf Fehler/Warnungen.
    Gibt (html_body, is_important) zurück.
    """
    summary = {
        "status": "Unbekannt", "duration": "N/A", "start_time": "N/A", "end_time": "N/A",
        "final_size": "N/A", # NEU: Feld für die Grösse
        "vms_processed": [],
        "errors": [], "warnings": [], "infos": [], # NEU: Feld für Infos
        "config": [], "storage_before": [], "storage_after": [],
        "directory_listing": [], "detailed_log": []
    }
    in_listing, in_storage_before, in_storage_after, in_config, in_detailed = (False, False, False, False, False)
    current_vm = "Allgemein"
    is_detailed_log = False
    storage_header = None

    for line in log_content.splitlines():
        s = line.strip()
        s_lower = s.lower()

        # --- Parsing Logik ---
        if "final status:" in s_lower:
            summary["status"] = s[s_lower.find("final status:") + len("final status:"):].replace("#", "").strip()
            continue
        if "backup duration:" in s_lower:
            summary["duration"] = s[s_lower.find("backup duration:") + len("backup duration:"):].strip()
            continue
        # NEU: Final size parsen
        if "final size:" in s_lower:
            summary["final_size"] = s[s_lower.find("final size:") + len("final size:"):].strip()
            continue
        if "initiate backup for" in s_lower:
            vm = s[s_lower.find("initiate backup for") + len("initiate backup for"):].strip()
            current_vm = vm
            if vm and vm not in summary["vms_processed"]:
                summary["vms_processed"].append(vm)
            continue

        # NEU: smtplib-Warnung als INFO behandeln
        if "warn:" in s_lower and "smtplib not available" in s_lower:
            msg = s[s_lower.find("warn:") + len("warn:"):].strip()
            summary["infos"].append(("ESXi Host", msg))
            continue
        if ("warn:" in s_lower or "warning:" in s_lower) and "permanently added" not in s_lower:
            find_str = "warning:" if "warning:" in s_lower else "warn:"
            msg = s[s_lower.find(find_str) + len(find_str):].strip()
            vm_context = current_vm
            if msg.startswith("[") and "]" in msg:
                vm_context = msg.split(']')[0][1:]; msg = msg.split('] - ', 1)[-1]
            summary["warnings"].append((vm_context, msg))
            continue
        
        if "error:" in s_lower:
            msg = s[s_lower.find("error:") + len("error:"):].strip()
            vm_context = current_vm
            if msg.startswith("[") and "]" in msg:
                vm_context = msg.split(']')[0][1:]; msg = msg.split('] - ', 1)[-1]
            summary["errors"].append((vm_context, msg))
            continue
            
        if s.startswith("Startzeit:"):
            summary["start_time"] = s.split(":", 1)[-1].strip(); is_detailed_log = True; continue
        if s.startswith("Endzeit:"):
            summary["end_time"] = s.split(":", 1)[-1].strip(); is_detailed_log = True; continue
        if s.startswith("Job-Konfiguration:"): in_config = True; continue
        if s.startswith("Speicherplatz (Vorher):"): in_config = False; in_storage_before = True; continue
        if s.startswith("Speicherplatz (Nachher):"): in_storage_before = False; in_storage_after = True; continue
        if s.startswith("--- START DES DETAILLOGS ---"): in_config=in_storage_before=in_storage_after=False; in_detailed = True; continue
        if s.startswith("--- ENDE DES DETAILLOGS ---"): in_detailed = False; continue
        if s.startswith("--- START Backup Directory Listing ---"): in_detailed = False; in_storage_after = False; in_listing = True; continue
        if s.startswith("--- END Backup Directory Listing ---"): in_listing = False; continue

        if in_config: summary["config"].append(s); continue
        if in_storage_before:
            if "filesystem" in s_lower and "mounted on" in s_lower: storage_header = s
            summary["storage_before"].append(s)
            continue
        if in_storage_after: summary["storage_after"].append(s); continue
        if in_listing: summary["directory_listing"].append(line); continue
        if in_detailed: summary["detailed_log"].append(line); continue

    # --- HTML-Erstellung ---
    status_color = "#28a745" if "OK" in summary["status"] or "erfolgreich" in summary["status"].lower() else "#dc3545"
    parts = ["<html><head><meta charset='utf-8'><style>body{font-family:Arial,sans-serif;font-size:14px; margin:15px;}h2,h3,h4{color:#333} pre{font-family:monospace;background:#f8f8f8;padding:10px;border:1px solid #ddd;border-radius:4px;white-space:pre-wrap;word-wrap:break-word}ul{list-style-type:none;padding-left:0} li{margin-bottom:5px} li ul{margin-top:5px;margin-left:20px;list-style-type:circle}.error-vm{color:#b00020;font-weight:bold} .warn-vm{color:#b06a00;font-weight:bold} .info-vm{color:#00579b;font-weight:bold}</style></head><body>"]
    parts.append('<h2 style="color: %s;">Backup-Zusammenfassung</h2><hr>' % status_color)
    status_html = '<span style="color: %s; font-weight: bold;">%s</span>' % (status_color, html_escape(summary["status"]))
    
    parts.append('<p><b>Status:</b> %s</p>' % status_html)
    parts.append("<h4>Job-Details:</h4><ul>")
    parts.append("<li><b>Startzeit:</b> %s</li>" % html_escape(summary["start_time"]))
    parts.append("<li><b>Endzeit:</b> %s</li>" % (html_escape(summary["end_time"]) if summary["end_time"] != "N/A" else "<em>Job nicht beendet</em>"))
    parts.append("<li><b>Dauer:</b> %s</li>" % html_escape(summary["duration"]))
    # NEU: Füge die Grösse hinzu, wenn vorhanden
    if summary["final_size"] != "N/A":
        parts.append("<li><b>Grösse:</b> %s</li>" % html_escape(summary["final_size"]))
    parts.append("</ul>")

    parts.append("<hr>")
    parts.append("<h3>Verarbeitete VMs (%d)</h3>" % len(summary["vms_processed"]))
    parts.append("<ul>%s</ul>" % "".join("<li>%s</li>" % html_escape(vm) for vm in summary["vms_processed"]) if summary["vms_processed"] else "<p>Keine.</p>")
    
    # NEU: Info-Sektion hinzufügen
    parts.append("<h3>Informationen (%d)</h3>" % len(summary["infos"]))
    parts.append("<ul>%s</ul>" % "".join('<li><strong class="info-vm">Kontext: %s</strong><ul><li>%s</li></ul></li>' % (html_escape(vm), html_escape(msg)) for vm, msg in summary["infos"]) if summary["infos"] else "<p>Keine.</p>")

    parts.append("<h3>Warnungen (%d)</h3>" % len(summary["warnings"]))
    parts.append("<ul>%s</ul>" % "".join('<li><strong class="warn-vm">VM: %s</strong><ul><li>%s</li></ul></li>' % (html_escape(vm), html_escape(msg)) for vm, msg in summary["warnings"]) if summary["warnings"] else "<p>Keine.</p>")
    parts.append("<h3>Fehler (%d)</h3>" % len(summary["errors"]))
    parts.append("<ul>%s</ul>" % "".join('<li><strong class="error-vm">VM: %s</strong><ul><li>%s</li></ul></li>' % (html_escape(vm), html_escape(msg)) for vm, msg in summary["errors"]) if summary["errors"] else "<p>Keine.</p>")
        
    if summary["config"]: parts.append("<hr><h4>Konfiguration:</h4><ul>%s</ul>" % "".join("<li>%s</li>" % html_escape(i) for i in summary["config"]))
    if summary["storage_before"] or summary["storage_after"]: parts.append("<h4>Speicherplatz:</h4><pre>"); parts.append("<b>Nach dem Job:</b>\n" + "\n".join(html_escape(s) for s in summary["storage_after"]) if summary["storage_after"] else ""); parts.append("\n<b>Vor dem Job:</b>\n" + "\n".join(html_escape(s) for s in summary["storage_before"]) if summary["storage_before"] else ""); parts.append("</pre>")
    if summary["directory_listing"]: parts.append("<hr><h3>Inhalt des Ziel-Verzeichnisses</h3><pre>%s</pre>" % "\n".join(html_escape(x) for x in summary["directory_listing"]))
    if summary["detailed_log"]: parts.append("<hr><h3>Detailliertes Prozess-Log</h3><pre>%s</pre>" % "\n".join(html_escape(x) for x in summary["detailed_log"]))
    parts.append("</body></html>")
    
    is_important = len(summary["errors"]) > 0 or len(summary["warnings"]) > 0
    return "\n".join(parts), is_important

def build_message(subject, html_body, to_csv, from_addr, is_important=False):
    """
    Erzeugt die MIME-Nachricht als String.
    """
    try:
        body_decoded = html_body.decode('utf-8', 'replace') if isinstance(html_body, bytes) else html_body
    except NameError:
        body_decoded = html_body

    if HAVE_EMAIL:
        try:
            msg = MIMEMultipart()
            msg['From'] = from_addr
            msg['To'] = to_csv
            try:
                msg['Subject'] = Header(subject, 'utf-8')
            except Exception:
                msg['Subject'] = subject
            try:
                msg['Date'] = formatdate(localtime=True)
            except Exception:
                pass
            
            if is_important:
                msg['Importance'] = 'high'
                msg['X-Priority'] = '1'
                msg['X-MSMail-Priority'] = 'High'
                
            msg.attach(MIMEText(body_decoded, 'html', 'utf-8'))
            return msg.as_string()
        except Exception:
            pass

    date_hdr = time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime())
    headers = [
        'From: %s' % from_addr,
        'To: %s' % to_csv,
        'Subject: %s' % subject,
        'Date: %s' % date_hdr,
    ]
    if is_important:
        headers.append('Importance: high')
        headers.append('X-Priority: 1')
        headers.append('X-MSMail-Priority: High')
        
    headers.extend([
        'MIME-Version: 1.0',
        'Content-Type: text/html; charset=utf-8',
        'Content-Transfer-Encoding: 8bit',
        '',
        body_decoded,
    ])
    return "\r\n".join(headers)


def _split_recipients(to_str):
    if not to_str:
        return []
    s = to_str.replace(',', ' ').replace(';', ' ')
    return [chunk.strip() for chunk in s.split() if chunk.strip()]


def _smtp_try_send(subject, html_body, to_csv, from_addr, host, port, user, pwd,
                   tls_mode, auth_mode, is_important=False):
    if smtplib is None:
        sys.stderr.write("WARN: smtplib not available on this host; skipping smtplib path\n")
        return False

    raw = build_message(subject, html_body, to_csv, from_addr, is_important)
    server = None
    try:
        if tls_mode == 'ssl':
            if hasattr(smtplib, 'SMTP_SSL'):
                server = smtplib.SMTP_SSL(host, port, timeout=30)
                try: server.ehlo()
                except Exception: pass
            else:
                raise RuntimeError("SMTP_SSL not available in this Python.")
        else:
            server = smtplib.SMTP(host, port, timeout=30)
            try: server.ehlo()
            except Exception: pass
            if tls_mode in ('auto', 'starttls'):
                try: has_tls = server.has_extn('starttls') or server.has_extn('STARTTLS')
                except Exception: has_tls = False
                if has_tls:
                    server.starttls()
                    try: server.ehlo()
                    except Exception: pass
                elif tls_mode == 'starttls':
                    raise RuntimeError("Server does not support STARTTLS.")
        do_auth = False
        if auth_mode == 'none': do_auth = False
        elif auth_mode in ('auto', 'login', 'plain'): do_auth = bool(user and pwd)
        if do_auth:
            server.login(user, pwd)
        server.sendmail(from_addr, _split_recipients(to_csv), raw)
        try: server.quit()
        except Exception: pass
        sys.stdout.write("INFO: Email successfully sent to %s\n" % to_csv)
        return True
    except Exception as e:
        if server:
            try: server.quit()
            except Exception: pass
        sys.stderr.write("WARN: smtplib path failed: %s\n" % str(e))
        return False


def _openssl_fallback(subject, html_body, to_csv, from_addr, host, port, user, pwd,
                      tls_mode, auth_mode, is_important=False):
    
    # NEU: Interaktive Sende-Funktion
    def run_interactive_cmd(cmd, command_list):
        try:
            p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as oe:
            raise RuntimeError("Cannot exec %s: %s" % (" ".join(cmd), str(oe)))
        
        time.sleep(0.5)
        
        for command in command_list:
            p.stdin.write(command.encode('utf-8'))
            p.stdin.flush()
            time.sleep(0.3)
        
        p.stdin.close()
        
        out = p.stdout.read()
        err = p.stderr.read()
        rc = p.wait()

        if rc != 0 and "can't open config file" not in err.decode('utf-8', 'ignore'):
             if not (cmd[0].endswith('openssl') and rc == 1):
                raise RuntimeError("Tool failed (rc=%s): %s" % (rc, (err or b'').decode('utf-8', 'ignore')))
        return out, err

    recipients = _split_recipients(to_csv)
    if not recipients:
        raise RuntimeError("No recipients.")

    raw_email_content = build_message(subject, html_body, to_csv, from_addr, is_important)

    try: import base64 as b64mod
    except Exception: b64mod = None

    def b64(s):
        if b64mod is None: raise RuntimeError("No base64 available for AUTH.")
        if not isinstance(s, _basestr): s = str(s)
        out = b64mod.b64encode(s.encode('utf-8'))
        try: return out.decode('ascii')
        except Exception: return out

    ehlo = (socket.gethostname().split('.')[0] or 'esxi')
    
    commands = []
    commands.append("EHLO %s\r\n" % ehlo)
    
    do_auth = bool(user and pwd)
    if do_auth:
        commands.append("AUTH LOGIN\r\n")
        commands.append("%s\r\n" % b64(user))
        commands.append("%s\r\n" % b64(pwd))

    commands.append("MAIL FROM:<%s>\r\n" % from_addr)
    for r in recipients:
        commands.append("RCPT TO:<%s>\r\n" % r)
    commands.append("DATA\r\n")
    
    if isinstance(raw_email_content, bytes):
        try: raw_email_content = raw_email_content.decode('utf-8')
        except: raw_email_content = str(raw_email_content)
    
    normalized_content = raw_email_content.replace('\r\n', '\n').replace('\r', '\n')
    final_email_data = normalized_content.replace('\n', '\r\n')
    
    commands.append(final_email_data + "\r\n.\r\n")
    commands.append("QUIT\r\n")

    # Intelligenter Fallback für ESXi 6.0 auf Port 25
    if port == 25 and tls_mode != 'ssl':
        try:
            sys.stdout.write("INFO: Port 25, attempting unencrypted interactive fallback with 'nc'...\n")
            cmd = ['/bin/nc', host, str(port)] # NEU: Absoluter Pfad
            run_interactive_cmd(cmd, commands)
            sys.stdout.write("INFO: Email successfully sent to %s ('nc' fallback)\n" % to_csv)
            return True
        except Exception as nc_e:
            sys.stderr.write("WARN: 'nc' fallback failed: %s. Proceeding...\n" % str(nc_e))

    # Bestehende openssl Logik als zweiter Fallback
    tls_mode = (tls_mode or 'auto').lower()
    if tls_mode in ('auto', 'starttls'):
        cmd = ['/bin/openssl', 's_client', '-quiet', '-crlf', '-starttls', 'smtp', '-connect', '%s:%s' % (host, port)] # NEU: Absoluter Pfad
    elif tls_mode == 'ssl':
        cmd = ['/bin/openssl', 's_client', '-quiet', '-crlf', '-connect', '%s:%s' % (host, port)] # NEU: Absoluter Pfad
    else:
        cmd = ['/bin/nc', host, str(port)] # NEU: Absoluter Pfad
        
    run_interactive_cmd(cmd, commands)
    sys.stdout.write("INFO: Email successfully sent to %s (openssl fallback)\n" % to_csv)
    return True


def send_email(subject, body, to_addr, from_addr, smtp_server, smtp_port_str, user, password,
               tls_mode, auth_mode, openssl_fallback=True, is_important=False):
    try:
        smtp_port = int(smtp_port_str)
    except Exception:
        sys.stderr.write("ERROR: Invalid port: %s\n" % smtp_port_str)
        return

    ok = _smtp_try_send(subject, body, to_addr, from_addr, smtp_server, smtp_port,
                        user, password, tls_mode, auth_mode, is_important)
    if ok:
        return

    if openssl_fallback:
        try:
            _openssl_fallback(subject, body, to_addr, from_addr, smtp_server, smtp_port,
                              user, password, tls_mode, auth_mode, is_important)
            return
        except Exception as e:
            sys.stderr.write("ERROR: Fallback method failed: %s\n" % str(e))

    sys.stderr.write("ERROR: Failed to send email (no usable transport)\n")


# --- Main ---
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='GhettoVCB Custom Sendmail Script (ESXi 6.0 compatible).')
    parser.add_argument('-f', dest='sender', required=True)
    parser.add_argument('-s', dest='server', required=True)
    parser.add_argument('-S', dest='port', required=True)
    parser.add_argument('-u', dest='username')
    parser.add_argument('-p', dest='password')
    parser.add_argument('-j', dest='subject', required=True)
    parser.add_argument('-m', dest='message_file', required=True)
    parser.add_argument('recipients', nargs='+')
    parser.add_argument('--tls', choices=['auto', 'starttls', 'ssl', 'none'], default='auto')
    parser.add_argument('--auth', choices=['auto', 'login', 'plain', 'none'], default='auto')
    parser.add_argument('--no-openssl-fallback', action='store_true', help='disable automatic openssl fallback')

    args = parser.parse_args()
    recipients_str = ",".join(args.recipients)

    try:
        with open(args.message_file, 'r') as f:
            log_content = f.read()
    except Exception as e:
        sys.stderr.write("ERROR: Failed to read message file %s: %s\n" % (args.message_file, str(e)))
        sys.exit(1)

    email_body, is_important = create_summary(log_content)

    openssl_fb = (not args.no_openssl_fallback)
    send_email(args.subject, email_body, recipients_str, args.sender,
               args.server, args.port, args.username, args.password,
               tls_mode=args.tls, auth_mode=args.auth, openssl_fallback=openssl_fb, is_important=is_important)