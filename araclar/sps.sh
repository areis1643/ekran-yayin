#!/bin/bash
# Usage: sps.sh < script.ps1  -> runs PowerShell on Slayer via nilserver
enc=$(iconv -f UTF-8 -t UTF-16LE | base64 -w0)
ssh -o BatchMode=yes nilserver "ssh -i ~/.ssh/slayer_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 alir@100.101.69.89 powershell -NoProfile -EncodedCommand $enc"
