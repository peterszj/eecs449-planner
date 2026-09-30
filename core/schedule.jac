"""Pure planning logic: clock math, the quick-add parser and the auto-scheduler.

Nothing here touches the graph, so every rule is unit-tested in schedule.test.jac.
"""
import re;
import datetime;

glob WEEKDAYS: list[str] = [
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
];
glob RECURS: list[str] = ["daily", "weekdays", "weekly"];

"""'9:05' or '09:05' -> 545 minutes after midnight."""
def:priv to_min(hhmm: str) -> int {
    text = hhmm.strip();
    m = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?", text);
    if not m {
        raise ValueError(f"'{hhmm}' is not a time like 14:30");
    }
    hours = int(m.group(1));
    minutes = int(m.group(2) or "0");
    if hours > 24 or minutes > 59 or (hours == 24 and minutes > 0) {
        raise ValueError(f"'{hhmm}' is not a valid time");
    }
    return hours * 60 + minutes;
}

"""545 -> '09:05'."""
def:priv fmt_min(total: int) -> str {
    return f"{total // 60:02d}:{total % 60:02d}";
}

"""90 -> '1h 30m', 45 -> '45m'."""
def:priv fmt_dur(total: int) -> str {
    if total < 60 {
        return f"{total}m";
    }
    rest = total % 60;
    return f"{total // 60}h" + (f" {rest}m" if rest else "");
}

def:priv add_days(day: str, n: int) -> str {
    return (datetime.date.fromisoformat(day) + datetime.timedelta(days=n)).isoformat();
}

def:priv weekday_of(day: str) -> int {
    return datetime.date.fromisoformat(day).weekday();
}

"""Monday of the week containing `day`."""
def:priv week_start(day: str) -> str {
    return add_days(day, -weekday_of(day));
}

"""Resolve today / tomorrow / fri / +3 / 2026-10-05 / 10-05 relative to `today`."""
def:priv parse_date(token: str, today: str) -> str {
    word = token.strip().lower();
    if word in ["today", "tod", "now"] {
        return today;
    }
    if word in ["tomorrow", "tmr", "tom", "tmrw"] {
        return add_days(today, 1);
    }
    if word in ["yesterday"] {
        return add_days(today, -1);
    }
    for (i, name) in enumerate(WEEKDAYS) {
        if len(word) >= 3 and name.startswith(word) {
            return add_days(today, (i - weekday_of(today)) % 7);
        }
    }
    m = re.fullmatch(r"\+(\d{1,3})d?", word);
    if m {
        return add_days(today, int(m.group(1)));
    }
    try {
        return datetime.date.fromisoformat(word).isoformat();
    } except ValueError {}
    m = re.fullmatch(r"(\d{1,2})[-/](\d{1,2})", word);
    if m {
        year = int(today[:4]);
        try {
            candidate = datetime.date(year, int(m.group(1)), int(m.group(2)));
        } except ValueError {
            raise ValueError(f"'{token}' is not a real date");
        }
        if candidate.isoformat() < add_days(today, -60) {
            candidate = datetime.date(year + 1, candidate.month, candidate.day);
        }
        return candidate.isoformat();
    }
    raise ValueError(f"'{token}' is not a date (try today, tomorrow, fri, +3, 10-05)");
}

"""The next day a recurring task should appear after `day`."""
def:priv next_occurrence(day: str, recur: str) -> str {
    if recur == "daily" {
        return add_days(day, 1);
    }
    if recur == "weekly" {
        return add_days(day, 7);
    }
    if recur == "weekdays" {
        nxt = add_days(day, 1);
        while weekday_of(nxt) >= 5 {
            nxt = add_days(nxt, 1);
        }
        return nxt;
    }
    raise ValueError(f"Unknown repeat rule '{recur}'");
}

obj Parsed {
    has title: str = "",
        priority: int = 2,
        estimate: int = 30,
        day: str = "",
        due: str = "",
        tag: str = "",
        recur: str = "",
        start: int = -1,
        end: int = -1;

    def is_block -> bool {
        return self.start >= 0;
    }
}

def:priv parse_priority(word: str) -> int {
    table = {
        "1": 1, "h": 1, "hi": 1, "high": 1, "!": 1,
        "2": 2, "m": 2, "med": 2, "medium": 2, "normal": 2,
        "3": 3, "l": 3, "lo": 3, "low": 3
    };
    if word.lower() not in table {
        raise ValueError(f"'!{word}' is not a priority (use !high, !med, !low or !1-!3)");
    }
    return table[word.lower()];
}

"""Minutes in 45m, 90min, 1h, 1.5h, 1h30m, 1h30; -1 when `word` is not a duration."""
def:priv parse_duration(word: str) -> int {
    w = word.lower().lstrip("~");
    m = re.fullmatch(r"(\d+)(?:m|min|mins)", w);
    if m {
        return int(m.group(1));
    }
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(?:h|hr|hrs)(?:(\d+)(?:m|min)?)?", w);
    if m {
        return int(round(float(m.group(1)) * 60)) + int(m.group(2) or "0");
    }
    return -1;
}

