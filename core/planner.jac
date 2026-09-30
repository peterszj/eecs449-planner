"""Dayblock planner service: the one server every client talks to.

Each signed-in user plans on their own root graph:

    root --> Prefs            working hours and scheduling knobs
    root --> Task*            things to do, planned on a day
    root --> Block*           time blocks on a day: fixed commitments
                              or auto-scheduled pieces of a task

All endpoints are def:protect, so data is per user and requires a token.
Dates and the current time always come from the client, so "today" is the
user's today, not the server's.
"""
import datetime;
import from core.schedule {
    Slot,
    Job,
    Parsed,
    parse_quick,
    parse_date,
    next_occurrence,
    free_slots,
    auto_schedule,
    order_jobs,
    fmt_min,
    fmt_dur,
    to_min,
    add_days,
    week_start
}

node Prefs {
    has day_start: int = 540,
        day_end: int = 1260,
        buffer: int = 10,
        min_chunk: int = 25;
}

node Task {
    has title: str,
        priority: int = 2,
        estimate: int = 30,
        day: str = "",
        due: str = "",
        tag: str = "",
        recur: str = "",
        done: bool = False,
        done_on: str = "",
        created: str = "";
}

node Block {
    has day: str,
        start: int,
        end: int,
        label: str = "",
        kind: str = "fixed",
        task_id: str = "",
        part: int = 1,
        parts: int = 1;
}

obj TaskView {
    has id: str,
        title: str,
        priority: int,
        estimate: int,
        day: str,
        due: str,
        tag: str,
        recur: str,
        done: bool,
        quick: str,
        slot: str = "",
        due_soon: bool = False;
}

obj BlockView {
    has id: str,
        day: str,
        start: int,
        end: int,
        time: str,
        label: str,
        kind: str,
        task_id: str = "",
        done: bool = False,
        priority: int = 2,
        part: int = 1,
        parts: int = 1;
}

obj PrefsView {
    has day_start: str = "09:00",
        day_end: str = "21:00",
        buffer: int = 10;
}

obj DayView {
    has day: str = "",
        label: str = "",
        tasks: list[TaskView] = [],
        blocks: list[BlockView] = [],
        overdue: int = 0,
        done_count: int = 0,
        total_count: int = 0,
        open_min: int = 0,
        free_min: int = 0,
        unscheduled: int = 0,
        now_block: BlockView | None = None,
        next_block: BlockView | None = None,
        prefs: PrefsView = PrefsView();
}

obj DaySummary {
    has day: str,
        label: str,
        total: int = 0,
        done: int = 0,
        task_min: int = 0,
        fixed_min: int = 0,
        capacity_min: int = 0;
}

obj WeekView {
    has start: str = "",
        days: list[DaySummary] = [],
        streak: int = 0,
        done_week: int = 0,
        done_min_week: int = 0;
}

obj AddResult {
    has kind: str,
        id: str,
        message: str;
}

obj PlanResult {
    has placed: int = 0,
        split: int = 0,
        overflow: list[str] = [],
        message: str = "";
}

# ---------------------------------------------------------------- helpers

def:priv label_of(day: str) -> str {
    return datetime.date.fromisoformat(day).strftime("%a, %b %-d");
}

def:priv short_label(day: str) -> str {
    return datetime.date.fromisoformat(day).strftime("%a %-m/%-d");
}

def:priv check_day(day: str) -> str {
    try {
        return datetime.date.fromisoformat(day).isoformat();
    } except ValueError {
        raise ValueError(f"'{day}' is not a date like 2026-10-05");
    }
}

def:priv my_prefs -> Prefs {
    found = [root-->[?:Prefs]];
    if found {
        return found[0];
    }
    return root ++> Prefs();
}

def:priv tasks_on(day: str) -> list[Task] {
    return [t for t in [root-->[?:Task]] if t.day == day];
}

def:priv blocks_on(day: str) -> list[Block] {
    return [b for b in [root-->[?:Block]] if b.day == day];
}

def:priv find_task(id: str) -> Task {
    for t in [root-->[?:Task]] {
        if jid(t) == id {
            return t;
        }
    }
    raise ValueError("That task no longer exists. Refresh and try again.");
}

def:priv drop_blocks_of(task_id: str) {
    for b in [root-->[?:Block]] {
        if b.task_id == task_id {
            del b;
        }
    }
}

