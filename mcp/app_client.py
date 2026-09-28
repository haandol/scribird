"""Private Unix-socket transport for a single running Scribird instance."""

from __future__ import annotations

import asyncio
import json
import os
import stat
from pathlib import Path
from typing import Any


class AppUnavailable(ValueError):
    pass


async def control_request(command: str, arguments: dict | None = None, timeout: float = 30) -> dict[str, Any]:
    configured = os.environ.get("SCRIBIRD_CONTROL_SOCKET")
    directory = Path(f"/tmp/scribird-control-{os.getuid()}")
    if configured:
        paths = [Path(configured)]
    else:
        try:
            info = directory.lstat()
        except FileNotFoundError as error:
            raise AppUnavailable("Scribird is not running with MCP control support. Use launch_app after rebuilding.") from error
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("Unsafe Scribird control directory; expected an owned directory with mode 0700.")
        paths = sorted(directory.glob("*.sock"))
    connected = []
    try:
        for path in paths:
            try:
                info = path.lstat()
                if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                    continue
                connection = await asyncio.wait_for(asyncio.open_unix_connection(str(path), limit=8 * 1024 * 1024), 1)
                connected.append(connection)
            except (FileNotFoundError, ConnectionRefusedError, TimeoutError):
                continue
        if not connected:
            raise AppUnavailable("No Scribird app with MCP control support is listening. Build and launch the updated app.")
        if len(connected) != 1:
            raise ValueError("Multiple Scribird instances are running. Set SCRIBIRD_CONTROL_SOCKET to the intended instance; no command was sent.")
        reader, writer = connected[0]
        payload = json.dumps({"command": command, "arguments": arguments or {}}, allow_nan=False).encode() + b"\n"
        if len(payload) > 65_536:
            raise ValueError("Control request exceeds 64 KiB.")
        writer.write(payload)
        await writer.drain()
        try:
            response = json.loads(await asyncio.wait_for(reader.readline(), timeout))
        except TimeoutError as error:
            raise ValueError("Scribird has not replied yet. The operation may still finish; check get_app_status before retrying. Requests are never retried automatically.") from error
        except (json.JSONDecodeError, ValueError) as error:
            raise ValueError("Invalid response from Scribird. Rebuild the app and reconnect.") from error
        if not isinstance(response, dict):
            raise ValueError("Invalid response from Scribird.")
        if response.get("error"):
            raise ValueError(response["error"])
        result = response.get("result")
        if not isinstance(result, dict):
            raise ValueError("Scribird returned no structured result.")
        return result
    finally:
        for _, writer in connected:
            writer.close()
        for _, writer in connected:
            try:
                await writer.wait_closed()
            except OSError:
                pass
