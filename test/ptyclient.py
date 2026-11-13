"""A presentation client on a real PTY, read back as a screen (shared by
test/attach.py and test/live.py).

The client's host-terminal output is replayed into a fresh venom-term Vt by
the screen helper (test/screen.zig), so assertions read what a user sees.
"""
import fcntl
import os
import signal
import struct
import subprocess
import sys
import termios
import time

TIMEOUT = 10


def leader_byte(chord):
    """What legacy input sends for venomx's leader, from `keys list`."""
    return {'ctrl+space': b'\x00', 'ctrl+a': b'\x01', 'ctrl+b': b'\x02'}[chord]


def until(fn, what, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(f'{what} did not become true')


class Client:
    """One presentation client whose stdin/stdout are a PTY of cols x rows."""

    def __init__(self, name, argv, env, screen, cols, rows):
        self.name = name
        self.screen_exe = screen
        self.cols, self.rows = cols, rows
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        self.proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=env, start_new_session=True)
        os.close(slave)
        os.set_blocking(master, False)
        self.master = master
        self.out = bytearray()

    def pump(self):
        while True:
            try:
                chunk = os.read(self.master, 65536)
            except (BlockingIOError, OSError):
                return
            if not chunk:
                return
            self.out += chunk

    def screen(self):
        self.pump()
        r = subprocess.run([self.screen_exe, str(self.cols), str(self.rows)], input=bytes(self.out), capture_output=True, timeout=TIMEOUT)
        assert r.returncode == 0, r.stderr
        return r.stdout.decode(errors='replace')

    def dump(self):
        print(f'--- {self.name} screen:\n{self.screen()}', file=sys.stderr)
        if self.proc.poll() is not None:
            print(f'--- {self.name} exited {self.proc.returncode}: {self.proc.stderr.read().decode(errors="replace")}', file=sys.stderr)

    def shows(self, text):
        try:
            return until(lambda: text in self.screen(), f'{self.name} showing {text!r}')
        except AssertionError:
            self.dump()
            raise

    def hides(self, text):
        try:
            return until(lambda: text not in self.screen(), f'{self.name} hiding {text!r}')
        except AssertionError:
            self.dump()
            raise

    def wait_for(self, fn, what):
        try:
            return until(lambda: fn(self.screen()), f'{self.name}: {what}')
        except AssertionError:
            self.dump()
            raise

    def type(self, data):
        os.write(self.master, data)

    def stop(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait(timeout=TIMEOUT)
