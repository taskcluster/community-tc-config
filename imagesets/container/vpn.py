#!/usr/bin/env python3
"""The Mozilla VPN, in imageset.sh's container (run by run.sh, under
with-gpg).

  vpn.py prepare     Makes sure that /state has the VPN bundle (the OpenVPN
                     configuration, with your certificate and key), encrypted
                     to your gpg key (IMAGESET_GPG_KEY). If it doesn't, signs in
                     to login.mozilla.com (your LDAP password, and a 2FA code,
                     through Duo's prompt in a headless browser) to download it.
  vpn.py connect     Connects (with another 2FA code), and leaves openvpn
                     running, with the VPN's DNS servers in /etc/resolv.conf.
  vpn.py disconnect  Disconnects.

The bundle is only decrypted in memory, or in /dev/shm (a memory filesystem)
while openvpn starts. Passwords and codes are read from the terminal, and kept
in memory only. The VPN only exists inside the container.

With IMAGESET_DIAGNOSTICS_DIR (for imageset.sh's diagnostic log), each page
of the sign-in, and what was done on it, is recorded there (see Capture).
"""

import datetime
import getpass
import io
import os
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.parse
import zipfile

LOGIN = "https://login.mozilla.com"
BUNDLE = "/state/vpn-bundle.zip.gpg"
# Where that is, for messages
BUNDLE_ON_HOST = os.environ.get("IMAGESET_STATE_DIR_ON_HOST", "/state").rstrip("/") + "/vpn-bundle.zip.gpg"
# The macOS workers are in mdc1
CONFIG = "mozilla_vpn/vpn-config-mdc1.conf"
RUN = "/dev/shm/imageset-vpn"
# A 2FA code was asked for already in this run, so the next is "another"
ASKED_CODE = f"{RUN}/asked-code"
# Warn this long before the certificate expires
EXPIRY_WARNING = datetime.timedelta(days=30)
ATTEMPTS = 3
# The file descriptor that with-gpg gives the passphrase on, if it's open
def _open_fds(fd):
    try:
        os.fstat(fd)
        return (fd,)
    except OSError:
        return ()
GPG_FDS = _open_fds(int(os.environ["IMAGESET_GPG_PASSPHRASE_FD"])) if os.environ.get("IMAGESET_GPG_PASSPHRASE_FD") else ()


class VpnError(Exception):
    pass


def username():
    """Your LDAP username: IMAGESET_LDAP_USERNAME, or else asked for,
    suggesting IMAGESET_LDAP_SUGGESTION (from run.sh)"""
    name = os.environ.get("IMAGESET_LDAP_USERNAME", "")
    suggestion = os.environ.get("IMAGESET_LDAP_SUGGESTION", "")
    while not name:
        name = input(f"Your Mozilla LDAP username{f' [{suggestion}]' if suggestion else ' (e.g. you@mozilla.com)'}: ").strip() or suggestion
    return name


def ask_code(user, purpose=""):
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    another = os.path.exists(ASKED_CODE)
    open(ASKED_CODE, "w").close()
    return CAPTURE.secret(getpass.getpass(f"{'Another 2FA code' if another else '2FA code'} for {user}{purpose}: ").strip())


def gpg(*args, input=None):
    r = subprocess.run(["gpg", "--quiet", *args], input=input, capture_output=True, pass_fds=GPG_FDS)
    if r.returncode != 0:
        raise VpnError(f"gpg {' '.join(args)} failed: {r.stderr.decode().strip()}")
    return r.stdout


def read_bundle():
    """The cached bundle, as a ZipFile, or None"""
    if not os.path.exists(BUNDLE):
        return None
    try:
        return zipfile.ZipFile(io.BytesIO(gpg("--decrypt", BUNDLE)))
    except (VpnError, zipfile.BadZipFile) as e:
        print(f"Can't use the VPN bundle in {BUNDLE} ({e}): downloading it again.")
        return None


