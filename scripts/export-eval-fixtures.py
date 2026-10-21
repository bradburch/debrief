#!/usr/bin/env python3
"""Export anonymized eval fixtures from the local Debrief DB (read-only).

Writes only to eval/fixtures/local/ (gitignored). Prints only counts/ids/stats.
Anonymization is heuristic: review eval/fixtures/local/REVIEW.md before use.
"""
import argparse, hashlib, json, os, random, re, sqlite3, sys
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "eval", "fixtures", "local")
DEFAULT_DB = "~/Library/Application Support/Debrief/db/debrief.sqlite"
DEFAULT_PROMPTS = "~/Library/Application Support/Debrief/prompts"

ALLOW = set("""i i'm i'll i've i'd ok okay aws gcp api apis sql nosql python java javascript typescript
kubernetes docker linux unix ios android swift react node nodejs golang rust ruby rails django flask
postgres postgresql mysql redis kafka spark hadoop terraform jenkins github gitlab git jira slack zoom
excel word powerpoint html css json xml http https rest graphql grpc ci cd ml ai llm gpt
monday tuesday wednesday thursday friday saturday sunday january february march april may june july
august september october november december american english spanish french german chinese indian
european asian african california texas york""".split())

_dict = None
def dict_words():
    global _dict
    if _dict is None:
        s = set()
        try:
            with open("/usr/share/dict/words", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    w = line.strip()
                    if w and w == w.lower() and w.isalpha():
                        s.add(w)
        except OSError:
            pass
        _dict = s
    return _dict

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
URL = re.compile(r"(?:https?://|www\.)\S+|\b[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:com|org|net|io|ai|co|dev|edu|gov)(?:/\S*)?\b", re.I)
PHONE = re.compile(r"(?<![\w$])(?:\+\d{1,3}[\s.-]?)?(?:\(\d{3}\)\s?|\d{3}[\s.-]?)\d{3}[\s.-]?\d{4}(?!\w)|(?<![\w$])\+\d{1,3}(?:[\s.-]?\d{2,4}){2,5}(?!\w)")
CAP = re.compile(r"\b[A-Z][a-z]+(?:'[a-z]+)?\b")
CTX = re.compile(r"\b((?i:my name is|this is|i'm|talk to|with))\s+((?:[A-Z][a-z]+)(?:\s+[A-Z][a-z]+)*)")

def alias_for(i):
    s, n = "", i
    while True:
        s = chr(65 + n % 26) + s
        n = n // 26 - 1
        if n < 0:
            return "Company " + s

class Anonymizer:
    def __init__(self, names):
        # names: list of company names in alias order
        self.alias = {n.lower(): alias_for(i) for i, n in enumerate(names)}
        ordered = sorted((n for n in names if n.strip()), key=len, reverse=True)
        self.co = re.compile(r"(?<!\w)(?:%s)(?!\w)" % "|".join(re.escape(n) for n in ordered), re.I) if ordered else None
        self.counts = Counter()

    def _sub(self, rx, tok, text, cat):
        text, n = rx.subn(tok, text)
        self.counts[cat] += n
        return text

    def run(self, text, local=None):
        c = local if local is not None else Counter()
        before = Counter(self.counts)
        text = self._sub(EMAIL, "[EMAIL]", text, "email")
        text = self._sub(URL, "[URL]", text, "url")
        text = self._sub(PHONE, "[PHONE]", text, "phone")
        if self.co:
            text = self.co.sub(lambda m: self.alias[m.group(0).lower()], text)
        text = self._names(text)
        for k, v in self.counts.items():
            if v != before[k]:
                c[k] += v - before[k]
        return text

    def _names(self, text):
        d = dict_words()
        def ctx(m):
            words = m.group(2).split()
            keep = []
            out = []
            for w in words:
                if w.lower() in ALLOW or w.startswith("Company"):
                    out.append(w)
                else:
                    out.append("[NAME]")
            # collapse adjacent [NAME]
            res = []
            for w in out:
                if w == "[NAME]" and res and res[-1] == "[NAME]":
                    continue
                res.append(w)
            self.counts["name"] += sum(1 for w in out if w == "[NAME]") and 1
            return m.group(1) + " " + " ".join(res)
        text = CTX.sub(ctx, text)
        def tok(m):
            w = m.group(0)
            base = w.split("'")[0].lower()
            if base in ALLOW or w.lower() in ALLOW or base in d:
                return w
            pre = text[:m.start()].rstrip(" \t\"'(")
            if not pre or pre[-1] in ".?!":
                return w
            self.counts["name"] += 1
            return "[NAME]"
        return CAP.sub(tok, text)

def parse_transcript_only(markdown):
    """Mirror of PromptStore.parseTranscriptOnly: only the lines before the first heading count."""
    key = "transcript-only:"
    for line in markdown.split("\n"):
        t = line.strip(" \t")
        if t.startswith("#"):
            return False
        if not t.lower().startswith(key):
            continue
        return t[len(key):].strip(" \t").lower() == "true"
    return False

def transcript_only_types(prompts_dir):
    """Round types whose overlay opts out of scoring (base.md is not an overlay)."""
    d = os.path.expanduser(prompts_dir)
    out = set()
    for fn in os.listdir(d):
        if fn.endswith(".md") and fn != "base.md":
            with open(os.path.join(d, fn), encoding="utf-8") as f:
                if parse_transcript_only(f.read()):
                    out.add(fn[:-3])
    return out

def count_company(anon, text):
    return len(re.findall(r"Company [A-Z]+\b", text))

def self_test():
    a = Anonymizer(["Acme, Inc.", "Foo-Bar", "Block"])
    t = a.run("I interviewed at ACME, Inc. and foo-bar yesterday")
    assert "Company A" in t and "Company B" in t and "ACME" not in t.upper().replace("COMPANY", ""), t
    t = a.run("Email me at jane.doe@example.com or see https://example.com/x or www.foo.org, call (415) 555-1234 or +44 20 7946 0958")
    for tag in ("[EMAIL]", "[URL]", "[PHONE]"):
        assert tag in t, t
    assert "@" not in t and "555" not in t and "7946" not in t, t
    t = a.run("Hi, my name is Priya Raman and I like it.")
    assert "Priya" not in t and "Raman" not in t and "[NAME]" in t, t
    t = a.run("Then I talked to Priya yesterday.")
    assert "Priya" not in t, t
    assert a.run("Music is my hobby") == "Music is my hobby"
    assert a.run("Sure. Tuesday works, we use Python and AWS.") == "Sure. Tuesday works, we use Python and AWS."
    t = a.run("The offer was $180k base, 15% bonus, on March 3rd.")
    assert "$180k" in t and "15%" in t and "March 3rd" in t, t
    assert "(indistinct" not in a.run("we sat in silence")
    assert parse_transcript_only("transcript-only: true\n\n# Mock\n")
    assert parse_transcript_only("  Transcript-Only:  TRUE  \n# x")
    assert not parse_transcript_only("transcript-only: false\n# x")
    assert not parse_transcript_only("# Mock\ntranscript-only: true\n"), "prose after a heading never opts out"
    assert not parse_transcript_only("transcript-only: yes\n")
    print("self-test OK")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--n", type=int, default=30)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--prompts-dir", default=DEFAULT_PROMPTS)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="print selection counts; write nothing")
    args = ap.parse_args()
    if args.self_test:
        self_test(); return

    path = os.path.expanduser(args.db)
    db = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
    companies = db.execute("SELECT id, name, status FROM company ORDER BY id").fetchall()
    cname = {i: n for i, n, _ in companies}
    cstatus = {i: s for i, _, s in companies}
    alias = {i: alias_for(k) for k, (i, _, _) in enumerate(companies)}
    anon = Anonymizer([n for _, n, _ in companies])

    # Transcript-only rounds (practice) are never coached, and aren't a real "later round"
    # for the per-company advancement label either.
    skip = transcript_only_types(args.prompts_dir)
    sess = [s for s in db.execute("SELECT id, companyId, roundType, date, durationSeconds, contextNotes FROM session "
                                  "ORDER BY date, id").fetchall() if s[2] not in skip]
    bycomp = defaultdict(list)
    for s in sess:
        bycomp[s[1]].append(s)
    label = {}
    for cid, lst in bycomp.items():
        for k, s in enumerate(lst):
            if k < len(lst) - 1:
                label[s[0]] = (True, "later_round")
            elif cstatus[cid] == "dead":
                label[s[0]] = (False, "last_at_dead")
            else:
                label[s[0]] = (None, "none")
    has_seg = {r[0] for r in db.execute("SELECT DISTINCT sessionId FROM transcriptSegment")}
    cands = [s for s in sess if s[0] in has_seg]

    rng = random.Random(args.seed)
    groups = defaultdict(list)
    for s in cands:
        groups[s[2]].append(s)
    chosen = []
    if args.all or len(cands) <= args.n:
        chosen = list(cands)
    else:
        small = {k: v for k, v in groups.items() if len(v) <= 2}
        big = {k: v for k, v in groups.items() if len(v) > 2}
        for v in small.values():
            chosen += v
        rem = max(0, args.n - len(chosen))
        tot = sum(len(v) for v in big.values())
        quota = {k: len(v) * rem / tot for k, v in big.items()} if tot else {}
        take = {k: int(q) for k, q in quota.items()}
        left = rem - sum(take.values())
        for k in sorted(quota, key=lambda k: quota[k] - take[k], reverse=True)[:left]:
            take[k] += 1
        for k in sorted(big):
            v = big[k]
            pools = {True: [], False: [], None: []}
            for s in v:
                pools[label[s[0]][0]].append(s)
            for p in pools.values():
                rng.shuffle(p)
            picked = []
            want = min(take[k], len(v))
            while len(picked) < want:
                progressed = False
                for key in (True, False):
                    if len(picked) < want and pools[key]:
                        picked.append(pools[key].pop()); progressed = True
                if not progressed:
                    if pools[None]:
                        picked.append(pools[None].pop())
                    else:
                        break
            chosen += picked

    if args.dry_run:
        print("transcript-only round types:", sorted(skip))
        print("would export", len(chosen), "of", len(cands), "candidate sessions")
        print("per roundType:", dict(Counter(s[2] for s in chosen)))
        print("labels:", dict(Counter(label[s[0]][1] for s in chosen)))
        print("selection sha:", hashlib.sha256(json.dumps(sorted([s[0], label[s[0]]] for s in chosen)).encode()).hexdigest()[:12])
        return

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, ".gitignore"), "w") as f:
        f.write("*\n")
    for fn in os.listdir(OUT):
        if fn.endswith(".json") or fn == "REVIEW.md":
            os.remove(os.path.join(OUT, fn))

    per_rt = defaultdict(list)
    for s in chosen:
        per_rt[s[2]].append(s)
    mapping, review = {}, []
    stats_rt, stats_label, stats_repl = Counter(), Counter(), Counter()
    for rt in sorted(per_rt):
        lst = sorted(per_rt[rt], key=lambda s: s[0])
        rng.shuffle(lst)
        for n, s in enumerate(lst, 1):
            fid = "%s-%02d" % (rt, n)
            sid, cid, _, _, dur, notes = s
            loc = Counter()
            segs = []
            for spk, ts, tx in db.execute("SELECT speaker, tStart, text FROM transcriptSegment WHERE sessionId=? ORDER BY tStart, id", (sid,)):
                a = anon.run(tx, loc)
                loc["company"] += count_company(anon, a)
                segs.append({"speaker": spk, "tStart": ts, "text": a})
            notes_a = anon.run(notes or "", loc)
            adv, src = label[sid]
            fx = {"id": fid, "source": "real", "roundType": rt, "company": alias[cid],
                  "durationSeconds": dur, "contextNotes": notes_a, "segments": segs,
                  "expected": {"advances": adv, "outcomeSource": src}}
            with open(os.path.join(OUT, fid + ".json"), "w") as f:
                json.dump(fx, f, indent=1)
            mapping[fid] = sid
            stats_rt[rt] += 1
            stats_label[src] += 1
            stats_repl.update(loc)
            review.append((fid, rt, src, dict(loc), [("%s: %s" % (g["speaker"], g["text"])) for g in segs[:40]]))
    with open(os.path.join(OUT, "_mapping.json"), "w") as f:
        json.dump(mapping, f, indent=1)
    with open(os.path.join(OUT, "REVIEW.md"), "w") as f:
        f.write("# Fixture review (PRIVATE, local only)\n\nAnonymization is heuristic. Before running the eval, scan each "
                "transcript below (and the full JSON files) for leaked names, employers, or other identifying details. "
                "Edit or delete any fixture that leaks.\n\n")
        for fid, rt, src, loc, lines in review:
            f.write("## %s\n\n- roundType: %s\n- label: %s\n- replacements: %s\n\n```\n%s\n```\n\n"
                    % (fid, rt, src, json.dumps(loc), "\n".join(lines)))

    print("exported", len(chosen), "of", len(cands), "candidate sessions to", OUT)
    print("per roundType:", dict(stats_rt))
    print("labels:", dict(stats_label))
    print("replacements:", dict(stats_repl))

if __name__ == "__main__":
    main()
