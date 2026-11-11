"""Tests of clone.sh's use of the checkout's files (IMAGESET_LOCAL_CHANGES),
with rsync: that the clone ends up with exactly the checkout's files, other
than config/ and ignored files, keeping its .git. In the container image:

  docker run --rm -v "$PWD:/repo" -w /repo/imagesets/container imagesets python3 -m pytest -q -p no:cacheprovider test_clone.py
"""

import os
import subprocess

import pytest

CLONE_SH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clone.sh")
ENV = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
       "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def sh(command, cwd):
    return subprocess.run(["bash", "-c", command], cwd=cwd, env=ENV, check=True, capture_output=True, text=True).stdout


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def clone_sh(function, checkout, clone, *args):
    """Runs a function of clone.sh, with these as its checkout and clone"""
    return subprocess.run(["bash", "-c", f'source {CLONE_SH}; CHECKOUT="$1"; CLONE="$2"; shift 2; {function} "$@"',
                           "_", str(checkout), str(clone), *args], env=ENV, capture_output=True, text=True)


def files(root):
    """The files and symlinks under root, other than .git's, with their contents and modes"""
    found = {}
    for dir, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if not (dir == str(root) and d == ".git")]
        for name in names:
            path = os.path.join(dir, name)
            rel = os.path.relpath(path, root)
            found[rel] = ("-> " + os.readlink(path)) if os.path.islink(path) else (open(path).read(), os.stat(path).st_mode & 0o777)
    return found


@pytest.fixture
def repos(tmp_path):
    """Upstream, a clone of it (as clone.sh makes), and a checkout of it"""
    upstream, clone, checkout = tmp_path / "upstream", tmp_path / "clone", tmp_path / "checkout"
    upstream.mkdir()
    for name, text in {"same.txt": "same", "changed.txt": "old", "deleted.txt": "gone", "renamed-from.txt": "moved",
                       "dir-to-file/inner.txt": "inner", "file-to-dir": "file", "deleted-dir/a.txt": "a",
                       "script.sh": "echo", "config/projects/p.yml": "upstream", ".gitignore": "*.secrets\n__pycache__/\n"}.items():
        write(str(upstream / name), text)
    sh("git init -q -b main && git add -A && git commit -qm base", upstream)
    sh(f"git clone -q {upstream} {clone} && git clone -q {upstream} {checkout}", tmp_path)
    return upstream, clone, checkout


def test_mirrors_the_checkout(repos):
    upstream, clone, checkout = repos
    # Every kind of change, committed or not
    sh("""
      echo new > changed.txt
      git rm -q deleted.txt
      git mv renamed-from.txt renamed-to.txt
      git rm -rq dir-to-file && echo now-a-file > dir-to-file
      git rm -q file-to-dir && mkdir file-to-dir && echo inside > file-to-dir/inner.txt
      git rm -rq deleted-dir
      chmod +x script.sh
      ln -s same.txt link
      git add -A && git commit -qm changes
      echo untracked > untracked.txt
      echo uncommitted >> same.txt
      echo local > config/projects/p.yml
      echo secret > x.secrets
      mkdir -p sub/__pycache__ && echo cache > sub/__pycache__/m.pyc
    """, checkout)
    head = sh("git rev-parse HEAD", clone)

    listed = clone_sh("sync-checkout --dry-run", checkout, clone)
    assert listed.returncode == 0, listed.stderr
    assert "  deleted.txt (deleted)" in listed.stdout.splitlines()
    assert "  renamed-to.txt" in listed.stdout.splitlines()
    assert files(clone)["deleted.txt"]

    result = clone_sh("sync-checkout", checkout, clone)
    assert result.returncode == 0, result.stderr
    expected = {name: value for name, value in files(checkout).items()
                if not name.startswith("config/") and name != "x.secrets" and "__pycache__" not in name}
    expected["config/projects/p.yml"] = files(upstream)["config/projects/p.yml"]
    assert files(clone) == expected
    # The clone's git, unchanged, sees the checkout's changes as its own
    assert sh("git rev-parse HEAD", clone) == head
    status = sh("git status --porcelain", clone)
    assert " D deleted.txt" in status and "config" not in status


def test_local_changes(repos):
    upstream, clone, checkout = repos
    assert clone_sh("has-local-changes", checkout, clone).returncode != 0
    # Only behind upstream main: no changes of its own
    sh("echo newer > same.txt && git commit -qam newer", upstream)
    sh("git pull -q", clone)
    assert clone_sh("has-local-changes", checkout, clone).returncode != 0
    # Only config/
    sh("echo local > config/projects/p.yml", checkout)
    assert clone_sh("has-local-changes", checkout, clone).returncode != 0
    # Uncommitted
    sh("echo x > new.txt", checkout)
    assert clone_sh("has-local-changes", checkout, clone).returncode == 0
    # Committed
    sh("git add new.txt && git commit -qm new", checkout)
    assert clone_sh("has-local-changes", checkout, clone).returncode == 0


def test_local_config_changes(repos):
    upstream, clone, checkout = repos
    assert clone_sh("local-config-changes", checkout, clone).stdout == ""
    # Only behind upstream main's config/
    sh("echo newer > config/projects/p.yml && git commit -qam newer", upstream)
    sh("git pull -q", clone)
    assert clone_sh("local-config-changes", checkout, clone).stdout == ""
    # Committed, uncommitted and untracked changes of its own
    sh("echo mine > config/projects/p.yml && git commit -qam mine && echo x > config/aws.yml", checkout)
    result = clone_sh("local-config-changes", checkout, clone)
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == ["config/aws.yml", "config/projects/p.yml"]
