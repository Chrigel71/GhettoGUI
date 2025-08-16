#!/usr/bin/env python
# -*- coding: utf-8 -*-
# GhettoVCB-GUI Custom Sendmail Engine v6.0 (ESXi 6.0 compatible)
#
# - Beibehaltener smtplib Pfad (STARTTLS/SSL/PLAINTEXT)
# - Automatischer Fallback via `openssl s_client` bei TLS-Problemen (ESXi 6.0)
# - Optionale Flags: --tls {auto,starttls,ssl,none}, --auth {auto,login,plain,none},
#                    --no-openssl-fallback

import sys, os, argparse, socket, subprocess, time
try:
    import smtplib
except Exception:
    smtplib = None
try:
    from email.mime.text import MIMEText
    from email.mime.multipart import MIMEMultipart
    from email.header import Header
    from email.utils import formatdate
    HAVE_EMAIL = True
except Exception:
    MIMEText = MIMEMultipart = Header = formatdate = None
    HAVE_EMAIL = False



try:
    import ssl
except Exception:
    ssl = None

try:
    _string_types = basestring  # Py2
except NameError:
    _string_types = str         # Py3

def html_escape(text):
    if not isinstance(text, _string_types):
        text = str(text)
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

def create_summary(log_content):
    summary = {"status":"Unbekannt","duration":"N/A","vms_processed":[],
               "errors":[], "warnings":[], "directory_listing":[]}
    in_listing_section = False
    for line in log_content.splitlines():
        clean_line = line.strip()
        if "###### Final status:" in clean_line:
            summary["status"] = clean_line.split("###### Final status:",1)[1].replace("#","").strip()
        elif "Backup Duration:" in clean_line:
            summary["duration"] = clean_line.split("Backup Duration:",1)[1].strip()
        elif "info: Initiate backup for" in clean_line:
            vm_name = clean_line.split("Initiate backup for",1)[1].strip()
            if vm_name not in summary["vms_processed"]:
                summary["vms_processed"].append(vm_name)
        elif "ERROR:" in clean_line:
            summary["errors"].append(clean_line.split("ERROR:",1)[1].strip())
        elif "WARN:" in clean_line or "WARNING:" in clean_line:
            summary["warnings"].append(clean_line.split(":",1)[1].strip())
        elif "--- START Backup Directory Listing ---" in clean_line:
            in_listing_section = True
            continue
        elif "--- END Backup Directory Listing ---" in clean_line:
            in_listing_section = False
            continue
        if in_listing_section:
            summary["directory_listing"].append(line)

    parts = []
    parts.append("<html><head><style>body{font-family:Arial,sans-serif;font-size:14px}"
                 "pre{font-family:monospace;background-color:#f0f0f0;padding:10px;border:1px solid #ccc;"
                 "border-radius:5px;white-space:pre-wrap;word-wrap:break-word}.error{color:red;font-weight:bold}"
                 ".warn{color:orange;font-weight:bold}</style></head><body>")
    parts.append("<h2>Backup-Zusammenfassung</h2><hr><p><b>Status:</b> %s</p><p><b>Dauer:</b> %s</p>" %
                 (html_escape(summary["status"]), html_escape(summary["duration"])))
    parts.append("<h3>Verarbeitete VMs (%d)</h3>" % len(summary["vms_processed"]))
    if summary["vms_processed"]:
        parts.append("<ul>%s</ul>" % "".join(["<li>%s</li>" % html_escape(vm) for vm in summary["vms_processed"]]))
    else:
        parts.append("<p>Keine.</p>")
    parts.append("<h3>Warnungen (%d)</h3>" % len(summary["warnings"]))
    if summary["warnings"]:
        parts.append("<ul>%s</ul>" % "".join(["<li class='warn'>%s</li>" % html_escape(w) for w in summary["warnings"]]))
    else:
        parts.append("<p>Keine.</p>")
    parts.append("<h3>Fehler (%d)</h3>" % len(summary["errors"]))
    if summary["errors"]:
        parts.append("<ul>%s</ul>" % "".join(["<li class='error'>%s</li>" % html_escape(e) for e in summary["errors"]]))
    else:
        parts.append("<p>Keine.</p>")
    if summary["directory_listing"]:
        parts.append("<hr><h3>Inhalt des Backup-Verzeichnisses</h3><pre>%s</pre>" %
                     "\n".join([html_escape(x) for x in summary["directory_listing"]]))
    parts.append("</body></html>")
    return "\n".join(parts)
    
    def build_message(subject, html_body, to_csv, from_addr):
    # Body in Unicode bringen
    try:
        body_decoded = html_body.decode('utf-8', 'replace') if isinstance(html_body, bytes) else html_body
    except NameError:
        body_decoded = html_body

    # Falls email.mime verfügbar ist (HAVE_EMAIL True), den Komfortweg nutzen
    try:
        HAVE_EMAIL
    except NameError:
        HAVE_EMAIL = True  # falls Patch A noch nicht gesetzt ist, gehen wir vom Standard aus

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
            # Falls email.mime doch nicht verfügbar ist, auf Roh-MIME fallen wir unten zurück
            pass

    # Minimaler Roh-MIME-String (kompatibel für ESXi 6.0 ohne email.mime)
    try:
        import time
    except Exception:
        time = None
    date_hdr = time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime()) if time else ''
    headers = [
        'From: %s' % from_addr,
        'To: %s' % to_csv,
        'Subject: %s' % subject,
        ('Date: %s' % date_hdr) if date_hdr else 'Date:',
        'MIME-Version: 1.0',
        'Content-Type: text/html; charset=utf-8',
        'Content-Transfer-Encoding: 8bit',
        '',
        body_decoded,
    ]
    return "\r\n".join(headers)


