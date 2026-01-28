"""Tests for keyword_extractor module."""

import sys
import time
from pathlib import Path

# Add hooks directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "hooks"))

from keyword_extractor import extract_keywords, keywords_to_query


class TestExtractKeywords:
    """Tests for extract_keywords function."""

    def test_empty_text_returns_empty(self):
        assert extract_keywords("") == []
        assert extract_keywords("   ") == []
        assert extract_keywords(None) == []  # type: ignore

    def test_short_text_returns_empty(self):
        # Less than 20 chars
        assert extract_keywords("hello world") == []
        assert extract_keywords("fix the bug") == []

    def test_extracts_keywords_from_prompt(self):
        text = "fix authentication bug in login flow with JWT token validation"
        keywords = extract_keywords(text)

        assert len(keywords) > 0
        assert len(keywords) <= 8

        # Should contain relevant terms
        keyword_str = " ".join(keywords).lower()
        assert any(
            w in keyword_str
            for w in ["authentication", "login", "jwt", "token", "validation"]
        )

    def test_extracts_from_thinking_block(self):
        text = """
        The user is asking about implementing a rate limiter for their API.
        I should consider different rate limiting algorithms like token bucket,
        sliding window, and fixed window. The user mentioned they're using Redis
        for their backend, so I should suggest using Redis for distributed rate
        limiting. They also mentioned concerns about burst traffic handling.
        """
        keywords = extract_keywords(text)

        assert len(keywords) > 0

        # Should extract relevant technical terms
        keyword_str = " ".join(keywords).lower()
        assert any(w in keyword_str for w in ["rate", "limit", "redis", "api"])

    def test_respects_max_keywords(self):
        text = "authentication login jwt token validation security encryption password user session cookie"
        keywords = extract_keywords(text, max_keywords=3)

        assert len(keywords) <= 3

    def test_filters_stopwords(self):
        text = "I am looking for the code that we wrote yesterday about authentication"
        keywords = extract_keywords(text)

        # Stopwords should be filtered
        for stopword in ["i", "am", "looking", "for", "the", "that", "we", "about"]:
            assert stopword not in [k.lower() for k in keywords]


class TestKeywordsToQuery:
    """Tests for keywords_to_query function."""

    def test_joins_keywords(self):
        keywords = ["auth", "jwt", "token"]
        assert keywords_to_query(keywords) == "auth jwt token"

    def test_empty_list(self):
        assert keywords_to_query([]) == ""

    def test_single_keyword(self):
        assert keywords_to_query(["authentication"]) == "authentication"


class TestPerformance:
    """Performance tests for keyword extraction."""

    def test_extraction_latency(self):
        """YAKE must complete in < 500ms for hook constraints."""
        # Generate moderately long text
        text = " ".join(["authentication", "login", "jwt"] * 100)

        start = time.perf_counter()
        keywords = extract_keywords(text)
        elapsed = time.perf_counter() - start

        assert elapsed < 0.5, f"Extraction took {elapsed:.3f}s, must be < 500ms"
        assert len(keywords) > 0


class TestFallbackBehavior:
    """Tests for fallback when YAKE is not installed."""

    def test_fallback_extracts_words(self):
        """Even without YAKE, should extract some keywords."""
        text = "implement rate limiting with redis sliding window algorithm"
        keywords = extract_keywords(text)

        # Should return something (either YAKE or fallback)
        assert len(keywords) > 0

    def test_fallback_filters_short_words(self):
        """Fallback should filter words < 3 chars."""
        text = "a to of by on in at is it me we or an fix the authentication bug"
        keywords = extract_keywords(text)

        # Short words should be filtered
        for kw in keywords:
            assert len(kw) >= 3


class TestIntegration:
    """Integration tests for keyword extraction workflow."""

    def test_long_prompt_produces_focused_query(self):
        """Long prompts should be condensed to focused keywords."""
        long_prompt = """
        I am looking for the work we did on GTM tracking implementation
        in the application. We added some dataLayer push events for
        tracking form submissions and purchases. I need to find that
        code so I can add similar tracking to the new checkout flow.
        """

        keywords = extract_keywords(long_prompt)
        query = keywords_to_query(keywords)

        # Query should be much shorter than original
        assert len(query.split()) < len(long_prompt.split())

        # Should contain key terms
        query_lower = query.lower()
        assert any(w in query_lower for w in ["gtm", "tracking", "datalayer"])
