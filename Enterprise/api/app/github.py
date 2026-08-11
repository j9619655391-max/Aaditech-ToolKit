"""GitHub remote-build client.

Used by the SaaS setup when the server cannot build the Windows agent locally
(build_mode = "github" on a Linux host). Flow:

  1. validate(repo, token)     -> confirms the repo is reachable and the token
                                  has actions:write + actions:read scopes.
  2. trigger(repo, token)      -> POST workflow_dispatch on .github/workflows/ci.yml.
  3. status(repo, token)       -> latest dispatch run's status/conclusion.
  4. download_msi(repo, token) -> fetches the latest "it-toolkit-agent" artifact,
                                  extracts IT-Toolkit-Agent.msi, writes it into
                                  the agent_artifacts volume (ARTIFACTS_DIR).

The MSI itself is generic (built by CI from the repo's SERVER_ENDPOINT +
API_TOKEN secrets, which the operator points at this server); the portal's
company bundle (agent.json + ca.crt + install.cmd) is layered over it at
install time, so one generic MSI works for every deployment.
"""

import io
import json
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

from . import config

_API = "https://api.github.com"
_WORKFLOW = "ci.yml"
_ARTIFACT = "it-toolkit-agent"
_MSI = "IT-Toolkit-Agent.msi"
_TIMEOUT = 30


class GitHubError(Exception):
    pass


def _request(method: str, path: str, token: str, payload: dict | None = None) -> dict:
    url = f"{_API}{path}"
    data = None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "IT-Toolkit-Enterprise",
    }
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=_TIMEOUT) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = json.loads(e.read()).get("message", "")
        except Exception:
            pass
        raise GitHubError(f"GitHub {method} {path} -> {e.code}: {detail or e.reason}") from e
    except urllib.error.URLError as e:
        raise GitHubError(f"Cannot reach GitHub: {e.reason}") from e


def _normalize_repo(repo: str) -> str:
    """Turn whatever the operator pasted into `owner/repo`.

    Accepts full URLs (https://github.com/OWNER/REPO.git, github.com/OWNER/REPO,
    git@github.com:OWNER/REPO.git) as well as bare `OWNER/REPO`. Returns the
    canonical `owner/repo` used in every API path.
    """
    repo = (repo or "").strip().strip("/")
    if not repo:
        return ""
    if repo.endswith(".git"):
        repo = repo[:-4]
    repo = repo.replace("git@github.com:", "github.com/")
    repo = repo.replace("https://github.com/", "github.com/")
    repo = repo.replace("http://github.com/", "github.com/")
    repo = repo.removeprefix("github.com/")
    repo = repo.strip("/")
    return repo


def validate(repo: str, token: str) -> dict:
    """Returns {ok, repo, permissions} or raises GitHubError."""
    repo = _normalize_repo(repo)
    info = _request("GET", f"/repos/{repo}", token)
    perms = info.get("permissions", {})
    ok = bool(info.get("id"))
    # GitHub's /repos/{repo} permissions object has no `actions` key (only
    # admin/maintain/push/triage/pull). Admin or maintain implies the ability
    # to run workflows and download artifacts, so treat those as write access.
    actions_write = bool(
        perms.get("admin") or perms.get("maintain") or (perms.get("actions") and perms.get("contents"))
    )
    return {
        "ok": ok,
        "repo": info.get("full_name", repo),
        "default_branch": info.get("default_branch", "main"),
        "actions_write": actions_write,
        "private": bool(info.get("private")),
    }


def trigger(repo: str, token: str, branch: str = "main") -> dict:
    """Fire workflow_dispatch on ci.yml. Returns the dispatched run id (may be
    null until GitHub schedules it — status() resolves it)."""
    repo = _normalize_repo(repo)
    _request(
        "POST",
        f"/repos/{repo}/actions/workflows/{_WORKFLOW}/dispatches",
        token,
        payload={"ref": branch},
    )
    return {"dispatched": True, "branch": branch}


def status(repo: str, token: str) -> dict:
    """Latest run for ci.yml on this repo (push or workflow_dispatch)."""
    repo = _normalize_repo(repo)
    info = _request(
        "GET",
        f"/repos/{repo}/actions/workflows/{_WORKFLOW}/runs?per_page=1",
        token,
    )
    runs = info.get("workflow_runs", [])
    if not runs:
        return {"run_id": None, "state": "none", "conclusion": None}
    run = runs[0]
    return {
        "run_id": run.get("id"),
        "run_number": run.get("run_number"),
        "state": run.get("status"),          # queued | in_progress | completed
        "conclusion": run.get("conclusion"),  # success | failure | ... (null while running)
        "html_url": run.get("html_url"),
        "created_at": run.get("created_at"),
    }


def latest_artifact(repo: str, token: str) -> dict | None:
    repo = _normalize_repo(repo)
    info = _request("GET", f"/repos/{repo}/actions/artifacts?per_page=10", token)
    for art in info.get("artifacts", []):
        if art.get("name") == _ARTIFACT and not art.get("expired"):
            return {
                "id": art["id"],
                "size": art.get("size_in_bytes", 0),
                "created_at": art.get("created_at"),
                "workflow_run_id": art.get("workflow_run", {}).get("id") if art.get("workflow_run") else None,
            }
    return None


def download_msi(repo: str, token: str, artifact_id: int, created_at: str | None = None) -> Path:
    """Download the artifact zip and write IT-Toolkit-Agent.msi into the
    artifacts dir. Returns the written path. Raises GitHubError on failure.

    GitHub's artifact API 302s to a signed CDN URL; the Bearer header must NOT
    be forwarded there (the CDN rejects it with 401), so we follow the redirect
    manually and re-issue the GET without auth headers.
    """
    repo = _normalize_repo(repo)
    config.ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
    dest = config.ARTIFACTS_DIR / _MSI
    stamp = config.ARTIFACTS_DIR / ".msi_artifact.json"
    stamp.write_text(json.dumps({"artifact_id": artifact_id, "created_at": created_at}))

    class _RedirectSink(urllib.request.HTTPRedirectHandler):
        location: str | None = None

        def redirect_request(self, req, fp, code, msg, headers, newurl):
            self.location = newurl
            raise urllib.error.HTTPError(
                req.full_url, code, f"Redirect to {newurl}", headers, fp
            )

    sink = _RedirectSink()
    opener = urllib.request.build_opener(sink)
    req = urllib.request.Request(
        f"{_API}/repos/{repo}/actions/artifacts/{artifact_id}/zip",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "IT-Toolkit-Enterprise",
        },
        method="GET",
    )
    try:
        raw = opener.open(req, timeout=120).read()
    except urllib.error.HTTPError as e:
        loc = sink.location
        if not loc:
            raise GitHubError(f"Artifact download {req.full_url} -> {e.code}: {e.reason}") from e
        # Re-issue against the signed CDN URL WITHOUT the Bearer header.
        cdn = urllib.request.Request(
            loc, headers={"User-Agent": "IT-Toolkit-Enterprise"}, method="GET"
        )
        try:
            with urllib.request.urlopen(cdn, timeout=120) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e2:
            raise GitHubError(f"Artifact CDN download {loc} -> {e2.code}: {e2.reason}") from e2

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        names = [n for n in zf.namelist() if n.endswith(_MSI)]
        if not names:
            raise GitHubError(f"Artifact zip has no {_MSI} (contents: {zf.namelist()[:5]})")
        with zf.open(names[0]) as src, open(dest, "wb") as out:
            out.write(src.read())
    return dest
