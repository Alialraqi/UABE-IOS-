from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import traceback
import uuid
from typing import Any, Callable, Dict, List, Optional, Set


sys.setrecursionlimit(6000)

_sessions: Dict[str, "Session"] = {}


class Session:
    def __init__(self, env: Any, path: str, backup_path: Optional[str] = None,
                 history_path: Optional[str] = None):
        self.env = env
        self.path = path
        self.backup_path = backup_path
        self.history_path = history_path
        self.dirty = False
        self.audio_cache: Dict[int, Any] = {}
        self.audio_override: Dict[int, bytes] = {}
        self.pending_audio: Dict[int, str] = {}
        self.raw_backup: Dict[int, bytes] = {}
        self.raw_before: Dict[int, Any] = {}
        self.object_backups: Dict[int, bytes] = {}
        self.restored_pending: Set[int] = set()


def _install_astc_decode_patch() -> None:
    """Decode ASTC with the bundled lightweight decoder, not astcenc contexts."""
    import importlib
    import math
    import re

    converter = importlib.import_module("UnityPy.export.Texture2DConverter")
    if getattr(converter, "_uabe_astc_decode_patch", False):
        return

    from PIL import Image
    import texture2ddecoder

    for texture_format, (_decoder, args) in list(converter.CONV_TABLE.items()):
        name = getattr(texture_format, "name", "")
        if not name.startswith("ASTC_") or name.startswith("ASTC_HDR_"):
            continue
        match = re.search(r"_(\d+)x(\d+)$", name)
        if not match:
            continue
        block = (int(match.group(1)), int(match.group(2)))

        def decode_astc(data, width, height, block_size=block):
            width, height = int(width), int(height)
            bx, by = block_size
            if width <= 0 or height <= 0:
                return Image.new("RGBA", (0, 0))
            expected = ((width + bx - 1) // bx) * ((height + by - 1) // by) * 16
            if len(data) < expected:
                raise ValueError(f"Invalid ASTC data size: {len(data)} < {expected}")
            rgba_as_bgra = texture2ddecoder.decode_astc(bytes(data[:expected]), width, height, bx, by)
            return Image.frombytes("RGBA", (width, height), rgba_as_bgra, "raw", "BGRA")

        converter.CONV_TABLE[texture_format] = (decode_astc, (block,))

    converter._uabe_astc_decode_patch = True


def _unitypy():
    import UnityPy

    # CI smoke tests and embedders may provide a lightweight UnityPy stub.
    # Only the real UnityPy package has export.Texture2DConverter to patch.
    if getattr(UnityPy, "__path__", None):
        _install_astc_decode_patch()
    return UnityPy


def _pil_image():
    from PIL import Image

    return Image


def _tname(obj: Any) -> str:
    try:
        return str(obj.type.name)
    except Exception:
        try:
            s = str(obj.type)
            if s.startswith("ClassIDType."):
                s = s[len("ClassIDType."):]
            return s or "Unknown"
        except Exception:
            return "Unknown"


def _safe_int(v: Any, default: int = 0) -> int:
    try:
        return int(v)
    except Exception:
        return default


def _try_size(obj: Any) -> Optional[int]:
    for a in ("byte_size", "size", "data_size", "m_Size"):
        try:
            v = getattr(obj, a)
            if v is not None and int(v) >= 0:
                return int(v)
        except Exception:
            pass
    return None


def _try_container(obj: Any) -> Optional[str]:
    try:
        c = obj.container
        if c:
            return str(c)
    except Exception:
        pass
    return None


def _extract_name(obj: Any) -> str:
    try:
        peek = getattr(obj, "peek_name", None)
        if peek is not None:
            n = peek()
            return str(n) if n else ""
        parsed = obj.parse_as_object()
        n = getattr(parsed, "m_Name", None)
        return str(n) if n else ""
    except Exception:
        return ""


def _normalize_export_name(s: Optional[str]) -> str:
    return (s or "").strip().replace(" ", "_").replace("-", "_")


def _sanitize_filename(name: Optional[str], fallback: str) -> str:
    n = fallback if not name or not name.strip() else name.strip()
    for ch in '<>:"/\\|?*\n\r\t':
        n = n.replace(ch, "_")
    n = n.rstrip(". ").strip()
    return n or fallback


def _archive_tag(obj: Any) -> str:
    try:
        af = obj.assets_file
        if af is None:
            return ""
        name = getattr(af, "name", None) or ""
        if not name:
            f = getattr(af, "file", None)
            name = getattr(f, "name", "") if f is not None else ""
        if name:
            base = os.path.basename(str(name))
            dot = base.rfind(".")
            if dot >= 0:
                base = base[:dot]
            return _normalize_export_name(base)
    except Exception:
        pass
    return ""


def _export_base_name(obj: Any, idx: int) -> str:
    obj_name = _normalize_export_name(_extract_name(obj))
    arch = _archive_tag(obj)
    pid = _safe_int(getattr(obj, "path_id", idx), idx)
    if obj_name and arch:
        base = f"{obj_name}_{arch}"
    elif obj_name:
        base = f"{obj_name}_{pid}"
    else:
        base = f"{_normalize_export_name(_tname(obj))}_{pid}"
    return _sanitize_filename(base, str(pid))


def _keep_archive_key(k: str) -> bool:
    if not k:
        return False
    if k.startswith("/") or k.startswith("\\") or ":/" in k or ":\\" in k:
        return False
    if k.startswith("CAB-"):
        return True
    if k.endswith((".resS", ".resource", ".resources")):
        return True
    return k.startswith("archive:/")


def _archive_names(env: Any) -> List[str]:
    names: List[str] = []

    def add_from(mapping: Any) -> None:
        try:
            for k in list(mapping.keys()):
                ks = str(k)
                if _keep_archive_key(ks) and ks not in names:
                    names.append(ks)
        except Exception:
            pass

    add_from(getattr(env, "files", None) or {})
    bf = getattr(env, "file", None)
    if bf is not None:
        add_from(getattr(bf, "files", None) or {})
    return names


def _mime_for(t: str) -> str:
    return {"TextAsset": "text/plain", "Texture2D": "image/png", "AudioClip": "audio/*"}.get(t, "application/json")


def _extension_for(obj: Any, t: str) -> str:
    if t == "TextAsset":
        name = _try_container(obj) or f"textasset_{_safe_int(getattr(obj, 'path_id', 0))}"
        if not name.endswith((".txt", ".bytes", ".json", ".lua")):
            return "txt"
        dot = name.rfind(".")
        return name[dot + 1:] if dot >= 0 else ""
    return {"Texture2D": "png", "Mesh": "obj"}.get(t, "json")


def _json_default(o: Any):
    if isinstance(o, (bytes, bytearray, memoryview)):
        return list(bytes(o))
    return str(o)


def _get_object(env: Any, idx: int) -> Any:
    objects = list(env.objects)
    if idx < 0 or idx >= len(objects):
        raise IndexError(f"Index out of range: {idx} / {len(objects)}")
    return objects[idx]


def _require(session_id: str) -> Session:
    s = _sessions.get(session_id)
    if s is None:
        raise KeyError(f"Session not found: {session_id}")
    return s


def _history_file(s: Session, idx: int) -> Optional[str]:
    if not s.history_path:
        return None
    return os.path.join(s.history_path, f"{idx}.bin")


def _history_indices(s: Session) -> List[int]:
    indices = set(s.object_backups)
    if s.history_path and os.path.isdir(s.history_path):
        for filename in os.listdir(s.history_path):
            if not filename.endswith(".bin"):
                continue
            try:
                indices.add(int(filename[:-4]))
            except ValueError:
                continue
    return sorted(indices)


def _read_object_backup(s: Session, idx: int) -> Optional[bytes]:
    raw = s.object_backups.get(idx)
    path = _history_file(s, idx)
    if raw is None and path and os.path.isfile(path):
        with open(path, "rb") as fh:
            raw = fh.read()
        s.object_backups[idx] = raw
    return raw


def _remove_object_backup(s: Session, idx: int) -> None:
    s.object_backups.pop(idx, None)
    path = _history_file(s, idx)
    if path:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass


def _clear_object_backups(s: Session) -> None:
    for idx in _history_indices(s):
        _remove_object_backup(s, idx)


def _snapshot_object(s: Session, idx: int, obj: Any) -> None:
    s.restored_pending.discard(idx)
    if _read_object_backup(s, idx) is not None:
        return
    try:
        s.object_backups[idx] = bytes(obj.get_raw_data())
    except Exception:
        pass


def _persist_object_backup(s: Session, idx: int) -> None:
    path = _history_file(s, idx)
    raw = s.object_backups.get(idx)
    if not path or raw is None or os.path.exists(path):
        return
    os.makedirs(s.history_path, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(raw)
    os.replace(tmp, path)


def restore_object(p: dict) -> dict:
    s = _require(p["sessionId"])
    idx = int(p["idx"])
    raw = _read_object_backup(s, idx)
    if raw is None:
        raise ValueError("No saved original is available for this object.")
    _get_object(s.env, idx).set_raw_data(raw)
    s.restored_pending.add(idx)
    s.raw_backup.pop(idx, None)
    s.raw_before.pop(idx, None)
    s.audio_cache.pop(idx, None)
    s.audio_override.pop(idx, None)
    s.pending_audio.pop(idx, None)
    s.dirty = True
    return {"idx": idx}


def restore_all(p: dict) -> dict:
    s = _require(p["sessionId"])
    restored = _history_indices(s)
    if s.backup_path and os.path.isfile(s.backup_path):
        shutil.copy2(s.backup_path, s.path)
        s.env = _unitypy().load(s.path)
    else:
        for idx in restored:
            raw = _read_object_backup(s, idx)
            if raw is not None:
                _get_object(s.env, idx).set_raw_data(raw)
    _clear_object_backups(s)
    s.restored_pending.clear()
    s.raw_backup.clear()
    s.raw_before.clear()
    s.audio_cache.clear()
    s.audio_override.clear()
    s.pending_audio.clear()
    s.dirty = bool(restored)
    return {"restored": restored}


def _write_bytes(path: str, data: bytes) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def _file_dicts(obj: Any, env: Any) -> List[dict]:
    found: List[dict] = []
    parent = getattr(getattr(obj, "assets_file", None), "parent", None)
    for holder in (parent, getattr(env, "file", None), env):
        files = getattr(holder, "files", None)
        if isinstance(files, dict) and not any(files is d for d in found):
            found.append(files)
    cabs = getattr(env, "cabs", None)
    if isinstance(cabs, dict) and not any(cabs is d for d in found):
        found.append(cabs)
    return found


def _base(name: Any) -> str:
    return os.path.basename(str(name).replace("\\", "/")).lower()


def _find_stream(obj: Any, env: Any, src: str):
    target = _base(src)
    for files in _file_dicts(obj, env):
        for key in list(files.keys()):
            if _base(key) == target:
                return files, key
    return None, None


def _entry_view(entry: Any) -> memoryview:
    for attr in ("bytes", "data"):
        value = getattr(entry, attr, None)
        if value is not None:
            try:
                return memoryview(value)
            except TypeError:
                pass
    try:
        entry.Position = 0
        length = getattr(entry, "Length", None)
        if length is None:
            length = len(entry)
        return memoryview(bytes(entry.read_bytes(int(length))))
    except Exception as exc:
        raise RuntimeError(f"Cannot read stream data ({type(entry).__name__}): {exc}") from exc


def _stream_ref(tree: dict):
    res = tree.get("m_Resource")
    if isinstance(res, dict):
        return res.get("m_Source") or "", _safe_int(res.get("m_Offset")), _safe_int(res.get("m_Size")), True
    return tree.get("m_Source") or "", _safe_int(tree.get("m_Offset")), _safe_int(tree.get("m_Size")), False


def _inherit_attrs(old: Any, new: Any) -> None:
    try:
        for name, value in vars(old).items():
            if name not in vars(new):
                setattr(new, name, value)
    except TypeError:
        pass
    for name in ("flags", "name", "path"):
        if hasattr(old, name) and not hasattr(new, name):
            setattr(new, name, getattr(old, name))
    if not hasattr(new, "flags"):
        new.flags = 0


def _audio_raw(obj: Any, env: Any, override: Optional[bytes] = None):
    tree = obj.parse_as_dict()
    if override:
        return bytes(override), tree
    inline = tree.get("m_AudioData")
    if inline:
        return bytes(inline), tree
    src, off, size, _ = _stream_ref(tree)
    if not src:
        return b"", tree
    files, key = _find_stream(obj, env, src)
    if files is not None:
        view = _entry_view(files[key])
        end = off + size if size else len(view)
        return bytes(view[off:end]), tree
    try:
        from UnityPy.helpers.ResourceReader import get_resource_data

        return bytes(get_resource_data(src, obj.assets_file, off, size)), tree
    except Exception as exc:
        raise RuntimeError(
            f"The audio stream '{src}' is not inside this file, so it cannot be read: {exc}"
        ) from exc


def _audio_decode(session: "Session", idx: int):
    cached = session.audio_cache.get(idx)
    if cached is not None:
        return cached
    import uabe_audio

    obj = _get_object(session.env, idx)
    raw, tree = _audio_raw(obj, session.env, session.audio_override.get(idx))
    result = uabe_audio.decode_audio(
        raw,
        name=str(tree.get("m_Name", "audio")),
        subsound=_safe_int(tree.get("m_SubsoundIndex", 0)),
        hint_channels=_safe_int(tree.get("m_Channels", 0)),
        hint_rate=_safe_int(tree.get("m_Frequency", 0)),
    )
    session.audio_cache[idx] = result
    return result


def _export_text_asset(obj: Any) -> bytes:
    parsed = obj.parse_as_object()
    script = getattr(parsed, "m_Script", None)
    if isinstance(script, str) and script:
        return script.encode("utf-8", "surrogateescape")
    if isinstance(script, (bytes, bytearray)) and script:
        return bytes(script)
    raw = getattr(parsed, "m_Bytes", None)
    return bytes(raw) if raw else b""


def _export_texture(obj: Any) -> bytes:
    tex = obj.parse_as_object()
    image = tex.image
    if image is None:
        return b""
    bio = io.BytesIO()
    image.save(bio, format="PNG")
    return bio.getvalue()


def _export_mesh(obj: Any) -> bytes:
    mesh = obj.parse_as_object()
    try:
        text = mesh.export()
    except AttributeError:
        from UnityPy.export import MeshExporter

        text = MeshExporter.export_mesh(mesh, "obj")
    if isinstance(text, bytes):
        return text
    return (text or "").encode("utf-8")


def _export_typetree_json(obj: Any) -> bytes:
    try:
        d = obj.parse_as_dict()
        return json.dumps(d, ensure_ascii=False, indent=2, default=_json_default).encode("utf-8")
    except Exception:
        pass
    raw = obj.get_raw_data()
    return bytes(raw) if raw else b""


def get_object_bytes(obj: Any) -> bytes:
    t = _tname(obj)
    if t == "TextAsset":
        return _export_text_asset(obj)
    if t == "Texture2D":
        return _export_texture(obj)
    if t == "Mesh":
        return _export_mesh(obj)
    return _export_typetree_json(obj)


def _restore_bytes(new: Any, ref: Any) -> Any:
    if isinstance(ref, (bytes, bytearray)) and isinstance(new, list):
        return bytes(new)
    if isinstance(ref, dict) and isinstance(new, dict):
        return {k: _restore_bytes(v, ref.get(k)) for k, v in new.items()}
    if isinstance(ref, list) and isinstance(new, list) and ref:
        return [_restore_bytes(v, ref[min(i, len(ref) - 1)]) for i, v in enumerate(new)]
    return new


def _import_typetree(obj: Any, data: bytes) -> None:
    text = data.decode("utf-8", errors="replace").strip()
    if not text:
        raise ValueError("Input JSON is empty.")
    tree = json.loads(text)
    if not isinstance(tree, dict):
        raise ValueError("Typetree JSON must be a JSON object (dict).")
    try:
        tree = _restore_bytes(tree, obj.parse_as_dict())
    except Exception:
        pass
    obj.save_typetree(tree)


def _fit_to_texture(tex: Any, img: Any, keep: bool = True):
    if not keep:
        return img, None
    try:
        width = int(getattr(tex, "m_Width", 0) or 0)
        height = int(getattr(tex, "m_Height", 0) or 0)
    except (TypeError, ValueError):
        return img, None
    if width <= 0 or height <= 0 or tuple(img.size) == (width, height):
        return img, None
    module = _pil_image()
    resample = getattr(getattr(module, "Resampling", module), "LANCZOS")
    resized = img.convert("RGBA").resize((width, height), resample)
    return resized, {"resizedFrom": f"{img.size[0]}x{img.size[1]}", "resizedTo": f"{width}x{height}"}


def _set_texture_image(tex: Any, img: Any) -> bool:
    """Encode using the existing format, falling back from broken ASTC encoders."""
    try:
        tex.image = img
        return False
    except Exception as exc:
        try:
            texture_format = int(tex.m_TextureFormat)
        except (AttributeError, TypeError, ValueError):
            raise
        is_astc = 48 <= texture_format <= 59 or 66 <= texture_format <= 71
        if not is_astc:
            raise

        # Unity's RGBA32 format (4) is broadly supported. set_image encodes
        # first, then updates the format, so a failed ASTC attempt leaves the
        # original object metadata intact until this fallback succeeds.
        set_image = getattr(tex, "set_image", None)
        if callable(set_image):
            try:
                set_image(img, target_format=4)
            except Exception as fallback_exc:
                raise RuntimeError(
                    f"ASTC encoding failed ({exc}); RGBA32 fallback also failed ({fallback_exc})"
                ) from fallback_exc
        else:
            old_format = tex.m_TextureFormat
            try:
                tex.m_TextureFormat = 4
                tex.image = img
            except Exception as fallback_exc:
                tex.m_TextureFormat = old_format
                raise RuntimeError(
                    f"ASTC encoding failed ({exc}); RGBA32 fallback also failed ({fallback_exc})"
                ) from fallback_exc
        return True


def _import_into(obj: Any, data: bytes, keep: bool = True) -> Optional[dict]:
    t = _tname(obj)
    if t == "Texture2D":
        tex = obj.parse_as_object()
        img = _pil_image().open(io.BytesIO(data))
        img.load()
        img, resized = _fit_to_texture(tex, img, keep)
        astc_fallback = _set_texture_image(tex, img)
        tex.save()
        result = dict(resized or {})
        if astc_fallback:
            result["formatFallback"] = "ASTC encoding failed; texture saved as RGBA32"
        return result or None
    elif t == "TextAsset":
        txt = obj.parse_as_object()
        txt.m_Script = data.decode("utf-8", errors="surrogateescape")
        txt.save()
    elif t == "Mesh":
        raise ValueError("export_mesh not supported for type: Mesh (import is not available)")
    else:
        _import_typetree(obj, data)


def ping(_: dict) -> dict:
    info: Dict[str, Any] = {"python": sys.version.split()[0], "platform": sys.platform}
    for name in ("UnityPy", "PIL", "attr", "fsspec"):
        try:
            mod = __import__(name)
            info[name] = str(getattr(mod, "__version__", "ok"))
        except Exception as exc:
            info[name] = f"MISSING: {exc}"
    try:
        import uabe_native

        for lib in ("T2D", "Etcpak", "Astc", "Vorbis"):
            try:
                uabe_native.load(lib)
                info[f"native_{lib}"] = "ok"
            except Exception as exc:
                info[f"native_{lib}"] = f"MISSING: {exc}"
    except Exception as exc:
        info["native"] = f"MISSING: {exc}"
    for mod in ("texture2ddecoder", "etcpak", "astc_encoder", "lz4.block", "brotli", "uabe_audio", "fsb5"):
        try:
            __import__(mod)
            info[f"py_{mod}"] = "ok"
        except Exception as exc:
            info[f"py_{mod}"] = f"MISSING: {exc}"
    return info


def _describe(env: Any) -> dict:
    items: List[dict] = []
    types: List[str] = []
    for i, obj in enumerate(list(env.objects)):
        t = _tname(obj)
        name = _extract_name(obj)
        items.append({
            "index": i,
            "type": t,
            "id": _safe_int(getattr(obj, "path_id", 0)),
            "bytes": _try_size(obj),
            "name": name or "Unnamed asset",
            "container": _try_container(obj),
        })
        if t.strip() and t.strip() not in types:
            types.append(t.strip())
    return {"archives": _archive_names(env), "objects": items, "types": types}


def _unity_version_for_env(env: Any) -> Optional[str]:
    for obj in list(getattr(env, "objects", [])):
        owner = getattr(obj, "assets_file", None)
        value = getattr(owner, "unity_version", None) or getattr(owner, "m_UnityVersion", None)
        if isinstance(value, (tuple, list)):
            value = ".".join(str(part) for part in value)
        if value:
            return str(value)
    return None


def open_bundle(p: dict) -> dict:
    path = p["path"]
    if not os.path.exists(path):
        raise FileNotFoundError(f"Input not found: {path}")
    env = _unitypy().load(path)
    backup_path = path + ".uabe-original"
    if not os.path.exists(backup_path):
        shutil.copy2(path, backup_path)
    history_path = path + ".uabe-history"
    sid = uuid.uuid4().hex[:12]
    session = Session(env, path, backup_path, history_path)
    _sessions[sid] = session
    result = _describe(env)
    result["sessionId"] = sid
    result["modified"] = _history_indices(session)
    return result


def close_bundle(p: dict) -> dict:
    _sessions.pop(p.get("sessionId", ""), None)
    return {}


def stage_asset_companions(p: dict) -> dict:
    """Stage Unity sidecar streams beside an .assets file, including from an IPA ZIP."""
    source = os.path.abspath(p["sourcePath"])
    out_dir = os.path.abspath(p["outDir"])
    os.makedirs(out_dir, exist_ok=True)
    name = os.path.basename(source)
    if not name.lower().endswith(".assets"):
        return {"companions": []}

    destinations = {
        name + ".resS": os.path.join(out_dir, name + ".resS"),
        os.path.splitext(name)[0] + ".resource": os.path.join(out_dir, os.path.splitext(name)[0] + ".resource"),
    }
    found = []
    for sidecar_name, destination in destinations.items():
        direct = os.path.join(os.path.dirname(source), sidecar_name)
        if os.path.isfile(direct):
            shutil.copy2(direct, destination)
            found.append({"name": sidecar_name, "source": "sibling"})
    missing = {sidecar_name for sidecar_name, destination in destinations.items()
               if sidecar_name not in {item["name"] for item in found}}
    if not missing:
        return {"companions": found}

    import zipfile

    parent = os.path.dirname(source)
    try:
        archives = sorted(
            entry.path for entry in os.scandir(parent)
            if entry.is_file() and entry.name.lower().endswith((".zip", ".ipa"))
        )
    except OSError:
        return {"companions": found}
    for archive_path in archives:
        try:
            with zipfile.ZipFile(archive_path, "r") as archive:
                for member in archive.infolist():
                    if member.is_dir():
                        continue
                    sidecar_name = os.path.basename(member.filename.replace("\\", "/"))
                    if sidecar_name not in missing:
                        continue
                    destination = destinations[sidecar_name]
                    with archive.open(member, "r") as src, open(destination, "wb") as dst:
                        shutil.copyfileobj(src, dst)
                    missing.remove(sidecar_name)
                    found.append({"name": sidecar_name, "source": os.path.basename(archive_path)})
                    if not missing:
                        return {"companions": found}
        except (OSError, zipfile.BadZipFile):
            continue
    return {"companions": found}


def _saveable(env: Any) -> Any:
    main = getattr(env, "file", None)
    if main is not None and hasattr(main, "save"):
        return main
    found = [f for f in (getattr(env, "files", None) or {}).values() if hasattr(f, "save")]
    if len(found) == 1:
        return found[0]
    if not found:
        raise RuntimeError("This file type cannot be saved (it is not a single bundle or assets file).")
    raise RuntimeError(
        f"This source contains {len(found)} separate files, so it cannot be saved as one file. "
        "Open the individual bundle instead."
    )


def _mesh_stats(obj: Any) -> Optional[dict]:
    if _tname(obj) != "Mesh":
        return None
    try:
        tree = obj.parse_as_dict()
        vd = tree.get("m_VertexData") or {}
        channels = vd.get("m_Channels") or []
        return {
            "name": str(tree.get("m_Name", "")),
            "vertices": _safe_int(vd.get("m_VertexCount")),
            "bones": len(tree.get("m_BindPose") or []),
            "submeshes": len(tree.get("m_SubMeshes") or []),
            "compressed": _safe_int(tree.get("m_MeshCompression")),
            "skinned": any(_safe_int(c.get("dimension")) & 0xF for i, c in enumerate(channels) if i in (12, 13)),
        }
    except Exception:
        return None


def _raw_warnings(s: "Session", before: Dict[int, Any]) -> List[str]:
    notes: List[str] = []
    for idx, old in before.items():
        if not old:
            continue
        new = _mesh_stats(_get_object(s.env, idx))
        if not new:
            continue
        label = new["name"] or f"#{idx}"
        if old["bones"] != new["bones"]:
            notes.append(f"{label}: bones {old['bones']} -> {new['bones']} (the game may break or not render it)")
        if old["skinned"] != new["skinned"]:
            notes.append(f"{label}: skin weights {'present' if old['skinned'] else 'missing'} -> "
                         f"{'present' if new['skinned'] else 'missing'}")
        if old["compressed"] != new["compressed"]:
            notes.append(f"{label}: compression {old['compressed']} -> {new['compressed']}")
        if old["vertices"] != new["vertices"] or old["submeshes"] != new["submeshes"]:
            notes.append(f"{label}: vertices {old['vertices']} -> {new['vertices']}, "
                         f"sub-meshes {old['submeshes']} -> {new['submeshes']}")
    return notes


def _revert_raw(s: "Session") -> None:
    for idx, raw in s.raw_backup.items():
        try:
            _get_object(s.env, idx).set_raw_data(raw)
        except Exception:
            pass
    s.raw_backup.clear()
    s.raw_before.clear()


def save_bundle(p: dict) -> dict:
    s = _require(p["sessionId"])
    out = p["outPath"]
    env_file = _saveable(s.env)
    packer = p.get("packer", "original")
    if packer not in ("original", "none", "lz4", "lz4hc", "lzma"):
        raise ValueError(f"Unsupported compression mode: {packer}")
    try:
        data = bytes(env_file.save(packer=packer))
    except TypeError:
        # SerializedFile implementations in some UnityPy revisions do not
        # accept a packer argument; compression is only available for bundles.
        if packer != "original":
            raise ValueError("This file type does not support selecting bundle compression.")
        data = bytes(env_file.save())
    tmp = out + ".tmp"
    _write_bytes(tmp, data)
    pending_raw = sorted(s.raw_backup.keys())
    if pending_raw:
        try:
            probe = _unitypy().load(tmp)
            objects = list(probe.objects)
            for idx in pending_raw:
                objects[idx].parse_as_dict()
            del probe, objects
        except Exception as exc:
            os.remove(tmp)
            _revert_raw(s)
            raise RuntimeError(
                "The imported raw data is not valid for this object, so nothing was saved and the "
                f"original data was restored. ({exc})"
            ) from exc
    os.replace(tmp, out)
    if os.path.abspath(out) == os.path.abspath(s.path):
        for idx in list(s.restored_pending):
            _remove_object_backup(s, idx)
        s.restored_pending.clear()
    s.dirty = False
    result: Dict[str, Any] = {"path": out, "bytes": len(data)}
    if p.get("checksum"):
        import zlib
        result["crc32"] = f"{zlib.crc32(data) & 0xffffffff:08X}"
    if p.get("reload"):
        del data
        before = dict(s.raw_before)
        s.raw_backup.clear()
        s.raw_before.clear()
        s.env = _unitypy().load(out)
        s.path = out
        s.audio_cache.clear()
        _verify_pending_audio(s)
        described = _describe(s.env)
        described["sessionId"] = p["sessionId"]
        result["reloaded"] = described
        result["warnings"] = _raw_warnings(s, before)
    return result


def set_decrypt_key(p: dict) -> dict:
    _unitypy().set_assetbundle_decrypt_key(p.get("key", ""))
    return {}


def object_info(p: dict) -> dict:
    s = _require(p["sessionId"])
    idx = int(p["idx"])
    obj = _get_object(s.env, idx)
    t = _tname(obj)
    ext = _audio_decode(s, idx).ext if t == "AudioClip" else _extension_for(obj, t)
    return {
        "type": t,
        "filename": _export_base_name(obj, idx),
        "ext": ext,
        "mime": _mime_for(t),
    }


def export_object(p: dict) -> dict:
    s = _require(p["sessionId"])
    obj = _get_object(s.env, int(p["idx"]))
    t = _tname(obj)
    data = _audio_decode(s, int(p["idx"])).data if t == "AudioClip" else get_object_bytes(obj)
    if not data:
        raise ValueError(f"export_object not supported for type: {t}")
    _write_bytes(p["outPath"], data)
    return {"idx": int(p["idx"]), "type": t, "bytes": len(data)}


def _embedded_bundle_bytes(obj: Any) -> bytes:
    if _tname(obj) != "TextAsset":
        raise ValueError("This object is not a TextAsset.")
    parsed = obj.parse_as_object()
    script = getattr(parsed, "m_Script", b"")
    if isinstance(script, str):
        packed = script.encode("utf-8", "surrogateescape")
    else:
        packed = bytes(script or b"")
    signature = b"\x0esubway_bundles"
    header_size = len(signature) + 4
    if not packed.startswith(signature) or len(packed) <= header_size:
        raise ValueError("This TextAsset does not contain a subway_bundles AssetBundle.")
    expected = int.from_bytes(packed[len(signature):header_size], "little")
    if expected <= 0 or expected > 512 * 1024 * 1024:
        raise ValueError(f"Embedded AssetBundle declares an invalid size ({expected} bytes).")
    import zlib

    try:
        decoder = zlib.decompressobj(-zlib.MAX_WBITS)
        decoded = decoder.decompress(packed[header_size:], expected + 1)
        decoded += decoder.flush()
    except zlib.error as exc:
        raise ValueError(f"Could not decompress embedded AssetBundle: {exc}") from exc
    if len(decoded) != expected:
        raise ValueError(f"Embedded AssetBundle size mismatch: expected {expected}, got {len(decoded)}.")
    if not decoded.startswith((b"UnityFS", b"UnityRaw", b"UnityWeb", b"UnityArchive")):
        raise ValueError("The decompressed TextAsset is not a recognized Unity bundle.")
    return decoded


def _write_embedded_preview_texture(session: Session, source_obj: Any, out_path: str) -> bool:
    """Find the closest companion *_tex_low TextAsset and cache its Texture2D as PNG."""
    import re

    source_name = _extract_name(source_obj).casefold()
    if source_name.startswith("zombiejake"):
        source_name = source_name.replace("zombiejake", "jake_zombie", 1)
    ignored = {"bundle", "asset", "assets", "tex", "texture", "low", "high", "idles", "anim", "animation"}
    source_tokens = {part for part in re.split(r"[^a-z0-9]+", source_name) if part and part not in ignored}
    candidates = []
    for item in getattr(session.env, "objects", []):
        if _tname(item) != "TextAsset":
            continue
        name = _extract_name(item).casefold()
        if not name.endswith("tex_low"):
            continue
        tokens = {part for part in re.split(r"[^a-z0-9]+", name) if part and part not in ignored}
        score = len(source_tokens & tokens)
        if score:
            candidates.append((score, name, item))
    if not candidates:
        return False

    candidates.sort(key=lambda row: (-row[0], row[1]))
    unity = _unitypy()
    for _, _, candidate in candidates:
        try:
            texture_env = unity.load(_embedded_bundle_bytes(candidate))
            texture_obj = next((entry for entry in texture_env.objects if _tname(entry) == "Texture2D"), None)
            if texture_obj is None:
                continue
            image = texture_obj.parse_as_object().image
            if image is None:
                continue
            preview_path = out_path + ".preview.png"
            image.save(preview_path, format="PNG")
            return True
        except Exception:
            continue
    return False


def _mesh_preview_bytes(obj: Any, out_path: str, texture_path: Optional[str] = None) -> bytes:
    """Export an OBJ and, when available, give it a real MTL/Texture2D companion."""
    mesh = obj.parse_as_object()
    if not texture_path or not os.path.isfile(texture_path):
        return _export_mesh(obj)
    from UnityPy.export.MeshExporter import export_mesh_obj

    material_name = "UABETexture"
    material_names = [material_name] * len(getattr(mesh, "m_SubMeshes", []))
    text = export_mesh_obj(mesh, material_names)
    if not text:
        return _export_mesh(obj)
    stem = os.path.splitext(os.path.basename(out_path))[0]
    mtl_name = stem + ".mtl"
    texture_name = stem + "_texture.png"
    text = text.replace(f"mtllib {mesh.m_Name}.mtl", f"mtllib {mtl_name}")
    with open(os.path.join(os.path.dirname(out_path), mtl_name), "w", encoding="utf-8") as stream:
        stream.write(
            f"newmtl {material_name}\nKa 0.8 0.8 0.8\nKd 1.0 1.0 1.0\n"
            f"Ks 0.0 0.0 0.0\nillum 1\nmap_Kd {texture_name}\n"
        )
    import shutil

    shutil.copyfile(texture_path, os.path.join(os.path.dirname(out_path), texture_name))
    return text.encode("utf-8")


def extract_embedded_bundle(p: dict) -> dict:
    session = _require(p["sessionId"])
    idx = int(p["idx"])
    obj = _get_object(session.env, idx)
    data = _embedded_bundle_bytes(obj)
    # Validate that UnityPy can parse the reconstructed file before it reaches the UI.
    extracted = _unitypy().load(data)
    objects = list(getattr(extracted, "objects", []))
    if not objects:
        raise ValueError("The embedded Unity bundle contains no readable objects.")
    _write_bytes(p["outPath"], data)
    preview_texture = _write_embedded_preview_texture(session, obj, p["outPath"])
    type_counts: Dict[str, int] = {}
    for item in objects:
        kind = _tname(item)
        type_counts[kind] = type_counts.get(kind, 0) + 1
    return {"path": p["outPath"], "bytes": len(data), "objects": len(objects),
            "types": type_counts, "previewTexture": preview_texture}


def get_object_data(p: dict) -> dict:
    s = _require(p["sessionId"])
    idx = int(p["idx"])
    obj = _get_object(s.env, idx)
    t = _tname(obj)
    extra: Dict[str, Any] = {}
    if t == "AudioClip":
        a = _audio_decode(s, idx)
        data = a.data
        extra = {"ext": a.ext, "channels": a.channels, "frequency": a.frequency,
                 "length": a.length, "format": a.format, "note": a.note,
                 "playable": a.ext in ("wav", "mp3"), "preview": False}
        if a.ext == "ogg" and p.get("previewPath"):
            try:
                import uabe_audio

                _write_bytes(p["previewPath"], uabe_audio.ogg_to_wav(a.data))
                extra["preview"] = True
            except Exception:
                extra["preview"] = False
    else:
        if t == "Mesh":
            texture_path = s.path + ".preview.png"
            data = _mesh_preview_bytes(obj, p["outPath"], texture_path)
        else:
            data = get_object_bytes(obj)
        if t == "TextAsset":
            try:
                unpacked = _embedded_bundle_bytes(obj)
                data = (f"Embedded Unity AssetBundle\nUncompressed size: {len(unpacked)} bytes\n"
                        "Use Open embedded AssetBundle to inspect its Texture2D and Mesh objects.\n").encode("utf-8")
                extra["embeddedBundle"] = True
                extra["embeddedBytes"] = len(unpacked)
            except ValueError:
                # Some TextAssets are binary or use a game-specific encoding. Keep the
                # preview readable while leaving raw export/import byte-preserving.
                data = data.decode("utf-8", errors="replace").encode("utf-8")
                extra["embeddedBundle"] = False
    _write_bytes(p["outPath"], data)
    kind = {"Texture2D": "image", "Mesh": "mesh", "TextAsset": "text", "AudioClip": "audio"}.get(t, "json")
    result = {
        "idx": idx,
        "type": t,
        "id": _safe_int(getattr(obj, "path_id", 0)),
        "name": _extract_name(obj),
        "kind": kind,
        "bytes": len(data),
    }
    result.update(extra)
    return result


def import_object(p: dict) -> dict:
    s = _require(p["sessionId"])
    obj = _get_object(s.env, int(p["idx"]))
    _snapshot_object(s, int(p["idx"]), obj)
    with open(p["inPath"], "rb") as fh:
        data = fh.read()
    if _tname(obj) == "AudioClip":
        raise ValueError("Use replace_audio for AudioClip objects.")
    info = _import_into(obj, data, bool(p.get("keepSize", True)))
    _persist_object_backup(s, int(p["idx"]))
    s.dirty = True
    s.audio_cache.clear()
    return info or {}


def export_raw(p: dict) -> dict:
    s = _require(p["sessionId"])
    obj = _get_object(s.env, int(p["idx"]))
    data = bytes(obj.get_raw_data())
    _write_bytes(p["outPath"], data)
    return {"type": _tname(obj), "bytes": len(data)}


def export_dump(p: dict) -> dict:
    s = _require(p["sessionId"])
    obj = _get_object(s.env, int(p["idx"]))
    data = _export_typetree_json(obj)
    _write_bytes(p["outPath"], data)
    return {"type": _tname(obj), "bytes": len(data)}


def import_raw(p: dict) -> dict:
    s = _require(p["sessionId"])
    idx = int(p["idx"])
    obj = _get_object(s.env, idx)
    _snapshot_object(s, idx, obj)
    with open(p["inPath"], "rb") as fh:
        data = fh.read()
    if len(data) < 4:
        raise ValueError("The raw file is empty or too small.")
    if idx not in s.raw_backup:
        s.raw_backup[idx] = bytes(obj.get_raw_data())
        s.raw_before[idx] = _mesh_stats(obj)
    obj.set_raw_data(data)
    _persist_object_backup(s, idx)
    s.dirty = True
    s.audio_cache.clear()
    return {"bytes": len(data)}


def import_dump(p: dict) -> dict:
    s = _require(p["sessionId"])
    idx = int(p["idx"])
    obj = _get_object(s.env, idx)
    _snapshot_object(s, idx, obj)
    with open(p["inPath"], "rb") as fh:
        data = fh.read()
    _import_typetree(obj, data)
    _persist_object_backup(s, idx)
    s.dirty = True
    s.audio_cache.clear()
    return {}


def replace_audio(p: dict) -> dict:
    import wave

    import uabe_audio

    s = _require(p["sessionId"])
    idx = int(p["idx"])
    obj = _get_object(s.env, idx)
    _snapshot_object(s, idx, obj)
    if _tname(obj) != "AudioClip":
        raise ValueError("Object is not an AudioClip")

    with wave.open(p["inPath"], "rb") as wav:
        channels, width, rate, frames = wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()
        pcm = wav.readframes(frames)
    if width != 2:
        raise ValueError(f"Expected 16-bit PCM WAV, got {width * 8}-bit")
    if frames == 0:
        raise ValueError("The audio file is empty.")

    fsb = uabe_audio.build_fsb5_pcm16(pcm, channels, rate)
    tree = obj.parse_as_dict()
    src, _, _, nested = _stream_ref(tree)

    updates = {
        "m_Channels": channels, "m_Frequency": rate, "m_BitsPerSample": 16,
        "m_Length": frames / float(rate), "m_CompressionFormat": 0,
        "m_IsTrackerFormat": False, "m_SubsoundIndex": 0,
        "m_PreloadAudioData": True, "m_LoadType": 0,
    }
    for key, value in updates.items():
        if key in tree:
            tree[key] = value

    if src:
        files, key = _find_stream(obj, s.env, src)
        if files is None:
            raise ValueError(
                f"The audio stream '{src}' is stored outside this file, so this clip cannot be replaced here."
            )
        old = _entry_view(files[key])
        offset = (len(old) + 31) // 32 * 32
        merged = bytearray(offset + len(fsb))
        merged[:len(old)] = old
        merged[offset:] = fsb
        try:
            from UnityPy.streams import EndianBinaryReader
        except ImportError:
            from UnityPy.streams.EndianBinaryReader import EndianBinaryReader
        reader = EndianBinaryReader(bytes(merged), endian=">")
        _inherit_attrs(files[key], reader)
        del merged
        for holder in _file_dicts(obj, s.env):
            for k in list(holder.keys()):
                if _base(k) == _base(src):
                    holder[k] = reader
        if nested:
            tree["m_Resource"] = {"m_Source": src, "m_Offset": offset, "m_Size": len(fsb)}
        else:
            tree["m_Offset"] = offset
            tree["m_Size"] = len(fsb)
    elif "m_AudioData" in tree:
        tree["m_AudioData"] = fsb
        if isinstance(tree.get("m_Resource"), dict):
            tree["m_Resource"] = {"m_Source": "", "m_Offset": 0, "m_Size": 0}
    else:
        raise ValueError("This clip has neither an inline buffer nor a stream reference.")

    obj.save_typetree(tree)
    s.audio_override[idx] = fsb
    s.pending_audio[idx] = hashlib.sha256(fsb).hexdigest()
    s.audio_cache.pop(idx, None)
    _persist_object_backup(s, idx)
    s.dirty = True
    return {"bytes": len(fsb), "channels": channels, "frequency": rate}


def _verify_pending_audio(s: "Session") -> None:
    pending = dict(s.pending_audio)
    s.pending_audio.clear()
    s.audio_override.clear()
    s.audio_cache.clear()
    for idx, digest in pending.items():
        raw, _ = _audio_raw(_get_object(s.env, idx), s.env)
        if hashlib.sha256(raw).hexdigest() != digest:
            raise RuntimeError(
                f"The file was saved, but the new audio for object #{idx} is not inside it "
                "(the audio stream was not written back)."
            )


_METHODS: Dict[str, Callable[[dict], dict]] = {
    "ping": ping,
    "open_bundle": open_bundle,
    "close_bundle": close_bundle,
    "stage_asset_companions": stage_asset_companions,
    "save_bundle": save_bundle,
    "restore_object": restore_object,
    "restore_all": restore_all,
    "set_decrypt_key": set_decrypt_key,
    "object_info": object_info,
    "export_object": export_object,
    "extract_embedded_bundle": extract_embedded_bundle,
    "get_object_data": get_object_data,
    "import_object": import_object,
    "replace_audio": replace_audio,
    "export_raw": export_raw,
    "export_dump": export_dump,
    "import_raw": import_raw,
    "import_dump": import_dump,
}


def dispatch(method: str, payload_json: str) -> str:
    try:
        fn = _METHODS.get(method)
        if fn is None:
            raise KeyError(f"Unknown method: {method}")
        payload = json.loads(payload_json) if payload_json else {}
        return json.dumps({"ok": True, "data": fn(payload)}, ensure_ascii=False)
    except Exception as exc:
        msg = str(exc) or exc.__class__.__name__
        return json.dumps({"ok": False, "error": msg, "trace": traceback.format_exc()},
                          ensure_ascii=False)


import uabe_sync

uabe_sync.install(_METHODS)
