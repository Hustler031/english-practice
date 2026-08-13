const MATHS = Object.freeze({
  TITLE: 'Maths Revision',
  SHEETS: {
    QUESTIONS: 'Questions', STATE: 'State', ATTEMPTS: 'Attempts', SESSIONS: 'Sessions',
    NOTES: 'Notes', SETTINGS: 'Settings', GENERATED: 'Generated_Practice', PLAN: 'Chapter_Plan', DEMAND_SETS: 'Demand_Sets'
  },
  DEFAULTS: {
    daily_chapter_size: 30,
    daily_reinforcement_size: 10,
    practice_more_size: 20,
    current_day: 1,
    today_chapter: 'Coordinate Geometry',
    mastered_excluded_daily: true,
    marked_reinforcement_enabled: true
  }
});

function doGet() {
  ensureMathsInfrastructure_();
  return HtmlService.createHtmlOutputFromFile('Index')
    .setTitle(MATHS.TITLE)
    .addMetaTag('viewport', 'width=device-width, initial-scale=1, viewport-fit=cover')
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}

function setupMathsRevision() {
  ensureMathsInfrastructure_();
  return getAppBootstrap();
}

function getAppBootstrap() {
  ensureMathsInfrastructure_();
  return {
    title: MATHS.TITLE,
    dashboard: getDashboard_(),
    chapters: getChapters_(),
    library: getLibraryCounts_(),
    resume: getResumeSession_(),
    demandSets: getDemandSets_(),
    settings: getSettingsObject_()
  };
}

function startQuiz(request) {
  ensureMathsInfrastructure_();
  request = request || {};
  const mode = String(request.mode || 'daily');
  const all = getAllQuestions_();
  const state = getStateMap_();
  let pool = [];
  let title = MATHS.TITLE;

  if (mode === 'daily') {
    const today = String(getSetting_('today_chapter', MATHS.DEFAULTS.today_chapter));
    const size = Number(getSetting_('daily_chapter_size', MATHS.DEFAULTS.daily_chapter_size));
    const reinforcementSize = Number(getSetting_('daily_reinforcement_size', MATHS.DEFAULTS.daily_reinforcement_size));

    const chapterPool = all.filter(q =>
      active_(q) && q.chapter === today && rotationTier_(q) === 'Core' && !isMastered_(state[q.question_id])
    );
    const fresh = shuffle_(chapterPool.filter(q => Number((state[q.question_id] || {}).attempts || 0) === 0));
    const seen = shuffle_(chapterPool.filter(q => Number((state[q.question_id] || {}).attempts || 0) > 0));
    pool = fresh.slice(0, size);
    if (pool.length < size) pool = uniqueQuestions_(pool.concat(seen.slice(0, size - pool.length)));

    if (bool_(getSetting_('marked_reinforcement_enabled', true)) && reinforcementSize > 0) {
      const marked = all.filter(q => active_(q) && q.chapter !== today && isMarked_(state[q.question_id]) && !isMastered_(state[q.question_id]));
      const continuous = all.filter(q => active_(q) && rotationTier_(q) === 'Continuous' && !isMastered_(state[q.question_id]));
      pool = uniqueQuestions_(pool.concat(shuffle_(marked.concat(continuous)).slice(0, reinforcementSize)));
    }
    title = 'Day ' + getSetting_('current_day', 1) + ' · ' + today;
  }

  if (mode === 'practice_more') {
    const chapter = String(request.chapter || getSetting_('today_chapter', MATHS.DEFAULTS.today_chapter));
    const size = Number(request.count || getSetting_('practice_more_size', 20));
    pool = shuffle_(all.filter(q => active_(q) && q.chapter === chapter && !isMastered_(state[q.question_id]))).slice(0, size);
    title = 'Practice More · ' + chapter;
  }

  if (mode === 'chapter') {
    const chapter = String(request.chapter || '');
    pool = all.filter(q => active_(q) && q.chapter === chapter);
    title = chapter + ' · Complete Bank';
  }

  if (mode === 'library') {
    const cluster = String(request.cluster || 'Formula');
    pool = filterLibrary_(all, state, cluster);
    title = 'Library · ' + cluster;
  }

  if (mode === 'ondemand') {
    pool = filterOnDemand_(all, state, request);
    const count = Math.max(1, Number(request.count || 20));
    pool = shuffle_(pool).slice(0, count);
    title = 'On Demand' + (request.chapter ? ' · ' + request.chapter : '');
  }

  if (mode === 'generated') {
    const generated = getGeneratedQuestions_();
    pool = filterOnDemand_(generated, state, request);
    const count = Math.max(1, Number(request.count || 20));
    pool = weightedGeneratedSample_(pool, state, count, request);
    title = request.title ? String(request.title) : 'Quick Practice';
  }

  if (mode === 'demand_set') {
    const set = getDemandSetById_(String(request.setId || ''));
    if (!set) return {ok:false, message:'Saved demand set not found.'};
    const ids = json_(set.question_ids_json, []);
    const map = {};
    getAllQuestions_().concat(getGeneratedQuestions_()).forEach(q => map[String(q.question_id)] = q);
    pool = ids.map(id => map[String(id)]).filter(q => q && active_(q));
    if (request.activeOnly) pool = pool.filter(q => !isMastered_(state[q.question_id]));
    pool = shuffle_(pool);
    title = String(set.set_name || 'My Demand Set');
  }

  if (!pool.length) return {ok:false, message:'No eligible questions found for this selection.'};

  const sessionId = Utilities.getUuid();
  const payload = sessionPayload_(sessionId, pool, state, title, mode, 0);
  saveSession_({
    session_id: sessionId,
    mode: mode,
    title: title,
    question_ids_json: JSON.stringify(pool.map(q => q.question_id)),
    current_index: 0,
    updated_at: new Date(),
    completed: false,
    params_json: JSON.stringify(request),
    rendered_questions_json: JSON.stringify(payload.questions)
  });

  return payload;
}

