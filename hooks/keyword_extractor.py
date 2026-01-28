#!/usr/bin/env python3
"""
YAKE keyword extraction for qmd search queries.

Usage:
  # As module
  from keyword_extractor import extract_keywords, keywords_to_query

  # As CLI (for shell scripts)
  echo '{"prompt": "..."}' | python3 keyword_extractor.py
"""

import json
import re
import sys
from collections import Counter

# Lazy-loaded YAKE extractor
_yake_extractor = None

# Stopwords for fallback extraction
STOPWORDS = {
    "i", "me", "my", "we", "our", "you", "your", "the", "a", "an", "is", "are",
    "was", "were", "be", "been", "being", "have", "has", "had", "do", "does",
    "did", "will", "would", "could", "should", "may", "might", "must", "can",
    "to", "of", "in", "for", "on", "with", "at", "by", "from", "as", "into",
    "and", "but", "or", "so", "yet", "both", "either", "neither", "not", "only",
    "this", "that", "these", "those", "what", "which", "who", "how", "why",
    "if", "then", "else", "because", "about", "think", "want", "need", "like",
    "know", "see", "look", "make", "take", "get", "use", "try", "work", "let",
    "going", "looking", "using", "file", "code", "user", "just", "now", "here",
    "there", "some", "all", "any", "each", "more", "most", "other", "also",
    "very", "too", "less", "such", "than", "when", "where", "while", "after",
    "before", "during", "through", "between", "under", "over", "above", "below",
}


def get_extractor():
    """Lazy-load YAKE extractor. Returns None if not installed."""
    global _yake_extractor
    if _yake_extractor is None:
        try:
            import yake

            _yake_extractor = yake.KeywordExtractor(
                lan="en",
                n=2,  # unigrams + bigrams
                dedupLim=0.7,  # moderate deduplication
                dedupFunc="seqm",
                top=10,  # get extras for filtering
            )
        except ImportError:
            return None
    return _yake_extractor


def extract_keywords(text: str, max_keywords: int = 8) -> list[str]:
    """Extract keywords from text for BM25 search.

    Uses YAKE if installed, falls back to simple word extraction.
    Returns list of keywords (most relevant first).
    """
    if not text or len(text.strip()) < 20:
        return []

    extractor = get_extractor()

    if extractor:
        # YAKE returns (keyword, score) tuples, lower score = more relevant
        try:
            keywords = extractor.extract_keywords(text)
            return [kw for kw, _ in keywords[:max_keywords]]
        except Exception:
            pass  # Fall through to fallback

    # Fallback: simple frequency-based extraction
    words = re.findall(r"[a-z][a-z0-9_-]*", text.lower())
    words = [w for w in words if w not in STOPWORDS and len(w) >= 3]

    # Count frequency - more frequent = more important
    counts = Counter(words)
    return [w for w, _ in counts.most_common(max_keywords)]


def keywords_to_query(keywords: list[str]) -> str:
    """Convert keywords list to qmd search query string."""
    return " ".join(keywords)


def main():
    """CLI mode: read JSON from stdin, output keywords."""
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    text = input_data.get("prompt") or input_data.get("thinking") or ""
    keywords = extract_keywords(text)
    print(keywords_to_query(keywords))


if __name__ == "__main__":
    main()
