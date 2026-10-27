"use strict";

(() => {
  const $ = id => document.getElementById(id);

  const SLOTS = [1, 2, 3, 4, 5, 6, 7, 8];

  const SLOT_LABELS = {
    1: "1限",
    2: "2限",
    3: "3限",
    4: "4限",
    5: "5限",
    6: "18:00〜19:00",
    7: "19:00〜20:00",
    8: "20:00〜21:00"
  };

  const PAGE_IDS = [
    "home-section",
    "schedule-section",
    "band-section",
    "band-create-section",
    "band-leave-section",
    "band-detail-section",
    "profile-section",
    "admin-section"
  ];

  let currentUser = null;
  let scheduleData = new Map();
  let currentDates = [];
  let loadingVersion = 0;

  function showSchedulePage(pageId) {
    for (const id of PAGE_IDS) {
      const section = $(id);
      if (section) section.hidden = id !== pageId;
    }
  }

  function showScheduleMessage(text) {
    $("schedule-message").textContent = text;
  }

  function createElement(tag, text, className = "") {
    const el = document.createElement(tag);

    if (text !== undefined) el.textContent = text;
    if (className) el.className = className;

    return el;
  }

  function formatDate(date) {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, "0");
    const day = String(date.getDate()).padStart(2, "0");

    return `${year}-${month}-${day}`;
  }

  function parseDate(value) {
    const [year, month, day] = value.split("-").map(Number);
    return new Date(year, month - 1, day);
  }

  function getDateRange(start, end) {
    const first = parseDate(start);
    const last = parseDate(end);

    if (
      Number.isNaN(first.getTime()) ||
      Number.isNaN(last.getTime())
    ) {
      throw new Error("日付を正しく入力してください。");
    }

    if (first > last) {
      throw new Error("終了日は開始日以降にしてください。");
    }

    const dates = [];
    const current = new Date(first);

    while (current <= last) {
      dates.push(formatDate(current));
      current.setDate(current.getDate() + 1);

      if (dates.length > 31) {
        throw new Error("表示期間は31日以内にしてください。");
      }
    }

    return dates;
  }

  function scheduleKey(date, slot) {
    return `${date}|${slot}`;
  }

  async function getCurrentUser() {
    const { data, error } = await db.auth.getUser();

    if (error) throw error;
    if (!data.user) throw new Error("ログインしてください。");

    currentUser = data.user;
    return currentUser;
  }

  function setDefaultDates() {
    const today = new Date();
    const end = new Date(today);

    end.setDate(end.getDate() + 6);

    $("start-date").value = formatDate(today);
    $("end-date").value = formatDate(end);
  }

  async function openSchedule() {
    showSchedulePage("schedule-section");
    setDefaultDates();
    $("schedule-results").hidden = true;

    await loadSchedule();
  }

  $("open-schedule-button").addEventListener(
    "click",
    openSchedule
  );

  $("back-home-button").addEventListener("click", () => {
    loadingVersion++;
    showSchedulePage("home-section");
  });

  $("date-range-form").addEventListener(
    "submit",
    async event => {
      event.preventDefault();
      await loadSchedule();
    }
  );

  async function loadSchedule() {
    const version = ++loadingVersion;

    const start = $("start-date").value;
    const end = $("end-date").value;

    showScheduleMessage("スケジュールを読み込み中...");

    try {
      const dates = getDateRange(start, end);
      const user = await getCurrentUser();

      const { data, error } = await db
        .from("schedules")
        .select("schedule_date, slot, available")
        .eq("user_id", user.id)
        .gte("schedule_date", start)
        .lte("schedule_date", end);

      if (error) throw error;
      if (version !== loadingVersion) return;

      currentDates = dates;
      scheduleData = new Map();

      for (const row of data || []) {
        const date = String(row.schedule_date).slice(0, 10);

        scheduleData.set(
          scheduleKey(date, Number(row.slot)),
          row.available === true
        );
      }

      renderSchedule();

      $("selected-range").textContent = `${start} ～ ${end}`;
      $("schedule-results").hidden = false;

      showScheduleMessage("");
    } catch (error) {
      if (version === loadingVersion) {
        $("schedule-results").hidden = true;
        showScheduleMessage("読み込みエラー：" + error.message);
      }
    }
  }

  function renderSchedule() {
    const table = $("schedule-table");
    const thead = table.querySelector("thead");
    const tbody = table.querySelector("tbody");

    thead.replaceChildren();
    tbody.replaceChildren();

    const weekdays = ["日", "月", "火", "水", "木", "金", "土"];

    // 横方向：8つの時間帯
    const headerRow = document.createElement("tr");
    headerRow.appendChild(createElement("th", "日付"));

    for (const slot of SLOTS) {
      headerRow.appendChild(
        createElement("th", SLOT_LABELS[slot])
      );
    }

    thead.appendChild(headerRow);

    // 縦方向：日付
    for (const date of currentDates) {
      const row = document.createElement("tr");
      const parsed = parseDate(date);

      const dateLabel =
        `${parsed.getMonth() + 1}/${parsed.getDate()}` +
        `(${weekdays[parsed.getDay()]})`;

      row.appendChild(createElement("th", dateLabel));

      for (const slot of SLOTS) {
        const td = document.createElement("td");
        const key = scheduleKey(date, slot);

        const available = scheduleData.get(key) === true;

        const cellButton = createElement(
          "button",
          available ? "〇" : "－",
          available ? "slot-button yes" : "slot-button"
        );

        cellButton.type = "button";

        cellButton.setAttribute(
          "aria-label",
          `${date} ${SLOT_LABELS[slot]}：` +
          (available ? "参加可能" : "参加不可")
        );

        cellButton.addEventListener("click", () => {
          toggleSchedule(date, slot, cellButton);
        });

        td.appendChild(cellButton);
        row.appendChild(td);
      }

      tbody.appendChild(row);
    }
  }

  async function toggleSchedule(date, slot, cellButton) {
    const user = currentUser;

    if (!user) {
      showScheduleMessage("ログイン情報がありません。");
      return;
    }

    const key = scheduleKey(date, slot);
    const oldValue = scheduleData.get(key) === true;
    const newValue = !oldValue;

    cellButton.disabled = true;
    showScheduleMessage("保存中...");

    try {
      const { data: existing, error: readError } = await db
        .from("schedules")
        .select("id")
        .eq("user_id", user.id)
        .eq("schedule_date", date)
        .eq("slot", slot)
        .limit(1);

      if (readError) throw readError;

      let saveError;

      if (existing && existing.length > 0) {
        const result = await db
          .from("schedules")
          .update({ available: newValue })
          .eq("id", existing[0].id)
          .eq("user_id", user.id);

        saveError = result.error;
      } else {
        const result = await db
          .from("schedules")
          .insert({
            user_id: user.id,
            schedule_date: date,
            slot,
            available: newValue
          });

        saveError = result.error;
      }

      if (saveError) throw saveError;

      scheduleData.set(key, newValue);

      cellButton.textContent = newValue ? "〇" : "－";
      cellButton.classList.toggle("yes", newValue);

      cellButton.setAttribute(
        "aria-label",
        `${date} ${SLOT_LABELS[slot]}：` +
        (newValue ? "参加可能" : "参加不可")
      );

      showScheduleMessage("保存しました。");
    } catch (error) {
      showScheduleMessage("保存エラー：" + error.message);
    } finally {
      cellButton.disabled = false;
    }
  }

  db.auth.onAuthStateChange(event => {
    if (event === "SIGNED_OUT") {
      loadingVersion++;
      currentUser = null;
      scheduleData.clear();
      currentDates = [];

      $("schedule-section").hidden = true;
      $("schedule-results").hidden = true;
    }
  });
})();