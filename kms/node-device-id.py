#!/usr/bin/env python3
"""Print THIS node's auth-simple deviceId, derived on the node itself.

deviceId = sha256(PPID). The PPID (Intel Platform Provisioning ID, 16 bytes) is a field of the
PCK certificate Intel issued for this CPU, and that certificate travels inside every TDX quote the
host produces (quote cert-data type 5 = PEM chain, leaf first). So any quote from any running CVM
on this host yields the id, offline, with no coordinator database and no auth-simple log needed:

    python3 node-device-id.py                 # quote from the KMS CVM's guest agent on :11005
    python3 node-device-id.py --port 11007    # any other CVM's guest-agent host port
    python3 node-device-id.py --quote-hex ~/platform-quote.hex   # a saved quote (extract-platform-quote.py)

Output: one line, `0x<64 hex>`, ready for `KMS_DEVICES=$(python3 node-device-id.py) ./apply-auth-simple.sh`.
The KMS derives the same value from the DCAP-verified quote of a booting CVM (dstack-attest
`get_devide_id` = sha256(pck_ext.ppid)); a patched auth-simple prints it in every boot-auth request
line, so the two can be cross-checked with `journalctl -u outlayer-kms-auth.service | grep deviceId`.

The certificate is NOT verified here — this only reads a public identifier out of it. The security
of the allowlist rests on the KMS verifying the chain to Intel's root, not on this helper.
"""
import argparse
import hashlib
import json
import re
import sys
import urllib.request

QUOTE_EXT_OID = "1.3.6.1.4.1.62397.1.8"        # dstack app_cert extension carrying the raw quote
# DER of OID 1.2.840.113741.1.13.1.1 (SGX-PPID) inside the PCK cert's SGX-extensions sequence,
# followed by OCTET STRING of 16 bytes.
PPID_OID_DER = bytes.fromhex("060a2a864886f84d010d0101")
PEM_RE = re.compile(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", re.S)


def die(msg):
    print("node-device-id: " + msg, file=sys.stderr)
    sys.exit(1)


def quote_from_agent(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/prpc/Info?json", timeout=10) as r:
            info = json.load(r)
    except Exception as e:
        die(f"guest agent on 127.0.0.1:{port} unreachable ({e}); pass --port of a running CVM or --quote-hex")
    try:
        from cryptography import x509  # installed by 00-host-setup.sh
    except ImportError:
        die("python 'cryptography' module missing (00-host-setup.sh installs it); use --quote-hex instead")
    cert = x509.load_pem_x509_certificate(info["app_cert"].encode())
    ext = cert.extensions.get_extension_for_oid(x509.ObjectIdentifier(QUOTE_EXT_OID))
    return ext.value.value


def ppid_from_quote(quote: bytes) -> bytes:
    """PPID from the PCK leaf certificate embedded in a quote (first PEM block of the cert chain)."""
    pems = PEM_RE.findall(quote)
    if not pems:
        die("no PEM certificate chain inside the quote (cert-data type != 5?) — is this a TDX DCAP quote?")
    try:
        from cryptography import x509
        leaf = x509.load_pem_x509_certificate(pems[0])
        sgx_ext = None
        for e in leaf.extensions:
            if e.oid.dotted_string == "1.2.840.113741.1.13.1":
                sgx_ext = e.value.value
        if sgx_ext is None:
            die("PCK leaf certificate has no SGX extension (1.2.840.113741.1.13.1)")
        der = sgx_ext
    except ImportError:
        # No cryptography module: search the raw DER of the PEM body instead.
        import base64
        body = b"".join(pems[0].splitlines()[1:-1])
        der = base64.b64decode(body)
    i = der.find(PPID_OID_DER)
    if i < 0:
        die("SGX-PPID OID not found in the PCK certificate")
    j = i + len(PPID_OID_DER)
    if der[j:j + 2] != b"\x04\x10":
        die("PPID is not a 16-byte OCTET STRING (unexpected certificate layout)")
    return der[j + 2:j + 18]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="11005", help="guest-agent host port of a running CVM (default: KMS CVM, 11005)")
    ap.add_argument("--quote-hex", help="path to a hex-encoded quote instead of asking a guest agent")
    ap.add_argument("--show-ppid", action="store_true", help="also print the PPID (matches the coordinator's tee_nodes.ppid)")
    a = ap.parse_args()
    if a.quote_hex:
        with open(a.quote_hex) as f:
            quote = bytes.fromhex(f.read().strip())
    else:
        quote = quote_from_agent(a.port)
    ppid = ppid_from_quote(quote)
    if a.show_ppid:
        print("ppid=" + ppid.hex(), file=sys.stderr)
    print("0x" + hashlib.sha256(ppid).hexdigest())


if __name__ == "__main__":
    main()