function resumeSession(sessionId) {
  ensureMathsInfrastructure_();
  const s = getSessionById_(String(sessionId || ''));
  if (!s) return {ok:false, message:'Saved session not found.'};
  const rendered = json_(s.rendered_questions_json, []);
  if (Array.isArray(rendered) && rendered.length) {
    const state = getStateMap_(), notes = getNotesMap_();
    rendered.forEach(q => {
      const st = state[q.questionId] || {};
      q.mastered = isMastered_(st);
      q.marked = isMarked_(st);
      q.attempts = Number(st.attempts || 0);
      q.note = String(notes[q.questionId] || q.note || '');
    });
    return {ok:true, sessionId:s.session_id, title:s.title || 'Resume', mode:s.mode || '', currentIndex:Number(s.current_index || 0), total:rendered.length, questions:rendered};
  }
  const allMap = {};
  getAllQuestions_().concat(getGeneratedQuestions_()).forEach(q => allMap[q.question_id] = q);
  const ids = json_(s.question_ids_json, []);
  const list = ids.map(id => allMap[id]).filter(Boolean);
  return sessionPayload_(s.session_id, list, getStateMap_(), s.title || 'Resume', s.mode || '', Number(s.current_index || 0));
}

function submitRecall(payload) {
  ensureMathsInfrastructure_();
  payload = payload || {};
  const id = String(payload.questionId || '');
  if (!id) throw new Error('Missing question ID.');
  const result = String(payload.result || 'seen');
  const now = new Date();
  const responseSec = Math.max(0, Number(payload.responseSec || 0));
  const variantType = String(payload.variantType || '');
  const st = upsertState_(id, {
    attempt:true,
    mastered:!!payload.mastered,
    result:result,
    responseSec:responseSec,
    lastVariant:variantType,
    lastCorrectOption:String(payload.correctOption || '')
  });

  getSheet_(MATHS.SHEETS.ATTEMPTS).appendRow([
    Utilities.getUuid(), now, id, result, responseSec, String(payload.mode || ''),
    String(payload.sessionId || ''), !!st.mastered, !!st.marked, variantType
  ]);
  if (payload.sessionId) updateSessionProgress_(String(payload.sessionId), Number(payload.nextIndex || 0), false);
  return {ok:true, mastered:!!st.mastered, marked:!!st.marked};
}

function setMastered(questionId, mastered) {
  ensureMathsInfrastructure_();
  const st = upsertState_(String(questionId), {mastered:!!mastered});
  return {mastered:!!st.mastered};
}

function toggleMarked(questionId) {
  ensureMathsInfrastructure_();
  const id = String(questionId || '');
  const current = getStateMap_()[id];
  const st = upsertState_(id, {marked:!isMarked_(current)});
  return {marked:!!st.marked};
}

function saveNote(questionId, note) {
  ensureMathsInfrastructure_();
  const id = String(questionId || '');
  const sh = getSheet_(MATHS.SHEETS.NOTES);
  const rows = sheetObjects_(sh);
  const found = rows.find(r => String(r.question_id) === id);
  if (found) sh.getRange(found.__row, 2, 1, 2).setValues([[String(note || ''), new Date()]]);
  else sh.appendRow([id, String(note || ''), new Date(), false]);
  return {ok:true, note:String(note || '')};
}

function finishSession(sessionId) {
  ensureMathsInfrastructure_();
  updateSessionProgress_(String(sessionId || ''), 999999, true);
  return getDashboard_();
}

function getDashboard_() {
  const all = getAllQuestions_();
  const state = getStateMap_();
  const today = String(getSetting_('today_chapter', MATHS.DEFAULTS.today_chapter));
  const chapterCore = all.filter(q => active_(q) && q.chapter === today && rotationTier_(q) === 'Core');
  const masteredToday = chapterCore.filter(q => isMastered_(state[q.question_id])).length;
  const freshRemaining = chapterCore.filter(q => !isMastered_(state[q.question_id]) && Number((state[q.question_id] || {}).attempts || 0) === 0).length;
  let mastered = 0, marked = 0, attempted = 0;
  all.forEach(q => {
    const s = state[q.question_id];
    if (isMastered_(s)) mastered++;
    if (isMarked_(s)) marked++;
    if (s && Number(s.attempts || 0) > 0) attempted++;
  });
  return {
    day:Number(getSetting_('current_day', 1)), todayChapter:today, total:all.length,
    chapterTotal:chapterCore.length, chapterRemaining:chapterCore.length - masteredToday,
    chapterMastered:masteredToday, freshRemaining:freshRemaining,
    mastered:mastered, marked:marked, attempted:attempted,
    generated:getGeneratedQuestions_().length,
    fractions:all.filter(q => q.chapter === 'Fraction Patterns').length,
    triplets:all.filter(q => q.chapter === 'Triplets').length
  };
}

function getChapters_() {
  const all = getAllQuestions_();
  const state = getStateMap_();
  const map = {};
  all.forEach(q => {
    if (!active_(q)) return;
    const c = q.chapter || 'Other';
    if (!map[c]) map[c] = {chapter:c,total:0,mastered:0,remaining:0,core:0,support:0,continuous:0,topics:{}};
    map[c].total++;
    const tier = rotationTier_(q).toLowerCase();
    if (tier === 'core') map[c].core++;
    else if (tier === 'support') map[c].support++;
    else if (tier === 'continuous') map[c].continuous++;
    if (isMastered_(state[q.question_id])) map[c].mastered++; else map[c].remaining++;
    const t = q.topic || 'General';
    map[c].topics[t] = (map[c].topics[t] || 0) + 1;
  });
  return Object.values(map).sort((a,b) => a.chapter.localeCompare(b.chapter));
}

function getLibraryCounts_() {
  const all = getAllQuestions_();
  const state = getStateMap_();
  const notes = sheetObjects_(getSheet_(MATHS.SHEETS.NOTES)).filter(n => String(n.note || '').trim());
  return {
    formulas:all.filter(q => String(q.card_type).toLowerCase() === 'formula').length,
    methods:all.filter(q => ['method','pattern','trap'].includes(String(q.card_type).toLowerCase())).length,
    fractions:all.filter(q => q.chapter === 'Fraction Patterns').length,
    triplets:all.filter(q => q.chapter === 'Triplets').length,
    marked:all.filter(q => isMarked_(state[q.question_id])).length,
    notes:notes.length,
    recent:Math.min(20, all.filter(active_).length)
  };
}

function filterLibrary_(all, state, cluster) {
  const c = String(cluster || '').toLowerCase();
  if (c === 'formula' || c === 'formulas') return all.filter(q => String(q.card_type).toLowerCase() === 'formula');
  if (c === 'methods') return all.filter(q => ['method','pattern','trap'].includes(String(q.card_type).toLowerCase()));
  if (c === 'fractions') return all.filter(q => q.chapter === 'Fraction Patterns');
  if (c === 'triplets') return all.filter(q => q.chapter === 'Triplets');
  if (c === 'marked') return all.filter(q => isMarked_(state[q.question_id]));
  if (c === 'notes') {
    const ids = new Set(sheetObjects_(getSheet_(MATHS.SHEETS.NOTES)).filter(n => String(n.note || '').trim()).map(n => String(n.question_id)));
    return all.filter(q => ids.has(q.question_id));
  }
  if (c === 'recent') return all.slice(-20);
  return all;
}

