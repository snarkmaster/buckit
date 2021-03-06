#!/usr/bin/env python3
'Utilities to make Python systems programming more palatable.'
import array
import logging
import os
import random
import socket
import subprocess
import tempfile

from typing import AnyStr, Iterable, Iterator, List, Tuple, TypeVar
from contextlib import AbstractContextManager, contextmanager

T = TypeVar('T')


# Bite me, Python3.
def byteme(s: AnyStr) -> bytes:
    'Byte literals are tiring, just promote strings as needed.'
    return s.encode() if isinstance(s, str) else s


def get_file_logger(py_path: AnyStr):
    return logging.getLogger(os.path.basename(py_path))


def init_logging(*, debug: bool=False):
    logging.basicConfig(
        format='%(levelname)s %(name)s %(asctime)s %(message)s',
        level=logging.DEBUG if debug else logging.INFO,
    )


# contextlib.nullcontext is 3.7+ but we are on 3.6 for now. This has to be a
# class since it should be multi-use.
class nullcontext(AbstractContextManager):

    def __init__(self, val=None):
        self._val = val

    def __enter__(self):
        return self._val

    def __exit__(self, exc_type, exc_val, exc_tb):
        return None  # Do not suppress exceptions


def check_popen_returncode(proc: subprocess.Popen):
    if proc.returncode != 0:  # pragma: no cover
        # Providing a meaningful coverage test for this is annoying, so I just
        # tested manually:
        #   >>> import subprocess
        #   >>> raise subprocess.CalledProcessError(returncode=5, cmd=['a'])
        #   Traceback (most recent call last):
        #     File "<stdin>", line 1, in <module>
        #   subprocess.CalledProcessError: Command '['a']' returned non-zero
        #   exit status 5.
        raise subprocess.CalledProcessError(
            returncode=proc.returncode, cmd=proc.args,
        )


def set_new_key(d, k, v):
    '`d[k] = v` that raises if it would it would overwrite an existing value'
    if k in d:
        raise KeyError(f'{k} was already set')
    d[k] = v


def shuffled(it: Iterable[T]) -> List[T]:
    l = list(it)
    random.shuffle(l)
    return l


@contextmanager
def listen_temporary_unix_socket() -> Iterator[Tuple[str, socket.socket]]:
    # Hardcoding /tmp is ugly, but Buck sets $TMP to fairly long paths,
    # which can cause `AF_UNIX path too long`.
    with tempfile.TemporaryDirectory(dir='/tmp') as td, \
            socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as lsock:
        sock_path = os.path.join(td, 'sock')
        lsock.bind(sock_path)
        lsock.listen()
        yield sock_path, lsock


def recv_fds(sock, msglen, maxfds, inheritable=False):
    '''
    Receives via a Unix domain socket a message of at most `msglen` bytes,
    with at most `maxfds` file descriptors in the ancillary data.  The file
    descriptors will be marked O_CLOEXEC unless inheritable is set to False.
    '''
    fds = array.array('i')
    msg, ancdata, msg_flags, _addr = sock.recvmsg(
        msglen, maxfds * socket.CMSG_SPACE(fds.itemsize),
        0 if inheritable else socket.MSG_CMSG_CLOEXEC,
    )
    assert not (msg_flags & socket.MSG_TRUNC), msg_flags
    assert not (msg_flags & socket.MSG_CTRUNC), msg_flags
    assert not (msg_flags & socket.MSG_ERRQUEUE), msg_flags
    for cmsg_level, cmsg_type, cmsg_data in ancdata:
        assert cmsg_level == socket.SOL_SOCKET, cmsg_level
        assert cmsg_type == socket.SCM_RIGHTS, cmsg_type
        assert len(cmsg_data) % fds.itemsize == 0, cmsg_data
        fds.frombytes(cmsg_data)
    return msg, list(fds)


# Don't wait forever if the `send_fds` side crashes.  This is 2.5 minutes so
# we still make progress on overloaded hosts.
FD_UNIX_SOCK_TIMEOUT = 150


def recv_fds_from_unix_sock(sock_path, max_fds):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn_sock:
        # Don't wait forever if the `send_fds` side crashes.  This is 3
        # minutes so we still make progress on overloaded hosts.
        conn_sock.settimeout(FD_UNIX_SOCK_TIMEOUT)
        conn_sock.connect(sock_path)
        ignored_msg_len = 128
        _msg, fds = recv_fds(conn_sock, ignored_msg_len, max_fds)
        return fds


def run_stdout_to_err(
    args: Iterable[AnyStr], *, stdout: None=None, **kwargs
) -> subprocess.CompletedProcess:
    '''
    Use this instead of `subprocess.{run,call,check_call}()` to prevent
    subprocesses from accidentally polluting stdout.
    '''
    assert stdout is None, 'run_stdout_to_err does not take a stdout kwarg'
    return subprocess.run(args, **kwargs, stdout=2)  # Redirect to stderr


@contextmanager
def pipe():
    r_fd, w_fd = os.pipe2(os.O_CLOEXEC)
    with os.fdopen(r_fd, 'rb') as r, os.fdopen(w_fd, 'wb') as w:
        yield r, w


@contextmanager
def open_fd(path: AnyStr, flags) -> int:
    # If you ever need **NOT** to set one of these very sane defaults, add a
    # clearly named keyword-only arg.
    fd = os.open(path, flags=flags | os.O_NOCTTY | os.O_CLOEXEC)
    try:
        yield fd
    finally:
        os.close(fd)
