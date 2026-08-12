# English Practice / Revision System

Frontend source for the English Practice / Revision System.

## Architecture

- **Google Sheets** — source of truth for questions, attempts, revision state, source/PDF registry and configuration.
- **Google Apps Script** — lightweight JSON API between the spreadsheet and the frontend.
- **GitHub** — modular frontend source code.

## Initial database

The current primary spreadsheet is **English 30-Day Mastery**. Existing core tabs are preserved:

- `Questions`
- `Performance`
- `Question_Status`
- `Daily_Quiz`
- `Import_50`

Architecture-support tabs added without modifying existing data:

- `Sources`
- `System_Config`

## Frontend modules

- `index.html` — application shell
- `css/app.css` — global UI styles
- `js/config.js` — non-secret frontend configuration
- `js/api.js` — all Apps Script API calls
- `js/app.js` — application bootstrapping/navigation
- `js/quiz.js` — quiz session behavior
- `js/progress.js` — progress state/UI
- `js/revision.js` — revision flows
- `js/sources.js` — source/PDF/category handling

No Google credentials, spreadsheet credentials, API keys, or other secrets should be committed to this repository.
