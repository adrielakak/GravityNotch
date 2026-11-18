(() => {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  const island = document.getElementById("island");
  const states = ["music", "volume", "agent", "caffeine"];
  let stateIndex = 0;
  if (island && !reduceMotion) {
    setInterval(() => {
      if (document.hidden) return;
      stateIndex = (stateIndex + 1) % states.length;
      island.dataset.state = states[stateIndex];
    }, 3200);
  }

  const nav = document.getElementById("nav");
  const hero = document.querySelector(".hero");
  if (nav && hero) {
    new IntersectionObserver(([entry]) => {
      nav.classList.toggle("light", !entry.isIntersecting);
    }, { rootMargin: "-60px 0px 0px 0px" }).observe(hero);
  }

  const rail = document.getElementById("rail");
  const dotsEl = document.getElementById("dots");
  const prev = document.getElementById("prev");
  const next = document.getElementById("next");
  if (rail && dotsEl) {
    const slides = [...rail.querySelectorAll(".slide")];
    const dots = slides.map((_, i) => {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("role", "tab");
      b.setAttribute("aria-label", `Diapositive ${i + 1}`);
      b.addEventListener("click", () => goTo(i));
      dotsEl.appendChild(b);
      return b;
    });

    const current = () => {
      const left = rail.scrollLeft;
      let best = 0, bestDist = Infinity;
      slides.forEach((s, i) => {
        const d = Math.abs(s.offsetLeft - rail.offsetLeft - left - parseFloat(getComputedStyle(rail).paddingLeft));
        if (d < bestDist) { bestDist = d; best = i; }
      });
      return best;
    };
    const goTo = (i) => {
      const s = slides[Math.max(0, Math.min(slides.length - 1, i))];
      rail.scrollTo({ left: s.offsetLeft - slides[0].offsetLeft, behavior: reduceMotion ? "auto" : "smooth" });
    };
    const sync = () => {
      const i = current();
      dots.forEach((d, j) => d.setAttribute("aria-selected", String(i === j)));
      if (prev) prev.disabled = rail.scrollLeft < 4;
      if (next) next.disabled = rail.scrollLeft + rail.clientWidth >= rail.scrollWidth - 4;
    };
    let raf = 0;
    rail.addEventListener("scroll", () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(sync); }, { passive: true });
    window.addEventListener("resize", sync);
    prev?.addEventListener("click", () => goTo(current() - 1));
    next?.addEventListener("click", () => goTo(current() + 1));
    sync();
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
        e.target.style.transitionDelay = `${Math.min(siblings.indexOf(e.target), 4) * 70}ms`;
        e.target.classList.add("in");
        io.unobserve(e.target);
      });
    }, { threshold: 0.15 });
    revealEls.forEach((el) => io.observe(el));
  } else {
    revealEls.forEach((el) => el.classList.add("in"));
  }
})();
