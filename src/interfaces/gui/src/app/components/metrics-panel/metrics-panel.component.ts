import { Component, inject, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { EmulatorService } from '../../services/emulator.service';

@Component({
  selector: 'app-metrics-panel',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="pane-card">
      <div class="pane-header">
        <div class="header-left">
          <span class="pane-title">Host Diagnostics &amp; Guest Health</span>
          <span class="virt-clock" *ngIf="hasMetrics()">t = {{ virtualClockLabel() }}</span>
        </div>
        <span
          class="pacing-pill"
          [class.bottleneck]="isBottlenecked()"
          [class.healthy]="!isBottlenecked() && pacingText() !== 'Paused'"
          title="Virtual guest time delta divided by wall-clock elapsed time"
        >
          {{ pacingText() }}
        </span>
      </div>

      <div class="telemetry-body">
        <!-- Tier 1: Host Emulator Self-Profiling ("htop" Strip + 60s Sparklines) -->
        <div class="tier-block">
          <div class="tier-label">
            <span>Host Process Self-Profile</span>
            <span class="threads-tag">{{ hostThreads() }} threads</span>
          </div>

          <div class="spark-grid">
            <div class="spark-card">
              <div class="spark-meta">
                <span class="spark-name">Host CPU</span>
                <span class="spark-val cyan">{{ hostCpu() }}%</span>
              </div>
              <svg viewBox="0 0 120 26" preserveAspectRatio="none" class="spark-svg">
                <polyline
                  fill="none"
                  stroke="#38bdf8"
                  stroke-width="1.6"
                  [attr.points]="cpuSparkPoints()"
                />
              </svg>
            </div>

            <div class="spark-card">
              <div class="spark-meta">
                <span class="spark-name">Host RSS</span>
                <span class="spark-val emerald">{{ hostRss() }} MiB</span>
              </div>
              <svg viewBox="0 0 120 26" preserveAspectRatio="none" class="spark-svg">
                <polyline
                  fill="none"
                  stroke="#34d399"
                  stroke-width="1.6"
                  [attr.points]="rssSparkPoints()"
                />
              </svg>
            </div>
          </div>
        </div>

        <!-- Tier 2: Guest Silicon Utilization, Stack Watermarks, & RTOS Ownership -->
        <div class="tier-block">
          <div class="tier-label">
            <span>Guest Silicon &amp; Stack Watermarks</span>
          </div>

          <div class="cores-telemetry">
            <!-- CPU0 M85 -->
            <div class="core-box">
              <div class="core-head">
                <span class="c-name m85">CPU0 • M85</span>
                <span *ngIf="cpu0Pinned()" class="pinned-badge" title="0 WFI idle cycles — core spinning at 100%">PINNED</span>
                <span *ngIf="!cpu0Pinned()" class="c-pct">{{ cpu0Load() }}%</span>
              </div>
              <div class="meter-track">
                <div class="meter-fill m85" [style.width.%]="cpu0Load()"></div>
              </div>
              <div class="sub-stats">
                <span>RAM {{ cpu0RamUsed() }}/{{ cpu0RamTotal() }} KB</span>
                <span *ngIf="cpu0Stack()">MSP 0x{{ toHex(cpu0Stack()!.msp) }}</span>
              </div>
              <div class="sub-stats" *ngIf="cpu0Stack()">
                <span>Low 0x{{ toHex(cpu0Stack()!.lowMsp) }}</span>
                <span [class.overflow-warn]="cpu0Stack()!.overflow > 0">
                  {{ cpu0Stack()!.overflow > 0 ? 'OVF ' + cpu0Stack()!.overflow + 'B!' : 'Stack OK' }}
                </span>
              </div>
            </div>

            <!-- CPU1 M33 -->
            <div class="core-box">
              <div class="core-head">
                <span class="c-name m33">CPU1 • M33</span>
                <span *ngIf="cpu1Pinned()" class="pinned-badge">PINNED</span>
                <span *ngIf="!cpu1Pinned()" class="c-pct">
                  {{ emu.cpu1Attached() ? cpu1Load() + '%' : 'Gated' }}
                </span>
              </div>
              <div class="meter-track">
                <div class="meter-fill m33" [style.width.%]="cpu1Load()"></div>
              </div>
              <div class="sub-stats">
                <span>RAM {{ cpu1RamUsed() }}/{{ cpu1RamTotal() }} KB</span>
                <span *ngIf="cpu1Stack()">MSP 0x{{ toHex(cpu1Stack()!.msp) }}</span>
              </div>
            </div>
          </div>
        </div>

        <!-- RTOS Task Ownership (when Trace events stream) -->
        <div class="tier-block" *ngIf="rtosTasks().length > 0">
          <div class="tier-label">
            <span>RTOS Thread Ownership</span>
            <span class="threads-tag">Live Trace</span>
          </div>
          <div class="rtos-list">
            <div *ngFor="let t of rtosTasks()" class="rtos-row">
              <span class="rtos-name">{{ t.name }}</span>
              <div class="meter-track rtos-track">
                <div class="meter-fill rtos" [style.width.%]="t.sharePercent"></div>
              </div>
              <span class="rtos-pct">{{ t.sharePercent }}%</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .pane-card {
      background: linear-gradient(180deg, rgba(15, 23, 42, 0.84), rgba(6, 10, 19, 0.92));
      border: 1px solid rgba(255, 255, 255, 0.08);
      box-shadow: inset 0 1px 0 0 rgba(255, 255, 255, 0.06);
      border-radius: 10px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .pane-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 7px 12px;
      background: rgba(15, 23, 42, 0.55);
      border-bottom: 1px solid rgba(255, 255, 255, 0.07);
      gap: 8px;
    }

    .header-left {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .pane-title {
      font-size: 0.8rem;
      font-weight: 600;
      color: #f1f5f9;
    }

    .virt-clock {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.66rem;
      color: #94a3b8;
    }

    .pacing-pill {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.65rem;
      font-weight: 600;
      padding: 2px 7px;
      border-radius: 999px;
      background: rgba(30, 41, 59, 0.7);
      color: #94a3b8;
      border: 1px solid rgba(255, 255, 255, 0.08);
    }
    .pacing-pill.healthy {
      color: #4ade80;
      background: rgba(34, 197, 94, 0.14);
      border-color: rgba(74, 222, 128, 0.35);
    }
    .pacing-pill.bottleneck {
      color: #fbbf24;
      background: rgba(245, 158, 11, 0.16);
      border-color: rgba(251, 191, 36, 0.4);
    }

    .telemetry-body {
      padding: 8px 10px;
      display: flex;
      flex-direction: column;
      gap: 10px;
    }

    .tier-block {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }

    .tier-label {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 0.68rem;
      font-weight: 600;
      color: #94a3b8;
    }

    .threads-tag {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.63rem;
      color: #64748b;
    }

    .spark-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 8px;
    }

    .spark-card {
      background: rgba(9, 13, 22, 0.72);
      border: 1px solid rgba(255, 255, 255, 0.06);
      border-radius: 6px;
      padding: 5px 7px;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .spark-meta {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 0.67rem;
    }
    .spark-name { color: #94a3b8; }
    .spark-val {
      font-family: "JetBrains Mono", monospace;
      font-weight: 700;
    }
    .spark-val.cyan { color: #38bdf8; }
    .spark-val.emerald { color: #34d399; }

    .spark-svg {
      width: 100%;
      height: 24px;
      display: block;
    }

    .cores-telemetry {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 8px;
    }

    .core-box {
      background: rgba(9, 13, 22, 0.72);
      border: 1px solid rgba(255, 255, 255, 0.06);
      border-radius: 6px;
      padding: 6px 8px;
      display: flex;
      flex-direction: column;
      gap: 5px;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.66rem;
    }

    .core-head {
      display: flex;
      justify-content: space-between;
      align-items: center;
    }

    .c-name { font-weight: 700; }
    .c-name.m85 { color: #38bdf8; }
    .c-name.m33 { color: #c084fc; }
    .c-pct { color: #e2e8f0; }

    .pinned-badge {
      color: #fbbf24;
      background: rgba(245, 158, 11, 0.16);
      border: 1px solid rgba(245, 158, 11, 0.4);
      padding: 0 4px;
      border-radius: 3px;
      font-size: 0.6rem;
      font-weight: 700;
    }

    .meter-track {
      height: 5px;
      background: rgba(30, 41, 59, 0.85);
      border-radius: 3px;
      overflow: hidden;
    }

    .meter-fill {
      height: 100%;
      border-radius: 3px;
      transition: width 0.25s ease;
    }
    .meter-fill.m85 { background: #38bdf8; }
    .meter-fill.m33 { background: #a855f7; }
    .meter-fill.rtos { background: #34d399; }

    .sub-stats {
      display: flex;
      justify-content: space-between;
      color: #94a3b8;
      font-size: 0.62rem;
      gap: 4px;
    }

    .overflow-warn {
      color: #f87171;
      font-weight: 700;
    }

    .rtos-list {
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .rtos-row {
      display: flex;
      align-items: center;
      gap: 7px;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.66rem;
    }
    .rtos-name {
      width: 95px;
      color: #cbd5e1;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .rtos-track { flex: 1; }
    .rtos-pct { width: 32px; text-align: right; color: #34d399; }
  `]
})
export class MetricsPanelComponent {
  public emu = inject(EmulatorService);
  private m = this.emu.metrics;

  public hasMetrics = computed(() => this.m() !== null);
  public hostCpu = computed(() => this.m()?.hostCpuPercent ?? 0);
  public hostRss = computed(() => this.m()?.hostRssMb ?? 0);
  public hostThreads = computed(() => this.m()?.hostThreads ?? 0);

  public cpu0Load = computed(() => this.m()?.cpu0LoadPercent ?? 0);
  public cpu0Pinned = computed(() => (this.m()?.cpu0Pinned ?? 0) !== 0);
  public cpu0RamUsed = computed(() => Math.round((this.m()?.cpu0RamUsedBytes ?? 0) / 1024));
  public cpu0RamTotal = computed(() => Math.round((this.m()?.cpu0RamTotalBytes ?? 0) / 1024));

  public cpu1Load = computed(() => this.m()?.cpu1LoadPercent ?? 0);
  public cpu1Pinned = computed(() => (this.m()?.cpu1Pinned ?? 0) !== 0);
  public cpu1RamUsed = computed(() => Math.round((this.m()?.cpu1RamUsedBytes ?? 0) / 1024));
  public cpu1RamTotal = computed(() => Math.round((this.m()?.cpu1RamTotalBytes ?? 0) / 1024));

  public cpu0Stack = this.emu.cpu0Stack;
  public cpu1Stack = this.emu.cpu1Stack;
  public rtosTasks = this.emu.rtosTasks;

  public virtualClockLabel = computed(() => {
    const ns = Number(this.emu.virtualTimeNs());
    if (ns >= 1_000_000_000) return `${(ns / 1_000_000_000).toFixed(3)}s`;
    if (ns >= 1_000_000) return `${(ns / 1_000_000).toFixed(2)}ms`;
    if (ns >= 1_000) return `${(ns / 1_000).toFixed(1)}µs`;
    return `${ns}ns`;
  });

  public pacingText = computed(() => {
    if (this.emu.connectionState() !== 'connected') return 'Offline';
    const ratio = this.emu.pacingRatio();
    if (ratio === null || this.emu.executionStatus() !== 'running') return 'Paused';
    if (ratio < 0.35) return `${ratio.toFixed(2)}x Bottleneck`;
    return `${ratio.toFixed(2)}x Realtime`;
  });

  public isBottlenecked = computed(() => {
    const ratio = this.emu.pacingRatio();
    return this.emu.executionStatus() === 'running' && ratio !== null && ratio < 0.35;
  });

  public cpuSparkPoints = computed(() => this.toPolyline(this.emu.hostCpuHistory(), 100));
  public rssSparkPoints = computed(() => {
    const hist = this.emu.hostRssHistory();
    const maxVal = Math.max(128, ...hist);
    return this.toPolyline(hist, maxVal);
  });

  private toPolyline(samples: number[], maxScale: number): string {
    if (samples.length === 0) return '0,24 120,24';
    if (samples.length === 1) {
      const y = 24 - Math.min(22, Math.round(((samples[0] ?? 0) / Math.max(1, maxScale)) * 22));
      return `0,${y} 120,${y}`;
    }
    return samples
      .map((val, idx) => {
        const x = ((idx / (samples.length - 1)) * 120).toFixed(1);
        const y = (24 - Math.min(22, ((val ?? 0) / Math.max(1, maxScale)) * 22)).toFixed(1);
        return `${x},${y}`;
      })
      .join(' ');
  }

  public toHex(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