def _split_recipients(to_str):
    # akzeptiert "a@b,c@d" ODER "a@b;c@d" ODER gemischt/mit Leerzeichen
    items = []
    for sep in (',',';'):
        to_str = to_str.replace(sep, ' ')
    for chunk in to_str.split():
        c = chunk.strip()
        if c:
            items.append(c)
    return items


def _smtp_try_send(subject, html_body, to_csv, from_addr, host, port, user, pwd,
                   tls_mode, auth_mode):
    """Primärer Pfad via smtplib. Gibt True bei Erfolg, sonst False."""
    if smtplib is None:
        sys.stderr.write("WARN: smtplib not available on this host; skipping smtplib path\n")
        return False

        """Primärer Pfad via smtplib. Gibt True bei Erfolg, sonst False + Exception nach außen."""
    msg = MIMEMultipart()
    msg['From'] = from_addr
    msg['To'] = to_csv
    msg['Subject'] = Header(subject, 'utf-8')
    msg['Date'] = formatdate(localtime=True)
    try:
        body_decoded = html_body.decode('utf-8','replace') if isinstance(html_body, bytes) else html_body
    except NameError:
        body_decoded = html_body
    msg.attach(MIMEText(body_decoded, 'html', 'utf-8'))

    raw = build_message(subject, html_body, to_csv, from_addr)
    server = None
    server = None
    try:
        # TLS-Auswahl
        if tls_mode == 'ssl':
            if hasattr(smtplib, 'SMTP_SSL'):
                server = smtplib.SMTP_SSL(host, port, timeout=30)
                server.ehlo()
            else:
                raise RuntimeError("SMTP_SSL not available in this Python.")
        else:
            server = smtplib.SMTP(host, port, timeout=30)
            server.ehlo()
            if tls_mode in ('auto','starttls'):
                # nur wenn der Server STARTTLS anbietet
                if server.has_extn('STARTTLS'):
                    # In Py2 gibt es kein context-Argument -> nimmt Systemdefaults
                    server.starttls()
                    server.ehlo()
                elif tls_mode == 'starttls':
                    raise RuntimeError("Server does not support STARTTLS.")
            # tls_mode == 'none' => nichts tun

        # Auth-Auswahl
        do_auth = False
        if auth_mode == 'none':
            do_auth = False
        elif auth_mode in ('auto','login','plain'):
            do_auth = (user and pwd)
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
        # Aufräumen & Fehler nach außen (für Fallback)
        if server:
            try:
                server.quit()
            except Exception:
                pass
        sys.stderr.write("WARN: smtplib path failed: %s\n" % str(e))
        return False

