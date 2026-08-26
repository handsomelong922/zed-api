#!/usr/bin/env python3
from pathlib import Path
import sys

path = Path('src/stream.zig')
text = path.read_text(encoding='utf-8')
marker = 'test "completion status failure preserves downstream commit state"'

stub = r'''
fn completionFailureResult(_: bool, kind: accounts.FailureKind, status: u16) StreamResult {
    return .{ .ok = false, .kind = kind, .status = status };
}

test "completion status failure preserves downstream commit state" {
    const before_headers = completionFailureResult(false, .transient, 502);
    try std.testing.expect(!before_headers.committed);
    const after_headers = completionFailureResult(true, .rate_limit, 429);
    try std.testing.expect(after_headers.committed);
    try std.testing.expectEqual(accounts.FailureKind.rate_limit, after_headers.kind);
    try std.testing.expectEqual(@as(u16, 429), after_headers.status);
}
'''

impl = r'''
fn completionFailureResult(headers_sent: bool, kind: accounts.FailureKind, status: u16) StreamResult {
    return .{ .ok = false, .committed = headers_sent, .kind = kind, .status = status };
}

test "completion status failure preserves downstream commit state" {
    const before_headers = completionFailureResult(false, .transient, 502);
    try std.testing.expect(!before_headers.committed);
    const after_headers = completionFailureResult(true, .rate_limit, 429);
    try std.testing.expect(after_headers.committed);
    try std.testing.expectEqual(accounts.FailureKind.rate_limit, after_headers.kind);
    try std.testing.expectEqual(@as(u16, 429), after_headers.status);
}
'''

if len(sys.argv) != 2 or sys.argv[1] not in {'red', 'green'}:
    raise SystemExit('usage: review_fix_committed_status.py red|green')

if sys.argv[1] == 'red':
    if marker not in text:
        text = text.rstrip() + '\n\n' + stub.strip() + '\n'
else:
    if stub.strip() not in text:
        raise SystemExit('RED stub not found')
    text = text.replace(stub.strip(), impl.strip(), 1)
    old = 'return .{ .ok = false, .kind = mapped_kind, .status = mapped_status };'
    new = 'return completionFailureResult(headers_sent, mapped_kind, mapped_status);'
    if text.count(old) != 1:
        raise SystemExit(f'expected one completion failure return, found {text.count(old)}')
    text = text.replace(old, new, 1)

path.write_text(text, encoding='utf-8')
