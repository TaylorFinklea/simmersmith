"""Unit + integration tests for the M6 conversational planning tool loop."""
from __future__ import annotations

from dataclasses import dataclass


from app.config import get_settings
from app.db import session_scope
from app.services.assistant_ai import (
    AssistantExecutionTarget,
    AssistantProviderEnvelope,
    AssistantTurnResult,
)
from app.services.assistant_tools import (
    REGISTRY,
    anthropic_tools_schema,
    openai_tools_schema,
    run_tool,
)


def _seed_week(client) -> str:
    response = client.post("/api/weeks", json={"week_start": "2026-04-20"})
    assert response.status_code == 200, response.text
    return response.json()["week_id"]


def _add_meal_directly(client, week_id: str, day_name: str, slot: str, recipe_name: str) -> str:
    response = client.put(
        f"/api/weeks/{week_id}/meals",
        json=[
            {
                "day_name": day_name,
                "meal_date": "2026-04-20",
                "slot": slot,
                "recipe_name": recipe_name,
                "approved": False,
            }
        ],
    )
    assert response.status_code == 200, response.text
    for meal in response.json()["meals"]:
        if meal["recipe_name"] == recipe_name:
            return meal["meal_id"]
    raise AssertionError("Expected meal not found after creation")


def test_registry_exposes_expected_tools() -> None:
    expected = {
        "get_current_week",
        "get_dietary_goal",
        "get_preferences_summary",
        "generate_week_plan",
        "add_meal",
        "swap_meal",
        "remove_meal",
        "set_meal_approved",
        "rebalance_day",
        "fetch_pricing",
        "set_dietary_goal",
        # M26 Phase 5: dry-run confirm flow.
        "confirm_swap_meal",
        "cancel_swap_meal",
    }
    assert set(REGISTRY.keys()) == expected
    # Every mutating tool has a JSON schema
    for tool in REGISTRY.values():
        assert tool.parameters_schema["type"] == "object"


def test_provider_schemas_share_registry() -> None:
    openai_schema = openai_tools_schema()
    anthropic_schema = anthropic_tools_schema()
    assert len(openai_schema) == len(REGISTRY) == len(anthropic_schema)

    openai_names = {entry["function"]["name"] for entry in openai_schema}
    anthropic_names = {entry["name"] for entry in anthropic_schema}
    assert openai_names == anthropic_names == set(REGISTRY.keys())

    # Anthropic uses `input_schema`, OpenAI nests under `function.parameters`.
    by_name = {entry["name"]: entry for entry in anthropic_schema}
    for tool_name, tool in REGISTRY.items():
        anthropic_entry = by_name[tool_name]
        assert anthropic_entry["description"] == tool.description
        assert anthropic_entry["input_schema"] is tool.parameters_schema


def test_tool_get_current_week_with_no_week_returns_not_ok(client) -> None:
    # No week seeded
    with session_scope() as session:
        result = run_tool(
            "get_current_week",
            session=session,
            user_id=get_settings().local_user_id,
            household_id=get_settings().local_user_id,
            linked_week_id=None,
            args={},
            settings=get_settings(),
        )
    assert result.ok is False
    assert "No active week" in result.detail


def test_tool_add_swap_remove_meal(client) -> None:
    week_id = _seed_week(client)
    settings = get_settings()

    with session_scope() as session:
        add_result = run_tool(
            "add_meal",
            session=session,
            user_id=get_settings().local_user_id,
            household_id=get_settings().local_user_id,
            linked_week_id=week_id,
            args={
                "day_name": "Monday",
                "meal_date": "2026-04-20",
                "slot": "dinner",
                "recipe_name": "Salmon Tacos",
            },
            settings=settings,
        )
    assert add_result.ok is True
    assert add_result.week is not None
    meal_id = next(
        m["meal_id"]
        for m in add_result.week["meals"]
        if m["recipe_name"] == "Salmon Tacos"
    )

    # M26 Phase 5: swap_meal now PROPOSES (no DB mutation). The actual
    # swap requires confirm_swap_meal — exercise the two-step flow.
    with session_scope() as session:
        propose_result = run_tool(
            "swap_meal",
            session=session,
            user_id=get_settings().local_user_id,
            household_id=get_settings().local_user_id,
            linked_week_id=week_id,
            args={"meal_id": meal_id, "recipe_name": "Shrimp Tacos"},
            settings=settings,
        )
    assert propose_result.ok is True
    assert propose_result.data.get("kind") == "proposed_change"

    with session_scope() as session:
        swap_result = run_tool(
            "confirm_swap_meal",
            session=session,
            user_id=get_settings().local_user_id,
            household_id=get_settings().local_user_id,
            linked_week_id=week_id,
            args={"meal_id": meal_id, "recipe_name": "Shrimp Tacos"},
            settings=settings,
        )
    assert swap_result.ok is True
    assert any(m["recipe_name"] == "Shrimp Tacos" for m in swap_result.week["meals"])

    with session_scope() as session:
        remove_result = run_tool(
            "remove_meal",
            session=session,
            user_id=get_settings().local_user_id,
            household_id=get_settings().local_user_id,
            linked_week_id=week_id,
            args={"day_name": "Monday", "slot": "dinner"},
            settings=settings,
        )
    assert remove_result.ok is True
    assert all(m["recipe_name"] != "Shrimp Tacos" for m in remove_result.week["meals"])


