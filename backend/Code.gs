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
  schemaVersion: 2,
  maxQuestionBatch: 100
});

function doGet(e) {
  try {
    const params = (e && e.parameter) || {};
    const action = String(params.action || 'health').trim();
    switch (action) {
      case 'health': return json_({ ok: true, data: { service: 'english-practice-api', version: EP.schemaVersion } });
      case 'config': return json_({ ok: true, data: getConfig_() });
      case 'categories': return json_({ ok: true, data: getCategories_() });
      case 'sources': return json_({ ok: true, data: getSources_() });
      case 'questions': return json_({ ok: true, data: getQuestions_(params) });
      case 'dailyQuiz': return json_({ ok: true, data: getDailyQuiz_() });
      case 'weakQuestions': return json_({ ok: true, data: getStatusQuestions_('Weak', params) });
      case 'wrongQuestions': return json_({ ok: true, data: getWrongQuestions_(params) });
      case 'revision': return json_({ ok: true, data: getRevisionQuestions_(params) });
      default: return json_({ ok: false, error: 'UNKNOWN_ACTION' });
    }
  } catch (err) {
    console.error(err);
    return json_({ ok: false, error: err && err.message ? err.message : 'SERVER_ERROR' });
  }
}

function doPost(e) {
  const lock = LockService.getScriptLock();
  try {
    lock.waitLock(10000);
    const params = (e && e.parameter) || {};
    const action = String(params.action || '').trim();
    if (action === 'saveAnswer') return json_({ ok: true, data: saveAnswer_(params) });
    return json_({ ok: false, error: 'UNKNOWN_ACTION' });
  } catch (err) {
    console.error(err);
    return json_({ ok: false, error: err && err.message ? err.message : 'SERVER_ERROR' });
  } finally {
    try { lock.releaseLock(); } catch (_) {}
  }
}

function saveAnswer_(params) {
  const questionId = String(params.questionId || '').trim();
  const selected = String(params.selectedAnswer || '').trim().toUpperCase();
  const clientAttemptId = String(params.clientAttemptId || '').trim();
  const marked = normalizeBoolean_(params.markedRevision);
  const timeSeconds = Math.max(0, Number(params.timeSeconds || 0));
  if (!questionId) throw new Error('MISSING_QUESTION_ID');
  if (!['A','B','C','D'].includes(selected)) throw new Error('INVALID_ANSWER');
  if (!clientAttemptId) throw new Error('MISSING_ATTEMPT_ID');

  const performance = getSheet_(EP.sheets.performance);
  const existing = performance.getLastRow() >= 2
    ? performance.getRange(2, 7, performance.getLastRow() - 1, 1).getDisplayValues().flat()
    : [];
  if (existing.includes(clientAttemptId)) return { duplicate: true, attemptId: clientAttemptId };

  const question = findQuestion_(questionId);
  if (!question) throw new Error('QUESTION_NOT_FOUND');
  const isCorrect = selected === String(question.correct || '').toUpperCase();
  const now = new Date();

  performance.appendRow([
    now, questionId, selected, isCorrect, timeSeconds, marked, clientAttemptId,
    question.topic || '', question.conceptId || ''
  ]);

  const status = upsertQuestionStatus_(question, isCorrect, timeSeconds, marked, now);
  markDailyCompleted_(questionId);

  return {
    duplicate: false,
    attemptId: clientAttemptId,
    questionId,
    correct: isCorrect,
    correctAnswer: question.correct,
    status
  };
}

