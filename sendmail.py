#!/usr/bin/python
# GhettoVCB-GUI Custom Sendmail Engine v2.2 "The Summarizer"

import smtplib
import argparse
import sys
import os
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.header import Header
from email.utils import formatdate
from datetime import datetime

def send_email(subject, body, to_addr, from_addr, smtp_server, smtp_port_str, user, password):
    """ Connects to an SMTP server and sends an email """
    msg = MIMEMultipart()
    msg['From'] = from_addr
    msg['To'] = to_addr
    msg['Subject'] = Header(subject, 'utf-8')
    msg['Date'] = formatdate(localtime=True)
    
    try:
        smtp_port = int(smtp_port_str)
    except (ValueError, TypeError):
        sys.stderr.write("ERROR: Invalid port specified: %s\n" % smtp_port_str)
        return

    try:
        body_decoded = body.decode('utf-8', 'replace')
    except AttributeError:
        body_decoded = body

    msg.attach(MIMEText(body_decoded, 'plain', 'utf-8'))

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
        if "###### Final status:" in line:
            summary["status"] = line.split(":", 1)[1].replace("#", "").strip()
        elif "Backup Duration:" in line:
            summary["duration"] = line.split(":", 1)[1].strip()
        elif "Initiate backup for" in line:
            vm_name = line.split("for", 1)[1].strip()
            if vm_name not in summary["vms_processed"]:
                summary["vms_processed"].append(vm_name)
        elif "ERROR:" in line and "ghettoVCB.sh" not in line:
             summary["errors"].append(line.split("ERROR:", 1)[1].strip())
        elif "WARN:" in line or "WARNING:" in line:
             summary["warnings"].append(line.split(":", 1)[1].strip())
        elif "Backup-Verzeichnis Inhalt:" in line:
            in_listing_section = True
            continue
        
        if in_listing_section:
            summary["directory_listing"].append(line)

    body = []
    body.append("Backup-Zusammenfassung")
    body.append("==============================")
    body.append("Status: %s" % summary["status"])
    body.append("Dauer: %s" % summary["duration"])
    body.append("\nVerarbeitete VMs (%d):" % len(summary["vms_processed"]))
    body.extend(["- %s" % vm for vm in summary["vms_processed"]])
    
    body.append("\nWarnungen (%d):" % len(summary["warnings"]))
    if summary["warnings"]:
        body.extend(["- %s" % w for w in summary["warnings"]])
    else:
        body.append("Keine.")

    body.append("\nFehler (%d):" % len(summary["errors"]))
    if summary["errors"]:
        body.extend(["- %s" % e for e in summary["errors"]])
    else:
        body.append("Keine.")

    body.append("\n\nInhalt des Backup-Verzeichnisses:")
    body.append("---------------------------------")
    body.extend(summary["directory_listing"])
    
    return "\n".join(body)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Custom sendmail script for GhettoVCB.')
    parser.add_argument('-f', dest='sender', required=True)
    parser.add_argument('-s', dest='server', required=True)
    parser.add_argument('-S', dest='port', required=True)
    parser.add_argument('-u', dest='username')
    parser.add_argument('-p', dest='password')
    parser.add_argument('-j', dest='subject')
    parser.add_argument('--password-file', dest='password_file')
    parser.add_argument('recipient', nargs='?', default=None, help='The recipient email address.')

    args, unknown = parser.parse_known_args()
    
    recipient = args.recipient
    if not recipient and unknown:
        recipient = unknown[0]
    
    password = args.password
    if args.password_file:
        try:
            with open(args.password_file, 'r') as f:
                password = f.read().strip()
        except Exception:
            pass

    log_content = sys.stdin.read()
    email_body = create_summary(log_content)
    
    # Der Betreff wird jetzt direkt vom ghettoVCB.sh Skript übergeben
    final_subject = args.subject
    
    if not recipient:
        sys.stderr.write("ERROR: No recipient defined.\n")
    else:
        send_email(
            subject=final_subject,
            body=email_body,
            to_addr=recipient,
            from_addr=args.sender,
            smtp_server=args.server,
            smtp_port_str=args.port,
            user=args.username,
            password=password
        )