#!/usr/bin/env python
# -*- coding: utf-8 -*-
# GhettoVCB-GUI Sendmail (ESXi 6.0–8.x kompatibel)
# - smtplib/email.mime optional (ESXi 6.0 hat teils "gestripptes" Python)
# - Automatischer Fallback via `openssl s_client` (oder `nc` bei TLS=none)
# - Empfänger: komma- ODER semikolon-getrennt
# - Farbliche Hervorhebung für Status OK/ERROR

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
    Erzeugt eine kleine HTML-Zusammenfassung aus der ghettoVCB-Logdatei.
    """
    summary = {
        "status": "Unbekannt",
        "duration": "N/A",
        "vms_processed": [],
        "errors": [],
        "warnings": [],
        "directory_listing": []
    }
    in_listing = False

    for line in log_content.splitlines():
        s = line.strip()

        # Finalstatus
        if "###### Final status:" in s:
            tail = s.split("###### Final status:", 1)[1]
            summary["status"] = tail.replace("#", "").strip()
            continue

        # Dauer
        if "Backup Duration:" in s:
            summary["duration"] = s.split("Backup Duration:", 1)[1].strip()
            continue

        # VM Start
        if "info: Initiate backup for" in s:
            vm = s.split("Initiate backup for", 1)[1].strip()
            if vm and vm not in summary["vms_processed"]:
                summary["vms_processed"].append(vm)
            continue

        # Warnungen/Fehler
        if "ERROR:" in s:
            summary["errors"].append(s.split("ERROR:", 1)[1].strip())
            continue
        if "WARN:" in s or "WARNING:" in s:
            parts = s.split(":", 1)
            summary["warnings"].append(parts[1].strip() if len(parts) > 1 else s)
            continue

        # Directory Listing Sektion
        if "--- START Backup Directory Listing ---" in s:
            in_listing = True
            continue
        if "--- END Backup Directory Listing ---" in s:
            in_listing = False
            continue
        if in_listing:
            summary["directory_listing"].append(line)

    # Farbe basierend auf dem Status definieren
    if "OK" in summary["status"]:
        status_color = "#28a745"  # Grün
    else:
        status_color = "#dc3545"  # Rot

    parts = []
    parts.append(
        "<html><head><meta charset='utf-8'>"
        "<style>"
        "body{font-family:Arial,Helvetica,sans-serif;font-size:14px}"
        "pre{font-family:monospace;background:#f8f8f8;padding:10px;border:1px solid #ddd;"
        "border-radius:4px;white-space:pre-wrap;word-wrap:break-word}"
        ".error{color:#b00020;font-weight:bold}"
        ".warn{color:#b06a00;font-weight:bold}"
        "ul{margin-top:4px}"
        "</style></head><body>"
    )
    
    # H2-Tag mit dynamischer Farbe
    parts.append('<h2 style="color: %s;">Backup-Zusammenfassung</h2><hr>' % status_color)
    
    # Status-Zeile mit farbigem Span-Tag versehen
    status_html = '<span style="color: %s; font-weight: bold;">%s</span>' % (status_color, html_escape(summary["status"]))
    duration_html = html_escape(summary["duration"])
    parts.append('<p><b>Status:</b> %s<br><b>Dauer:</b> %s</p>' % (status_html, duration_html))

    parts.append("<h3>Verarbeitete VMs (%d)</h3>" % len(summary["vms_processed"]))
    if summary["vms_processed"]:
        parts.append("<ul>%s</ul>" % "".join("<li>%s</li>" % html_escape(vm) for vm in summary["vms_processed"]))
    else:
        parts.append("<p>Keine.</p>")

    parts.append("<h3>Warnungen (%d)</h3>" % len(summary["warnings"]))
    if summary["warnings"]:
        parts.append("<ul>%s</ul>" % "".join("<li class='warn'>%s</li>" % html_escape(w) for w in summary["warnings"]))
    else:
        parts.append("<p>Keine.</p>")

    parts.append("<h3>Fehler (%d)</h3>" % len(summary["errors"]))
    if summary["errors"]:
        parts.append("<ul>%s</ul>" % "".join("<li class='error'>%s</li>" % html_escape(e) for e in summary["errors"]))
    else:
        parts.append("<p>Keine.</p>")

    if summary["directory_listing"]:
        parts.append("<hr><h3>Inhalt des Backup-Verzeichnisses</h3>")
        parts.append("<pre>%s</pre>" % "\n".join(html_escape(x) for x in summary["directory_listing"]))

    parts.append("</body></html>")
    return "\n".join(parts)


def build_message(subject, html_body, to_csv, from_addr):
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
        'MIME-Version: 1.0',
        'Content-Type: text/html; charset=utf-8',
        'Content-Transfer-Encoding: 8bit',
        '',
        body_decoded,
    ]
    return "\r\n".join(headers)


def _split_recipients(to_str):
    if not to_str:
        return []
    s = to_str.replace(',', ' ').replace(';', ' ')
    return [chunk.strip() for chunk in s.split() if chunk.strip()]


def _smtp_try_send(subject, html_body, to_csv, from_addr, host, port, user, pwd,
                   tls_mode, auth_mode):
    if smtplib is None:
        sys.stderr.write("WARN: smtplib not available on this host; skipping smtplib path\n")
        return False

    raw = build_message(subject, html_body, to_csv, from_addr)
    server = None
    try:
        if tls_mode == 'ssl':
            if hasattr(smtplib, 'SMTP_SSL'):
                server = smtplib.SMTP_SSL(host, port, timeout=30)
                try:
                    server.ehlo()
                except Exception:
                    pass
            else:
                raise RuntimeError("SMTP_SSL not available in this Python.")
        else:
            server = smtplib.SMTP(host, port, timeout=30)
            try:
                server.ehlo()
            except Exception:
                pass
            if tls_mode in ('auto', 'starttls'):
                try:
                    has_tls = server.has_extn('starttls') or server.has_extn('STARTTLS')
                except Exception:
                    has_tls = False
                if has_tls:
                    server.starttls()
                    try:
                        server.ehlo()
                    except Exception:
                        pass
                elif tls_mode == 'starttls':
                    raise RuntimeError("Server does not support STARTTLS.")

        do_auth = bool(user and pwd) and auth_mode != 'none'
        if do_auth:
            server.login(user, pwd)

        server.sendmail(from_addr, _split_recipients(to_csv), raw)
        try:
            server.quit()
        except Exception:
            pass
        sys.stdout.write("INFO: Email successfully sent to %s\n" % to_csv)
        return True
    except Exception as e:
        if server:
            try:
                server.quit()
            except Exception:
                pass
        sys.stderr.write("WARN: smtplib path failed: %s\n" % str(e))
        return False


def _openssl_fallback(subject, html_body, to_csv, from_addr, host, port, user, pwd,
                      tls_mode, auth_mode):
    recipients = _split_recipients(to_csv)
    if not recipients:
        raise RuntimeError("No recipients.")

    raw = build_message(subject, html_body, to_csv, from_addr)

    try:
        import base64 as b64mod
    except Exception:
        b64mod = None

    def b64(s):
        if b64mod is None:
            raise RuntimeError("No base64 available for AUTH.")
        if not isinstance(s, _basestr):
            s = str(s)
        out = b64mod.b64encode(s.encode('utf-8'))
        try:
            return out.decode('ascii')
        except Exception:
            return out

    ehlo = (socket.gethostname().split('.')[0] or 'esxi')
    lines = ["EHLO %s\r\n" % ehlo]
    
    do_auth = bool(user and pwd) and auth_mode != 'none'
    if do_auth:
        lines.append("AUTH LOGIN\r\n")
        lines.append("%s\r\n" % b64(user))
        lines.append("%s\r\n" % b64(pwd))

    lines.append("MAIL FROM:<%s>\r\n" % from_addr)
    for r in recipients:
        lines.append("RCPT TO:<%s>\r\n" % r)
    lines.append("DATA\r\n")
    
    if isinstance(raw, _basestr):
        body_crlf = raw.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\r\n")
    else:
        try:
            raw_s = raw.decode('utf-8', 'replace')
        except Exception:
            raw_s = str(raw)
        body_crlf = raw_s.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\r\n")
    lines.append(body_crlf + "\r\n.\r\n")
    lines.append("QUIT\r\n")

    def run_cmd(cmd, payload_bytes):
        try:
            p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as oe:
            raise RuntimeError("Cannot exec %s: %s" % (" ".join(cmd), str(oe)))
        out, err = p.communicate(payload_bytes)
        rc = p.returncode
        if rc != 0:
            raise RuntimeError("openssl/nc failed (rc=%s): %s" %