"""The task written back in quick-add shorthand, so editing reuses the parser."""
def:priv to_quick(t: Task) -> str {
    parts = [t.title, {1: "!high", 2: "!med", 3: "!low"}[t.priority], fmt_dur(t.estimate).replace(" ", "")];
    if t.day {
        parts.append("@" + t.day);
    }
    if t.due {
        parts.append("due:" + t.due);
    }
    if t.tag {
        parts.append("#" + t.tag);
    }
    if t.recur {
        parts.append("*" + t.recur);
    }
    return " ".join(parts);
}

def:priv task_view(t: Task, slots: dict[str, list[Block]]) -> TaskView {
    mine = slots.get(jid(t), []);
    slot = "";
    if mine {
        slot = fmt_min(mine[0].start) + (f" +{len(mine) - 1}" if len(mine) > 1 else "");
    }
    return TaskView(
        id=jid(t),
        title=t.title,
        priority=t.priority,
        estimate=t.estimate,
        day=t.day,
        due=t.due,
        tag=t.tag,
        recur=t.recur,
        done=t.done,
        quick=to_quick(t),
        slot=slot,
        due_soon=bool(t.due) and not t.done and t.due <= add_days(t.day or t.due, 1)
    );
}

def:priv block_view(b: Block, tasks: dict[str, Task]) -> BlockView {
    t = tasks.get(b.task_id, None);
    return BlockView(
        id=jid(b),
        day=b.day,
        start=b.start,
        end=b.end,
        time=fmt_min(b.start) + "–" + fmt_min(b.end),
        label=t.title if t else b.label,
        kind=b.kind,
        task_id=b.task_id,
        done=t.done if t else False,
        priority=t.priority if t else 2,
        part=b.part,
        parts=b.parts
    );
}

def:priv fixed_minutes(blocks: list[Block], p: Prefs) -> int {
    return sum(
        max(0, min(b.end, p.day_end) - max(b.start, p.day_start))
        for b in blocks
        if b.kind == "fixed"
    );
}

def:priv make_task(fields: Parsed) -> Task {
    return root ++> Task(
        title=fields.title,
        priority=fields.priority,
        estimate=fields.estimate,
        day=fields.day,
        due=fields.due,
        tag=fields.tag,
        recur=fields.recur,
        created=datetime.datetime.now(datetime.UTC).isoformat()
    );
}

def:priv describe(t: Task) -> str {
    bits = [label_of(t.day), fmt_dur(t.estimate), {1: "high", 2: "medium", 3: "low"}[t.priority] + " priority"];
    if t.due {
        bits.append("due " + short_label(t.due));
    }
    if t.recur {
        bits.append("repeats " + t.recur);
    }
    return f"Added “{t.title}” · " + " · ".join(bits);
}

# ---------------------------------------------------------------- reads

"""Everything a client needs to draw one day. `now_min` is minutes after
midnight on the client, or -1 when `day` is not today."""
def:protect get_day(day: str, now_min: int) -> DayView {
    day = check_day(day);
    p = my_prefs();
    tasks = tasks_on(day);
    blocks = sorted(blocks_on(day), key=lambda (b: Block) -> int { return b.start; });
    by_id = {jid(t): t for t in tasks};
    slots: dict[str, list[Block]] = {};
    for b in blocks {
        if b.task_id {
            slots.setdefault(b.task_id, []).append(b);
        }
    }
    tasks.sort(
        key=lambda (t: Task) -> tuple[bool, int, int, str] {
            first = slots.get(jid(t), []);
            return (t.done, first[0].start if first else 9999, t.priority, t.created);
        }
    );
    views = [block_view(b, by_id) for b in blocks];
    open_tasks = [t for t in tasks if not t.done];
    fixed = [Slot(start=b.start, end=b.end) for b in blocks if b.kind == "fixed"];
    free = free_slots(p.day_start, p.day_end, fixed, max(now_min, 0));
    now_block: BlockView | None = None;
    next_block: BlockView | None = None;
    if now_min >= 0 {
        for v in views {
            if v.done {
                continue;
            }
            if v.start <= now_min and now_min < v.end and not now_block {
                now_block = v;
            } elif v.start > now_min and not next_block {
                next_block = v;
            }
        }
    }
    return DayView(
        day=day,
        label=label_of(day),
        tasks=[task_view(t, slots) for t in tasks],
        blocks=views,
        overdue=len(
            [t for t in [root-->[?:Task]] if not t.done and t.day and t.day < day]
        ) if now_min >= 0 else 0,
        done_count=len(tasks) - len(open_tasks),
        total_count=len(tasks),
        open_min=sum(t.estimate for t in open_tasks),
        free_min=sum(s.length() for s in free),
        unscheduled=len([t for t in open_tasks if jid(t) not in slots]),
        now_block=now_block,
        next_block=next_block,
        prefs=PrefsView(
            day_start=fmt_min(p.day_start), day_end=fmt_min(p.day_end), buffer=p.buffer
        )
    );
}

