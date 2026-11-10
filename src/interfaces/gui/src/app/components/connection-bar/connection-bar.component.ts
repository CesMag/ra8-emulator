import { Component, ElementRef, ViewChild, inject, computed, signal, effect } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';
import { Core } from 'ra8-rpc-client';

@Component({
  selector: 'app-connection-bar',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <header class="xcode-toolbar">
      <!-- Left: App Identity, Connection Status, & Load ELF -->
      <div class="toolbar-section toolbar-left">
        <div class="app-identity">
          <div class="app-icon">RA8</div>
          <div class="app-titles">
            <span class="app-name">RA8 Workbench</span>
            <span class="target-chip">EK-RA8D2</span>
          </div>
        </div>

        <!-- Connection Pill & Popover -->
        <div class="popover-anchor">
          <button
            type="button"
            class="conn-pill-btn"
            [class.connected]="isConnected()"
            [class.connecting]="isConnecting()"
            (click)="toggleSettingsPopover()"
            title="Configure Emulator WebSocket Endpoint"
          >
            <span class="status-dot" [class.online]="isConnected()" [class.busy]="isConnecting()"></span>
            <span class="conn-text">{{ isConnected() ? 'Online' : isConnecting() ? 'Connecting…' : 'Offline' }}</span>
          </button>

          <div *ngIf="showSettings()" class="xcode-popover settings-popover">
            <div class="popover-header">
              <span>Emulator WebSocket</span>
              <button type="button" class="close-btn" (click)="showSettings.set(false)">✕</button>
            </div>
            <div class="popover-body">
              <label class="input-label" for="ws-url-input">Server Endpoint</label>
              <div class="input-row">
                <input
                  id="ws-url-input"
                  type="text"
                  class="xcode-input"
                  [ngModel]="urlInput()"
                  (ngModelChange)="urlInput.set($event)"
                  placeholder="ws://127.0.0.1:4567"
                  (keydown.enter)="applyConnection()"
                />
                <button
                  type="button"
                  class="xcode-btn primary-solid"
                  [class.destructive]="isConnected()"
                  (click)="applyConnection()"
                >
                  {{ isConnected() ? 'Disconnect' : 'Connect' }}
                </button>
              </div>
              <div *ngIf="!isConnected()" class="cmd-help">
                <div class="cmd-label">Start local backend (auto-connects in 3s):</div>
                <code class="cmd-code" (click)="copyLaunchCommand()">{{ launchCommand() }}</code>
                <span class="copy-hint">{{ copied() ? 'Copied to clipboard' : 'Click command to copy' }}</span>
              </div>
            </div>
          </div>
        </div>

        <!-- Load ELF Firmware Button & Popover -->
        <div class="popover-anchor">
          <input
            #elfFileInput
            type="file"
            accept=".elf,.axf,.out,application/x-executable,application/octet-stream"
            class="sr-file-input"
            (change)="onFilePicked($event)"
          />
          <button
            type="button"
            class="load-elf-btn"
            [class.loaded]="!!emu.cpu0ElfName()"
            (click)="toggleLoadPopover()"
            title="Upload ARM32 .elf firmware image into emulator (Ctrl/Cmd+O)"
          >
            <span class="load-icon">↑</span>
            <span class="load-label">{{ emu.cpu0ElfName() || 'Load ELF…' }}</span>
          </button>

          <div *ngIf="showLoadPopover()" class="xcode-popover load-popover">
            <div class="popover-header">
              <span>Load Firmware (.elf)</span>
              <button type="button" class="close-btn" (click)="showLoadPopover.set(false)">✕</button>
            </div>
            <div class="popover-body">
              <div class="field-group">
                <span class="input-label">Target Silicon Core</span>
                <div class="core-seg">
                  <button
                    type="button"
                    class="core-seg-btn"
                    [class.active]="uploadCore() === Core.Cpu0"
                    (click)="uploadCore.set(Core.Cpu0)"
                  >
                    CPU0 • Cortex-M85
                  </button>
                  <button
                    type="button"
                    class="core-seg-btn"
                    [class.active]="uploadCore() === Core.Cpu1"
                    (click)="uploadCore.set(Core.Cpu1)"
                  >
                    CPU1 • Cortex-M33
                  </button>
                </div>
                <div *ngIf="uploadCore() === Core.Cpu1 && !cpu1Attached()" class="warn-note">
                  CPU1 is clock-gated. Start server with <code>--cpu1 m33.elf</code> to attach both cores.
                </div>
              </div>

              <label class="check-row">
                <input
                  type="checkbox"
                  [ngModel]="breakAtMain()"
                  (ngModelChange)="breakAtMain.set($event)"
                />
                <div class="check-copy">
                  <span class="check-title">Break at <code>main()</code> &amp; Run</span>
                  <span class="check-sub">Executes Reset_Handler startup and halts cleanly at main</span>
                </div>
              </label>

              <button
                type="button"
                class="choose-elf-cta"
                [disabled]="!isConnected() || !!emu.uploadProgress()?.active"
                (click)="triggerBrowserFilePicker()"
              >
                {{ isConnected() ? 'Choose .elf Firmware File…' : 'Connect Backend First to Load .elf' }}
              </button>

              <div *ngIf="emu.uploadProgress() as prog" class="upload-progress-box">
                <div class="prog-row font-mono">
                  <span>{{ prog.statusText }}</span>
                  <span>{{ prog.percent }}%</span>
                </div>
                <div class="prog-track">
                  <div class="prog-fill" [style.width.%]="prog.percent"></div>
                </div>
              </div>

              <div *ngIf="emu.cpu0ElfName() || emu.cpu1ElfName()" class="loaded-summary font-mono">
                <div *ngIf="emu.cpu0ElfName()">
                  CPU0: {{ emu.cpu0ElfName() }} ({{ emu.cpu0ElfSymbols().length }} syms)
                </div>
                <div *ngIf="emu.cpu1ElfName()">
                  CPU1: {{ emu.cpu1ElfName() }} ({{ emu.cpu1ElfSymbols().length }} syms)
                </div>
              </div>

              <div class="drop-tip">
                Tip: Drag &amp; drop any <code>.elf</code> file anywhere onto the workbench window.
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Center: Iconic Xcode Activity HUD -->
      <div class="toolbar-section toolbar-center">
        <div class="activity-hud" [class.offline]="!isConnected()" [class.running]="isRunning()">
          <ng-container *ngIf="isConnected()">
            <div class="hud-item core-m85">
              <span class="hud-core-label">M85</span>
              <span class="hud-value font-mono">0x{{ toHex8(emu.cpu0Pc()) }}</span>
              <span *ngIf="cpu0SourceShort()" class="hud-src font-mono" [title]="cpu0SourceFull()">
                {{ cpu0SourceShort() }}
              </span>
              <span *ngIf="!cpu0SourceShort()" class="hud-sub">{{ emu.cpu0StateLabel() }}</span>
            </div>

            <span class="hud-divider"></span>

            <div class="hud-item core-m33" [class.dimmed]="!cpu1Attached()">
              <span class="hud-core-label">M33</span>
              <span class="hud-value font-mono" *ngIf="cpu1Attached()">0x{{ toHex8(emu.cpu1Pc()) }}</span>
              <span class="hud-sub">{{ emu.cpu1StateLabel() }}</span>
            </div>

            <span class="hud-divider"></span>

            <button
              type="button"
              class="hud-item hud-meta-btn"
              [class.slow]="isSlowPacing()"
              (click)="openDiagnostics()"
              title="Virtual time & host pacing ratio — click to open System Diagnostics"
            >
              <span class="hud-value font-mono">{{ formattedCycles() }}</span>
              <span class="hud-sub font-mono pacing-pill" [class.slow]="isSlowPacing()">{{ pacingText() }}</span>
            </button>
          </ng-container>

          <ng-container *ngIf="!isConnected()">
            <div class="hud-offline-wrap" (click)="copyLaunchCommand()">
              <span class="status-dot"></span>
              <span class="offline-headline">Waiting for Local Emulator</span>
              <span class="offline-sub">• Click to copy startup command</span>
            </div>
          </ng-container>
        </div>
      </div>

      <!-- Right: Debugger Stepping Transport & Workbench Utilities -->
      <div class="toolbar-section toolbar-right">
        <div class="transport-segment">
          <button
            type="button"
            class="xcode-btn play-btn"
            [class.active]="isRunning()"
            [disabled]="!isConnected()"
            (click)="toggleRun()"
            [title]="isRunning() ? 'Pause Execution (F5)' : 'Run Continuously (F5)'"
          >
            {{ isRunning() ? '⏸ Pause' : '▶ Run' }}
          </button>

          <button
            type="button"
            class="xcode-btn"
            [disabled]="!isConnected() || isRunning()"
            (click)="stepOver()"
            title="Step Over Function Call (F10)"
          >
            Over
          </button>

          <button
            type="button"
            class="xcode-btn"
            [disabled]="!isConnected() || isRunning()"
            (click)="stepInto()"
            title="Step Into Instruction (F11)"
          >
            Into
          </button>

          <button
            type="button"
            class="xcode-btn"
            [disabled]="!isConnected() || isRunning()"
            (click)="stepOut()"
            title="Step Out of Current Function (Shift+F11)"
          >
            Out
          </button>

          <button
            type="button"
            class="xcode-btn font-mono"
            [disabled]="!isConnected() || isRunning()"
            (click)="advance1ms()"
            title="Advance Virtual Time Deterministically by +1 ms (480k M85 cycles)"
          >
            +1ms
          </button>

          <button
            type="button"
            class="xcode-btn"
            [disabled]="!isConnected()"
            (click)="reset()"
            title="Reset Session to Entry Vector / t=0"
          >
            ↺
          </button>
        </div>

        <div class="v-sep"></div>

        <!-- Timeline DAG Drawer Toggle -->
        <button
          type="button"
          class="xcode-btn"
          [class.active]="dagOpen()"
          (click)="toggleDag()"
          title="Toggle Time-Travel Execution DAG"
        >
          Timeline
        </button>

        <!-- Actor Attribution Mode -->
        <button
          type="button"
          class="xcode-btn actor-btn"
          [class.agent]="actorMode() === 'agent'"
          (click)="toggleActor()"
          title="Actor attribution recorded on mutations and forks"
        >
          {{ actorMode() === 'human' ? '👤' : '🤖' }}
        </button>

        <!-- Keyboard Shortcuts & Quick Workflow Guide -->
        <div class="popover-anchor">
          <button
            type="button"
            class="xcode-btn icon-only"
            [class.active]="showHelp()"
            (click)="toggleHelpPopover()"
            title="Keyboard Shortcuts & Quick Debugger Guide"
          >
            ?
          </button>

          <div *ngIf="showHelp()" class="xcode-popover help-popover">
            <div class="popover-header">
              <span>Debugger Shortcuts &amp; Guide</span>
              <button type="button" class="close-btn" (click)="showHelp.set(false)">✕</button>
            </div>
            <div class="shortcut-list">
              <div class="sc-row"><span>Run / Pause Session</span><kbd>F5</kbd></div>
              <div class="sc-row"><span>Step Over Call</span><kbd>F10</kbd></div>
              <div class="sc-row"><span>Step Into Instruction</span><kbd>F11</kbd></div>
              <div class="sc-row"><span>Step Out of Frame</span><kbd>⇧ F11</kbd></div>
              <div class="sc-row"><span>Load .elf Firmware</span><kbd>⌘/Ctrl O</kbd></div>
            </div>
            <div class="help-tips">
              <div>• Type <code>main</code> in Disassembly or Locals &amp; Watch to set a symbolic breakpoint.</div>
              <div>• Click any byte in Memory Hex to poke values or attach a hardware write watchpoint.</div>
            </div>
          </div>
        </div>

        <!-- macOS Theme Toggle -->
        <button
          type="button"
          class="xcode-btn icon-only"
          (click)="toggleTheme()"
          [title]="isDark() ? 'Switch to macOS Light Theme' : 'Switch to Xcode Dark Theme'"
        >
          {{ isDark() ? '☀️' : '🌙' }}
        </button>
      </div>
    </header>
  `,
  styles: [`
    .xcode-toolbar {
      height: 44px;
      min-height: 44px;
      max-height: 44px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 12px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border-subtle);
      user-select: none;
      position: relative;
      z-index: 50;
      gap: 10px;
    }

    .toolbar-section {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .toolbar-left {
      flex-shrink: 0;
    }

    .app-identity {
      display: flex;
      align-items: center;
      gap: 7px;
    }

    .app-icon {
      width: 24px;
      height: 24px;
      background: var(--accent-blue);
      color: #ffffff;
      font-weight: 700;
      font-size: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: var(--radius-md);
      letter-spacing: 0.03em;
    }

    .app-titles {
      display: flex;
      align-items: baseline;
      gap: 5px;
    }

    .app-name {
      font-size: 12px;
      font-weight: 600;
      color: var(--text-primary);
      letter-spacing: -0.01em;
      white-space: nowrap;
    }

    .target-chip {
      font-size: 10px;
      font-weight: 500;
      padding: 1px 5px;
      border-radius: var(--radius-sm);
      background: var(--border-subtle);
      color: var(--text-secondary);
      font-family: var(--font-mono);
    }

    .popover-anchor {
      position: relative;
    }

    .sr-file-input {
      display: none;
    }

    .conn-pill-btn {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      padding: 3px 8px;
      background: var(--border-subtle);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-xl);
      color: var(--text-secondary);
      font-size: 11px;
      cursor: pointer;
      transition: background 0.15s, border-color 0.15s;
    }

    .conn-pill-btn:hover {
      background: var(--bg-surface-elevated);
      border-color: var(--border-strong);
      color: var(--text-primary);
    }

    .load-elf-btn {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 3px 9px;
      background: var(--accent-blue-subtle);
      border: 1px solid var(--accent-blue);
      border-radius: var(--radius-md);
      color: var(--accent-blue);
      font-size: 11px;
      font-weight: 600;
      cursor: pointer;
      max-width: 150px;
      transition: background 0.15s, color 0.15s;
    }

    .load-elf-btn:hover {
      background: var(--accent-blue);
      color: #ffffff;
    }

    .load-elf-btn.loaded {
      background: var(--bg-well);
      border-color: var(--border-strong);
      color: var(--text-primary);
    }

    .load-elf-btn.loaded:hover {
      border-color: var(--accent-blue);
      color: var(--accent-blue);
    }

    .load-icon {
      font-size: 11px;
      line-height: 1;
    }

    .load-label {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .status-dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: var(--accent-amber);
    }
    .status-dot.online {
      background: var(--accent-green);
    }
    .status-dot.busy {
      background: var(--accent-blue);
    }

    /* Center Activity HUD */
    .toolbar-center {
      flex: 1;
      min-width: 0;
      justify-content: center;
      max-width: 530px;
    }

    .activity-hud {
      width: 100%;
      height: 30px;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-md);
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 0 10px;
      gap: 10px;
      overflow: hidden;
    }

    .activity-hud.running {
      border-color: var(--accent-blue);
    }

    .hud-item {
      display: flex;
      align-items: baseline;
      gap: 5px;
      white-space: nowrap;
    }
    .hud-item.dimmed {
      opacity: 0.45;
    }

    .hud-meta-btn {
      background: transparent;
      border: none;
      padding: 2px 4px;
      border-radius: var(--radius-sm);
      cursor: pointer;
    }

    .hud-meta-btn:hover {
      background: var(--bg-surface-elevated);
    }

    .hud-core-label {
      font-size: 10px;
      font-weight: 700;
      color: var(--accent-blue);
      letter-spacing: 0.04em;
    }

    .hud-value {
      font-size: 11px;
      color: var(--text-primary);
    }

    .hud-src {
      font-size: 10px;
      color: var(--accent-green);
      max-width: 120px;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .hud-sub {
      font-size: 10px;
      color: var(--text-secondary);
    }

    .pacing-pill.slow {
      color: var(--accent-amber);
      font-weight: 700;
    }

    .hud-divider {
      width: 1px;
      height: 14px;
      background: var(--border-subtle);
      flex-shrink: 0;
    }

    .hud-offline-wrap {
      display: flex;
      align-items: center;
      gap: 6px;
      cursor: pointer;
      font-size: 11px;
      white-space: nowrap;
    }

    .offline-headline {
      color: var(--accent-amber);
      font-weight: 500;
    }
    .offline-sub {
      color: var(--text-secondary);
    }

    /* Right Section: Transport & Utilities */
    .toolbar-right {
      flex-shrink: 0;
      justify-content: flex-end;
    }

    .transport-segment {
      display: flex;
      align-items: center;
      background: var(--bg-well);
      padding: 2px;
      border-radius: var(--radius-md);
      border: 1px solid var(--border-subtle);
      gap: 1px;
    }

    .xcode-btn {
      background: transparent;
      border: none;
      color: var(--text-primary);
      padding: 4px 7px;
      border-radius: var(--radius-sm);
      font-size: 11px;
      font-weight: 500;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 4px;
      white-space: nowrap;
      transition: background 0.12s, color 0.12s;
    }

    .xcode-btn:hover:not(:disabled) {
      background: var(--bg-surface-elevated);
    }

    .xcode-btn:disabled {
      opacity: 0.35;
      cursor: not-allowed;
    }

    .xcode-btn.active {
      background: var(--accent-blue-subtle);
      color: var(--accent-blue);
    }

    .xcode-btn.play-btn {
      font-weight: 600;
    }

    .xcode-btn.play-btn.active {
      background: var(--accent-blue);
      color: #ffffff;
    }

    .xcode-btn.primary-solid {
      background: var(--accent-blue);
      color: #ffffff;
    }

    .xcode-btn.destructive {
      background: var(--accent-red);
      color: #ffffff;
    }

    .xcode-btn.icon-only {
      padding: 4px 6px;
      font-size: 12px;
      font-weight: 600;
    }

    .v-sep {
      width: 1px;
      height: 18px;
      background: var(--border-subtle);
    }

    /* Popovers */
    .xcode-popover {
      position: absolute;
      top: 34px;
      background: var(--bg-surface);
      border: 1px solid var(--border-strong);
      border-radius: var(--radius-lg);
      box-shadow: 0 12px 32px rgba(0, 0, 0, 0.38);
      padding: 12px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      z-index: 120;
    }

    .settings-popover {
      left: 0;
      width: 320px;
    }

    .load-popover {
      left: 0;
      width: 340px;
    }

    .help-popover {
      right: 0;
      width: 290px;
    }

    .popover-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 12px;
      font-weight: 600;
      color: var(--text-primary);
    }

    .close-btn {
      background: transparent;
      border: none;
      color: var(--text-secondary);
      cursor: pointer;
      font-size: 12px;
      padding: 2px 4px;
    }

    .popover-body {
      display: flex;
      flex-direction: column;
      gap: 10px;
    }

    .field-group {
      display: flex;
      flex-direction: column;
      gap: 5px;
    }

    .input-label {
      font-size: 11px;
      font-weight: 500;
      color: var(--text-secondary);
      display: block;
    }

    .input-row {
      display: flex;
      gap: 6px;
    }

    .xcode-input {
      flex: 1;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      color: var(--text-primary);
      padding: 5px 8px;
      font-size: 11px;
      font-family: var(--font-mono);
    }

    .core-seg {
      display: grid;
      grid-template-columns: 1fr 1fr;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      padding: 2px;
      gap: 2px;
    }

    .core-seg-btn {
      background: transparent;
      border: none;
      color: var(--text-secondary);
      font-size: 11px;
      font-weight: 500;
      padding: 4px 6px;
      border-radius: 3px;
      cursor: pointer;
    }

    .core-seg-btn.active {
      background: var(--bg-surface);
      color: var(--accent-blue);
      font-weight: 600;
    }

    .warn-note {
      font-size: 10px;
      color: var(--accent-amber);
      background: var(--accent-amber-subtle);
      padding: 5px 7px;
      border-radius: var(--radius-sm);
      line-height: 1.35;
    }

    .check-row {
      display: flex;
      align-items: flex-start;
      gap: 8px;
      cursor: pointer;
      padding: 6px 8px;
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
    }

    .check-row input {
      margin-top: 2px;
      accent-color: var(--accent-blue);
    }

    .check-copy {
      display: flex;
      flex-direction: column;
      gap: 2px;
    }

    .check-title {
      font-size: 11px;
      font-weight: 600;
      color: var(--text-primary);
    }

    .check-sub {
      font-size: 10px;
      color: var(--text-secondary);
    }

    .choose-elf-cta {
      width: 100%;
      padding: 7px 10px;
      background: var(--accent-blue);
      color: #ffffff;
      border: none;
      border-radius: var(--radius-md);
      font-size: 11px;
      font-weight: 600;
      cursor: pointer;
    }

    .choose-elf-cta:disabled {
      opacity: 0.45;
      cursor: not-allowed;
    }

    .upload-progress-box {
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .prog-row {
      display: flex;
      justify-content: space-between;
      font-size: 10px;
      color: var(--text-secondary);
    }

    .prog-track {
      height: 5px;
      background: var(--bg-well);
      border-radius: 3px;
      overflow: hidden;
    }

    .prog-fill {
      height: 100%;
      background: var(--accent-blue);
      transition: width 0.12s ease;
    }

    .loaded-summary {
      font-size: 10px;
      color: var(--accent-green);
      background: var(--accent-green-subtle);
      padding: 5px 7px;
      border-radius: var(--radius-sm);
      display: flex;
      flex-direction: column;
      gap: 2px;
    }

    .drop-tip {
      font-size: 10px;
      color: var(--text-tertiary);
      line-height: 1.35;
    }

    .cmd-help {
      border-top: 1px solid var(--border-subtle);
      padding-top: 8px;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .cmd-label {
      font-size: 10px;
      color: var(--text-secondary);
    }

    .cmd-code {
      font-size: 10px;
      font-family: var(--font-mono);
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      padding: 4px 6px;
      cursor: pointer;
      color: var(--accent-amber);
      word-break: break-all;
    }

    .copy-hint {
      font-size: 9px;
      color: var(--text-tertiary);
    }

    .shortcut-list {
      display: flex;
      flex-direction: column;
      gap: 5px;
    }

    .sc-row {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 11px;
      color: var(--text-primary);
    }

    kbd {
      font-family: var(--font-mono);
      font-size: 10px;
      padding: 1px 5px;
      border-radius: var(--radius-sm);
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      color: var(--text-secondary);
    }

    .help-tips {
      border-top: 1px solid var(--border-subtle);
      padding-top: 8px;
      font-size: 10px;
      color: var(--text-secondary);
      display: flex;
      flex-direction: column;
      gap: 4px;
      line-height: 1.4;
    }
  `]
})
export class ConnectionBarComponent {
  @ViewChild('elfFileInput') public elfFileInput?: ElementRef<HTMLInputElement>;

  public emu = inject(EmulatorService);
  public Core = Core;

  public urlInput = signal<string>(this.emu.serverUrl());
  public showSettings = signal<boolean>(false);
  public showLoadPopover = signal<boolean>(false);
  public showHelp = signal<boolean>(false);
  public copied = signal<boolean>(false);

  public uploadCore = signal<Core>(Core.Cpu0);
  public breakAtMain = signal<boolean>(true);

  public state = this.emu.connectionState;
  public actorMode = this.emu.actorMode;
  public dagOpen = this.emu.dagDrawerOpen;

  public isConnected = computed(() => this.state() === 'connected');
  public isConnecting = computed(() => this.state() === 'connecting');
  public isRunning = computed(() => this.emu.executionStatus() === 'running');
  public cpu1Attached = this.emu.cpu1Attached;
  public isDark = computed(() => this.emu.currentTheme() === 'dark');

  private lastHandledLoadTick = 0;

  constructor() {
    effect(() => {
      const tick = this.emu.openLoadPopoverTick();
      if (tick > this.lastHandledLoadTick) {
        this.lastHandledLoadTick = tick;
        this.showSettings.set(false);
        this.showHelp.set(false);
        this.showLoadPopover.set(true);
      }
    });
  }

  public cpu0SourceShort = computed(() => {
    const sl = this.emu.cpu0SourceLine();
    if (!sl || !sl.found || !sl.path) return '';
    const base = sl.path.split(/[\\/]/).pop() ?? sl.path;
    return `${base}:${sl.line}`;
  });

  public cpu0SourceFull = computed(() => {
    const sl = this.emu.cpu0SourceLine();
    if (!sl || !sl.found) return '';
    return `${sl.path}:${sl.line}`;
  });

  public formattedCycles = computed(() => {
    const ns = this.emu.virtualTimeNs();
    if (ns >= 1_000_000n) {
      return `${(Number(ns) / 1_000_000).toFixed(2)} ms`;
    }
    if (ns > 0n) {
      return `${(Number(ns) / 1_000).toFixed(1)} µs`;
    }
    return `0.00 ms`;
  });

  public pacingText = computed(() => {
    const ratio = this.emu.pacingRatio();
    if (ratio === null) return '1.00x';
    return `${ratio.toFixed(2)}x`;
  });

  public isSlowPacing = computed(() => {
    const ratio = this.emu.pacingRatio();
    return ratio !== null && ratio > 0 && ratio < 0.5;
  });

  public launchCommand = computed(() => {
    const raw = this.urlInput().trim();
    const hostPort = raw.replace(/^wss?:\/\//i, '') || '127.0.0.1:4567';
    return `ra8_emulator serve <firmware.elf> --listen tcp:${hostPort}`;
  });

  public toggleSettingsPopover(): void {
    const next = !this.showSettings();
    this.showLoadPopover.set(false);
    this.showHelp.set(false);
    this.showSettings.set(next);
  }

  public toggleLoadPopover(): void {
    const next = !this.showLoadPopover();
    this.showSettings.set(false);
    this.showHelp.set(false);
    this.showLoadPopover.set(next);
  }

  public toggleHelpPopover(): void {
    const next = !this.showHelp();
    this.showSettings.set(false);
    this.showLoadPopover.set(false);
    this.showHelp.set(next);
  }

  public triggerBrowserFilePicker(): void {
    this.elfFileInput?.nativeElement.click();
  }

  public async onFilePicked(event: Event): Promise<void> {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;
    const buf = await file.arrayBuffer();
    const res = await this.emu.loadElfFile(file.name, new Uint8Array(buf), this.uploadCore(), {
      breakAtMainAndRun: this.breakAtMain(),
    });
    input.value = '';
    if (res.ok) {
      this.showLoadPopover.set(false);
    }
  }

  public openDiagnostics(): void {
    this.emu.requestOpenDiagnostics();
  }

  public toHex8(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }

  public copyLaunchCommand(): void {
    void navigator.clipboard?.writeText(this.launchCommand());
    this.copied.set(true);
    setTimeout(() => this.copied.set(false), 1800);
  }

  public applyConnection(): void {
    if (this.isConnected()) {
      this.emu.disconnect();
    } else {
      void this.emu.connect(this.urlInput());
    }
    this.showSettings.set(false);
  }

  public toggleRun(): void {
    if (this.isRunning()) {
      void this.emu.pause();
    } else {
      void this.emu.run();
    }
  }

  public stepOver(): void {
    void this.emu.stepOver();
  }

  public stepInto(): void {
    void this.emu.step();
  }

  public stepOut(): void {
    void this.emu.stepOut();
  }

  public advance1ms(): void {
    void this.emu.advanceTimeMs(1);
  }

  public reset(): void {
    void this.emu.reset();
  }

  public toggleActor(): void {
    this.emu.actorMode.set(this.actorMode() === 'human' ? 'agent' : 'human');
  }

  public toggleDag(): void {
    this.emu.dagDrawerOpen.update((v) => !v);
  }

  public toggleTheme(): void {
    this.emu.toggleTheme();
  }
}
