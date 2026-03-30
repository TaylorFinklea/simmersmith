#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import os
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.server.fastmcp import FastMCP


@dataclass
class BridgeState:
    session: ClientSession | None = None
    lock: asyncio.Lock | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Expose a local codex stdio MCP server over Streamable HTTP.",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--path", default="/mcp")
    parser.add_argument("--codex-command", default="codex")
    parser.add_argument(
        "--codex-arg",
        action="append",
        default=[],
        help="Additional argument to pass to codex before the default safety flags.",
    )
    return parser.parse_args()


def build_server_parameters(args: argparse.Namespace) -> StdioServerParameters:
    codex_args = [
        "-s",
        "read-only",
        "-a",
        "never",
        "mcp-server",
        *args.codex_arg,
    ]
    return StdioServerParameters(
        command=args.codex_command,
        args=codex_args,
        env=os.environ.copy(),
    )


def main() -> None:
    args = parse_args()
    state = BridgeState()

    @asynccontextmanager
    async def lifespan(_: FastMCP):
        params = build_server_parameters(args)
        devnull_path = Path(os.devnull)
        with devnull_path.open("w", encoding="utf-8") as errlog:
            async with stdio_client(params, errlog=errlog) as (read_stream, write_stream):
                async with ClientSession(read_stream, write_stream) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    available = {tool.name for tool in tools.tools}
                    missing = {"codex", "codex-reply"} - available
                    if missing:
                        raise RuntimeError(f"Underlying Codex MCP server is missing tools: {sorted(missing)}")
                    state.session = session
                    state.lock = asyncio.Lock()
                    yield
                    state.session = None
                    state.lock = None

    mcp = FastMCP(
        name="codex-http-bridge",
        instructions=(
            "Bridge the local Codex stdio MCP server over Streamable HTTP. "
            "This bridge is read-only and never-approve."
        ),
        host=args.host,
        port=args.port,
        streamable_http_path=args.path,
        lifespan=lifespan,
    )

    async def call_tool(tool_name: str, arguments: dict[str, Any]) -> dict[str, str]:
        session = state.session
        lock = state.lock
        if session is None or lock is None:
            raise RuntimeError("Codex MCP bridge is not ready.")
        async with lock:
            result = await session.call_tool(tool_name, arguments)
        if result.isError:
            raise RuntimeError(f"Codex MCP tool {tool_name} returned an error.")

        structured = result.structuredContent if isinstance(result.structuredContent, dict) else {}
        text = structured.get("content") if isinstance(structured.get("content"), str) else ""
        thread_id = structured.get("threadId") if isinstance(structured.get("threadId"), str) else None

        if not text:
            text_parts: list[str] = []
            for item in result.content:
                candidate = getattr(item, "text", None)
                if isinstance(candidate, str) and candidate.strip():
                    text_parts.append(candidate.strip())
            text = "\n".join(text_parts).strip()
        if not text:
            raise RuntimeError(f"Codex MCP tool {tool_name} returned an empty response.")

        payload: dict[str, str] = {"content": text}
        if thread_id:
            payload["threadId"] = thread_id
        return payload

    @mcp.tool(name="codex", description="Run an initial Codex assistant turn.")
    async def codex(prompt: str, model: str | None = None) -> dict[str, str]:
        arguments: dict[str, Any] = {"prompt": prompt}
        if model:
            arguments["model"] = model
        return await call_tool("codex", arguments)

    @mcp.tool(name="codex-reply", description="Continue an existing Codex assistant thread.")
    async def codex_reply(prompt: str, threadId: str, model: str | None = None) -> dict[str, str]:
        arguments: dict[str, Any] = {
            "prompt": prompt,
            "threadId": threadId,
        }
        if model:
            arguments["model"] = model
        return await call_tool("codex-reply", arguments)

    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
