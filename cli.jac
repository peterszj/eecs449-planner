"""Dayblock in the terminal.

    jac run cli -- login peter        jac run cli -- add "Essay !high 90m due:fri"
    jac run cli -- today              jac run cli -- done 2
    jac run cli -- plan               jac run cli -- now

The CLI calls the same planner service as the web and mobile apps (over HTTP,
through Jac's typed bridge), so everything it changes shows up there too.
"""
import argparse;
import asyncio;
import datetime;
import getpass;
import json;
import os;
import sys;
import urllib.error;
import urllib.request;
import from pathlib { Path }
import from jaclang.server { sv_client }
import from core.planner {
    DayView,
    WeekView,
    TaskView,
    get_day,
    get_week,
    quick_add,
    toggle_task,
    move_task,
    delete_task,
    rollover,
    auto_plan,
    clear_plan,
    set_prefs,
    load_sample
}

glob COLOR: bool = sys.stdout.isatty() and not os.environ.get("NO_COLOR");

def paint(text: str, code: str) -> str {
    return f"\033[{code}m{text}\033[0m" if COLOR else text;
}

def dim(text: str) -> str {
    return paint(text, "2");
}

def bold(text: str) -> str {
    return paint(text, "1");
}

def prio(p: int) -> str {
    return paint("●", {1: "31", 2: "33", 3: "90"}[p]);
}

def hm(total: int) -> str {
    return f"{total // 60:02d}:{total % 60:02d}";
}

def dur(total: int) -> str {
    if total < 60 {
        return f"{total}m";
    }
    rest = total % 60;
    return f"{total // 60}h" + (f" {rest}m" if rest else "");
}

def today_str -> str {
    return datetime.date.today().isoformat();
}

def now_min -> int {
    now = datetime.datetime.now();
    return now.hour * 60 + now.minute;
}

"""The server's own error message out of a failed call."""
def reason(e: Exception) -> str {
    text = str(e);
    brace = text.find("{");
    if brace >= 0 {
        try {
            return str(json.loads(text[brace:])["error"]["message"]);
        } except Exception {}
    }
    if "Connection refused" in text or "not reachable" in text or "Unavailable" in type(e).__name__ {
        return "Cannot reach the Dayblock server. Start it with `jac run` (or pass --url).";
    }
    return text;
}

obj Session {
    has path: Path,
        data: dict[str, any] = {};

    def load -> Session {
        if self.path.exists() {
            try {
                self.data = json.loads(self.path.read_text());
            } except Exception {
                self.data = {};
            }
        }
        return self;
    }

    def save {
        fd = os.open(str(self.path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600);
        with os.fdopen(fd, "w") as handle {
            json.dump(self.data, handle);
        }
        self.path.chmod(0o600);
    }
}

def auth(base: str, path: str, payload: dict[str, any]) -> dict[str, any] {
    request = urllib.request.Request(
        base + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}
    );
    try {
        with urllib.request.urlopen(request, timeout=15) as response {
            return json.loads(response.read())["data"];
        }
    } except urllib.error.HTTPError as e {
        body = e.read().decode();
        try {
            raise RuntimeError(json.loads(body)["error"]["message"]);
        } except (ValueError, KeyError, TypeError) {
            raise RuntimeError(f"HTTP {e.code}: {body[:200]}");
        }
    } except urllib.error.URLError {
        raise RuntimeError(f"Cannot reach the Dayblock server at {base}. Start it with `jac run`.");
    }
}

"""Resolve `2` (a number from the last listing) or an id prefix to a task id."""
def pick(ref: str, session: Session) -> str {
    ids: list[str] = session.data.get("last_ids", []);
    if ref.isdigit() {
        n = int(ref);
        if n < 1 or n > len(ids) {
            raise ValueError(f"No task #{ref} in the last listing; run `today` first");
        }
        return ids[n - 1];
    }
    matches = [i for i in ids if i.startswith(ref)];
    if len(matches) == 1 {
        return matches[0];
    }
    return ref;
}

