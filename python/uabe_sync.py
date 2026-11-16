import os
from typing import Any, Dict, List, Tuple

import uabe_backend as b

SYNC_TYPES = ("Mesh", "Texture2D", "TextAsset")
_source: Dict[str, Any] = {"path": None, "stamp": None, "env": None}


def _load_source(path: str) -> Any:
    if not os.path.exists(path):
        raise FileNotFoundError(f"Source file not found: {path}")
    stamp = (os.path.getsize(path), int(os.path.getmtime(path)))
    if _source["path"] == path and _source["stamp"] == stamp and _source["env"] is not None:
        return _source["env"]
    _source.update(path=None, stamp=None, env=None)
    env = b._unitypy().load(path)
    _source.update(path=path, stamp=stamp, env=env)
    return env


def _unity_version(env: Any) -> Any:
    for obj in env.objects:
        owner = getattr(obj, "assets_file", None)
        value = getattr(owner, "unity_version", None) or getattr(owner, "m_UnityVersion", None)
        if isinstance(value, (tuple, list)):
            value = ".".join(str(v) for v in value)
        return str(value) if value else None
    return None


def _collect(env: Any, types: Tuple[str, ...]) -> List[dict]:
    rows = []
    for index, obj in enumerate(list(env.objects)):
        kind = b._tname(obj)
        if kind in types:
            rows.append({
                "index": index,
                "obj": obj,
                "type": kind,
                "name": b._extract_name(obj),
                "pid": b._safe_int(getattr(obj, "path_id", 0)),
                "size": b._try_size(obj),
            })
    return rows


def _pair(source: List[dict], target: List[dict], mode: str) -> Tuple[List[Tuple[dict, dict]], List[str]]:
    def key(row: dict) -> tuple:
        return (row["type"], row["pid"]) if mode == "pathid" else (row["type"], row["name"])

    def group(rows: List[dict]) -> Dict[tuple, List[dict]]:
        out: Dict[tuple, List[dict]] = {}
        for row in rows:
            if mode != "pathid" and not row["name"]:
                continue
            out.setdefault(key(row), []).append(row)
        return out

    wanted, available = group(source), group(target)
    pairs: List[Tuple[dict, dict]] = []
    missing: List[str] = []
    for k, sources in wanted.items():
        free = list(available.get(k, []))
        if not free:
            missing.extend(f"{r['type']}: {r['name'] or r['pid']}" for r in sources)
            continue
        leftover = []
        for row in sources:
            hit = next((t for t in free if t["pid"] == row["pid"]), None)
            if hit is None:
                leftover.append(row)
            else:
                free.remove(hit)
                pairs.append((row, hit))
        for row, hit in zip(leftover, free):
            pairs.append((row, hit))
        missing.extend(f"{r['type']}: {r['name'] or r['pid']}" for r in leftover[len(free):])
    return pairs, missing


def _mesh_note(src: dict, dst: dict) -> str:
    a, c = b._mesh_stats(src["obj"]), b._mesh_stats(dst["obj"])
    if not a or not c:
        return ""
    notes = []
    try:
        stream = (src["obj"].parse_as_dict().get("m_StreamData") or {})
        if b._safe_int(stream.get("size")) > 0:
            return "Mesh data is stored in an external stream and cannot be copied"
    except Exception:
        pass
    if a["bones"] != c["bones"]:
        notes.append(f"bones {c['bones']} -> {a['bones']}")
    if a["skinned"] != c["skinned"]:
        notes.append("skin weights differ")
    if a["compressed"] != c["compressed"]:
        notes.append("compression differs")
    if a["vertices"] != c["vertices"]:
        notes.append(f"vertices {c['vertices']} -> {a['vertices']}")
    return ", ".join(notes)


def _plan(payload: dict) -> Tuple[Any, Any, List[Tuple[dict, dict]], List[str], List[dict]]:
    session = b._require(payload["sessionId"])
    source_env = _load_source(payload["sourcePath"])
    types = tuple(t for t in payload.get("types", SYNC_TYPES) if t in SYNC_TYPES)
    mode = payload.get("match", "name")
    source_rows = _collect(source_env, types)
    target_rows = _collect(session.env, types)
    pairs, missing = _pair(source_rows, target_rows, mode)
    paired_targets = {id(d["obj"]) for _, d in pairs}
    spare = [r for r in target_rows if id(r["obj"]) not in paired_targets]
    return session, source_env, pairs, missing, spare


