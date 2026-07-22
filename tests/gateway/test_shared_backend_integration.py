from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from urllib.parse import quote

import pytest

import gateway.run as gateway_run
import tui_gateway.server as tui_server
from gateway.config import GatewayConfig, Platform, PlatformConfig
from gateway.platforms.base import BasePlatformAdapter, MessageEvent, SendResult
from gateway.session import SessionSource
from hermes_cli.shared_backend import (
    read_shared_backend_descriptor,
    shared_backend_descriptor_path,
)


class _StubFeishuAdapter(BasePlatformAdapter):
    """Local Feishu-shaped adapter; no network or Feishu SDK is involved."""

    def __init__(self, handled: asyncio.Event, delivered: asyncio.Event):
        super().__init__(
            PlatformConfig(enabled=True, token="test-feishu-token"),
            Platform.FEISHU,
        )
        self.handled = handled
        self.delivered = delivered
        self.sent: list[tuple[str, str]] = []

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        self._mark_connected()
        return True

    async def disconnect(self) -> None:
        self._mark_disconnected()

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        self.sent.append((str(chat_id), str(content)))
        self.delivered.set()
        return SendResult(success=True, message_id="stub-feishu-reply")

    async def send_typing(self, chat_id, metadata=None):
        return None

    async def get_chat_info(self, chat_id):
        return {"id": str(chat_id)}


class _TestCronProvider:
    def start(self, stop_event, **kwargs):
        stop_event.wait(timeout=10)

    def stop(self):
        return None


async def _wait_for_descriptor(home: Path):
    for _ in range(100):
        descriptor = read_shared_backend_descriptor(home)
        if descriptor is not None:
            return descriptor
        await asyncio.sleep(0.05)
    raise AssertionError("gateway did not publish shared-backend.json")


