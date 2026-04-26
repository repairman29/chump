/**
 * Client-side UI self-tests (SSE framing, etc.). Requires global createSseBlockParser from sse-event-parser.js.
 * Run from Settings, or: node ../scripts/ci/run-web-ui-selftests.cjs
 */
(function (root) {
  'use strict';

  function assert(cond, msg, lines, failedRef) {
    if (cond) lines.push('ok: ' + msg);
    else {
      failedRef.n += 1;
      lines.push('FAIL: ' + msg);
    }
  }

  function runChumpUiSelfTests() {
    var lines = [];
    var failedRef = { n: 0 };
    var factory = root.createSseBlockParser;
    if (typeof factory !== 'function') {
      return { ok: false, failed: 1, lines: ['FAIL: createSseBlockParser is not a function (load /sse-event-parser.js first)'] };
    }

    var evs;

    evs = [];
    var p1 = factory(function (e) {
      evs.push(e);
    });
    p1.push(
      'event: web_session_ready\ndata: {"type":"web_session_ready","session_id":"s1"}\nevent: text_complete\ndata: {"type":"text_complete","text":"hi"}\n'
    );
    p1.finish();
    assert(evs.length === 2, 'two events when only single newlines between frames', lines, failedRef);
    assert(
      evs[0] && evs[0].event === 'web_session_ready' && evs[0].data && evs[0].data.session_id === 's1',
      'first event is web_session_ready',
      lines,
      failedRef
    );
    assert(
      evs[1] && evs[1].event === 'text_complete' && evs[1].data && evs[1].data.text === 'hi',
      'second event is text_complete with text',
      lines,
      failedRef
    );

    evs = [];
    var p2 = factory(function (e) {
      evs.push(e);
    });
    p2.push(
      'event: turn_complete\ndata: {"type":"turn_complete","request_id":"r","full_text":"done","duration_ms":0,"tool_calls_count":0,"model_calls_count":1}'
    );
    p2.finish();
    assert(evs.length === 1, 'finish() flushes final frame without trailing newline', lines, failedRef);
    assert(
      evs[0] && evs[0].data && evs[0].data.full_text === 'done',
      'turn_complete full_text preserved',
      lines,
      failedRef
    );

    evs = [];
    var p3 = factory(function (e) {
      evs.push(e);
    });
    p3.push(
      'event: turn_error\ndata: {"type":"turn_error","request_id":"","error":"bad"}\n\nevent: thinking\ndata: {"type":"thinking","elapsed_ms":5}\n\n'
    );
    p3.finish();
    assert(evs.length === 2, 'classic blank-line delimited blocks', lines, failedRef);
    assert(evs[0].event === 'turn_error', 'turn_error first', lines, failedRef);
    assert(evs[1].event === 'thinking', 'thinking second', lines, failedRef);

    evs = [];
    var p4 = factory(function (e) {
      evs.push(e);
    });
    p4.push('data: {"type":"turn_error","request_id":"","error":"orphan"}\n');
    p4.finish();
    assert(evs.length === 1 && evs[0].event === 'turn_error', 'infer event name from JSON type when event: line missing', lines, failedRef);

    evs = [];
    var p5 = factory(function (e) {
      evs.push(e);
    });
    p5.push(
      'event: tool_approval_request\ndata: {"type":"tool_approval_request","request_id":"rid1","tool_name":"run_cli","tool_input":{"cmd":"echo"},"risk_level":"high","reason":"shell","expires_at_secs":999}\n'
    );
    p5.finish();
    assert(evs.length === 1, 'single tool_approval_request frame', lines, failedRef);
    assert(
      evs[0] && evs[0].event === 'tool_approval_request' && evs[0].data && evs[0].data.request_id === 'rid1',
      'tool_approval_request parses request_id',
      lines,
      failedRef
    );

    return { ok: failedRef.n === 0, failed: failedRef.n, lines: lines };
  }

  root.runChumpUiSelfTests = runChumpUiSelfTests;
  if (typeof module !== 'undefined' && module.exports) {
    module.exports.runChumpUiSelfTests = runChumpUiSelfTests;
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
