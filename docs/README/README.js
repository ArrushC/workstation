/* Progressive enhancement for the offline-capable workstation handbook. */
(function () {
    "use strict";

    const $ = (selector, root = document) => root.querySelector(selector);
    const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
    const main = $("main");
    const status = $("#interaction-status");
    const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
    const mobile = matchMedia("(max-width: 900px)");
    const announce = (message) => { status.textContent = message; };
    // Injected chip counts are presentation, not heading text: search titles,
    // aria-labels and the passage index must all read the heading without them.
    const textOf = (el) => {
        let source = el;
        if (el.querySelector && el.querySelector(".card-count")) {
            source = el.cloneNode(true);
            source.querySelectorAll(".card-count").forEach((node) => node.remove());
        }
        return source.textContent.replace(/\s+/g, " ").trim();
    };
    const pref = {
        get(key) { try { return localStorage.getItem(key); } catch (_) { return null; } },
        set(key, value) { try { localStorage.setItem(key, value); } catch (_) { /* Session-only preference. */ } },
    };

    // Themes follow the OS unless the reader has explicitly selected one.
    const themes = ["auto", "light", "dark"];
    const themeButton = $("#theme-toggle");
    let theme = pref.get("readme-theme");
    if (!themes.includes(theme)) theme = "dark";
    function applyTheme() {
        document.documentElement.dataset.theme = theme;
        const label = `Theme: ${theme === "auto" ? "system" : theme}. Click to change.`;
        themeButton.setAttribute("aria-label", label);
        themeButton.title = label;
        $("#theme-icon").textContent = { auto: "◐", light: "☀", dark: "☾" }[theme];
    }
    applyTheme();
    themeButton.hidden = false;
    themeButton.addEventListener("click", () => {
        theme = themes[(themes.indexOf(theme) + 1) % themes.length];
        pref.set("readme-theme", theme);
        applyTheme();
        announce(`Theme set to ${theme === "auto" ? "system" : theme}.`);
    });

    // Clipboard text is captured before controls and search marks are inserted.
    $$("pre").forEach((pre) => {
        const code = $("code", pre) || pre;
        const command = code.textContent;
        const button = document.createElement("button");
        button.type = "button";
        button.className = "copy-btn";
        button.textContent = "Copy";
        button.setAttribute("aria-label", "Copy code to clipboard");
        pre.tabIndex = 0;
        pre.append(button);
        let timer;
        button.addEventListener("click", async () => {
            clearTimeout(timer);
            try {
                if (!navigator.clipboard) throw new Error("Clipboard unavailable");
                await navigator.clipboard.writeText(command);
                button.textContent = "Copied";
                button.classList.add("copied");
                announce("Code copied to clipboard.");
            } catch (_) {
                const selection = getSelection();
                const range = document.createRange();
                range.selectNodeContents(code);
                selection.removeAllRanges();
                selection.addRange(range);
                button.textContent = "Select & copy";
                announce("Clipboard unavailable. Code selected; use your system copy shortcut.");
            }
            timer = setTimeout(() => {
                button.textContent = "Copy";
                button.classList.remove("copied");
            }, 2200);
        });
    });

    // Platform selection is progressively enhanced: both guides remain visible without JS.
    const platformTabs = $$("[data-platform]");
    function selectPlatform(platform, focus = false) {
        platformTabs.forEach((tab) => {
            const selected = tab.dataset.platform === platform;
            tab.setAttribute("aria-selected", String(selected));
            tab.tabIndex = selected ? 0 : -1;
            const panel = document.getElementById(tab.getAttribute("aria-controls"));
            panel.hidden = !selected;
            panel.setAttribute("role", "tabpanel");
            panel.tabIndex = 0;
            panel.setAttribute("aria-labelledby", tab.id);
            if (selected && focus) tab.focus();
        });
    }
    platformTabs.forEach((tab, i) => {
        tab.addEventListener("click", () => selectPlatform(tab.dataset.platform));
        tab.addEventListener("keydown", (event) => {
            if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
            event.preventDefault();
            const next = event.key === "Home" ? 0 : event.key === "End" ? platformTabs.length - 1 : (i + (event.key === "ArrowRight" ? 1 : -1) + platformTabs.length) % platformTabs.length;
            selectPlatform(platformTabs[next].dataset.platform, true);
        });
    });
    $(".platform-tabs").hidden = false;
    selectPlatform("linux");
    $$("[data-tool-total]").forEach((el) => { el.textContent = $$("#toolbelt-grid .chip").length; });

    // Local filters show only matching entries, with explicit reset and empty states.
    const filters = [];
    function setupFilter(inputId, itemsSelector, countId, noun) {
        const input = $(inputId);
        const items = $$(itemsSelector);
        const counter = $(countId);
        const category = inputId === "#tool-filter" ? $("#tool-category") : null;
        if (category) {
            items.forEach((card, i) => {
                const option = document.createElement("option");
                option.value = String(i);
                option.textContent = textOf($("h4", card));
                category.append(option);
                const count = document.createElement("span");
                count.className = "card-count";
                count.textContent = $$(".chip", card).length;
                count.setAttribute("aria-label", `${count.textContent} tools`);
                $("h4", card).append(count);
            });
            category.addEventListener("change", update);
        }
        const records = items.map((el) => ({ el, text: [textOf(el), el.dataset.cat || "", ...$$(".chip", el).map((chip) => chip.dataset.tip || "")].join(" ").toLowerCase() }));
        const clear = document.createElement("button");
        clear.type = "button";
        clear.className = "filter-clear";
        clear.textContent = "Clear";
        clear.hidden = true;
        clear.setAttribute("aria-label", `Clear ${noun} filter`);
        input.after(clear);
        const empty = document.createElement("p");
        empty.className = "filter-empty";
        empty.hidden = true;
        empty.textContent = `No matching ${noun}. Try another term or clear the filter.`;
        input.closest(".filter-bar").after(empty);
        input.closest(".filter-bar").hidden = false;
        const openedBeforeFilter = new Set();
        let filtering = false;
        function update() {
            const q = input.value.trim().toLowerCase();
            if (q && !filtering) {
                records.forEach(({ el }) => { if (el.tagName === "DETAILS" && el.open) openedBeforeFilter.add(el); });
            }
            let shown = 0;
            records.forEach(({ el, text }, index) => {
                const match = (!q || text.includes(q)) && (!category || category.value === "" || category.value === String(index));
                el.hidden = !match;
                if (match) shown++;
                if (el.tagName === "DETAILS") {
                    if (q) el.open = match;
                    else if (filtering) el.open = openedBeforeFilter.has(el);
                }
                $$(".chip", el).forEach((chip) => {
                    chip.classList.toggle("match-hit", Boolean(q) && (textOf(chip) + " " + chip.dataset.tip).toLowerCase().includes(q));
                });
            });
            filtering = Boolean(q);
            if (!filtering) openedBeforeFilter.clear();
            if (category) $$("[data-tool-query]").forEach((button) => {
                button.setAttribute("aria-pressed", String(button.dataset.toolQuery === q && category.value === ""));
            });
            const constrained = q || (category && category.value !== "");
            counter.textContent = constrained ? `${shown} of ${items.length} ${noun}` : `${items.length} ${noun}`;
            counter.classList.toggle("no-match", shown === 0);
            clear.hidden = !constrained;
            empty.hidden = shown !== 0;
        }
        function reset() { input.value = ""; if (category) category.value = ""; update(); }
        input.addEventListener("input", update);
        input.addEventListener("keydown", (event) => { if (event.key === "Escape") { event.stopPropagation(); reset(); } });
        clear.addEventListener("click", () => { reset(); input.focus(); });
        filters.push({ reset, hides: (target) => records.some(({ el }) => el.hidden && el.contains(target)) });
        update();
    }
    setupFilter("#tool-filter", "#toolbelt-grid .tool-card", "#tool-filter-meta", "categories");
    setupFilter("#ts-filter", "[data-ts]", "#ts-count", "entries");

    $(".directory-controls").hidden = false;
    $$("[data-tool-query]").forEach((button) => button.addEventListener("click", () => {
        $("#tool-category").value = "";
        $("#tool-filter").value = button.dataset.toolQuery;
        $("#tool-filter").dispatchEvent(new Event("input", { bubbles: true }));
    }));
    function setToolView(view) {
        $("#toolbelt-grid").classList.toggle("list-view", view === "list");
        $$("[data-tool-view]").forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.toolView === view)));
    }
    setToolView(pref.get("readme-tool-view") === "list" ? "list" : "grid");
    $$("[data-tool-view]").forEach((button) => button.addEventListener("click", () => {
        setToolView(button.dataset.toolView);
        pref.set("readme-tool-view", button.dataset.toolView);
    }));
    $(".disclosure-actions").hidden = false;
    $$("[data-disclosures]").forEach((button) => button.addEventListener("click", () => {
        const open = button.dataset.disclosures === "open";
        $$("[data-ts]").forEach((entry) => { if (!open || !entry.hidden) entry.open = open; });
        announce(open ? "Matching troubleshooting entries expanded." : "All troubleshooting entries collapsed.");
    }));

    // Keep chip descriptions inside the viewport for pointer and keyboard readers.
    function positionTooltip(chip) {
        const left = chip.getBoundingClientRect().left;
        const width = Math.min(250, innerWidth - 40);
        const offset = Math.max(20 - left, Math.min(0, innerWidth - 20 - left - width));
        chip.style.setProperty("--tip-left", `${offset}px`);
    }
    $$(".chip").forEach((chip) => {
        chip.addEventListener("pointerenter", () => positionTooltip(chip));
        chip.addEventListener("focus", () => positionTooltip(chip));
    });
    window.addEventListener("resize", () => {
        $$(".chip:hover, .chip:focus").forEach(positionTooltip);
    });

    const toc = $("#toc");
    const tocButton = $("#toc-collapse-ctrl");
    function setContents(open) {
        toc.classList.toggle("mobile-collapsed", !open);
        tocButton.setAttribute("aria-expanded", String(open));
    }
    tocButton.hidden = false;
    setContents(!mobile.matches);
    mobile.addEventListener("change", () => setContents(!mobile.matches));
    tocButton.addEventListener("click", () => setContents(tocButton.getAttribute("aria-expanded") !== "true"));
    toc.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && mobile.matches) { setContents(false); tocButton.focus(); }
    });

    // Preserve native radio behavior while allowing navigation into inactive panels.
    const tabInputs = new Map([
        ["panel-prod", "pprod"], ["panel-dev", "pdev"], ["ar-panel-all", "ar-all"],
        ["ar-panel-group", "ar-group"], ["ar-panel-host", "ar-host"], ["ar-panel-check", "ar-check"],
    ]);
    function reveal(target) {
        // Only a filter that is hiding the target gets reset; every other in-page
        // link (heading anchors, TOC, cross-references) leaves active filters alone.
        filters.forEach((filter) => { if (filter.hides(target)) filter.reset(); });
        const quickstart = target.closest(".qs-card");
        if (quickstart) selectPlatform(quickstart.classList.contains("windows") ? "windows" : "linux");
        for (let node = target; node && node !== main; node = node.parentElement) {
            if (node.tagName === "DETAILS") node.open = true;
            if (node.classList.contains("tab-panel")) {
                tabInputs.forEach((id, cls) => { if (node.classList.contains(cls)) document.getElementById(id).checked = true; });
            }
        }
    }
    function navigate(target, { push = true, smooth = true } = {}) {
        if (!target) return;
        reveal(target);
        if (mobile.matches) setContents(false);
        if (push && target.id && location.hash !== `#${target.id}`) {
            try { history.pushState(null, "", `#${target.id}`); } catch (_) { /* file:// may restrict history writes. */ }
        }
        if (!target.hasAttribute("tabindex")) target.tabIndex = -1;
        target.focus({ preventScroll: true });
        target.scrollIntoView({ block: "start", behavior: smooth && !reducedMotion.matches ? "smooth" : "instant" });
        scheduleScroll();
    }
    function hashTarget() {
        try { return document.getElementById(decodeURIComponent(location.hash.slice(1))); } catch (_) { return null; }
    }
    document.addEventListener("click", (event) => {
        const link = event.target.closest('a[href^="#"]');
        if (!link || event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
        let target;
        try { target = document.getElementById(decodeURIComponent(link.hash.slice(1))); } catch (_) { return; }
        if (!target) return;
        event.preventDefault();
        closeSearch();
        navigate(target);
    });
    // Back/forward between fragment entries fires popstate AND hashchange; listen
    // once or the page navigates (focus + scroll) twice per step.
    window.addEventListener("hashchange", () => navigate(hashTarget() || $("#intro"), { push: false, smooth: false }));

    // Index content once, including paragraphs inside disclosures and radio panels.
    // Each result points to a real passage; queries never rewrite or dim the document.
    const searchInput = $("#global-search");
    const searchPanel = $("#search-panel");
    const resultsEl = $("#search-results");
    const searchSummary = $("#toc-search-meta");
    const indexed = [];
    let heading = "Overview";
    let sequence = 0;
    $$("h1, h2, h3, h4, p, pre, summary, li, .chip, tr, .ln", main).forEach((el) => {
        if (el.closest(".page-footer, .filter-bar, .setup-journey, .directory-controls, .platform-tabs") || el.classList.contains("filter-empty")) return;
        if (/^H[1-4]$/.test(el.tagName)) heading = textOf(el);
        if (el.tagName === "LI" && $("p, pre, li, summary", el)) return;
        const source = el.tagName === "PRE" ? $("code", el) || el : el;
        const text = textOf(source);
        if (!text) return;
        if (!el.id) {
            do { sequence++; } while (document.getElementById(`readme-passage-${sequence}`));
            el.id = `readme-passage-${sequence}`;
        }
        indexed.push({ el, text, lower: text.toLowerCase(), heading });
    });
    let matches = [];
    let activeIndex = -1;
    let searchTimer;
    let destination;
    function clearDestination() {
        if (!destination) return;
        destination.classList.remove("search-destination");
        $$("mark[data-search-hit]", destination).forEach((mark) => {
            const parent = mark.parentNode;
            mark.replaceWith(document.createTextNode(mark.textContent));
            parent.normalize();
        });
        destination = null;
    }
    function highlight(target, query) {
        clearDestination();
        destination = target;
        target.classList.add("search-destination");
        if (!query) return;
        const walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT, {
            acceptNode(node) { return node.parentElement.closest("button, .sr-only, .heading-anchor") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT; },
        });
        const nodes = [];
        while (walker.nextNode()) nodes.push(walker.currentNode);
        nodes.forEach((node) => {
            const offset = node.textContent.toLowerCase().indexOf(query);
            if (offset < 0) return;
            const range = document.createRange();
            range.setStart(node, offset);
            range.setEnd(node, offset + query.length);
            const mark = document.createElement("mark");
            mark.dataset.searchHit = "";
            range.surroundContents(mark);
        });
    }
    function closeSearch() {
        clearTimeout(searchTimer);
        searchTimer = null;
        searchPanel.hidden = true;
        searchInput.setAttribute("aria-expanded", "false");
        searchInput.removeAttribute("aria-activedescendant");
        activeIndex = -1;
    }
    function activate(index) {
        activeIndex = index;
        Array.from(resultsEl.children).forEach((el, i) => el.setAttribute("aria-selected", String(i === index)));
        if (index >= 0 && resultsEl.children[index]) {
            const active = resultsEl.children[index];
            searchInput.setAttribute("aria-activedescendant", active.id);
            active.scrollIntoView({ block: "nearest" });
        } else searchInput.removeAttribute("aria-activedescendant");
    }
    function selectResult(index) {
        const result = matches[index];
        if (!result) return;
        const query = searchInput.value.trim().toLowerCase();
        closeSearch();
        navigate(result.el);
        highlight(result.el, query);
        announce(`Opened ${result.heading}.`);
    }
    function runSearch() {
        clearTimeout(searchTimer);
        searchTimer = null;
        const q = searchInput.value.trim().toLowerCase();
        resultsEl.replaceChildren();
        searchInput.removeAttribute("aria-activedescendant");
        activeIndex = -1;
        if (!q) { matches = []; closeSearch(); clearDestination(); return; }
        const all = indexed.filter((item) => item.lower.includes(q));
        matches = all.slice(0, 30);
        searchSummary.textContent = all.length ? `${all.length} matching passages${all.length > 30 ? " · showing first 30" : ""}` : "No results. Try a tool name, command, or platform.";
        matches.forEach((item, i) => {
            const result = document.createElement("div");
            result.className = "search-result";
            result.id = `search-result-${i}`;
            result.setAttribute("role", "option");
            result.setAttribute("aria-selected", "false");
            const title = document.createElement("strong");
            title.textContent = item.heading;
            const excerpt = document.createElement("p");
            const offset = item.lower.indexOf(q);
            const start = Math.max(0, offset - 45);
            const end = Math.min(item.text.length, offset + q.length + 100);
            excerpt.append((start ? "…" : "") + item.text.slice(start, offset));
            const mark = document.createElement("mark");
            mark.textContent = item.text.slice(offset, offset + q.length);
            excerpt.append(mark, item.text.slice(offset + q.length, end) + (end < item.text.length ? "…" : ""));
            result.append(title, excerpt);
            result.addEventListener("mousedown", (event) => event.preventDefault());
            result.addEventListener("click", () => selectResult(i));
            resultsEl.append(result);
        });
        searchPanel.hidden = false;
        searchInput.setAttribute("aria-expanded", "true");
    }
    $(".search-wrap").hidden = false;
    searchInput.addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(runSearch, 120); });
    searchInput.addEventListener("focus", () => { if (searchInput.value.trim()) runSearch(); });
    searchInput.addEventListener("keydown", (event) => {
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            if (searchPanel.hidden || searchTimer) { runSearch(); searchTimer = null; }
            if (!matches.length) return;
            const next = activeIndex < 0 ? (event.key === "ArrowDown" ? 0 : matches.length - 1) : (activeIndex + (event.key === "ArrowDown" ? 1 : -1) + matches.length) % matches.length;
            activate(next);
        } else if (event.key === "Enter") {
            event.preventDefault();
            if (searchPanel.hidden || searchTimer) { runSearch(); searchTimer = null; }
            selectResult(activeIndex < 0 ? 0 : activeIndex);
        } else if (event.key === "Escape") {
            event.stopPropagation();
            if (!searchPanel.hidden) closeSearch();
            else { searchInput.value = ""; runSearch(); }
        } else if (event.key === "Tab") closeSearch();
    });
    document.addEventListener("pointerdown", (event) => { if (!event.target.closest(".search-wrap")) closeSearch(); });
    document.addEventListener("keydown", (event) => {
        const typing = event.target.closest("input, textarea, select, [contenteditable]:not([contenteditable='false'])");
        if (event.key === "/" && !typing && !event.ctrlKey && !event.metaKey && !event.altKey) {
            event.preventDefault(); searchInput.focus(); searchInput.select();
        }
        if (event.key === "Escape" && !typing) { closeSearch(); clearDestination(); }
    });

    // Heading links include section-owned IDs and preserve all existing anchors.
    $$("h2, h3, h4", main).forEach((headingEl) => {
        if (headingEl.closest("a")) return;
        const id = headingEl.parentElement.tagName === "SECTION" && $("h2", headingEl.parentElement) === headingEl ? headingEl.parentElement.id : headingEl.id;
        if (!id) return;
        const anchor = document.createElement("a");
        anchor.className = "heading-anchor";
        anchor.href = `#${id}`;
        anchor.textContent = "#";
        anchor.setAttribute("aria-label", `Link to ${textOf(headingEl)}`);
        headingEl.append(anchor);
    });
    const tocLinks = $$("#toc a[href^='#']");
    const targets = $$("[id]", main).filter((el) => tocLinks.some((link) => link.hash === `#${el.id}`));
    let scrollPending = false;
    let activeHash = "";
    function updateScroll() {
        scrollPending = false;
        const threshold = parseFloat(getComputedStyle(document.documentElement).scrollPaddingTop) + 35;
        let current = targets[0];
        targets.forEach((target) => { if (target.getClientRects().length && target.getBoundingClientRect().top <= threshold) current = target; });
        const hash = current ? `#${current.id}` : "#intro";
        if (hash !== activeHash) {
            activeHash = hash;
            tocLinks.forEach((link) => {
                const active = link.hash === hash;
                link.classList.toggle("active", active);
                if (active) link.setAttribute("aria-current", "location");
                else link.removeAttribute("aria-current");
            });
            const activeLink = tocLinks.find((link) => link.hash === hash);
            $("#current-section").textContent = activeLink ? textOf(activeLink) : "Overview";
        }
        const range = document.documentElement.scrollHeight - innerHeight;
        $("#scroll-progress").style.setProperty("--scroll-progress", range > 0 ? Math.min(1, Math.max(0, scrollY / range)) : 0);
    }
    function scheduleScroll() { if (!scrollPending) { scrollPending = true; requestAnimationFrame(updateScroll); } }
    window.addEventListener("scroll", scheduleScroll, { passive: true });
    window.addEventListener("resize", scheduleScroll);
    main.addEventListener("toggle", scheduleScroll, true);
    if (location.hash) navigate(hashTarget(), { push: false, smooth: false });
    scheduleScroll();

    let printClosed = [];
    window.addEventListener("beforeprint", () => {
        printClosed = $$("details:not([open])", main);
        printClosed.forEach((el) => { el.open = true; });
    });
    window.addEventListener("afterprint", () => { printClosed.forEach((el) => { el.open = false; }); });
})();
