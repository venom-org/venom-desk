#!/usr/bin/env python3
"""Live case: venom-desk next to a real `venomx attach` on one session.

A real daemon, a real `venomx attach` on a PTY, and venom-desk's headless
core (the desk-probe test binary) on the same session. Both clients must show
the same segments and attention; venom-desk keeps its own view and clears
attention only for the pane its user focused; its palette lists venomx verbs
(from the real binary) and venom verbs (from a stand-in `venom` MCP adapter,
since venom has no binary yet).

It also runs `venom-desk attach` and
`venomx attach` side by side on real PTYs: both load the same registered key
tables, a tag-scoped table is active only on a matching pane, popups open only
on the ticket's client, and a preset change through `config set` resizes the
float on both screens.

Usage: live.py <desk-probe> <venomx> <venom-desk> <screen>. Skips (exit 0)
when <venomx> is missing.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

import ptyclient

PROBE = str(Path(sys.argv[1]).resolve())
VENOMX = Path(sys.argv[2])
if not VENOMX.is_absolute():
    VENOMX = (Path(__file__).resolve().parent.parent / VENOMX)
if not VENOMX.exists():
    print(f'skip: no venomx binary at {VENOMX} (build venomx, or pass -Dvenomx=PATH)')
    sys.exit(0)
VENOMX = str(VENOMX.resolve())
DESK = str(Path(sys.argv[3]).resolve())
SCREEN = str(Path(sys.argv[4]).resolve())
TIMEOUT = 10
COLS, ROWS = 100, 30
ANSI = re.compile(rb'\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b[()][0-9A-B]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[=>78DEHMc]')


def until(fn, what):
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(f'{what} did not become true')


VENOM_STUB = r'''#!/usr/bin/env python3
import json, sys
tools = [
    {"name": "approve", "description": "Approve the pending request of an agent pane",
     "inputSchema": {"type": "object", "properties": {"pane": {"type": "string"}}, "required": ["pane"]}},
    {"name": "thread_dpick", "description": "Pick a thread in a popup",
     "inputSchema": {"type": "object", "properties": {"ticket": {"type": "string"}}, "required": ["ticket"]}},
]
assert sys.argv[1:] == ["mcp"], sys.argv
for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg:
        continue
    if msg["method"] == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": "venom", "version": "0.0.0"}}
    else:
        result = {"tools": tools}
    print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}), flush=True)
'''


with tempfile.TemporaryDirectory(prefix='desk-live-') as root:
    root = Path(root)
    path = str(root / 'd.sock')
    env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN')}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_STATE_HOME=str(root / 'state'),
               PS1='$ ', ENV='', TERM='xterm-256color', SHELL='/bin/sh')
    env.pop('VENOMX_PANE', None)
    owner = dict(env, VENOMX_TOKEN='@owner')
    venom = root / 'venom'
    venom.write_text(VENOM_STUB)
    venom.chmod(0o755)

    def cli(*args, code=0):
        r = subprocess.run([VENOMX, *args, '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=owner,
                           capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout)

    def probe(*args, cols=COLS, timeout=TIMEOUT * 2):
        r = subprocess.run([PROBE, '--session', 's0', '--socket', path, '--cols', str(cols), '--rows', str(ROWS), *args],
                           stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=timeout)
        assert r.returncode == 0, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout)

    d = subprocess.Popen([VENOMX, 'serve', '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    attach = None
    clients = []
    try:
        until(lambda: Path(path).exists() or d.poll() is not None, 'daemon socket')
        assert d.poll() is None, d.communicate()
        cli('session', 'create', '--name', 'work')
        p0 = cli('window', 'create', '--session=s0', '--argv=["/bin/sh"]')['pane']
        p1 = cli('pane', 'split', f'--pane={p0}', '--axis=cols', '--argv=["/bin/sh"]', '--tags=[{"key":"role","value":"agent"}]')['pane']

        # The human's `venomx attach`, on a PTY.
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
        attach = subprocess.Popen([VENOMX, 'attach', '--session', 's0', '--socket', path], stdin=slave, stdout=slave,
                                  stderr=subprocess.PIPE, env=env, start_new_session=True)
        os.close(slave)
        os.set_blocking(master, False)
        out = bytearray()

        def screen_text():
            while True:
                try:
                    chunk = os.read(master, 65536)
                except (BlockingIOError, OSError):
                    break
                if not chunk:
                    break
                out.extend(chunk)
            return ANSI.sub(b'', bytes(out)).decode(errors='replace')

        def attach_shows(text):
            until(lambda: text in screen_text(), f'venomx attach showing {text!r}')

        # A product's segment (daemon-bound, so it outlives the CLI call) and
        # attention on the agent pane.
        cli('status', 'set', '--id=user.e2e', '--text=e2e segment', '--bind=daemon', '--style=ok', '--priority=60')
        cli('pane', 'attention', f'--pane={p1}', '--level=warn', '--reason=look here')
        attach_shows('● e2e segment')
        attach_shows('▲ 1 attention')

        seen = probe('--product', VENOMX, '--product', str(venom))
        line = seen['status_line']
        assert seen['status_row'] == 0, seen
        # venomx's built-ins: the session's name, then windows.
        assert line.startswith(' work  │ ▸1 │ '), line
        assert '● e2e segment' in line and '▲ 1 attention' in line, line
        assert {'pane': p1, 'level': 'warn'} in seen['attention'], seen['attention']
        # Same segment content as the daemon holds, glyph-prefixed by style.
        listed = {s['id']: s['text'] for s in cli('status', 'list')['segments']}
        shown = {s['id']: s['text'] for s in seen['segments'] if not s['id'].startswith('venomx.')}
        assert shown == {k: '● ' + v for k, v in listed.items()}, (shown, listed)
        # Its own view: lowest window, first pane; nothing was sent to move it.
        assert seen['window'] == 'w0' and seen['focus'] == p0, seen
        # venomx serves keys.list: product tables are loaded.
        assert seen['product_keys'] is True, seen
        assert seen['floats'] == [], seen
        verbs = {(e['tool'], e['verb']) for e in seen['palette']}
        assert ('venomx', 'pane.split') in verbs and ('venomx', 'status.set') in verbs, sorted(verbs)[:20]
        assert ('venom', 'approve') in verbs and ('venom', 'thread.pick') in verbs, verbs
        assert ('venom-desk', 'focus-attention') in verbs
        assert set(seen['reachable']) == {'venomx', 'venom'}, seen['reachable']
        print('ok same segments and attention as venomx attach; palette lists venomx and venom verbs')

        # One `status` config drives both clients. A centred static
        # segment with a click, templates for a built-in and a user segment,
        # and a tray of two pushed members (one with a click).
        # venomx attach read back as a screen, so text with spaces is whole.
        vxs = ptyclient.Client('venomx attach', [VENOMX, 'attach', '--session', 's0', '--socket', path], env, SCREEN, COLS, ROWS)
        clients.append(vxs)
        clicked = json.dumps({'id': 'user.clicked', 'text': 'clicked', 'bind': 'daemon'})
        cli('config', 'set', '--key', 'status.center', '--value', '.{ "user.host" }')
        cli('config', 'set', '--key', 'status.segments', '--value',
            '.{ .{ .id = "user.host", .text = "devbox", .click = .{ .verb = "status.set", .args = ' + json.dumps(clicked) + ' } },'
            ' .{ .id = "venomx.pane", .format = "focus:{pane.id}" },'
            ' .{ .id = "user.where", .format = "at {session.name}", .side = .left } }')
        cli('status', 'set', '--id=user.bat', '--text=81%', '--icon=B', '--group=tray', '--bind=daemon', '--priority=50',
            '--click=' + json.dumps({'verb': 'status.set', 'args': json.dumps({'id': 'user.batclick', 'text': 'bat', 'bind': 'daemon'})}))
        cli('status', 'set', '--id=user.net', '--text=wifi', '--icon=N', '--group=tray', '--bind=daemon', '--priority=40')
        wants = ['devbox', 'at work', 'B N', f'focus:{p0}', '● e2e segment']
        for want in wants:
            vxs.shows(want)
        seen = probe()
        for want in wants:
            assert want in seen['status_line'], (want, seen['status_line'])
        ids = {s['id'] for s in seen['segments']}
        assert {'user.host', 'user.where', 'venomx.tray', 'venomx.pane'} <= ids and not {'user.bat', 'user.net'} & ids, ids
        # The centre segment sits in the middle on both clients.
        mid = seen['status_line'].index('devbox')
        assert abs(mid - (COLS - len('devbox')) // 2) <= 1, seen['status_line']
        # The rail lists the same segments, the tray as a list.
        railed = probe('--action', 'toggle-rail')['rail']
        for want in (' work', ' at work', ' devbox', ' tray', '  B 81%', '  N wifi', ' ● e2e segment', f' focus:{p0}'):
            assert want in railed, (want, railed)
        print('ok status: venom-desk shows the same templates, centre and tray as venomx attach, the tray as a list in its rail')

        # clicks run the target as the clicking client: venomx
        # attach first (an SGR mouse press on the screen), then venom-desk
        # on its status line, then a tray member in venom-desk's rail.
        def segments():
            return {s['id'] for s in cli('status', 'list')['segments']}
        col = vxs.screen().splitlines()[0].index('devbox') + 1
        vxs.type(f'\x1b[<0;{col + 1};1M\x1b[<0;{col + 1};1m'.encode())
        until(lambda: 'user.clicked' in segments(), 'venomx attach click ran status.set')
        cli('status', 'clear', '--id=user.clicked')
        at = next(p for p in seen['placed'] if p['id'] == 'user.host')
        probe('--click', f"{at['x'] + 1},0")
        until(lambda: 'user.clicked' in segments(), 'venom-desk click ran status.set')
        row = 1 + railed.index('  B 81%')
        probe('--action', 'toggle-rail', '--click', f'3,{row}')
        until(lambda: 'user.batclick' in segments(), 'venom-desk rail click on a tray member')
        # A click on a segment without a target does nothing (and is not a pane's).
        clock = next(p for p in seen['placed'] if p['id'] == 'venomx.clock')
        before = segments()
        probe('--click', f"{clock['x']},0")
        assert segments() == before
        for sid in ('user.clicked', 'user.batclick'):
            cli('status', 'clear', f'--id={sid}')
        vxs.stop()
        clients.remove(vxs)
        print('ok clicks on the line and on a rail tray member run the target as the clicking client, as in venomx attach')

        # A narrow venom-desk truncates by priority on its own.
        narrow = probe(cols=40)['status_line']
        assert narrow.startswith(' work ') and '--:--' not in narrow, narrow
        print('ok narrow client drops low priorities')

        # venom-desk's user focuses the attention pane; the clear
        # is sent under venom-desk's identity and reaches venomx attach too.
        after = probe('--action', 'focus-attention')
        assert after['focus'] == p1 and after['message'] == '', after
        until(lambda: not any(p['pane'] == p1 for p in probe()['attention']), 'attention cleared in the daemon')
        print('ok focusing in venom-desk clears attention for every client')

        # A tiling split through venom-desk is an ordinary pane.split with the
        # workspace tag; venomx attach shows the same topology.
        probe('--action', 'tile-split')
        panes = cli('pane', 'list')['panes']
        tagged = [p for p in panes if any(t.get('key') == 'workspace' for t in p.get('tags', [])) or (isinstance(p.get('tags'), dict) and 'workspace' in p['tags'])]
        assert len(panes) == 3 and len(tagged) == 1, panes
        print('ok tile-split creates a workspace-tagged pane via pane.split')

        # ------------------------------------------------ key tables, popups, floats
        # Both presentation clients on real PTYs, read back as screens.
        vx = ptyclient.Client('venomx attach', [VENOMX, 'attach', '--session', 's0', '--socket', path], env, SCREEN, COLS, ROWS)
        clients.append(vx)
        dk = ptyclient.Client('venom-desk attach', [DESK, 'attach', '--session', 's0'], dict(env, VENOMX_SOCKET=path), SCREEN, COLS, ROWS)
        clients.append(dk)
        for c in (vx, dk):
            c.shows('e2e segment')

        # A product-layer table (the owner's namespace is `user`) scoped to
        # agent panes: an exec binding and the client's own pane.popup.
        ran = root / 'exec-ran'
        popup_argv = ['/bin/sh', '-c', 'echo POPUP-CONTENT; exec sleep 600']
        bindings = [
            {'key': 't', 'exec': ['/bin/sh', '-c', f'echo ran > {ran}']},
            {'key': 'p', 'verb': 'pane.popup', 'args': json.dumps({'argv': popup_argv, 'preset': 'user.pop', 'title': 'e2e popup'})},
        ]
        cli('keys', 'register', '--name=user', '--prefix=u', '--when=[{"key":"role","value":"agent"}]',
            '--bindings=' + json.dumps(bindings), '--bind=daemon')
        listed = cli('keys', 'list')
        seen = probe()
        want = {(t['name'], t['layer']) for t in listed['tables'] if t['layer'] != 'builtin'}
        got = {(t['name'], t['layer']) for t in seen['tables'] if t['layer'] != 'builtin'}
        assert ('user', 'product') in want and got == want, (got, want)
        assert seen['leader'] == listed['leader'], (seen['leader'], listed['leader'])
        LEADER = ptyclient.leader_byte(listed['leader'])
        print('ok venom-desk loads the same registered key tables and leader as keys.list')

        # The table is offered only while an agent pane is focused.
        off = probe('--keys', listed['leader'])['popup_rows']
        on = probe('--focus', p1, '--keys', listed['leader'])['popup_rows']
        user_row = {'keys': 'u', 'more': True, 'label': 'user'}
        assert user_row not in off and any(h['keys'] == 'd' for h in off), off
        assert user_row in on, on
        # The same on the real screens: venom-desk starts on p0 (no table),
        # then focuses p1 (leader tab) where `leader u` opens it.
        dk.type(LEADER)
        dk.shows('focus-next')
        assert '+ user' not in dk.screen(), dk.screen()
        dk.type(b'\x1b')
        dk.hides('focus-next')
        # leader tab until the agent pane has this client's focus (the
        # `venomx.pane` template above shows it on the status line).
        for _ in range(4):
            if f'focus:{p1}' in dk.screen().splitlines()[0]:
                break
            dk.type(LEADER + b'\t')
            time.sleep(.3)
        dk.wait_for(lambda s: f'focus:{p1}' in s.splitlines()[0], f'focus on {p1}')
        dk.type(LEADER)
        dk.shows('+ user')
        dk.type(b'u')
        dk.shows('t  /bin/sh')
        dk.type(b't')
        until(lambda: ran.exists(), 'the exec binding of the tag-scoped table')
        # venomx attach on p0 offers no `user` table after the leader; on p1
        # it does, in which-key (the status line or a popup, after its delay).
        vx.type(LEADER)
        vx.wait_for(lambda s: 'LEADER' in s.splitlines()[0], 'leader mode')
        time.sleep(.4)
        assert 'user' not in vx.screen(), vx.screen()
        vx.type(b'\x1b')
        vx.wait_for(lambda s: 'LEADER' not in s.splitlines()[0], 'leader mode over')
        for _ in range(4):
            if f'focus:{p1}' in vx.screen().splitlines()[0]:
                break
            vx.type(LEADER + b'\t')
            time.sleep(.3)
        vx.wait_for(lambda s: f'focus:{p1}' in s.splitlines()[0], f'focus on {p1}')
        vx.type(LEADER)
        vx.wait_for(lambda s: 'user' in s, 'the user table in which-key')
        vx.type(b'\x1b')
        vx.wait_for(lambda s: 'LEADER' not in s.splitlines()[0], 'leader mode over')
        print('ok a tag-scoped table is active only on a matching pane, on both clients')

        # One table, one popup. Only the header's client name differs, and
        # the width it asks for.
        def popup_rows(c, name):
            lines = c.screen().splitlines()
            top = next((i for i, s in enumerate(lines) if f'╭ {name} › user' in s), None)
            if top is None:
                return None
            bottom = next(i for i in range(top, len(lines)) if lines[i].startswith('╰'))
            # The box's width follows the header; the pane behind shows beside it.
            return [s.split('│')[1].strip() for s in lines[top + 1:bottom]]

        for c in (vx, dk):
            c.type(LEADER + b'u')
        got = until(lambda: popup_rows(vx, 'venomx'), 'venomx attach popup')
        want = until(lambda: popup_rows(dk, 'venom-desk'), 'venom-desk attach popup')
        assert got == want and any('/bin/sh' in s for s in got), (got, want)
        for c in (vx, dk):
            c.type(b'\x1b')
            c.wait_for(lambda s: 'LEADER' not in s.splitlines()[0], 'leader mode over')
        print('ok venom-desk and venomx attach draw the same popup for the same table')

        # A changed `keys.leader` applies on both clients, in the keys and the
        # popup, with no restart.
        cli('config', 'set', '--key', 'keys.leader', '--value', '"ctrl+b"')
        until(lambda: cli('keys', 'list')['leader'] == 'ctrl+b', 'the new leader in keys.list')
        NEW = ptyclient.leader_byte('ctrl+b')
        for c in (vx, dk):
            c.type(NEW)
            c.wait_for(lambda s: 'send-leader' in s and 'ctrl+b' in s, 'the new leader in the popup')
            c.type(b'\x1b')
            c.wait_for(lambda s: 'LEADER' not in s.splitlines()[0], 'leader mode over')
        cli('config', 'set', '--key', 'keys.leader', '--value', json.dumps(listed['leader']))
        until(lambda: cli('keys', 'list')['leader'] == listed['leader'], 'the old leader in keys.list')
        print('ok a changed keys.leader applies on both clients')

        # No ticket, a ticket of a client that has gone, another
        # client's ticket and an expired one all fail; a valid one opens the
        # popup on its client only.
        r = cli('pane', 'popup', '--argv=["true"]', code=4)
        assert r['error']['code'] == 'denied.popup_ticket' and r['error']['data']['reason'] == 'missing', r
        gone = cli('popup', 'ticket', '--session=s0')['ticket']
        r = cli('pane', 'popup', f'--ticket={gone}', '--argv=["true"]', code=3)
        assert r['error']['code'] == 'not_found.client', r
        cases = probe('--popup-cases', json.dumps(['/bin/sh', '-c', 'echo PROBE-POPUP; exec sleep 600']), timeout=TIMEOUT * 4)['popup_cases']
        assert cases == {'other_client': 'denied.popup_ticket', 'valid': 'ok', 'shown_here': 1, 'shown_there': 0,
                         'focus_is_popup': True, 'expired': 'denied.popup_ticket'}, cases
        # venom-desk's own `leader u p` binding mints a ticket and opens the
        # popup on venom-desk only, focused there.
        dk.type(LEADER + b'up')
        dk.shows('POPUP-CONTENT')
        dk.shows('e2e popup')
        popups = until(lambda: [p for p in cli('pane', 'list')['panes'] if p.get('layer') == 'popup' and not p['exited']], 'the popup pane')
        assert len(popups) == 1, popups
        time.sleep(.5)
        for text in ('POPUP-CONTENT', 'PROBE-POPUP'):
            assert text not in vx.screen(), (text, vx.screen())
        assert 'PROBE-POPUP' not in dk.screen(), dk.screen()
        # Keys reach the popup, which has the focus.
        dk.type(b'\x03')
        dk.type(LEADER + b'x')
        dk.hides('POPUP-CONTENT')
        until(lambda: not any(p.get('layer') == 'popup' for p in cli('pane', 'list')['panes']), 'popups removed')
        print('ok popups need a ticket of this client and open on it only; leader x dismisses')

        # A float with a preset nobody defined (floats.default,
        # 60%), then `config set` of the preset and a reload: venomx
        # re-resolves it and both screens redraw it at 30%.
        cli('pane', 'float', '--window=w0', '--argv=["/bin/sh","-c","echo FLOAT-NINE; exec sleep 600"]', '--preset=user.e2e', '--title=e2e float')

        def box_width(screen):
            for row in screen.splitlines():
                if 'e2e float' in row and '╭' in row and '╮' in row:
                    return row.rindex('╮') - row.index('╭') + 1
            return None
        for c in (vx, dk):
            c.shows('FLOAT-NINE')
            c.wait_for(lambda s: box_width(s) == 60, 'a 60-column float')
        assert [f['width'] for f in probe()['floats']] == [60]
        cli('config', 'set', '--key=floats.presets."user.e2e".width', '--value="30%"')
        cli('config', 'reload')
        for c in (vx, dk):
            c.wait_for(lambda s: box_width(s) == 30, 'the float resized to 30 columns')
        assert [f['width'] for f in probe()['floats']] == [30]
        print('ok a preset change through config set resizes the float on both clients')
    finally:
        for c in clients:
            c.stop()
        if attach is not None and attach.poll() is None:
            os.killpg(attach.pid, signal.SIGTERM)
            attach.wait(timeout=TIMEOUT)
        d.send_signal(signal.SIGTERM)
        try:
            d.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            d.kill()
