import 'dart:convert';

import 'package:dbcraft/features/ai/ai_context.dart';
import 'package:dbcraft/features/ai/claude_client.dart';
import 'package:dbcraft/features/ai/markdown_view.dart';
import 'package:dbcraft/model/db_objects.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String sse(String event, Map<String, Object?> data) => 'event: $event\ndata: ${jsonEncode(data)}\n\n';

String sampleStream({String stop = 'end_turn', Map<String, Object?>? stopDetails}) => [
  sse('message_start', {
    'type': 'message_start',
    'message': {
      'id': 'msg_1',
      'model': 'claude-opus-5-5',
      'usage': {'input_tokens': 10, 'cache_read_input_tokens': 5, 'output_tokens': 1},
    },
  }),
  sse('content_block_start', {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''},
  }),
  sse('content_block_delta', {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'thinking_delta', 'thinking': 'hmm'},
  }),
  sse('content_block_delta', {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'signature_delta', 'signature': 'sig'},
  }),
  sse('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
  'event: ping\ndata: {"type": "ping"}\n\n',
  sse('content_block_start', {
    'type': 'content_block_start',
    'index': 1,
    'content_block': {'type': 'text', 'text': ''},
  }),
  sse('content_block_delta', {
    'type': 'content_block_delta',
    'index': 1,
    'delta': {'type': 'text_delta', 'text': 'Ciao è '},
  }),
  sse('content_block_delta', {
    'type': 'content_block_delta',
    'index': 1,
    'delta': {'type': 'text_delta', 'text': 'mondo '},
  }),
  sse('content_block_stop', {'type': 'content_block_stop', 'index': 1}),
  sse('message_delta', {
    'type': 'message_delta',
    'delta': {'stop_reason': stop, 'stop_details': ?stopDetails},
    'usage': {'output_tokens': 42},
  }),
  sse('message_stop', {'type': 'message_stop'}),
].join();

