import json
import os
import sys
import tempfile
import types

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))


class Kind:
    def __init__(self, name):
        self.name = name


class Tex:
    def __init__(self, image):
        self.image = image
        self.saved = 0

    def save(self):
        self.saved += 1


class Obj:
    def __init__(self, kind, pid, name, raw=b"", payload=None, stream=0):
        self.type = Kind(kind)
        self.path_id = pid
        self._name = name
        self.raw = raw
        self.payload = payload
        self.stream = stream
        self.byte_size = len(raw)
        self.assets_file = types.SimpleNamespace(unity_version="2020.3.30f1")
        self.container = None

    def peek_name(self):
        return self._name

    def get_raw_data(self):
        return self.raw

    def set_raw_data(self, data):
        self.raw = bytes(data)

    def parse_as_object(self):
        return self.payload

    def parse_as_dict(self):
        if self.type.name == "Mesh":
            verts, bones = self.raw[1:].split(b"B")
            return {"m_Name": self._name, "m_VertexData": {"m_VertexCount": int(verts), "m_Channels": []},
                    "m_BindPose": [0] * int(bones), "m_SubMeshes": [1], "m_MeshCompression": 0,
                    "m_StreamData": {"size": self.stream}}
        return {"m_Name": self._name}


class Env:
    def __init__(self, objects):
        self.objects = objects
        self.file = types.SimpleNamespace(files={}, save=lambda: b"BUNDLE")
        self.files = {}


src_objs = [
    Obj("Mesh", 1, "1", b"V100B0"),
    Obj("Mesh", 2, "4", b"V200B5"),
    Obj("Mesh", 3, "streamed", b"V10B0", stream=99),
    Obj("Mesh", 4, "only_android", b"V1B0"),
    Obj("Texture2D", 5, "tex_a", payload=Tex("android-image")),
    Obj("Texture2D", 6, "broken", payload=Tex(None)),
    Obj("TextAsset", 7, "cfg", b"android-text"),
]
dst_objs = [
    Obj("Mesh", 1, "1", b"V50B0"),
    Obj("Mesh", 22, "4", b"V60B26"),
    Obj("Mesh", 3, "streamed", b"V10B0"),
    Obj("Mesh", 9, "only_ios", b"V1B0"),
    Obj("Texture2D", 15, "tex_a", payload=Tex("ios-image")),
    Obj("Texture2D", 16, "broken", payload=Tex("ios-broken")),
    Obj("TextAsset", 17, "cfg", b"ios-text"),
]
envs = {"/src.bundle": Env(src_objs), "/dst.bundle": Env(dst_objs)}
fake = types.ModuleType("UnityPy")
fake.load = lambda path: envs[path]
fake.set_assetbundle_decrypt_key = lambda key: None
sys.modules["UnityPy"] = fake

import uabe_backend as backend
import uabe_sync

tmp = tempfile.mkdtemp()
real_src = os.path.join(tmp, "src.bundle")
open(real_src, "wb").write(b"x")
_orig_load = uabe_sync._load_source
uabe_sync._load_source = lambda path: envs["/src.bundle"]


def call(method, **kw):
    return json.loads(backend.dispatch(method, json.dumps(kw)))


backend._sessions["s1"] = backend.Session(envs["/dst.bundle"], "/dst.bundle")

scan = call("sync_scan", sessionId="s1", sourcePath=real_src, types=["Mesh", "Texture2D", "TextAsset"], match="name")
assert scan["ok"], scan
data = scan["data"]
names = {(m["type"], m["name"]): m for m in data["matches"]}
assert set(names) == {("Mesh", "1"), ("Mesh", "4"), ("Mesh", "streamed"), ("Texture2D", "tex_a"),
                      ("Texture2D", "broken"), ("TextAsset", "cfg")}, names
