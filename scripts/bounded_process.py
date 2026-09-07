"""Cleanup for subprocesses launched in their own session/process group."""
import os
import signal
import time


def terminate_process_group(process, grace=5):
    """Stop the owned group even when its leader exits before its descendants."""
    def send(sig):
        try:
            os.killpg(process.pid, sig)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            # Darwin can report EPERM rather than ESRCH for an extinct group
            # after its leader has been reaped. Never suppress it for a live leader.
            if process.poll() is not None:
                return False
            if sig == 0:
                return True  # Leader may be exiting but not yet waitable; retry.
            raise

    if send(signal.SIGTERM):
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            process.poll()  # Reap the leader without treating its exit as group exit.
            if not send(0):
                break
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        send(signal.SIGKILL)
    process.wait()
