"""Dayblock's one UI, shared by the web app and the mobile app.

Wide screens (web) show the plan and the task list side by side; narrow
screens (phones) switch between Plan / Tasks / Week tabs. Every action is a
bridged call to the planner service, followed by a refresh.
"""
import from "@jac/mobui" {
    View,
    Text,
    TextInput,
    Pressable,
    ScrollView,
    Platform,
    useWindowDimensions
}
import from "@jac/runtime" {
    jacLogin,
    jacSignup,
    jacLogout,
    jacIsLoggedIn,
    SignupResult,
    __getLocalStorage,
    __setLocalStorage
}
import from core.planner {
    DayView,
    WeekView,
    TaskView,
    BlockView,
    AddResult,
    PlanResult,
    PrefsView,
    DaySummary,
    get_day,
    get_week,
    quick_add,
    edit_task,
    toggle_task,
    move_task,
    set_priority,
    delete_task,
    delete_block,
    rollover,
    auto_plan,
    clear_plan,
    set_prefs,
    load_sample
}
import from ui.theme { S, C, prio_color }
import from ui.parts {
    Button,
    Chip,
    Check,
    LoadBar,
    local_day,
    shift_day,
    now_minutes,
    clock,
    dur,
    problem
}

glob HINT: str = "!high 45m @fri due:sun #class *daily  ·  a range like 14:00-15:30 blocks time";

def to_minutes(hhmm: str) -> int {
    parts = hhmm.split(":");
    return int(parts[0]) * 60 + int(parts[1]);
}

"""Blocks interleaved with the free gaps (15m+) between them, inside working hours.
Gaps that are already over (before `not_before`) are dropped or trimmed."""
def timeline_rows(blocks: list[BlockView], prefs: PrefsView, not_before: int) -> list[dict[str, any]] {
    rows: list[dict[str, any]] = [];
    cursor = to_minutes(prefs.day_start);
    finish = to_minutes(prefs.day_end);
    for b in blocks {
        start = max(cursor, not_before);
        if b.start - start >= 15 {
            rows.append({"kind": "gap", "start": start, "end": b.start, "key": "gap-" + str(start)});
        }
        rows.append({"kind": "block", "block": b, "start": b.start, "key": b.id});
        cursor = max(cursor, b.end);
    }
    start = max(cursor, not_before);
    if finish - start >= 15 {
        rows.append({"kind": "gap", "start": start, "end": finish, "key": "gap-" + str(start)});
    }
    return rows;
}

"""Where the mobile app looks for the server before the user changes it: the page's
own origin in the browser preview (its dev backend shares the same data), else the
address `jac run --dev mobile` injected, else the usual local server."""
def default_server -> str {
    if Platform.OS == "web" and globalThis.location {
        return str(globalThis.location.origin);
    }
    return str(globalThis.__JAC_API_BASE_URL__ or "http://localhost:8000");
}

"""True when a Dayblock server answers at `address` within five seconds."""
async def reachable(address: str) -> bool {
    ctrl: any = new(AbortController);
    timer: any = setTimeout(lambda { ctrl.abort(); }, 5000);
    ok: bool = False;
    try {
        resp: any = await fetch(address + "/healthz", {"signal": ctrl.signal});
        ok = bool(resp.ok);
    } except Exception {
        ok = False;
    }
    clearTimeout(timer);
    return ok;
}

