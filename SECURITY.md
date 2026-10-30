# Security policy

- Report vulnerabilities privately through GitHub: **Security → Report a vulnerability**. Please do not open a public issue.
- Before posting an issue, log, or link, redact UUIDs, passwords, REALITY public keys and short IDs, and server IPs.
- The script creates `/etc/sing-box` with mode 700 and stores configuration and node files with mode 600. It uploads no data anywhere; its only network access is downloading sing-box and acme.sh and looking up the server's public IP.
