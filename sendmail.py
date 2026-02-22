#!/usr/bin/env python
# -*- coding: utf-8 -*-
# GhettoVCB-GUI 8.8.0 Sendmail (ESXi 6.0 - 8.0 Compatible)
# V9.5 - Fix: Reliable SMTP for Port 25 + Port 587 (STARTTLS) on ESXi6/ESXi8
# Patch: Hardened OpenSSL/NC fallback for ESXi 6 email-log sending (keeps ESXi 8 behavior).
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
    # Fix: Variable für Tail-Log Suche definieren
    all_lines = log_content.splitlines() 
    
    summary = {
        "status": "Unbekannt", "duration": "N/A", "start_time": "N/A", "end_time": "N/A",
        "final_size": "N/A", "avg_speed": "N/A",
        "vms_processed": [], "vm_report_lines": [], "errors": [], "warnings": [], "infos": [],
        "config": [], "storage_before": [], "storage_after": [], "directory_listing": [], "detailed_log": [],
        "source_host": "N/A", "target_host": "N/A", "target_datastore": "N/A"
    }
    in_listing, in_storage_before, in_storage_after, in_config, in_detailed = (False, False, False, False, False)
    current_vm = "Allgemein"
    
    in_vm_sum = False
    vm_report_lines = []
    
    for line in all_lines:
        s = line.strip(); s_lower = s.lower()
        
        # Sektions-Erkennung für die Zusammenfassung (Details)
        if ('zusammenfassung der' in s_lower) or ('summary of' in s_lower) or ('backup-zusammenfassung' in s_lower):
            in_vm_sum = True; continue
        if in_vm_sum and (s.startswith('---') or 'backup duration' in s_lower or 'final status' in s_lower or s.startswith('===')):
            in_vm_sum = False; continue

        if in_vm_sum:
            if "VM-Name:" in s and "Groesse" in s: continue
            if s.startswith('-') or '- ' in s:
                for entry in s.split('- '):
                    rep = entry.strip()
                    if rep.startswith('-'): rep = rep[1:].strip()
                    if rep and "VM-Name:" not in rep: vm_report_lines.append(rep)
            elif s and "VM-Name:" not in s:
                vm_report_lines.append(s)
            continue

        if "final status:" in s_lower: 
            summary["status"] = s[s_lower.find("final status:") + len("final status:"):].replace("#", "").strip(); continue

        if "average speed:" in s_lower:
            summary["avg_speed"] = s[s_lower.find("average speed:") + len("average speed:"):].strip(); continue
            
        if "initiate backup for" in s_lower:
            vm = s[s_lower.find("initiate backup for") + len("initiate backup for"):].strip(); current_vm = vm
            if vm and vm not in summary["vms_processed"]: summary["vms_processed"].append(vm)
            continue

        # Zusätzliche ESXi/GhettoVCB Fehlerzeilen ohne "error:"-Prefix
        if ("failed to clone disk" in s_lower) or ("disklib_check()" in s_lower) or ("disklib_check" in s_lower and "failed" in s_lower):
            vm_context = current_vm if current_vm else "Allgemein"
            summary["errors"].append((vm_context, s)); continue
        if ("the file already exists" in s_lower) and ("clone" in s_lower or "vmdk" in s_lower):
            vm_context = current_vm if current_vm else "Allgemein"
            summary["errors"].append((vm_context, s)); continue

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

                # --- Direkte Replikation: Quell/Ziel Host & Datastore erkennen ---
        if in_config:
            # Logformat: "- Quell-Host: 192.168...."
            m = re.match(r'^\-+\s*Quell-Host:\s*(.+)$', s, re.IGNORECASE)
            if m:
                summary["source_host"] = m.group(1).strip()
                continue

            m = re.match(r'^\-+\s*Ziel-Host:\s*(.+)$', s, re.IGNORECASE)
            if m:
                summary["target_host"] = m.group(1).strip()
                continue

            m = re.match(r'^\-+\s*Ziel-Datastore:\s*(.+)$', s, re.IGNORECASE)
            if m:
                summary["target_datastore"] = m.group(1).strip()
                continue


        # Zeitstempel & Blöcke
        if s.startswith("Startzeit:") and summary["start_time"] == "N/A": summary["start_time"] = s.split(":", 1)[-1].strip(); continue
        if s.startswith("Endzeit:"): summary["end_time"] = s.split(":", 1)[-1].strip(); continue
        if "- Quell-Host:" in s:
            summary["source_host"] = s.split(":", 1)[-1].strip()
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

    # --- Dauer und Gesamt-Sekunden berechnen ---
    total_seconds = 0
    if summary["start_time"] != "N/A" and summary["end_time"] != "N/A":
        try:
            t1 = datetime.strptime(summary["start_time"].strip(), "%Y-%m-%d %H:%M:%S")
            t2 = datetime.strptime(summary["end_time"].strip(), "%Y-%m-%d %H:%M:%S")
            delta = t2 - t1
            total_seconds = delta.total_seconds()
            minutes, seconds = divmod(total_seconds, 60)
            summary["duration"] = "%d Minuten, %d Sekunden" % (minutes, seconds)
        except:
            summary["duration"] = "Konnte nicht berechnet werden"

    # --- EIGENE GRÖSSENBERECHNUNG ---
    total_gb = 0.0
    if vm_report_lines:
        for _rep in vm_report_lines:
            m = re.search(r':\s*([0-9\.,]+)\s*([TGM])B?', _rep, re.IGNORECASE)
            if not m: m = re.search(r'\(([0-9\.]+)\s*([GM]B?)\)', _rep, re.IGNORECASE)
            if m:
                try:
                    val = float(m.group(1).replace(',', '.'))
                    unit = m.group(2).upper().replace('B','')

                    if unit.startswith('M'):
                        gb = val / 1024.0
                    elif unit.startswith('T'):
                        gb = val * 1024.0
                    else:  # 'G'
                        gb = val

                    total_gb += gb

                except: pass
        
        if total_gb > 0:
            summary['final_size'] = "{:.1f} GB".format(total_gb)
            # Korrekter Durchschnitts-Speed: (Gesamt GB * 1024) / Gesamtsekunden
            if total_seconds > 0:
                calc_speed = (total_gb * 1024) / total_seconds
                summary["avg_speed"] = "{:.1f} MB/s".format(calc_speed)

    # --- Automatisches Tail-Log bei Warnungen oder Fehlern ---
    status_upper = summary["status"].upper()
    if "ERROR" in status_upper or "WARNING" in status_upper:
        try:
            tail_lines = []
            for line in reversed(all_lines):
                ln = line.strip()
                if ln: tail_lines.append(ln)
                if len(tail_lines) >= 5: break
            tail_lines.reverse()
            target_list = summary["errors"] if "ERROR" in status_upper else summary["warnings"]
            for tl in tail_lines:
                target_list.append(("Letzte Logzeilen", tl))
        except: pass

    # --- HTML Zusammenstellung (Bereinigt) ---
    if "ERROR" in status_upper:
        status_color = "#dc3545"
    elif "WARNING" in status_upper:
        status_color = "#b06a00"
    elif "OK" in status_upper or "ERFOLGREICH" in status_upper:
        status_color = "#28a745"
    else:
        status_color = "#333"

    parts = ["<html><head><meta charset='utf-8'><style>body{font-family:Arial,sans-serif;font-size:13px}h3,h4{color:#333}pre{background:#f4f4f4;padding:10px;border:1px solid #ddd;white-space:pre-wrap}.err{color:#dc3545;font-weight:bold}.wrn{color:#b06a00;font-weight:bold}</style></head><body>"]   
    parts.append('<h2 style="color: %s;">Backup-Zusammenfassung v9.5</h2><hr>' % status_color)
    parts.append('<p><b>Status:</b> <span style="color: %s; font-weight: bold;">%s</span></p>' % (status_color, html_escape(summary["status"])))
    parts.append("<h4>Job-Details:</h4><ul>")
    parts.append("<li><b>Startzeit:&nbsp;&nbsp;</b> %s</li>" % html_escape(summary["start_time"]))
    parts.append("<li><b>Endzeit:&nbsp;&nbsp;&nbsp;</b> %s</li>" % (html_escape(summary["end_time"]) if summary["end_time"] != "N/A" else "<em>Job nicht beendet</em>"))
    parts.append("<li><b>Dauer:&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</b> %s</li>" % html_escape(summary["duration"]))
    if summary["final_size"] != "N/A": parts.append("<li><b>Groesse:&nbsp;&nbsp;&nbsp;</b> %s</li>" % html_escape(summary["final_size"]))
    if summary.get("avg_speed") and summary["avg_speed"] != "N/A": 
        parts.append("<li><b>Durchschnitts-Speed:&nbsp;</b> %s</li>" % html_escape(summary["avg_speed"]))
    parts.append("</ul><hr>")

    parts.append('<h3>Verarbeitete VMs (%d)</h3>' % len(vm_report_lines))
    if vm_report_lines:
        parts.append("<pre>")
        # Ausrichtung: VM-Name und Größe mit "Tab"-Optik (monospace + Padding)
        cleaned = [l.strip().replace('\\n', '') for l in vm_report_lines]
        name_width = 0
        for _l in cleaned:
            if ':' in _l:
                name = _l.split(':', 1)[0] + ':'
                if len(name) > name_width:
                    name_width = len(name)
        name_width = max(name_width + 2, 18)  # Mindestbreite, damit es auch bei kurzen Namen gut aussieht

        formatted = []
        for _l in cleaned:
            if ':' in _l:
                left, right = _l.split(':', 1)
                left = (left + ':').ljust(name_width)
                formatted.append(left + right.strip())
            else:
                formatted.append(_l)

        parts.append("\n".join(html_escape(x) for x in formatted))
        parts.append("</pre>")
    else:
        parts.append("<p>Keine.</p>")

        # Warnungen
    parts.append('<h3>Warnungen (%d)</h3>' % len(summary["warnings"]))
    if summary["warnings"]:
        parts.append('<ul>' + "".join(
            '<li><strong class="wrn">VM: %s</strong>: %s</li>' % (html_escape(v), html_escape(m))
            for v, m in summary["warnings"]
        ) + '</ul>')
    else:
        parts.append('<p>Keine.</p>')

    # Fehler
    parts.append('<h3>Fehler (%d)</h3>' % len(summary["errors"]))
    if summary["errors"]:
        parts.append('<ul>' + "".join(
            '<li><strong class="err">VM: %s</strong>: %s</li>' % (html_escape(v), html_escape(m))
            for v, m in summary["errors"]
        ) + '</ul>')
    else:
        parts.append('<p>Keine.</p>')

    if summary["config"]:
        parts.append("<hr><h4>Konfiguration:</h4><ul>")
        if summary.get("source_host", "N/A") != "N/A":
            parts.append("<li><b>Quell-Host:</b> %s</li>" % html_escape(summary["source_host"]))
        if summary.get("target_host", "N/A") != "N/A":
            parts.append("<li><b>Ziel-Host:</b> %s</li>" % html_escape(summary["target_host"]))
        if summary.get("target_datastore", "N/A") != "N/A":
            parts.append("<li><b>Ziel-Datastore:</b> %s</li>" % html_escape(summary["target_datastore"]))
        parts.append("".join("<li>%s</li>" % html_escape(i) for i in summary["config"]))
        parts.append("</ul>")
    
    if summary["storage_after"]:
        parts.append('<h4>Speicherplatz (Nachher):</h4><pre>%s</pre>' % "\n".join(html_escape(x) for x in summary["storage_after"]))
    
    if summary["directory_listing"]:
        parts.append('<hr><h3>Dateien:</h3><pre>%s</pre>' % "\n".join(html_escape(x) for x in summary["directory_listing"]))
    
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


