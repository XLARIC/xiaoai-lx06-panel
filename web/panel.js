"use strict";
const locationForm = document.querySelector("#location");
const audioForm = document.querySelector("#audio");
const notice = document.querySelector("#notice");
const target = audioForm.elements.target;
let current;

function message(text, error = false) {
  notice.textContent = text;
  notice.classList.toggle("error", error);
}

async function api(path, body) {
  const options = body === undefined ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-LX06-Panel": "1" },
    body: JSON.stringify(body)
  };
  const response = await fetch("/api/" + path, options);
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.error || "无法读取小爱，请刷新后重试");
  return result;
}

function options(devices, selected) {
  const choices = new Map(devices.map(device => [device.mac, device.name]));
  if (!choices.has(selected)) choices.set(selected, selected === "-" ? "请选择外接音箱" : selected);
  target.replaceChildren(...Array.from(choices, ([mac, name]) => new Option(name, mac)));
  target.value = selected;
}

function modeChanged() {
  const receive = audioForm.elements.mode.value === "receive";
  document.querySelector("#output-controls").hidden = receive;
  document.querySelector("#receive-note").hidden = !receive;
}

async function load() {
  current = await api("state");
  for (const [key, value] of Object.entries(current.position || { latitude: "", longitude: "", timeZone: "" })) locationForm.elements[key].value = value;
  locationForm.elements.consent.checked = false;
  audioForm.elements.mode.value = current.audio.mode;
  audioForm.elements.delay.value = current.audio.delay;
  options([], current.audio.target);
  modeChanged();
  document.querySelector("#connection").textContent = current.audio.mode === "receive"
    ? "接收模式已保存。在手机上选择小爱。"
    : current.linked ? "外接音箱已连接 · 同步输出已就绪" : "外接音箱尚未就绪";
}

async function run(working, fn) {
  document.querySelectorAll("button").forEach(button => { button.disabled = true; });
  message(working);
  try {
    message(await fn());
  } catch (error) {
    message(error.message, true);
  } finally {
    document.querySelectorAll("button").forEach(button => { button.disabled = false; });
  }
}

locationForm.addEventListener("submit", event => {
  event.preventDefault();
  const values = locationForm.elements;
  const body = {
    latitude: values.latitude.valueAsNumber,
    longitude: values.longitude.valueAsNumber,
    timeZone: values.timeZone.value.trim(),
    consent: values.consent.checked
  };
  run("正在保存位置…", async () => {
    const result = await api("location", body);
    values.consent.checked = false;
    return result.message;
  });
});
audioForm.addEventListener("change", modeChanged);
audioForm.addEventListener("submit", event => {
  event.preventDefault();
  if (!current) return;
  const values = audioForm.elements;
  const body = { mode: values.mode.value, target: target.value, delay: values.delay.valueAsNumber };
  run("正在应用蓝牙设置…", async () => {
    const result = await api("audio", body);
    await load();
    return result.message;
  });
});
document.querySelector("#refresh").addEventListener("click", () => run("正在读取小爱…", async () => {
  await load();
  return "已读取当前设置。";
}));
for (const id of ["paired", "scan"]) {
  document.querySelector("#" + id).addEventListener("click", () => run(id === "scan" ? "正在搜索附近设备，约 8 秒…" : "正在读取已配对设备…", async () => {
    if (!current) return "请先刷新设置。";
    const result = await api("devices", { scan: id === "scan" });
    options(result.devices, target.value || current.audio.target);
    return result.devices.length ? "请选择要连接的音箱，再应用设置。" : "没有发现新设备，请检查外接音箱的配对状态。";
  }));
}
const datalist = document.querySelector("#zones");
if (Intl.supportedValuesOf) {
  datalist.replaceChildren(...Intl.supportedValuesOf("timeZone").map(zone => new Option(zone, zone)));
}
run("正在读取小爱设置…", async () => { await load(); return "已读取当前设置。"; });
