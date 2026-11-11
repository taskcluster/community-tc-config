#!/usr/bin/env python3
"""imageset.sh's diagnostic file (see diagnostics-README.md).

  diagnostics.py package DIR ZIP   Writes ZIP: the files that a run recorded in
                                   DIR, with secrets removed, the README, and
                                   the tools' versions.
  diagnostics.py replay DIR|ZIP    Says what vpn.py would do now on each page
                                   of the sign-in that a run captured.
"""

import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))

# Patterns of secrets, removed from every text file
SECRETS = [
    (re.compile(r"-----BEGIN [A-Z0-9 ]+-----.*?-----END [A-Z0-9 ]+-----", re.S), "<redacted PEM block>"),
    (re.compile(r"<(key|tls-auth|tls-crypt|tls-crypt-v2|secret|pkcs12)>.*?</\1>", re.S), r"<\1><redacted></\1>"),
    (re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"), "<redacted token>"),
    (re.compile(r"\bA(KIA|SIA)[0-9A-Z]{16}\b"), "<redacted AWS key ID>"),
    (re.compile(r"\beyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{10,}"), "<redacted JWT>"),
    (re.compile(r"(?i)\b(bearer|basic)\s+[\w\-.=+/]{16,}"), r"\1 <redacted>"),
    (re.compile(r"(?i)\b(auth-token(?:-user)?)([ ,=]+)[^\s,']+"), r"\1\2<redacted>"),
    (re.compile(r"(?i)((?:[\w-]*(?:password|passwd|passphrase|secret|token|credential|api[_-]?key|access[_-]?key)[\w-]*)[\"']?\s*[:=]\s*)([\"']?)[^\s\"',;<>&]+"),
     r"\1\2<redacted>"),
]
URL_QUERY = re.compile(r"(https?://[^\s\"'<>?]*\?)([^\s\"'<>]+)")
INPUT_TAG = re.compile(r"<input\b[^>]*>", re.I)
HIDDEN = re.compile(r"\btype\s*=\s*[\"']?hidden\b", re.I)
VALUE = re.compile(r"(\bvalue\s*=\s*)([\"'])[^\"']*\2", re.I)


def scrub(text):
    for pattern, replacement in SECRETS:
        text = pattern.sub(replacement, text)
    # URL query values (e.g. OAuth codes, and Duo's transaction tokens), keeping the names
    text = URL_QUERY.sub(lambda m: m.group(1) + re.sub(r"=[^&#]*", "=<redacted>", m.group(2)), text)
    # Hidden form fields' values (e.g. CSRF tokens)
    return INPUT_TAG.sub(lambda m: VALUE.sub(r"\1\2<redacted>\2", m.group(0)) if HIDDEN.search(m.group(0)) else m.group(0),
                         text)


# Escape sequences, and control characters other than \b, \t, \n and \r
ESCAPES = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_]|[\x00-\x07\x0b\x0c\x0e-\x1f\x7f]")
BACKSPACE = re.compile(r"[^\x08\n]\x08")


def clean_transcript(raw):
    """The text of a terminal transcript (script's), as it was shown: without
    escape sequences, and with lines that were overwritten (\\r) as they ended"""
    text = ESCAPES.sub("", raw)
    while BACKSPACE.search(text):
        text = BACKSPACE.sub("", text)
    lines = []
    for line in text.replace("\x08", "").split("\n"):
        segments = [s for s in line.rstrip("\r").split("\r") if s]
        lines.append(segments[-1] if segments else "")
    return "\n".join(lines)


def versions():
    commands = [
        ["sh", "-c", ". /etc/os-release && echo \"$PRETTY_NAME ($(uname -m))\""],
        ["sh", "-c", "python3 -m pip show playwright tc-admin 2>/dev/null | grep -E '^(Name|Version):' | paste -sd ' ' -"],
        ["aws", "--version"],
        ["sh", "-c", "az version --output tsv --query '\"azure-cli\"' | sed 's/^/azure-cli /'"],
        ["sh", "-c", "gcloud --version | head -1"],
        ["sh", "-c", "gh --version | head -1"],
        ["sh", "-c", "openvpn --version | head -1"],
    ]
    out = []
    for command in commands:
        try:
            r = subprocess.run(command, capture_output=True, text=True, timeout=60)
            out.append((r.stdout or r.stderr).strip())
        except Exception as e:
            out.append(f"{command}: {e}")
    return "\n".join(out) + "\n"


def package(dir, path):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(HERE, "diagnostics-README.md"), "README.md")
        z.writestr("versions.txt", versions())
        for root, _, files in os.walk(dir):
            for name in sorted(files):
                full = os.path.join(root, name)
                arcname = os.path.relpath(full, dir)
                if os.path.islink(full):
                    continue
                if name.endswith(".png"):
                    z.write(full, arcname)
                    continue
                text = open(full, encoding="utf-8", errors="replace", newline="").read()
                if arcname == "transcript.raw":
                    arcname, text = "transcript.txt", clean_transcript(text)
                z.writestr(arcname, scrub(text))
    with open(os.open(f"{path}.new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as f:
        f.write(buffer.getvalue())
    if os.getuid() == 0 and os.environ.get("IMAGESET_HOST_UID"):
        os.chown(f"{path}.new", int(os.environ["IMAGESET_HOST_UID"]), int(os.environ["IMAGESET_HOST_GID"]))
    os.replace(f"{path}.new", path)


def replay(path):
    """Loads each captured page (without its scripts, and with the elements
    that weren't visible hidden), at its URL, and says what vpn.duo_step would
    do on it"""
    sys.path.insert(0, HERE)
    import vpn
    from playwright.sync_api import sync_playwright
    tmp = None
    if zipfile.is_zipfile(path):
        tmp = tempfile.mkdtemp()
        zipfile.ZipFile(path).extractall(tmp)
        path = tmp
    try:
        pages = sorted(f for f in os.listdir(os.path.join(path, "browser")) if f.endswith(".html"))
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            for name in pages:
                html = open(os.path.join(path, "browser", name), encoding="utf-8").read()
                html = re.sub(r"<script\b.*?</script>", "", html, flags=re.S | re.I)
                html = "<style>[data-imageset-hidden] { display: none !important }</style>" + html
                url = open(os.path.join(path, "browser", name[:-5] + ".txt")).readline().split(": ", 1)[1].strip()
                page = browser.new_page()
                page.route("**/*", serve(html))
                page.goto(url)
                print(f"{name[:-5]}: {describe(vpn.duo_step(page, other_clicked=False))}")
                page.close()
            browser.close()
    finally:
        if tmp:
            shutil.rmtree(tmp)


def serve(html):
    """A route handler that serves the page, and nothing else"""
    def handler(route):
        if route.request.resource_type == "document":
            route.fulfill(content_type="text/html", body=html)
        else:
            route.abort()
    return handler


def describe(step):
    if step is None:
        return "nothing it knows how to do (vpn.duo gives up)"
    from vpn import CODE_FIELD
    action, target = step
    if action == "done":
        return "the download page: done"
    if action == "code":
        return f"types the 2FA code into {CODE_FIELD}"
    return f"clicks {target.inner_text().splitlines()[0]!r}"


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "package":
        package(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "replay":
        replay(sys.argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
