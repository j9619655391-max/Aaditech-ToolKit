import os

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://ittoolkit:change-me@db:5432/ittoolkit")
API_TOKEN = os.environ.get("API_TOKEN", "change-me-random-token")
SERVER_HOST = os.environ.get("SERVER_HOST", "localhost")
PORTAL_DIR = os.environ.get("PORTAL_DIR", "/app/portal")
FEATURES_FILE = os.environ.get("FEATURES_FILE", "/app/features.json")