function filterOnDemand_(all, state, request) {
  return all.filter(q => {
    if (!active_(q)) return false;
    if (request.chapter && q.chapter !== request.chapter) return false;
    if (request.topic && q.topic !== request.topic) return false;
    if (request.subtopic && q.subtopic !== request.subtopic) return false;
    if (request.cardType && q.card_type !== request.cardType) return false;
    if (request.difficulty && q.difficulty !== request.difficulty) return false;
    if (request.markedOnly && !isMarked_(state[q.question_id])) return false;
    if (request.activeOnly && isMastered_(state[q.question_id])) return false;
    return true;
  });
}

function sessionPayload_(sessionId, pool, state, title, mode, currentIndex) {
  const noteMap = getNotesMap_();
  const questions = pool.map(q => serveQuestion_(q, state[q.question_id], noteMap[q.question_id] || ''));
  rebalanceMcqPositions_(questions);
  return {
    ok:true, sessionId:sessionId, title:title, mode:mode, currentIndex:currentIndex, total:questions.length,
    questions:questions
  };
}

function serveQuestion_(q, s, note) {
  if (q.chapter === 'Triplets') return serveTriplet_(q, s, note);
  if (q.chapter === 'Fraction Patterns') return serveFraction_(q, s, note);
  if (q.chapter === 'Calculation Memory') return serveCalculationMemory_(q, s, note);

  const mode = inferAnswerMode_(q);
  const base = baseQuestion_(q, s, note);
  base.answerMode = mode;
  base.variantType = 'BASE';
  base.diagramType = shouldShowDiagram_(q) ? String(q.diagram_type || '') : '';
  base.diagramJson = shouldShowDiagram_(q) ? String(q.diagram_json || '') : '';

  if (mode === 'MCQ') {
    const built = buildCoordinateOptions_(q);
    base.options = built.options;
    base.correctOption = built.correctOption;
  } else {
    base.options = [];
    base.correctOption = '';
  }
  return base;
}

function baseQuestion_(q, s, note) {
  return {
    questionId:String(q.question_id || ''),
    chapter:String(q.chapter || ''), topic:String(q.topic || ''), subtopic:String(q.subtopic || ''),
    cardType:String(q.card_type || ''), prompt:String(q.prompt || ''), answer:String(q.answer || ''),
    explanation:String(q.explanation || ''), memoryCue:String(q.memory_cue || ''), difficulty:String(q.difficulty || 'Medium'),
    sourceFile:String(q.source_file || ''), sourcePage:String(q.source_page || ''), sourceUrl:String(q.source_url || ''),
    rotationTier:rotationTier_(q), mastered:isMastered_(s), marked:isMarked_(s), attempts:Number((s || {}).attempts || 0), note:String(note || '')
  };
}

function inferAnswerMode_(q) {
  if (q.chapter === 'Triplets' || q.chapter === 'Fraction Patterns') return 'MCQ';
  const explicit = String(q.answer_mode || '').trim().toUpperCase();
  if (explicit === 'MCQ' || explicit === 'REVEAL') return explicit;
  const type = String(q.card_type || '').toLowerCase();
  return ['formula','pattern'].includes(type) ? 'MCQ' : 'REVEAL';
}

function shouldShowDiagram_(q) {
  const raw = String(q.diagram_json || '').trim();
  if (!raw || raw === '{}') return false;
  const parsed = json_(raw, {});
  return parsed && parsed.show === true && String(q.diagram_type || '').trim() !== '';
}

function buildCoordinateOptions_(q) {
  const explicit = [q.option_a, q.option_b, q.option_c, q.option_d].map(x => String(x || '').trim());
  if (explicit.every(Boolean)) {
    const answer = String(q.answer || '').trim();
    let correctText = '';
    const ck = String(q.correct_option || '').trim().toUpperCase();
    if (['A','B','C','D'].includes(ck)) correctText = explicit[['A','B','C','D'].indexOf(ck)];
    if (!correctText) correctText = explicit.find(x => normalize_(x) === normalize_(answer)) || answer;
    return shuffleOptionTexts_(explicit, correctText);
  }

  const bank = coordinateOptionBank_()[q.question_id];
  if (bank) return shuffleOptionTexts_(bank, String(q.answer || ''));

  const answer = String(q.answer || '').trim();
  const fallback = [answer, 'None of these', 'Cannot be determined', 'Not applicable'];
  return shuffleOptionTexts_(fallback, answer);
}

