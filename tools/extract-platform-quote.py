#!/usr/bin/env python3
"""Extract this node's TDX platform quote (hex) from a running CVM's guest agent.

The collateral for a platform is per-FMSPC, not per-quote, so ANY quote produced on this host
works as the input to `dcap-qvl verify` when (re)generating the collateral.

The dstack guest agent does not expose a quote RPC on its host port; it returns `app_cert`, an
X.509 certificate carrying the quote in extension OID 1.3.6.1.4.1.62397.1.8.

Usage:
  python3 extract-platform-quote.py [agent_port] > /home/outlayer/platform-quote.hex
  (agent_port defaults to 11005 = the KMS CVM's guest agent; any running CVM works)
"""
import json
import sys
import urllib.request

from cryptography import x509  # installed by 00-host-setup.sh (pip: cryptography)

QUOTE_EXT_OID = "1.3.6.1.4.1.62397.1.8"
# TDX quote header: version=4 (u16 LE), attestation key type=2 (u16 LE), tee_type=0x00000081
QUOTE_MAGIC = bytes([0x04, 0x00, 0x02, 0x00, 0x81, 0x00, 0x00, 0x00])

port = sys.argv[1] if len(sys.argv) > 1 else "11005"
with urllib.request.urlopen(f"http://127.0.0.1:{port}/prpc/Info?json", timeout=10) as r:
    info = json.load(r)

cert = x509.load_pem_x509_certificate(info["app_cert"].encode())
ext = cert.extensions.get_extension_for_oid(x509.ObjectIdentifier(QUOTE_EXT_OID))
raw = ext.value.value

start = raw.find(QUOTE_MAGIC)
if start < 0:
    sys.exit("no TDX quote header found in the app_cert extension")
quote = raw[start:]
print(f"quote: {len(quote)} bytes from CVM app_id={info['app_id']}", file=sys.stderr)
sys.stdout.write(quote.hex())
