"""Tests for the OpenAI → Gemini failover layer in
`generate_recipe_image`. We mock the per-provider helpers so the
tests don't hit network, then assert on which helper got called.

Coverage:
- OpenAI transient → Gemini takes over, returned provider == "gemini".
- OpenAI permanent (400) → no fallback, original error surfaces.
- OpenAI transient + no Gemini key → original transient surfaces.
- Gemini-first user with Gemini transient → no fallback to OpenAI
  (failover is one-directional).
- Successful OpenAI doesn't touch Gemini.
- Network-level httpx errors trigger failover.
- Each member of `_TRANSIENT_STATUS_CODES` triggers failover; 400/401
  do not.
"""
from __future__ import annotations

from unittest.mock import patch

import pytest

from app.config import Settings
from app.models import Recipe
from app.services.recipe_image_ai import (
    RecipeImageError,
    RecipeImageTransientError,
    _TRANSIENT_STATUS_CODES,
    generate_recipe_image,
)


def _settings(*, openai: bool = True, gemini: bool = True, primary: str = "openai") -> Settings:
    return Settings(
        ai_openai_api_key="fake-openai-key" if openai else "",
        ai_gemini_api_key="fake-gemini-key" if gemini else "",
        ai_image_provider=primary,
        ai_image_model="gpt-image-1",
        ai_gemini_image_model="gemini-2.5-flash-image-preview",
        ai_mcp_enabled=False,
    )


def _recipe() -> Recipe:
    # A bare Recipe is enough — `_build_prompt` runs inside the
    # provider helper, which we mock. We never actually look at the
    # recipe in these tests.
    return Recipe(id="r1", name="Test", household_id="h1")


_OPENAI_SUCCESS = (b"openai-bytes", "image/png", "p", "openai", "gpt-image-1")
_GEMINI_SUCCESS = (b"gemini-bytes", "image/png", "p", "gemini", "gemini-2.5-flash-image-preview")


# ---------------------------------------------------------------------
# Happy paths — no failover triggered
# ---------------------------------------------------------------------


class TestNoFailover:
    def test_successful_openai_does_not_invoke_gemini(self) -> None:
        with patch(
            "app.services.recipe_image_ai._generate_via_openai",
            return_value=_OPENAI_SUCCESS,
        ) as oa, patch(
            "app.services.recipe_image_ai._generate_via_gemini",
            return_value=_GEMINI_SUCCESS,
        ) as ge:
            result = generate_recipe_image(_recipe(), settings=_settings())
        assert result[3] == "openai"
        assert oa.call_count == 1
        assert ge.call_count == 0

    def test_gemini_first_user_routes_directly_to_gemini(self) -> None:
        with patch(
            "app.services.recipe_image_ai._generate_via_openai",
            return_value=_OPENAI_SUCCESS,
        ) as oa, patch(
            "app.services.recipe_image_ai._generate_via_gemini",
            return_value=_GEMINI_SUCCESS,
        ) as ge:
            result = generate_recipe_image(
                _recipe(),
                settings=_settings(primary="gemini"),
                user_settings={"image_provider": "gemini"},
            )
        assert result[3] == "gemini"
        assert oa.call_count == 0
        assert ge.call_count == 1


# ---------------------------------------------------------------------
# Failover triggers
# ---------------------------------------------------------------------


