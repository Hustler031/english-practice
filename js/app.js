(() => {
  const statusEl = document.getElementById("connectionStatus");
  const setupEl = document.getElementById("setupMessage");
  const dailyTargetEl = document.getElementById("dailyTarget");

  async function boot() {
    if (!window.EnglishPracticeConfig.apiBaseUrl) {
      statusEl.textContent = "API not connected";
      return;
    }

    statusEl.textContent = "Connecting…";

    try {
      const response = await window.EnglishAPI.getConfig();
      const config = response.data || response;
      if (config.dailyTarget) dailyTargetEl.textContent = config.dailyTarget;
      statusEl.textContent = "Connected";
      setupEl.textContent = "Frontend is connected to the English Practice database API.";
    } catch (error) {
      console.error(error);
      statusEl.textContent = "Connection error";
      setupEl.textContent = "The frontend loaded, but the database API could not be reached.";
    }
  }

  document.getElementById("homeButton").addEventListener("click", () => {
    window.scrollTo({ top: 0, behavior: "smooth" });
  });

  document.addEventListener("DOMContentLoaded", boot);
})();