function upsertQuestionStatus_(question, isCorrect, timeSeconds, marked, now) {
  const sheet = getSheet_(EP.sheets.status);
  const lastRow = sheet.getLastRow();
  let rowIndex = -1;
  let previous = null;
  if (lastRow >= 2) {
    const rows = sheet.getRange(2, 1, lastRow - 1, 16).getValues();
    for (let i = 0; i < rows.length; i++) {
      if (String(rows[i][0] || '').trim() === String(question.id)) {
        rowIndex = i + 2;
        previous = rows[i];
        break;
      }
    }
  }

  const attempts = Number(previous && previous[1] || 0) + 1;
  const correct = Number(previous && previous[2] || 0) + (isCorrect ? 1 : 0);
  const wrong = Number(previous && previous[3] || 0) + (isCorrect ? 0 : 1);
  const accuracy = attempts ? correct / attempts : 0;
  const markedCount = Number(previous && previous[5] || 0) + (marked ? 1 : 0);
  const oldAvg = Number(previous && previous[6] || 0);
  const avgTime = ((oldAvg * (attempts - 1)) + timeSeconds) / attempts;
  const oldStreak = Number(previous && previous[11] || 0);
  const streak = isCorrect ? oldStreak + 1 : 0;

  let status = 'Learning';
  if (marked) status = 'Marked';
  else if (!isCorrect || accuracy < 0.7) status = 'Weak';
  else if (attempts >= 3 && accuracy >= 0.85 && streak >= 2) status = 'Strong';

  const nextReview = nextReviewDate_(isCorrect, streak, marked, now);
  const values = [[
    question.id, attempts, correct, wrong, accuracy, markedCount, avgTime,
    now, isCorrect, timeSeconds, marked, streak, status, nextReview,
    question.topic || '', question.conceptId || ''
  ]];

  if (rowIndex > 0) sheet.getRange(rowIndex, 1, 1, 16).setValues(values);
  else sheet.appendRow(values[0]);

  return { attempts, correct, wrong, accuracy, streak, status, nextReview: nextReview.toISOString() };
}

function nextReviewDate_(isCorrect, streak, marked, now) {
  let days = 1;
  if (marked || !isCorrect) days = 1;
  else if (streak <= 1) days = 2;
  else if (streak === 2) days = 4;
  else if (streak === 3) days = 7;
  else if (streak === 4) days = 14;
  else days = 30;
  const date = new Date(now.getTime());
  date.setDate(date.getDate() + days);
  return date;
}

function markDailyCompleted_(questionId) {
  const sheet = getSheet_(EP.sheets.dailyQuiz);
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return;
  const ids = sheet.getRange(2, 1, lastRow - 1, 1).getDisplayValues();
  for (let i = 0; i < ids.length; i++) {
    if (String(ids[i][0] || '').trim() === questionId) {
      sheet.getRange(i + 2, 5).setValue('Completed');
      return;
    }
  }
}

function getConfig_() {
  const rows = readTable_(EP.sheets.config);
  const values = {};
  rows.forEach(row => { const key = String(row.Key || '').trim(); if (key) values[key] = row.Value; });
  return {
    schemaVersion: EP.schemaVersion,
    dailyTarget: Number(values.DAILY_TARGET || 120),
    extraCounts: String(values.EXTRA_COUNTS || '10,20,30,50').split(',').map(v => Number(v.trim())).filter(Number.isFinite),
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
    const id = String(row[0] || '').trim(), topic = String(row[1] || '').trim();
    if (id && topic) counts[topic] = (counts[topic] || 0) + 1;
  });
  return Object.keys(counts).sort((a,b) => a.localeCompare(b)).map(name => ({ name, count: counts[name] }));
}

function getSources_() {
  return readTable_(EP.sheets.sources).filter(row => String(row.Source_ID || '').trim()).map(row => ({
    sourceId: row.Source_ID, sourceType: row.Source_Type, sourceName: row.Source_Name,
    sourceFile: row.Source_File, sourceDate: normalizeValue_(row.Source_Date), active: normalizeBoolean_(row.Active),
    importedOn: normalizeValue_(row.Imported_On), questionCount: Number(row.Question_Count || 0),
    sourceRef: row.Source_Ref, notes: row.Notes
  }));
}

function getQuestions_(params) {
  const limit = clamp_(Number(params.count || 20), 1, EP.maxQuestionBatch);
  const topic = String(params.topic || '').trim().toLowerCase();
  const source = String(params.source || '').trim().toLowerCase();
  const questionType = String(params.questionType || '').trim().toLowerCase();
  return allQuestions_().filter(q =>
    (!topic || String(q.topic).toLowerCase() === topic) &&
    (!source || String(q.sourceFile).toLowerCase() === source) &&
    (!questionType || String(q.questionType).toLowerCase() === questionType)
  ).sort(() => Math.random() - 0.5).slice(0, limit);
}

