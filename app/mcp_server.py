"""Backward-compatible re-export.  All logic now lives in app.mcp."""

from app.mcp import main, mcp  # noqa: F401

if __name__ == "__main__":
    main()