def test_tool_set_meal_approved(client) -> None:
    week_id = _seed_week(client)
    meal_id = _add_meal_directly(client, week_id, "Tuesday", "lunch", "Chicken Bowl")

    with session_scope() as session:
        result = run_tool(
            "set_meal_approved",
            session=session,
            user_id=get_settings().local_user_id,
            household_id=get_settings().local_user_id,
            linked_week_id=week_id,
            args={"meal_id": meal_id, "approved": True},
            settings=get_settings(),
        )
    assert result.ok is True
    approved = next(m for m in result.week["meals"] if m["meal_id"] == meal_id)
    assert approved["approved"] is True


def test_tool_set_dietary_goal(client) -> None:
    with session_scope() as session:
        result = run_tool(
            "set_dietary_goal",
            session=session,
            user_id=get_settings().local_user_id,
            household_id=get_settings().local_user_id,
            linked_week_id=None,
            args={
                "goal_type": "maintain",
                "daily_calories": 2000,
                "protein_g": 150,
                "carbs_g": 225,
                "fat_g": 55,
            },
            settings=get_settings(),
        )
    assert result.ok is True
    assert "maintain" in result.detail.lower()

    with session_scope() as session:
        read_back = run_tool(
            "get_dietary_goal",
            session=session,
            user_id=get_settings().local_user_id,
            household_id=get_settings().local_user_id,
            linked_week_id=None,
            args={},
            settings=get_settings(),
        )
    assert read_back.data["goal"]["daily_calories"] == 2000


def test_tool_result_reply_is_json_serializable(client) -> None:
    """Regression: the tool loop feeds `json.dumps(result.to_model_reply())`
    back to the model. Week payloads contain `date` / `datetime` objects, so
    a naive `json.dumps` raises `TypeError: Object of type date is not JSON
    serializable`. The tool result must be pre-encoded via jsonable_encoder.
    """
    import json as _json

    from fastapi.encoders import jsonable_encoder

    week_id = _seed_week(client)
    with session_scope() as session:
        add_result = run_tool(
            "add_meal",
            session=session,
            user_id=get_settings().local_user_id,
            household_id=get_settings().local_user_id,
            linked_week_id=week_id,
            args={
                "day_name": "Monday",
                "meal_date": "2026-04-20",
                "slot": "dinner",
                "recipe_name": "Salmon Tacos",
            },
            settings=get_settings(),
        )
    assert add_result.ok is True
    assert add_result.week is not None
    # Plain json.dumps would blow up on date objects inside the week payload.
    # jsonable_encoder must normalize them to ISO strings first.
    encoded = _json.dumps(jsonable_encoder(add_result.to_model_reply()))
    assert "week_summary" in encoded


