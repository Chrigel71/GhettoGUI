#!/usr/bin/env python
# GhettoVCB-GUI Custom Sendmail Engine v3.3 "The Final One"

import sys
import argparse
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.header import Header
from email.utils import formatdate

def html_escape(text):
    """A simple function to escape basic HTML special characters."""
    if not isinstance(text, basestring):
        text = str(text)
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def create_summary(log_content):
    summary = {
        "status": "Unbekannt",
        "duration": "N/A",
        "vms_processed": [],
        "errors": [],
        "warnings": [],
        "directory_listing": []
    }

    in_listing_section = False
    for line in log_content.splitlines():
        clean_line = line.strip()

        if "###### Final status:" in clean_line:
            summary["status"] = clean_line.split(":", 1)[1].replace("#", "").strip()
        elif "Backup Duration:" in clean_line:
            summary["duration"] = clean_line.split(":", 1)[1].strip()
        elif "info: Initiate backup for" in clean_line:
            vm_name = clean_line.split("Initiate backup for", 1)[1].strip()
            if vm_name not in summary["vms_processed"]:
                summary["vms_processed"].append(vm_name)
        elif "ERROR:" in clean_line and "ghettoVCB.sh" not in clean_line:
             summary["errors"].append(clean_line.split("ERROR:", 1)[1].strip())
        elif "WARN:" in clean_line or "WARNING:" in clean_line:
             summary["warnings"].append(clean_line.split(":", 1)[1].strip())
        elif "--- Inhalt von" in clean_line and "---" in clean_line:
            in_listing_section = True
            continue
        elif "--- Ende der Liste ---" in clean_line:
            in_listing_section = False
            continue

        if in_listing_section:
            if clean_line:
                summary["directory_listing"].append(line)

    body_parts = []
    body_parts.append("<html><head><style>body { font-family: Arial, sans-serif; font-size: 14px; } pre { font-family: monospace; background-color: #f0f0f0; padding: 10px; border: 1px solid #ccc; border-radius: 5px; white-space: pre-wrap; word-wrap: break-word;} .error { color: red; font-weight: bold; } .warn { color: orange; font-weight: bold; }</style></head><body>")
    body_parts.append("<h2>Backup-Zusammenfassung</h2>")
    body_parts.append("<hr>")
    body_parts.append("<p><b>Status:</b> %s</p>" % summary["status"])
    body_parts.append("<p><b>Dauer:</b> %s</p>" % summary["duration"])
    
    body_parts.append("<h3>Verarbeitete VMs (%d)</h3>" % len(summary["vms_processed"]))
    if summary["vms_processed"]:
        body_parts.append("<ul>")
        body_parts.extend(["<li>%s</li>" % vm for vm in summary["vms_processed"]])
        body_parts.append("</ul>")
    else:
        body_parts.append("<p>Keine.</p>")

    body_parts.append("<h3>Warnungen (%d)</h3>" % len(summary["warnings"]))
    if summary["warnings"]:
        body_parts.append("<ul>")
        body_parts.extend(["<li class='warn'>%s</li>" % html_escape(w) for w in summary["warnings"]])
        body_parts.append("</ul>")
    else:
        body_parts.append("<p>Keine.</p>")

    body_parts.append("<h3>Fehler (%d)</h3>" % len(summary["errors"]))
    if summary["errors"]:
        body_parts.append("<ul>")
        body_parts.extend(["<li class='error'>%s</li>" % html_escape(e) for e in summary["errors"]])
        body_parts.append("</ul>")
    else:
        body_parts.append("<p>Keine.</p>")

    if summary["directory_listing"]:
        body_parts.append("<hr>")
        body_parts.append("<h3>Inhalt des Backup-Verzeichnisses</h3>")
        body_parts.append("<pre>")
        body_parts.extend([html_escape(line) for line in summary["directory_listing"]])
        body_parts.append("</pre>")
    
    body_parts.append("</body></html>")
    return "\n".join(body_parts)

def send_email(subject, body, to_addr, from_addr, smtp_server, smtp_port_str, user, password):
    msg = MIMEMultipart()
    msg['From'] = from_addr
    msg['To'] = to_addr
    msg['Subject'] = Header(subject, 'utf-8')
    msg['Date'] = formatdate(localtime=True)
    
    try:
        smtp_port = int(smtp_port_str)
    except (ValueError, TypeError):
        sys.stderr.write("ERROR: Invalid port: %s\n" % smtp_port_str)
        return

    try:
        body_decoded = body.decode('utf-8', 'replace') if isinstance(body, bytes) else body
    except NameError: # For Python 2 compatibility
        body_decoded = body

    msg.attach(MIMEText(body_decoded, 'html', 'utf-8'))

    server = None
    try:
        server = smtplib.SMTP(smtp_server, smtp_port, timeout=30)
        server.ehlo()
        if server.has_extn('STARTTLS'):
            server.starttls()
            server.ehlo()
        if user and password:
            server.login(user, password)
        server.sendmail(from_addr, to_addr.split(','), msg.as_string())
        print("INFO: Email successfully sent to %s" % to_addr)
    except Exception as e:
        sys.stderr.write("ERROR: Failed to send email: %s\n" % str(e))
    finally:
        if server:
            try:
                server.quit()
            except Exception:
                pass

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='GhettoVCB Custom Sendmail Script.')
    parser.add_argument('-f', dest='sender', required=True)
    parser.add_argument('-s', dest='server', required=True)
    parser.add_argument('-S', dest='port', required=True)
    parser.add_argument('-u', dest='username')
    parser.add_argument('-p', dest='password')
    parser.add_argument('-j', dest='subject', required=True)
    parser.add_argument('recipients', nargs='+')
    args = parser.parse_args()
    
    recipients_str = ",".join(args.recipients)
    log_content = sys.stdin.read()
    email_body = create_summary(log_content)
    
    # ### FINAL FIX: Call send_email on a single line to prevent any indentation errors ###
    send_email(args.subject, email_body, recipients_str, args.sender, args.server, args.port, args.username, args.password)