"""Turn one line of shorthand into task or time-block fields.

  Write lab report !high 1.5h @fri due:sun #eecs449
  Gym 17:00-18:30 @tomorrow
  Stretch 10m *daily
"""
def:priv parse_quick(text: str, today: str) -> Parsed {
    out = Parsed(day=today);
    words: list[str] = [];
    for raw in text.split() {
        low = raw.lower();
        if low.startswith("!") and len(raw) > 1 {
            out.priority = parse_priority(raw[1:]);
        } elif low == "!!" {
            out.priority = 1;
        } elif low.startswith("@") and len(raw) > 1 {
            out.day = parse_date(raw[1:], today);
        } elif low.startswith("due:") and len(raw) > 4 {
            out.due = parse_date(raw[4:], today);
        } elif low.startswith("^") and len(raw) > 1 {
            out.due = parse_date(raw[1:], today);
        } elif low.startswith("#") and len(raw) > 1 {
            out.tag = low[1:];
        } elif low.startswith("*") and len(raw) > 1 {
            if low[1:] not in RECURS {
                raise ValueError(f"'{raw}' is not a repeat rule (use *daily, *weekdays, *weekly)");
            }
            out.recur = low[1:];
        } elif re.fullmatch(r"\d{1,2}(:\d{2})?-\d{1,2}(:\d{2})?", low) {
            (a, b) = low.split("-");
            out.start = to_min(a);
            out.end = to_min(b);
            if out.end <= out.start {
                raise ValueError(f"'{raw}' ends before it starts");
            }
        } elif parse_duration(low) > 0 {
            out.estimate = parse_duration(low);
        } else {
            words.append(raw);
        }
    }
    out.title = " ".join(words).strip();
    if not out.title {
        raise ValueError("Give it a title, e.g. 'Read chapter 3 45m'");
    }
    if out.estimate > 12 * 60 {
        raise ValueError("Estimates over 12h are not plannable; split the task up");
    }
    if out.is_block() {
        out.estimate = out.end - out.start;
    }
    return out;
}

obj Slot {
    has start: int,
        end: int;

    def length -> int {
        return self.end - self.start;
    }
}

obj Job {
    has id: str,
        priority: int = 2,
        estimate: int = 30,
        due: str = "",
        created: str = "";
}

obj Placement {
    has id: str,
        start: int,
        end: int,
        part: int = 1,
        parts: int = 1;
}

obj PlanOut {
    has placements: list[Placement] = [],
        overflow: list[str] = [],
        unplaced_min: int = 0;
}

"""Round up to the next multiple of `step` minutes."""
def:priv ceil_to(total: int, step: int) -> int {
    return ((total + step - 1) // step) * step;
}

"""Open time between day_start and day_end that no busy slot covers."""
def:priv free_slots(day_start: int, day_end: int, busy: list[Slot], not_before: int = 0) -> list[Slot] {
    cursor = max(day_start, ceil_to(not_before, 5));
    out: list[Slot] = [];
    for b in sorted(busy, key=lambda (s: Slot) -> int { return s.start; }) {
        if b.end <= cursor {
            continue;
        }
        if b.start >= day_end {
            break;
        }
        if b.start - cursor >= 5 {
            out.append(Slot(start=cursor, end=min(b.start, day_end)));
        }
        cursor = max(cursor, b.end);
    }
    if day_end - cursor >= 5 {
        out.append(Slot(start=cursor, end=day_end));
    }
    return out;
}

"""Due-today-or-earlier first, then priority, then nearest deadline, then oldest."""
def:priv order_jobs(jobs: list[Job], day: str) -> list[Job] {
    def rank(j: Job) -> tuple[int, int, str, str] {
        urgent = 0 if j.due and j.due <= day else 1;
        return (urgent, j.priority, j.due or "9999-12-31", j.created);
    }
    return sorted(jobs, key=rank);
}

"""Place each job in order: the earliest gap that holds it whole, otherwise split
it across gaps (never into pieces shorter than `min_chunk`). A job that cannot be
fully placed is left out entirely and reported as overflow.
"""
def:priv auto_schedule(jobs: list[Job], free: list[Slot], buffer: int = 10, min_chunk: int = 25) -> PlanOut {
    slots = [Slot(start=s.start, end=s.end) for s in free];
    out = PlanOut();
    for job in jobs {
        whole = [s for s in slots if s.length() >= job.estimate];
        if whole {
            s = whole[0];
            out.placements.append(Placement(id=job.id, start=s.start, end=s.start + job.estimate));
            s.start = min(s.end, s.start + job.estimate + buffer);
            continue;
        }
        trial = [Slot(start=s.start, end=s.end) for s in slots];
        pieces: list[Placement] = [];
        remaining = job.estimate;
        for s in trial {
            if remaining <= 0 {
                break;
            }
            take = min(s.length(), remaining);
            if remaining - take > 0 and remaining - take < min_chunk {
                take = remaining - min_chunk;
            }
            if take < min_chunk {
                continue;
            }
            pieces.append(Placement(id=job.id, start=s.start, end=s.start + take));
            s.start = min(s.end, s.start + take + buffer);
            remaining -= take;
        }
        if remaining > 0 {
            out.overflow.append(job.id);
            out.unplaced_min += job.estimate;
            continue;
        }
        slots = trial;
        for (i, p) in enumerate(pieces) {
            p.part = i + 1;
            p.parts = len(pieces);
            out.placements.append(p);
        }
    }
    out.placements.sort(key=lambda (p: Placement) -> int { return p.start; });
    return out;
}
