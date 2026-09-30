import from "@jac/mobui" { StyleSheet }

obj Colors {
    has ink: str = "#1d2230",
        muted: str = "#6b7385",
        faint: str = "#9aa1b0",
        paper: str = "#f5f4f0",
        card: str = "#ffffff",
        line: str = "#e3e1da",
        accent: str = "#3d5afe",
        accent_soft: str = "#e8ecff",
        fixed: str = "#eceef3",
        fixed_ink: str = "#4a5264",
        high: str = "#e5484d",
        med: str = "#f0a500",
        low: str = "#8b95a7",
        good: str = "#1f9d62",
        good_soft: str = "#e3f5ec",
        warn_soft: str = "#fff4df",
        warn_ink: str = "#8a5a00",
        bad_soft: str = "#fde8e8",
        bad_ink: str = "#a1262b";
}

glob:pub C = Colors();

"""Colour for priority 1 (high), 2 (medium), 3 (low)."""
def:pub prio_color(p: int) -> str {
    return C.high if p == 1 else C.med if p == 2 else C.low;
}

glob:pub S = StyleSheet.create(
    {
        "screen": {"flex": 1, "backgroundColor": C.paper},
        "page": {
            "width": "100%",
            "maxWidth": 1180,
            "alignSelf": "center",
            "padding": 18,
            "paddingBottom": 48,
            "gap": 16
        },
        "header": {
            "flexDirection": "row",
            "justifyContent": "space-between",
            "alignItems": "center",
            "gap": 12,
            "flexWrap": "wrap"
        },
        "brand": {"fontSize": 24, "fontWeight": "800", "color": C.ink, "letterSpacing": -0.8},
        "brandDot": {"color": C.accent},
        "h1": {"fontSize": 26, "fontWeight": "700", "color": C.ink, "letterSpacing": -0.6},
        "h2": {"fontSize": 15, "fontWeight": "700", "color": C.ink},
        "eyebrow": {"fontSize": 11, "fontWeight": "700", "letterSpacing": 1.4, "color": C.muted},
        "body": {"fontSize": 15, "color": C.ink, "lineHeight": 21},
        "small": {"fontSize": 12, "color": C.muted, "lineHeight": 17},
        "tiny": {"fontSize": 11, "color": C.faint},
        "row": {"flexDirection": "row", "alignItems": "center", "gap": 8},
        "wrap": {"flexDirection": "row", "alignItems": "center", "gap": 8, "flexWrap": "wrap"},
        "between": {
            "flexDirection": "row",
            "justifyContent": "space-between",
            "alignItems": "center",
            "gap": 10
        },
        "stack": {"gap": 12},
        "card": {
            "backgroundColor": C.card,
            "borderWidth": 1,
            "borderColor": C.line,
            "borderRadius": 16,
            "padding": 16,
            "gap": 12
        },
        "input": {
            "borderWidth": 1,
            "borderColor": C.line,
            "borderRadius": 10,
            "paddingHorizontal": 12,
            "paddingVertical": 10,
            "fontSize": 15,
            "color": C.ink,
            "backgroundColor": "#fff"
        },
        "quickInput": {"flex": 1, "fontSize": 16, "minWidth": 0},
        "button": {
            "backgroundColor": C.accent,
            "paddingHorizontal": 16,
            "paddingVertical": 10,
            "borderRadius": 10,
            "alignItems": "center",
            "justifyContent": "center"
        },
        "buttonText": {"color": "#fff", "fontWeight": "700", "fontSize": 14},
        "quiet": {"backgroundColor": "#eef0f6"},
        "quietText": {"color": C.accent},
        "small_btn": {"paddingHorizontal": 10, "paddingVertical": 6, "borderRadius": 8},
        "small_btn_text": {"fontSize": 12},
        "chip": {
            "paddingHorizontal": 8,
            "paddingVertical": 3,
            "borderRadius": 999,
            "backgroundColor": "#f0f1f5"
        },
        "chipText": {"fontSize": 11, "color": C.muted, "fontWeight": "600"},
        "check": {
            "width": 22,
            "height": 22,
            "borderRadius": 11,
            "borderWidth": 2,
            "alignItems": "center",
            "justifyContent": "center"
        },
        "checkMark": {"color": "#fff", "fontSize": 13, "fontWeight": "800"},
        "taskRow": {
            "flexDirection": "row",
            "alignItems": "flex-start",
            "gap": 10,
            "paddingVertical": 10,
            "borderBottomWidth": 1,
            "borderBottomColor": "#f0efea"
        },
        "taskTitle": {"fontSize": 15, "color": C.ink, "fontWeight": "600"},
        "doneTitle": {"color": C.faint, "textDecorationLine": "line-through"},
        "timeCol": {"width": 50},
        "timeText": {"fontSize": 12, "color": C.muted, "fontWeight": "600"},
        "block": {
            "flex": 1,
            "borderRadius": 10,
            "paddingHorizontal": 12,
            "paddingVertical": 8,
            "borderLeftWidth": 4,
            "gap": 2
        },
        "gap": {
            "flex": 1,
            "borderRadius": 10,
            "paddingHorizontal": 12,
            "paddingVertical": 6,
            "borderWidth": 1,
            "borderStyle": "dashed",
            "borderColor": C.line
        },
        "barTrack": {
            "height": 8,
            "borderRadius": 4,
            "backgroundColor": "#eceae4",
            "overflow": "hidden",
            "flexDirection": "row"
        },
        "tabs": {
            "flexDirection": "row",
            "backgroundColor": "#e9e8e2",
            "borderRadius": 12,
            "padding": 4,
            "gap": 4
        },
        "tab": {"flex": 1, "paddingVertical": 8, "borderRadius": 9, "alignItems": "center"},
        "tabOn": {"backgroundColor": "#fff"},
        "tabText": {"fontSize": 13, "fontWeight": "700", "color": C.muted},
        "tabTextOn": {"color": C.ink},
        "banner": {"padding": 12, "borderRadius": 10, "gap": 8},
        "stat": {"fontSize": 22, "fontWeight": "800", "color": C.ink, "letterSpacing": -0.5},
        "dayRow": {
            "flexDirection": "row",
            "alignItems": "center",
            "gap": 10,
            "paddingHorizontal": 10,
            "paddingVertical": 8,
            "borderRadius": 10,
            "borderWidth": 1,
            "borderColor": "transparent"
        },
        "footer": {"paddingTop": 12, "alignItems": "center"}
    }
);
