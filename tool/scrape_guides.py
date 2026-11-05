"""Coleta counters, sinergias e builds de cada campeão no WildRiftFire.

Roda no GitHub Actions (o site não é acessível de todo lugar) e grava
assets/guides.json. Uma requisição por segundo, para não sobrecarregar o site.
"""
import datetime
import html
import json
import re
import sys
import time
import urllib.request

BASE = "https://www.wildriftfire.com"
UA = "Mozilla/5.0 (Linux; Android 14) RiftHelperFanApp/1.0 (+github.com/Guilherme-AMS/wild-rift-helpercoach)"
OUT = sys.argv[1] if len(sys.argv) > 1 else "assets/guides.json"


def get(path: str) -> str:
    req = urllib.request.Request(BASE + path, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", errors="ignore")


def names(fragment: str, pattern: str) -> list[str]:
    return [html.unescape(x).strip() for x in re.findall(pattern, fragment)]


def between(h: str, start: str, ends: list[str]) -> str:
    i = h.find(start)
    if i < 0:
        return ""
    j = len(h)
    for e in ends:
        k = h.find(e, i + len(start))
        if 0 <= k < j:
            j = k
    return h[i:j]


def sections(block: str) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    parts = re.split(r'<div class="section (\w+)">', block)
    for k in range(1, len(parts) - 1, 2):
        key, body = parts[k], parts[k + 1]
        found = names(body, r'<div class="name">([^<]+)</div>')
        if found:
            out.setdefault(key, found)
    return out


def parse(h: str) -> dict | None:
    m = re.search(r"<h2>(.+?) is Countered By</h2>", h)
    m2 = re.search(r"<h2>(.+?)&#039;s Item Build</h2>|<h2>(.+?)'s Item Build</h2>", h)
    if m:
        name = html.unescape(m.group(1)).strip()
    elif m2:
        name = html.unescape(m2.group(1) or m2.group(2)).strip()
    else:
        return None

    countered = between(h, "is Countered By</h2>", ["Synergizes With</h2>", "<h2>"])
    synergy = between(h, "Synergizes With</h2>", ["<h2>", "</section>"])
    items = between(h, "wf-champion__data__items", ["wf-champion__data__spells", "wf-champion__data__situational"])
    spells = between(h, "wf-champion__data__spells", ["wf-champion__data__situational", "counters-block"])

    item_secs = sections(items)
    spell_secs = sections(spells)
    tier = re.search(r'<span class="data rank (\w+)">', h)
    role = re.search(r'Recommended Role</span>\s*<span class="data">(?:\s*<img[^>]*>)?\s*([^<]+)</span>', h)

    return {
        "name": name,
        "role": html.unescape(role.group(1)).strip() if role else "",
        "siteTier": tier.group(1).upper() if tier else "",
        "counteredBy": names(countered, r"<span>([^<]+)</span>"),
        "synergy": names(synergy, r"<span>([^<]+)</span>"),
        "items": {k: item_secs[k] for k in ("starting", "core", "boots", "final") if k in item_secs},
        "spells": spell_secs.get("spells", []),
        "runes": spell_secs.get("runes", []),
    }


def main() -> None:
    home = get("/")
    links = sorted(set(re.findall(r'href="(/guide/[a-z0-9\-]+)"', home)))
    print("campeões encontrados:", len(links))
    guides: dict[str, dict] = {}
    failures = []
    for i, link in enumerate(links, 1):
        try:
            g = parse(get(link))
            if g and (g["counteredBy"] or g["items"]):
                g["slug"] = link.rsplit("/", 1)[-1]
                guides[g.pop("name")] = g
            else:
                failures.append(link)
        except Exception as e:  # noqa: BLE001
            failures.append(f"{link} ({e})")
        if i % 20 == 0:
            print(f"{i}/{len(links)}")
        time.sleep(1.0)

    patch = ""
    m = re.search(r"Patch\s+(\d+\.\d+[a-z]?)", home)
    if m:
        patch = m.group(1)
    data = {
        "patch": patch,
        "updated": datetime.date.today().isoformat(),
        "source": "WildRiftFire",
        "guides": dict(sorted(guides.items())),
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print("guias salvos:", len(guides), "| falhas:", len(failures))
    for f_ in failures:
        print("  falhou:", f_)
    if len(guides) < 50:
        sys.exit("poucos guias coletados, abortando")


if __name__ == "__main__":
    main()