def sync_scan(payload: dict) -> dict:
    session, source_env, pairs, missing, spare = _plan(payload)
    matches = []
    for src, dst in sorted(pairs, key=lambda p: (p[0]["type"], p[0]["name"].lower())):
        note = _mesh_note(src, dst) if src["type"] == "Mesh" else ""
        matches.append({
            "type": src["type"],
            "name": src["name"] or str(src["pid"]),
            "srcIndex": src["index"],
            "dstIndex": dst["index"],
            "srcBytes": src["size"],
            "dstBytes": dst["size"],
            "note": note or None,
        })
    return {
        "matches": matches,
        "unmatchedSource": missing[:200],
        "unmatchedTarget": len(spare),
        "sourceUnity": _unity_version(source_env),
        "targetUnity": _unity_version(session.env),
    }


def _transfer(session: Any, src: dict, dst: dict, keep: bool = True) -> Tuple[str, str]:
    b._snapshot_object(session, dst["index"], dst["obj"])
    if src["type"] == "Texture2D":
        image = src["obj"].parse_as_object().image
        if image is None:
            return "skipped", "The source texture has no image data"
        target = dst["obj"].parse_as_object()
        image, resized = b._fit_to_texture(target, image, keep)
        astc_fallback = b._set_texture_image(target, image)
        target.save()
        notes = []
        if resized:
            notes.append(f"resized {resized['resizedFrom']} -> {resized['resizedTo']}")
        if astc_fallback:
            notes.append("ASTC failed; saved as RGBA32")
        return "replaced", "; ".join(notes)
    if src["type"] == "TextAsset":
        source_text = src["obj"].parse_as_object().m_Script
        target = dst["obj"].parse_as_object()
        target.m_Script = source_text
        target.save()
        return "replaced", ""
    if src["type"] == "Mesh":
        stream = (src["obj"].parse_as_dict().get("m_StreamData") or {})
        if b._safe_int(stream.get("size")) > 0:
            return "skipped", "Mesh data is stored in an external stream"
    raw = bytes(src["obj"].get_raw_data())
    index = dst["index"]
    if index not in session.raw_backup:
        session.raw_backup[index] = bytes(dst["obj"].get_raw_data())
        session.raw_before[index] = b._mesh_stats(dst["obj"])
    dst["obj"].set_raw_data(raw)
    return "replaced", ""


def sync_apply(payload: dict) -> dict:
    session, _, pairs, _, _ = _plan(payload)
    exclude = {int(i) for i in payload.get("exclude", [])}
    keep = bool(payload.get("keepSize", True))
    source_version = _unity_version(_load_source(payload["sourcePath"]))
    target_version = _unity_version(session.env)
    versions_differ = bool(source_version and target_version and source_version != target_version)
    items: List[dict] = []
    modified: List[int] = []
    counts = {"replaced": 0, "skipped": 0, "failed": 0}
    for src, dst in pairs:
        if dst["index"] in exclude:
            continue
        try:
            if src["type"] == "Mesh" and versions_differ:
                status, reason = "skipped", (
                    f"Mesh raw data was not copied because Unity versions differ "
                    f"({source_version} -> {target_version}); raw layouts may be incompatible"
                )
            else:
                status, reason = _transfer(session, src, dst, keep)
        except Exception as exc:
            status, reason = "failed", str(exc) or exc.__class__.__name__
        counts[status] += 1
        if status == "replaced":
            modified.append(dst["index"])
        items.append({
            "type": src["type"],
            "name": src["name"] or str(src["pid"]),
            "dstIndex": dst["index"],
            "status": status,
            "reason": reason or None,
        })
    if modified:
        session.dirty = True
        session.audio_cache.clear()
    return {**counts, "items": items[:500], "modifiedIndices": modified}


def sync_close(payload: dict) -> dict:
    _source.update(path=None, stamp=None, env=None)
    return {}


def install(methods: Dict[str, Any]) -> None:
    methods["sync_scan"] = sync_scan
    methods["sync_apply"] = sync_apply
    methods["sync_close"] = sync_close
