(() => {
  const el = id => document.getElementById(id);
  let dailyQuestions = [];
  let dailyTarget = 120;

  function refreshCounters() {
    const completed = dailyQuestions.filter(q => String(q.daily?.status || "").toLowerCase() === "completed").length;
    el("dailyTarget").textContent = dailyTarget;
    el("dailyCompleted").textContent = completed;
    el("dailyRemaining").textContent = Math.max(0, dailyTarget - completed);
  }

  async function boot() {
    el("connectionStatus").textContent = "Connecting…";
    try {
      // Apps Script is intentionally called sequentially here. Daily Quiz is the heavier read.
      const configResponse = await window.EnglishAPI.getConfig();
      const config = configResponse.data || configResponse;
      dailyTarget = Number(config.dailyTarget || 120);

      const dailyResponse = await window.EnglishAPI.getDailyQuiz();
      dailyQuestions = dailyResponse.data || dailyResponse || [];
      refreshCounters();
      el("connectionStatus").textContent = "Connected";
      el("dailyMessage").textContent = dailyQuestions.length
        ? `${dailyQuestions.length} questions are ready for your fresh Daily 120.`
        : "No Daily Quiz questions are currently available.";
      el("startDailyButton").disabled = dailyQuestions.length === 0;
    } catch (error) {
      console.error("English Practice boot failed:", error);
      el("connectionStatus").textContent = "Connection error";
      el("dailyMessage").textContent = "Could not load today's quiz from the database API. Refresh once to retry.";
    }
  }

  function goHome() {
    if (!el("quizView").classList.contains("hidden")) window.EnglishQuiz.pause();
    else window.scrollTo({ top: 0, behavior: "smooth" });
  }

  document.addEventListener("english:answerSaved", event => {
    const id = event.detail?.questionId;
    const q = dailyQuestions.find(item => item.id === id);
    if (q) {
      q.daily = q.daily || {};
      q.daily.status = "Completed";
      refreshCounters();
    }
  });

  document.addEventListener("DOMContentLoaded", () => {
    el("homeButton").addEventListener("click", goHome);
    el("startDailyButton").addEventListener("click", () => window.EnglishQuiz.start(dailyQuestions));
    boot();
  });
})();
