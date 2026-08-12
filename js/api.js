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

  function saveAnswer(data) {
    ensureConfigured();
    return new Promise((resolve, reject) => {
      const iframeName = `ep_save_${Date.now()}_${++sequence}`;
      const iframe = document.createElement("iframe");
      iframe.name = iframeName;
      iframe.style.display = "none";
      const form = document.createElement("form");
      form.method = "POST";
      form.action = config.apiBaseUrl;
      form.target = iframeName;
      form.style.display = "none";

      const fields = { action: "saveAnswer", v: String(config.apiVersion), ...data };
      Object.entries(fields).forEach(([key, value]) => {
        if (value === undefined || value === null || value === "") return;
        const input = document.createElement("input");
        input.type = "hidden";
        input.name = key;
        input.value = String(value);
        form.appendChild(input);
      });

      let settled = false;
      const cleanup = () => { iframe.remove(); form.remove(); clearTimeout(timer); };
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(new Error("SAVE_TIMEOUT"));
      }, 60000);

      iframe.addEventListener("load", () => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve({ ok: true, data: { submitted: true } });
      }, { once: true });

      document.body.appendChild(iframe);
      document.body.appendChild(form);
      form.submit();
    });
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
