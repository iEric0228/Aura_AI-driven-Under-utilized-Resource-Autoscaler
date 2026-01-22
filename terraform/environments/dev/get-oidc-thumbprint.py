#!/usr/bin/env python3
import sys
import json
import ssl
import hashlib
from urllib.parse import urlparse
import socket

def get_thumbprint(oidc_url):
    parsed = urlparse(oidc_url)
    host = parsed.netloc
    port = 443
    cert = ssl.get_server_certificate((host, port))
    x509 = ssl.PEM_cert_to_DER_cert(cert)
    thumbprint = hashlib.sha1(x509).hexdigest()
    return thumbprint


if __name__ == "__main__":
    try:
        input_json = json.load(sys.stdin)
        oidc_url = input_json["url"]
        thumbprint = get_thumbprint(oidc_url)
        print(json.dumps({"thumbprint": thumbprint}))
    except Exception as exc:
        print(json.dumps({"error": f"failed to fetch OIDC thumbprint: {exc}"}), file=sys.stderr)
        sys.exit(1)