def _openssl_fallback(subject, html_body, to_csv, from_addr, host, port, user, pwd,
                      tls_mode, auth_mode):
    """Fallback über `openssl s_client` (starttls/smtps)."""
    # baue SMTP-Skript
    try:
        import base64
    except Exception:
        base64 = None

    recipients = _split_recipients(to_csv)
    if not recipients:
        raise RuntimeError("No recipients.")

    try:
        body_decoded = html_body.decode('utf-8','replace') if isinstance(html_body, bytes) else html_body
    except NameError:
        body_decoded = html_body

    # komplette MIME erzeugen (gleich wie smtplib) und roh senden
    msg = MIMEMultipart()
    msg['From'] = from_addr
    msg['To'] = to_csv
    msg['Subject'] = Header(subject, 'utf-8')
    msg['Date'] = formatdate(localtime=True)
    msg.attach(MIMEText(body_decoded, 'html', 'utf-8'))
    raw = build_message(subject, html_body, to_csv, from_addr)

    def b64(s):
        if base64 is None:
            raise RuntimeError("No base64 module available.")
        # Python2: base64.b64encode(bytes) -> bytes
        return base64.b64encode(s.encode('utf-8'))

    # SMTP Dialog
    ehlo = socket.gethostname().split('.')[0] or 'esxi'
    lines = []
    lines.append("EHLO %s\r\n" % ehlo)

    use_starttls = (tls_mode in ('auto','starttls'))
    use_smtps    = (tls_mode == 'ssl')

    if auth_mode == 'none':
        do_auth = False
    elif auth_mode in ('auto','login','plain'):
        do_auth = bool(user and pwd)
    else:
        do_auth = False

    if do_auth:
        if auth_mode in ('auto','login'):
            # AUTH LOGIN
            lines.append("AUTH LOGIN\r\n")
            lines.append(b64(user) + b"\r\n")
            lines.append(b64(pwd) + b"\r\n")
        elif auth_mode == 'plain':
            # authzid\0authcid\0passwd
            if base64 is None:
                raise RuntimeError("Cannot auth PLAIN without base64.")
            payload = "\0%s\0%s" % (user, pwd)
            import base64 as b64mod
            lines.append("AUTH PLAIN %s\r\n" % b64mod.b64encode(payload.encode('utf-8')).decode('ascii'))

    lines.append("MAIL FROM:<%s>\r\n" % from_addr)
    for r in recipients:
        lines.append("RCPT TO:<%s>\r\n" % r)
    lines.append("DATA\r\n")
    lines.append(raw.replace("\n", "\r\n"))
    lines.append("\r\n.\r\nQUIT\r\n")

    # Kommando bauen
    if tls_mode == 'none':
        # Klartext per nc (ESXi BusyBox hat in der Regel nc)
        cmd = ['nc', host, str(port)]
    else:
        if use_starttls:
            cmd = ['openssl','s_client','-quiet','-crlf','-starttls','smtp','-connect','%s:%s' % (host, port)]
        else:
            # SMTPS
            cmd = ['openssl','s_client','-quiet','-crlf','-connect','%s:%s' % (host, port)]

    try:
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as oe:
        raise RuntimeError("Cannot exec %s: %s" % (" ".join(cmd), str(oe)))

    payload = b""
    for L in lines:
        if isinstance(L, _string_types):
            payload += L.encode('utf-8')
        else:
            payload += L  # already bytes
    out, err = p.communicate(payload)
    rc = p.returncode
    if rc != 0:
        raise RuntimeError("openssl/nc failed (rc=%s): %s" % (rc, err.decode('utf-8','ignore')))
    sys.stdout.write("INFO: Email successfully sent to %s (openssl fallback)\n" % to_csv)
    return True

def send_email(subject, body, to_addr, from_addr, smtp_server, smtp_port_str, user, password,
               tls_mode, auth_mode, openssl_fallback=True):
    try:
        smtp_port = int(smtp_port_str)
    except Exception:
        sys.stderr.write("ERROR: Invalid port: %s\n" % smtp_port_str)
        return

    # 1) Erst normal via smtplib
    ok = _smtp_try_send(subject, body, to_addr, from_addr, smtp_server, smtp_port,
                        user, password, tls_mode, auth_mode)
    if ok:
        return

    # 2) Fallback via openssl s_client (esxi 6.0)
    if openssl_fallback:
        try:
            _openssl_fallback(subject, body, to_addr, from_addr, smtp_server, smtp_port,
                              user, password, tls_mode, auth_mode)
            return
        except Exception as e:
            sys.stderr.write("ERROR: OpenSSL fallback failed: %s\n" % str(e))
    # 3) Wenn beides scheitert -> Fehler
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
    # Empfänger als Positional (wie gehabt)
    parser.add_argument('recipients', nargs='+')
    # NEU/optional:
    parser.add_argument('--tls', choices=['auto','starttls','ssl','none'], default='auto')
    parser.add_argument('--auth', choices=['auto','login','plain','none'], default='auto')
    parser.add_argument('--no-openssl-fallback', action='store_true', help='disable automatic openssl fallback')

    args = parser.parse_args()
    recipients_str = ",".join(args.recipients)

    try:
        with open(args.message_file, 'r') as f:
            log_content = f.read()
    except Exception as e:
        sys.stderr.write("ERROR: Failed to read message file %s: %s\n" % (args.message_file, str(e)))
        sys.exit(1)

    email_body = create_summary(log_content)

    openssl_fb = (not args.no_openssl_fallback)
    send_email(args.subject, email_body, recipients_str, args.sender,
               args.server, args.port, args.username, args.password,
               tls_mode=args.tls, auth_mode=args.auth, openssl_fallback=openssl_fb)
