## Debugging the emulator from your IDE (RA8EMU-1155)

Start the emulator daemon with discovery enabled. It publishes a per-user
RPC address and a loopback GDB port for its loaded session. `ctl` reads that
file; the PWA is a separate client and does not own the emulator process.
The discovery listener is opt-in so independent ordinary `serve` processes
do not compete for the same per-user socket.

```sh
ra8_emulator serve --discover --listen tcp:127.0.0.1:4567 firmware.elf
```

```sh
# what is running
ra8_emulator ctl sessions
ra8_emulator ctl sessions --json

# a ready gdb target for a session (matches port or ELF name/suffix)
ra8_emulator ctl gdb-address
ra8_emulator ctl gdb-address threadx_blink
```

With no discoverable daemon running, both commands ask you to start
`ra8_emulator serve --discover` and exit 1.

### VS Code (cortex-debug)

`.vscode/launch.json` in this repository has two ready configurations.
The `Attach to hosted session (cortex-debug)` one uses the
`external` server type: copy the `target extended-remote 127.0.0.1:PORT`
line `ctl gdb-address` prints into its `target`'s `overrideLaunchCommands`.
The `Attach to hosted session (extended-remote)` one launches a plain
cppdbg-style gdb and is the fallback if the extension is not installed.

### gdb on the command line

```sh
gdb <the session's ELF>
(gdb) target extended-remote 127.0.0.1:PORT   # as ctl gdb-address prints
(gdb) monitor reset halt   # reboot the session from its ELF, stay paused
(gdb) monitor reload       # reload the ELF in place
(gdb) b main
(gdb) c
```

The port serves one client at a time; a second client waits or is
dropped, and run control (continue, step, interrupts) belongs to the
client that holds it. The daemon pumps GDB and RPC connections together. The browser frontend
can remain connected while GDB controls the shared session.

### CLion and Zed

CLion's "Remote Debug (GDB)" run configuration takes the same
`target extended-remote` line. Zed's debugger accepts it as a
`tcpConnection`-style gdb attach. Nothing here is exclusive to VS Code;
the discovery file and `ctl` are the whole interface.