function coordinateOptionBank_() {
  return {
    CG002:['m = -a/b','m = a/b','m = -b/a','m = b/a'],
    CG003:['x-intercept: set y=0; y-intercept: set x=0','x-intercept: set x=0; y-intercept: set y=0','Set x=y=0 for both','Differentiate the equation'],
    CG004:['x/a + y/b = 1','x/b + y/a = 1','ax + by = 1','x/a - y/b = 1'],
    CG005:['√[(x2-x1)^2 + (y2-y1)^2]','√[(x2+x1)^2 + (y2+y1)^2]','(x2-x1)+(y2-y1)','√[(x2-x1)+(y2-y1)]'],
    CG006:['m = (y2-y1)/(x2-x1)','m = (x2-x1)/(y2-y1)','m = (y2+y1)/(x2+x1)','m = -(y2-y1)/(x2-x1)'],
    CG008:['(x,-y)','(-x,y)','(-x,-y)','(y,x)'],
    CG009:['(-x,y)','(x,-y)','(-x,-y)','(y,x)'],
    CG010:['(-x,-y)','(-x,y)','(x,-y)','(y,x)'],
    CG011:['(y,x)','(-y,-x)','(-x,y)','(x,-y)'],
    CG012:['(2h-x, y)','(x,2h-y)','(h-x,y)','(2x-h,y)'],
    CG013:['(x, 2k-y)','(2k-x,y)','(x,k-y)','(x,2y-k)'],
    CG014:['(x-x1)/a = (y-y1)/b = -2(ax1+by1+c)/(a^2+b^2)','(x+x1)/a = (y+y1)/b = 2(ax1+by1+c)/(a^2+b^2)','(x-x1)/b = (y-y1)/a = -(ax1+by1+c)/(a^2+b^2)','(x-x1)/a = (y-y1)/b = -(ax1+by1+c)/(a^2+b^2)'],
    CG015:['((m x2+n x1)/(m+n), (m y2+n y1)/(m+n))','((m x1+n x2)/(m+n), (m y1+n y2)/(m+n))','((m x2-n x1)/(m-n), (m y2-n y1)/(m-n))','((x1+x2)/2,(y1+y2)/2)'],
    CG016:['((m x2-n x1)/(m-n), (m y2-n y1)/(m-n))','((m x2+n x1)/(m+n), (m y2+n y1)/(m+n))','((m x1-n x2)/(m-n), (m y1-n y2)/(m-n))','((x1+x2)/2,(y1+y2)/2)'],
    CG017:['((x1+x2)/2, (y1+y2)/2)','((x2-x1)/2,(y2-y1)/2)','(x1+x2,y1+y2)','((x1+y1)/2,(x2+y2)/2)'],
    CG018:['1/2 |x1(y2-y3)+x2(y3-y1)+x3(y1-y2)|','|x1(y2-y3)+x2(y3-y1)+x3(y1-y2)|','1/3 |x1(y2-y3)+x2(y3-y1)+x3(y1-y2)|','1/2 |x1(y2+y3)+x2(y3+y1)+x3(y1+y2)|'],
    CG019:['Area of triangle formed by them = 0','All three slopes must be 0','Their midpoint must be the origin','All x-coordinates must be equal'],
    CG020:['slope AB = slope BC (or AB = AC)','slope AB × slope BC = -1','slope AB + slope BC = 0','All slopes are undefined'],
    CG021:['y-y1 = m(x-x1)','y+y1 = m(x+x1)','x-x1 = m(y-y1)','y-y1 = (x-x1)/m²'],
    CG023:['m1 = m2','m1m2 = -1','m1 + m2 = 0','m1/m2 = -1'],
    CG024:['m1 m2 = -1','m1 = m2','m1 + m2 = 1','m1m2 = 1'],
    CG025:['tanθ = |(m1-m2)/(1+m1m2)|','tanθ = |(m1+m2)/(1-m1m2)|','tanθ = |(1+m1m2)/(m1-m2)|','tanθ = |m1-m2|'],
    CG026:['m = tanθ','m = sinθ','m = cosθ','m = cotθ'],
    CG027:['|ax1+by1+c|/√(a^2+b^2)','|ax1+by1+c|/(a^2+b^2)','|ax1+by1-c|/√(a^2-b^2)','√(a^2+b^2)/|ax1+by1+c|'],
    CG028:['|c1-c2|/√(a^2+b^2)','|c1+c2|/√(a^2+b^2)','|c1-c2|/(a^2+b^2)','√(a^2+b^2)/|c1-c2|'],
    CG032:['((x1+x2+x3)/3, (y1+y2+y3)/3)','((x1+x2+x3)/2,(y1+y2+y3)/2)','((x1+x2)/2,(y1+y2)/2)','((x1+x2+x3),(y1+y2+y3))'],
    CG034:['((a x1+b x2+c x3)/(a+b+c), (a y1+b y2+c y3)/(a+b+c))','((x1+x2+x3)/3,(y1+y2+y3)/3)','((a x1+b x2+c x3)/(abc),(a y1+b y2+c y3)/(abc))','((x1/a+x2/b+x3/c),(y1/a+y2/b+y3/c))'],
    CG039:['PA² = PB²','PA = PB²','PA² + PB² = 0','slope PA = slope PB'],
    CG040:['Area = |ab|/2','Area = |ab|','Area = |a+b|/2','Area = |a-b|/2'],
    CG042:['ax + by - (ax1+by1) = 0','bx - ay - (bx1-ay1)=0','ax - by + (ax1+by1)=0','a(x-x1)-b(y-y1)=0'],
    CG043:['bx - ay + k = 0 (or any proportional form)','ax + by + k = 0','ax - by + k = 0','-ax - by + k = 0'],
    CG044:['Substitute the point coordinates directly into the line equation.','Differentiate the line equation.','Set both coordinates equal to zero.','Use only the x-coordinate.'],
    CG045:['(d/a, d/b, d/c)','(a/d,b/d,c/d)','(d/a,d/a,d/a)','(a,b,c)']
  };
}

function serveFraction_(q, s, note) {
  const base = baseQuestion_(q, s, note);
  const parsed = parseFractionCard_(q);
  const variants = splitVariants_(q.variant_types, ['DIRECT','REVERSE','MULTIPLE']);
  const variant = chooseVariant_(variants, String((s || {}).last_variant || ''));
  let prompt = String(q.prompt || '');
  let answer = parsed.fractionText;
  let choices = [];
  let explanation = String(q.explanation || '');

  if (variant === 'REVERSE') {
    prompt = parsed.fractionText + ' ≈ ?';
    answer = formatPercent_(parsed.percent);
    const vals = [parsed.percent, parsed.percent + parsed.basePercent, Math.max(0, parsed.percent - parsed.basePercent), parsed.percent + 2 * parsed.basePercent];
    choices = vals.map(formatPercent_);
    explanation = parsed.fractionText + ' means ' + parsed.numerator + ' × (' + formatPercent_(parsed.basePercent) + '). Therefore it is approximately ' + formatPercent_(parsed.percent) + '.';
  } else if (variant === 'MULTIPLE') {
    prompt = formatPercent_(parsed.basePercent) + ' × ' + parsed.numerator + ' ≈ ?';
    answer = parsed.fractionText;
    choices = nearbyFractions_(parsed.numerator, parsed.denominator);
    explanation = formatPercent_(parsed.basePercent) + ' is the 1/' + parsed.denominator + ' pattern. Multiplying it by ' + parsed.numerator + ' gives ' + parsed.numerator + '/' + parsed.denominator + (parsed.simplifiedText !== parsed.fractionText ? ' = ' + parsed.simplifiedText : '') + '.';
  } else {
    prompt = formatPercent_(parsed.percent) + ' ≈ ?';
    answer = parsed.fractionText;
    choices = nearbyFractions_(parsed.numerator, parsed.denominator);
    explanation = formatPercent_(parsed.basePercent) + ' ≈ 1/' + parsed.denominator + '. Here ' + formatPercent_(parsed.percent) + ' = ' + formatPercent_(parsed.basePercent) + ' × ' + parsed.numerator + ', so think ' + parsed.numerator + '/' + parsed.denominator + (parsed.simplifiedText !== parsed.fractionText ? ' = ' + parsed.simplifiedText : '') + '.';
  }

  const shuffled = shuffleOptionTexts_(uniqueStrings_(choices.concat([answer])).slice(0, 4), answer);
  base.prompt = prompt;
  base.answer = answer;
  base.explanation = explanation;
  base.answerMode = 'MCQ';
  base.options = shuffled.options;
  base.correctOption = shuffled.correctOption;
  base.variantType = variant;
  base.diagramType = '';
  base.diagramJson = '';
  return base;
}

