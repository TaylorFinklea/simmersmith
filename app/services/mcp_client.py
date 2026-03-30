from __future__ import annotations

from contextlib import asynccontextmanager
from dataclasses import dataclass

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from app.config import Settings


@dataclass(frozen=True)
class MCPToolCallResult:
    text: str
    thread_id: str | None = None


def mcp_is_configured(settings: Settings) -> bool:
    return settings.ai_mcp_enabled and bool(settings.ai_mcp_base_url.strip())


@asynccontextmanager
async def mcp_session(settings: Settings):
    if not mcp_is_configured(settings):
        raise RuntimeError("MCP is not configured on the server.")

    headers: dict[str, str] = {}
    if settings.ai_mcp_auth_token.strip():
        headers["Authorization"] = f"Bearer {settings.ai_mcp_auth_token.strip()}"

    timeout = httpx.Timeout(settings.ai_timeout_seconds)
    async with httpx.AsyncClient(headers=headers, timeout=timeout) as http_client:
        async with streamable_http_client(settings.ai_mcp_base_url.strip(), http_client=http_client) as (
            read_stream,
            write_stream,
            _,
        ):
            async with ClientSession(read_stream, write_stream) as session:
                await session.initialize()
                yield session


async def probe_codex_mcp(settings: Settings) -> tuple[bool, str]:
    if not settings.ai_mcp_enabled:
        return False, "disabled"
    if not settings.ai_mcp_base_url.strip():
        return False, "unconfigured"
    headers: dict[str, str] = {}
    if settings.ai_mcp_auth_token.strip():
        headers["Authorization"] = f"Bearer {settings.ai_mcp_auth_token.strip()}"

    timeout = httpx.Timeout(min(settings.ai_timeout_seconds, 5))
    try:
        async with httpx.AsyncClient(headers=headers, timeout=timeout) as http_client:
            async with streamable_http_client(settings.ai_mcp_base_url.strip(), http_client=http_client) as (
                read_stream,
                write_stream,
                _,
            ):
                async with ClientSession(read_stream, write_stream) as session:
                    await session.initialize()
                    tools = await session.list_tools()
    except Exception:
        return False, "unreachable"

    available_names = {tool.name for tool in tools.tools}
    required_names = {
        settings.ai_mcp_tool_name.strip(),
        settings.ai_mcp_reply_tool_name.strip(),
    } - {""}
    if not required_names.issubset(available_names):
        return False, "misconfigured"
    return True, "server"


async def run_codex_mcp(
    *,
    settings: Settings,
    prompt: str,
    thread_id: str | None = None,
) -> MCPToolCallResult:
    if not prompt.strip():
        raise RuntimeError("Assistant prompt is empty.")

    async with mcp_session(settings) as session:
        tool_name = settings.ai_mcp_reply_tool_name.strip() if thread_id else settings.ai_mcp_tool_name.strip()
        arguments: dict[str, object] = {"prompt": prompt}
        if thread_id:
            arguments["threadId"] = thread_id

        result = await session.call_tool(tool_name, arguments)
        if result.isError:
            raise RuntimeError("MCP tool returned an error result.")

        structured = result.structuredContent if isinstance(result.structuredContent, dict) else {}
        resolved_thread_id = structured.get("threadId") if isinstance(structured.get("threadId"), str) else thread_id
        text = structured.get("content") if isinstance(structured.get("content"), str) else ""
        if not text:
            text_parts: list[str] = []
            for item in result.content:
                candidate = getattr(item, "text", None)
                if isinstance(candidate, str) and candidate.strip():
                    text_parts.append(candidate.strip())
            text = "\n".join(text_parts).strip()
        if not text:
            raise RuntimeError("MCP tool returned an empty response.")

    return MCPToolCallResult(text=text, thread_id=resolved_thread_id)
