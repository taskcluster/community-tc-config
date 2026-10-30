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
GPG_FDS = (int(os.environ["IMAGESET_GPG_PASSPHRASE_FD"]),) if os.environ.get("IMAGESET_GPG_PASSPHRASE_FD") else ()


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
    return getpass.getpass(f"{'Another 2FA code' if another else '2FA code'} for {user}{purpose}: ").strip()


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



# ---- Downloading the bundle ----

def visible(locator):
    try:
        return locator.count() > 0 and locator.first.is_visible()
    except Exception:
        return False


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
    return "\n".join(f"  | {line[:100]}" for line in text.splitlines()[:20])


def download_links(page):
    if urllib.parse.urlsplit(page.url).netloc != "login.mozilla.com":
        return []
    return [urllib.parse.urljoin(page.url, h) for h in
            page.locator("a[href*='/openvpn/download/']").evaluate_all("els => els.map(e => e.getAttribute('href'))")]


def sign_in(page, user):
    for attempt in range(ATTEMPTS):
        page.goto(f"{LOGIN}/login/")
        page.fill("#id_username", user)
        page.fill("#id_password", getpass.getpass(f"Password for {user} (Mozilla LDAP): "))
        page.click("button[type=submit]")
        settle(page)
        if urllib.parse.urlsplit(page.url).path.rstrip("/") != "/login":
            return
        print("That password was rejected." + (" Try again." if attempt + 1 < ATTEMPTS else ""))
    raise VpnError(f"Couldn't sign in to {LOGIN}")


def duo(page, user):
    """Duo's Universal Prompt: Other options, then Hardware token (a code from
    an authenticator app), then the code. Never anything else."""
    from playwright.sync_api import TimeoutError as PlaywrightTimeout
    passcode_option = re.compile(r"^\s*Hardware token", re.I)
    other_clicked = False
    codes = 0
    for _ in range(12):
        settle(page)
        if download_links(page):
            return
        try:
            code_field = page.locator("#passcode-input")
            if visible(code_field):
                if codes == ATTEMPTS:
                    break
                if codes:
                    print("That code was rejected: wait for the next one.")
                codes += 1
                code_field.first.fill(ask_code(user))
                page.keyboard.press("Enter")
                try:
                    page.wait_for_url(re.compile(r"^https://login\.mozilla\.com/"), timeout=20000)
                except PlaywrightTimeout:
                    pass
                continue
            option = page.get_by_role("button", name=passcode_option)
            if visible(option):
                option.first.click(timeout=10000)
                try:
                    code_field.first.wait_for(state="visible", timeout=15000)
                except PlaywrightTimeout:
                    pass
                continue
            other = page.get_by_role("button", name="Other options")
            if not other_clicked and visible(other):
                other.first.click(timeout=10000)
                other_clicked = True
                try:
                    option.first.wait_for(state="visible", timeout=15000)
                except PlaywrightTimeout:
                    pass
                continue
        except PlaywrightTimeout:
            # e.g. an element replaced while Duo animates: look again
            continue
        break
    raise VpnError("Couldn't get through Duo's prompt, which showed:\n" + page_text(page) +
                   "\n(imageset.sh uses Duo's \"Hardware token\" option, for a code from an authenticator app.)")


def download(user):
    from playwright.sync_api import sync_playwright
    print(f"Downloading your VPN certificate from {LOGIN}, as {user}...")
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            # As some sites turn away "HeadlessChrome"
            user_agent = browser.new_page().evaluate("navigator.userAgent").replace("HeadlessChrome", "Chrome")
            page = browser.new_context(user_agent=user_agent).new_page()
            sign_in(page, user)
            page.goto(f"{LOGIN}/openvpn/")
            duo(page, user)
            # Only ever the download link: the page also has one to revoke the certificate
            linux = [l for l in download_links(page) if l.rstrip("/").endswith("/Linux")]
            if not linux:
                raise VpnError(f"No Linux download on {LOGIN}/openvpn/, which showed:\n" + page_text(page))
            response = page.request.get(linux[0])
            if not response.ok:
                raise VpnError(f"Downloading {linux[0]} failed: HTTP {response.status}")
            return response.body()
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
