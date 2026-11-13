#!/usr/bin/env python3
"""End to end: `venom-desk attach` next to `venomx attach` on one
session, both on real PTYs against a real venomx daemon.

Each client's host-terminal output is replayed into a fresh venom-term Vt by
the screen helper, so assertions read what a user would see: both show the
same segments, attention and floats; keys typed into venom-desk reach the
focused pane; the palette opens and lists venomx verbs; the leader detaches.

Usage: attach.py <venom-desk> <screen> <venomx>. Skips (exit 0) when
<venomx> is missing.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

from ptyclient import TIMEOUT, leader_byte, until
import ptyclient

DESK = str(Path(sys.argv[1]).resolve())
SCREEN = str(Path(sys.argv[2]).resolve())
VENOMX = Path(sys.argv[3])
if not VENOMX.is_absolute():
    VENOMX = (Path(__file__).resolve().parent.parent / VENOMX)
if not VENOMX.exists():
    print(f'skip: no venomx binary at {VENOMX} (build venomx, or pass -Dvenomx=PATH)')
    sys.exit(0)
VENOMX = str(VENOMX.resolve())
COLS, ROWS = 100, 30


def Client(name, argv, env):
    return ptyclient.Client(name, argv, env, SCREEN, COLS, ROWS)


with tempfile.TemporaryDirectory(prefix='desk-attach-', dir='/tmp') as root:
    root = Path(root)
    path = str(root / 'x.sock')
    runtime = root / 'r'
    runtime.mkdir(mode=0o700)
    bindir = root / 'bin'
    bindir.mkdir()
    (bindir / 'venomx').symlink_to(VENOMX)
    env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN') and not k.startswith('VENOMX_')}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_STATE_HOME=str(root / 'state'), XDG_RUNTIME_DIR=str(runtime),
               PS1='$ ', ENV='', TERM='xterm-256color', SHELL='/bin/sh', VENOMX_SOCKET=path,
               PATH=f'{bindir}:{os.environ.get("PATH", "/usr/bin:/bin")}')
    owner = dict(env, VENOMX_TOKEN='@owner', VENOM_DESK_TOKEN='@owner')

    def cli(*args, code=0):
        r = subprocess.run([VENOMX, *args, '--json'], stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout)

    def desk(*args, code=0):
        r = subprocess.run([DESK, *args, '--json'], stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=TIMEOUT * 2)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout)

    d = subprocess.Popen([VENOMX, 'serve', '--json'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    clients = []
    try:
        until(lambda: Path(path).exists() or d.poll() is not None, 'venomx socket')
        assert d.poll() is None, d.communicate()
        cli('session', 'create', '--name', 'work')
        leader = cli('keys', 'list')['leader']
        LEADER = leader_byte(leader)
        p0 = cli('window', 'create', '--session=s0', '--argv=["/bin/sh"]')['pane']
        p1 = cli('pane', 'split', f'--pane={p0}', '--axis=cols', '--argv=["/bin/sh"]', '--tags=[{"key":"role","value":"agent"}]')['pane']

        # Without a terminal the interactive command refuses before any effect.
        err = desk('attach', '--session=s0', code=10)
        assert err['error']['code'] == 'unsupported.terminal', err
        # A missing session is an ordinary error object, not a broken screen.
        master, slave = os.openpty()
        r = subprocess.run([DESK, 'attach', '--session=s9', '--json'], stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=env, timeout=TIMEOUT)
        os.close(slave)
        os.set_blocking(master, False)
        try:
            text = os.read(master, 65536).decode(errors='replace')
        except (BlockingIOError, OSError):
            text = ''
        os.close(master)
        assert r.returncode == 3 and 'not_found.session' in text, (r.returncode, text, r.stderr)
        print('ok attach refuses without a terminal and reports a missing session')

        vx = Client('venomx attach', [VENOMX, 'attach', '--session', 's0'], env)
        clients.append(vx)
        dk = Client('venom-desk attach', [DESK, 'attach', '--session', 's0'], env)
        clients.append(dk)
        # venomx's built-ins: the session's name, then windows.
        dk.shows(' work  │ ▸1')
        vx.shows(' work ')

        # Shared chrome: a product segment and attention on the agent pane.
        cli('status', 'set', '--id=user.e2e', '--text=e2e segment', '--bind=daemon', '--style=ok', '--priority=60')
        cli('pane', 'attention', f'--pane={p1}', '--level=warn', '--reason=look here')
        for c in (vx, dk):
            c.shows('● e2e segment')
            c.shows('▲ 1 attention')
        # venom-desk also marks the pane itself, glyph plus level.
        dk.shows('▲ warn')
        print('ok both clients show the same segment and attention')

        # The rail (leader b) lists the same segments down the left edge.
        dk.type(LEADER + b'b')
        dk.wait_for(lambda s: s.splitlines()[1].startswith('status'), 'the rail heading')
        dk.wait_for(lambda s: any(r.startswith(' ● e2e segment') for r in s.splitlines()[1:]), 'the rail lists the segment')
        dk.type(LEADER + b'b')
        dk.wait_for(lambda s: not s.splitlines()[1].startswith('status'), 'the rail hidden')
        print('ok leader b shows the rail with the status segments, and hides it')

        # A float above the window, drawn by every client.
        cli('pane', 'float', '--window=w0', '--argv=["/bin/sh","-c","echo FLOAT-CONTENT; exec sleep 600"]', '--preset=user.e2e', '--title=e2e float')
        for c in (vx, dk):
            c.shows('FLOAT-CONTENT')
        dk.shows('e2e float')
        if os.environ.get('DESK_SCREEN_DUMP'):
            for c in (vx, dk):
                print(f'--- {c.name}:\n{c.screen()}')
        print('ok both clients show the float and its content')

        # Keys typed into venom-desk reach the focused pane (encoded for it).
        dk.type(b'echo desk-$((40+2))\r')
        for c in (vx, dk):
            c.shows('desk-42')
        print('ok keys typed into venom-desk reach the focused pane')

        # The popup after the leader, then the palette: query, matches.
        dk.type(LEADER)
        dk.shows('detach')
        dk.type(b':')
        dk.shows('> _')
        dk.type(b'pane split')
        dk.shows('venomx pane split')
        dk.type(b'\x1b')
        dk.hides('venomx pane split')
        print('ok the leader popup and the palette (venomx verbs from its schema)')

        # The desk daemon: doctor reads venomx, and its tiling override is
        # what desk actions apply to the session.
        serve = subprocess.Popen([DESK, 'serve'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            until(lambda: (runtime / 'venom' / 'venom-desk.sock').exists() or serve.poll() is not None, 'venom-desk socket')
            report = {c['id']: c for c in desk('doctor')['checks']}
            assert report['keys.leader']['status'] == 'ok' and leader in report['keys.leader']['message'], report['keys.leader']
            assert report['keys.shadowed']['status'] == 'ok', report['keys.shadowed']
            # The float above uses a preset nobody defined: venomx's own check.
            assert report['floats.presets']['status'] == 'warn' and 'user.e2e' in report['floats.presets']['message'], report['floats.presets']
            assert report['desk.nesting']['status'] == 'ok', report['desk.nesting']
            assert desk('tiling', 'set', '--session=s0', '--policy=master-stack')['policy'] == 'master-stack'
            palette = desk('palette', 'list', '--query=pane split')
            assert 'venomx' in palette['reachable'] and palette['entries'][0]['verb'] == 'pane.split', palette['entries'][:3]
            assert palette['entries'][0]['required'] == ['pane', 'axis'] or set(palette['entries'][0]['required']) >= {'pane', 'argv'}, palette['entries'][0]
            print('ok desk daemon: doctor reads venomx, palette lists its verbs')

            # A desk action as a local command, with the caller's venomx identity.
            split = desk('tile', 'split', '--window=w0', f'--pane={p0}', '--argv=["/bin/sh","-c","echo TILED; exec sleep 600"]')
            assert split['split'] in (p0, p1) and split['policy'] == 'master-stack', split
        finally:
            serve.send_signal(signal.SIGTERM)
            serve.wait(timeout=TIMEOUT)
        panes = cli('pane', 'list')['panes']
        new = [p for p in panes if p['pane'] == split['pane']][0]
        tags = new.get('tags', [])
        assert any(t.get('key') == 'workspace' and t.get('value') == 'work' for t in tags), new
        # Floats are a per-client view: each human hides them on their own
        # screen (leader f) to see the tiles below.
        for c in (vx, dk):
            c.type(LEADER + b'f')
            c.hides('FLOAT-CONTENT')
            c.shows('TILED')
        print('ok tile split opens a workspace-tagged pane both clients show')

        # The leader then d detaches, restoring the terminal.
        dk.type(LEADER + b'd')
        code = dk.proc.wait(timeout=TIMEOUT)
        stderr = dk.proc.stderr.read().decode(errors='replace')
        assert code == 0 and '[venom-desk: detached from s0]' in stderr, (code, stderr)
        assert vx.proc.poll() is None
        print('ok leader d detaches venom-desk; venomx attach stays')
    finally:
        for c in clients:
            c.stop()
        d.send_signal(signal.SIGTERM)
        try:
            d.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            d.kill()