assert "bones 26 -> 5" in names[("Mesh", "4")]["note"] and "vertices 60 -> 200" in names[("Mesh", "4")]["note"]
assert "external stream" in names[("Mesh", "streamed")]["note"]
assert data["unmatchedSource"] == ["Mesh: only_android"] and data["unmatchedTarget"] == 1
assert data["sourceUnity"] == data["targetUnity"] == "2020.3.30f1"

only_mesh = call("sync_scan", sessionId="s1", sourcePath=real_src, types=["Mesh"], match="name")["data"]
assert {m["type"] for m in only_mesh["matches"]} == {"Mesh"}

applied = call("sync_apply", sessionId="s1", sourcePath=real_src, types=["Mesh", "Texture2D", "TextAsset"],
               match="name", exclude=[names[("TextAsset", "cfg")]["dstIndex"]])
assert applied["ok"], applied
report = applied["data"]
assert report["replaced"] == 3 and report["skipped"] == 2 and report["failed"] == 0, report
assert dst_objs[0].raw == b"V100B0" and dst_objs[1].raw == b"V200B5"
assert dst_objs[2].raw == b"V10B0"
assert dst_objs[4].payload.image == "android-image" and dst_objs[4].payload.saved == 1
assert dst_objs[5].payload.image == "ios-broken"
assert dst_objs[6].raw == b"ios-text"
assert sorted(report["modifiedIndices"]) == [0, 1, 4]
session = backend._sessions["s1"]
assert set(session.raw_backup) == {0, 1} and session.raw_backup[1] == b"V60B26"
assert session.raw_before[1]["bones"] == 26

by_id = call("sync_scan", sessionId="s1", sourcePath=real_src, types=["Mesh"], match="pathid")["data"]
assert sorted(m["name"] for m in by_id["matches"]) == ["1", "streamed"]

dup_src = Env([Obj("Mesh", 31, "default", b"V1B0"), Obj("Mesh", 32, "default", b"V2B0")])
dup_dst = Env([Obj("Mesh", 32, "default", b"V8B0"), Obj("Mesh", 40, "default", b"V9B0")])
uabe_sync._load_source = lambda path: dup_src
backend._sessions["s2"] = backend.Session(dup_dst, "/dup")
dup = call("sync_scan", sessionId="s2", sourcePath=real_src, types=["Mesh"], match="name")["data"]
pairs = {(m["srcIndex"], m["dstIndex"]) for m in dup["matches"]}
assert pairs == {(1, 0), (0, 1)}, pairs

from PIL import Image


class SizedTex(Tex):
    def __init__(self, image, w=0, h=0):
        super().__init__(image)
        self.m_Width = w
        self.m_Height = h


resize_src = Env([Obj("Texture2D", 1, "t", payload=SizedTex(Image.new("RGBA", (8, 8), (0, 255, 0, 255))))])
resize_dst = Env([Obj("Texture2D", 2, "t", payload=SizedTex("old", 4, 4))])
uabe_sync._load_source = lambda path: resize_src
backend._sessions["s3"] = backend.Session(resize_dst, "/resize")
fitted = call("sync_apply", sessionId="s3", sourcePath=real_src, types=["Texture2D"], match="name")
assert fitted["ok"] and resize_dst.objects[0].payload.image.size == (4, 4), fitted
assert fitted["data"]["items"][0]["reason"] == "resized 8x8 -> 4x4"
free = call("sync_apply", sessionId="s3", sourcePath=real_src, types=["Texture2D"], match="name", keepSize=False)
assert free["ok"] and resize_dst.objects[0].payload.image.size == (8, 8)

missing = call("sync_scan", sessionId="nope", sourcePath=real_src)
assert not missing["ok"]
uabe_sync._load_source = _orig_load
gone = call("sync_scan", sessionId="s1", sourcePath=os.path.join(tmp, "gone.bundle"))
assert not gone["ok"] and "not found" in gone["error"]
assert call("sync_close")["ok"]
print("sync tests OK")