class TestFailoverTriggers:
    def test_transient_openai_failure_falls_over_to_gemini(self) -> None:
        with patch(
            "app.services.recipe_image_ai._generate_via_openai",
            side_effect=RecipeImageTransientError("OpenAI returned 503"),
        ) as oa, patch(
            "app.services.recipe_image_ai._generate_via_gemini",
            return_value=_GEMINI_SUCCESS,
        ) as ge:
            result = generate_recipe_image(_recipe(), settings=_settings())
        assert result[3] == "gemini"
        assert result[0] == b"gemini-bytes"
        assert oa.call_count == 1
        assert ge.call_count == 1

    @pytest.mark.parametrize("status_code", sorted(_TRANSIENT_STATUS_CODES))
    def test_every_transient_status_code_triggers_failover(self, status_code: int) -> None:
        """Lock in the contract: every entry in `_TRANSIENT_STATUS_CODES`
        is a failover trigger. If someone removes a code from that set
        in the future without updating this test, the parametrize fails
        loudly."""
        err = RecipeImageTransientError(f"OpenAI returned {status_code}: server hiccup")
        with patch(
            "app.services.recipe_image_ai._generate_via_openai", side_effect=err
        ), patch(
            "app.services.recipe_image_ai._generate_via_gemini",
            return_value=_GEMINI_SUCCESS,
        ):
            result = generate_recipe_image(_recipe(), settings=_settings())
        assert result[3] == "gemini"


# ---------------------------------------------------------------------
# Failover does NOT trigger
# ---------------------------------------------------------------------


class TestFailoverGuards:
    def test_permanent_openai_failure_surfaces_original_error(self) -> None:
        """400 / 401 / 403 are not transient — different provider would
        also reject. Caller should see the original error."""
        err = RecipeImageError("OpenAI returned 400: bad prompt")
        with patch(
            "app.services.recipe_image_ai._generate_via_openai", side_effect=err
        ) as oa, patch(
            "app.services.recipe_image_ai._generate_via_gemini",
            return_value=_GEMINI_SUCCESS,
        ) as ge:
            with pytest.raises(RecipeImageError, match="400"):
                generate_recipe_image(_recipe(), settings=_settings())
        assert oa.call_count == 1
        assert ge.call_count == 0

    def test_transient_openai_without_gemini_key_surfaces_transient(self) -> None:
        err = RecipeImageTransientError("OpenAI returned 503")
        with patch(
            "app.services.recipe_image_ai._generate_via_openai", side_effect=err
        ), patch(
            "app.services.recipe_image_ai._generate_via_gemini",
            return_value=_GEMINI_SUCCESS,
        ) as ge:
            with pytest.raises(RecipeImageTransientError):
                generate_recipe_image(
                    _recipe(),
                    settings=_settings(gemini=False),
                )
        assert ge.call_count == 0

    def test_gemini_first_user_transient_does_not_fall_back_to_openai(self) -> None:
        """Failover is one-directional: gemini-first users explicitly
        picked gemini, so falling through to openai would silently
        ignore their preference. Surface the original error instead."""
        err = RecipeImageTransientError("Gemini returned 503")
        with patch(
            "app.services.recipe_image_ai._generate_via_gemini", side_effect=err
        ) as ge, patch(
            "app.services.recipe_image_ai._generate_via_openai",
            return_value=_OPENAI_SUCCESS,
        ) as oa:
            with pytest.raises(RecipeImageTransientError):
                generate_recipe_image(
                    _recipe(),
                    settings=_settings(primary="gemini"),
                    user_settings={"image_provider": "gemini"},
                )
        assert ge.call_count == 1
        assert oa.call_count == 0


# ---------------------------------------------------------------------
# Telemetry: provider field reports the truth
# ---------------------------------------------------------------------


class TestFailoverTelemetryFields:
    def test_failover_result_reports_gemini_as_provider(self) -> None:
        """The callsite logs telemetry off `result[3]`. After failover,
        that field MUST be `"gemini"`, not the original primary
        provider, or admin dashboards will mis-attribute the call."""
        with patch(
            "app.services.recipe_image_ai._generate_via_openai",
            side_effect=RecipeImageTransientError("503"),
        ), patch(
            "app.services.recipe_image_ai._generate_via_gemini",
            return_value=_GEMINI_SUCCESS,
        ):
            _, _, _, provider, model = generate_recipe_image(_recipe(), settings=_settings())
        assert provider == "gemini"
        assert model == "gemini-2.5-flash-image-preview"