def print_day(view: DayView, session: Session, show_now: bool) {
    header = bold(view.label) + ("  " + paint("TODAY", "34;1") if view.day == today_str() else "");
    print(header);
    print(
        dim(f"{view.done_count}/{view.total_count} done · {dur(view.open_min)} to do · {dur(view.free_min)} free")
        + (paint("  over-booked", "31") if view.open_min > view.free_min else "")
    );
    if view.overdue {
        print(paint(f"⚠ {view.overdue} unfinished from earlier days: `rollover` moves them here", "33"));
    }
    if show_now and (view.now_block or view.next_block) {
        if view.now_block {
            print(paint("▶ now  ", "34;1") + f"{view.now_block.label} until {hm(view.now_block.end)}");
        }
        if view.next_block {
            print(paint("  next ", "34") + f"{hm(view.next_block.start)} {view.next_block.label}");
        }
    }
    print();
    print(bold("Timeline") + dim(f"  {view.prefs.day_start}–{view.prefs.day_end}"));
    if not view.blocks {
        print(dim("  nothing scheduled: add a block like `add \"Lecture 13:30-15:00\"`, then `plan`"));
    }
    for b in view.blocks {
        mark = "✓" if b.done else ("■" if b.kind == "fixed" else "□");
        part = f" ({b.part}/{b.parts})" if b.parts > 1 else "";
        line = f"  {b.time}  {mark} {b.label}{part}";
        if b.kind == "fixed" {
            line = dim(line);
        } elif view.now_block and view.now_block.id == b.id {
            line = paint(line, "34;1");
        }
        print(line);
    }
    print();
    print(bold("Tasks"));
    if not view.tasks {
        print(dim("  none: `add \"Read chapter 3 45m\"`"));
    }
    ids: list[str] = [];
    for (i, t) in enumerate(view.tasks) {
        ids.append(t.id);
        box = paint("[x]", "32") if t.done else "[ ]";
        extras = [dur(t.estimate)];
        if t.slot {
            extras.append("⏱ " + t.slot);
        }
        if t.due {
            extras.append(paint("due " + t.due[5:], "31" if t.due_soon else "0"));
        }
        if t.tag {
            extras.append("#" + t.tag);
        }
        if t.recur {
            extras.append("↻ " + t.recur);
        }
        title = dim(t.title) if t.done else t.title;
        print(f"  {i + 1:>2}. {box} {prio(t.priority)} {title}  " + dim(" · ".join(extras)));
    }
    session.data["last_ids"] = ids;
    session.save();
}

async def show(day: str, session: Session) {
    is_today = day == today_str();
    view = await get_day(day, now_min() if is_today else -1);
    print_day(view, session, is_today);
}

def resolve_day(text: str) -> str {
    if not text {
        return today_str();
    }
    base = datetime.date.today();
    word = text.lower();
    if word in ["today", "tod"] {
        return base.isoformat();
    }
    if word in ["tomorrow", "tmr", "tom"] {
        return (base + datetime.timedelta(days=1)).isoformat();
    }
    if word in ["yesterday", "yday"] {
        return (base - datetime.timedelta(days=1)).isoformat();
    }
    if word.startswith("+") and word[1:].isdigit() {
        return (base + datetime.timedelta(days=int(word[1:]))).isoformat();
    }
    return datetime.date.fromisoformat(text).isoformat();
}

