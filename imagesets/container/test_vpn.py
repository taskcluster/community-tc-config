"""Tests of vpn.py's sign-in, against a mock of login.mozilla.com and Duo's
Universal Prompt. In the container image:

  docker run --rm -v "$PWD:/repo" -w /repo/imagesets/container imagesets python3 -m pytest -q test_vpn.py
"""

import base64
import json
import os
import sys

import pytest
from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vpn  # noqa: E402

PASSWORD = "correct horse battery staple"
GOOD_CODE = "246810"
DUO = "https://api-x.duosecurity.com/frame/v4/auth/prompt?sid=frameless-abc123"

LOGIN_PAGE = """<html><body><form onsubmit="event.preventDefault();
  location = btoa(document.getElementById('id_password').value) === '%s' ? '/' : '/login/'">
<input id=id_username><input id=id_password type=password><input type=hidden name=csrfmiddlewaretoken value=csrf-secret-123>
<button type=submit>Sign in</button></form></body></html>""" % base64.b64encode(PASSWORD.encode()).decode()

# Duo Push first, then Other options, the options, and each option's passcode view
DUO_PAGE = """<html><body><h2>Check for a Duo Push</h2><button onclick="show()">Other options</button>
<div style="display: none"><button>Hardware token</button></div>
<script>
function show() {
  document.body.innerHTML = '<a>Back</a><h2>Select an option to log in</h2>' + %s.map(o =>
    `<button onclick="code('${o}')"><div>${o}</div><div>Some description</div></button>`).join('');
}
function code(o) {
  setTimeout(() => {
    document.body.innerHTML = `<h2>Enter a passcode (${o})</h2><input id=passcode-input>`;
    const input = document.getElementById('passcode-input');
    input.onkeydown = e => {
      if (e.key !== 'Enter') return;
      if (btoa(input.value) === %s) location = 'https://login.mozilla.com/openvpn/?via=' + encodeURIComponent(o);
      else { document.querySelector('h2').textContent = `Incorrect passcode ${input.value}`; input.value = ''; }
    };
  }, 300);
}
</script></body></html>"""

OPENVPN_PAGE = """<html><body><a href="/openvpn/download/7/Linux">Linux</a> <a href="/openvpn/revoke/7">Revoke</a></body></html>"""


def run_sign_in(options, codes, tmp_path, monkeypatch, capture=True):
    """Signs in, and goes through Duo, with the given options, typing the given codes"""
    monkeypatch.setattr(vpn, "CAPTURE", vpn.Capture(str(tmp_path) if capture else None))
    monkeypatch.setattr(vpn, "WAIT", 3000)
    monkeypatch.setattr(vpn, "CODE_WAIT", 3000)
    monkeypatch.setattr(vpn, "RUN", str(tmp_path / "run"))
    monkeypatch.setattr(vpn, "ASKED_CODE", str(tmp_path / "run" / "asked-code"))
    monkeypatch.setattr(vpn.getpass, "getpass", lambda prompt: PASSWORD if "Password" in prompt else next(codes))
    duo_page = DUO_PAGE % (json.dumps(options), json.dumps(base64.b64encode(GOOD_CODE.encode()).decode()))

    def login(route):
        path = route.request.url.split("login.mozilla.com", 1)[1]
        if path.startswith("/login"):
            body = LOGIN_PAGE
        elif path.startswith("/openvpn/?via="):
            body = OPENVPN_PAGE
        elif path.startswith("/openvpn"):
            body = f"<script>location = {json.dumps(DUO)}</script>"
        else:
            body = "<html><body>Home</body></html>"
        route.fulfill(content_type="text/html", body=body)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        page.route("https://login.mozilla.com/**", login)
        page.route("https://api-x.duosecurity.com/**", lambda route: route.fulfill(content_type="text/html", body=duo_page))
        try:
            vpn.sign_in(page, "someone@mozilla.com")
            page.goto(f"{vpn.LOGIN}/openvpn/")
            vpn.duo(page, "someone@mozilla.com")
            return page.url
        finally:
            browser.close()


def test_duo_mobile_passcode(tmp_path, monkeypatch):
    url = run_sign_in(["Duo Push", "Duo Mobile passcode", "Bypass Code"], iter([GOOD_CODE]), tmp_path, monkeypatch)
    assert url.endswith("?via=Duo%20Mobile%20passcode")


def test_hardware_token_preferred(tmp_path, monkeypatch):
    url = run_sign_in(["Duo Push", "Duo Mobile passcode", "Hardware token"], iter([GOOD_CODE]), tmp_path, monkeypatch)
    assert url.endswith("?via=Hardware%20token")


def test_rejected_code(tmp_path, monkeypatch, capsys):
    url = run_sign_in(["Duo Mobile passcode"], iter(["111111", GOOD_CODE]), tmp_path, monkeypatch)
    assert url.endswith("?via=Duo%20Mobile%20passcode")
    assert "That code was rejected" in capsys.readouterr().out


def test_too_many_rejected_codes(tmp_path, monkeypatch):
    with pytest.raises(vpn.VpnError, match="Incorrect passcode"):
        run_sign_in(["Duo Mobile passcode"], iter(["111111"] * 3 + [GOOD_CODE]), tmp_path, monkeypatch)


def test_no_passcode_option(tmp_path, monkeypatch):
    with pytest.raises(vpn.VpnError, match="Couldn't get through Duo's prompt"):
        run_sign_in(["Duo Push", "Bypass Code"], iter([GOOD_CODE]), tmp_path, monkeypatch)


def test_capture_scrubs_secrets(tmp_path):
    capture = vpn.Capture(str(tmp_path))
    capture.secret(PASSWORD)
    capture.log(f"typed {PASSWORD}")
    capture.write("page.html", f"<p>{PASSWORD}</p>")
    assert PASSWORD not in (tmp_path / "browser" / "actions.log").read_text()
    assert (tmp_path / "browser" / "page.html").read_text() == "<p><redacted></p>"


def test_without_capture(tmp_path, monkeypatch):
    run_sign_in(["Duo Mobile passcode"], iter([GOOD_CODE]), tmp_path, monkeypatch, capture=False)
    assert not (tmp_path / "browser").exists()


def test_capture(tmp_path, monkeypatch):
    run_sign_in(["Duo Push", "Duo Mobile passcode"], iter(["111111", GOOD_CODE]), tmp_path, monkeypatch)
    files = sorted(os.listdir(tmp_path / "browser"))
    assert {"actions.log", "01-login.html", "01-login.txt", "02-duo.html", "02-duo.txt"} <= set(files)
    for name in files:
        text = (tmp_path / "browser" / name).read_text()
        assert PASSWORD not in text and GOOD_CODE not in text and "111111" not in text, name
    actions = (tmp_path / "browser" / "actions.log").read_text()
    assert "clicking 'Other options'" in actions and "clicking 'Duo Mobile passcode'" in actions
    assert "typed a 2FA code into #passcode-input" in actions
    # The rejected code, which the mock shows on the page
    assert "Incorrect passcode <redacted>" in (tmp_path / "browser" / "05-duo.html").read_text()
    # The hidden Hardware token button, on the first page
    assert "hidden  <button > Hardware token" in (tmp_path / "browser" / "02-duo.txt").read_text()
