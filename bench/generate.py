#!/usr/bin/env python3
"""Generates the benchmark inputs.

Every workload is a document, a patch, and the expected result, so that the
output of each implementation can be checked and all of them are known to have
done the same work. The seed is fixed, so runs are comparable.

    python3 bench/generate.py bench/data
"""

import copy
import json
import random
import sys
import urllib.request
from pathlib import Path

REAL_WORLD = {
    "twitter": "https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/twitter.json",
    "citm_catalog": "https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/citm_catalog.json",
}


def record(rng, i):
    return {
        "id": i,
        "guid": "%032x" % rng.getrandbits(128),
        "active": rng.random() < 0.5,
        "balance": round(rng.uniform(0, 10000), 2),
        "name": "User Number %d" % i,
        "email": "user%d@example.com" % i,
        "about": " ".join(rng.choice(WORDS) for _ in range(30)),
        "tags": [rng.choice(WORDS) for _ in range(6)],
        "address": {"street": "%d Main St" % i, "city": rng.choice(WORDS), "zip": "%05d" % rng.randrange(99999)},
        "friends": [{"id": rng.randrange(1000), "name": rng.choice(WORDS)} for _ in range(3)],
    }


WORDS = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore".split()


def escape(token):
    return token.replace("~", "~0").replace("/", "~1")


def pointer(tokens):
    return "".join("/" + escape(str(t)) for t in tokens)


def get(doc, tokens):
    for t in tokens:
        doc = doc[t]
    return doc


def walk(rng, doc):
    """Returns a random path to an existing value, biased toward going deep."""
    tokens, node = [], doc
    while True:
        if isinstance(node, dict) and node:
            key = rng.choice(list(node))
            tokens.append(key)
            node = node[key]
        elif isinstance(node, list) and node:
            i = rng.randrange(len(node))
            tokens.append(i)
            node = node[i]
        else:
            return tokens
        if len(tokens) >= 2 and rng.random() < 0.2:
            return tokens


def patch_for(rng, doc, count):
    """Builds a valid patch of `count` operations, applying it to `doc`."""
    ops = []
    mix = ["replace"] * 7 + ["add"] * 4 + ["append"] * 2 + ["remove"] * 2 + ["test"] * 3 + ["copy", "move"]
    while len(ops) < count:
        kind = rng.choice(mix)
        tokens = walk(rng, doc)
        if not tokens:
            continue
        parent = get(doc, tokens[:-1])
        path = pointer(tokens)
        if kind == "replace":
            value = rng.choice([rng.randrange(1000), "updated value", True, None, {"replaced": [1, 2, 3]}])
            parent[tokens[-1]] = copy.deepcopy(value)
            ops.append({"op": "replace", "path": path, "value": value})
        elif kind == "test":
            ops.append({"op": "test", "path": path, "value": copy.deepcopy(get(doc, tokens))})
        elif kind == "add" and isinstance(parent, dict):
            key = "field_%d" % rng.randrange(1 << 30)
            parent[key] = {"added": True}
            ops.append({"op": "add", "path": pointer(tokens[:-1] + [key]), "value": {"added": True}})
        elif kind == "add":
            parent.insert(tokens[-1], "inserted")
            ops.append({"op": "add", "path": path, "value": "inserted"})
        elif kind == "append" and isinstance(parent, list):
            parent.append(7)
            ops.append({"op": "add", "path": pointer(tokens[:-1] + ["-"]), "value": 7})
        elif kind == "remove":
            del parent[tokens[-1]]
            ops.append({"op": "remove", "path": path})
        elif kind == "copy" and isinstance(parent, dict):
            key = "copy_%d" % rng.randrange(1 << 30)
            parent[key] = copy.deepcopy(parent[tokens[-1]])
            ops.append({"op": "copy", "from": path, "path": pointer(tokens[:-1] + [key])})
        elif kind == "move" and isinstance(parent, dict):
            key = "moved_%d" % rng.randrange(1 << 30)
            parent[key] = parent.pop(tokens[-1])
            ops.append({"op": "move", "from": path, "path": pointer(tokens[:-1] + [key])})
    return ops


def workload(out, name, doc, ops, rng, pretty=False):
    """Writes one workload. `doc` is left patched."""
    text = json.dumps(doc, ensure_ascii=False, indent=2 if pretty else None, separators=None if pretty else (",", ":"))
    patched = copy.deepcopy(doc)
    patch = patch_for(rng, patched, ops)
    (out / (name + ".doc.json")).write_text(text, encoding="utf-8")
    (out / (name + ".patch.json")).write_text(json.dumps(patch, ensure_ascii=False), encoding="utf-8")
    (out / (name + ".expected.json")).write_text(json.dumps(patched, ensure_ascii=False), encoding="utf-8")
    print("%-22s doc %12d bytes   patch %5d ops %9d bytes" % (name, len(text.encode()), len(patch), len(json.dumps(patch))))


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(6902)

    workload(out, "small", record(rng, 1), 4, rng)
    workload(out, "medium", {"users": [record(rng, i) for i in range(150)]}, 8, rng)
    workload(out, "large", {"users": [record(rng, i) for i in range(30000)]}, 8, rng)
    workload(out, "many_ops", {"users": [record(rng, i) for i in range(150)]}, 1000, rng)
    workload(out, "pretty", {"users": [record(rng, i) for i in range(3000)]}, 8, rng, pretty=True)
    workload(out, "keyed", {"users": {"user:%d" % i: record(rng, i) for i in range(30000)}}, 8, rng)

    for name, url in REAL_WORLD.items():
        path = out / (name + ".source.json")
        if not path.exists():
            urllib.request.urlretrieve(url, path)
        workload(out, name, json.loads(path.read_text(encoding="utf-8")), 8, rng)


if __name__ == "__main__":
    main()
