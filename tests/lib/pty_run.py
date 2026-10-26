r"""Run a command with a pseudo-terminal as its stdin, stdout and stderr.

    python3 tests/lib/pty_run.py OUT INPUT CMD [ARG...]

tests/che-archive-lines/test-config-validation.sh runs `calibrate` through this:
calibrate refuses to start unless stdin is a terminal (PsychQuant/che-msg#52),
so the tests need one, the way the user's own terminal provides it.

INPUT is what the user types: empty, or lines that each end in a newline. It is
written to the terminal followed by the terminal's end-of-file character, so
the command reads those lines in order and then end of input, as when the user
presses Ctrl-D at the start of a line. Everything the command prints, plus the
terminal's echo of INPUT, goes to the file OUT.

Exits with the command's exit status, 128 + N if signal N ended it, or 124 if
it is still running after TIMEOUT seconds (it is then killed and OUT says so).
Exits 2 if called wrongly.

Why not `script -q /dev/null CMD`: macOS script(1) does give the command a
terminal and passes its exit status through, but when piped stdin ends at once
it can deliver the end-of-file before the lines. On macOS 27.2,
`printf '\n250\n' | script -q /dev/null bash -c 'read -r a'` made that read see
end of input, and the two lines arrived afterwards; with a pause before the
pipe closed, the order was right. Writing the input and the end-of-file here,
in that order, does not depend on timing.
"""

import os
import select
import signal
import subprocess
import sys
import termios
import time

TIMEOUT = 20


def main(argv):
    if len(argv) < 4:
        sys.stderr.write("usage: pty_run.py OUT INPUT CMD [ARG...]\n")
        return 2
    out_path, typed, cmd = argv[1], argv[2], argv[3:]
    # An end-of-file in the middle of a line only hands over that partial line,
    # and the command would then wait for input that never comes.
    if typed and not typed.endswith("\n"):
        sys.stderr.write("pty_run.py: INPUT must be empty or end with a newline\n")
        return 2

    master, slave = os.openpty()
    veof = termios.tcgetattr(slave)[6][termios.VEOF]
    proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                            start_new_session=True)
    os.close(slave)
    data = typed.encode() + veof
    if os.write(master, data) != len(data):
        sys.stderr.write("pty_run.py: could not write INPUT to the terminal\n")
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        return 2

    # Read while the command runs: a terminal holds little output, and a
    # command whose output nobody reads stops at its next write.
    output = bytearray()
    deadline = time.monotonic() + TIMEOUT
    timed_out = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            break
        ready, _, _ = select.select([master], [], [], remaining)
        if not ready:
            continue
        try:
            chunk = os.read(master, 4096)
        except OSError:  # EIO: every process that had the terminal open has closed it
            break
        if not chunk:
            break
        output += chunk
    os.close(master)

    if timed_out:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        output += b"\n[pty_run.py: still running after %d s, killed]\n" % TIMEOUT
        rc = 124
    else:
        rc = proc.wait()
        if rc < 0:
            rc = 128 - rc
    with open(out_path, "wb") as f:
        f.write(output)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