@pytest.mark.asyncio
async def test_gateway_feishu_and_macos_chat_share_pid_but_not_sessions(
    tmp_path,
    monkeypatch,
):
    """The real gateway lifecycle serves Feishu and macOS Chat together.

    The adapter and model are local test doubles, but the process boundary,
    sidecar HTTP/WebSocket server, adapter dispatch, and SessionDB routing are
    real. This is the contract that component-only sidecar tests cannot prove.
    """
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setenv("GATEWAY_ALLOW_ALL_USERS", "true")
    monkeypatch.setattr(gateway_run, "_hermes_home", tmp_path)

    handled = asyncio.Event()
    delivered = asyncio.Event()
    adapter = _StubFeishuAdapter(handled, delivered)
    config = GatewayConfig(
        platforms={
            Platform.FEISHU: PlatformConfig(
                enabled=True,
                token="test-feishu-token",
                extra={"app_id": "test", "app_secret": "test"},
            )
        },
        sessions_dir=tmp_path / "sessions",
    )
    runner_class = gateway_run.GatewayRunner
    runner = runner_class(config)

    monkeypatch.setattr(runner, "_create_adapter", lambda platform, cfg: adapter)
    monkeypatch.setattr(runner, "_is_user_authorized", lambda source: True)
    monkeypatch.setattr(runner.hooks, "discover_and_load", lambda: None)
    monkeypatch.setattr(runner.hooks, "emit", _async_none)
    monkeypatch.setattr(runner, "_schedule_resume_pending_sessions", lambda *args, **kwargs: 0)
    monkeypatch.setattr(runner, "_send_update_notification", _async_false)
    monkeypatch.setattr(runner, "_send_restart_notification", _async_none)
    monkeypatch.setattr(runner, "_start_secondary_profile_adapters", _async_zero)
    monkeypatch.setattr(
        runner,
        "_finish_startup_restore",
        lambda: _async_finish_restore(runner),
    )
    monkeypatch.setattr(runner, "_send_home_channel_startup_notifications", _async_none)
    monkeypatch.setattr(runner, "_post_turn_goal_continuation", _async_none)

    feishu_session: dict[str, object] = {}

    async def fake_handle_message_with_agent(event, source, quick_key, run_generation):
        entry = runner.session_store.get_or_create_session(source)
        feishu_session.update(
            {
                "session_id": entry.session_id,
                "session_key": entry.session_key,
                "pid": os.getpid(),
            }
        )
        runner.session_store._db.append_message(entry.session_id, "user", event.text)
        runner.session_store._db.append_message(entry.session_id, "assistant", "feishu-ok")
        handled.set()
        return "feishu-ok"

    monkeypatch.setattr(runner, "_handle_message_with_agent", fake_handle_message_with_agent)

    class _RunnerFactory(runner_class):
        def __new__(cls, cfg):
            return runner

    monkeypatch.setattr(gateway_run, "GatewayRunner", _RunnerFactory)

    # Keep startup's unrelated infrastructure deterministic. The gateway and
    # its sidecar remain real; these providers have no bearing on this test.
    monkeypatch.setattr("tools.skills_sync.sync_skills", lambda quiet=True: None)
    monkeypatch.setattr("hermes_logging.setup_logging", lambda hermes_home, mode: tmp_path)
    monkeypatch.setattr(
        "hermes_cli.security_audit_startup.log_startup_security_warnings",
        lambda **kwargs: None,
    )
    monkeypatch.setattr("tools.mcp_tool.discover_mcp_tools", lambda: None)
    monkeypatch.setattr("hermes_cli.plugins.discover_plugins", lambda: None)
    monkeypatch.setattr("agent.shell_hooks.register_from_config", lambda *args, **kwargs: None)
    monkeypatch.setattr("tools.process_registry.process_registry.recover_from_checkpoint", lambda: 0)
    monkeypatch.setattr(
        "cron.scheduler_provider.resolve_cron_scheduler",
        lambda: _TestCronProvider(),
    )
    monkeypatch.setattr(gateway_run, "_start_gateway_housekeeping", _wait_for_stop_event)
    monkeypatch.setattr("hermes_cli.mcp_startup.start_background_mcp_discovery", lambda **kwargs: None)

    # start_gateway installs signal handlers on the pytest event loop. Keep
    # this test process's handlers untouched while exercising the lifecycle.
    loop = asyncio.get_running_loop()
    monkeypatch.setattr(loop, "add_signal_handler", lambda *args, **kwargs: None)
    monkeypatch.setattr(loop, "set_exception_handler", lambda *args, **kwargs: None)

    # tui_gateway.server is process-global because the shared Uvicorn endpoint
    # is process-local. Reset its lazy DB/session state for this temporary home.
    monkeypatch.setattr(tui_server, "_db", None)
    monkeypatch.setattr(tui_server, "_db_error", None)
    monkeypatch.setattr(tui_server, "_schedule_agent_build", lambda *args, **kwargs: None)
    monkeypatch.setattr(tui_server, "_schedule_session_cap_enforcement", lambda: None)
    macos_dispatch: dict[str, int] = {}
    create_session = tui_server._methods["session.create"]

    def create_session_instrumented(request_id, params):
        macos_dispatch["pid"] = os.getpid()
        return create_session(request_id, params)

    monkeypatch.setitem(
        tui_server._methods,
        "session.create",
        create_session_instrumented,
    )

    gateway_task = asyncio.create_task(
        gateway_run.start_gateway(config=config, verbosity=None)
    )
    macos_session_id = None
    try:
        descriptor = await _wait_for_descriptor(tmp_path)
        assert descriptor.pid == os.getpid()

        feishu_event = MessageEvent(
            text="hello from Feishu",
            source=SessionSource(
                platform=Platform.FEISHU,
                chat_id="oc-test-chat",
                chat_type="dm",
                user_id="ou-test-user",
            ),
            message_id="om-test-message",
        )
        await adapter.handle_message(feishu_event)
        feishu_tasks = tuple(adapter._background_tasks)
        assert feishu_tasks
        await asyncio.wait_for(
            asyncio.gather(*feishu_tasks),
            timeout=5,
        )
        assert handled.is_set()
        assert delivered.is_set()
        assert adapter.sent == [("oc-test-chat", "feishu-ok")]

        ws_url = (
            descriptor.server_url.replace("http://", "ws://", 1)
            + "api/ws?token="
            + quote(descriptor.session_token)
        )
        import websockets

        async with websockets.connect(ws_url) as ws:
            ready = json.loads(await asyncio.wait_for(ws.recv(), timeout=3))
            assert ready["params"]["type"] == "gateway.ready"

            await ws.send(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": "macos-create",
                        "method": "session.create",
                        "params": {
                            "source": "macos-chat",
                            "cols": 100,
                            "close_on_disconnect": True,
                        },
                    }
                )
            )
            created = json.loads(await asyncio.wait_for(ws.recv(), timeout=3))
            assert created["id"] == "macos-create"
            assert "result" in created
            macos_session_id = created["result"]["session_id"]

            macos_state = tui_server._sessions[macos_session_id]
            assert macos_state["source"] == "macos-chat"
            assert macos_state["session_key"] == created["result"]["stored_session_id"]
            assert macos_state["session_key"] != feishu_session["session_key"]
            assert macos_state["session_key"] != feishu_session["session_id"]
            assert macos_state["source"] != Platform.FEISHU.value
            assert (
                feishu_session["pid"]
                == macos_dispatch["pid"]
                == descriptor.pid
                == os.getpid()
            )

            await ws.send(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": "macos-close",
                        "method": "session.close",
                        "params": {"session_id": macos_session_id},
                    }
                )
            )
            closed = json.loads(await asyncio.wait_for(ws.recv(), timeout=3))
            assert closed["result"]["closed"] is True

        await asyncio.wait_for(runner.stop(), timeout=10)
        assert await asyncio.wait_for(gateway_task, timeout=10) is True
        assert not shared_backend_descriptor_path(tmp_path).exists()
        assert adapter.is_connected is False
    finally:
        if not gateway_task.done():
            try:
                await asyncio.wait_for(runner.stop(), timeout=10)
                await asyncio.wait_for(gateway_task, timeout=10)
            except Exception:
                gateway_task.cancel()
                await asyncio.gather(gateway_task, return_exceptions=True)
        if macos_session_id is not None:
            tui_server._sessions.pop(macos_session_id, None)


async def _async_false(*args, **kwargs):
    return False


async def _async_none(*args, **kwargs):
    return None


async def _async_zero(*args, **kwargs):
    return 0


async def _async_finish_restore(*args, **kwargs):
    runner = args[0] if args else None
    if runner is not None:
        runner._startup_restore_in_progress = False


def _wait_for_stop_event(stop_event, **kwargs):
    stop_event.wait(timeout=10)
