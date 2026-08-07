import ipaddress
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from . import config

_CA_CN = "IT-Toolkit Enterprise CA"


def _paths():
    d = config.DATA_DIR / "certs"
    return {
        "dir": d,
        "ca_crt": d / "ca.crt",
        "ca_key": d / "ca.key",
        "server_crt": d / "server.crt",
        "server_key": d / "server.key",
    }


def certs_exist() -> bool:
    p = _paths()
    return p["ca_crt"].exists() and p["server_crt"].exists()


def _write_private_key(path, key) -> None:
    path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )


def _write_cert(path, cert) -> None:
    path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))


def ensure_certs(host: str) -> dict:
    """Generate (once) a local self-signed CA and a server cert signed by it
    for `host` (IP or DNS). Persisted under DATA_DIR/certs so they survive
    restarts. The CA is what agents will trust (distributed with the agent
    package in P3)."""
    p = _paths()
    if certs_exist():
        return {k: str(v) for k, v in p.items()}

    p["dir"].mkdir(parents=True, exist_ok=True)

    now = datetime.now(timezone.utc)

    # --- CA ---
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, _CA_CN)])
    ca_cert = (
        x509.CertificateBuilder()
        .subject_name(ca_name)
        .issuer_name(ca_name)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=3650))
        .add_extension(
            x509.BasicConstraints(ca=True, path_length=0), critical=True
        )
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .sign(ca_key, hashes.SHA256())
    )

    # --- server cert signed by the CA, SAN = host ---
    san_entries = []
    try:
        san_entries.append(x509.IPAddress(ipaddress.ip_address(host)))
    except ValueError:
        san_entries.append(x509.DNSName(host))
    # also trust via loopback for local testing
    san_entries.append(x509.DNSName("localhost"))
    san_entries.append(x509.IPAddress(ipaddress.ip_address("127.0.0.1")))

    server_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    server_cert = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, host)]))
        .issuer_name(ca_name)
        .public_key(server_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=825))
        .add_extension(x509.SubjectAlternativeName(san_entries), critical=False)
        .sign(ca_key, hashes.SHA256())
    )

    _write_private_key(p["ca_key"], ca_key)
    _write_cert(p["ca_crt"], ca_cert)
    _write_private_key(p["server_key"], server_key)
    _write_cert(p["server_crt"], server_cert)

    return {k: str(v) for k, v in p.items()}


def ensure_ca() -> dict:
    """Ensure the CA exists (without the server host) and return cert paths.

    Used by the client-cert enrollment endpoint so agents can be issued certs
    even when the TLS server cert was generated for a different host.
    """
    p = _paths()
    if p["ca_crt"].exists():
        return {k: str(v) for k, v in p.items()}
    return ensure_certs("localhost")


def client_cert_paths(hostname: str) -> dict:
    d = config.DATA_DIR / "certs" / "clients"
    safe = hostname.replace("/", "_").replace("\\", "_")
    return {
        "dir": d,
        "crt": d / f"{safe}.crt",
        "key": d / f"{safe}.key",
    }


def issue_client_cert(hostname: str) -> dict:
    """Issue (once) a client-auth cert for an agent, signed by the local CA.

    Returns {crt, key, ca, pfx} — crt/key/ca are PEM, pfx is base64 PKCS#12
    (cert + key + CA, no password) so the Windows agent can load it into an
    X509Certificate2 for Invoke-RestMethod -Certificate. Persisted under
    DATA_DIR/certs/clients/ so it survives restarts and is served back to the
    same agent on re-enroll.
    """
    paths = client_cert_paths(hostname)
    if paths["crt"].exists():
        key = paths["key"].read_text(encoding="utf-8")
        crt = paths["crt"].read_text(encoding="utf-8")
        ca = _paths()["ca_crt"].read_text(encoding="utf-8")
        return {
            "crt": crt, "key": key, "ca": ca,
            "pfx": _to_pfx(crt, key, ca),
        }

    ca = ensure_ca()
    ca_cert = x509.load_pem_x509_certificate(Path(ca["ca_crt"]).read_bytes())
    ca_key = serialization.load_pem_private_key(
        Path(ca["ca_key"]).read_bytes(), password=None
    )

    now = datetime.now(timezone.utc)
    client_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    client_cert = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, hostname)]))
        .issuer_name(ca_cert.subject)
        .public_key(client_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=825))
        .add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), critical=True
        )
        .sign(ca_key, hashes.SHA256())
    )

    crt_pem = client_cert.public_bytes(serialization.Encoding.PEM).decode()
    key_pem = client_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    ca_pem = Path(ca["ca_crt"]).read_text(encoding="utf-8")

    paths["dir"].mkdir(parents=True, exist_ok=True)
    paths["crt"].write_text(crt_pem, encoding="utf-8")
    paths["key"].write_text(key_pem, encoding="utf-8")

    return {"crt": crt_pem, "key": key_pem, "ca": ca_pem, "pfx": _to_pfx(crt_pem, key_pem, ca_pem)}


def _to_pfx(crt_pem: str, key_pem: str, ca_pem: str) -> str:
    """Bundle cert + key + CA into a password-less PKCS#12, base64-encoded."""
    import base64

    from cryptography.hazmat.primitives.serialization import pkcs12

    cert = x509.load_pem_x509_certificate(crt_pem.encode())
    key = serialization.load_pem_private_key(key_pem.encode(), password=None)
    ca_certs = [x509.load_pem_x509_certificate(ca_pem.encode())]
    data = pkcs12.serialize_key_and_certificates(
        name=b"itk-agent", key=key, cert=cert, cas=ca_certs,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return base64.b64encode(data).decode()
