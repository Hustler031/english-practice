(() => {
  const state = { questions: [], index: 0, answers: {} };

  const el = id => document.getElementById(id);
  const letters = ["A", "B", "C", "D"];
  const sessionKey = "englishDailySession_2026-08-12_v2";

  // Old prototype progress is intentionally ignored from this fresh-start version.
  localStorage.removeItem("englishDailySession");

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
    el("previousButton").disabled = state.index === 0;
    el("nextButton").textContent = state.index === state.questions.length - 1 ? "Finish" : "Next →";

    const chosen = state.answers[q.id];
    const options = el("optionsList");
    options.innerHTML = "";
    (q.options || []).forEach((text, i) => {
      const letter = letters[i];
      const button = document.createElement("button");
      button.type = "button";
      button.className = "option-button";
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
    if (chosen) {
      explanation.innerHTML = "";
      const title = document.createElement("strong");
      title.textContent = chosen === q.correct ? "Correct" : `Correct answer: ${q.correct}`;
      const body = document.createElement("span");
      body.textContent = q.explanation || "Explanation will be expanded in the next content phase.";
      explanation.append(title, body);
      explanation.classList.remove("hidden");
    } else explanation.classList.add("hidden");
  }

  function selectAnswer(q, letter) {
    if (state.answers[q.id]) return;
    state.answers[q.id] = letter;
    saveLocal();
    render();
  }

  function previous() {
    if (state.index > 0) { state.index--; saveLocal(); render(); window.scrollTo({ top: 0, behavior: "smooth" }); }
  }

  function next() {
    if (state.index < state.questions.length - 1) { state.index++; saveLocal(); render(); window.scrollTo({ top: 0, behavior: "smooth" }); }
    else pause();
  }

  function pause() {
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