def test_planning_thread_streams_tool_call_events(client, monkeypatch) -> None:
    week_id = _seed_week(client)
    _add_meal_directly(client, week_id, "Wednesday", "dinner", "Pasta Primavera")

    @dataclass
    class FakeTarget:
        provider_kind: str = "direct"
        provider_name: str = "openai"
        source: str = "test"
        model: str = "test-model"
        mcp_server_name: str | None = None

        def as_payload(self) -> dict[str, object]:
            return {
                "provider_kind": self.provider_kind,
                "provider_name": self.provider_name,
                "source": self.source,
                "model": self.model,
                "mcp_server_name": self.mcp_server_name,
            }

    def fake_run_assistant_turn(
        *, tool_runner=None, on_event=None, **_: object
    ) -> AssistantTurnResult:
        assert tool_runner is not None
        assert on_event is not None
        # Simulate the loop: first call get_current_week, then swap a meal,
        # then finalize with a message.
        get_result = tool_runner("get_current_week", {})
        on_event(
            "assistant.tool_call",
            {"call_id": "c1", "name": "get_current_week", "arguments": {}, "status": "running"},
        )
        on_event(
            "assistant.tool_result",
            {"call_id": "c1", "name": "get_current_week", "ok": get_result.ok, "detail": get_result.detail, "status": "completed"},
        )
        # M26 Phase 5: simulate the apply-after-confirm path. The LLM
        # would normally call swap_meal first (proposal) then
        # confirm_swap_meal after the user taps Confirm — for this
        # streaming test we go straight to confirm so we can assert
        # the swap landed server-side.
        swap_result = tool_runner(
            "confirm_swap_meal",
            {"day_name": "Wednesday", "slot": "dinner", "recipe_name": "Mushroom Risotto"},
        )
        on_event(
            "assistant.tool_call",
            {"call_id": "c2", "name": "confirm_swap_meal", "arguments": {}, "status": "running"},
        )
        on_event(
            "assistant.tool_result",
            {"call_id": "c2", "name": "confirm_swap_meal", "ok": swap_result.ok, "detail": swap_result.detail, "status": "completed"},
        )
        if swap_result.week is not None:
            on_event("week.updated", {"week": swap_result.week})

        envelope = AssistantProviderEnvelope(
            assistant_markdown="Swapped Wednesday's dinner to Mushroom Risotto."
        )
        return AssistantTurnResult(
            target=AssistantExecutionTarget(
                provider_kind="direct",
                source="test",
                provider_name="openai",
                model="test-model",
            ),
            prompt="system",
            raw_output="{}",
            envelope=envelope,
            provider_thread_id=None,
            tool_calls=[
                {
                    "call_id": "c1",
                    "name": "get_current_week",
                    "arguments": {},
                    "ok": True,
                    "detail": get_result.detail,
                    "status": "completed",
                },
                {
                    "call_id": "c2",
                    "name": "confirm_swap_meal",
                    "arguments": {},
                    "ok": swap_result.ok,
                    "detail": swap_result.detail,
                    "status": "completed" if swap_result.ok else "failed",
                },
            ],
        )

    monkeypatch.setattr("app.api.assistant.run_assistant_turn", fake_run_assistant_turn)

    create = client.post(
        "/api/assistant/threads",
        json={"title": "Plan Wed", "thread_kind": "planning", "linked_week_id": week_id},
    )
    assert create.status_code == 200, create.text
    assert create.json()["thread_kind"] == "planning"
    assert create.json()["linked_week_id"] == week_id
    thread_id = create.json()["thread_id"]

    with client.stream(
        "POST",
        f"/api/assistant/threads/{thread_id}/respond",
        json={"text": "make Wednesday mushroom risotto", "intent": "planning"},
    ) as response:
        assert response.status_code == 200
        body = "".join(response.iter_text())

    assert "event: assistant.tool_call" in body
    assert "event: assistant.tool_result" in body
    assert "event: week.updated" in body
    assert "event: assistant.completed" in body

    # Verify the swap happened server-side
    week_detail = client.get(f"/api/weeks/{week_id}")
    assert week_detail.status_code == 200
    meals = week_detail.json()["meals"]
    assert any(m["recipe_name"] == "Mushroom Risotto" for m in meals)
    assert all(m["recipe_name"] != "Pasta Primavera" for m in meals)

    # Tool calls persisted on the assistant message
    thread_detail = client.get(f"/api/assistant/threads/{thread_id}").json()
    assistant_messages = [m for m in thread_detail["messages"] if m["role"] == "assistant"]
    assert len(assistant_messages) == 1
    tool_calls = assistant_messages[0]["tool_calls"]
    assert [call["name"] for call in tool_calls] == ["get_current_week", "confirm_swap_meal"]


