import from pathlib { Path }
import from tempfile { TemporaryDirectory }
import from jaclang.testing.testing { JacTestClient }

glob TODAY: str = "2026-09-30";

def:priv call(client: JacTestClient, name: str, fields: dict[str, any] = {}) -> any {
    response = client.post("/function/" + name, json=fields);
    assert response.ok , f"{name}: {response.text}";
    return response.data["result"];
}

def:priv fails(client: JacTestClient, name: str, fields: dict[str, any] = {}) -> bool {
    return not client.post("/function/" + name, json=fields).ok;
}

test "planner API: quick add, auto plan, recurrence, rollover, isolation" {
    with TemporaryDirectory() as folder {
        client = JacTestClient.from_file(
            str(Path(__file__).with_name("planner.jac")), base_path=folder
        );
        try {
            assert fails(client, "get_day", {"day": TODAY, "now_min": -1});
            for name in ["alice", "bob"] {
                assert client.register_user(name, "dayblock-123").ok;
            }
            assert client.login("alice", "dayblock-123").ok;

            call(client, "set_prefs", {"day_start": "09:00", "day_end": "12:00", "buffer": 0});
            lecture = call(client, "quick_add", {"text": "Lecture 10:00-11:00", "today": TODAY});
            assert lecture["kind"] == "block";
            essay = call(client, "quick_add", {"text": "Essay !high 90m due:today", "today": TODAY});
            assert essay["kind"] == "task" and "Essay" in essay["message"];
            call(client, "quick_add", {"text": "Email 15m !low", "today": TODAY});
            call(client, "quick_add", {"text": "Walk 20m *daily", "today": TODAY});
            assert fails(client, "quick_add", {"text": "Oops @nextyear", "today": TODAY});

            plan = call(client, "auto_plan", {"day": TODAY, "now_min": 540});
            # 9-10 and 11-12 are free: the 90m essay is split 60 + 30,
            # leaving 30m, where the 20m walk fits; the 15m email overflows.
            assert plan["placed"] == 2 and plan["split"] == 1 , plan;
            assert plan["overflow"] == ["Email"] , plan;

            day = call(client, "get_day", {"day": TODAY, "now_min": 545});
            assert day["total_count"] == 3 and day["unscheduled"] == 1;
            assert [b["time"] for b in day["blocks"]] == [
                "09:00–10:00", "10:00–11:00", "11:00–11:30", "11:30–11:50"
            ] , day["blocks"];
            assert day["now_block"]["label"] == "Essay";
            assert day["next_block"]["label"] == "Lecture";

            walk = [t for t in day["tasks"] if t["title"] == "Walk"][0];
            done = call(client, "toggle_task", {"id": walk["id"], "today": TODAY});
            assert done["done"];
            tomorrow = call(client, "get_day", {"day": "2026-10-01", "now_min": -1});
            assert [t["title"] for t in tomorrow["tasks"]] == ["Walk"];
            # re-toggling must not queue a second copy
            call(client, "toggle_task", {"id": walk["id"], "today": TODAY});
            call(client, "toggle_task", {"id": walk["id"], "today": TODAY});
            assert len(call(client, "get_day", {"day": "2026-10-01", "now_min": -1})["tasks"]) == 1;

            email = [t for t in day["tasks"] if t["title"] == "Email"][0];
            edited = call(
                client,
                "edit_task",
                {"id": email["id"], "text": email["quick"].replace("!low", "!high"), "today": TODAY}
            );
            assert edited["priority"] == 1 and edited["title"] == "Email";

            week = call(client, "get_week", {"day": TODAY, "today": TODAY});
            assert week["start"] == "2026-09-28" and week["streak"] == 1;
            assert week["days"][2]["total"] == 3 and week["days"][2]["fixed_min"] == 60;

            # next day: unfinished work rolls forward
            nxt = call(client, "get_day", {"day": "2026-10-01", "now_min": 540});
            assert nxt["overdue"] == 2;
            assert call(client, "rollover", {"today": "2026-10-01"}) == 2;
            moved = call(client, "get_day", {"day": "2026-10-01", "now_min": -1});
            assert sorted([t["title"] for t in moved["tasks"]]) == ["Email", "Essay", "Walk"];
            assert all(not b["task_id"] for b in call(client, "get_day", {"day": TODAY, "now_min": -1})["blocks"] if not b["done"]);

            assert client.login("bob", "dayblock-123").ok;
            assert call(client, "get_day", {"day": TODAY, "now_min": -1})["total_count"] == 0;
            assert fails(client, "delete_task", {"id": email["id"]});
            assert call(client, "load_sample", {"today": TODAY}) > 5;
            assert fails(client, "load_sample", {"today": TODAY});

            assert client.login("alice", "dayblock-123").ok;
            assert call(client, "delete_task", {"id": email["id"]});
        } finally {
            client.close();
        }
    }
}
