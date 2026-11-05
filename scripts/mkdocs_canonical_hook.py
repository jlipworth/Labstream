"""MkDocs hook: let a page's front matter override its canonical URL.

The project site's privacy and support pages are identical copies of PRIVACY.md and SUPPORT.md,
which https://labstream.app/ also publishes. Their `docs/` wrappers set `canonical_url:` so search
engines treat the labstream.app pages as the originals. Pages without it keep MkDocs' default.
"""


def on_page_context(context, page, config, nav):
    canonical = page.meta.get("canonical_url")
    if canonical:
        if not str(canonical).startswith("https://"):
            raise ValueError(f"{page.file.src_path}: canonical_url must be an absolute https URL")
        page.canonical_url = canonical
    return context