void main() {
  group('SSE parser', () {
    test('handles arbitrary chunk boundaries and CRLF', () {
      final text = sampleStream().replaceAll('\n', '\r\n');
      for (final size in [1, 2, 3, 7, 50, text.length]) {
        final parser = SseParser();
        final events = <SseEvent>[];
        for (var i = 0; i < text.length; i += size) {
          events.addAll(parser.add(text.substring(i, i + size > text.length ? text.length : i + size)));
        }
        events.addAll(parser.close());
        expect(events.map((e) => e.event).toList(), [
          'message_start',
          'content_block_start',
          'content_block_delta',
          'content_block_delta',
          'content_block_stop',
          'ping',
          'content_block_start',
          'content_block_delta',
          'content_block_delta',
          'content_block_stop',
          'message_delta',
          'message_stop',
        ], reason: 'chunk size $size');
      }
    });

    test('joins multi-line data, ignores comments, flushes on close', () {
      final parser = SseParser();
      final events = parser.add(': keep-alive\nevent: x\ndata: a\ndata: b\n\ndata: tail');
      expect(events.single.event, 'x');
      expect(events.single.data, 'a\nb');
      final last = parser.close();
      expect(last.single.event, 'message');
      expect(last.single.data, 'tail');
    });
  });

  group('response accumulation', () {
    AiResponse parse(String stream) {
      final r = AiResponse();
      for (final e in [...SseParser().add(stream)]) {
        r.apply(e);
      }
      return r;
    }

    test('text deltas, usage and replay content', () {
      final r = parse(sampleStream());
      expect(r.text, 'Ciao è mondo ');
      expect(r.stopReason, 'end_turn');
      expect(r.outputTokens, 42);
      expect(r.cacheReadTokens, 5);
      expect(r.notice, isNull);
      final replay = r.replayContent();
      expect(replay.first['type'], 'thinking');
      expect(replay.first['thinking'], 'hmm');
      expect(replay.first['signature'], 'sig');
      expect(replay.last['text'], 'Ciao è mondo', reason: 'trailing whitespace trimmed');
    });

    test('refusal and max_tokens are reported', () {
      final refused = parse(sampleStream(stop: 'refusal', stopDetails: {'type': 'refusal', 'category': 'cyber'}));
      expect(refused.refused, isTrue);
      expect(refused.refusalCategory, 'cyber');
      expect(refused.notice, contains('cyber'));
      final cut = parse(sampleStream(stop: 'max_tokens'));
      expect(cut.truncated, isTrue);
      expect(cut.notice, contains('troncata'));
    });

    test('error event throws an Italian AiException', () {
      final r = AiResponse();
      expect(
        () => r.apply(const SseEvent('error', '{"type":"error","error":{"type":"overloaded_error","message":"x"}}')),
        throwsA(
          isA<AiException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.message, 'message', contains('sovraccarico')),
        ),
      );
    });

    test('fallback block drops earlier model-internal blocks on replay', () {
      final r = AiResponse()
        ..applyMessage({
          'model': 'claude-opus-4-8',
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'thinking', 'thinking': '', 'signature': 's'},
            {'type': 'text', 'text': 'parte '},
            {
              'type': 'fallback',
              'from': {'model': 'claude-opus-5-5'},
              'to': {'model': 'claude-opus-4-8'},
            },
            {'type': 'text', 'text': 'fine'},
          ],
        });
      expect(r.fallbackUsed, isTrue);
      expect(r.replayContent().map((b) => b['type']).toList(), ['text', 'text']);
    });
  });

  group('request building', () {
    const cfg = AiConfig(apiKey: 'k', model: 'claude-opus-5-5', effort: 'high');

    test('no forbidden parameters', () {
      final body = buildRequestBody(cfg, AiRequest.single(const [AiSystemBlock('s', cache: true)], 'q'));
      for (final k in ['thinking', 'temperature', 'top_p', 'top_k', 'budget_tokens']) {
        expect(body.containsKey(k), isFalse, reason: k);
      }
      expect(jsonEncode(body).contains('budget_tokens'), isFalse);
      expect(body['max_tokens'], 64000);
      expect(body['stream'], isTrue);
      expect(body['output_config'], {'effort': 'high'});
      final sys = body['system'] as List;
      expect((sys.last as Map)['cache_control'], {'type': 'ephemeral'});
      final msgs = body['messages'] as List;
      expect((msgs.last as Map)['role'], 'user', reason: 'never an assistant prefill');
    });

    test('non-streaming uses 16000 tokens', () {
      final body = buildRequestBody(cfg, AiRequest.single(const [], 'q', stream: false));
      expect(body['max_tokens'], 16000);
      expect(body.containsKey('stream'), isFalse);
    });

    test('fallbacks only on the default host and supported models', () {
      final h = buildRequestHeaders(cfg);
      expect(h['anthropic-beta'], 'server-side-fallback-2026-07-01');
      expect(h['anthropic-version'], '2023-06-01');
      expect(h['x-api-key'], 'k');
      expect(buildRequestBody(cfg, AiRequest.single(const [], 'q'))['fallbacks'], 'default');

      const proxy = AiConfig(apiKey: 'k', baseUrl: 'https://llm.example.com/anthropic');
      expect(buildRequestHeaders(proxy).containsKey('anthropic-beta'), isFalse);
      expect(buildRequestBody(proxy, AiRequest.single(const [], 'q')).containsKey('fallbacks'), isFalse);

      const haiku = AiConfig(apiKey: 'k', model: 'claude-haiku-5-5');
      expect(haiku.useFallbacks, isFalse);
      const off = AiConfig(apiKey: 'k', fallbacks: false);
      expect(off.useFallbacks, isFalse);
      expect(const AiConfig(apiKey: 'k', model: 'claude-sonnet-5-5').useFallbacks, isTrue);
    });

    test('base url normalization', () {
      expect(
        const AiConfig(apiKey: 'k', baseUrl: 'https://api.anthropic.com/').messagesUri.toString(),
        'https://api.anthropic.com/v1/messages',
      );
    });
  });

  group('client', () {
    test('streams text and retries on 529', () async {
      var calls = 0;
      final client = ClaudeClient(
        const AiConfig(apiKey: 'k'),
        clientFactory: () => MockClient.streaming((req, body) async {
          calls++;
          final sent = jsonDecode(await body.bytesToString()) as Map;
          expect(sent['model'], 'claude-opus-5-5');
          if (calls == 1) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('{"type":"error","error":{"type":"overloaded_error","message":"busy"}}')),
              529,
              headers: {'retry-after': '0'},
            );
          }
          final bytes = utf8.encode(sampleStream());
          return http.StreamedResponse(Stream.fromIterable([bytes.sublist(0, 33), bytes.sublist(33)]), 200);
        }),
      );
      final seen = <String>[];
      final r = await client.send(AiRequest.single(const [], 'q'), onText: seen.add);
      expect(calls, 2);
      expect(r.text, 'Ciao è mondo ');
      expect(seen.last, 'Ciao è mondo ');
    });

    test('401 maps to an Italian message without retry', () async {
      var calls = 0;
      final client = ClaudeClient(
        const AiConfig(apiKey: 'bad'),
        clientFactory: () => MockClient((req) async {
          calls++;
          return http.Response(
            '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}',
            401,
          );
        }),
      );
      await expectLater(
        client.send(AiRequest.single(const [], 'q')),
        throwsA(isA<AiException>().having((e) => e.message, 'message', contains('Chiave API non valida'))),
      );
      expect(calls, 1);
    });
  });

  group('context', () {
    test('schema summary is capped', () {
      final tables = [
        for (var i = 0; i < 200; i++)
          AiTableSummary('t$i', columns: [for (var j = 0; j < 50; j++) AiColumnSummary('c$j', 'INT', pk: j == 0)]),
      ];
      final text = renderSchemaSummary(tables, maxTables: 150, maxColumns: 40, maxChars: 1000000);
      expect('\n'.allMatches(text).length, 150);
      expect(text, contains('… (+10 colonne)'));
      expect(text, contains('altre 50 tabelle omesse'));
      expect(text, contains('c0 INT PK'));
      final small = renderSchemaSummary(tables, maxChars: 2000);
      expect(small.length, lessThan(2200));
      expect(small, contains('tabelle omesse'));
    });

    test('column rendering with FK and NOT NULL', () {
      expect(
        const AiColumnSummary('customer_id', 'INTEGER', nullable: false, ref: 'customers.id').render(),
        'customer_id INTEGER FK→customers.id NOT NULL',
      );
    });

    test('referenced tables from identifiers', () {
      DbTable t(String n) => DbTable(catalog: null, schema: 'public', name: n, type: 'TABLE');
      final all = [t('orders'), t('Customers'), t('products'), t('order items')];
      final refs = referencedTables(
        'select * from public.orders o join "Customers" c on c.id = o.cid -- products\n'
        "where o.note = 'products' and exists (select 1 from [order items])",
        all,
      );
      expect(refs.map((e) => e.name), ['orders', 'Customers', 'order items']);
    });

    test('query language per family', () {
      expect(queryLanguage(DbFamily.mongodb).$2, 'javascript');
      expect(queryLanguage(DbFamily.redis).$1, contains('Redis'));
      expect(queryLanguage(DbFamily.postgres).$1, contains('PostgreSQL'));
    });

    test('system blocks put the cache breakpoint last', () {
      final sys = buildSystem(AiTask.fixQuery, AiDbContext(family: DbFamily.postgres, schemaText: '- t: a INT'));
      expect(sys.first.cache, isFalse);
      expect(sys.last.cache, isTrue);
      expect(sys.last.text, contains('- t: a INT'));
    });
  });

  group('answers', () {
    const answer = 'La colonna non esiste.\n\n```sql\nSELECT id\nFROM t\n```\n\nAltro:\n```text\nnope\n```';

    test('code block extraction', () {
      final blocks = extractCodeBlocks(answer);
      expect(blocks.length, 2);
      expect(blocks.first.language, 'sql');
      expect(blocks.first.code, 'SELECT id\nFROM t');
      expect(pickQuery(answer), 'SELECT id\nFROM t');
      expect(pickQuery('```\nselect 1\n```'), 'select 1');
      expect(pickQuery('nessun codice'), isNull);
      expect(extractCodeBlocks('```sql\nselect 1').single.code, 'select 1', reason: 'streaming');
      expect(stripCodeBlocks(answer), 'La colonna non esiste.\n\nAltro:');
    });

    test('line diff', () {
      final d = diffLines('select a\nfrom t\nwhere x', 'select a\nfrom t2\nwhere x');
      expect(d.map((l) => l.kind).toList(), [DiffKind.same, DiffKind.removed, DiffKind.added, DiffKind.same]);
    });
  });

  group('markdown', () {
    test('blocks', () {
      final blocks = parseMarkdown('''
## Come funziona

Prima riga
continua.

- uno
  - due
1. primo

```sql
select 1
```

| a | b |
|---|---|
| 1 | x\\|y |

> nota
---
''');
      expect(blocks[0], isA<MdHeading>().having((h) => h.level, 'level', 2));
      expect((blocks[1] as MdParagraph).text, 'Prima riga continua.');
      final list = blocks[2] as MdList;
      expect(list.items.map((e) => e.indent), [0, 1, 0]);
      expect(list.items.last.number, '1');
      expect(
        blocks[3],
        isA<MdCode>().having((c) => c.code, 'code', 'select 1').having((c) => c.closed, 'closed', true),
      );
      final table = blocks[4] as MdTable;
      expect(table.header, ['a', 'b']);
      expect(table.rows.single, ['1', 'x|y']);
      expect((blocks[5] as MdQuote).text, 'nota');
      expect(blocks[6], isA<MdRule>());
    });

    test('unterminated code block while streaming', () {
      final b = parseMarkdown('Testo\n```sql\nselect');
      expect((b.last as MdCode).closed, isFalse);
    });

    test('inline spans keep snake_case identifiers', () {
      final s = parseInline('Usa **customer_id** e `order_date`, _corsivo_ non snake_case');
      expect(s.where((e) => e.bold).map((e) => e.text).join(), 'customer_id');
      expect(s.where((e) => e.code).single.text, 'order_date');
      expect(s.where((e) => e.italic).single.text, 'corsivo');
      expect(s.map((e) => e.text).join(), contains('snake_case'));
    });
  });
}
