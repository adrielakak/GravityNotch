(() => {
  const tint = document.querySelector(".safari-top-tint");
  const hero = document.querySelector(".hero");
  if (!tint || !hero) return;
  let pending = false;
  const update = () => {
    pending = false;
    tint.hidden = hero.getBoundingClientRect().bottom <= tint.offsetHeight + 1;
  };
  const schedule = () => {
    if (!pending) { pending = true; requestAnimationFrame(update); }
  };
  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", schedule, { passive: true });
  update();
})();
