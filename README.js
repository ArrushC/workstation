(function () {
    "use strict";

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
})();
