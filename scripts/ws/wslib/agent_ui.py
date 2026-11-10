"""`ws-agent ui`: the jobs and the open inbox items in one fzf list (Linux).

Each row is `kind<TAB>id<TAB>state<TAB>title<TAB>repo`; fzf shows all but the kind. The preview
is `show` for a job and `inbox --show` for an item. enter pages the result with its patch (or the
item), and alt-t/r/c/x/a/d tell, retry, cancel, close, accept and dismiss, then reload the list.
The binds run under bash (`--with-shell`), since `read -p` is bash's whatever the login shell is.
"""

from __future__ import annotations

from . import agent_inbox, jobs

HEADER = ("enter result+patch | alt-t tell | alt-r retry | alt-c cancel | alt-x close | "
          "alt-a accept | alt-d dismiss")
# fzf ends an execute(...) argument at its first ')': no command here may hold one.
_PAUSE = '; printf "\\npress a key "; read -r -s -n 1'


def _cell(text: str) -> str:
    return agent_inbox.printable(text)   # also turns a tab into a space, so a title adds no column


def rows() -> list[str]:
    q = jobs.pueue_status()
    tasks = q.tasks if q else None
    out = []
    for j in jobs.all_jobs():
        st = jobs.state(j, tasks)
        if st != "closed":
            out.append("\t".join(("job", j.id, st, _cell(j.title), j.repo)))
    for it in agent_inbox.items():
        word = str((it.decision or {}).get("decision") or ("request" if it.candidate.get("explicit") else "open"))
        out.append("\t".join(("inbox", it.id, word, _cell(str(it.candidate.get("title") or "")),
                              str(it.candidate.get("repo") or ""))))
    return out


def fzf_argv(ws_agent: str, *, fleet: bool = False) -> list[str]:
    """fzf's command line; `ws_agent` is the shell words that run ws-agent. With `fleet` the rows
    start with a host column and every command runs on that row's host (`ws-agent _on <host> ...`)."""
    if fleet:
        return _fleet_argv(ws_agent)
    a = ws_agent
    reload = f"+reload({a} ui --rows)"

    def bind(key: str, action: str) -> list[str]:
        return ["--bind", f"{key}:execute({action}){reload}"]

    preview = f"if [ {{1}} = inbox ]; then {a} inbox --show {{2}}; else {a} show {{2}}; fi"
    page = (f"if [ {{1}} = inbox ]; then {a} inbox --show {{2}}; else {a} result {{2}} --diff; fi"
            " 2>&1 | ${PAGER:-less}")
    return ["fzf", "--delimiter", "\\t", "--with-nth", "2..", "--with-shell", "bash -c", "--header", HEADER,
            "--preview", preview, "--preview-window", "right,60%,wrap",
            *bind("enter", page),
            *bind("alt-t", f'read -r -p "tell {{2}}: " m && {a} tell {{2}} "$m"{_PAUSE}'),
            *bind("alt-r", f"{a} retry {{2}}{_PAUSE}"),
            *bind("alt-c", f"{a} cancel {{2}}{_PAUSE}"),
            *bind("alt-x", f"{a} close {{2}}{_PAUSE}"),
            *bind("alt-a", f"{a} accept {{2}}{_PAUSE}"),
            *bind("alt-d", f"{a} dismiss {{2}}{_PAUSE}")]


def _fleet_argv(a: str) -> list[str]:
    """Rows are host, kind, id, state, title, repo: {1} is the host, {2} the kind, {3} the id."""
    on = f"{a} _on {{1}}"
    reload = f"+reload({a} ui --fleet --rows)"

    def bind(key: str, action: str) -> list[str]:
        return ["--bind", f"{key}:execute({action}){reload}"]

    preview = f"if [ {{2}} = inbox ]; then {on} inbox --show {{3}}; else {on} show {{3}}; fi"
    page = (f"if [ {{2}} = inbox ]; then {on} inbox --show {{3}}; else {on} result {{3}} --diff; fi"
            " 2>&1 | ${PAGER:-less}")
    return ["fzf", "--delimiter", "\\t", "--with-nth", "1,3..", "--with-shell", "bash -c", "--header", HEADER,
            "--preview", preview, "--preview-window", "right,60%,wrap",
            *bind("enter", page),
            *bind("alt-t", f'read -r -p "tell {{3}}: " m && {on} tell {{3}} "$m"{_PAUSE}'),
            *bind("alt-r", f"{on} retry {{3}}{_PAUSE}"),
            *bind("alt-c", f"{on} cancel {{3}}{_PAUSE}"),
            *bind("alt-x", f"{on} close {{3}}{_PAUSE}"),
            *bind("alt-a", f"{on} accept {{3}}{_PAUSE}"),
            *bind("alt-d", f"{on} dismiss {{3}}{_PAUSE}")]
