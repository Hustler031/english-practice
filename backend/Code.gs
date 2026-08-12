const EP = Object.freeze({
  spreadsheetId: '1IgUGQZu6sp1STBCX6gyI5pHayLGVpmYYrkKGYdwkjak',
  sheets: Object.freeze({
    questions: 'Questions',
    performance: 'Performance',
    status: 'Question_Status',
    dailyQuiz: 'Daily_Quiz',
    sources: 'Sources',
    config: 'System_Config'
  }),
  schemaVersion: 1,
  maxQuestionBatch: 100
});

function doGet(e) {
  try {
    const params = (e && e.parameter) || {};
    const action = String(params.action || 'health').trim();

    switch (action) {
      case 'health':
        return json_({ ok: true, data: { service: 'english-practice-api', version: EP.schemaVersion } });
      case 'config':
        return json_({ ok: true, data: getConfig_() });
      case 'categories':
        return json_({ ok: true, data: getCategories_() });
      case 'sources':
        return json_({ ok: true, data: getSources_() });
      case 'questions':
        return json_({ ok: true, data: getQuestions_(params) });
      case 'dailyQuiz':
        return json_({ ok: true, data: getDailyQuiz_() });
      default:
        return json_({ ok: false, error: 'UNKNOWN_ACTION' });
    }
  } catch (err) {
    console.error(err);
    return json_({ ok: false, error: err && err.message ? err.message : 'SERVER_ERROR' });
  }
}

function getConfig_() {
  const rows = readTable_(EP.sheets.config);
  const values = {};

  rows.forEach(row => {
    const key = String(row.Key || '').trim();
    if (key) values[key] = row.Value;
  });

  return {
    schemaVersion: Number(values.SCHEMA_VERSION || EP.schemaVersion),
    dailyTarget: Number(values.DAILY_TARGET || 120),
    extraCounts: String(values.EXTRA_COUNTS || '10,20,30,50')
      .split(',')
      .map(v => Number(v.trim()))
      .filter(Number.isFinite),
    databaseRole: String(values.DATABASE_ROLE || 'PRIMARY')
  };
}

function getCategories_() {
  const sheet = getSheet_(EP.sheets.questions);
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return [];

  const values = sheet.getRange(2, 1, lastRow - 1, 16).getValues();
  const counts = {};

  values.forEach(row => {
    const questionId = String(row[0] || '').trim();
    const topic = String(row[1] || '').trim();
    if (!questionId || !topic) return;
    counts[topic] = (counts[topic] || 0) + 1;
  });

  return Object.keys(counts)
    .sort((a, b) => a.localeCompare(b))
    .map(name => ({ name, count: counts[name] }));
}

function getSources_() {
  return readTable_(EP.sheets.sources)
    .filter(row => String(row.Source_ID || '').trim())
    .map(row => ({
      sourceId: row.Source_ID,
      sourceType: row.Source_Type,
      sourceName: row.Source_Name,
      sourceFile: row.Source_File,
      sourceDate: normalizeValue_(row.Source_Date),
      active: normalizeBoolean_(row.Active),
      importedOn: normalizeValue_(row.Imported_On),
      questionCount: Number(row.Question_Count || 0),
      sourceRef: row.Source_Ref,
      notes: row.Notes
    }));
}

function getQuestions_(params) {
  const limit = clamp_(Number(params.count || 20), 1, EP.maxQuestionBatch);
  const topic = String(params.topic || '').trim().toLowerCase();
  const source = String(params.source || '').trim().toLowerCase();
  const questionType = String(params.questionType || '').trim().toLowerCase();

  const sheet = getSheet_(EP.sheets.questions);
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return [];

  const values = sheet.getRange(2, 1, lastRow - 1, 16).getValues();
  const matches = [];

  values.forEach(row => {
    if (!String(row[0] || '').trim()) return;
    if (topic && String(row[1] || '').trim().toLowerCase() !== topic) return;
    if (source && String(row[12] || '').trim().toLowerCase() !== source) return;
    if (questionType && String(row[11] || '').trim().toLowerCase() !== questionType) return;
    matches.push(questionFromRow_(row));
  });

  shuffle_(matches);
  return matches.slice(0, limit);
}

function getDailyQuiz_() {
  const dailyRows = readTable_(EP.sheets.dailyQuiz)
    .filter(row => String(row.Question_ID || '').trim());

  if (!dailyRows.length) return [];

  const wanted = new Map();
  dailyRows.forEach((row, index) => wanted.set(String(row.Question_ID).trim(), { row, index }));

  const questionSheet = getSheet_(EP.sheets.questions);
  const lastRow = questionSheet.getLastRow();
  if (lastRow < 2) return [];

  const values = questionSheet.getRange(2, 1, lastRow - 1, 16).getValues();
  const result = [];

  values.forEach(row => {
    const id = String(row[0] || '').trim();
    if (!wanted.has(id)) return;
    const meta = wanted.get(id).row;
    const question = questionFromRow_(row);
    question.daily = {
      priority: meta.Priority,
      reason: meta.Reason,
      quizDate: normalizeValue_(meta.Quiz_Date),
      status: meta.Status
    };
    result.push({ index: wanted.get(id).index, question });
  });

  return result.sort((a, b) => a.index - b.index).map(item => item.question);
}

function questionFromRow_(row) {
  return {
    id: row[0],
    topic: row[1],
    word: row[2],
    question: row[3],
    options: [row[4], row[5], row[6], row[7]],
    correct: row[8],
    explanation: row[9],
    subtopic: row[10],
    questionType: row[11],
    sourceFile: row[12],
    sourcePage: row[13],
    conceptId: row[14],
    difficulty: row[15]
  };
}

function readTable_(sheetName) {
  const sheet = getSheet_(sheetName);
  const lastRow = sheet.getLastRow();
  const lastColumn = sheet.getLastColumn();
  if (lastRow < 2 || lastColumn < 1) return [];

  const values = sheet.getRange(1, 1, lastRow, lastColumn).getValues();
  const headers = values.shift().map(value => String(value || '').trim());

  return values.map(row => {
    const obj = {};
    headers.forEach((header, index) => {
      if (header) obj[header] = row[index];
    });
    return obj;
  });
}

function getSheet_(name) {
  const spreadsheet = SpreadsheetApp.openById(EP.spreadsheetId);
  const sheet = spreadsheet.getSheetByName(name);
  if (!sheet) throw new Error('MISSING_SHEET_' + name);
  return sheet;
}

function json_(payload) {
  return ContentService
    .createTextOutput(JSON.stringify(payload))
    .setMimeType(ContentService.MimeType.JSON);
}

function clamp_(value, min, max) {
  if (!Number.isFinite(value)) return min;
  return Math.min(max, Math.max(min, Math.floor(value)));
}

function normalizeBoolean_(value) {
  if (value === true || value === false) return value;
  return String(value || '').trim().toLowerCase() === 'true';
}

function normalizeValue_(value) {
  if (value instanceof Date) return value.toISOString();
  return value;
}

function shuffle_(array) {
  for (let i = array.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [array[i], array[j]] = [array[j], array[i]];
  }
  return array;
}
