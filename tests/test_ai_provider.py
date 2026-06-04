"""Tests for AI provider resolution and the online/offline detector factory."""

from __future__ import annotations

from app.config import Settings
from app.dependencies import build_ai_detector


def test_resolver_prefers_openrouter_in_auto() -> None:
    s = Settings(_env_file=None, AI_PROVIDER="auto", OPENROUTER_API_KEY="sk-or-x", ANTHROPIC_API_KEY="sk-ant-y", HUGGINGFACE_API_URL=None)
    assert s.resolved_ai_provider() == "openrouter"
    assert s.ai_is_configured() is True


def test_resolver_falls_back_to_anthropic() -> None:
    s = Settings(_env_file=None, AI_PROVIDER="auto", OPENROUTER_API_KEY=None, ANTHROPIC_API_KEY="sk-ant-y", HUGGINGFACE_API_URL=None)
    assert s.resolved_ai_provider() == "anthropic"


def test_resolver_none_when_no_keys() -> None:
    s = Settings(_env_file=None, AI_PROVIDER="auto", OPENROUTER_API_KEY=None, ANTHROPIC_API_KEY=None, HUGGINGFACE_API_URL=None)
    assert s.resolved_ai_provider() is None
    assert s.ai_is_configured() is False


def test_resolver_forced_provider_without_key_is_none() -> None:
    s = Settings(_env_file=None, AI_PROVIDER="openrouter", OPENROUTER_API_KEY=None, ANTHROPIC_API_KEY="sk-ant-y", HUGGINGFACE_API_URL=None)
    # Forced to openrouter but no OR key -> no provider (won't silently use anthropic).
    assert s.resolved_ai_provider() is None


def test_factory_off_returns_none_even_with_key() -> None:
    s = Settings(_env_file=None, AI_PROVIDER="openrouter", OPENROUTER_API_KEY="sk-or-x", HUGGINGFACE_API_URL=None)
    # Offline toggle: AI disabled regardless of configured key.
    assert build_ai_detector(s, use_ai=False) is None


def test_factory_builds_openrouter_detector() -> None:
    s = Settings(_env_file=None, AI_PROVIDER="openrouter", OPENROUTER_API_KEY="sk-or-x", HUGGINGFACE_API_URL=None)
    det = build_ai_detector(s, use_ai=True)
    assert det is not None
    assert type(det).__name__ == "OpenRouterDetector"
    assert det.is_available() is True


def test_factory_none_when_unconfigured() -> None:
    s = Settings(_env_file=None, AI_PROVIDER="auto", OPENROUTER_API_KEY=None, ANTHROPIC_API_KEY=None, HUGGINGFACE_API_URL=None)
    assert build_ai_detector(s, use_ai=True) is None
