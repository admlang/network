#!/usr/bin/env python3
"""Checks Signature Version 4A against AWS's own signer.

  ADM_TEST_S3_V4A_OUT=out.txt adm test network/s3 --file sigv4_test
  python3 v4a-check.py out.txt          (needs: pip install awscrt cryptography)

The test writes the SHA-256 of its string to sign, its signature and the
public key it derived. awscrt signs the same request; when that signature
verifies over the test's digest under the test's key, both sides made the
same key and the same string to sign."""
import sys, datetime
from awscrt import auth, http
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives import hashes

digest, ours, x, y = open(sys.argv[1]).read().split()
key = ec.EllipticCurvePublicNumbers(int(x, 16), int(y, 16), ec.SECP256R1()).public_key()

def holds(signature_hex):
    try:
        key.verify(bytes.fromhex(signature_hex), bytes.fromhex(digest), ec.ECDSA(utils.Prehashed(hashes.SHA256())))
        return True
    except Exception:
        return False

empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
request = http.HttpRequest("GET", "/reports/2026.csv", http.HttpHeaders([("Host", "bucket.s3.amazonaws.com")]))
config = auth.AwsSigningConfig(
    algorithm=auth.AwsSigningAlgorithm.V4_ASYMMETRIC,
    signature_type=auth.AwsSignatureType.HTTP_REQUEST_HEADERS,
    credentials_provider=auth.AwsCredentialsProvider.new_static("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
    region="*", service="s3",
    date=datetime.datetime(2026, 1, 2, 3, 4, 5, tzinfo=datetime.timezone.utc),
    use_double_uri_encode=False, should_normalize_uri_path=False,
    signed_body_value=empty, signed_body_header_type=auth.AwsSignedBodyHeaderType.X_AMZ_CONTENT_SHA_256)
signed = auth.aws_sign_request(request, config).result()
authorization = dict(signed.headers)["Authorization"]
theirs = authorization.split("Signature=")[1]
print("awscrt:", authorization[:150])
print("our signature verifies:        ", holds(ours))
print("awscrt's signature verifies:   ", holds(theirs))
sys.exit(0 if holds(ours) and holds(theirs) else 1)
