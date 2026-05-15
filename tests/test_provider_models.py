"""Unit tests for provider_models param helpers.

The chat/completions request-body shape depends on the model: reasoning-
class models (o-series, gpt-5.5+) 400 on non-default ``temperature`` and
on ``max_tokens``. ``openai_chat_body`` normalizes for this.
"""
from __future__ import annotations

from app.services.provider_models import (
    is_openai_reasoning_model,
    openai_chat_body,
)


class TestIsReasoningModel:
    def test_gpt_5_5_is_reasoning(self) -> None:
        assert is_openai_reasoning_model("gpt-5.5") is True

    def test_gpt_5_5_mini_is_reasoning(self) -> None:
        assert is_openai_reasoning_model("gpt-5.5-mini") is True

    def test_o1_is_reasoning(self) -> None:
        assert is_openai_reasoning_model("o1") is True

    def test_o3_mini_is_reasoning(self) -> None:
        assert is_openai_reasoning_model("o3-mini") is True

    def test_o4_mini_is_reasoning(self) -> None:
        assert is_openai_reasoning_model("o4-mini") is True

    def test_gpt_5_4_is_not_reasoning(self) -> None:
        # gpt-5.4 / gpt-5.4-mini accept standard temperature/max_tokens.
        assert is_openai_reasoning_model("gpt-5.4") is False
        assert is_openai_reasoning_model("gpt-5.4-mini") is False

    def test_gpt_5_is_not_reasoning(self) -> None:
        assert is_openai_reasoning_model("gpt-5") is False

    def test_gpt_4_1_is_not_reasoning(self) -> None:
        assert is_openai_reasoning_model("gpt-4.1") is False
        assert is_openai_reasoning_model("gpt-4o") is False

    def test_empty_and_garbage_are_not_reasoning(self) -> None:
        assert is_openai_reasoning_model("") is False
        assert is_openai_reasoning_model("   ") is False
        assert is_openai_reasoning_model("claude-3-5-sonnet") is False

    def test_case_insensitive(self) -> None:
        assert is_openai_reasoning_model("GPT-5.5") is True
        assert is_openai_reasoning_model("O3") is True


class TestOpenAIChatBody:
    def test_standard_model_passes_through(self) -> None:
        result = openai_chat_body(
            model="gpt-5.4-mini",
            base={
                "messages": [{"role": "user", "content": "hi"}],
                "temperature": 0.3,
                "stream": True,
            },
        )
        assert result == {
            "model": "gpt-5.4-mini",
            "messages": [{"role": "user", "content": "hi"}],
            "temperature": 0.3,
            "stream": True,
        }

    def test_reasoning_model_strips_temperature(self) -> None:
        result = openai_chat_body(
            model="gpt-5.5",
            base={
                "messages": [{"role": "user", "content": "hi"}],
                "temperature": 0.3,
                "stream": True,
            },
        )
        assert "temperature" not in result
        assert result["model"] == "gpt-5.5"
        assert result["messages"] == [{"role": "user", "content": "hi"}]
        assert result["stream"] is True

    def test_reasoning_model_renames_max_tokens(self) -> None:
        result = openai_chat_body(
            model="gpt-5.5",
            base={
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 1800,
            },
        )
        assert "max_tokens" not in result
        assert result["max_completion_tokens"] == 1800

    def test_reasoning_model_handles_both_params(self) -> None:
        result = openai_chat_body(
            model="o3-mini",
            base={
                "messages": [{"role": "user", "content": "hi"}],
                "temperature": 0.7,
                "max_tokens": 2000,
                "response_format": {"type": "json_object"},
            },
        )
        assert "temperature" not in result
        assert "max_tokens" not in result
        assert result["max_completion_tokens"] == 2000
        assert result["response_format"] == {"type": "json_object"}

    def test_does_not_mutate_input(self) -> None:
        base = {
            "messages": [{"role": "user", "content": "hi"}],
            "temperature": 0.3,
        }
        openai_chat_body(model="gpt-5.5", base=base)
        # Caller's base dict should be untouched.
        assert base == {
            "messages": [{"role": "user", "content": "hi"}],
            "temperature": 0.3,
        }

    def test_model_param_overrides_base_model(self) -> None:
        # If base accidentally carries a `model` key, the explicit param wins.
        result = openai_chat_body(
            model="gpt-5.5",
            base={"model": "ignored", "messages": []},
        )
        assert result["model"] == "gpt-5.5"
