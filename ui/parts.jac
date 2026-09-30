"""Small shared UI pieces and client-side clock helpers (dates come from the device)."""
import from "@jac/mobui" { View, Text, Pressable }
import from ui.theme { S, C, prio_color }

def:pub pad2(n: int) -> str {
    return ("0" + str(n)) if n < 10 else str(n);
}

"""The device's local date as YYYY-MM-DD, shifted by `offset` days."""
def:pub local_day(offset: int = 0) -> str {
    now = new(Date);
    d = new(Date, now.getFullYear(), now.getMonth(), now.getDate() + offset);
    return str(d.getFullYear()) + "-" + pad2(int(d.getMonth()) + 1) + "-" + pad2(int(d.getDate()));
}

"""`day` (YYYY-MM-DD) shifted by `offset` days."""
def:pub shift_day(day: str, offset: int) -> str {
    parts = day.split("-");
    d = new(Date, int(parts[0]), int(parts[1]) - 1, int(parts[2]) + offset);
    return str(d.getFullYear()) + "-" + pad2(int(d.getMonth()) + 1) + "-" + pad2(int(d.getDate()));
}

def:pub now_minutes -> int {
    now = new(Date);
    return int(now.getHours()) * 60 + int(now.getMinutes());
}

def:pub clock(total: int) -> str {
    return pad2(int(Math.floor(total / 60))) + ":" + pad2(total % 60);
}

def:pub dur(total: int) -> str {
    if total < 60 {
        return str(total) + "m";
    }
    hours = int(Math.floor(total / 60));
    rest = total % 60;
    return str(hours) + "h" + ((" " + str(rest) + "m") if rest > 0 else "");
}

"""Readable text for a failed server call: the server's own message when there is one.

Bridge errors carry the server's JSON envelope; pull `error.message` out of it."""
def:pub problem(e: any, fallback: str) -> str {
    text = "";
    if e {
        text = str(e.detail or e.message or "");
    }
    brace = text.find("{");
    if brace >= 0 {
        try {
            envelope: any = JSON.parse(text[brace:]);
            if envelope and envelope.error and envelope.error.message {
                text = str(envelope.error.message);
            }
        } except Exception {}
    }
    if not text or "Failed to fetch" in text or "NetworkError" in text or "Network request failed" in text {
        return fallback;
    }
    return text;
}

def:pub Button(
    label: str,
    action: Callable,
    quiet: bool = False,
    disabled: bool = False,
    small: bool = False
) -> JsxElement {
    return
        <Pressable
            accessibilityRole="button"
            accessibilityLabel={label}
            disabled={disabled}
            onPress={action}
            style={[
                S.button,
                S.quiet if quiet else {},
                S.small_btn if small else {},
                {"opacity": 0.45 if disabled else 1}
            ]}
        >
            <Text
                style={[
                    S.buttonText,
                    S.quietText if quiet else {},
                    S.small_btn_text if small else {}
                ]}
            >
                {label}
            </Text>
        </Pressable>;
}

def:pub Chip(label: str, color: str = "") -> JsxElement {
    return
        <View style={[S.chip, {"backgroundColor": color + "22"} if color else {}]}>
            <Text style={[S.chipText, {"color": color} if color else {}]}>{label}</Text>
        </View>;
}

def:pub Check(done: bool, priority: int, action: Callable, label: str) -> JsxElement {
    tint = prio_color(priority);
    return
        <Pressable
            accessibilityRole="checkbox"
            accessibilityLabel={label}
            accessibilityState={{"checked": done}}
            onPress={action}
            hitSlop={8}
            style={[
                S.check,
                {"borderColor": C.good if done else tint, "backgroundColor": C.good if done else "#fff"}
            ]}
        >
            <Text style={S.checkMark}>{"✓" if done else ""}</Text>
        </Pressable>;
}

"""A horizontal bar: `used` of `total`, turning red when over."""
def:pub LoadBar(used: int, total: int) -> JsxElement {
    cap = max(total, 1);
    pct = min(100, int(Math.round(used * 100 / cap)));
    over = used > total;
    return
        <View style={S.barTrack}>
            <View
                style={{
                    "width": str(pct) + "%",
                    "backgroundColor": C.high if over else C.accent
                }}
            />
        </View>;
}
