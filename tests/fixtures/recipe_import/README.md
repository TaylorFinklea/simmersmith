Recipe import fixture corpus for regression coverage.

Goals:
- keep real-world-shaped URL, OCR, and PDF-style samples on disk instead of inline in test code
- make it easy to add new fixtures when imports fail on actual recipes
- preserve expected structure quality for ingredients, steps, source metadata, and wrapped-line cleanup

Current fixture groups:
- `url_*.html` for URL import HTML / JSON-LD samples
- `text_*.txt` for direct text import and OCR-like samples
- `scan_*.txt` for noisy scan/photo/PDF-style text with page markers and wrapped lines
