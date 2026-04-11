/**
 * SSE block parser for Chump /api/chat (Axum). Loaded before the main inline bundle.
 * Keep in sync with any logic changes — also exercised by web/ui-selftests.js and CI.
 */
(function (root) {
  'use strict';
  function createSseBlockParser(onParsedEvent) {
    var carry = '';
    var blockEvent = '';
    var blockDataLines = [];
    function flushBlock() {
      if (!blockEvent && blockDataLines.length === 0) return;
      var dataStr = blockDataLines.join('\n');
      var ev = blockEvent;
      if (!ev && dataStr) {
        try {
          var peek = JSON.parse(dataStr);
          if (peek && typeof peek.type === 'string') ev = peek.type;
        } catch (_) {}
      }
      if (ev && dataStr) {
        try {
          onParsedEvent({ event: ev, data: JSON.parse(dataStr) });
        } catch (_) {}
      }
      blockEvent = '';
      blockDataLines = [];
    }
    function handlePhysicalLine(raw) {
      var line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
      if (line === '') {
        flushBlock();
        return;
      }
      if (line.startsWith('event:')) {
        if (blockEvent || blockDataLines.length) flushBlock();
        blockEvent = line.slice(6).trim();
      } else if (line.startsWith('data:')) {
        blockDataLines.push(line.slice(5).trimStart());
      }
    }
    return {
      push: function (chunk) {
        carry += String(chunk).replace(/\r\n/g, '\n').replace(/\r/g, '\n');
        while (true) {
          var i = carry.indexOf('\n');
          if (i === -1) break;
          var ln = carry.slice(0, i);
          carry = carry.slice(i + 1);
          handlePhysicalLine(ln);
        }
      },
      finish: function () {
        if (carry.length) {
          handlePhysicalLine(carry);
          carry = '';
        }
        flushBlock();
      },
    };
  }

  root.createSseBlockParser = createSseBlockParser;
  if (typeof module !== 'undefined' && module.exports) {
    module.exports.createSseBlockParser = createSseBlockParser;
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
