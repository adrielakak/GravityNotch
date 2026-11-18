(() => {
  document.documentElement.classList.add("js");
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  const nav = document.getElementById("nav");
  const hero = document.querySelector(".hero");
  const heroVideo = document.querySelector(".screen-video");
  if (hero) {
    new IntersectionObserver(([entry]) => {
      nav?.classList.toggle("light", !entry.isIntersecting);
      if (!heroVideo || reduceMotion) return;
      if (entry.isIntersecting) heroVideo.play().catch(() => {});
      else heroVideo.pause();
    }, { rootMargin: "-60px 0px 0px 0px" }).observe(hero);
  }
  if (heroVideo && reduceMotion) {
    heroVideo.removeAttribute("autoplay");
    heroVideo.pause();
    heroVideo.controls = true;
  }

  /* Dynamic Island / GravityNotch morphic navbar */
  const sectionWrap = document.getElementById("island-section-wrap");
  const indexEl = document.getElementById("island-index");
  const nameEl = document.getElementById("island-section-name");
  const percentEl = document.getElementById("island-percent");
  const progressBar = document.getElementById("island-progress-bar");
  const statusBtn = document.getElementById("island-status");

  if (nav && indexEl && nameEl && percentEl && progressBar && statusBtn) {
    const navLinks = [...nav.querySelectorAll(".nav-links a[data-section]")];
    const sections = [
      { id: "hero", index: "00", label: "Intro" },
      { id: "demo", index: "01", label: "En action" },
      { id: "features", index: "02", label: "Fonctionnalités" },
      { id: "install", index: "03", label: "Installation" },
      { id: "faq", index: "04", label: "FAQ" }
    ].map((s) => ({ ...s, el: document.getElementById(s.id) })).filter((s) => s.el);

    const hoverMedia = window.matchMedia("(hover: hover) and (pointer: fine)");
    let lastSectionId = null;
    let lastScrollY = window.scrollY;
    let openedAtScrollY = 0;
    let rafPending = false;
    let lastInputWasKeyboard = false;

    const getDocTop = (el) => {
      let top = 0, node = el;
      while (node) { top += node.offsetTop; node = node.offsetParent; }
      return top;
    };

    const getActiveSection = (scrollY, maxScroll) => {
      if (maxScroll > 0 && window.innerHeight + scrollY >= document.documentElement.scrollHeight - 24) {
        return sections[sections.length - 1];
      }
      const probeY = scrollY + window.innerHeight * 0.35;
      let current = sections[0];
      for (const sec of sections) {
        if (getDocTop(sec.el) <= probeY) current = sec;
      }
      return current;
    };

    const updateIsland = () => {
      rafPending = false;
      const scrollY = window.scrollY;
      const direction = scrollY >= lastScrollY ? 1 : -1;
      lastScrollY = scrollY;

      const isCompact = scrollY > 80;
      nav.classList.toggle("island-compact", isCompact);
      if (!isCompact) {
        nav.classList.remove("island-open");
      } else if (hoverMedia.matches && nav.matches(":hover")) {
        nav.classList.add("island-open");
      } else if (!hoverMedia.matches && nav.classList.contains("island-open") && Math.abs(scrollY - openedAtScrollY) > 50) {
        nav.classList.remove("island-open");
      }

      const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
      const ratio = maxScroll > 0 ? Math.min(1, Math.max(0, scrollY / maxScroll)) : 0;
      const percent = Math.round(ratio * 100);
      progressBar.style.width = `${(ratio * 100).toFixed(1)}%`;
      percentEl.textContent = `${percent}%`;

      if (!sections.length) return;
      const active = getActiveSection(scrollY, maxScroll);
      navLinks.forEach((link) => {
        link.classList.toggle("active-nav", link.dataset.section === active.id);
      });

      if (active.id !== lastSectionId) {
        indexEl.textContent = active.index;
        nameEl.textContent = active.label;
        statusBtn.setAttribute("aria-label", `Section actuelle : ${active.label}. Ouvrir la navigation`);
        if (lastSectionId !== null && sectionWrap && !reduceMotion && sectionWrap.animate) {
          sectionWrap.animate(
            [{ transform: `translateY(${direction * 6}px)`, opacity: 0 }, { transform: "translateY(0)", opacity: 1 }],
            { duration: 220, easing: "cubic-bezier(0.22, 1, 0.36, 1)" }
          );
        }
        lastSectionId = active.id;
      }
    };

    const scheduleUpdate = () => {
      if (!rafPending) {
        rafPending = true;
        requestAnimationFrame(updateIsland);
      }
    };

    document.addEventListener("keydown", (e) => {
      if (e.key === "Tab" || e.key === "Enter" || e.key === " ") lastInputWasKeyboard = true;
    }, true);
    document.addEventListener("pointerdown", () => { lastInputWasKeyboard = false; }, true);

    window.addEventListener("scroll", scheduleUpdate, { passive: true });
    window.addEventListener("resize", scheduleUpdate, { passive: true });

    nav.addEventListener("pointerenter", (e) => {
      if (hoverMedia.matches && e.pointerType !== "touch" && nav.classList.contains("island-compact")) {
        nav.classList.add("island-open");
      }
    });
    nav.addEventListener("pointerleave", (e) => {
      if (hoverMedia.matches && e.pointerType !== "touch") {
        nav.classList.remove("island-open");
      }
    });

    nav.addEventListener("click", (e) => {
      if (nav.classList.contains("island-compact") && !nav.classList.contains("island-open")) {
        e.preventDefault();
        e.stopPropagation();
        nav.classList.add("island-open");
        openedAtScrollY = window.scrollY;
        if (!lastInputWasKeyboard && document.activeElement && nav.contains(document.activeElement)) {
          document.activeElement.blur();
        }
      }
    }, true);

    const brandLink = nav.querySelector(".brand");
    brandLink?.addEventListener("click", () => {
      nav.classList.remove("island-open");
      if (!lastInputWasKeyboard) brandLink.blur();
    });

    statusBtn.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        if (nav.classList.contains("island-compact")) {
          nav.classList.toggle("island-open");
          if (nav.classList.contains("island-open")) openedAtScrollY = window.scrollY;
        }
      }
    });

    nav.querySelectorAll(".nav-links a, .nav-cta").forEach((link) => {
      link.addEventListener("click", (e) => {
        nav.classList.remove("island-open");
        if (!lastInputWasKeyboard || e.detail > 0) e.currentTarget.blur();
      });
    });

    document.addEventListener("pointerdown", (e) => {
      if (!nav.contains(e.target)) {
        nav.classList.remove("island-open");
        if (document.activeElement && nav.contains(document.activeElement)) {
          document.activeElement.blur();
        }
      }
    });

    updateIsland();
  }

  const rail = document.getElementById("rail");
  const dotsEl = document.getElementById("dots");
  if (rail && dotsEl) {
    const slides = [...rail.querySelectorAll(".slide")];
    const videos = slides.map((s) => s.querySelector("video"));
    const toggle = document.getElementById("playpause");
    let active = -1;
    let playing = !reduceMotion;
    let inView = false;
    let programmaticScroll = false;
    let settleTimer = 0;

    const dots = slides.map((_, i) => {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("role", "tab");
      b.setAttribute("aria-label", `Diapositive ${i + 1}`);
      b.addEventListener("click", () => goTo(i));
      dotsEl.appendChild(b);
      return b;
    });

    const offsetOf = (i) => slides[i].offsetLeft - slides[0].offsetLeft;

    const syncPlayback = () => {
      videos.forEach((v, i) => {
        if (!v) return;
        if (i === active && playing && inView) v.play().catch(() => {});
        else v.pause();
      });
    };

    const activate = (i) => {
      if (i === active) return;
      const prev = videos[active];
      if (prev) { prev.pause(); prev.currentTime = 0; }
      dots[active]?.style.setProperty("--p", 0);
      active = i;
      slides.forEach((s, j) => s.classList.toggle("is-active", j === i));
      dots.forEach((d, j) => d.setAttribute("aria-selected", String(j === i)));
      const next = videos[(i + 1) % videos.length];
      if (next && next.preload === "none") next.preload = "auto";
      const cur = videos[i];
      if (cur) { cur.preload = "auto"; cur.currentTime = 0; }
      syncPlayback();
    };

    const goTo = (i) => {
      const n = (i + slides.length) % slides.length;
      activate(n);
      programmaticScroll = true;
      rail.scrollTo({ left: offsetOf(n), behavior: reduceMotion ? "auto" : "smooth" });
      clearTimeout(settleTimer);
      settleTimer = setTimeout(() => { programmaticScroll = false; }, 900);
    };

    const nearest = () => {
      const max = rail.scrollWidth - rail.clientWidth;
      if (rail.scrollLeft >= max - 4) return slides.length - 1;
      let best = 0, bestDist = Infinity;
      slides.forEach((_, i) => {
        const d = Math.abs(offsetOf(i) - rail.scrollLeft);
        if (d < bestDist) { bestDist = d; best = i; }
      });
      return best;
    };

    rail.addEventListener("scroll", () => {
      clearTimeout(settleTimer);
      settleTimer = setTimeout(() => {
        if (!programmaticScroll) activate(nearest());
        programmaticScroll = false;
      }, 140);
    }, { passive: true });

    videos.forEach((v, i) => {
      if (!v) return;
      v.addEventListener("ended", () => {
        if (i !== active) return;
        if (playing) goTo(active + 1);
      });
    });

    const tick = () => {
      const v = videos[active];
      if (v && v.duration) dots[active].style.setProperty("--p", (v.currentTime / v.duration).toFixed(4));
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);

    const setPlaying = (p) => {
      playing = p;
      toggle?.classList.toggle("paused", !p);
      toggle?.setAttribute("aria-label", p ? "Mettre en pause" : "Lire");
      syncPlayback();
    };
    toggle?.addEventListener("click", () => setPlaying(!playing));
    document.getElementById("prev")?.addEventListener("click", () => goTo(active - 1));
    document.getElementById("next")?.addEventListener("click", () => goTo(active + 1));

    new IntersectionObserver(([entry]) => {
      inView = entry.isIntersecting;
      syncPlayback();
    }, { threshold: 0.35 }).observe(rail);

    document.addEventListener("visibilitychange", () => {
      if (document.hidden) videos.forEach((v) => v?.pause());
      else syncPlayback();
    });

    setPlaying(playing);
    activate(0);
  }

  const copyBtn = document.getElementById("copy");
  const cmd = document.getElementById("cmd");
  if (copyBtn && cmd) {
    copyBtn.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(cmd.textContent.trim());
        copyBtn.textContent = "Copié";
      } catch {
        copyBtn.textContent = "Échec";
      }
      setTimeout(() => { copyBtn.textContent = "Copier"; }, 1600);
    });
  }

  const revealEls = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduceMotion) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (!e.isIntersecting) return;
        const siblings = [...e.target.parentElement.children].filter((c) => c.classList.contains("reveal"));
        e.target.style.transitionDelay = `${Math.min(siblings.indexOf(e.target), 5) * 70}ms`;
        e.target.classList.add("in");
        io.unobserve(e.target);
      });
    }, { threshold: 0.15 });
    revealEls.forEach((el) => io.observe(el));
  } else {
    revealEls.forEach((el) => el.classList.add("in"));
  }
})();
