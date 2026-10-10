"""Independent check of the Anthropic request bodies that the ai_agent suite prints (`BODY>>>label|n|json<<<BODY`).

The Luau suite already decodes them with its own strict decoder; this re-reads them with Python's json module and checks
the shape of the Messages API request: valid JSON, required fields, the conversation alternates user / assistant, every
tool_use is answered in order by the next user message, tool schemas stay inside what strict tool use accepts, and each
request of an agent turn extends the previous one byte for byte (so the prompt cache is reused).
"""
import json
import re


def _walk_schema(name, schema, strict, bad, path="input_schema"):
    if schema.get("type") == "object":
        if strict and schema.get("additionalProperties") is not False:
            bad("%s %s: object without additionalProperties false" % (name, path))
        if "properties" in schema and not isinstance(schema["properties"], dict):
            bad("%s %s: properties is not an object" % (name, path))
        for key, value in (schema.get("properties") or {}).items():
            _walk_schema(name, value, strict, bad, path + "." + key)
    for key in ("minimum", "maximum", "minLength", "maxLength", "multipleOf"):
        if key in schema:
            bad("%s %s: unsupported %s" % (name, path, key))
    if "items" in schema:
        _walk_schema(name, schema["items"], strict, bad, path + "[]")


def validate(text):
    """Returns (problems, number of bodies checked)."""
    problems = []

    def bad(message):
        problems.append(message)

    by_label = {}
    for label, index, body in re.findall(r"BODY>>>(.*?)\|(\d+)\|(.*?)<<<BODY", text, flags=re.S):
        by_label.setdefault(label, []).append((int(index), body))
    total = 0
    for label, items in by_label.items():
        items.sort()
        previous = None
        for index, body in items:
            total += 1
            try:
                data = json.loads(body)
            except ValueError as e:
                bad("%s body %d invalid JSON: %s" % (label, index, e))
                continue
            for key in ("model", "max_tokens", "messages", "system", "tools"):
                if key not in data:
                    bad("%s body %d lacks %s" % (label, index, key))
            if data.get("tool_choice") not in (None, {"type": "auto"}):
                bad("%s body %d: tool_choice must be auto" % (label, index))
            messages = data.get("messages", [])
            if messages and (messages[0]["role"] != "user" or messages[-1]["role"] != "user"):
                bad("%s body %d: must start and end with a user message" % (label, index))
            for a, b in zip(messages, messages[1:]):
                if a["role"] == b["role"]:
                    bad("%s body %d: two %s messages in a row" % (label, index, a["role"]))
            for j, message in enumerate(messages):
                if message["role"] == "assistant" and isinstance(message["content"], list):
                    ids = [c["id"] for c in message["content"] if c.get("type") == "tool_use"]
                    for c in message["content"]:
                        if c.get("type") == "tool_use" and not isinstance(c.get("input"), dict):
                            bad("%s body %d: tool_use input is not an object" % (label, index))
                    if ids:
                        following = messages[j + 1]["content"]
                        got = [c["tool_use_id"] for c in following if c.get("type") == "tool_result"]
                        if got != ids:
                            bad("%s body %d: results %s != calls %s" % (label, index, got, ids))
                        for c in following:
                            if not isinstance(c.get("content"), str) or not c["content"]:
                                bad("%s body %d: empty or non-string tool_result content" % (label, index))
            for tool in data.get("tools", []):
                _walk_schema(tool["name"], tool["input_schema"], tool.get("strict") is True, bad)
                if not tool.get("description"):
                    bad("%s body %d: tool %s without description" % (label, index, tool["name"]))
            if previous is not None:
                prefix = previous[:-2]  # without the closing "]}"
                if not body.startswith(prefix + ","):
                    bad("%s body %d does not extend body %d byte for byte" % (label, index, index - 1))
                before = json.loads(previous)
                for key in ("system", "tools", "model", "max_tokens", "output_config"):
                    if before.get(key) != data.get(key):
                        bad("%s body %d: %s changed" % (label, index, key))
                if data["messages"][:len(before["messages"])] != before["messages"]:
                    bad("%s body %d: earlier messages changed" % (label, index))
            previous = body
    return problems, total
