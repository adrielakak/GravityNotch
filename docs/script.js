(() => {
  document.documentElement.classList.add("js");
  const reduceMotionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  const reduceMotion = reduceMotionQuery.matches;
  const i18n = window.gnI18n || { t: (k) => k, onChange: () => {} };
  const t = i18n.t;

  const root = document.documentElement;
  const themeMeta = document.querySelector('meta[name="theme-color"]');
  const nav = document.getElementById("nav");
  const hero = document.querySelector(".hero");
  const heroScreen = document.querySelector(".screen");
  const heroVideo = document.querySelector(".screen-video");
  if (hero) {
    const tryPlayHero = () => {
      if (!heroVideo || reduceMotion) return;
      heroVideo.muted = true;
      heroVideo.defaultMuted = true;
      const p = heroVideo.play();
      if (p && typeof p.catch === "function") {
        p.then(() => {
          heroScreen?.classList.remove("is-paused");
        }).catch(() => {
          heroScreen?.classList.add("is-paused");
        });
      }
    };

    new IntersectionObserver(([entry]) => {
      nav?.classList.toggle("light", !entry.isIntersecting);
      if (!heroVideo || reduceMotion) return;
      if (entry.isIntersecting) tryPlayHero();
      else heroVideo.pause();
    }, { rootMargin: "-60px 0px 0px 0px" }).observe(hero);

    if (heroVideo && !reduceMotion) {
      heroVideo.addEventListener("play", () => heroScreen?.classList.remove("is-paused"));
      heroScreen?.addEventListener("click", () => {
        if (heroVideo.paused) tryPlayHero();
      });
      const resumeOnGesture = () => {
        if (heroScreen?.classList.contains("is-paused") && heroVideo.paused && hero.getBoundingClientRect().bottom > 60) {
          tryPlayHero();
        }
      };
      document.addEventListener("click", resumeOnGesture, { passive: true });
      document.addEventListener("touchend", resumeOnGesture, { passive: true });
    }

    let tintPending = false;
    const updateHeroTint = () => {
      tintPending = false;
      const atHero = hero.getBoundingClientRect().bottom > 2;
      root.classList.toggle("at-hero", atHero);
      if (themeMeta) themeMeta.content = atHero ? "#070910" : "#f5f5f7";
    };
    const scheduleHeroTint = () => {
      if (!tintPending) {
        tintPending = true;
        requestAnimationFrame(updateHeroTint);
      }
    };
    window.addEventListener("scroll", scheduleHeroTint, { passive: true });
    window.addEventListener("resize", scheduleHeroTint, { passive: true });
    window.addEventListener("pageshow", updateHeroTint);
    i18n.onChange(scheduleHeroTint);
    updateHeroTint();
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
    // A page can declare its own tracked sections with data-island-index (the docs page does)
    const declared = [...document.querySelectorAll("[data-island-index]")]
      .map((el) => ({ id: el.id, index: el.dataset.islandIndex }));
    const sections = (declared.length ? declared : [
      { id: "hero", index: "00" },
      { id: "demo", index: "01" },
      { id: "features", index: "02" },
      { id: "install", index: "03" },
      { id: "faq", index: "04" }
    ]).map((s) => ({ ...s, el: document.getElementById(s.id) })).filter((s) => s.el);

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
        const label = t(`sec.${active.id}`);
        nameEl.textContent = label;
        statusBtn.setAttribute("aria-label", t("status.label", { label }));
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

    i18n.onChange(() => { lastSectionId = undefined; scheduleUpdate(); });
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
      b.setAttribute("aria-label", t("dot.label", { n: i + 1 }));
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
      toggle?.setAttribute("aria-label", t(p ? "play.pause" : "play.play"));
      syncPlayback();
    };
    toggle?.addEventListener("click", () => setPlaying(!playing));
    document.getElementById("prev")?.addEventListener("click", () => goTo(active - 1));
    document.getElementById("next")?.addEventListener("click", () => goTo(active + 1));
    slides.forEach((slide, i) => {
      slide.querySelector(".media")?.addEventListener("click", () => {
        const v = videos[i];
        if (!v || reduceMotion) return;
        if (i !== active) goTo(i);
        else if (v.paused && playing) v.play().catch(() => {});
      });
    });

    new IntersectionObserver(([entry]) => {
      inView = entry.isIntersecting;
      syncPlayback();
    }, { threshold: 0.35 }).observe(rail);

    document.addEventListener("visibilitychange", () => {
      if (document.hidden) videos.forEach((v) => v?.pause());
      else syncPlayback();
    });

    i18n.onChange(() => {
      dots.forEach((b, i) => b.setAttribute("aria-label", t("dot.label", { n: i + 1 })));
      toggle?.setAttribute("aria-label", t(playing ? "play.pause" : "play.play"));
    });
    setPlaying(playing);
    activate(0);
  }

  document.querySelectorAll(".copy[data-copy]").forEach((copyBtn) => {
    const cmd = document.getElementById(copyBtn.dataset.copy);
    if (!cmd) return;
    copyBtn.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(cmd.textContent.trim());
        copyBtn.textContent = t("copy.done");
      } catch {
        copyBtn.textContent = t("copy.fail");
      }
      setTimeout(() => { copyBtn.textContent = t("inst.copy"); }, 1600);
    });
  });

  const revealEls = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduceMotion) {
    const io = new IntersectionObserver((entries) => {
      entries
        .filter((e) => e.isIntersecting)
        .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top || a.boundingClientRect.left - b.boundingClientRect.left)
        .forEach((e, i) => {
          e.target.style.setProperty("--reveal-delay", `${Math.min(i, 4) * 80}ms`);
          e.target.classList.add("in");
          e.target.addEventListener("transitionend", () => e.target.style.removeProperty("--reveal-delay"), { once: true });
          io.unobserve(e.target);
        });
    }, { threshold: 0, rootMargin: "0px 0px -8% 0px" });
    revealEls.forEach((el) => io.observe(el));
  } else {
    revealEls.forEach((el) => el.classList.add("in"));
  }

  const ease = "cubic-bezier(0.22, 1, 0.36, 1)";
  const sheet = "cubic-bezier(0.32, 0.72, 0, 1)";
  document.querySelectorAll(".faq details").forEach((d) => {
    const summary = d.querySelector("summary");
    const content = d.querySelector("summary ~ *");
    if (!summary) return;

    let isOpen = d.open;
    let heightAnim = null;
    let contentAnim = null;
    let span = 0;
    let pressTimer = 0;
    let releaseTimer = 0;
    let startX = 0;
    let startY = 0;
    let moved = false;

    d.classList.toggle("is-open", isOpen);

    // Enables native :active states on quick taps in iOS Safari
    summary.addEventListener("touchstart", () => {}, { passive: true });

    const clearPress = () => {
      clearTimeout(pressTimer);
      clearTimeout(releaseTimer);
      d.classList.remove("is-pressed");
    };

    summary.addEventListener("pointerdown", (e) => {
      if (reduceMotionQuery.matches) return;
      if (e.pointerType === "mouse" && e.button !== 0) return;
      clearTimeout(pressTimer);
      clearTimeout(releaseTimer);
      moved = false;
      startX = e.clientX;
      startY = e.clientY;
      if (e.pointerType === "touch") {
        pressTimer = setTimeout(() => { d.classList.add("is-pressed"); }, 40);
      } else {
        d.classList.add("is-pressed");
      }
    });

    summary.addEventListener("pointermove", (e) => {
      if (!moved && Math.hypot(e.clientX - startX, e.clientY - startY) > 8) {
        moved = true;
        clearPress();
      }
    });

    summary.addEventListener("pointercancel", clearPress);
    summary.addEventListener("pointerleave", (e) => {
      if (e.pointerType === "mouse") clearPress();
    });

    summary.addEventListener("pointerup", (e) => {
      clearTimeout(pressTimer);
      if (reduceMotionQuery.matches || moved) {
        clearPress();
        return;
      }
      if (e.pointerType === "touch") {
        if (!d.classList.contains("is-pressed")) d.classList.add("is-pressed");
        releaseTimer = setTimeout(() => { d.classList.remove("is-pressed"); }, 95);
      } else {
        clearPress();
      }
    });

    summary.addEventListener("click", (e) => {
      e.preventDefault();
      const expanding = !isOpen;
      isOpen = expanding;
      d.classList.toggle("is-open", isOpen);

      if (!d.animate) {
        d.open = isOpen;
        return;
      }

      if (reduceMotionQuery.matches) {
        const curOpacity = content && contentAnim
          ? parseFloat(getComputedStyle(content).opacity)
          : (expanding ? 0 : 1);
        heightAnim?.cancel();
        heightAnim = null;
        contentAnim?.cancel();
        contentAnim = null;

        if (expanding) {
          d.open = true;
          if (content) {
            const anim = content.animate(
              { opacity: [Number.isFinite(curOpacity) ? curOpacity : 0, 1] },
              { duration: 200, easing: "ease" }
            );
            contentAnim = anim;
            anim.onfinish = () => { if (contentAnim === anim) contentAnim = null; };
          }
        } else if (content) {
          const anim = content.animate(
            { opacity: [Number.isFinite(curOpacity) ? curOpacity : 1, 0] },
            { duration: 160, easing: "ease", fill: "forwards" }
          );
          contentAnim = anim;
          anim.onfinish = () => {
            if (contentAnim !== anim) return;
            contentAnim = null;
            if (!isOpen) d.open = false;
            anim.cancel();
          };
        } else {
          d.open = false;
        }
        return;
      }

      const wasAnimating = Boolean(heightAnim || contentAnim);

      // Read live presentation values before cancelling running animations
      let fromHeight;
      if (heightAnim) {
        try {
          heightAnim.commitStyles();
          fromHeight = parseFloat(d.style.height);
        } catch {}
        if (!Number.isFinite(fromHeight)) fromHeight = parseFloat(getComputedStyle(d).height);
        heightAnim.cancel();
        d.style.height = "";
        heightAnim = null;
      } else {
        fromHeight = parseFloat(getComputedStyle(d).height);
      }

      let fromOpacity = expanding ? 0 : 1;
      let fromTransform = expanding ? "translateY(-10px)" : "translateY(0px)";
      let fromFilter = expanding ? "blur(4px)" : "blur(0px)";
      if (content && contentAnim) {
        const cs = getComputedStyle(content);
        const op = parseFloat(cs.opacity);
        if (Number.isFinite(op)) fromOpacity = op;
        fromTransform = cs.transform === "none" ? "translateY(0px)" : cs.transform;
        fromFilter = cs.filter === "none" ? "blur(0px)" : cs.filter;
        contentAnim.cancel();
        contentAnim = null;
      }

      let toHeight;
      if (expanding) {
        d.open = true;
        toHeight = parseFloat(getComputedStyle(d).height);
      } else {
        const dCs = getComputedStyle(d);
        toHeight =
          parseFloat(getComputedStyle(summary).height) +
          parseFloat(dCs.paddingTop) +
          parseFloat(dCs.paddingBottom) +
          parseFloat(dCs.borderTopWidth) +
          parseFloat(dCs.borderBottomWidth);
      }

      const delta = Math.abs(toHeight - fromHeight);
      if (!wasAnimating) span = delta;
      else if (delta > span) span = delta;
      const ratio = span > 0 ? Math.min(1, delta / span) : 1;
      const scaleDuration = (base) => Math.max(180, Math.round(base * (0.35 + 0.65 * ratio)));

      const heightDelay = expanding ? 0 : (fromOpacity > 0.15 ? 110 : 0);
      const heightDuration = scaleDuration(expanding ? 500 : 380);

      const hAnim = d.animate(
        { height: [`${fromHeight}px`, `${toHeight}px`] },
        { duration: heightDuration, delay: heightDelay, easing: ease, fill: "backwards" }
      );
      heightAnim = hAnim;

      let cAnim = null;
      if (content) {
        if (expanding) {
          const contentDelay = fromOpacity < 0.05 && delta > 20 ? 120 : 0;
          const contentDuration = Math.max(180, Math.round(400 * Math.max(0.4, 1 - fromOpacity)));
          cAnim = content.animate(
            {
              opacity: [fromOpacity, 1],
              transform: [fromTransform, "translateY(0px)"],
              filter: [fromFilter, "blur(0px)"]
            },
            { duration: contentDuration, delay: contentDelay, easing: sheet, fill: "backwards" }
          );
          contentAnim = cAnim;
          cAnim.onfinish = () => { if (contentAnim === cAnim) contentAnim = null; };
        } else {
          const contentDuration = Math.max(60, Math.round(170 * Math.max(0.2, fromOpacity)));
          cAnim = content.animate(
            {
              opacity: [fromOpacity, 0],
              transform: [fromTransform, "translateY(-6px)"],
              filter: [fromFilter, "blur(3px)"]
            },
            { duration: contentDuration, easing: "ease-out", fill: "forwards" }
          );
          contentAnim = cAnim;
        }
      }

      hAnim.onfinish = () => {
        if (heightAnim !== hAnim) return;
        heightAnim = null;
        if (!isOpen) {
          // Collapse is complete: hide content in DOM before cancelling forwards-fill
          d.open = false;
          if (contentAnim === cAnim) {
            cAnim?.cancel();
            contentAnim = null;
          }
        }
      };
    });
  });
})();
