# Deploy the English Practice Apps Script API

Use a separate standalone Apps Script project. Do not replace the existing Apps Script project attached to the old English quiz.

## One-time deployment

1. Open https://script.google.com/ and click **New project**.
2. Rename the project to **English Practice API**.
3. Open the default `Code.gs` file.
4. Replace only the new project's placeholder code with the contents of `backend/Code.gs` from this repository.
5. Click **Save**.
6. Click **Deploy > New deployment**.
7. Click the gear beside **Select type** and choose **Web app**.
8. Description: `English Practice API v1`.
9. **Execute as:** Me.
10. **Who has access:** Anyone.
11. Click **Deploy** and complete Google's authorization prompts.
12. Copy the final Web App URL ending in `/exec`.

The `/exec` URL is the production API URL. Do not use the `/dev` test-deployment URL in the GitHub frontend.

## First browser test

Open:

`YOUR_WEB_APP_URL?action=health`

Expected JSON:

`{"ok":true,"data":{"service":"english-practice-api","version":1}}`

Then test:

`YOUR_WEB_APP_URL?action=config`

Expected data includes the daily target (`120`) and extra practice counts (`10,20,30,50`).

## Security

The GitHub frontend contains no Google credentials. The Apps Script web app executes as the deploying Google account and reads only the spreadsheet configured server-side in `backend/Code.gs`.
