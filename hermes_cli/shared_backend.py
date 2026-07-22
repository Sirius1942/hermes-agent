"""Process-local Chat backend published by the messaging gateway.

The messaging gateway already owns the long-lived platform adapters and their
per-conversation agents.  This module lets that same process expose the
existing dashboard ``/api/ws`` JSON-RPC surface on an ephemeral loopback port
so native clients can attach without starting a second ``hermes serve``
process.

Discovery is profile-scoped under ``HERMES_HOME``.  The descriptor contains an
ephemeral session token, so it is written atomically with owner-only
permissions and is removed only by the instance that published it.
"""

from __future__ import annotations

import asyncio
import importlib
import json
import logging
import os
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Optional

from gateway.status import get_process_start_time
from hermes_constants import get_hermes_home
from utils import atomic_json_write


logger = logging.getLogger(__name__)

_SCHEMA_VERSION = 1
_RUNTIME_DIRECTORY = "runtime"
_DESCRIPTOR_FILENAME = "shared-backend.json"
_LOOPBACK_HOST = "127.0.0.1"


@dataclass(frozen=True)
class SharedBackendDescriptor:
    schema_version: int
    owner: str
    pid: int
    process_start_time: Optional[int]
    server_url: str
    session_token: str
    hermes_home: str
    instance_id: str
    started_at: float

    @classmethod
    def from_mapping(cls, payload: dict[str, Any]) -> "SharedBackendDescriptor":
        return cls(
            schema_version=int(payload["schema_version"]),
            owner=str(payload["owner"]),
            pid=int(payload["pid"]),
            process_start_time=(
                int(payload["process_start_time"])
                if payload.get("process_start_time") is not None
                else None
            ),
            server_url=str(payload["server_url"]),
            session_token=str(payload["session_token"]),
            hermes_home=str(payload["hermes_home"]),
            instance_id=str(payload["instance_id"]),
            started_at=float(payload["started_at"]),
        )


def shared_backend_descriptor_path(
    hermes_home: Optional[Path] = None,
) -> Path:
    home = Path(hermes_home) if hermes_home is not None else get_hermes_home()
    return home / _RUNTIME_DIRECTORY / _DESCRIPTOR_FILENAME


def read_shared_backend_descriptor(
    hermes_home: Optional[Path] = None,
) -> Optional[SharedBackendDescriptor]:
    """Read a structurally valid descriptor without exposing its token."""

    path = shared_backend_descriptor_path(hermes_home)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            return None
        descriptor = SharedBackendDescriptor.from_mapping(payload)
    except (
        FileNotFoundError,
        OSError,
        UnicodeDecodeError,
        ValueError,
        KeyError,
        TypeError,
    ):
        return None

    if descriptor.schema_version != _SCHEMA_VERSION:
        return None
    if descriptor.owner != "gateway":
        return None
    if descriptor.pid <= 0 or not descriptor.instance_id:
        return None
    if not descriptor.session_token:
        return None
    if not descriptor.server_url.startswith(f"http://{_LOOPBACK_HOST}:"):
        return None
    return descriptor


def publish_shared_backend_descriptor(
    *,
    port: int,
    session_token: str,
    hermes_home: Optional[Path] = None,
    instance_id: Optional[str] = None,
) -> SharedBackendDescriptor:
    if port <= 0:
        raise ValueError("shared backend port must be positive")
    if not session_token:
        raise ValueError("shared backend session token must not be empty")

    home = (
        Path(hermes_home) if hermes_home is not None else get_hermes_home()
    ).resolve()
    descriptor = SharedBackendDescriptor(
        schema_version=_SCHEMA_VERSION,
        owner="gateway",
        pid=os.getpid(),
        process_start_time=get_process_start_time(os.getpid()),
        server_url=f"http://{_LOOPBACK_HOST}:{port}/",
        session_token=session_token,
        hermes_home=str(home),
        instance_id=instance_id or uuid.uuid4().hex,
        started_at=time.time(),
    )
    atomic_json_write(
        shared_backend_descriptor_path(home),
        asdict(descriptor),
        indent=None,
        separators=(",", ":"),
        mode=0o600,
    )
    return descriptor


def remove_shared_backend_descriptor(
    instance_id: str,
    hermes_home: Optional[Path] = None,
) -> bool:
    """Remove only the descriptor still owned by ``instance_id``."""

    if not instance_id:
        return False
    path = shared_backend_descriptor_path(hermes_home)
    descriptor = read_shared_backend_descriptor(hermes_home)
    if descriptor is None or descriptor.instance_id != instance_id:
        return False
    try:
        path.unlink()
        return True
    except FileNotFoundError:
        return False
    except OSError:
        logger.debug("Could not remove shared backend descriptor at %s", path)
        return False


class GatewaySharedBackend:
    """An in-process loopback uvicorn server owned by ``GatewayRunner``."""

    def __init__(
        self,
        *,
        server: Any,
        task: "asyncio.Task[None]",
        descriptor: SharedBackendDescriptor,
    ) -> None:
        self._server = server
        self._task = task
        self.descriptor = descriptor
        self._stopped = False

    @classmethod
    async def start(cls) -> "GatewaySharedBackend":
        # web_server has a deliberately broad route surface and a cold import
        # can take seconds on Windows/macOS. Import it off the gateway loop so
        # Feishu/Discord heartbeats continue while Python builds that module.
        # Do not set HERMES_SERVE_HEADLESS in this long-lived process: tool
        # subprocesses inherit the gateway environment and a later explicit
        # `hermes dashboard` command must still be allowed to serve its UI.
        web_server = await asyncio.to_thread(
            importlib.import_module,
            "hermes_cli.web_server",
        )

        import uvicorn

        web_server.app.state.auth_required = False
        web_server.app.state.bound_host = _LOOPBACK_HOST

        config = uvicorn.Config(
            web_server.app,
            host=_LOOPBACK_HOST,
            port=0,
            log_level="warning",
            proxy_headers=False,
            ws_ping_interval=None,
            ws_ping_timeout=None,
            timeout_graceful_shutdown=30,
        )
        server = uvicorn.Server(config)
        if not config.loaded:
            config.load()
        server.lifespan = config.lifespan_class(config)
        await server.startup()
        if server.should_exit or not server.started:
            raise RuntimeError("shared Chat backend failed to bind")

        port = web_server._read_bound_port(server, fallback=0)
        if port <= 0:
            server.should_exit = True
            await server.shutdown()
            raise RuntimeError("shared Chat backend did not report a bound port")
        web_server.app.state.bound_port = port

        try:
            descriptor = publish_shared_backend_descriptor(
                port=port,
                session_token=web_server._SESSION_TOKEN,
            )
        except BaseException:
            server.should_exit = True
            await server.shutdown()
            raise

        async def _run() -> None:
            try:
                await server.main_loop()
            finally:
                try:
                    if server.started:
                        await server.shutdown()
                finally:
                    remove_shared_backend_descriptor(
                        descriptor.instance_id,
                        Path(descriptor.hermes_home),
                    )

        task = asyncio.create_task(_run(), name="gateway-shared-chat-backend")
        logger.info(
            "Gateway shared Chat backend listening on %s (PID %d)",
            descriptor.server_url,
            descriptor.pid,
        )
        return cls(server=server, task=task, descriptor=descriptor)

    async def stop(self) -> None:
        if self._stopped:
            return
        self._stopped = True
        self._server.should_exit = True
        try:
            await self._task
        finally:
            remove_shared_backend_descriptor(
                self.descriptor.instance_id,
                Path(self.descriptor.hermes_home),
            )
