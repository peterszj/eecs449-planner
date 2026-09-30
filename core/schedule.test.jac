glob WED: str = "2026-09-30";

test "clock and duration formatting" {
    assert to_min("9:05") == 545;
    assert to_min("24:00") == 1440;
    assert fmt_min(545) == "09:05";
    assert fmt_dur(45) == "45m";
    assert fmt_dur(90) == "1h 30m";
    assert fmt_dur(120) == "2h";
    for bad in ["25:00", "9:75", "noon"] {
        try {
            to_min(bad);
            assert False , bad;
        } except ValueError {}
    }
}

test "dates resolve relative to today" {
    assert parse_date("today", WED) == WED;
    assert parse_date("tmr", WED) == "2026-10-01";
    assert parse_date("wed", WED) == WED;
    assert parse_date("fri", WED) == "2026-10-02";
    assert parse_date("Monday", WED) == "2026-10-05";
    assert parse_date("thurs", WED) == "2026-10-01";
    assert parse_date("+3", WED) == "2026-10-03";
    assert parse_date("10-05", WED) == "2026-10-05";
    assert parse_date("1/15", WED) == "2027-01-15";
    assert parse_date("2026-12-01", WED) == "2026-12-01";
    assert week_start(WED) == "2026-09-28";
    try {
        parse_date("someday", WED);
        assert False;
    } except ValueError {}
}

test "recurrence skips weekends for weekdays" {
    assert next_occurrence("2026-10-02", "weekdays") == "2026-10-05";
    assert next_occurrence(WED, "daily") == "2026-10-01";
    assert next_occurrence(WED, "weekly") == "2026-10-07";
}

test "quick add parses every token" {
    p = parse_quick("Write lab report !high 1.5h @fri due:sun #EECS449", WED);
    assert p.title == "Write lab report";
    assert p.priority == 1;
    assert p.estimate == 90;
    assert p.day == "2026-10-02";
    assert p.due == "2026-10-04";
    assert p.tag == "eecs449";
    assert not p.is_block();

    b = parse_quick("Gym 17:00-18:30 @tmr", WED);
    assert b.is_block();
    assert b.start == 1020 and b.end == 1110 and b.estimate == 90;
    assert b.day == "2026-10-01";

    r = parse_quick("Stretch 10m *weekdays !low", WED);
    assert r.recur == "weekdays" and r.priority == 3 and r.estimate == 10;
    assert r.day == WED;

    d = parse_quick("Email prof", WED);
    assert d.estimate == 30 and d.priority == 2;

    for bad in ["!high 30m", "Thing !urgent", "Thing @someday", "Thing *hourly", "Nap 15:00-14:00"] {
        try {
            parse_quick(bad, WED);
            assert False , bad;
        } except ValueError {}
    }
}

test "free slots subtract busy time and respect now" {
    busy = [Slot(start=600, end=660), Slot(start=720, end=780)];
    free = free_slots(540, 900, busy);
    assert [(s.start, s.end) for s in free] == [(540, 600), (660, 720), (780, 900)];
    later = free_slots(540, 900, busy, not_before=633);
    assert [(s.start, s.end) for s in later] == [(660, 720), (780, 900)];
    assert free_slots(540, 600, [Slot(start=500, end=700)]) == [];
}

test "jobs order by deadline, priority, then age" {
    jobs = [
        Job(id="low", priority=3, created="1"),
        Job(id="high", priority=1, created="2"),
        Job(id="due", priority=3, due=WED, created="3"),
        Job(id="high-old", priority=1, created="0")
    ];
    assert [j.id for j in order_jobs(jobs, WED)] == ["due", "high-old", "high", "low"];
}

test "scheduler fits whole jobs first and splits only when it must" {
    free = [Slot(start=540, end=570), Slot(start=600, end=720)];
    out = auto_schedule(
        [Job(id="a", estimate=45), Job(id="b", estimate=25)], free, buffer=10
    );
    got = [(p.id, p.start, p.end) for p in out.placements];
    # a skips the 30-minute gap it does not fit in; b backfills it.
    assert got == [("b", 540, 565), ("a", 600, 645)];
    assert out.overflow == [];

    split = auto_schedule(
        [Job(id="big", estimate=100)],
        [Slot(start=540, end=600), Slot(start=660, end=720)],
        buffer=0
    );
    assert [(p.start, p.end, p.part, p.parts) for p in split.placements] == [
        (540, 600, 1, 2),
        (660, 700, 2, 2)
    ];

    # a whole fit later in the day beats splitting across earlier gaps
    whole = auto_schedule(
        [Job(id="t", estimate=50)],
        [Slot(start=0, end=45), Slot(start=100, end=200)],
        buffer=0
    );
    assert [(p.start, p.end) for p in whole.placements] == [(100, 150)];

    # a split never leaves a piece shorter than min_chunk: 40 + 20 becomes 35 + 25
    tail = auto_schedule(
        [Job(id="t", estimate=60)],
        [Slot(start=0, end=40), Slot(start=100, end=130)],
        buffer=0,
        min_chunk=25
    );
    assert [(p.start, p.end) for p in tail.placements] == [(0, 35), (100, 125)];

    full = auto_schedule(
        [Job(id="x", estimate=60), Job(id="y", estimate=60)],
        [Slot(start=0, end=70)],
        buffer=10
    );
    assert [p.id for p in full.placements] == ["x"];
    assert full.overflow == ["y"] and full.unplaced_min == 60;
}
