"""Tests of clone.sh's use of the checkout's files (IMAGESET_LOCAL_CHANGES):
that the clone ends up with exactly the checkout's files (with rsync), other
than config/ and ignored files, keeping its .git, and that checkouts without
upstream main's latest commit, or with changes to config/, are refused. In
the container image:

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


def clone_sh(function, checkout, clone, *args, local_changes="", answer="", env=ENV):
    """Runs a function of clone.sh, with these as its checkout and clone"""
    return subprocess.run(
        ["bash", "-c", f'source {CLONE_SH}; CHECKOUT="$1"; CLONE="$2"; IMAGESET_LOCAL_CHANGES="$3"; shift 3; {function} "$@"',
         "_", str(checkout), str(clone), local_changes, *args], env=env, input=answer, capture_output=True, text=True)


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
      echo ignored > 'w[1].secrets'
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
                if not name.startswith("config/") and not name.endswith(".secrets") and "__pycache__" not in name}
    expected["config/projects/p.yml"] = files(upstream)["config/projects/p.yml"]
    assert files(clone) == expected
    # The clone's git, unchanged, sees the checkout's changes as its own
    assert sh("git rev-parse HEAD", clone) == head
    status = sh("git status --porcelain", clone)
    assert " D deleted.txt" in status and "config" not in status


def test_checkout_has_upstream(repos):
    upstream, clone, checkout = repos
    assert clone_sh("checkout-has-upstream", checkout, clone).returncode == 0
    sh("echo newer > same.txt && git commit -qam newer", upstream)
    sh("git pull -q", clone)
    assert clone_sh("checkout-has-upstream", checkout, clone).returncode != 0
    sh("git pull -q", checkout)
    assert clone_sh("checkout-has-upstream", checkout, clone).returncode == 0


def test_local_config_changes(repos):
    upstream, clone, checkout = repos
    assert clone_sh("local-config-changes", checkout, clone).stdout == ""
    # Committed, uncommitted and untracked changes
    sh("echo mine > config/projects/p.yml && git commit -qam mine && echo x > config/aws.yml", checkout)
    assert clone_sh("local-config-changes", checkout, clone).stdout.splitlines() == ["config/aws.yml", "config/projects/p.yml"]
    # Once landed upstream (as a different commit, e.g. squash merged), and the checkout has it, they don't count
    sh("rm config/aws.yml", checkout)
    sh("echo mine > config/projects/p.yml && git commit -qam squashed", upstream)
    sh("git pull -q", clone)
    sh("git pull -q --rebase", checkout)
    assert clone_sh("local-config-changes", checkout, clone).stdout == ""


def test_refuses_checkout_without_upstream(repos):
    upstream, clone, checkout = repos
    sh("echo newer > same.txt && git commit -qam newer", upstream)
    sh("git pull -q", clone)
    sh("echo mine > changed.txt", checkout)
    result = clone_sh("choose-local-changes", checkout, clone, local_changes="true")
    assert result.returncode == 64 and "git pull " in result.stderr
    # Not asked, without IMAGESET_LOCAL_CHANGES: upstream main's files run
    result = clone_sh("choose-local-changes; echo $IMAGESET_LOCAL_CHANGES", checkout, clone)
    assert result.returncode == 0 and "upstream main's files run" in result.stdout
    assert result.stdout.splitlines()[-1] == "false"
    assert files(clone)["changed.txt"][0] == "old"


def test_refuses_config_changes(repos):
    upstream, clone, checkout = repos
    sh("echo mine > changed.txt && echo local > config/projects/p.yml", checkout)
    result = clone_sh("choose-local-changes", checkout, clone, local_changes="true")
    assert result.returncode == 64 and "config/projects/p.yml" in result.stderr and "land them" in result.stderr
    assert files(clone)["changed.txt"][0] == "old"


def test_asks(repos):
    upstream, clone, checkout = repos
    sh("echo mine > changed.txt", checkout)
    result = clone_sh("choose-local-changes", checkout, clone, answer="n\n")
    assert result.returncode == 0 and "  changed.txt" in result.stdout
    assert files(clone)["changed.txt"][0] == "old"
    result = clone_sh("choose-local-changes", checkout, clone, answer="y\n")
    assert result.returncode == 0
    assert files(clone)["changed.txt"][0] == "mine\n"


def test_global_gitignore(repos, tmp_path):
    upstream, clone, checkout = repos
    write(str(tmp_path / "ignore"), ".envrc\n")
    write(str(tmp_path / "gitconfig"), f"[core]\n\texcludesFile = {tmp_path / 'ignore'}\n")
    env = {**ENV, "GIT_CONFIG_GLOBAL": str(tmp_path / "gitconfig")}
    sh("echo token > .envrc", checkout)
    assert clone_sh("has-local-changes", checkout, clone, env=env).returncode != 0
    assert clone_sh("sync-checkout --dry-run", checkout, clone, env=env).stdout == ""


def test_permissions(repos):
    upstream, clone, checkout = repos
    # As git: only whether a file is executable counts (not e.g. a umask of 002's group write)
    sh("chmod g+w same.txt changed.txt", checkout)
    assert clone_sh("sync-checkout --dry-run", checkout, clone).stdout == ""
    sh("chmod +x script.sh", checkout)
    assert clone_sh("sync-checkout --dry-run", checkout, clone).stdout.splitlines() == ["  script.sh"]
    clone_sh("sync-checkout", checkout, clone)
    assert os.access(clone / "script.sh", os.X_OK)
