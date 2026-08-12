(() => {
  const config = window.EnglishPracticeConfig;

  function ensureConfigured() {
    if (!config?.apiBaseUrl) throw new Error("API_NOT_CONFIGURED");
  }

  async function getRequest(action, params = {}) {
    ensureConfigured();
    const url = new URL(config.apiBaseUrl);
    url.searchParams.set("action", action);
    url.searchParams.set("v", String(config.apiVersion));
    Object.entries(params).forEach(([key, value]) => {
      if (value !== undefined && value !== null && value !== "") url.searchParams.set(key, String(value));
    });
    return fetchJson(url, { method: "GET" });
  }

  async function postRequest(action, params = {}) {
    ensureConfigured();
    const body = new URLSearchParams({ action, v: String(config.apiVersion) });
    Object.entries(params).forEach(([key, value]) => {
      if (value !== undefined && value !== null && value !== "") body.set(key, String(value));
    });
    return fetchJson(config.apiBaseUrl, { method: "POST", body });
  }

  async function fetchJson(url, options) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), config.requestTimeoutMs);
    try {
      const response = await fetch(url, { ...options, signal: controller.signal });
      if (!response.ok) throw new Error(`HTTP_${response.status}`);
      const payload = await response.json();
      if (payload?.ok === false) throw new Error(payload.error || "API_ERROR");
      return payload;
    } finally {
      clearTimeout(timeout);
    }
  }

  window.EnglishAPI = Object.freeze({
    getConfig: () => getRequest("config"),
    getCategories: () => getRequest("categories"),
    getSources: () => getRequest("sources"),
    getDailyQuiz: () => getRequest("dailyQuiz"),
    getQuestions: params => getRequest("questions", params),
    getRevision: params => getRequest("revision", params),
    getWeakQuestions: params => getRequest("weakQuestions", params),
    getWrongQuestions: params => getRequest("wrongQuestions", params),
    saveAnswer: data => postRequest("saveAnswer", data)
  });
})();
