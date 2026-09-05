# AutoVPN Knowledge Base

Reference documentation for the AutoVPN automation layer that drives the VMware
SSL VPN-Plus Client (`SVPClient.exe`) on Windows.

Everything here describes the code as it exists in
[`AutoVPN.ps1`](../AutoVPN.ps1) at version 2.0. Line references point at that
file. Where a document states a limitation of the VMware client rather than of
this project, it says so explicitly.

## Index

| Document | What it covers |
|---|---|
| [01-architecture.md](01-architecture.md) | How the application is put together: regions, threading model, state, files on disk |
| [02-connect-flow.md](02-connect-flow.md) | The seven-step connect sequence and the disconnect sequence, step by step |
| [03-win32-reference.md](03-win32-reference.md) | Every P/Invoke, message constant, and SVPClient dialog control ID the project depends on |
| [04-background-service.md](04-background-service.md) | Why the automation stalls when you click elsewhere, which background models are viable, and which are not |
| [05-troubleshooting.md](05-troubleshooting.md) | Observed failure modes, how to recognise them in the log, and what to do |
| [06-data-reference.md](06-data-reference.md) | `config.json` fields, credential storage format, DPAPI scope, and file locations |

## Quick orientation

AutoVPN does **not** replace the VMware client. It launches `SVPClient.exe`,
locates its dialogs by window title, and drives them by posting Win32 messages
directly to control handles. There is no mouse movement and no `SendKeys`
anywhere in the codebase — see [03-win32-reference.md](03-win32-reference.md).

The most common question this knowledge base answers:

> Why does the automation sometimes stop partway through when I click something?

It used to, and the cause was structural: the connect sequence ran on the
Windows Forms UI thread and pumped the message loop while waiting, so any click
re-entered it. The sequence now runs on a worker thread and the entry points that
could re-enter it are gated. The mechanism, the fix, and the options that were
ruled out are in [04-background-service.md](04-background-service.md).