function serveTriplet_(q, s, note) {
  const base = baseQuestion_(q, s, note);
  const t = parseTripletCard_(q);
  const variants = splitVariants_(q.variant_types, ['MISSING','RECOGNIZE','SCALED','NOT_TRIPLET','APPLICATION']);
  const variant = chooseVariant_(variants, String((s || {}).last_variant || ''));
  let prompt = '';
  let answer = '';
  let choices = [];
  let explanation = '';

  if (variant === 'RECOGNIZE') {
    prompt = 'Which of the following is a Pythagorean triplet?';
    answer = t.a + ', ' + t.b + ', ' + t.c;
    choices = [answer, t.a + ', ' + t.b + ', ' + (t.c + 1), (t.a + 1) + ', ' + t.b + ', ' + t.c, t.a + ', ' + (t.b - 1) + ', ' + t.c];
    explanation = 'Check a² + b² = c². For ' + answer + ': ' + t.a + '² + ' + t.b + '² = ' + (t.a*t.a + t.b*t.b) + ' = ' + t.c + '². So it is a right-triangle triplet.';
  } else if (variant === 'NOT_TRIPLET') {
    const valid = tripletPool_().filter(x => !(x[0]===t.a && x[1]===t.b && x[2]===t.c));
    shuffle_(valid);
    const bad = [t.a, t.b, t.c + 1];
    prompt = 'Which of the following is NOT a Pythagorean triplet?';
    answer = bad.join(', ');
    choices = [answer].concat(valid.slice(0,3).map(x => x.join(', ')));
    explanation = 'A Pythagorean triplet must satisfy a² + b² = c². ' + t.a + '² + ' + t.b + '² = ' + (t.a*t.a + t.b*t.b) + ', but ' + (t.c+1) + '² = ' + ((t.c+1)*(t.c+1)) + ', so this set fails the test.';
  } else if (variant === 'APPLICATION') {
    prompt = 'A right triangle has perpendicular sides ' + t.a + ' and ' + t.b + '. What is its hypotenuse?';
    answer = String(t.c);
    choices = nearbyNumbers_(t.c);
    explanation = 'Use a² + b² = c². ' + t.a + '² + ' + t.b + '² = ' + (t.a*t.a + t.b*t.b) + ' = ' + t.c + '², so the hypotenuse is ' + t.c + '.';
  } else if (variant === 'SCALED') {
    const factor = (t.a + t.b + t.c) % 2 === 0 ? 3 : 2;
    const A = t.a * factor, B = t.b * factor, C = t.c * factor;
    prompt = A + ', ' + B + ', ?';
    answer = String(C);
    choices = nearbyNumbers_(C);
    explanation = 'This is ' + factor + ' × (' + t.a + ', ' + t.b + ', ' + t.c + '). A multiple of a Pythagorean triplet is also a Pythagorean triplet, so the missing value is ' + C + '.';
  } else {
    prompt = t.a + ', ' + t.b + ', ?';
    answer = String(t.c);
    choices = nearbyNumbers_(t.c);
    explanation = (isPrimitiveTriplet_(t.a,t.b,t.c) ? 'Recognize the standard triplet ' : 'Recognize this scaled triplet ') + t.a + '-' + t.b + '-' + t.c + '. You can verify: ' + t.a + '² + ' + t.b + '² = ' + t.c + '².';
  }

  const shuffled = shuffleOptionTexts_(uniqueStrings_(choices.concat([answer])).slice(0, 4), answer);
  base.prompt = prompt;
  base.answer = answer;
  base.explanation = explanation;
  base.memoryCue = t.a + '-' + t.b + '-' + t.c;
  base.answerMode = 'MCQ';
  base.options = shuffled.options;
  base.correctOption = shuffled.correctOption;
  base.variantType = variant;
  base.diagramType = '';
  base.diagramJson = '';
  return base;
}

function serveCalculationMemory_(q, s, note) {
  const base = baseQuestion_(q, s, note);
  const isCube = String(q.topic || '').toLowerCase() === 'cubes' || /^CB/i.test(String(q.question_id || ''));
  const nMatch = String(q.question_id || '').match(/(\d+)$/) || String(q.prompt || '').match(/(\d+)/);
  const n = Number(nMatch ? nMatch[1] : 1);
  const value = isCube ? n*n*n : n*n;
  const fallbackVariants = isCube ? ['DIRECT','REVERSE','IDENTIFY'] : ['DIRECT','REVERSE','IDENTIFY','NEARBY'];
  const variants = splitFlexibleVariants_(q.variant_types, fallbackVariants);
  const variant = chooseVariant_(variants, String((s || {}).last_variant || ''));
  let prompt='', answer='', choices=[], explanation='', memoryCue='';

  if (variant === 'REVERSE') {
    prompt = value + ' is the ' + (isCube ? 'cube' : 'square') + ' of which number?';
    answer = String(n);
    choices = closeRoots_(n);
    explanation = 'Recall the pair directly: ' + n + (isCube ? '³ = ' : '² = ') + value + '. Reverse questions make sure you remember both directions.';
    memoryCue = value + ' ↔ ' + n + (isCube ? '³' : '²');
  } else if (variant === 'IDENTIFY') {
    prompt = 'Which of the following pairings is correct?';
    answer = n + (isCube ? '³ = ' : '² = ') + value;
    const roots = closeRoots_(n).filter(x => Number(x) !== n).slice(0,3);
    choices = [answer].concat(roots.map((r,i) => {
      const rr = Number(r);
      const trueVal = isCube ? rr*rr*rr : rr*rr;
      const fake = sameUnitDistractor_(trueVal, i+1, isCube ? 20 : 10);
      return rr + (isCube ? '³ = ' : '² = ') + fake;
    }));
    explanation = 'The exact memory pair is ' + answer + '. Do not rely only on the last digit; the wrong choices are designed to preserve plausible endings.';
    memoryCue = 'Exact pair, not unit-digit guessing.';
  } else if (variant === 'NEARBY' && !isCube) {
    prompt = 'What is ' + n + '²?';
    answer = String(value);
    choices = sameUnitDigitOptions_(value, 10);
    explanation = n + '² = ' + value + '. All options deliberately keep the same unit digit, so you must recall the exact square rather than eliminate by last digit.';
    memoryCue = n + '² → ' + value;
  } else {
    prompt = n + (isCube ? '³ = ?' : '² = ?');
    answer = String(value);
    choices = sameUnitDigitOptions_(value, isCube ? 10 : 10);
    explanation = (isCube ? 'Cube' : 'Square') + ' to memorize: ' + n + (isCube ? '³ = ' : '² = ') + value + '. The distractors keep the same last digit whenever possible, so unit-digit elimination will not solve it.';
    memoryCue = 'Instant target: ' + n + (isCube ? '³ → ' : '² → ') + value;
  }

  const shuffled = shuffleOptionTexts_(uniqueStrings_(choices.concat([answer])).slice(0,4), answer, String((s || {}).last_correct_option || ''));
  base.prompt = prompt;
  base.answer = answer;
  base.explanation = explanation;
  base.memoryCue = memoryCue;
  base.answerMode = 'MCQ';
  base.options = shuffled.options;
  base.correctOption = shuffled.correctOption;
  base.variantType = variant;
  base.diagramType = '';
  base.diagramJson = '';
  return base;
}

