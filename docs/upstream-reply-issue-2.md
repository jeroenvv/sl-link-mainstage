# Draft reply — fatarsrl/sl-link issue #2

Paste-ready. Trimmed to what is established on hardware; open questions at the end.

---

Thanks — that unblocked us. Master Volume now works from our Lua device script (Apple MainStage, SL88 MK2, firmware 1.1.2).

**What actually fixed it, and what we can't explain.** Our writes were well-formed the whole time (`07 01 <VOL>`, identified + keepalive + logged in). They were simply ignored. They started working when we began issuing a **READ (`07 00`) alongside each write**. With reads in flight, writes take effect and are audible; with writes alone, nothing happens — and the reads go unanswered too. We haven't found this dependency documented anywhere.

**On your questions:**

*Is the documentation misleading on DeviceID / nomenclature?* Mildly, yes — in one specific way. `docs/` describing bytes 5–6 as a single opaque DeviceID regenerated per session is clear once stated, but the `examples/` plugins still use the older static HostID/InstanceID mechanics, so a reader who starts from the reference implementations (as we did) builds the wrong model and only discovers it later. A one-line note in `examples/` saying they are not a current reference for identification would have saved us a lot.

*The full SysEx capture you offered to look at* — we can only give you half of it. Our sniffer watches CoreMIDI **sources**, so it sees device→host but structurally cannot see host→device. We can provide the device→host capture plus our own logged outbound bytes, if that combination is useful.

**Open questions:**

1. **Must a READ accompany a WRITE for the write to be honoured?** That is what we observe, but we'd rather rely on documented behaviour than on a coincidence that happens to work.
2. **What does the READ reply report?** It lags a long way behind: in one capture it returned `vol=29` while we were actively writing 67, and replies arrive only occasionally during a sweep. Is it a sampled/cached value rather than the current setting?
3. **Does the audio board rate-limit closely-spaced writes?** We currently send one write per encoder tick (~30/s). Every value goes out on the wire in order, but the audible change is uneven. Is there a recommended minimum interval between Master Volume writes?
4. **What does `IDENTIFICATION REJECTED` reason `00` mean beyond "id taken"?** We see it for a freshly generated DeviceID that has never been used in the session — it is then approved on a later retry with the same id. That doesn't fit "already in use".

---

## Notes for us (not for the issue)

- Deliberately **not** claimed: that login is required. We concluded that at one point and it was a false positive — a probe run had inherited the keyboard's app selection from a previous run. Unresolved on our side, so it stays out.
- Deliberately not raised: the identification approval/rejection frames being lost before MainStage starts delivering inbound MIDI. That is a MainStage host issue, not a protocol one.
- Question 3 is the one whose answer would most change our code: a documented minimum interval turns the uneven-stepping defect into a one-line cadence limit.
