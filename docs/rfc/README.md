# The RFCs tcp.zig transcribes

Verbatim copies from https://www.rfc-editor.org/rfc/, so the literate
`tcp*.zig` files quote them from the repo. The IETF Trust permits copying an
RFC in full.

- `rfc9293.txt`: TCP (§3.10, Event Processing, is what the files follow).
- `rfc6298.txt`: the retransmission timer (§5.4: resend the oldest segment).
- `rfc5681.txt`: congestion control, fast retransmit.
- `rfc6056.txt`: choosing ephemeral ports.

A quote in the code is copied from these files word for word, never from
memory, and `src/tcp_test.zig` fails on one that is not.
