# Design QA

## Current Implementation

- Visual direction: category-first default app management with a format list
  and application chooser.
- Primary workflow: configure and audit video file associations.
- Data source: local Agent API; simulated success state has been removed.
- Primary viewport tested: 1280 x 720.
- Compact viewport tested: 1024 x 720.

## Functional QA

- The packaged UI loads from the Agent's loopback origin.
- All 34 rows display the real COM-backed audit result.
- Format selection updates the visible selection count.
- Saving a selection persists the Agent configuration atomically.
- The repair action opens the official Windows Default Apps surface.
- Manual scan updates `lastAuditReason` to `manual-api`.
- Missing API and asset routes return 404 instead of the app shell.
- Browser console warnings and errors: none.
- Production build: passed.

## Layout QA

- The defaults workspace and action bar remain inside the viewport at both
  tested sizes.
- The extension list scrolls vertically without horizontal page overflow.
- The action button, chooser, status labels, and navigation do not overlap.

## Residual Work

- Replace desktop-style browser chrome with a native WebView2 window before a
  polished desktop release.
- Discover installed application icons from package or executable metadata.
