r"""Run a command with a pseudo-terminal as its stdin, stdout and stderr.

    python3 tests/lib/pty_run.py [--timeout SECONDS] OUT INPUT CMD [ARG...]

tests/che-archive-lines/test-config-validation.sh runs `calibrate` through this:
calibrate refuses to start unless stdin is a terminal (PsychQuant/che-msg#52),
so the tests need one, the way the user's own terminal provides it.

INPUT is what the user types: empty, or lines that each end in a newline. It is
written to the terminal followed by the terminal's end-of-file character, so
the command reads those lines in order and then end of input, as when the user
presses Ctrl-D at the start of a line. Everything the command prints, plus the
terminal's echo of INPUT, goes to the file OUT.

Exits with the command's exit status, 128 + N if signal N ended it, or 124 if
it is still running after SECONDS (default TIMEOUT); its process group is then
killed and OUT says so. Exits 127 if CMD cannot be started, and 2 if called
wrongly. Once the arguments name OUT, it is written on every exit, with the
reason when the command did not run to the end, so a caller cannot read a
previous run's output by mistake.
tests/che-archive-lines/test-pty-run.sh tests these exits.

Why not `script -q /dev/null CMD`: macOS script(1) does give the command a
terminal and passes its exit status through, but when piped stdin ends at once
it can deliver the end-of-file before the lines. On macOS 27.2,
`printf '\n250\n' | script -q /dev/null bash -c 'read -r a'` made that read see
end of input, and the two lines arrived afterwards; with a pause before the
pipe closed, the order was right. Writing the input and the end-of-file here,
in that order, does not depend on timing.
"""

import math
import os
import select
import signal
import subprocess
import sys
import termios
import time

TIMEOUT = 20.0
USAGE = "usage: pty_run.py [--timeout SECONDS] OUT INPUT CMD [ARG...]\n"


def read_until_closed(master: int, deadline: float) -> tuple[bytes, bool]:
    """Read what the terminal shows until no process has it open.

    Returns the output and True, or what was read so far and False if the
    deadline passed first. It has to read while the command runs: a terminal
    holds little output, and a command whose output nobody reads stops at its
    next write.
    """
    output = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return bytes(output), False
        ready, _, _ = select.select([master], [], [], remaining)
        if not ready:
            continue
        try:
            chunk = os.read(master, 4096)
        except OSError:  # EIO: every process that had the terminal open has closed it
            return bytes(output), True
        if not chunk:
            return bytes(output), True
        output += chunk


def kill_group(proc: subprocess.Popen) -> None:
    """SIGKILL the command's process group; it leads its own (start_new_session)."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass  # the group is already gone, or holds only an unreaped exited leader


def run(cmd: list[str], typed: str, timeout: float) -> tuple[bytes, int]:
    """Run cmd on a new terminal; return what it showed and the exit code to report."""
    master, slave = os.openpty()
    veof = termios.tcgetattr(slave)[6][termios.VEOF]
    try:
        proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                                start_new_session=True)
    except OSError as e:
        os.close(master)
        return f"[pty_run.py: cannot run {cmd[0]}: {e}]\n".encode(), 127
    finally:
        os.close(slave)

    deadline = time.monotonic() + timeout
    output = b""
    status = None  # set once the command has exited within the deadline
    short_write = False
    try:
        data = typed.encode() + veof
        short_write = os.write(master, data) != len(data)
        if not short_write:
            output, closed = read_until_closed(master, deadline)
            # A command can close its copies of the terminal and keep running,
            # so the end of the output is not the end of the command.
            if closed:
                try:
                    status = proc.wait(timeout=max(0.0, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    pass
    finally:
        # Kill and reap before closing the terminal. Closing it first hangs up
        # the command, which can then be gone by the time of the kill.
        if status is None:
            kill_group(proc)
            proc.wait()
        os.close(master)

    if short_write:
        return output + b"\n[pty_run.py: could not write INPUT to the terminal]\n", 2
    if status is None:
        return output + b"\n[pty_run.py: still running after %g s, killed]\n" % timeout, 124
    return output, (128 - status if status < 0 else status)


def refuse(out_path: str, problem: str) -> int:
    message = f"pty_run.py: {problem}\n"
    sys.stderr.write(message)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(message)
    return 2


def main(argv: list[str]) -> int:
    args = argv[1:]
    timeout_arg = None
    if args[:1] == ["--timeout"]:
        timeout_arg, args = (args[1] if len(args) > 1 else None), args[2:]
    if len(args) < 3:
        sys.stderr.write(USAGE)
        return 2
    out_path, typed, cmd = args[0], args[1], args[2:]

    timeout = TIMEOUT
    if timeout_arg is not None:
        try:
            timeout = float(timeout_arg)
        except ValueError:
            timeout = math.nan
        if not math.isfinite(timeout) or timeout <= 0:
            return refuse(out_path, f"--timeout must be a positive number of seconds, not {timeout_arg!r}")
    # An end-of-file in the middle of a line only hands over that partial line,
    # and the command would then wait for input that never comes.
    if typed and not typed.endswith("\n"):
        return refuse(out_path, "INPUT must be empty or end with a newline")

    output, code = run(cmd, typed, timeout)
    with open(out_path, "wb") as f:
        f.write(output)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
