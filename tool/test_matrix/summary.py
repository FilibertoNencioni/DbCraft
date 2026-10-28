"""Aggregates build/matrix/**/results.jsonl into a case x target matrix.

For each (case, target) the most recent results file wins; inside it the
worst outcome counts (defect > limited > ok > not applicable), so a case
marked "limited" and then "ok" stays limited. Sub-results ("CASE/detail")
roll up into CASE for the multi-part cases (SQL-16, CMP-02, DCM-02, XFR-04, GRD-10, CON-03, CON-13);
other sub-results and D-xxx/FRAMEWORK/ABORT markers are skipped.
Usage: python3 -I tool/test_matrix/summary.py build/matrix
"""
import json
import pathlib
import sys

ROLLUP = ('SQL-16/', 'CMP-02/', 'DCM-02/', 'XFR-04/', 'GRD-10/', 'CON-03/', 'CON-13/')
RANK = {'defect': 4, 'limited': 3, 'notRun': 2, 'ok': 1, 'notApplicable': 0}
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'build/matrix')
best = {}  # (case, target) -> (file mtime, outcome)
for f in root.rglob('results.jsonl'):
    mt = f.stat().st_mtime
    per = {}
    for line in f.read_text().splitlines():
        try:
            j = json.loads(line)
        except ValueError:
            continue
        c = j['case']
        if c.startswith(ROLLUP) and c.count('/') == 1:
            c = c.split('/')[0]
        elif '/' in c or c.startswith(('D-', 'FRAMEWORK', 'ABORT', 'GUARD')):
            continue
        k = (c, j['target'])
        if k not in per or RANK[j['outcome']] > RANK[per[k]]:
            per[k] = j['outcome']
    for k, o in per.items():
        if k not in best or mt > best[k][0]:
            best[k] = (mt, o)
targets = [t for t in ['sqlite', 'pg', 'mssql', 'mysql', 'mariadb', 'mongo', 'redis', 'cassandra', 's3', 'azure', 'cross', 'app', 'drivers']
           if any(k[1] == t for k in best)]
cases = sorted({k[0] for k in best}, key=lambda c: (c.split('-')[0], c))
sym = {'ok': '✅', 'defect': '❌', 'limited': '⚠️', 'notApplicable': '➖', 'notRun': '⏸'}
print('| Caso | ' + ' | '.join(targets) + ' |')
print('|---|' + '---|' * len(targets))
for c in cases:
    print(f'| {c} | ' + ' | '.join(sym.get(best.get((c, t), (0, ''))[1], '') for t in targets) + ' |')
