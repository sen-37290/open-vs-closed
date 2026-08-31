Build a single, self-contained static webpage whose purpose is to prove that a
one-shot generation environment is working end to end.

The page must prominently display the exact text:

One-shot environment test

That text is the centrepiece of the page and must be immediately readable on
first paint, without scrolling, on both a desktop viewport and a narrow mobile
viewport. Below it, show a short subtitle line giving the current date the page
was generated, and a small footer listing the three things the page proves:
that a page was generated, that it renders standalone from the filesystem, and
that it reflows correctly on a narrow screen.

Keep it deliberately small and calm: one screen, a legible typographic
hierarchy, generous whitespace, a restrained two-colour palette, and a
comfortable dark and light appearance that follows the visitor's system
preference. No build step, no external network requests, no fonts or scripts
fetched from a CDN, and no images that are not inline. Everything the page needs
must live inside the artifact folder and work when opened directly from disk.

This is an intentionally trivial page. Do not expand it into a larger site, add
navigation, invent extra sections, or embellish it beyond the brief above.
