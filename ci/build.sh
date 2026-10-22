#!/usr/bin/env bash
set -u
echo "recon start $(date -u +%FT%TZ)"
python3 -u ci/recon.py
echo "recon done rc=$? $(date -u +%FT%TZ)"
