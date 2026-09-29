"""Send one test alert email through Gmail SMTP, using the secret stored in AWS Secrets Manager.

Checks the same path Alertmanager uses (smtp.gmail.com:587 with STARTTLS), independently of the
cluster. Prints only the result of each stage, never the password.

Usage:
    aws secretsmanager get-secret-value --secret-id sre-challenge/shared/alertmanager-smtp \
      --query SecretString --output text | python3 scripts/smtp_test.py

The secret is JSON with the keys: username, password, to.
"""
import json
import smtplib
import sys
from datetime import datetime, timezone
from email.message import EmailMessage

try:
    secret = json.loads(sys.stdin.read())
    user, password, to = secret["username"], secret["password"], secret["to"]
except Exception as e:
    sys.exit(f"Could not read the secret from the vault: {type(e).__name__}")

msg = EmailMessage()
msg["From"] = user
msg["To"] = to
msg["Subject"] = "[TEST] SRE challenge: alert email check"
msg.set_content(
    "This is a test from the command line.\n\n"
    "It used the Gmail app password stored in AWS Secrets Manager, logged in to "
    "smtp.gmail.com on port 587 with STARTTLS, the same way Alertmanager will.\n\n"
    f"Sent at {datetime.now(timezone.utc):%Y-%m-%d %H:%M:%S} UTC."
)

try:
    with smtplib.SMTP("smtp.gmail.com", 587, timeout=20) as s:
        s.ehlo()
        s.starttls()
        s.ehlo()
        print("1. Connected to smtp.gmail.com:587 and switched to encryption (STARTTLS): OK")
        s.login(user, password)
        print("2. Logged in with the app password from the vault: OK")
        s.send_message(msg)
        print("3. Test email handed to Gmail for delivery: OK")
except smtplib.SMTPAuthenticationError as e:
    sys.exit(f"Login rejected by Gmail (code {e.smtp_code}). The app password or username is wrong, or it was deleted.")
except Exception as e:
    sys.exit(f"Failed: {type(e).__name__}: {e}")