function splitFlexibleVariants_(raw, fallback) {
  const arr = String(raw || '').split(/[|,]/).map(x => x.trim().toUpperCase()).filter(Boolean);
  const normalized = arr.map(v => v === 'MIXED' ? 'IDENTIFY' : v);
  return normalized.length ? normalized : fallback.slice();
}

function sameUnitDigitOptions_(correctValue, step) {
  const c = Number(correctValue);
  const vals = [c];
  const offsets = shuffle_([1,2,3,4,5,6]);
  offsets.forEach(k => {
    if (vals.length >= 4) return;
    const sign = vals.length % 2 ? -1 : 1;
    let v = c + sign * k * Number(step || 10);
    if (v <= 0 || String(Math.abs(v)%10) !== String(Math.abs(c)%10)) v = c + k * Number(step || 10);
    if (v > 0 && Math.abs(v)%10 === Math.abs(c)%10 && !vals.includes(v)) vals.push(v);
  });
  let k = 1;
  while (vals.length < 4) {
    const v = c + k*10;
    if (!vals.includes(v)) vals.push(v);
    k++;
  }
  return vals.map(String);
}

function sameUnitDistractor_(trueValue, index, step) {
  const c = Number(trueValue), s = Number(step || 10);
  let v = c + (index % 2 ? index*s : -index*s);
  if (v <= 0 || Math.abs(v)%10 !== Math.abs(c)%10) v = c + index*10;
  return v;
}

function closeRoots_(n) {
  const c = Number(n);
  const vals = [c, c-1, c+1, c+2, c-2, c+3].filter(x => x > 0);
  return shuffle_(uniqueStrings_(vals.map(String))).slice(0,4);
}

function weightedGeneratedSample_(pool, state, count, request) {
  let src = pool.slice();
  if (!src.length) return [];
  const isCalc = String(request.chapter || '') === 'Calculation Memory' || src.some(q => q.chapter === 'Calculation Memory');
  if (!isCalc) return shuffle_(src).slice(0,count);

  const weighted = [];
  src.forEach(q => {
    const st = state[q.question_id] || {};
    const attempts = Number(st.attempts || 0);
    const priority = /Priority/i.test(String(q.subtopic || '')) ? 5 : 1;
    const weakness = String(st.last_result || '').toLowerCase() === 'wrong' ? 3 : 0;
    const freshness = attempts === 0 ? 2 : 0;
    const copies = Math.max(1, priority + weakness + freshness);
    for (let i=0;i<copies;i++) weighted.push(q);
  });
  const out=[], used={};
  shuffle_(weighted).forEach(q => {
    if (out.length >= count || used[q.question_id]) return;
    used[q.question_id]=1; out.push(q);
  });
  if (out.length < count) shuffle_(src).forEach(q => { if(out.length<count&&!used[q.question_id]){used[q.question_id]=1;out.push(q);} });
  return out.slice(0,count);
}

function rebalanceMcqPositions_(questions) {
  const mcqs = questions.filter(q => q.answerMode === 'MCQ' && Array.isArray(q.options) && q.options.length === 4);
  const targets = [];
  while (targets.length < mcqs.length) {
    let block = shuffle_(['A','B','C','D']);
    if (targets.length && block[0] === targets[targets.length-1]) [block[0],block[1]]=[block[1],block[0]];
    targets.push.apply(targets, block);
  }
  mcqs.forEach((q,idx) => forceCorrectPosition_(q, targets[idx]));
}

function forceCorrectPosition_(q, targetKey) {
  const keys=['A','B','C','D'];
  const correctObj = (q.options || []).find(o => o.key === q.correctOption);
  if (!correctObj) return;
  const wrong = shuffle_((q.options || []).filter(o => o.key !== q.correctOption).map(o => ({text:o.text})));
  const targetIndex = keys.indexOf(targetKey);
  const rebuilt = [];
  let w=0;
  for(let i=0;i<4;i++){
    if(i===targetIndex) rebuilt.push({key:keys[i],text:correctObj.text});
    else rebuilt.push({key:keys[i],text:wrong[w++].text});
  }
  q.options = rebuilt;
  q.correctOption = targetKey;
}

function parseFractionCard_(q) {
  const percentMatch = String(q.prompt || '').match(/([0-9]+(?:\.[0-9]+)?)\s*%/);
  const percent = percentMatch ? Number(percentMatch[1]) : 0;
  const frMatches = String(q.answer || '').match(/(\d+)\s*\/\s*(\d+)/g) || [];
  const first = frMatches[0] || '1/1';
  const p = first.split('/').map(Number);
  const numerator = p[0] || 1, denominator = p[1] || 1;
  const simplifiedText = frMatches.length > 1 ? frMatches[frMatches.length-1].replace(/\s/g,'') : first.replace(/\s/g,'');
  const basePercent = numerator ? percent / numerator : percent;
  return {percent, numerator, denominator, fractionText:first.replace(/\s/g,''), simplifiedText, basePercent};
}

