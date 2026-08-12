# Apps Script live app

This folder is the new live architecture. GitHub is only the source backup; the deployed app runs inside Google Apps Script.

Create these files in one Apps Script project:

- `Code.gs` (script file)
- `Index.html`
- `Styles.html`
- `AppJS.html`
- `QuizJS.html`

The app uses `google.script.run`, so there is no CORS/JSONP/GitHub Pages API bridge.

Current implemented foundation:
- mobile-first dashboard
- dark mode with device persistence
- Daily 120
- Topic Practice count picker
- New Practice
- Random Practice eligibility
- Recall Check / Weak / Due batch modes
- Previous / Next / Pause / Home
- Mark for revision
- Mastered / Don't Repeat
- option reshuffling when safe
- explanation blocks for Explanation / Example / Usage / Tip / Memory Aid / Related

Next modules: The Hindu daily word screen, Source/PDF selector, Mastered restore screen, content import/deduplication workflow.
