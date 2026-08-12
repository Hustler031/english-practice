(() => {
  const el = id => document.getElementById(id);
  let dailyQuestions = [];

  async function boot() {
    el("connectionStatus").textContent = "Connecting…";
    try {
      const [configResponse, dailyResponse] = await Promise.all([
        window.EnglishAPI.getConfig(),
        window.EnglishAPI.getDailyQuiz()
      ]);
      const config = configResponse.data || configResponse;
      dailyQuestions = dailyResponse.data || dailyResponse || [];
      const target = Number(config.dailyTarget || 120);
      const completed = dailyQuestions.filter(q => String(q.daily?.status || "").toLowerCase() === "completed").length;
      const remaining = Math.max(0, target - completed);

      el("dailyTarget").textContent = target;
      el("dailyCompleted").textContent = completed;
      el("dailyRemaining").textContent = remaining;
      el("connectionStatus").textContent = "Connected";
      el("dailyMessage").textContent = dailyQuestions.length
        ? `${dailyQuestions.length} questions are available in today's Daily Quiz. Your existing spreadsheet progress is preserved.`
        : "No Daily Quiz questions are currently available.";
      el("startDailyButton").disabled = dailyQuestions.length === 0;
    } catch (error) {
      console.error(error);
      el("connectionStatus").textContent = "Connection error";
      el("dailyMessage").textContent = "Could not load today's quiz from the database API.";
    }
  }

  function goHome() {
    if (!el("quizView").classList.contains("hidden")) window.EnglishQuiz.pause();
    else window.scrollTo({ top: 0, behavior: "smooth" });
  }

  document.addEventListener("DOMContentLoaded", () => {
    el("homeButton").addEventListener("click", goHome);
    el("startDailyButton").addEventListener("click", () => window.EnglishQuiz.start(dailyQuestions));
    boot();
  });
})();
