from __future__ import annotations

import asyncio
import json
import os
import stat
import urllib.request

import pytest

from hermes_cli.shared_backend import (
    GatewaySharedBackend,
    publish_shared_backend_descriptor,
    read_shared_backend_descriptor,
    remove_shared_backend_descriptor,
    shared_backend_descriptor_path,
)


def test_descriptor_is_profile_scoped_atomic_and_owner_only(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))

    descriptor = publish_shared_backend_descriptor(
        port=19199,
        session_token="test-session-token",
        instance_id="test-instance",
    )
    path = shared_backend_descriptor_path()

    assert path == tmp_path / "runtime" / "shared-backend.json"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert descriptor.pid == os.getpid()
    assert descriptor.hermes_home == str(tmp_path.resolve())
    assert descriptor.server_url == "http://127.0.0.1:19199/"
    assert read_shared_backend_descriptor() == descriptor

    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["session_token"] == "test-session-token"
    assert payload["owner"] == "gateway"


def test_cleanup_cannot_delete_a_newer_gateway_descriptor(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    publish_shared_backend_descriptor(
        port=19198,
        session_token="old-token",
        instance_id="old-instance",
    )
    current = publish_shared_backend_descriptor(
        port=19199,
        session_token="new-token",
        instance_id="new-instance",
    )

    assert remove_shared_backend_descriptor("old-instance") is False
    assert read_shared_backend_descriptor() == current
    assert remove_shared_backend_descriptor("new-instance") is True
    assert not shared_backend_descriptor_path().exists()


@pytest.mark.asyncio
async def test_gateway_sidecar_is_live_in_this_process_and_cleans_up(
    tmp_path,
    monkeypatch,
):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    handle = await GatewaySharedBackend.start()
    descriptor = handle.descriptor

    try:
        assert descriptor.pid == os.getpid()
        assert read_shared_backend_descriptor() == descriptor

        def _read_status() -> dict:
            with urllib.request.urlopen(
                descriptor.server_url + "api/status",
                timeout=3,
            ) as response:
                assert response.status == 200
                return json.load(response)

        status = await asyncio.to_thread(_read_status)
        assert status["hermes_home"] == str(tmp_path.resolve())
        assert status["auth_required"] is False
        assert status["version"]
    finally:
        await handle.stop()

    assert not shared_backend_descriptor_path().exists()
