#!/usr/bin/env python3
"""pass under the sign-in box (PassStore.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/pass_store.py`. Needs pass,
gpg and oathtool from Homebrew. Everything it decrypts is its own: a
throwaway password store in a folder under /tmp, encrypted to a throwaway
key without a passphrase in a keyring beside it (GNUPGHOME), both removed at
the end. The real store and keyring are never read. The probe is pointed at
them through the bench's `passstore`, which only a test run has.

A local page on 127.0.0.1 has a sign-in form and a box for a code. Checked:

- with the switch off, nothing from pass is offered;
- on, the store's account for 127.0.0.1 hangs from the box, by its file's
  name, and another site's doesn't;
- a pick fills the login line's name and the first line's password;
- an account with no login line fills its file's name;
- under the box for a code, a pick fills `pass otp`'s code, and an account
  without one fills nothing;
- a private tab is offered nothing.

Nothing here makes, shows or brings forward a window.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pass-store")

BIN = next((d for d in ("/opt/homebrew/bin", "/usr/local/bin") if os.path.exists(f"{d}/pass")), None)
# Made up for this test, in a store that exists only while it runs.
PASSWORD = "made-up-pw-4711"
LOGIN = "someone@example.invalid"
SECRET = "JBSWY3DPEHPK3PXP"

SIGNIN = """<!doctype html><title>sign in</title>
<form id="f" onsubmit="return false">
<input id="user" name="username" autocomplete="username" autofocus>
<input id="pw" name="password" type="password" autocomplete="current-password">
<button>Sign in</button></form>"""
CODE = """<!doctype html><title>code</title>
<form onsubmit="return false"><label for="code">Verification code</label>
<input id="code" name="otp" autocomplete="one-time-code" inputmode="numeric" autofocus>
<button>Verify</button></form>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (CODE if self.path.startswith("/code") else SIGNIN).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


def make_store(root):
    """A keyring with one key and no passphrase, and a store encrypted to it."""
    home, store = f"{root}/gnupg", f"{root}/store"
    os.makedirs(home, mode=0o700)
    env = dict(os.environ, GNUPGHOME=home, PASSWORD_STORE_DIR=store, PATH=f"{BIN}:/usr/bin:/bin")
    def run(*args, text=None):
        subprocess.run(args, input=text, env=env, check=True, capture_output=True, text=True)
    run("gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
        "--quick-gen-key", "Search pass test <pass-test@example.invalid>", "default", "default", "never")
    fingerprint = subprocess.run(["gpg", "--batch", "--with-colons", "--list-secret-keys"], env=env,
                                 capture_output=True, text=True).stdout
    fpr = next(line.split(":")[9] for line in fingerprint.splitlines() if line.startswith("fpr:"))
    run("pass", "init", fpr)
    run("pass", "insert", "-m", "127.0.0.1/work-account", text=f"{PASSWORD}\nlogin: {LOGIN}\nurl: http://127.0.0.1/\n")
    run("pass", "insert", "-m", "127.0.0.1/no-login", text="second-made-up-pw\n")
    run("pass", "insert", "-m", "127.0.0.1/with-code",
        text=f"third-made-up-pw\nlogin: coder@example.invalid\notpauth://totp/Test:coder?secret={SECRET}&issuer=Test\n")
    run("pass", "insert", "-m", "elsewhere.example/not-this-site", text="fourth\n")
    return home, store, env


def acc(**f): return sv.cmd({"do": "accounts", **f})


def open_page(base, path):
    tab = sv.sp("open", url=f"{base}{path}")["resultID"]
    sv.sp("select", id=tab)
    time.sleep(1.5)
    return tab


def value(tab, box): return sv.ev(tab, f"document.getElementById('{box}').value")


def pick(name):
    """The row named so, picked once the list takes clicks."""
    rows = acc().get("rows") or []
    at = next((i for i, row in enumerate(rows) if name in row.values()), None)
    if at is None: return False
    time.sleep(0.6)
    acc(pick=at)
    time.sleep(2)
    return True


def main():
    if not BIN or not shutil.which("gpg", path=BIN) or not shutil.which("oathtool", path=BIN):
        sys.exit("pass, gpg and oathtool are needed (Homebrew)")
    t = sv.T()
    root = tempfile.mkdtemp(prefix="pst-", dir="/tmp")
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}"
    home = None
    try:
        home, store, env = make_store(root)
        sv.setup(); sv.launch()
        acc(forget=True)
        r = sv.cmd({"do": "passstore", "folder": store, "keyring": home, "on": False})
        t.ok("the test's store is the probe's", r["here"] and r["test"] and len(r["entries"]) == 4, r)

        tab = open_page(base, "/login")
        r = acc()
        t.ok("off: nothing from pass under the box", not any("pass" in row for row in r.get("rows") or []), r)

        sv.cmd({"do": "passstore", "on": True})
        tab = open_page(base, "/login")
        r = acc()
        names = [row.get("pass") for row in r.get("rows") or [] if "pass" in row]
        t.ok("on: the site's accounts hang from the box, by name",
             sorted(names) == ["no-login", "with-code", "work-account"], r)
        t.ok("…not another site's", "not-this-site" not in names, names)

        t.ok("a pick", pick("work-account"))
        t.ok("…fills the login line's name", value(tab, "user") == LOGIN, value(tab, "user"))
        t.ok("…and the first line's password", value(tab, "pw") == PASSWORD)
        r = acc()
        t.ok("…and asks nothing about saving it", not r.get("offer"), r)

        tab = open_page(base, "/login")
        t.ok("an account without a login line", pick("no-login"))
        t.ok("…fills its file's name", value(tab, "user") == "no-login", value(tab, "user"))

        tab = open_page(base, "/code")
        r = acc()
        codes = [row.get("passCode") for row in r.get("rows") or [] if "passCode" in row]
        t.ok("under a box for a code, the site's accounts", sorted(codes) == ["no-login", "with-code", "work-account"], r)
        t.ok("a pick of one with a code", pick("with-code"))
        want = subprocess.run([f"{BIN}/oathtool", "--totp", "-b", SECRET], capture_output=True, text=True).stdout.strip()
        got = value(tab, "code")
        # The code may have turned over between the two.
        t.ok("…fills pass otp's code", got.isdigit() and len(got) == 6 and (got == want or abs(int(time.time()) % 30) < 3), (got, want))

        tab = open_page(base, "/code")
        t.ok("a pick of one without a code", pick("no-login"))
        t.ok("…fills nothing", value(tab, "code") == "", value(tab, "code"))

        shy = sv.cmd({"do": "open", "url": f"{base}/login", "private": True})["id"]
        sv.sp("select", id=shy); time.sleep(1.5)
        r = acc()
        t.ok("a private tab is offered nothing from pass", not any("pass" in row for row in r.get("rows") or []), r)
    finally:
        try: acc(forget=True)
        except Exception: pass
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
        if home: subprocess.run([f"{BIN}/gpgconf", "--kill", "all"], env=dict(os.environ, GNUPGHOME=home), capture_output=True)
        shutil.rmtree(root, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
