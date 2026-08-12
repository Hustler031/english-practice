(() => {
  const config = window.EnglishPracticeConfig;
  let sequence = 0;

  function ensureConfigured() { if (!config?.apiBaseUrl) throw new Error("API_NOT_CONFIGURED"); }

  function request(action, params = {}) {
    ensureConfigured();
    return new Promise((resolve, reject) => {
      const callback = `__epJsonp_${Date.now()}_${++sequence}`;
      const url = new URL(config.apiBaseUrl);
      url.searchParams.set("action", action);
      url.searchParams.set("v", String(config.apiVersion));
      url.searchParams.set("callback", callback);
      url.searchParams.set("_", String(Date.now()));
      Object.entries(params).forEach(([key,value]) => {
        if (value !== undefined && value !== null && value !== "") url.searchParams.set(key, String(value));
      });

      const script = document.createElement("script");
      const cleanup = () => { delete window[callback]; script.remove(); clearTimeout(timer); };
      const timer = setTimeout(() => { cleanup(); reject(new Error("API_TIMEOUT")); }, config.requestTimeoutMs);

      window[callback] = payload => {
        cleanup();
        if (payload?.ok === false) reject(new Error(payload.error || "API_ERROR"));
        else resolve(payload);
      };
      script.onerror = () => { cleanup(); reject(new Error("API_NETWORK_ERROR")); };
      script.src = url.toString();
      document.head.appendChild(script);
    });
  }

  function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

  async function saveAnswer(data) {
    ensureConfigured();

    const url = new URL(config.apiBaseUrl);
    url.searchParams.set("action", "saveAnswer");
    url.searchParams.set("v", String(config.apiVersion));
    url.searchParams.set("_", String(Date.now()));
    Object.entries(data || {}).forEach(([key, value]) => {
      if (value !== undefined && value !== null && value !== "") url.searchParams.set(key, String(value));
    });

    const beacon = document.createElement("img");
    beacon.alt = "";
    beacon.style.display = "none";
    beacon.src = url.toString();
    document.body.appendChild(beacon);
    setTimeout(() => beacon.remove(), 30000);

    for (let attempt = 0; attempt < 20; attempt++) {
      await sleep(attempt === 0 ? 1200 : 900);
      try {
        const response = await request("dailyQuiz");
        const rows = response.data || response || [];
        const found = rows.find(q => String(q.id) === String(data.questionId));
        if (found && String(found.daily?.status || "").toLowerCase() === "completed") {
          return { ok: true, data: { submitted: true, confirmed: true, questionId: data.questionId } };
        }
      } catch (_) {}
    }

    throw new Error("SAVE_NOT_CONFIRMED");
  }

  window.EnglishAPI = Object.freeze({
    getConfig: () => request("config"),
    getCategories: () => request("categories"),
    getSources: () => request("sources"),
    getDailyQuiz: () => request("dailyQuiz"),
    getQuestions: params => request("questions", params),
    getRevision: params => request("revision", params),
    getWeakQuestions: params => request("weakQuestions", params),
    getWrongQuestions: params => request("wrongQuestions", params),
    saveAnswer
  });
})();