function getDailyQuiz_() {
  const dailyRows = readTable_(EP.sheets.dailyQuiz).filter(row => String(row.Question_ID || '').trim());
  if (!dailyRows.length) return [];
  const questionMap = new Map(allQuestions_().map(q => [String(q.id), q]));
  return dailyRows.map(row => {
    const q = questionMap.get(String(row.Question_ID).trim());
    if (!q) return null;
    q.daily = { priority: row.Priority, reason: row.Reason, quizDate: normalizeValue_(row.Quiz_Date), status: row.Status };
    return q;
  }).filter(Boolean);
}

function getStatusQuestions_(statusName, params) {
  const limit = clamp_(Number(params.count || 20), 1, EP.maxQuestionBatch);
  const ids = readTable_(EP.sheets.status)
    .filter(row => String(row.Status || '').trim().toLowerCase() === statusName.toLowerCase())
    .map(row => String(row.Question_ID || '').trim());
  return questionsByIds_(ids).slice(0, limit);
}

function getWrongQuestions_(params) {
  const limit = clamp_(Number(params.count || 20), 1, EP.maxQuestionBatch);
  const ids = readTable_(EP.sheets.status).filter(row => Number(row.Wrong || 0) > 0).map(row => String(row.Question_ID || '').trim());
  return questionsByIds_(ids).slice(0, limit);
}

function getRevisionQuestions_(params) {
  const limit = clamp_(Number(params.count || 20), 1, EP.maxQuestionBatch);
  const now = new Date();
  const ids = readTable_(EP.sheets.status).filter(row => {
    if (!row.Next_Review) return false;
    const date = row.Next_Review instanceof Date ? row.Next_Review : new Date(row.Next_Review);
    return !isNaN(date.getTime()) && date <= now;
  }).map(row => String(row.Question_ID || '').trim());
  return questionsByIds_(ids).slice(0, limit);
}

function questionsByIds_(ids) {
  const wanted = new Set(ids.filter(Boolean));
  return allQuestions_().filter(q => wanted.has(String(q.id)));
}

function allQuestions_() {
  const sheet = getSheet_(EP.sheets.questions);
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return [];
  return sheet.getRange(2, 1, lastRow - 1, 16).getValues().filter(r => String(r[0] || '').trim()).map(questionFromRow_);
}

function findQuestion_(id) {
  return allQuestions_().find(q => String(q.id) === String(id)) || null;
}

function questionFromRow_(row) {
  return {
    id: row[0], topic: row[1], word: row[2], question: row[3],
    options: [row[4], row[5], row[6], row[7]], correct: row[8], explanation: row[9],
    subtopic: row[10], questionType: row[11], sourceFile: row[12], sourcePage: row[13],
    conceptId: row[14], difficulty: row[15]
  };
}

function readTable_(sheetName) {
  const sheet = getSheet_(sheetName), lastRow = sheet.getLastRow(), lastColumn = sheet.getLastColumn();
  if (lastRow < 2 || lastColumn < 1) return [];
  const values = sheet.getRange(1, 1, lastRow, lastColumn).getValues();
  const headers = values.shift().map(value => String(value || '').trim());
  return values.map(row => {
    const obj = {};
    headers.forEach((header, index) => { if (header) obj[header] = row[index]; });
    return obj;
  });
}

function getSheet_(name) {
  const sheet = SpreadsheetApp.openById(EP.spreadsheetId).getSheetByName(name);
  if (!sheet) throw new Error('MISSING_SHEET_' + name);
  return sheet;
}

function json_(payload) { return ContentService.createTextOutput(JSON.stringify(payload)).setMimeType(ContentService.MimeType.JSON); }
function clamp_(value, min, max) { return Number.isFinite(value) ? Math.min(max, Math.max(min, Math.floor(value))) : min; }
function normalizeBoolean_(value) { return value === true || String(value || '').trim().toLowerCase() === 'true'; }
function normalizeValue_(value) { return value instanceof Date ? value.toISOString() : value; }