def test_abort_event_cancels_tool_loop_mid_stream(client, monkeypatch) -> None:
    """When abort_event fires mid-stream, the tool loop exits early,
    preserves accumulated text, and returns cancelled=True.
    """
    import threading as _threading

    from app.services.assistant_ai import (
        AssistantExecutionTarget,
        OpenAIAdapter,
        _run_provider_tool_loop,
    )

    abort_event = _threading.Event()

    class _FakeLineStream:
        def __init__(self, lines):
            self._lines = lines

        def iter_lines(self):
            for line in self._lines:
                yield line

        def raise_for_status(self):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

    class _FakeClient:
        def __init__(self, *args, **kwargs):
            pass

        def stream(self, *args, **kwargs):
            # Emit two content deltas, then the test asserts abort fires
            # before any `finish_reason` — so we never send [DONE].
            lines = [
                'data: {"choices":[{"delta":{"content":"Hel"}}]}',
                'data: {"choices":[{"delta":{"content":"lo"}}]}',
                # After this one lands, abort_event will be set by the test
                # so the next iteration of iter_lines short-circuits.
                'data: {"choices":[{"delta":{"content":"_ABORT_"}}]}',
                'data: {"choices":[{"delta":{"content":" ignored"}}]}',
                "data: [DONE]",
            ]
            return _FakeLineStream(lines)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

    monkeypatch.setattr("app.services.assistant_ai.httpx.Client", _FakeClient)
    monkeypatch.setattr(
        "app.services.assistant_ai.resolve_direct_api_key", lambda *a, **k: "fake-key"
    )

    events: list[tuple[str, dict]] = []

    def on_event(name, data):
        events.append((name, data))
        if data.get("delta") == "_ABORT_":
            abort_event.set()

    def never_called_tool_runner(name, args):  # noqa: ARG001
        raise AssertionError("tool_runner should not fire on a pure-text abort test")

    target = AssistantExecutionTarget(
        provider_kind="direct",
        source="test",
        provider_name="openai",
        model="test-model",
    )
    adapter = OpenAIAdapter(
        target=target,
        settings=get_settings(),
        user_settings={},
        system_prompt="system",
        conversation=[],
        user_text="say hi",
    )
    result = _run_provider_tool_loop(
        adapter=adapter,
        target=target,
        settings=get_settings(),
        tool_runner=never_called_tool_runner,
        on_event=on_event,
        abort_event=abort_event,
    )

    assert result.cancelled is True
    # The text that arrived before the abort is preserved.
    assert "Hel" in result.envelope.assistant_markdown
    assert "lo" in result.envelope.assistant_markdown
    # The "ignored" delta came after the abort check and never fired.
    assert "ignored" not in result.envelope.assistant_markdown


def test_streamed_deltas_persist_before_turn_completes(client, monkeypatch) -> None:
    """Regression: closing + reopening the assistant sheet mid-stream should
    show the text that's already arrived. The SSE endpoint flushes
    `content_markdown` on a throttle while deltas come in.
    """
    from app.db import session_scope as _session_scope
    from app.models import AssistantMessage

    week_id = _seed_week(client)

    # Force a flush on every delta so the test doesn't need real time.
    monkeypatch.setattr("app.api.assistant.STREAM_PERSIST_INTERVAL_SECONDS", 0.0)

    observed_partials: list[str] = []

    def fake_run_assistant_turn(
        *, tool_runner=None, on_event=None, **_: object
    ) -> AssistantTurnResult:
        assert on_event is not None
        on_event("assistant.delta", {"delta": "I'll "})
        # After the first delta, the row should have partial content written.
        # We can't inspect mid-request here (session scope differs), but the
        # final assertion below proves it — an intermediate sampling here
        # would couple too tightly to the stream loop timing.
        on_event("assistant.delta", {"delta": "plan "})
        on_event("assistant.delta", {"delta": "Wednesday."})
        envelope = AssistantProviderEnvelope(
            assistant_markdown="I'll plan Wednesday."
        )
        return AssistantTurnResult(
            target=AssistantExecutionTarget(
                provider_kind="direct",
                source="test",
                provider_name="openai",
                model="test-model",
            ),
            prompt="system",
            raw_output="{}",
            envelope=envelope,
            provider_thread_id=None,
            tool_calls=[],
            streamed_deltas=True,
        )

    # Wrap persist_streaming_content so we can observe every partial write.
    from app.services import assistant_threads as _threads_module
    original_persist = _threads_module.persist_streaming_content

    def spy_persist(session, message_id, content_markdown):  # noqa: ANN001
        observed_partials.append(content_markdown)
        return original_persist(session, message_id, content_markdown)

    monkeypatch.setattr("app.api.assistant.persist_streaming_content", spy_persist)
    monkeypatch.setattr("app.api.assistant.run_assistant_turn", fake_run_assistant_turn)

    create = client.post(
        "/api/assistant/threads",
        json={"title": "Plan Wed", "thread_kind": "planning", "linked_week_id": week_id},
    )
    thread_id = create.json()["thread_id"]

    with client.stream(
        "POST",
        f"/api/assistant/threads/{thread_id}/respond",
        json={"text": "plan wednesday", "intent": "planning"},
    ) as response:
        assert response.status_code == 200
        "".join(response.iter_text())

    # Every delta should have triggered a partial persist (interval=0).
    # At minimum: first non-empty text + final flush.
    assert len(observed_partials) >= 2
    assert observed_partials[0] == "I'll "
    # Final observation is the full accumulated text
    assert observed_partials[-1] == "I'll plan Wednesday."

    # Final DB state matches (update_assistant_message runs after the loop
    # with the envelope text, so content_markdown reads the completed text).
    with _session_scope() as session:
        messages = session.query(AssistantMessage).all()
        assistant_row = next(m for m in messages if m.role == "assistant")
        assert assistant_row.content_markdown == "I'll plan Wednesday."
