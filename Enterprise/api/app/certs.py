import ipaddress
from datetime import datetime, timedelta, timezone

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

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
