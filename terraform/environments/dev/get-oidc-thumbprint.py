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
    # Connect and get the cert
    cert = ssl.get_server_certificate((host, port))
    x509 = ssl.PEM_cert_to_DER_cert(cert)
    thumbprint = hashlib.sha1(x509).hexdigest()
    return thumbprint

if __name__ == "__main__":
    input_json = json.load(sys.stdin)
    oidc_url = input_json["url"]  # Use the full URL
    thumbprint = get_thumbprint(oidc_url)
    print(json.dumps({"thumbprint": thumbprint}))