async def main -> int {
    parser = argparse.ArgumentParser(
        prog="jac run cli --",
        description="Dayblock: plan your day in blocks, from the terminal.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""commands:
  signup USER | login USER | logout | whoami
  today [DAY]            timeline + numbered tasks (DAY: tomorrow, +2, 2026-10-05)
  now                    what you should be doing right now, and what's next
  add "TEXT"             quick add: Essay !high 90m @fri due:sun #class *daily
                         a time range makes a fixed block: "Gym 18:00-19:00 @tmr"
  done N                 check task N off (or back on)
  move N DAY             move task N to another day
  rm N                   delete task N
  plan [DAY]             auto-schedule open tasks into free time
  clear [DAY]            remove auto-scheduled blocks
  rollover               bring unfinished tasks from earlier days to today
  week                   this week's load and your streak
  hours START END [BRK]  working hours, e.g. hours 09:00 21:00 10
  sample                 load a sample day into an empty planner"""
    );
    parser.add_argument(
        "--url",
        `default=os.environ.get("DAYBLOCK_URL", "http://127.0.0.1:8000"),
        help="server address (default $DAYBLOCK_URL or http://127.0.0.1:8000)"
    );
    parser.add_argument("command", nargs="?", `default="today");
    parser.add_argument("args", nargs="*");
    args = parser.parse_args();
    base = str(args.url).rstrip("/");
    session = Session(
        path=Path(os.environ.get("DAYBLOCK_SESSION", str(Path.home() / ".dayblock.json")))
    ).load();
    os.environ["JAC_APP_PLANNER_URL"] = base + "/api/planner";
    cmd = str(args.command);
    rest: list[str] = [str(a) for a in args.args];
    try {
        if cmd in ["login", "signup"] {
            if not rest {
                parser.error(cmd + " needs a username");
            }
            user = rest[0];
            password = os.environ.get("DAYBLOCK_PASSWORD") or getpass.getpass("Password: ");
            if cmd == "signup" {
                auth(
                    base,
                    "/user/register",
                    {
                        "identities": [{"type": "username", "value": user}],
                        "credential": {"type": "password", "password": password}
                    }
                );
            }
            data = auth(
                base,
                "/user/login",
                {
                    "identity": {"type": "username", "value": user},
                    "credential": {"type": "password", "password": password}
                }
            );
            session.data = {"url": base, "token": str(data["token"]), "user": user};
            session.save();
            print(paint("✓", "32") + f" Signed in as @{user} on {base}");
            return 0;
        }
        if cmd == "logout" {
            session.path.unlink(missing_ok=True);
            print("Signed out.");
            return 0;
        }
        if cmd == "whoami" {
            print(
                f"@{session.data['user']} on {session.data['url']}"
                    if session.data.get("token")
                    else "Not signed in. Run: jac run cli -- login USER"
            );
            return 0;
        }
        if not session.data.get("token") {
            print("Not signed in. Run: jac run cli -- login USER  (or signup USER)", file=sys.stderr);
            return 1;
        }
        if session.data.get("url") != base {
            print(f"Your session is for {session.data.get('url')}; log in again for {base}.", file=sys.stderr);
            return 1;
        }
        sv_client.set_bearer_token(str(session.data["token"]));

        if cmd in ["today", "day", "ls"] {
            await show(resolve_day(rest[0] if rest else ""), session);
        } elif cmd == "now" {
            view = await get_day(today_str(), now_min());
            if view.now_block {
                left = view.now_block.end - now_min();
                print(paint("▶ ", "34;1") + bold(view.now_block.label) + dim(f"  until {hm(view.now_block.end)} ({dur(left)} left)"));
            } else {
                print(dim("Nothing scheduled right now."));
            }
            if view.next_block {
                print(f"  next {hm(view.next_block.start)} " + view.next_block.label + dim(f"  (in {dur(view.next_block.start - now_min())})"));
            }
            if view.unscheduled {
                print(dim(f"  {view.unscheduled} task(s) not on the timeline: run `plan`"));
            }
        } elif cmd == "add" {
            if not rest {
                parser.error("add needs text, e.g. add \"Essay !high 90m @fri\"");
            }
            result = await quick_add(" ".join(rest), today_str());
            print(paint("✓ ", "32") + result.message);
        } elif cmd == "done" {
            if not rest {
                parser.error("done needs a task number from `today`");
            }
            t = await toggle_task(pick(rest[0], session), today_str());
            print((paint("✓ Done: ", "32") if t.done else "↺ Reopened: ") + t.title + (dim(f"  (next one queued: {t.recur})") if t.done and t.recur else ""));
        } elif cmd == "move" {
            if len(rest) < 2 {
                parser.error("move needs a task number and a day");
            }
            t = await move_task(pick(rest[0], session), resolve_day(rest[1]));
            print(f"→ Moved “{t.title}” to {t.day}");
        } elif cmd in ["rm", "delete"] {
            if not rest {
                parser.error("rm needs a task number");
            }
            await delete_task(pick(rest[0], session));
            print("Deleted.");
        } elif cmd == "plan" {
            day = resolve_day(rest[0] if rest else "");
            planned = await auto_plan(day, now_min() if day == today_str() else -1);
            print(paint("✓ ", "32") + planned.message);
            print();
            await show(day, session);
        } elif cmd == "clear" {
            n = await clear_plan(resolve_day(rest[0] if rest else ""));
            print(f"Cleared {n} scheduled block(s).");
        } elif cmd == "rollover" {
            n = await rollover(today_str());
            print(f"Moved {n} unfinished task(s) to today.");
        } elif cmd == "week" {
            w = await get_week(today_str(), today_str());
            print(bold("Week of " + w.start) + dim(f"   🔥 {w.streak}-day streak · {w.done_week} done ({dur(w.done_min_week)})"));
            for d in w.days {
                cap = max(d.capacity_min, 1);
                filled = min(20, round(d.task_min * 20 / cap));
                bar = paint("█" * filled, "31" if d.task_min > d.capacity_min else "34") + dim("░" * (20 - filled));
                label = bold(d.label.ljust(9)) if d.day == today_str() else d.label.ljust(9);
                print(f"  {label} {bar} {d.done}/{d.total} done · {dur(d.task_min)} of {dur(d.capacity_min)}");
            }
        } elif cmd == "hours" {
            if len(rest) < 2 {
                parser.error("hours needs START END, e.g. hours 09:00 21:00 10");
            }
            p = await set_prefs(rest[0], rest[1], int(rest[2]) if len(rest) > 2 else 10);
            print(f"Working hours {p.day_start}–{p.day_end}, {p.buffer}m break between tasks.");
        } elif cmd == "sample" {
            n = await load_sample(today_str());
            print(f"Loaded {n} sample items. Try: jac run cli -- plan");
        } else {
            parser.error(f"unknown command '{cmd}'");
        }
        return 0;
    } except Exception as e {
        print(paint("✗ ", "31") + reason(e), file=sys.stderr);
        return 1;
    }
}

with entry:__main__ {
    sys.`exit(asyncio.run(main()));
}