def _smtp_plain_socket_send(subject, html_body, to_csv, from_addr, display_name, host, port, user, pwd, is_important=False, timeout=30):
    """
    Plain SMTP over TCP using Python sockets (reliable on ESXi 6 for Port 25).
    Reads server replies per step, so we only report success if DATA is accepted (250 after <CRLF>.<CRLF>).
    """
    import socket as _sock

    def _recvline(sock):
        buf = b""
        while True:
            ch = sock.recv(1)
            if not ch:
                break
            buf += ch
            if buf.endswith(b"\n"):
                break
        return buf

    def _recv_reply(sock):
        lines = []
        while True:
            line = _recvline(sock)
            if not line:
                break
            lines.append(line)
            if len(line) >= 4 and line[3:4] == b" ":
                break
        return b"".join(lines)

    def _send(sock, s):
        if isinstance(s, str):
            s = s.encode("utf-8")
        sock.sendall(s)

    def _code(reply_bytes):
        try:
            return int(reply_bytes[:3])
        except Exception:
            return -1

    recipients = _split_recipients(to_csv)
    if not recipients:
        raise RuntimeError("No recipients.")

    raw = build_message(subject, html_body, to_csv, from_addr, display_name, is_important)

    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except Exception:
            raw = str(raw)

    # Normalize + dot-stuff + hard wrap long lines (<1000 chars SMTP)
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    stuffed_lines = []
    for ln in raw.split("\n"):
        while len(ln) > 900:
            stuffed_lines.append(ln[:900])
            ln = ln[900:]
        if ln.startswith("."):
            ln = "." + ln
        stuffed_lines.append(ln)
    data_block = "\r\n".join(stuffed_lines) + "\r\n"

    s = _sock.socket(_sock.AF_INET, _sock.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((host, int(port)))

    rep = _recv_reply(s)
    if _code(rep) != 220:
        raise RuntimeError("SMTP greeting failed: %r" % rep)

    ehlo = (socket.gethostname().split(".")[0] or "esxi")
    _send(s, "EHLO %s\r\n" % ehlo)
    rep = _recv_reply(s)
    if _code(rep) != 250:
        _send(s, "HELO %s\r\n" % ehlo)
        rep = _recv_reply(s)
        if _code(rep) != 250:
            raise RuntimeError("EHLO/HELO failed: %r" % rep)

    if user and pwd:
        try:
            import base64 as _b64
            _send(s, "AUTH LOGIN\r\n")
            rep = _recv_reply(s)
            if _code(rep) == 334:
                _send(s, _b64.b64encode(user.encode("utf-8")).decode("ascii") + "\r\n")
                rep = _recv_reply(s)
                if _code(rep) != 334:
                    raise RuntimeError("AUTH LOGIN user rejected: %r" % rep)
                _send(s, _b64.b64encode(pwd.encode("utf-8")).decode("ascii") + "\r\n")
                rep = _recv_reply(s)
                if _code(rep) not in (235, 503):
                    raise RuntimeError("AUTH LOGIN failed: %r" % rep)
        except Exception:
            pass

    _send(s, "MAIL FROM:<%s>\r\n" % from_addr)
    rep = _recv_reply(s)
    if _code(rep) not in (250, 251):
        raise RuntimeError("MAIL FROM rejected: %r" % rep)

    for r in recipients:
        _send(s, "RCPT TO:<%s>\r\n" % r)
        rep = _recv_reply(s)
        if _code(rep) not in (250, 251):
            raise RuntimeError("RCPT TO rejected for %s: %r" % (r, rep))

    _send(s, "DATA\r\n")
    rep = _recv_reply(s)
    if _code(rep) != 354:
        raise RuntimeError("DATA not accepted: %r" % rep)

    _send(s, data_block)
    _send(s, ".\r\n")
    rep = _recv_reply(s)
    if _code(rep) != 250:
        raise RuntimeError("Message not accepted: %r" % rep)

    try:
        _send(s, "QUIT\r\n")
        _recv_reply(s)
    except Exception:
        pass
    try:
        s.close()
    except Exception:
        pass

    sys.stdout.write("INFO: Email successfully sent (socket25)\n")
    return True


def _smtp_starttls_socket_send(subject, html_body, to_csv, from_addr, display_name, host, port, user, pwd, is_important=False, timeout=30):
    """
    SMTP over TCP with STARTTLS + optional AUTH LOGIN using Python sockets.
    This replaces OpenSSL s_client fallback for Port 587 to avoid SMTP state desync / 503 errors
    when sending long ERROR/WARNING messages.
    - Enforces SMTP line length < 1000 chars (wrap at 900)
    - Dot-stuffing for DATA lines starting with '.'
    - Proper SMTP state machine with reply checking
    - STARTTLS upgrade + second EHLO after TLS (RFC)
    """
    import socket as _sock
    import ssl as _ssl
    import base64 as _b64

    def _recvline(sock):
        buf = b""
        while True:
            ch = sock.recv(1)
            if not ch:
                break
            buf += ch
            if buf.endswith(b"\n"):
                break
        return buf

    def _recv_reply(sock):
        lines = []
        while True:
            line = _recvline(sock)
            if not line:
                break
            lines.append(line)
            # multi-line replies have '-' after code, final has space
            if len(line) >= 4 and line[3:4] == b" ":
                break
        return b"".join(lines)

    def _send(sock, s):
        if isinstance(s, str):
            s = s.encode("utf-8")
        sock.sendall(s)

    def _code(reply_bytes):
        try:
            return int(reply_bytes[:3])
        except Exception:
            return -1

    recipients = _split_recipients(to_csv)
    if not recipients:
        raise RuntimeError("No recipients.")

    raw = build_message(subject, html_body, to_csv, from_addr, display_name, is_important)
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except Exception:
            raw = str(raw)

    # Normalize + dot-stuff + hard wrap long lines (<1000 chars SMTP)
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    stuffed_lines = []
    for ln in raw.split("\n"):
        while len(ln) > 900:
            part = ln[:900]
            if part.startswith("."):
                part = "." + part
            stuffed_lines.append(part)
            ln = ln[900:]
        if ln.startswith("."):
            ln = "." + ln
        stuffed_lines.append(ln)
    data_block = "\r\n".join(stuffed_lines) + "\r\n"

    s = _sock.socket(_sock.AF_INET, _sock.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((host, int(port)))

    rep = _recv_reply(s)
    if _code(rep) != 220:
        raise RuntimeError("SMTP greeting failed: %r" % rep)

    ehlo = (socket.gethostname().split(".")[0] or "esxi")
    _send(s, "EHLO %s\r\n" % ehlo)
    rep = _recv_reply(s)
    if _code(rep) != 250:
        _send(s, "HELO %s\r\n" % ehlo)
        rep = _recv_reply(s)
        if _code(rep) != 250:
            raise RuntimeError("EHLO/HELO failed: %r" % rep)

    # STARTTLS (optional)
    # Some SMTP relays on port 587 do AUTH without advertising STARTTLS.
    # If STARTTLS is not advertised, continue in plain mode (minimal fallback).
    caps = rep
    try:
        if not isinstance(caps, (bytes, bytearray)):
            caps = str(caps).encode("utf-8")
    except Exception:
        caps = b""
    caps_upper = caps.upper() if isinstance(caps, (bytes, bytearray)) else b""

    if b"STARTTLS" in caps_upper:
        _send(s, "STARTTLS\r\n")
        rep = _recv_reply(s)
        if _code(rep) != 220:
            raise RuntimeError("STARTTLS rejected: %r" % rep)

        # Wrap socket with TLS, disable verification (ESXi often lacks CA chain)
        try:
            ctx = _ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = _ssl.CERT_NONE
            s = ctx.wrap_socket(s, server_hostname=host)
        except Exception:
            s = _ssl.wrap_socket(s, cert_reqs=_ssl.CERT_NONE)

        # EHLO again after TLS per RFC
        _send(s, "EHLO %s\r\n" % ehlo)
        rep = _recv_reply(s)
        if _code(rep) != 250:
            _send(s, "HELO %s\r\n" % ehlo)
            rep = _recv_reply(s)
            if _code(rep) != 250:
                raise RuntimeError("EHLO/HELO after STARTTLS failed: %r" % rep)
    else:
        try:
            sys.stderr.write("WARN: STARTTLS not advertised on %s:%s - continuing without TLS\n" % (str(host), str(port)))
        except Exception:
            pass

    # AUTH (optional)
    if user and pwd:
        _send(s, "AUTH LOGIN\r\n")
        rep = _recv_reply(s)
        if _code(rep) != 334:
            raise RuntimeError("AUTH LOGIN not accepted: %r" % rep)
        _send(s, _b64.b64encode(user.encode("utf-8")).decode("ascii") + "\r\n")
        rep = _recv_reply(s)
        if _code(rep) != 334:
            raise RuntimeError("AUTH LOGIN user rejected: %r" % rep)
        _send(s, _b64.b64encode(pwd.encode("utf-8")).decode("ascii") + "\r\n")
        rep = _recv_reply(s)
        if _code(rep) not in (235, 503):
            raise RuntimeError("AUTH LOGIN failed: %r" % rep)

    _send(s, "MAIL FROM:<%s>\r\n" % from_addr)
    rep = _recv_reply(s)
    if _code(rep) not in (250, 251):
        raise RuntimeError("MAIL FROM rejected: %r" % rep)

    for r in recipients:
        _send(s, "RCPT TO:<%s>\r\n" % r)
        rep = _recv_reply(s)
        if _code(rep) not in (250, 251):
            raise RuntimeError("RCPT TO rejected for %s: %r" % (r, rep))

    _send(s, "DATA\r\n")
    rep = _recv_reply(s)
    if _code(rep) != 354:
        raise RuntimeError("DATA not accepted: %r" % rep)

    _send(s, data_block)
    _send(s, ".\r\n")
    rep = _recv_reply(s)
    if _code(rep) != 250:
        raise RuntimeError("Message not accepted: %r" % rep)

    try:
        _send(s, "QUIT\r\n")
        _recv_reply(s)
    except Exception:
        pass
    try:
        s.close()
    except Exception:
        pass

    sys.stdout.write("INFO: Email successfully sent (socket587_starttls)\n")
    return True

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

    # --- ESXi 6 LOGIC (PORT 25 RELIABLE SOCKET FALLBACK) ---
    use_nc = False
    if port == 25 and tls_mode != 'ssl':
        use_nc = True

    if use_nc:
        sys.stdout.write("INFO: Port 25 on ESXi 6 -> using reliable socket fallback...\n")
        _smtp_plain_socket_send(subject, html_body, to_csv, from_addr, display_name, host, port, user, pwd, is_important=is_important)
        return True

    # For TLS/587 or implicit SSL, keep OpenSSL s_client path
    if tls_mode == 'ssl':
        cmd = ['/bin/openssl', 's_client', '-quiet', '-crlf', '-connect', '%s:%s' % (host, port)]
    else:
        cmd = ['/bin/openssl', 's_client', '-quiet', '-crlf', '-starttls', 'smtp', '-connect', '%s:%s' % (host, port)]

    out, err = run_interactive(cmd)
    out_str = str(out)

    # Only declare success if we see a post-DATA accept (queued/2.0.0) or a clear OK.
    if ("queued" in out_str.lower()) or ("250 2.0.0" in out_str) or ("message accepted" in out_str.lower()):
        sys.stdout.write("INFO: Email successfully sent (fallback)\n")
        return True

    # Retry with plain socket if OpenSSL failed and port is 25
    if ("connect:errno" in str(err)) or ("handshake failure" in str(err)) or ("Broken pipe" in str(err)):
        sys.stderr.write("WARN: OpenSSL failed. Retrying with socket fallback...\n")
        try:
            _smtp_plain_socket_send(subject, html_body, to_csv, from_addr, display_name, host, 25, user, pwd, is_important=is_important)
            return True
        except Exception:
            pass

    sys.stderr.write("DEBUG OUT: %s\n" % str(out))
    sys.stderr.write("DEBUG ERR: %s\n" % str(err))
    raise RuntimeError("SMTP conversation failed")
    return True


def send_email(subject, body, to_addr, from_addr, display_name, smtp_server, smtp_port_str, user, password, tls_mode, auth_mode, openssl_fallback=True, is_important=False):
    try: smtp_port = int(smtp_port_str)
    except: sys.stderr.write("ERROR: Invalid port\n"); return
    
    if _smtp_try_send(subject, body, to_addr, from_addr, display_name, smtp_server, smtp_port, user, password, tls_mode, auth_mode, is_important): return
    # Port 587 STARTTLS: use socket-based sender (reliable for long ERROR/WARN bodies)
    if smtp_port == 587:
        try:
            _smtp_starttls_socket_send(subject, body, to_addr, from_addr, display_name, smtp_server, smtp_port, user, password, is_important=is_important)
            return
        except Exception as e:
            sys.stderr.write("WARN: socket587_starttls failed: %s\n" % str(e))
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
