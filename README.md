# English Practice / Revision System

The live application is now designed to run inside **Google Apps Script** for speed and reliability. GitHub remains the source backup/version history.

## Live architecture

- **Google Sheets** — source of truth for questions, sources, learning status, attempts, revision state, The Hindu words, recall checks and mastered items.
- **Google Apps Script** — live hosting + backend using `google.script.run`.
- **GitHub** — modular code backup.

## Modular Apps Script files

See [`apps-script/`](apps-script/):

- `Code.gs`
- `Index.html`
- `Styles.html`
- `AppJS.html`
- `QuizJS.html`

This removes the GitHub Pages → Apps Script CORS/JSONP bridge from the live app.
