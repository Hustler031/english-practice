(() => {
  const state = { questions: [], index: 0, answers: {}, pending: false, questionStartedAt: 0 };
  const el = id => document.getElementById(id);
  const letters = ["A", "B", "C", "D"];
  const sessionKey = "englishDailySession_2026-08-12_v3";

  localStorage.removeItem("englishDailySession");
  localStorage.removeItem("englishDailySession_2026-08-12_v2");

  function loadSaved() {
    try { return JSON.parse(localStorage.getItem(sessionKey) || "null"); }
    catch { return null; }
  }

  function saveLocal() {
    localStorage.setItem(sessionKey, JSON.stringify({ index: state.index, answers: state.answers }));
  }

  function start(questions) {
    state.questions = questions || [];
    const saved = loadSaved();
    state.answers = saved?.answers || {};
    state.index = Math.min(saved?.index || 0, Math.max(0, state.questions.length - 1));
    el("homeView").classList.add("hidden");
    el("quizView").classList.remove("hidden");
    state.questionStartedAt = Date.now();
    render();
    window.scrollTo({ top: 0 });
  }

  function render() {
    const q = state.questions[state.index];
    if (!q) return;
    el("quizCounter").textContent = `${state.index + 1} / ${state.questions.length}`;
    el("quizProgressBar").style.width = `${((state.index + 1) / state.questions.length) * 100}%`;
    el("questionTopic").textContent = q.topic || "English";
    el("questionId").textContent = q.id || "";
    el("questionText").textContent = q.question || q.word || "";
    el("previousButton").disabled = state.index === 0 || state.pending;
    el("nextButton").disabled = state.pending;
    el("nextButton").textContent = state.index === state.questions.length - 1 ? "Finish" : "Next →";

    const chosen = state.answers[q.id];
    const options = el("optionsList");
    options.innerHTML = "";
    (q.options || []).forEach((text, i) => {
      const letter = letters[i];
      const button = document.createElement("button");
      button.type = "button";
      button.className = "option-button";
      button.disabled = state.pending || Boolean(chosen);
      if (chosen) {
        if (letter === q.correct) button.classList.add("correct");
        if (letter === chosen && chosen !== q.correct) button.classList.add("wrong");
        if (letter === chosen) button.classList.add("selected");
      }
      button.innerHTML = `<span class="option-letter">${letter}</span><span></span>`;
      button.lastElementChild.textContent = text;
      button.addEventListener("click", () => selectAnswer(q, letter));
      options.appendChild(button);
    });

    const explanation = el("explanationBox");
    explanation.innerHTML = "";
    if (state.pending) {
      const title = document.createElement("strong");
      title.textContent = "Saving answer…";
      explanation.append(title);
      explanation.classList.remove("hidden");
    } else if (chosen) {
      const title = document.createElement("strong");
      title.textContent = chosen === q.correct ? "Correct" : `Correct answer: ${q.correct}`;
      const body = document.createElement("span");
      body.textContent = q.explanation || "Explanation will be expanded in the next content phase.";
      explanation.append(title, body);
      explanation.classList.remove("hidden");
    } else explanation.classList.add("hidden");
  }

  async function selectAnswer(q, letter) {
    if (state.answers[q.id] || state.pending) return;
    state.pending = true;
    render();
    const timeSeconds = Math.max(0.1, (Date.now() - state.questionStartedAt) / 1000);
    const clientAttemptId = `${q.id}-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;

    try {
      const response = await window.EnglishAPI.saveAnswer({
        questionId: q.id,
        selectedAnswer: letter,
        timeSeconds: timeSeconds.toFixed(2),
        markedRevision: false,
        clientAttemptId
      });
      const result = response.data || response;
      state.answers[q.id] = letter;
      q.daily = q.daily || {};
      q.daily.status = "Completed";
      saveLocal();
      document.dispatchEvent(new CustomEvent("english:answerSaved", { detail: { questionId: q.id, result } }));
    } catch (error) {
      console.error(error);
      const box = el("explanationBox");
      box.innerHTML = "";
      const title = document.createElement("strong");
      title.textContent = "Answer was not saved";
      const body = document.createElement("span");
      body.textContent = "Please tap the option again. No attempt was recorded for this failed save.";
      box.append(title, body);
      box.classList.remove("hidden");
    } finally {
      state.pending = false;
      render();
    }
  }

  function previous() {
    if (!state.pending && state.index > 0) {
      state.index--;
      state.questionStartedAt = Date.now();
      saveLocal();
      render();
      window.scrollTo({ top: 0, behavior: "smooth" });
    }
  }

  function next() {
    if (state.pending) return;
    if (state.index < state.questions.length - 1) {
      state.index++;
      state.questionStartedAt = Date.now();
      saveLocal();
      render();
      window.scrollTo({ top: 0, behavior: "smooth" });
    } else pause();
  }

  function pause() {
    if (state.pending) return;
    saveLocal();
    el("quizView").classList.add("hidden");
    el("homeView").classList.remove("hidden");
    window.scrollTo({ top: 0 });
  }

  document.addEventListener("DOMContentLoaded", () => {
    el("previousButton").addEventListener("click", previous);
    el("nextButton").addEventListener("click", next);
    el("pauseButton").addEventListener("click", pause);
  });

  window.EnglishQuiz = Object.freeze({ start, pause });
})();