function parseTripletCard_(q) {
  const nums = String(q.prompt || '').match(/\d+/g) || [];
  const a = Number(nums[0] || 3), b = Number(nums[1] || 4);
  const ans = String(q.answer || '').match(/\d+/);
  const c = Number(ans ? ans[0] : Math.round(Math.sqrt(a*a+b*b)));
  return {a,b,c};
}

function splitVariants_(raw, fallback) {
  const arr = String(raw || '').split('|').map(x => x.trim().toUpperCase()).filter(Boolean);
  return arr.length ? arr : fallback.slice();
}

function chooseVariant_(variants, last) {
  const choices = variants.filter(v => v !== String(last || '').toUpperCase());
  const pool = choices.length ? choices : variants;
  return pool[Math.floor(Math.random() * pool.length)];
}

function nearbyFractions_(n, d) {
  const vals = [n, Math.max(1,n-1), n+1, n+2].map(x => x + '/' + d);
  return uniqueStrings_(vals);
}

function nearbyNumbers_(n) {
  const d = n < 20 ? 1 : (n < 60 ? 2 : 3);
  return uniqueStrings_([String(n), String(Math.max(1,n-d)), String(n+d), String(n+2*d)]);
}

function tripletPool_() {
  return [[3,4,5],[5,12,13],[8,15,17],[7,24,25],[20,21,29],[12,35,37],[9,40,41],[11,60,61],[28,45,53],[33,56,65]];
}

function isPrimitiveTriplet_(a,b,c) {
  return gcd_(gcd_(a,b),c) === 1;
}
function gcd_(a,b){ while(b){ const t=a%b; a=b; b=t; } return Math.abs(a); }

function formatPercent_(x) {
  const rounded = Math.round(x * 100) / 100;
  return (Math.abs(rounded - Math.round(rounded)) < 1e-9 ? String(Math.round(rounded)) : rounded.toFixed(2).replace(/0$/,'').replace(/\.$/,'')) + '%';
}

function shuffleOptionTexts_(texts, correctText, avoidOption) {
  const correct = String(correctText || '').trim();
  const uniq = uniqueStrings_(texts.map(String));
  if (!uniq.some(x => normalize_(x) === normalize_(correct))) uniq.unshift(correct);
  while (uniq.length < 4) uniq.push('None of these ' + uniq.length);
  let objs = uniq.slice(0,4).map(text => ({text:text, correct:normalize_(text) === normalize_(correct)}));
  objs = shuffle_(objs);
  const keys = ['A','B','C','D'];
  let correctOption = '';
  let options = objs.map((o,i) => {
    if (o.correct) correctOption = keys[i];
    return {key:keys[i], text:o.text};
  });
  if (!correctOption) {
    options[0] = {key:'A', text:correct};
    correctOption = 'A';
  }
  const avoid = String(avoidOption || '').toUpperCase();
  if (avoid && correctOption === avoid) {
    const ci = keys.indexOf(correctOption);
    const candidates = [0,1,2,3].filter(i => i !== ci);
    const swapIndex = candidates[Math.floor(Math.random()*candidates.length)];
    const temp = options[ci].text;
    options[ci].text = options[swapIndex].text;
    options[swapIndex].text = temp;
    correctOption = keys[swapIndex];
  }
  return {options, correctOption};
}

function uniqueStrings_(arr) {
  const seen = {};
  return arr.filter(x => { const k = normalize_(x); if (!k || seen[k]) return false; seen[k]=1; return true; });
}
function normalize_(x){ return String(x || '').replace(/\s+/g,'').toLowerCase(); }

function getAllQuestions_() { return sheetObjects_(getSheet_(MATHS.SHEETS.QUESTIONS)).filter(r => r.question_id); }
function getGeneratedQuestions_() { return sheetObjects_(getSheet_(MATHS.SHEETS.GENERATED)).filter(r => r.question_id); }
function rotationTier_(q) { return String(q.rotation_tier || (q.chapter === 'Triplets' || q.chapter === 'Fraction Patterns' ? 'Continuous' : 'Core')).trim() || 'Core'; }
function active_(q) { return String(q.status || 'Active').toLowerCase() !== 'inactive'; }
function isMastered_(s) { return !!(s && bool_(s.mastered)); }
function isMarked_(s) { return !!(s && bool_(s.marked)); }

function getNotesMap_() {
  const m = {};
  sheetObjects_(getSheet_(MATHS.SHEETS.NOTES)).forEach(r => { if (r.question_id) m[String(r.question_id)] = String(r.note || ''); });
  return m;
}

function upsertState_(id, patch) {
  const sh = getSheet_(MATHS.SHEETS.STATE);
  const rows = sheetObjects_(sh);
  const found = rows.find(r => String(r.question_id) === id);
  const s = found ? Object.assign({}, found) : {question_id:id, attempts:0, mastered:false, marked:false};
  if (patch.attempt) s.attempts = Number(s.attempts || 0) + 1;
  if (Object.prototype.hasOwnProperty.call(patch,'mastered')) s.mastered = !!patch.mastered;
  if (Object.prototype.hasOwnProperty.call(patch,'marked')) s.marked = !!patch.marked;
  if (patch.attempt) {
    s.last_attempt = new Date(); s.last_result = String(patch.result || 'seen'); s.last_response_sec = Number(patch.responseSec || 0);
  }
  if (Object.prototype.hasOwnProperty.call(patch,'lastVariant')) s.last_variant = String(patch.lastVariant || '');
  if (Object.prototype.hasOwnProperty.call(patch,'lastCorrectOption')) s.last_correct_option = String(patch.lastCorrectOption || '');
  const q = getAllQuestions_().concat(getGeneratedQuestions_()).find(x => x.question_id === id) || {};
  const row = [id, Number(s.attempts || 0), !!s.mastered, !!s.marked, s.last_attempt || '', s.last_result || '', Number(s.last_response_sec || 0), q.chapter || '', q.topic || '', q.subtopic || '', s.last_variant || '', s.last_correct_option || ''];
  if (found) sh.getRange(found.__row,1,1,row.length).setValues([row]); else sh.appendRow(row);
  return {question_id:id, attempts:row[1], mastered:row[2], marked:row[3], last_variant:row[10], last_correct_option:row[11]};
}

function getStateMap_() {
  const m = {};
  sheetObjects_(getSheet_(MATHS.SHEETS.STATE)).forEach(r => { if (r.question_id) m[String(r.question_id)] = r; });
  return m;
}

