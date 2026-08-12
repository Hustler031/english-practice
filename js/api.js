(() => {
  const config = window.EnglishPracticeConfig;

  function ensureConfigured() {
    if (!config?.apiBaseUrl) {
      throw new Error("API_NOT_CONFIGURED");
    }
  }

  async function request(action, params = {}) {
    ensureConfigured();

    const url = new URL(config.apiBaseUrl);
    url.searchParams.set("action", action);
    url.searchParams.set("v", String(config.apiVersion));

    Object.entries(params).forEach(([key, value]) => {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    });

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), config.requestTimeoutMs);

    try {
      const response = await fetch(url, { method: "GET", signal: controller.signal });
      if (!response.ok) throw new Error(`HTTP_${response.status}`);
      const payload = await response.json();
      if (payload?.ok === false) throw new Error(payload.error || "API_ERROR");
      return payload;
    } finally {
      clearTimeout(timeout);
    }
  }

  window.EnglishAPI = Object.freeze({
    getConfig: () => request("config"),
    getCategories: () => request("categories"),
    getSources: () => request("sources"),
    getDailyQuiz: () => request("dailyQuiz"),
    getQuestions: params => request("questions", params),
    getRevision: params => request("revision", params),
    getWeakQuestions: params => request("weakQuestions", params),
    getWrongQuestions: params => request("wrongQuestions", params)
  });
})();