def save_bundle(data):
    encrypted = gpg("--trust-model", "always", "--encrypt", "--recipient", os.environ["IMAGESET_GPG_KEY"], input=data)
    with open(os.open(f"{BUNDLE}.new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as f:
        f.write(encrypted)
    os.replace(f"{BUNDLE}.new", BUNDLE)


def expiry(bundle):
    """When the bundle's certificate expires"""
    cert = re.search(r"<cert>\s*(.*?)\s*</cert>", bundle.read(CONFIG).decode(), re.S)
    if not cert:
        raise VpnError(f"No certificate in {CONFIG}")
    r = subprocess.run(["openssl", "x509", "-noout", "-enddate"], input=cert.group(1).encode(),
                       capture_output=True, check=True)
    end = r.stdout.decode().strip().split("=", 1)[1]
    return datetime.datetime.strptime(end, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)


def check_expiry(bundle):
    """Fails if the certificate has expired, and warns if it soon will"""
    expires = expiry(bundle)
    left = expires - datetime.datetime.now(datetime.timezone.utc)
    renew = (f"renew it at {LOGIN}/openvpn/ (revoke it there, and generate a new one), then delete {BUNDLE_ON_HOST}, "
             "so that imageset.sh downloads the new one")
    if left <= datetime.timedelta(0):
        raise VpnError(f"Your VPN certificate expired on {expires:%Y-%m-%d}: {renew}.")
    if left < EXPIRY_WARNING:
        print(f"WARNING: your VPN certificate expires on {expires:%Y-%m-%d}: {renew}.")
    return expires



# ---- Diagnostics ----

# A page's controls, and whether each is visible
ELEMENTS = """() => [...document.querySelectorAll('button, a, input, select, textarea, [role=button], [role=link], iframe')].map(e => {
  const attrs = ['id', 'name', 'type', 'role', 'aria-label', 'autocomplete'].filter(a => e.hasAttribute(a)).map(a => `${a}=${e.getAttribute(a)}`);
  return `${e.checkVisibility() ? 'visible' : 'hidden '} <${e.tagName.toLowerCase()} ${attrs.join(' ')}> ${(e.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 120)}`;
})"""


def lean(html):
    """The page's HTML, without the contents of its scripts, and values of its
    hidden inputs (e.g. tokens), which don't matter for finding its controls"""
    html = re.sub(r"(<script\b[^>]*>).*?(</script>)", r"\1\2", html, flags=re.S | re.I)
    return re.sub(r"<input\b[^>]*>",
                  lambda m: re.sub(r"""(\bvalue\s*=\s*)("[^"]*"|'[^']*'|[^\s>]+)""", r'\1""', m.group(0))
                  if re.search(r"""\btype\s*=\s*["']?hidden\b""", m.group(0), re.I) else m.group(0),
                  html, flags=re.I)


class Capture:
    """Records each page of the sign-in (its URL, controls and HTML), and what
    was done, in DIR/browser, for imageset.sh's diagnostic log, with the
    password and codes typed replaced. Pages are captured before anything is
    typed into them."""

    def __init__(self, dir=None):
        self.dir = os.path.join(dir, "browser") if dir else None
        self.secrets = []
        self.pages = 0

    def secret(self, value):
        if value:
            self.secrets.append(value)
        return value

    def scrub(self, text):
        for secret in self.secrets:
            text = text.replace(secret, "<redacted>")
        return text

    def write(self, name, text, mode="w"):
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        with open(os.path.join(self.dir, name), mode, encoding="utf-8") as f:
            f.write(self.scrub(text))

    def log(self, message):
        if self.dir:
            self.write("actions.log", f"{datetime.datetime.now():%H:%M:%S} {message}\n", "a")

    def page(self, page, label):
        if not self.dir:
            return
        self.pages += 1
        name = f"{self.pages:02d}-{label}"
        try:
            self.write(f"{name}.html", lean(page.content()))
            self.write(f"{name}.txt", f"URL: {page.url}\nTitle: {page.title()}\n\n" + "\n".join(page.evaluate(ELEMENTS)) + "\n")
            self.log(f"captured {name}: {page.url}")
        except Exception as e:
            self.log(f"couldn't capture {name}: {e}")


CAPTURE = Capture(os.environ.get("IMAGESET_DIAGNOSTICS_DIR"))


# ---- Downloading the bundle ----

def visible(locator):
    """The first visible element of locator (as a page can have hidden copies
    of an element too), or None"""
    try:
        shown = locator.filter(visible=True)
        return shown.first if shown.count() else None
    except Exception:
        return None


def settle(page):
    from playwright.sync_api import TimeoutError as PlaywrightTimeout
    try:
        page.wait_for_load_state("networkidle", timeout=15000)
    except PlaywrightTimeout:
        pass


def page_text(page):
    try:
        text = re.sub(r"\n\s*\n+", "\n", page.locator("body").inner_text(timeout=5000)).strip()
    except Exception:
        text = ""
    return CAPTURE.scrub("\n".join(f"  | {line[:100]}" for line in text.splitlines()[:20]))


def download_links(page):
    if urllib.parse.urlsplit(page.url).netloc != "login.mozilla.com":
        return []
    return [urllib.parse.urljoin(page.url, h) for h in
            page.locator("a[href*='/openvpn/download/']").evaluate_all("els => els.map(e => e.getAttribute('href'))")]


def sign_in(page, user):
    for attempt in range(ATTEMPTS):
        page.goto(f"{LOGIN}/login/")
        CAPTURE.page(page, "login")
        page.fill("#id_username", user)
        page.fill("#id_password", CAPTURE.secret(getpass.getpass(f"Password for {user} (Mozilla LDAP): ")))
        page.click("button[type=submit]")
        CAPTURE.log("filled #id_username and #id_password, and clicked button[type=submit]")
        settle(page)
        if urllib.parse.urlsplit(page.url).path.rstrip("/") != "/login":
            return
        CAPTURE.log("the password was rejected")
        print("That password was rejected." + (" Try again." if attempt + 1 < ATTEMPTS else ""))
    raise VpnError(f"Couldn't sign in to {LOGIN}")


CODE_FIELD = "#passcode-input"
# How long to wait for what is expected next, and to be back at login.mozilla.com after a code (ms)
WAIT = 15000
CODE_WAIT = 20000
# In order of preference
PASSCODE_OPTIONS = [re.compile(r"^\s*Hardware token", re.I), re.compile(r"^\s*Duo Mobile passcode", re.I)]


def duo_step(page, other_clicked):
    """What to do next at Duo's Universal Prompt, as it is now: (action,
    locator), where action is "done" (at the download page), "code" (type a
    2FA code into it), "option" (click it: a passcode option), or "other"
    (click it: Other options); or None, if there's nothing to do"""
    if download_links(page):
        return ("done", None)
    code_field = visible(page.locator(CODE_FIELD))
    if code_field:
        return ("code", code_field)
    for name in PASSCODE_OPTIONS:
        option = visible(page.get_by_role("button", name=name))
        if option:
            return ("option", option)
    other = visible(page.get_by_role("button", name="Other options"))
    if not other_clicked and other:
        return ("other", other)
    return None


def duo(page, user):
    """Duo's Universal Prompt: Other options, then Hardware token (a code from
    an authenticator app) or, if there isn't one, Duo Mobile passcode (a code
    from the Duo Mobile app), then the code. Never anything else."""
    from playwright.sync_api import TimeoutError as PlaywrightTimeout
    other_clicked = False
    codes = 0
    for _ in range(12):
        settle(page)
        CAPTURE.page(page, "duo")
        try:
            step = duo_step(page, other_clicked)
            if step is None:
                break
            action, target = step
            if action == "done":
                return
            if action == "code":
                if codes == ATTEMPTS:
                    break
                if codes:
                    print("That code was rejected: wait for the next one.")
                codes += 1
                target.fill(ask_code(user))
                page.keyboard.press("Enter")
                CAPTURE.log(f"typed a 2FA code into {CODE_FIELD}, and pressed Enter")
                try:
                    page.wait_for_url(re.compile(r"^https://login\.mozilla\.com/"), timeout=CODE_WAIT)
                except PlaywrightTimeout:
                    CAPTURE.log(f"not back at login.mozilla.com after {CODE_WAIT // 1000}s")
                continue
            CAPTURE.log(f"clicking {(target.inner_text(timeout=5000).splitlines() or [action])[0]!r}")
            target.click(timeout=10000)
            if action == "other":
                other_clicked = True
                waiting = page.get_by_role("button", name=re.compile("|".join(p.pattern for p in PASSCODE_OPTIONS), re.I))
            else:
                waiting = page.locator(CODE_FIELD)
            try:
                waiting.filter(visible=True).first.wait_for(timeout=WAIT)
            except PlaywrightTimeout:
                CAPTURE.log(f"what was expected next didn't appear within {WAIT // 1000}s")
        except PlaywrightTimeout as e:
            # e.g. an element replaced while Duo animates: look again
            CAPTURE.log(f"timed out, looking again: {e}")
            continue
    CAPTURE.log("found nothing to do on the page: giving up")
    raise VpnError("Couldn't get through Duo's prompt, which showed:\n" + page_text(page) +
                   "\n(imageset.sh uses Duo's \"Hardware token\" option, for a code from an authenticator app, "
                   "or else its \"Duo Mobile passcode\" option, for a code from the Duo Mobile app.)")


def download(user):
    from playwright.sync_api import sync_playwright
    print(f"Downloading your VPN certificate from {LOGIN}, as {user}...")
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            # As some sites turn away "HeadlessChrome"
            user_agent = browser.new_page().evaluate("navigator.userAgent").replace("HeadlessChrome", "Chrome")
            page = browser.new_context(user_agent=user_agent).new_page()
            try:
                sign_in(page, user)
                page.goto(f"{LOGIN}/openvpn/")
                duo(page, user)
                CAPTURE.page(page, "openvpn")
                # Only ever the download link: the page also has one to revoke the certificate
                linux = [l for l in download_links(page) if l.rstrip("/").endswith("/Linux")]
                if not linux:
                    raise VpnError(f"No Linux download on {LOGIN}/openvpn/, which showed:\n" + page_text(page))
                CAPTURE.log(f"downloading {linux[0]}")
                response = page.request.get(linux[0])
                if not response.ok:
                    raise VpnError(f"Downloading {linux[0]} failed: HTTP {response.status}")
                CAPTURE.log(f"downloaded {len(response.body())} bytes ({response.headers.get('content-type')})")
                return response.body()
            except Exception as e:
                CAPTURE.log(f"failed: {type(e).__name__}: {e}")
                CAPTURE.page(page, "failed")
                raise
        finally:
            browser.close()


def prepare():
    bundle = read_bundle()
    if bundle:
        check_expiry(bundle)
        return
    data = download(username())
    try:
        bundle = zipfile.ZipFile(io.BytesIO(data))
        bundle.read(CONFIG)
    except (zipfile.BadZipFile, KeyError) as e:
        raise VpnError(f"The download isn't a VPN bundle with {CONFIG}: {e}")
    expires = check_expiry(bundle)
    save_bundle(data)
    print(f"Downloaded your VPN certificate (valid until {expires:%Y-%m-%d}), and stored it encrypted to your gpg key.")


# ---- Connecting ----

def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def connect():
    bundle = read_bundle()
    if not bundle:
        raise VpnError("No VPN bundle: run vpn.py prepare first")
    config = bundle.read(CONFIG)
    user = bundle.read("mozilla_vpn/username.txt").decode().strip() or username()
    remote = re.search(r"^remote\s+(\S+)", config.decode(), re.M)
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    conf, sock, pushed, log, pid = (f"{RUN}/{n}" for n in ("vpn.conf", "management", "pushed", "openvpn.log", "openvpn.pid"))
    for path in (sock, pushed):
        if os.path.exists(path):
            os.remove(path)
    with open(os.open(conf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as f:
        f.write(config)
    # Records the DNS servers that the VPN pushes (through sh, as /dev/shm is noexec)
    with open(f"{RUN}/up.sh", "w") as f:
        f.write(f"env | grep '^foreign_option_' > {pushed} || true\n")
    print(f"Connecting to the Mozilla VPN ({remote.group(1) if remote else 'mdc1'})...")
    vpn = subprocess.Popen(["openvpn", "--config", conf, "--management", sock, "unix", "--management-query-passwords",
                            "--management-hold", "--auth-retry", "interact", "--script-security", "2",
                            "--up", f"/bin/sh {RUN}/up.sh", "--log", log, "--writepid", pid, "--verb", "3"],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           start_new_session=True)
    try:
        connected = manage(vpn, sock, user)
    finally:
        os.remove(conf)
    if not connected:
        if vpn.poll() is None:
            vpn.terminate()
        tail = "".join(open(log).readlines()[-15:]) if os.path.exists(log) else "(no log)"
        raise VpnError(f"Couldn't connect to the VPN. The end of openvpn's log:\n{tail}")
    use_vpn_dns(pushed)
    print("Connected to the VPN.")


def manage(vpn, sock, user):
    """Answers openvpn's management interface until it is connected"""
    for _ in range(100):
        if os.path.exists(sock) or vpn.poll() is not None:
            break
        time.sleep(0.1)
    if not os.path.exists(sock):
        return False
    m = socket.socket(socket.AF_UNIX)
    m.connect(sock)
    m.settimeout(120)

    def send(command):
        m.sendall((command + "\n").encode())

    send("state on")
    attempts = 0
    challenge = None
    try:
        for line in m.makefile("r", encoding="utf-8", newline="\n"):
            line = line.rstrip("\r\n")
            if line.startswith(">HOLD:"):
                # Also after a failed attempt, before retrying
                send("hold release")
            elif line.startswith(">PASSWORD:Need 'Auth' username/password"):
                if attempts == ATTEMPTS:
                    return False
                attempts += 1
                if challenge:
                    state_id, text = challenge
                    password = f"CRV1::{state_id}::{getpass.getpass(f'{text}: ')}"
                    challenge = None
                else:
                    password = ask_code(user, ", for the VPN")
                send(f'username "Auth" {quote(user)}')
                send(f'password "Auth" {quote(password)}')
            elif line.startswith(">PASSWORD:Verification Failed: 'Auth' ['CRV1:"):
                _, state_id, _, text = line.split("['CRV1:", 1)[1].rstrip("']").split(":", 3)
                challenge = (state_id, text)
            elif line.startswith(">PASSWORD:Verification Failed"):
                if attempts < ATTEMPTS:
                    print("That code was rejected: wait for the next one.")
            elif line.startswith(">STATE:") and line.split(",")[1] == "CONNECTED":
                return True
            elif line.startswith(">FATAL"):
                return False
    except socket.timeout:
        return False
    finally:
        m.close()
    return False


def use_vpn_dns(pushed):
    """Puts the VPN's DNS servers and domains first in /etc/resolv.conf"""
    servers, domains = [], []
    for line in open(pushed) if os.path.exists(pushed) else []:
        value = line.split("=", 1)[1].strip()
        if value.startswith("dhcp-option DNS "):
            servers.append(value.split()[2])
        elif value.startswith(("dhcp-option DOMAIN ", "dhcp-option DOMAIN-SEARCH ")):
            domains.append(value.split()[2])
    if not servers:
        return
    original = open("/etc/resolv.conf").read()
    if not os.path.exists(f"{RUN}/resolv.conf.orig"):
        with open(f"{RUN}/resolv.conf.orig", "w") as f:
            f.write(original)
    with open("/etc/resolv.conf", "w") as f:
        f.write("".join(f"nameserver {s}\n" for s in servers)
                + (f"search {' '.join(domains)}\n" if domains else "")
                + "".join(l + "\n" for l in original.splitlines() if l.startswith("nameserver")))


def disconnect():
    pid_file = f"{RUN}/openvpn.pid"
    if os.path.exists(pid_file):
        pid = int(open(pid_file).read().strip())
        try:
            os.kill(pid, signal.SIGTERM)
            for _ in range(100):
                os.kill(pid, 0)
                time.sleep(0.1)
        except ProcessLookupError:
            pass
        # openvpn removes it, as it exits
        if os.path.exists(pid_file):
            os.remove(pid_file)
        print("Disconnected from the VPN.")
    if os.path.exists(f"{RUN}/resolv.conf.orig"):
        with open("/etc/resolv.conf", "w") as f:
            f.write(open(f"{RUN}/resolv.conf.orig").read())
        os.remove(f"{RUN}/resolv.conf.orig")


def main():
    commands = {"prepare": prepare, "connect": connect, "disconnect": disconnect}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit(f"Usage: {sys.argv[0]} {'|'.join(commands)}")
    try:
        commands[sys.argv[1]]()
    except VpnError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