"""Seven-day overview (Mon-Sun around `day`) plus a completion streak ending at `today`."""
def:protect get_week(day: str, today: str) -> WeekView {
    start = week_start(check_day(day));
    today = check_day(today);
    p = my_prefs();
    all_tasks = [root-->[?:Task]];
    all_blocks = [root-->[?:Block]];
    days: list[DaySummary] = [];
    for i in range(7) {
        d = add_days(start, i);
        ts = [t for t in all_tasks if t.day == d];
        fixed = fixed_minutes([b for b in all_blocks if b.day == d], p);
        days.append(
            DaySummary(
                day=d,
                label=short_label(d),
                total=len(ts),
                done=len([t for t in ts if t.done]),
                task_min=sum(t.estimate for t in ts),
                fixed_min=fixed,
                capacity_min=max(0, p.day_end - p.day_start - fixed)
            )
        );
    }
    done_days = {t.done_on for t in all_tasks if t.done and t.done_on};
    cursor = today if today in done_days else add_days(today, -1);
    streak = 0;
    while cursor in done_days {
        streak += 1;
        cursor = add_days(cursor, -1);
    }
    week_done = [t for t in all_tasks if t.done and start <= t.done_on and t.done_on <= add_days(start, 6)];
    return WeekView(
        start=start,
        days=days,
        streak=streak,
        done_week=len(week_done),
        done_min_week=sum(t.estimate for t in week_done)
    );
}

# ---------------------------------------------------------------- writes

"""One line of shorthand -> a task, or a fixed block when it has a time range."""
def:protect quick_add(text: str, today: str) -> AddResult {
    fields = parse_quick(text, check_day(today));
    if fields.is_block() {
        b = root ++> Block(day=fields.day, start=fields.start, end=fields.end, label=fields.title);
        return AddResult(
            kind="block",
            id=jid(b),
            message=f"Blocked {fmt_min(fields.start)}–{fmt_min(fields.end)} on {label_of(fields.day)} for “{fields.title}”"
        );
    }
    t = make_task(fields);
    return AddResult(kind="task", id=jid(t), message=describe(t));
}

"""Rewrite a task from shorthand (see TaskView.quick). Moving it to another day
or changing its length clears its scheduled blocks."""
def:protect edit_task(id: str, text: str, today: str) -> TaskView {
    t = find_task(id);
    fields = parse_quick(text, check_day(today));
    if fields.is_block() {
        raise ValueError("Tasks cannot hold a time range; add it as its own block instead");
    }
    if fields.day != t.day or fields.estimate != t.estimate {
        drop_blocks_of(id);
    }
    t.title = fields.title;
    t.priority = fields.priority;
    t.estimate = fields.estimate;
    t.day = fields.day;
    t.due = fields.due;
    t.tag = fields.tag;
    t.recur = fields.recur;
    return task_view(t, {});
}

"""Check a task off (or back on). Finishing a repeating task queues its next one."""
def:protect toggle_task(id: str, today: str) -> TaskView {
    t = find_task(id);
    t.done = not t.done;
    t.done_on = check_day(today) if t.done else "";
    if t.done and t.recur {
        nxt = next_occurrence(t.day, t.recur);
        exists = [o for o in [root-->[?:Task]] if o.title == t.title and o.recur == t.recur and o.day == nxt];
        if not exists {
            make_task(
                Parsed(
                    title=t.title,
                    priority=t.priority,
                    estimate=t.estimate,
                    day=nxt,
                    tag=t.tag,
                    recur=t.recur
                )
            );
        }
    }
    return task_view(t, {});
}

def:protect move_task(id: str, day: str) -> TaskView {
    t = find_task(id);
    t.day = check_day(day);
    drop_blocks_of(id);
    return task_view(t, {});
}

def:protect set_priority(id: str, priority: int) -> TaskView {
    if priority not in [1, 2, 3] {
        raise ValueError("Priority is 1 (high), 2 (medium) or 3 (low)");
    }
    t = find_task(id);
    t.priority = priority;
    return task_view(t, {});
}

def:protect delete_task(id: str) -> bool {
    t = find_task(id);
    drop_blocks_of(id);
    del t;
    return True;
}

def:protect add_block(day: str, start: str, end: str, label: str) -> BlockView {
    s = to_min(start);
    e = to_min(end);
    if e <= s {
        raise ValueError("A block must end after it starts");
    }
    if not label.strip() {
        raise ValueError("Give the block a name");
    }
    b = root ++> Block(day=check_day(day), start=s, end=e, label=label.strip());
    return block_view(b, {});
}

