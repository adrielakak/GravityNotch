(() => {
  const GH = "https://github.com/TheBoredTeam/boring.notch";

  const EN = {
    "meta.title": "GravityNotch, the Dynamic Island for your Mac",
    "meta.desc": "GravityNotch turns your MacBook notch into a control center: music, lyrics on the lock screen, system HUD, text capture and AI agent tracking. Free and open source.",
    "nav.home": "GravityNotch, home",
    "nav.tagline": "The control center in your notch",
    "nav.open": "Open navigation",
    "nav.main": "Main navigation",
    "nav.cta": "Download",
    "sec.demo": "In action",
    "sec.features": "Features",
    "sec.install": "Install",
    "hero.video": "Demo: music, volume, brightness and AI agent activity appear in the notch",
    "hero.eyebrow": '<span class="dot"></span> Free and open source',
    "hero.title": '<span class="soft">The Dynamic Island</span> your Mac was missing',
    "hero.lede": "Music, live lyrics, system HUD, text capture and AI agent tracking. Everything lives in the notch, nothing clutters the Dock.",
    "hero.fine": "macOS 14 Sonoma or later · Apple Silicon and Intel",
    "cta.download": "Download for macOS",
    "cta.code": "View the code",
    "demo.title": 'One notch, <span class="soft">all your tools</span>',
    "demo.sub": "Each tool shows up at the right moment, then tucks back into the notch. Filmed as is on a MacBook.",
    "demo.carousel": "carousel",
    "demo.choose": "Choose a slide",
    "demo.prev": "Previous",
    "demo.next": "Next",
    "slide.1": "<b>Lock screen.</b> Artwork, controls and synced lyrics, even while your Mac is locked.",
    "slide.2": "<b>Music and Playing Next.</b> Hover over the notch: player, lyrics and your Apple Music queue.",
    "slide.3": "<b>System HUD.</b> Volume and brightness show up in the notch, without the macOS bubbles.",
    "slide.4": "<b>Text capture.</b> Select an area of the screen and the text is already in your clipboard.",
    "slide.5": "<b>AI agents.</b> Claude Code and Antigravity tracked live: step, context, tools.",
    "feat.title": 'And this is <span class="soft">just the beginning</span>',
    "feat.sub": "Native, written in Swift and SwiftUI. It stays out of the way until you need it.",
    "tile.1.t": "Clips",
    "tile.1.d": "Clipboard history: text, links, files and colors, with search and pinning.",
    "tile.2.t": "Shelf",
    "tile.2.d": "Drop a file into the notch, then OCR, ZIP, PNG conversion or background removal.",
    "tile.3.t": "Caffeine",
    "tile.3.d": "Keep your Mac awake for 15 min, 1 h, 2 h or indefinitely, right from the header.",
    "tile.4.t": "Audio output",
    "tile.4.d": "Switch from the MacBook speakers to AirPods or an external display in one click.",
    "tile.5.t": "Caps Lock",
    "tile.5.d": "A subtle indicator in the notch when Caps Lock turns on.",
    "tile.6.t": "Calendar",
    "tile.6.d": "Your upcoming events in the Home tab, right next to what's playing.",
    "inst.title": 'Installed <span class="soft">in a minute</span>',
    "inst.sub": "The app isn't signed with a paid Apple certificate, so macOS blocks the first launch. Here is how to allow it.",
    "step.1.t": "Install and try opening",
    "step.1.d": "Open <code>GravityNotch.dmg</code>, drag the app to <b>Applications</b>, launch it once and dismiss the warning.",
    "step.2.t": "Allow in System Settings",
    "step.2.d": "Open <b>System Settings</b> → <b>Privacy &amp; Security</b>, scroll <b>all the way down</b> and click <b>Open Anyway</b>.",
    "step.3.t": "Allow Accessibility",
    "step.3.d": "Follow the startup guide to enable Accessibility (required for the volume and brightness HUDs).",
    "inst.comment": "# If the \"Open Anyway\" button doesn't appear",
    "inst.copy": "Copy",
    "faq.title": 'Frequently asked <span class="soft">questions</span>',
    "faq.1.q": "Is GravityNotch really free?",
    "faq.1.a": "Yes. The code is released under the GNU GPL v3.0 license: you can use, read, modify and redistribute it under the terms of the license.",
    "faq.2.q": "Do I need a MacBook with a notch?",
    "faq.2.a": "No. On a display without a notch, GravityNotch shows a virtual island at the top of the screen.",
    "faq.3.q": "Which macOS versions are supported?",
    "faq.3.a": "macOS 14 Sonoma, macOS 15 Sequoia and macOS 26 Tahoe, on both Apple Silicon and Intel.",
    "faq.4.q": "Why does the app ask for Accessibility?",
    "faq.4.a": "To intercept the volume, brightness and keyboard backlight keys and show their HUD in the notch instead of the macOS bubbles.",
    "faq.5.q": "How is it related to Boring Notch?",
    "faq.5.a": `GravityNotch is a fork of <a href="${GH}" target="_blank" rel="noopener">boring.notch</a> by TheBoredTeam, who built the original architecture. GravityNotch adds the lock screen, Playing Next, OCR, Clips, Agents and more.`,
    "final.title": "Your notch can do so much more.",
    "final.sub": "Download GravityNotch and finally put it to work.",
    "final.all": "All releases",
    "footer.text": `Fork of <a href="${GH}" target="_blank" rel="noopener">boring.notch</a>, distributed under the GPL-3.0 license. Not affiliated with Apple.`,
    "footer.bug": "Report a bug"
  };

  const DYNAMIC = {
    fr: {
      "sec.hero": "Intro",
      "sec.faq": "FAQ",
      "status.label": "Section actuelle : {label}. Ouvrir la navigation",
      "slide.of": "{n} sur {total}",
      "slide.role": "diapositive",
      "dot.label": "Diapositive {n}",
      "play.pause": "Mettre en pause",
      "play.play": "Lire",
      "copy.done": "Copié",
      "copy.fail": "Échec",
      "lang.switch": "Switch to English",
      "lang.short": "EN"
    },
    en: {
      "sec.hero": "Intro",
      "sec.faq": "FAQ",
      "status.label": "Current section: {label}. Open navigation",
      "slide.of": "{n} of {total}",
      "slide.role": "slide",
      "dot.label": "Slide {n}",
      "play.pause": "Pause",
      "play.play": "Play",
      "copy.done": "Copied",
      "copy.fail": "Failed",
      "lang.switch": "Passer en français",
      "lang.short": "FR"
    }
  };

  const textNodes = [...document.querySelectorAll("[data-i18n]")];
  const attrNodes = [...document.querySelectorAll("[data-i18n-attr]")].map((el) => ({
    el,
    pairs: el.dataset.i18nAttr.split(";").map((p) => p.split(":"))
  }));

  const FR = {};
  textNodes.forEach((el) => { FR[el.dataset.i18n] ??= el.innerHTML; });
  attrNodes.forEach(({ el, pairs }) => pairs.forEach(([attr, key]) => { FR[key] ??= el.getAttribute(attr); }));
  const DICT = { fr: FR, en: EN };

  const listeners = [];
  let lang = "fr";

  const t = (key, vars = {}) => {
    const raw = DYNAMIC[lang][key] ?? DICT[lang][key] ?? FR[key] ?? key;
    return raw.replace(/\{(\w+)\}/g, (_, k) => vars[k] ?? "");
  };

  const apply = (next) => {
    lang = next === "en" ? "en" : "fr";
    document.documentElement.lang = lang;
    textNodes.forEach((el) => {
      const html = DICT[lang][el.dataset.i18n];
      if (html != null && el.innerHTML !== html) el.innerHTML = html;
    });
    attrNodes.forEach(({ el, pairs }) => pairs.forEach(([attr, key]) => {
      const v = DICT[lang][key];
      if (v != null) el.setAttribute(attr, v);
    }));
    const slides = [...document.querySelectorAll(".slide")];
    slides.forEach((s, i) => {
      s.setAttribute("aria-roledescription", t("slide.role"));
      s.setAttribute("aria-label", t("slide.of", { n: i + 1, total: slides.length }));
    });
    const toggle = document.getElementById("lang-toggle");
    if (toggle) {
      toggle.textContent = t("lang.short");
      toggle.setAttribute("aria-label", t("lang.switch"));
      toggle.lang = lang === "fr" ? "en" : "fr";
    }
    listeners.forEach((fn) => fn(lang));
  };

  const readStored = () => { try { return localStorage.getItem("gn-lang"); } catch { return null; } };
  const store = (v) => { try { localStorage.setItem("gn-lang", v); } catch {} };

  const fromUrl = new URLSearchParams(location.search).get("lang");
  const fromBrowser = (navigator.languages?.[0] || navigator.language || "fr").toLowerCase().startsWith("fr") ? "fr" : "en";
  const initial = ["fr", "en"].includes(fromUrl) ? fromUrl : (readStored() || fromBrowser);

  window.gnI18n = {
    t,
    get lang() { return lang; },
    onChange: (fn) => listeners.push(fn),
    set: (next) => { store(next); apply(next); }
  };

  document.getElementById("lang-toggle")?.addEventListener("click", () => {
    window.gnI18n.set(lang === "fr" ? "en" : "fr");
  });

  apply(initial);
})();