def:pub PlannerApp(remote: bool = False) -> JsxElement {
    has server: str = "",
        connected: bool = not remote,
        logged: bool = False,
        username: str = "",
        password: str = "",
        signup: bool = False,
        busy: bool = False,
        loading: bool = False,
        error: str = "",
        notice: str = "",
        day: str = "",
        view: DayView = DayView(),
        week: WeekView = WeekView(),
        tab: str = "plan",
        draft: str = "",
        editing: str = "",
        edit_text: str = "",
        pref_start: str = "",
        pref_end: str = "",
        pref_buffer: str = "",
        clock_now: int = 0;

    wide = useWindowDimensions().width >= 920;
    prefs = view.prefs or PrefsView();
    blocks: list[BlockView] = view.blocks or [];
    task_list: list[TaskView] = view.tasks or [];
    days: list[DaySummary] = week.days or [];
    today = local_day();
    is_today = day == today;

    def fail(e: any, fallback: str) {
        text = problem(e, fallback);
        if "UNAUTHORIZED" in text.upper() or "401" in text {
            jacLogout();
            logged = False;
            error = "Your session ended. Please sign in again.";
            return;
        }
        error = text;
    }

    async def refresh {
        loading = True;
        fresh: DayView = DayView();
        fresh_week: WeekView = WeekView();
        try {
            clock_now = now_minutes();
            fresh = await get_day(day, clock_now if day == local_day() else -1);
            fresh_week = await get_week(day, local_day());
            view = fresh;
            week = fresh_week;
            if not pref_start {
                pref_start = fresh.prefs.day_start;
                pref_end = fresh.prefs.day_end;
                pref_buffer = str(fresh.prefs.buffer);
            }
        } except Exception as e {
            fail(e, "Could not reach the Dayblock server. Check it is running, then Refresh.");
        } finally {
            loading = False;
        }
    }

    async def go(target: str) {
        day = target;
        editing = "";
        await refresh();
    }

    can with entry {
        day = local_day();
        logged = jacIsLoggedIn();
        username = __getLocalStorage("dayblock_user") or "";
        saved = __getLocalStorage("dayblock_server") or "";
        server = saved or default_server();
        if remote and saved {
            globalThis.__JAC_API_BASE_URL__ = saved;
            connected = True;
        }
        if connected and logged {
            refresh();
        }
    }

    async def connect {
        address = server.strip().rstrip("/");
        if not address.startswith("http://") and not address.startswith("https://") {
            error = "Enter an address that starts with http:// or https://";
            return;
        }
        server = address;
        busy = True;
        error = "";
        up: bool = False;
        up = await reachable(address);
        busy = False;
        if not up {
            error = "No Dayblock server answered at " + address + ". Is `jac run` running, and is the phone on the same Wi-Fi?";
            return;
        }
        globalThis.__JAC_API_BASE_URL__ = address;
        __setLocalStorage("dayblock_server", address);
        jacLogout();
        logged = False;
        connected = True;
        error = "";
    }

    async def authenticate {
        if busy {
            return;
        }
        name = username.strip();
        if not name or not password {
            error = "Enter a username and a password.";
            return;
        }
        busy = True;
        error = "";
        made: SignupResult | None = None;
        ok: bool = False;
        try {
            if signup {
                made = await jacSignup(name, password);
                if not made.success {
                    error = made.error or "Could not create that account. Try another username.";
                    return;
                }
            }
            ok = await jacLogin(name, password);
            if not ok {
                error = "Wrong username or password.";
                return;
            }
            __setLocalStorage("dayblock_user", name);
            logged = True;
            password = "";
            day = local_day();
            await refresh();
        } except Exception as e {
            error = problem(e, "Could not reach the server. Is it running?");
        } finally {
            busy = False;
        }
    }

    async def sign_out {
        jacLogout();
        logged = False;
        view = DayView();
        week = WeekView();
        pref_start = "";
        notice = "";
        error = "";
    }

    """Every mutation goes through here: call the service, show its message, refresh."""
    async def act(kind: str, id: str = "", value: str = "") {
        if busy {
            return;
        }
        busy = True;
        error = "";
        added: AddResult | None = None;
        planned: PlanResult | None = None;
        count: int = 0;
        try {
            if kind == "add" {
                if not draft.strip() {
                    return;
                }
                added = await quick_add(draft.strip(), local_day());
                notice = added.message;
                draft = "";
            } elif kind == "toggle" {
                await toggle_task(id, local_day());
                notice = "";
            } elif kind == "priority" {
                await set_priority(id, int(value));
            } elif kind == "tomorrow" {
                await move_task(id, shift_day(day, 1));
                notice = "Moved to " + shift_day(day, 1);
            } elif kind == "today" {
                await move_task(id, local_day());
                notice = "Moved to today";
            } elif kind == "delete" {
                await delete_task(id);
                notice = "Task deleted";
            } elif kind == "unblock" {
                await delete_block(id);
                notice = "Block removed";
            } elif kind == "edit" {
                await edit_task(id, edit_text, local_day());
                editing = "";
                notice = "Saved";
            } elif kind == "plan" {
                planned = await auto_plan(day, now_minutes() if day == local_day() else -1);
                notice = planned.message;
            } elif kind == "clear" {
                count = await clear_plan(day);
                notice = "Cleared " + str(count) + " scheduled block" + ("" if count == 1 else "s");
            } elif kind == "rollover" {
                count = await rollover(local_day());
                notice = "Moved " + str(count) + " unfinished task" + ("" if count == 1 else "s") + " to today";
            } elif kind == "prefs" {
                await set_prefs(pref_start, pref_end, int(pref_buffer or "0"));
                notice = "Working hours saved";
            } elif kind == "sample" {
                count = await load_sample(local_day());
                notice = "Loaded " + str(count) + " sample items. Try Auto-plan!";
            }
            await refresh();
        } except Exception as e {
            fail(e, "That did not work. Refresh and try again.");
        } finally {
            busy = False;
        }
    }

    # ------------------------------------------------------------ sections

    header =
        <View style={S.header}>
            <Text style={S.brand}>
                dayblock<Text style={S.brandDot}>.</Text>
            </Text>
            {<View style={S.row}>
                <Text style={S.small}>@{username}</Text>
                <Button label="Refresh" quiet={True} small={True} action={refresh} disabled={loading}/>
                <Button label="Sign out" quiet={True} small={True} action={sign_out}/>
            </View>
                if logged
                else None}
        </View>;

    messages =
        <View style={S.stack}>
            {<View style={[S.banner, {"backgroundColor": C.bad_soft}]}>
                <Text accessibilityRole="alert" style={[S.body, {"color": C.bad_ink}]}>{error}</Text>
            </View>
                if error
                else None}
            {<View style={[S.banner, {"backgroundColor": C.good_soft}, S.between]}>
                <Text style={[S.body, {"color": C.good, "flex": 1}]}>{notice}</Text>
                <Pressable onPress={lambda { notice = ""; }} accessibilityLabel="Dismiss">
                    <Text style={S.small}>✕</Text>
                </Pressable>
            </View>
                if notice and not error
                else None}
        </View>
            if error or notice
            else None;

    if not connected {
        return
            <ScrollView style={S.screen} contentContainerStyle={S.page} keyboardShouldPersistTaps="handled">
                {header}
                {messages}
                <View style={S.card}>
                    <Text style={S.h2}>Connect to your Dayblock server</Text>
                    <Text style={S.small}>
                        On a phone use your computer's LAN address, e.g. http://192.168.1.10:8000 (run `jac run` on the computer first).
                    </Text>
                    <TextInput
                        accessibilityLabel="Server address"
                        style={S.input}
                        value={server}
                        autoCapitalize="none"
                        autoCorrect={False}
                        onChangeText={lambda (t: str) { server = t; }}
                        onSubmitEditing={connect}
                    />
                    <Button label={"Checking…" if busy else "Connect"} action={connect} disabled={busy}/>
                </View>
            </ScrollView>;
    }

    if not logged {
        return
            <ScrollView style={S.screen} contentContainerStyle={S.page} keyboardShouldPersistTaps="handled">
                {header}
                <View style={[S.stack, {"maxWidth": 440, "width": "100%", "alignSelf": "center", "paddingTop": 24}]}>
                    <Text style={S.h1}>Plan the day in blocks.</Text>
                    <Text style={S.body}>
                        Jot tasks in one line, pin your fixed commitments, and let Dayblock fit everything else around them, on the web, your phone, or your terminal.
                    </Text>
                    {messages}
                    <View style={S.card}>
                        <Text style={S.h2}>{"Create your account" if signup else "Sign in"}</Text>
                        <TextInput
                            accessibilityLabel="Username"
                            style={S.input}
                            placeholder="Username"
                            placeholderTextColor={C.faint}
                            value={username}
                            autoCapitalize="none"
                            autoCorrect={False}
                            onChangeText={lambda (t: str) { username = t; }}
                        />
                        <TextInput
                            accessibilityLabel="Password"
                            style={S.input}
                            placeholder="Password (8+ characters)"
                            placeholderTextColor={C.faint}
                            value={password}
                            secureTextEntry={True}
                            onChangeText={lambda (t: str) { password = t; }}
                            onSubmitEditing={authenticate}
                        />
                        <Button
                            label={"Please wait…" if busy else "Create account" if signup else "Sign in"}
                            action={authenticate}
                            disabled={busy}
                        />
                        <Button
                            label={"I already have an account" if signup else "New here? Create an account"}
                            quiet={True}
                            action={lambda {
                                signup = not signup;
                                error = "";
                            }}
                        />
                    </View>
                    {<Button
                        label="Change server"
                        quiet={True}
                        small={True}
                        action={lambda {
                            connected = False;
                            error = "";
                        }}
                    />
                        if remote
                        else None}
                </View>
            </ScrollView>;
    }

    day_nav =
        <View style={S.between}>
            <View style={{"gap": 2, "flex": 1}}>
                <Text style={S.eyebrow}>{"TODAY" if is_today else "PLANNING"}</Text>
                <Text accessibilityRole="header" style={S.h1}>{view.label or "…"}</Text>
            </View>
            <View style={S.row}>
                <Button label="‹" quiet={True} small={True} action={lambda { go(shift_day(day, -1)); }}/>
                {<Button label="Today" quiet={True} small={True} action={lambda { go(local_day()); }}/>
                    if not is_today
                    else None}
                <Button label="›" quiet={True} small={True} action={lambda { go(shift_day(day, 1)); }}/>
            </View>
        </View>;

    quick =
        <View style={S.card}>
            <View style={S.row}>
                <TextInput
                    accessibilityLabel="Quick add"
                    style={[S.input, S.quickInput]}
                    placeholder="Add a task… e.g. Problem set 3 !high 2h @fri"
                    placeholderTextColor={C.faint}
                    value={draft}
                    autoCapitalize="none"
                    autoCorrect={False}
                    onChangeText={lambda (t: str) { draft = t; }}
                    onSubmitEditing={lambda { act("add"); }}
                    returnKeyType="done"
                />
                <Button label="Add" action={lambda { act("add"); }} disabled={busy or not draft.strip()}/>
            </View>
            <Text style={S.tiny}>{HINT}</Text>
        </View>;

    overdue =
        <View style={[S.banner, {"backgroundColor": C.warn_soft}, S.between]}>
            <Text style={[S.body, {"color": C.warn_ink, "flex": 1}]}>
                {str(view.overdue)} unfinished task{"" if view.overdue == 1 else "s"} from earlier days
            </Text>
            <Button label="Move to today" small={True} action={lambda { act("rollover"); }} disabled={busy}/>
        </View>
            if is_today and view.overdue > 0
            else None;

    now_card =
        <View style={[S.card, {"backgroundColor": C.accent_soft, "borderColor": C.accent_soft}]}>
            {<View style={{"gap": 2}}>
                <Text style={[S.eyebrow, {"color": C.accent}]}>NOW · UNTIL {clock(view.now_block.end)}</Text>
                <Text style={[S.h2, {"fontSize": 18}]}>{view.now_block.label}</Text>
            </View>
                if view.now_block
                else <Text style={S.h2}>Free right now</Text>}
            {<Text style={S.small}>
                Next at {clock(view.next_block.start)} · {view.next_block.label}
                {" (in " + dur(view.next_block.start - clock_now) + ")"}
            </Text>
                if view.next_block
                else <Text style={S.small}>Nothing else on the timeline today.</Text>}
        </View>
            if is_today and view.total_count + len(blocks) > 0
            else None;

    summary =
        <View style={S.card}>
            <View style={S.between}>
                <View>
                    <Text style={S.stat}>{str(view.done_count)}/{str(view.total_count)}</Text>
                    <Text style={S.small}>tasks done</Text>
                </View>
                <View style={{"alignItems": "flex-end"}}>
                    <Text style={[S.stat, {"color": C.high if view.open_min > view.free_min else C.ink}]}>
                        {dur(view.open_min)}
                    </Text>
                    <Text style={S.small}>to do · {dur(view.free_min)} free{" from now" if is_today else ""}</Text>
                </View>
            </View>
            <LoadBar used={view.open_min} total={view.free_min}/>
            {<Text style={[S.small, {"color": C.high}]}>
                Over-booked by {dur(view.open_min - view.free_min)}: auto-plan will list what does not fit.
            </Text>
                if view.open_min > view.free_min
                else None}
            <View style={S.wrap}>
                <Button
                    label={"Planning…" if busy else "Auto-plan " + ("rest of today" if is_today else "this day")}
                    action={lambda { act("plan"); }}
                    disabled={busy or view.total_count == view.done_count}
                />
                <Button label="Clear plan" quiet={True} action={lambda { act("clear"); }} disabled={busy}/>
                {<Text style={S.small}>{str(view.unscheduled)} not on the timeline yet</Text>
                    if view.unscheduled > 0
                    else None}
            </View>
        </View>;

    timeline =
        <View style={S.card}>
            <View style={S.between}>
                <Text style={S.h2}>Timeline</Text>
                <Text style={S.small}>{prefs.day_start}–{prefs.day_end}</Text>
            </View>
            {for row in timeline_rows(blocks, prefs, clock_now if is_today else 0) {
                <View key={row["key"]} style={S.row}>
                    <View style={S.timeCol}>
                        <Text style={S.timeText}>{clock(row["start"])}</Text>
                    </View>
                    {<View style={S.gap}>
                        <Text style={S.tiny}>free · {dur(row["end"] - row["start"])}</Text>
                    </View>
                        if row["kind"] == "gap"
                        else <View
                            style={[
                                S.block,
                                {
                                    "backgroundColor": C.fixed
                                        if row["block"].kind == "fixed"
                                        else C.good_soft if row["block"].done else C.accent_soft,
                                    "borderLeftColor": C.fixed_ink
                                        if row["block"].kind == "fixed"
                                        else C.good if row["block"].done else prio_color(row["block"].priority)
                                },
                                {"borderWidth": 2, "borderColor": C.accent}
                                    if view.now_block and view.now_block.id == row["block"].id
                                    else {}
                            ]}
                        >
                            <View style={S.between}>
                                <Text
                                    style={[
                                        S.taskTitle,
                                        S.doneTitle if row["block"].done else {},
                                        {"flex": 1}
                                    ]}
                                >
                                    {row["block"].label}
                                    {(" (" + str(row["block"].part) + "/" + str(row["block"].parts) + ")")
                                        if row["block"].parts > 1
                                        else ""}
                                </Text>
                                {<Check
                                    done={row["block"].done}
                                    priority={row["block"].priority}
                                    label={"Done: " + row["block"].label}
                                    action={lambda { act("toggle", row["block"].task_id); }}
                                />
                                    if row["block"].kind == "task"
                                    else <Pressable
                                        accessibilityLabel={"Remove block " + row["block"].label}
                                        onPress={lambda { act("unblock", row["block"].id); }}
                                        hitSlop={8}
                                    >
                                        <Text style={S.small}>✕</Text>
                                    </Pressable>}
                            </View>
                            <Text style={S.small}>
                                {row["block"].time} · {dur(row["block"].end - row["block"].start)}
                                {" · fixed" if row["block"].kind == "fixed" else ""}
                            </Text>
                        </View>}
                </View>
            }}
            {<Text style={S.small}>
                Nothing scheduled. Add tasks, block fixed time with a range like “Lecture 13:30-15:00”, then Auto-plan.
            </Text>
                if not blocks
                else None}
        </View>;

    tasks =
        <View style={S.card}>
            <View style={S.between}>
                <Text style={S.h2}>Tasks</Text>
                <Text style={S.small}>{str(view.total_count - view.done_count)} open</Text>
            </View>
            {<View style={S.stack}>
                <Text style={S.body}>No tasks on this day yet.</Text>
                {<Button
                    label="Load a sample student day"
                    quiet={True}
                    action={lambda { act("sample"); }}
                    disabled={busy}
                />
                    if is_today and sum([d.total for d in days]) == 0
                    else None}
            </View>
                if not task_list
                else None}
            {for t in task_list {
                <View key={t.id} style={S.taskRow}>
                    <Check
                        done={t.done}
                        priority={t.priority}
                        label={"Done: " + t.title}
                        action={lambda { act("toggle", t.id); }}
                    />
                    <View style={{"flex": 1, "gap": 6}}>
                        {<View style={S.stack}>
                            <TextInput
                                accessibilityLabel="Edit task"
                                style={S.input}
                                value={edit_text}
                                autoCapitalize="none"
                                autoCorrect={False}
                                onChangeText={lambda (s: str) { edit_text = s; }}
                                onSubmitEditing={lambda { act("edit", t.id); }}
                            />
                            <View style={S.row}>
                                <Button label="Save" small={True} action={lambda { act("edit", t.id); }} disabled={busy}/>
                                <Button label="Cancel" small={True} quiet={True} action={lambda { editing = ""; }}/>
                            </View>
                        </View>
                            if editing == t.id
                            else <Text style={[S.taskTitle, S.doneTitle if t.done else {}]}>{t.title}</Text>}
                        <View style={S.wrap}>
                            <Pressable
                                accessibilityLabel={"Change priority of " + t.title}
                                onPress={lambda { act("priority", t.id, str(t.priority % 3 + 1)); }}
                            >
                                <Chip
                                    label={["", "high", "med", "low"][t.priority]}
                                    color={prio_color(t.priority)}
                                />
                            </Pressable>
                            <Chip label={dur(t.estimate)}/>
                            {<Chip label={"⏱ " + t.slot} color={C.accent}/> if t.slot else None}
                            {<Chip label={"due " + t.due[5:]} color={C.high if t.due_soon else ""}/>
                                if t.due
                                else None}
                            {<Chip label={"#" + t.tag}/> if t.tag else None}
                            {<Chip label={"↻ " + t.recur}/> if t.recur else None}
                        </View>
                        {<View style={S.wrap}>
                            <Button
                                label="Edit"
                                small={True}
                                quiet={True}
                                action={lambda {
                                    editing = t.id;
                                    edit_text = t.quick;
                                }}
                            />
                            {<Button label="→ Today" small={True} quiet={True} action={lambda { act("today", t.id); }}/>
                                if day < today
                                else <Button
                                    label="→ Next day"
                                    small={True}
                                    quiet={True}
                                    action={lambda { act("tomorrow", t.id); }}
                                />}
                            <Button label="Delete" small={True} quiet={True} action={lambda { act("delete", t.id); }}/>
                        </View>
                            if not t.done and editing != t.id
                            else None}
                    </View>
                </View>
            }}
        </View>;

    week_card =
        <View style={S.card}>
            <View style={S.between}>
                <Text style={S.h2}>This week</Text>
                <Text style={S.small}>
                    🔥 {str(week.streak)}-day streak · {str(week.done_week)} done ({dur(week.done_min_week)})
                </Text>
            </View>
            <View style={{"gap": 6}}>
                {for d in days {
                    <Pressable
                        key={d.day}
                        accessibilityLabel={"Open " + d.label}
                        onPress={lambda { go(d.day); }}
                        style={[
                            S.dayRow,
                            {"borderColor": C.accent} if d.day == day else {},
                            {"backgroundColor": C.accent_soft} if d.day == today else {}
                        ]}
                    >
                        <Text style={[S.small, {"fontWeight": "700", "color": C.ink, "width": 70}]}>{d.label}</Text>
                        <View style={{"flex": 1}}>
                            <LoadBar used={d.task_min} total={d.capacity_min}/>
                        </View>
                        <Text style={[S.tiny, {"width": 124, "textAlign": "right"}]}>
                            {str(d.done)}/{str(d.total)} done · {dur(d.task_min).replace(" ", "")}/{dur(d.capacity_min).replace(" ", "")}
                        </Text>
                    </Pressable>
                }}
            </View>
            <Text style={S.tiny}>Bars compare planned task time with the free time left after fixed blocks.</Text>
        </View>;

    settings =
        <View style={S.card}>
            <Text style={S.h2}>Working hours</Text>
            <View style={S.wrap}>
                <View style={{"gap": 4}}>
                    <Text style={S.small}>Start</Text>
                    <TextInput
                        accessibilityLabel="Day start"
                        style={[S.input, {"width": 80}]}
                        value={pref_start}
                        onChangeText={lambda (s: str) { pref_start = s; }}
                    />
                </View>
                <View style={{"gap": 4}}>
                    <Text style={S.small}>End</Text>
                    <TextInput
                        accessibilityLabel="Day end"
                        style={[S.input, {"width": 80}]}
                        value={pref_end}
                        onChangeText={lambda (s: str) { pref_end = s; }}
                    />
                </View>
                <View style={{"gap": 4}}>
                    <Text style={S.small}>Break (min)</Text>
                    <TextInput
                        accessibilityLabel="Break between tasks"
                        style={[S.input, {"width": 80}]}
                        value={pref_buffer}
                        keyboardType="number-pad"
                        onChangeText={lambda (s: str) { pref_buffer = s; }}
                    />
                </View>
            </View>
            <Button label="Save hours" quiet={True} action={lambda { act("prefs"); }} disabled={busy}/>
            <Text style={S.tiny}>Auto-plan fits tasks inside these hours, around fixed blocks, with a break after each task.</Text>
        </View>;

    tab_bar =
        <View style={S.tabs}>
            {for (key, name) in [("plan", "Plan"), ("tasks", "Tasks"), ("week", "Week")] {
                <Pressable
                    key={key}
                    accessibilityRole="tab"
                    accessibilityState={{"selected": tab == key}}
                    onPress={lambda { tab = key; }}
                    style={[S.tab, S.tabOn if tab == key else {}]}
                >
                    <Text style={[S.tabText, S.tabTextOn if tab == key else {}]}>{name}</Text>
                </Pressable>
            }}
        </View>;

    # ------------------------------------------------------------ screens

    if wide {
        return
            <ScrollView style={S.screen} contentContainerStyle={S.page} keyboardShouldPersistTaps="handled">
                {header}
                {day_nav}
                {messages}
                {quick}
                {overdue}
                <View style={{"flexDirection": "row", "gap": 16, "alignItems": "flex-start"}}>
                    <View style={[S.stack, {"flex": 1.1, "minWidth": 0}]}>
                        {now_card}
                        {summary}
                        {timeline}
                    </View>
                    <View style={[S.stack, {"flex": 1, "minWidth": 0}]}>
                        {tasks}
                        {week_card}
                        {settings}
                    </View>
                </View>
            </ScrollView>;
    }

    return
        <ScrollView style={S.screen} contentContainerStyle={S.page} keyboardShouldPersistTaps="handled">
            {header}
            {day_nav}
            {tab_bar}
            {messages}
            {quick if tab != "week" else None}
            {overdue}
            {<View style={S.stack}>
                {now_card}
                {summary}
                {timeline}
            </View>
                if tab == "plan"
                else None}
            {tasks if tab == "tasks" else None}
            {<View style={S.stack}>
                {week_card}
                {settings}
            </View>
                if tab == "week"
                else None}
            <View style={S.footer}>
                {<Button
                    label="Change server"
                    quiet={True}
                    small={True}
                    action={lambda {
                        sign_out();
                        connected = False;
                    }}
                />
                    if remote
                    else None}
            </View>
        </ScrollView>;
}