def:protect delete_block(id: str) -> bool {
    for b in [root-->[?:Block]] {
        if jid(b) == id {
            del b;
            return True;
        }
    }
    raise ValueError("That block no longer exists. Refresh and try again.");
}

"""Move every unfinished task from earlier days onto `today`."""
def:protect rollover(today: str) -> int {
    today = check_day(today);
    moved = 0;
    for t in [root-->[?:Task]] {
        if not t.done and t.day and t.day < today {
            drop_blocks_of(jid(t));
            t.day = today;
            moved += 1;
        }
    }
    return moved;
}

"""Auto-schedule `day`: clear its unfinished task blocks, then fit every open
task into the gaps between fixed blocks, starting no earlier than `now_min`."""
def:protect auto_plan(day: str, now_min: int) -> PlanResult {
    day = check_day(day);
    p = my_prefs();
    tasks = tasks_on(day);
    by_id = {jid(t): t for t in tasks};
    for b in blocks_on(day) {
        if b.kind == "task" {
            owner = by_id.get(b.task_id, None);
            if not owner or not owner.done {
                del b;
            }
        }
    }
    busy = [Slot(start=b.start, end=b.end) for b in blocks_on(day)];
    kept = {b.task_id for b in blocks_on(day) if b.task_id};
    jobs = [
        Job(id=jid(t), priority=t.priority, estimate=t.estimate, due=t.due, created=t.created)
        for t in tasks
        if not t.done and jid(t) not in kept
    ];
    if not jobs {
        return PlanResult(message="Nothing left to schedule on " + label_of(day));
    }
    plan = auto_schedule(
        order_jobs(jobs, day),
        free_slots(p.day_start, p.day_end, busy, max(now_min, 0)),
        p.buffer,
        p.min_chunk
    );
    for pl in plan.placements {
        root ++> Block(
            day=day,
            start=pl.start,
            end=pl.end,
            label=by_id[pl.id].title,
            kind="task",
            task_id=pl.id,
            part=pl.part,
            parts=pl.parts
        );
    }
    placed_ids = {pl.id for pl in plan.placements};
    split = len({pl.id for pl in plan.placements if pl.parts > 1});
    names = [by_id[i].title for i in plan.overflow];
    msg = f"Scheduled {len(placed_ids)} task{'s' if len(placed_ids) != 1 else ''}";
    if split {
        msg += f" ({split} split across gaps)";
    }
    if names {
        msg += f" · {len(names)} didn't fit ({fmt_dur(plan.unplaced_min)}): " + ", ".join(names);
    }
    return PlanResult(placed=len(placed_ids), split=split, overflow=names, message=msg);
}

def:protect clear_plan(day: str) -> int {
    cleared = 0;
    for b in blocks_on(check_day(day)) {
        if b.kind == "task" {
            del b;
            cleared += 1;
        }
    }
    return cleared;
}

def:protect get_prefs -> PrefsView {
    p = my_prefs();
    return PrefsView(day_start=fmt_min(p.day_start), day_end=fmt_min(p.day_end), buffer=p.buffer);
}

def:protect set_prefs(day_start: str, day_end: str, buffer: int = 10) -> PrefsView {
    s = to_min(day_start);
    e = to_min(day_end);
    if e - s < 60 {
        raise ValueError("Your working day needs to be at least an hour long");
    }
    if buffer < 0 or buffer > 60 {
        raise ValueError("Breaks between tasks must be 0–60 minutes");
    }
    p = my_prefs();
    p.day_start = s;
    p.day_end = e;
    p.buffer = buffer;
    return get_prefs();
}

"""Fill an empty account with a realistic student day so the app can be tried at once."""
def:protect load_sample(today: str) -> int {
    today = check_day(today);
    if [root-->[?:Task]] {
        raise ValueError("Samples only load into an empty planner");
    }
    lines = [
        "EECS 449 lecture 13:30-15:00",
        "Lunch 12:00-12:45",
        "Gym 18:00-19:00",
        "Finish Jac planner README !high 45m due:today #eecs449",
        "Problem set 3 !high 2h due:tmr #math",
        "Read attention paper 1h #research",
        "Reply to advisor email 15m !high",
        "Grocery run 40m !low",
        "Stretch 10m *daily !low",
        "Plan next week 30m @tmr",
        "Weekly review 30m @fri *weekly"
    ];
    for line in lines {
        quick_add(line, today);
    }
    return len(lines);
}
