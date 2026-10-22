#!/usr/bin/env bash
set -u
echo "recon2 start $(date -u +%FT%TZ)"
python3 -u ci/recon2.py
echo "recon2 done rc=$? $(date -u +%FT%TZ)"
