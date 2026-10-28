// Test matrix dataset for MongoDB (docs/test-plan.md §3.3).
const neg = db.getSiblingDB('negozio');
neg.dropDatabase();
neg.clienti.insertMany([
  { _id: 1, nome: 'Mario Rossi', email: 'mario@esempio.it', citta: 'Forlì', tag: ['vip', 'nord'], indirizzo: { via: 'Via Roma 1', cap: '47121' } },
  { _id: 2, nome: 'Anna Bianchi', email: 'anna@esempio.it', citta: 'Città di Castello', tag: [], indirizzo: null },
  { _id: 3, nome: '東京 太郎', email: null, citta: '東京', tag: ['estero'], note: 'emoji 😀👍🏽' },
]);
const stati = ['nuovo', 'pagato', 'spedito', 'annullato'];
const ordini = [];
for (let i = 1; i <= 10000; i++) {
  ordini.push({
    numero: i, cliente_id: (i % 3) + 1, stato: stati[i % 4], totale: NumberDecimal(((i * 7919) % 100000 / 100).toFixed(2)),
    data: new Date(Date.UTC(2024, 0, 1) + i * 3600000), righe: [{ articolo: 'A' + (i % 50), qta: (i % 5) + 1 }, { articolo: 'B' + (i % 20), qta: 1 }],
  });
}
neg.ordini.insertMany(ordini);
neg.ordini.createIndex({ cliente_id: 1, data: -1 }, { name: 'ix_cliente_data' });
neg.tipi.insertMany([
  { _id: 'tutti', double: 3.14159, int32: NumberInt(42), int64: NumberLong('9223372036854775807'), dec: NumberDecimal('1234567890.0123456789'),
    bool: true, data: new Date('2024-02-29T23:59:59.123Z'), nullo: null, oid: ObjectId('65a1b2c3d4e5f60718293a4b'),
    bin: BinData(0, 'AP8QqwE='), uuid: UUID('0b5f6c1e-7d4a-4c3e-9b1a-2f6e8d9c0a11'), regex: /^abc/i, ts: Timestamp({ t: 1700000000, i: 1 }),
    arr: [1, 'due', { tre: 3 }], obj: { a: { b: { c: [1, 2] } } }, minKey: MinKey(), maxKey: MaxKey(), testo: 'accenti àèé — 漢字 — 😀' },
]);
const grande = [];
for (let i = 1; i <= 100000; i++) grande.push({ _id: i, gruppo: i % 100, testo: 'riga ' + i });
neg.grande.insertMany(grande);
neg.createView('v_ordini_pagati', 'ordini', [{ $match: { stato: 'pagato' } }, { $project: { numero: 1, totale: 1 } }]);
print('ok', neg.ordini.countDocuments(), neg.grande.countDocuments());