function saveSession_(s) {
  getSheet_(MATHS.SHEETS.SESSIONS).appendRow([s.session_id,s.mode,s.title,s.question_ids_json,s.current_index,s.updated_at,s.completed,s.params_json,s.rendered_questions_json || '']);
}
function getSessionById_(id) { return sheetObjects_(getSheet_(MATHS.SHEETS.SESSIONS)).find(r => String(r.session_id) === id); }
function updateSessionProgress_(id,index,completed) {
  const sh = getSheet_(MATHS.SHEETS.SESSIONS), r = sheetObjects_(sh).find(x => String(x.session_id) === id);
  if (!r) return;
  sh.getRange(r.__row,5,1,3).setValues([[Number(index || 0),new Date(),!!completed]]);
}
function getResumeSession_() {
  const rows = sheetObjects_(getSheet_(MATHS.SHEETS.SESSIONS)).filter(r => r.session_id && !bool_(r.completed)).sort((a,b) => new Date(b.updated_at) - new Date(a.updated_at));
  if (!rows.length) return null;
  const s = rows[0], ids = json_(s.question_ids_json, []);
  return {sessionId:s.session_id,title:s.title,currentIndex:Number(s.current_index || 0),total:ids.length,mode:s.mode};
}

function getDemandSets_() {
  return sheetObjects_(getSheet_(MATHS.SHEETS.DEMAND_SETS))
    .filter(r => r.set_id && String(r.status || 'Active').toLowerCase() !== 'inactive')
    .map(r => ({
      setId:String(r.set_id),
      name:String(r.set_name || 'Demand Set'),
      description:String(r.description || ''),
      count:json_(r.question_ids_json, []).length,
      createdAt:r.created_at ? Utilities.formatDate(new Date(r.created_at), Session.getScriptTimeZone(), 'dd MMM yyyy') : ''
    }))
    .sort((a,b) => String(b.createdAt).localeCompare(String(a.createdAt)));
}
function getDemandSetById_(id) {
  return sheetObjects_(getSheet_(MATHS.SHEETS.DEMAND_SETS)).find(r => String(r.set_id) === String(id) && String(r.status || 'Active').toLowerCase() !== 'inactive');
}

function getSettingsObject_() {
  const o = {};
  sheetObjects_(getSheet_(MATHS.SHEETS.SETTINGS)).forEach(r => { if (r.key) o[String(r.key)] = r.value; });
  return o;
}
function getSetting_(key,fallback) { const o=getSettingsObject_(); return Object.prototype.hasOwnProperty.call(o,key) ? o[key] : fallback; }

function ensureMathsInfrastructure_() {
  const ss = SpreadsheetApp.getActive();
  ensureSheet_(ss,MATHS.SHEETS.QUESTIONS,['Question_ID','Chapter','Topic','Subtopic','Card_Type','Prompt','Answer','Explanation','Memory_Cue','Difficulty','Marked_Default','Mastered_Default','Diagram_Type','Diagram_JSON','Source_File','Source_Page','Source_URL','Status','Answer_Mode','Option_A','Option_B','Option_C','Option_D','Correct_Option','Template_Group','Variant_Types','Rotation_Tier']);
  ensureSheet_(ss,MATHS.SHEETS.STATE,['Question_ID','Attempts','Mastered','Marked','Last_Attempt','Last_Result','Last_Response_Sec','Chapter','Topic','Subtopic','Last_Variant','Last_Correct_Option']);
  ensureSheet_(ss,MATHS.SHEETS.ATTEMPTS,['Attempt_ID','Timestamp','Question_ID','Result','Response_Sec','Mode','Session_ID','Mastered_After','Marked_After','Variant_Type']);
  ensureSheet_(ss,MATHS.SHEETS.SESSIONS,['Session_ID','Mode','Title','Question_IDs_JSON','Current_Index','Updated_At','Completed','Params_JSON','Rendered_Questions_JSON']);
  ensureSheet_(ss,MATHS.SHEETS.NOTES,['Question_ID','Note','Updated_At','Pinned']);
  const settings = ensureSheet_(ss,MATHS.SHEETS.SETTINGS,['Key','Value']);
  ensureSheet_(ss,MATHS.SHEETS.GENERATED,['Question_ID','Chapter','Topic','Subtopic','Card_Type','Prompt','Answer','Explanation','Memory_Cue','Difficulty','Marked_Default','Mastered_Default','Diagram_Type','Diagram_JSON','Source_File','Source_Page','Source_URL','Status','Answer_Mode','Option_A','Option_B','Option_C','Option_D','Correct_Option','Template_Group','Variant_Types','Rotation_Tier']);
  ensureSheet_(ss,MATHS.SHEETS.PLAN,['Order','Chapter','Target_Per_Day','Status','Introduced','Mastered']);
  ensureSheet_(ss,MATHS.SHEETS.DEMAND_SETS,['Set_ID','Set_Name','Description','Question_IDs_JSON','Status','Created_At']);
  if (settings.getLastRow() === 1) Object.keys(MATHS.DEFAULTS).forEach(k => settings.appendRow([k,MATHS.DEFAULTS[k]]));
}

function ensureSheet_(ss,name,headers) {
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  if (sh.getLastRow() === 0) sh.getRange(1,1,1,headers.length).setValues([headers]);
  else {
    const existing = sh.getRange(1,1,1,Math.max(sh.getLastColumn(),1)).getValues()[0].map(String);
    headers.forEach(h => { if (!existing.includes(h)) { sh.getRange(1,sh.getLastColumn()+1).setValue(h); existing.push(h); } });
  }
  return sh;
}
function getSheet_(name) { const sh=SpreadsheetApp.getActive().getSheetByName(name); if(!sh) throw new Error('Missing sheet: '+name); return sh; }
function sheetObjects_(sh) {
  if (!sh || sh.getLastRow() < 2) return [];
  const values=sh.getDataRange().getValues(), headers=values[0].map(key_);
  return values.slice(1).map((row,i) => { const o={__row:i+2}; headers.forEach((h,j) => o[h]=row[j]); return o; });
}
function key_(s){ return String(s||'').trim().toLowerCase().replace(/[^a-z0-9]+/g,'_').replace(/^_|_$/g,''); }
function bool_(v){ return v===true || String(v).toLowerCase()==='true' || String(v)==='1'; }
function json_(s,f){ try{return JSON.parse(String(s||''));}catch(e){return f;} }
function shuffle_(a){ a=a.slice(); for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[a[i],a[j]]=[a[j],a[i]];} return a; }
function uniqueQuestions_(arr){ const seen={}; return arr.filter(q => q && !seen[q.question_id] && (seen[q.question_id]=true)); }
