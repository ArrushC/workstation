(function () {
    "use strict";

    // ============================================================
    // F1. Capability gates + Prefs (foundation for all FX tasks)
    // ============================================================
    var reduceQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
    var fineQuery   = window.matchMedia("(pointer: fine)");
    function loadPref(k, d){ try{ var v=localStorage.getItem(k); return v===null?d:v==="1"; }catch(e){ return d; } }
    function savePref(k, v){ try{ localStorage.setItem(k, v?"1":"0"); }catch(e){} }
    var Prefs = {
        motion: loadPref("readme-motion", true), // default ON for everyone; the ◉ toggle is a true override (OS reduced-motion no longer hard-disables — toggle off or no-JS gives the full static fallback)
        sound:  loadPref("readme-sound", false)                  // default OFF
    };
    function fxEnabled(){ return Prefs.motion; } // OS reduced-motion sets no hard gate now; it's honored via CSS only when motion is OFF (no .fx-on)
    function pointerFx(){ return fxEnabled() && fineQuery.matches; }

    // ============================================================
    // F2. Shared rAF Scheduler (single loop for ALL FX subsystems)
    // ============================================================
    var Scheduler = (function(){
        var subs = []; var running = false;
        function frame(t){ running = false;
            if(document.hidden) return;
            var snap = subs.slice();
            for(var i=0;i<snap.length;i++){ try{ snap[i](t); }catch(e){} }
            if(subs.length){ running = true; requestAnimationFrame(frame); }
        }
        return {
            add:function(fn){ if(subs.indexOf(fn)<0) subs.push(fn); this.kick(); },
            remove:function(fn){ var i=subs.indexOf(fn); if(i>=0) subs.splice(i,1); },
            kick:function(){ if(!running && subs.length && !document.hidden){ running=true; requestAnimationFrame(frame); } }
        };
    })();
    document.addEventListener("visibilitychange", function(){ if(!document.hidden) Scheduler.kick(); });

    // ============================================================
    // 1. Theme toggle (auto / light / dark) with localStorage
    // ============================================================
    const themeToggle = document.getElementById("theme-toggle");
    const themeIcon = document.getElementById("theme-icon");
    const html = document.documentElement;
    const themes = ["auto", "light", "dark"];
    const icons = { auto: "◐", light: "☀", dark: "☾" };
    const labels = {
        auto: "Theme: auto (follows system)",
        light: "Theme: light",
        dark: "Theme: dark",
    };

    function applyTheme(t) {
        html.setAttribute("data-theme", t);
        themeIcon.textContent = icons[t];
        themeToggle.setAttribute("title", labels[t]);
        themeToggle.setAttribute("aria-label", labels[t]);
    }
    let current = localStorage.getItem("readme-theme") || "auto";
    if (!themes.includes(current)) current = "auto";
    applyTheme(current);
    themeToggle.addEventListener("click", () => {
        current =
            themes[(themes.indexOf(current) + 1) % themes.length];
        localStorage.setItem("readme-theme", current);
        applyTheme(current);
    });

    // ============================================================
    // 2. Copy-to-clipboard buttons on every <pre>
    // ============================================================
    document.querySelectorAll("pre").forEach((pre) => {
        const btn = document.createElement("button");
        btn.className = "copy-btn";
        btn.type = "button";
        btn.textContent = "Copy";
        btn.setAttribute("aria-label", "Copy code to clipboard");
        pre.appendChild(btn);
        btn.addEventListener("click", async (e) => {
            e.preventDefault();
            const code = pre.querySelector("code");
            const text = code
                ? code.innerText
                : pre.innerText.replace(/Copy$/, "").trimEnd();
            try {
                await navigator.clipboard.writeText(text);
                btn.textContent = "Copied!";
                btn.classList.add("copied");
                setTimeout(() => {
                    btn.textContent = "Copy";
                    btn.classList.remove("copied");
                }, 1500);
            } catch (_) {
                btn.textContent = "Failed";
                setTimeout(() => {
                    btn.textContent = "Copy";
                }, 1500);
            }
        });
    });

    // ============================================================
    // 3. Anchor link icons on h2/h3/h4 with an id
    // ============================================================
    document
        .querySelectorAll("main h2[id], main h3[id], main h4[id]")
        .forEach((h) => {
            const a = document.createElement("a");
            a.className = "heading-anchor";
            a.href = "#" + h.id;
            a.textContent = "#";
            a.setAttribute(
                "aria-label",
                "Link to " + (h.textContent || "").trim(),
            );
            h.appendChild(a);
        });

    // ============================================================
    // 4. Scroll-spy TOC
    // ============================================================
    const tocLinks = Array.from(
        document.querySelectorAll('nav.toc a[href^="#"]'),
    );
    const linkByHash = new Map(
        tocLinks.map((a) => [a.getAttribute("href"), a]),
    );
    const observed = Array.from(
        document.querySelectorAll("main section[id], main h3[id]"),
    );

    function setActive(hash) {
        tocLinks.forEach((a) => a.classList.remove("active"));
        tocLinks.forEach((a) => a.removeAttribute("aria-current"));
        const link = linkByHash.get(hash);
        if (link) {
            link.classList.add("active");
            link.setAttribute("aria-current", "location");
        }
    }

    const visible = new Set();
    const io = new IntersectionObserver(
        (entries) => {
            entries.forEach((e) => {
                const id = "#" + e.target.id;
                if (e.isIntersecting) visible.add(id);
                else visible.delete(id);
            });
            // Pick the first (topmost) visible target with a TOC link
            const ordered = observed
                .map((el) => "#" + el.id)
                .filter(
                    (id) => visible.has(id) && linkByHash.has(id),
                );
            if (ordered.length) setActive(ordered[0]);
        },
        { rootMargin: "-10% 0px -70% 0px", threshold: 0 },
    );
    observed.forEach((el) => io.observe(el));

    // Delegated in-page anchor handler. Intercepts clicks on any
    // <a href="#..."> (TOC links, heading-# icons, hero shortcuts)
    // and scrolls manually via scrollIntoView + history.pushState.
    // Why: Chromium logs "Unsafe attempt to load URL ... 'file:'
    // URLs are treated as unique security origins" on every default
    // fragment navigation when the page is opened from disk. Manual
    // scroll + History API updates the URL without triggering a
    // navigation, so no warning. Also sets the TOC active state
    // immediately for snappy feel — no need for the old 50ms timer.
    document.addEventListener("click", (e) => {
        const link = e.target.closest('a[href^="#"]');
        if (!link) return;
        const hash = link.getAttribute("href");
        if (!hash || hash === "#" || hash.length < 2) return;
        const target = document.getElementById(hash.slice(1));
        if (!target) return;
        e.preventDefault();
        target.scrollIntoView({ behavior: "smooth", block: "start" });
        if (history.pushState) history.pushState(null, "", hash);
        if (link.matches("nav.toc a")) setActive(hash);
    });

    // ============================================================
    // 5. Global search — highlight matches + dim sections without
    // ============================================================
    const globalSearch = document.getElementById("global-search");
    const tocSearchMeta =
        document.getElementById("toc-search-meta");
    const sections = Array.from(
        document.querySelectorAll("main section"),
    );
    // Map sections to their TOC links (top-level entry)
    const sectionToTopLink = new Map(
        sections.map((s) => [
            s,
            linkByHash.get("#" + s.id) || null,
        ]),
    );

    function clearHighlights() {
        document.querySelectorAll("main mark").forEach((m) => {
            const parent = m.parentNode;
            parent.replaceChild(
                document.createTextNode(m.textContent),
                m,
            );
            parent.normalize();
        });
    }

    function highlightInNode(node, regex) {
        if (node.nodeType === Node.TEXT_NODE) {
            const text = node.nodeValue;
            if (!regex.test(text)) return 0;
            regex.lastIndex = 0;
            const frag = document.createDocumentFragment();
            let lastIndex = 0;
            let match;
            let hits = 0;
            while ((match = regex.exec(text)) !== null) {
                if (match.index > lastIndex)
                    frag.appendChild(
                        document.createTextNode(
                            text.slice(lastIndex, match.index),
                        ),
                    );
                const mark = document.createElement("mark");
                mark.textContent = match[0];
                frag.appendChild(mark);
                lastIndex = match.index + match[0].length;
                hits++;
                if (match.index === regex.lastIndex)
                    regex.lastIndex++;
            }
            if (lastIndex < text.length)
                frag.appendChild(
                    document.createTextNode(text.slice(lastIndex)),
                );
            node.parentNode.replaceChild(frag, node);
            return hits;
        } else if (node.nodeType === Node.ELEMENT_NODE) {
            // Skip already-marked, inputs, scripts, styles
            const skip = [
                "MARK",
                "SCRIPT",
                "STYLE",
                "INPUT",
                "BUTTON",
                "TEXTAREA",
            ];
            if (skip.includes(node.tagName)) return 0;
            let total = 0;
            Array.from(node.childNodes).forEach((child) => {
                total += highlightInNode(child, regex);
            });
            return total;
        }
        return 0;
    }

    function escapeRegex(s) {
        return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }

    function runGlobalSearch(query) {
        clearHighlights();
        sections.forEach((s) => s.classList.remove("dimmed"));
        tocLinks.forEach((a) => {
            const li = a.closest("li");
            if (li) li.classList.remove("hidden");
        });
        if (!query) {
            tocSearchMeta.textContent = "";
            return;
        }
        const regex = new RegExp(escapeRegex(query), "gi");
        let totalHits = 0;
        let matchedSections = 0;
        sections.forEach((s) => {
            const hits = highlightInNode(
                s,
                new RegExp(escapeRegex(query), "gi"),
            );
            if (hits > 0) {
                matchedSections++;
                totalHits += hits;
            } else {
                s.classList.add("dimmed");
                const link = sectionToTopLink.get(s);
                if (link) {
                    const li = link.closest("li");
                    if (li) li.classList.add("hidden");
                }
            }
        });
        tocSearchMeta.textContent = totalHits
            ? totalHits +
              " match" +
              (totalHits === 1 ? "" : "es") +
              " in " +
              matchedSections +
              " section" +
              (matchedSections === 1 ? "" : "s")
            : "No matches";
    }

    let searchDebounce;
    globalSearch.addEventListener("input", () => {
        clearTimeout(searchDebounce);
        searchDebounce = setTimeout(
            () => runGlobalSearch(globalSearch.value.trim()),
            120,
        );
    });

    // ============================================================
    // 6. Keyboard shortcuts: '/' focuses search, Esc clears
    // ============================================================
    document.addEventListener("keydown", (e) => {
        const isTyping = ["INPUT", "TEXTAREA", "SELECT"].includes(
            document.activeElement.tagName,
        );
        if (
            e.key === "/" &&
            !isTyping &&
            !e.metaKey &&
            !e.ctrlKey &&
            !e.altKey
        ) {
            e.preventDefault();
            globalSearch.focus();
            globalSearch.select();
        }
        if (e.key === "Escape") {
            if (
                document.activeElement === globalSearch &&
                globalSearch.value
            ) {
                globalSearch.value = "";
                runGlobalSearch("");
            } else if (
                document.activeElement ===
                    document.getElementById("tool-filter") &&
                document.getElementById("tool-filter").value
            ) {
                document.getElementById("tool-filter").value = "";
                runToolFilter("");
            } else if (
                document.activeElement ===
                    document.getElementById("ts-filter") &&
                document.getElementById("ts-filter").value
            ) {
                document.getElementById("ts-filter").value = "";
                runToolFilter.tsUpdate && runToolFilter.tsUpdate();
            } else {
                document.activeElement.blur();
            }
        }
    });

    // ============================================================
    // 7. Toolbelt filter — dim non-matching cards, highlight chips
    // ============================================================
    const toolFilter = document.getElementById("tool-filter");
    const toolFilterMeta =
        document.getElementById("tool-filter-meta");
    const toolCards = Array.from(
        document.querySelectorAll("#toolbelt-grid .tool-card"),
    );

    function runToolFilter(q) {
        q = q.trim().toLowerCase();
        let visibleCards = 0;
        let matchedChips = 0;
        toolCards.forEach((card) => {
            card.classList.remove("dimmed");
            const chips = card.querySelectorAll(".chip");
            let cardHas = false;
            chips.forEach((c) => {
                c.classList.remove("match-hit");
                if (!q) return;
                const name = c.textContent.toLowerCase();
                const tip = (
                    c.getAttribute("data-tip") || ""
                ).toLowerCase();
                const cat = (
                    card.getAttribute("data-cat") || ""
                ).toLowerCase();
                const heading = (
                    card.querySelector("h4").textContent || ""
                ).toLowerCase();
                if (
                    name.includes(q) ||
                    tip.includes(q) ||
                    cat.includes(q) ||
                    heading.includes(q)
                ) {
                    c.classList.add("match-hit");
                    matchedChips++;
                    cardHas = true;
                }
            });
            if (q && !cardHas) card.classList.add("dimmed");
            else visibleCards++;
        });
        if (!q) {
            toolFilterMeta.textContent = "";
            toolFilterMeta.classList.remove("no-match");
        } else if (matchedChips === 0) {
            toolFilterMeta.textContent = "No matches";
            toolFilterMeta.classList.add("no-match");
        } else {
            const t = matchedChips === 1 ? "tool" : "tools";
            const c = visibleCards === 1 ? "cat" : "cats";
            toolFilterMeta.textContent =
                matchedChips +
                " " +
                t +
                " · " +
                visibleCards +
                " " +
                c;
            toolFilterMeta.classList.remove("no-match");
        }
    }
    toolFilter.addEventListener("input", () =>
        runToolFilter(toolFilter.value),
    );

    // ============================================================
    // 8. Troubleshooting filter (existing)
    // ============================================================
    const tsFilter = document.getElementById("ts-filter");
    const tsCount = document.getElementById("ts-count");
    const tsItems = Array.from(
        document.querySelectorAll("[data-ts]"),
    );

    function tsUpdate() {
        const q = tsFilter.value.trim().toLowerCase();
        let shown = 0;
        tsItems.forEach((d) => {
            if (!q) {
                d.hidden = false;
                d.open = false;
            } else {
                const match = d.textContent
                    .toLowerCase()
                    .includes(q);
                d.hidden = !match;
                d.open = match;
                if (match) shown++;
            }
        });
        if (!q) {
            tsCount.textContent = "";
            tsCount.classList.remove("no-match");
        } else if (shown === 0) {
            tsCount.textContent = "No matches";
            tsCount.classList.add("no-match");
        } else {
            tsCount.textContent = shown + " / " + tsItems.length;
            tsCount.classList.remove("no-match");
        }
    }
    tsFilter.addEventListener("input", tsUpdate);
    runToolFilter.tsUpdate = tsUpdate; // expose for Esc handler above

    // ============================================================
    // 9. Mobile TOC collapse toggle
    // ============================================================
    const tocCollapseCtrl =
        document.getElementById("toc-collapse-ctrl");
    const tocEl = document.getElementById("toc");
    function syncTocCollapsed() {
        if (window.matchMedia("(max-width: 900px)").matches) {
            tocEl.classList.add("mobile-collapsed");
            tocCollapseCtrl.setAttribute("aria-expanded", "false");
        } else {
            tocEl.classList.remove("mobile-collapsed");
            tocCollapseCtrl.setAttribute("aria-expanded", "true");
        }
    }
    syncTocCollapsed();
    window.addEventListener("resize", syncTocCollapsed);
    tocCollapseCtrl.addEventListener("click", () => {
        const isCollapsed =
            tocEl.classList.toggle("mobile-collapsed");
        tocCollapseCtrl.setAttribute(
            "aria-expanded",
            String(!isCollapsed),
        );
    });

    // ============================================================
    // 10. Reading-progress bar (top of viewport)
    //
    // Drives the --scroll-progress CSS custom property on the
    // <div class="scroll-progress"> element (0..1 fraction of doc
    // height scrolled). rAF-throttled so passive scroll listeners
    // never block the main thread.
    // ============================================================
    const progressEl = document.getElementById("scroll-progress");
    if (progressEl) {
        let ticking = false;
        function paintProgress() {
            const max =
                (document.documentElement.scrollHeight ||
                    document.body.scrollHeight) -
                window.innerHeight;
            const ratio =
                max > 0
                    ? Math.min(1, Math.max(0, window.scrollY / max))
                    : 0;
            progressEl.style.setProperty(
                "--scroll-progress",
                ratio.toFixed(4),
            );
            ticking = false;
        }
        window.addEventListener(
            "scroll",
            () => {
                if (!ticking) {
                    requestAnimationFrame(paintProgress);
                    ticking = true;
                }
            },
            { passive: true },
        );
        window.addEventListener("resize", paintProgress);
        paintProgress();
    }

    // ============================================================
    // F3. Motion + sound toggle wiring
    // ============================================================
    var motionBtn = document.getElementById("motion-toggle");
    var soundBtn  = document.getElementById("sound-toggle");
    function reflectMotion(){
        if(motionBtn){ motionBtn.setAttribute("aria-pressed", String(Prefs.motion)); motionBtn.textContent = Prefs.motion ? "◉" : "○"; }
        document.documentElement.classList.toggle("fx-off", !fxEnabled());
        document.documentElement.classList.toggle("fx-on", fxEnabled());
        // readme:fxchange is dispatched on window — consumers must use window.addEventListener("readme:fxchange", ...)
        window.dispatchEvent(new CustomEvent("readme:fxchange"));
    }
    function reflectSound(){ if(soundBtn){ soundBtn.setAttribute("aria-pressed", String(Prefs.sound)); soundBtn.textContent = Prefs.sound ? "♪" : "♪̶"; } }
    if(motionBtn) motionBtn.addEventListener("click", function(){ Prefs.motion=!Prefs.motion; savePref("readme-motion",Prefs.motion); reflectMotion(); });
    if(soundBtn)  soundBtn.addEventListener("click",  function(){ Prefs.sound=!Prefs.sound;  savePref("readme-sound",Prefs.sound);  reflectSound(); });
    if(reduceQuery.addEventListener) reduceQuery.addEventListener("change", reflectMotion);
    else if(reduceQuery.addListener) reduceQuery.addListener(reflectMotion);
    reflectMotion(); reflectSound();

    /* 20 — ambient SFX (opt-in, synthesized; primed on first user gesture so it never autoplays) */
    var SFX = (function(){
      var actx=null, master=null, primed=false;
      function prime(){
        if(primed) return;
        var AC = window.AudioContext || window.webkitAudioContext; if(!AC) return;
        try{ actx=new AC(); master=actx.createGain(); master.gain.value=0.05; master.connect(actx.destination); primed=true; }catch(e){ actx=null; }
      }
      function blip(freq, dur, type){
        if(!Prefs.sound || !actx) return;             // silent unless enabled AND primed by a gesture
        if(actx.state==="suspended"){ actx.resume(); }
        var o=actx.createOscillator(), g=actx.createGain();
        o.type=type||"sine"; o.frequency.value=freq;
        var t0=actx.currentTime;
        g.gain.setValueAtTime(0.0001, t0);
        g.gain.exponentialRampToValueAtTime(0.6, t0+0.01);
        g.gain.exponentialRampToValueAtTime(0.0001, t0+(dur||0.12));
        o.connect(g); g.connect(master); o.start(t0); o.stop(t0+(dur||0.12)+0.02);
      }
      return {
        prime: prime,
        hover: function(){ blip(880, 0.06, "sine"); },
        click: function(){ blip(420, 0.14, "triangle"); },
        boot:  function(){ blip(180, 0.5,  "sawtooth"); }
      };
    })();
    // prime the AudioContext on the FIRST real user gesture (so creation happens in a gesture context → no autoplay warning)
    (function(){
      function primeOnce(){ SFX.prime(); window.removeEventListener("pointerdown", primeOnce, true); window.removeEventListener("keydown", primeOnce, true); }
      window.addEventListener("pointerdown", primeOnce, true);
      window.addEventListener("keydown", primeOnce, true);
    })();
    // click + (throttled) hover blips — gated inside blip() on Prefs.sound
    document.addEventListener("pointerdown", function(){ SFX.click(); });
    var _lastHover=0;
    document.addEventListener("pointerover", function(e){
      if(!Prefs.sound) return;
      if(!e.target || !e.target.closest || !e.target.closest("a,button,.chip,.tool-card,summary")) return;
      var t=Date.now(); if(t-_lastHover>70){ _lastHover=t; SFX.hover(); }
    });

    /* 13 — mouse-parallax world + hero terminal tilt */
    (function initParallax(){
        var stars = document.querySelector(".gw-stars");
        var floor = document.querySelector(".gw-floorwrap");
        var disc  = document.querySelector(".hero-disc");
        var term  = document.querySelector(".term[data-typed]");
        var root  = document.documentElement;
        if(!stars && !floor && !term && !disc) return;
        var px=0, py=0, tx=0, ty=0, active=false;
        function onMove(e){ px = e.clientX/window.innerWidth - 0.5; py = e.clientY/window.innerHeight - 0.5; }
        function tick(){
            tx += (px - tx) * 0.06; ty += (py - ty) * 0.06;
            root.style.setProperty("--p-x", tx.toFixed(4));
            root.style.setProperty("--p-y", ty.toFixed(4));
            if(term) term.style.transform = "rotateY(" + (tx*8) + "deg) rotateX(" + (-ty*8) + "deg)";
        }
        function enable(){ if(active || !pointerFx()) return; active=true; window.addEventListener("pointermove", onMove, {passive:true}); Scheduler.add(tick); }
        function disable(){ if(!active) return; active=false; window.removeEventListener("pointermove", onMove);
            Scheduler.remove(tick); root.style.setProperty("--p-x","0"); root.style.setProperty("--p-y","0"); if(term) term.style.transform=""; }
        window.addEventListener("readme:fxchange", function(){ pointerFx() ? enable() : disable(); });
        enable();
    })();

    /* ============================================================
     * FX canvas singleton (shared by trail + click ripples)
     * ============================================================ */
    var FX = (function(){
        var cv = document.getElementById("fx-canvas"); if(!cv) return null;
        var ctx = cv.getContext("2d"), W=0, H=0, DPR=1;
        function size(){ DPR=Math.min(2, window.devicePixelRatio||1); W=window.innerWidth; H=window.innerHeight;
            cv.width=W*DPR; cv.height=H*DPR; cv.style.width=W+"px"; cv.style.height=H+"px"; ctx.setTransform(DPR,0,0,DPR,0,0); }
        window.addEventListener("resize", size); size();
        return { get ctx(){ return ctx; }, get W(){ return W; }, get H(){ return H; }, clear:function(){ ctx.clearRect(0,0,W,H); } };
    })();
    var fxDrawers = [];
    function fxLoop(){
        if(!FX) return;
        FX.clear();
        var anyActive = false;
        for(var i=0;i<fxDrawers.length;i++){ try{ if(fxDrawers[i](FX.ctx)) anyActive = true; }catch(e){} }
        if(!anyActive){ Scheduler.remove(fxLoop); FX.clear(); }   // self-quiesce when idle
    }

    /* ============================================================
     * 14 — cursor light-trail + reticle (the trail head is the reticle)
     * ============================================================ */
    (function initTrail(){
        if(!FX) return;
        var trail=[], rx=-1, ry=-1, active=false;
        function onMove(e){ rx=e.clientX; ry=e.clientY; trail.push({x:rx,y:ry}); if(trail.length>34) trail.shift(); Scheduler.add(fxLoop); }
        function onLeave(){ rx=-1; ry=-1; }
        function draw(ctx){
            var alive = false;
            if(trail.length>1){
                ctx.lineCap="round"; ctx.shadowColor="#67f0ff";
                for(var i=1;i<trail.length;i++){ var a=i/trail.length;
                    ctx.strokeStyle="rgba(103,240,255,"+(a*0.95)+")"; ctx.shadowBlur=20; ctx.lineWidth=a*7+1;
                    ctx.beginPath(); ctx.moveTo(trail[i-1].x,trail[i-1].y); ctx.lineTo(trail[i].x,trail[i].y); ctx.stroke(); }
                alive = true;
            }
            if(rx>=0 && trail.length){ // reticle ring at the head
                ctx.shadowBlur=10; ctx.shadowColor="#67f0ff"; ctx.strokeStyle="rgba(103,240,255,.85)"; ctx.lineWidth=1.5;
                ctx.beginPath(); ctx.arc(rx,ry,8,0,Math.PI*2); ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(rx-13,ry); ctx.lineTo(rx-5,ry); ctx.moveTo(rx+5,ry); ctx.lineTo(rx+13,ry);
                ctx.moveTo(rx,ry-13); ctx.lineTo(rx,ry-5); ctx.moveTo(rx,ry+5); ctx.lineTo(rx,ry+13); ctx.stroke();
                alive = true;
            }
            if(trail.length) trail.shift(); // decay one point per frame when idle
            ctx.shadowBlur=0;
            return alive;
        }
        function enable(){ if(active||!pointerFx()) return; active=true;
            window.addEventListener("pointermove", onMove, {passive:true}); window.addEventListener("pointerleave", onLeave);
            if(fxDrawers.indexOf(draw)<0) fxDrawers.push(draw); }
        function disable(){ if(!active) return; active=false;
            window.removeEventListener("pointermove", onMove); window.removeEventListener("pointerleave", onLeave);
            var i=fxDrawers.indexOf(draw); if(i>=0) fxDrawers.splice(i,1); trail.length=0; rx=-1; if(FX) FX.clear(); }
        window.addEventListener("readme:fxchange", function(){ pointerFx()?enable():disable(); });
        enable();
    })();

    /* ============================================================
     * 15 — click energy pulses + grid ripples
     * ============================================================ */
    (function initPulses(){
        if(!FX) return;
        var ripples=[], sparks=[], active=false, MAX_RIPPLES=6, MAX_SPARKS=120;
        function onDown(e){
            if(!fxEnabled()) return;
            if(ripples.length < MAX_RIPPLES) ripples.push({ x:e.clientX, y:e.clientY, rad:6, life:1 });
            for(var i=0;i<16;i++){ var a=Math.PI*2*i/16; sparks.push({ x:e.clientX, y:e.clientY, vx:Math.cos(a)*(2.6+i%4), vy:Math.sin(a)*(2.6+i%4), life:1 }); }
            if(sparks.length > MAX_SPARKS) sparks.splice(0, sparks.length - MAX_SPARKS);
            Scheduler.add(fxLoop);
        }
        function draw(ctx){
            var alive = false;
            ctx.shadowBlur = 12;
            for(var j=ripples.length-1;j>=0;j--){ var rp=ripples[j]; rp.rad += 9; rp.life -= 0.022;
                ctx.shadowColor="#ffa24d"; ctx.strokeStyle="rgba(255,162,77,"+Math.max(0,rp.life)+")"; ctx.lineWidth=2;
                ctx.beginPath(); ctx.arc(rp.x, rp.y, rp.rad, 0, Math.PI*2); ctx.stroke();
                ctx.strokeStyle="rgba(103,240,255,"+Math.max(0,rp.life*0.7)+")"; ctx.beginPath(); ctx.arc(rp.x, rp.y, rp.rad*0.6, 0, Math.PI*2); ctx.stroke();
                if(rp.life<=0) ripples.splice(j,1); else alive=true;
            }
            for(var k=sparks.length-1;k>=0;k--){ var s=sparks[k]; s.x+=s.vx; s.y+=s.vy; s.vy+=0.05; s.life-=0.03;
                ctx.shadowColor="#ffa24d"; ctx.fillStyle="rgba(255,162,77,"+Math.max(0,s.life)+")";
                ctx.beginPath(); ctx.arc(s.x, s.y, 1.6, 0, Math.PI*2); ctx.fill();
                if(s.life<=0) sparks.splice(k,1); else alive=true;
            }
            ctx.shadowBlur = 0;
            return alive;
        }
        function enable(){ if(active||!fxEnabled()) return; active=true; window.addEventListener("pointerdown", onDown, {passive:true}); if(fxDrawers.indexOf(draw)<0) fxDrawers.push(draw); }
        function disable(){ if(!active) return; active=false; window.removeEventListener("pointerdown", onDown); var i=fxDrawers.indexOf(draw); if(i>=0) fxDrawers.splice(i,1); ripples.length=0; sparks.length=0; }
        window.addEventListener("readme:fxchange", function(){ fxEnabled()?enable():disable(); });
        enable();
    })();

    /* ============================================================
     * 16 — 3D pointer-tilt + tracking glare on .tilt panels
     * ============================================================ */
    (function initTilt(){
        var els = Array.prototype.slice.call(document.querySelectorAll(".tilt"));
        if(!els.length) return;
        els.forEach(function(el){
            if(!el.dataset.glare){ el.dataset.glare="1"; var g=document.createElement("span"); g.className="glare"; g.setAttribute("aria-hidden","true"); el.appendChild(g); }
        });
        function onMove(e){
            var el=e.currentTarget, r=el.getBoundingClientRect();
            var px=(e.clientX-r.left)/r.width-0.5, py=(e.clientY-r.top)/r.height-0.5;
            el.style.setProperty("--gx",(e.clientX-r.left)+"px");
            el.style.setProperty("--gy",(e.clientY-r.top)+"px");
            if(pointerFx()) el.style.transform="perspective(700px) rotateY("+(px*12)+"deg) rotateX("+(-py*12)+"deg) translateZ(12px)";
        }
        function onLeave(e){ e.currentTarget.style.transform=""; }
        els.forEach(function(el){ el.addEventListener("pointermove", onMove, {passive:true}); el.addEventListener("pointerleave", onLeave); });
        window.addEventListener("readme:fxchange", function(){ if(!pointerFx()){ els.forEach(function(el){ el.style.transform=""; }); } });
    })();

    /* 17 — scroll-as-camera: drift the fixed grid/horizon as you scroll */
    (function initScrollCam(){
      var root = document.documentElement, pending = false;
      function paint(){ pending = false;
        if(!fxEnabled()){ root.style.setProperty("--cam-y","0px"); return; }
        var y = window.scrollY || window.pageYOffset || 0;
        root.style.setProperty("--cam-y", (Math.min(y * 0.06, 80)) + "px");
      }
      function onScroll(){ if(!pending){ pending = true; requestAnimationFrame(paint); } }
      window.addEventListener("scroll", onScroll, {passive:true});
      window.addEventListener("readme:fxchange", paint);
      paint();
    })();

    /* 18 — section boot-on-scroll (de-rez in) — SEPARATE observer from scroll-spy */
    (function initSectionBoot(){
      // Sections are ALWAYS visible (CSS base). The de-rez is a one-shot ENTRANCE
      // animation added as each section scrolls into view — it can never strand
      // content hidden, so a missed/failed IntersectionObserver just means "no
      // entrance flourish", never a blank chapter.
      var secs = Array.prototype.slice.call(document.querySelectorAll("main > section"));
      if(!secs.length || !('IntersectionObserver' in window)) return;
      var io = new IntersectionObserver(function(entries){
        entries.forEach(function(en){ if(en.isIntersecting){ if(fxEnabled()) en.target.classList.add("derez-in"); io.unobserve(en.target); } });
      }, { rootMargin:"0px 0px -8% 0px", threshold:0.04 });
      secs.forEach(function(s){ io.observe(s); });
    })();

    /* 12 — boot / "system online" intro (subsumes typed hero, behavior 11)
     *
     * The terminal's full content lives in the HTML, so no-JS and reduced-motion
     * users see the finished output immediately. When motion is allowed, the grid
     * "powers on" (0.7 s), then the terminal types itself (the former behavior 11,
     * now the finale). Skippable by any user interaction. Runs once per page load.
     *
     * revealHeroStatic() — shows the terminal's final state instantly (all .ln
     *   lines visible + final caret). Equivalent to the old reduced-motion branch.
     * typeHero(done)     — the old typing routine ported verbatim; calls done()
     *   when finished.
     */
    (function initBoot(){
      var htmlEl = document.documentElement;
      var term = document.querySelector(".term[data-typed]");
      if(!term) return;

      function revealHeroStatic(){
        // Show all .ln lines (unhide any that typeHero may have hidden)
        // and ensure the command text is fully visible — covers the case
        // where typeHero started then skip() fired mid-type.
        var lines = Array.prototype.slice.call(term.querySelectorAll(".body .ln"));
        var cmdEl = lines.length ? lines[0].querySelector(".cmd") : null;
        if(cmdEl && cmdEl._typeFull !== undefined){ cmdEl.textContent = cmdEl._typeFull; }
        // Remove temporary typing caret if present
        var tc = lines.length ? lines[0].querySelector(".caret._tcaret") : null;
        if(tc) tc.parentNode.removeChild(tc);
        for(var k=0; k<lines.length; k++){ lines[k].style.visibility = ""; }
      }

      function typeHero(done){
        SFX.boot(); // no-ops unless Prefs.sound && context primed by a prior gesture
        var lines = Array.prototype.slice.call(term.querySelectorAll(".body .ln"));
        if(!lines.length){ done(); return; }
        var cmdEl = lines[0].querySelector(".cmd");
        if(!cmdEl){ done(); return; }

        var full = cmdEl.textContent;
        cmdEl._typeFull = full;   // stash so revealHeroStatic can restore
        cmdEl.textContent = "";

        // Temporary typing caret on the command line (marked so revealHeroStatic can find it)
        var tcaret = document.createElement("span");
        tcaret.className = "caret _tcaret";
        tcaret.setAttribute("aria-hidden", "true");
        lines[0].appendChild(tcaret);

        // Hide the output lines without collapsing their layout.
        for(var k=1; k<lines.length; k++){ lines[k].style.visibility = "hidden"; }

        var i = 0;
        function type(){
          cmdEl.textContent = full.slice(0, ++i);
          if(i < full.length){
            setTimeout(type, 26);
          } else {
            if(tcaret.parentNode) tcaret.parentNode.removeChild(tcaret);
            setTimeout(reveal, 220);
          }
        }

        var j = 1;
        function reveal(){
          if(j < lines.length){
            lines[j].style.visibility = "";
            j++;
            setTimeout(reveal, 150);
          } else {
            done();
          }
        }

        requestAnimationFrame(function(){ setTimeout(type, 260); });
      }

      if(!fxEnabled()){ revealHeroStatic(); return; } // motion off / reduced-motion → static hero, no intro

      htmlEl.classList.add("booting");
      var skipped = false;

      function finish(){ htmlEl.classList.remove("booting"); htmlEl.classList.add("booted-done"); }
      function cleanup(){ ["click","keydown","wheel","touchstart"].forEach(function(ev){ window.removeEventListener(ev, skip); }); }
      function skip(){ if(skipped) return; skipped = true; cleanup(); revealHeroStatic(); finish(); }

      ["click","keydown","wheel","touchstart"].forEach(function(ev){ window.addEventListener(ev, skip, {passive:true, once:true}); });

      setTimeout(function(){
        if(skipped) return;
        typeHero(function(){ cleanup(); finish(); });
      }, 700);
    })();

    // ============================================================
    // 19 — Konami "derez" easter egg
    // ============================================================
    (function initKonami(){
      var seq=["ArrowUp","ArrowUp","ArrowDown","ArrowDown","ArrowLeft","ArrowRight","ArrowLeft","ArrowRight","b","a"], pos=0;
      document.addEventListener("keydown", function(e){
        if(/^(input|textarea)$/i.test(e.target.tagName)) return;
        var k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
        pos = (k===seq[pos]) ? pos+1 : (k===seq[0]?1:0);
        if(pos===seq.length){ pos=0; derez(); }
      });
      function derez(){ if(!fxEnabled()) return; var b=document.body; if(b.classList.contains("derez")) return; b.classList.add("derez"); setTimeout(function(){ b.classList.remove("derez"); }, 1400); }
    })();
})();
