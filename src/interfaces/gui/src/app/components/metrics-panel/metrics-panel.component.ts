import { Component, inject, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { EmulatorService } from '../../services/emulator.service';

@Component({
  selector: 'app-metrics-panel',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="metrics-pane">
      <!-- Sub-Toolbar -->
      <div class="metrics-subtoolbar">
        <div class="sub-left">
          <span class="sub-label">Diagnostics &amp; Pacing</span>
          <span class="virt-clock font-mono" *ngIf="hasMetrics()">t = {{ virtualClockLabel() }}</span>
        </div>
        <span
          class="pacing-pill font-mono"
          [class.bottleneck]="isBottlenecked()"
          [class.healthy]="!isBottlenecked() && pacingText() !== 'Paused'"
        >
          {{ pacingText() }}
        </span>
      </div>

      <div class="telemetry-body">
        <!-- Tier 1: Host Process Self-Profile (Instruments Style) -->
        <div class="tier-section">
          <div class="tier-head">
            <span class="tier-title">Host Process</span>
            <span class="meta-tag font-mono">{{ hostThreads() }} threads</span>
          </div>

          <div class="spark-grid">
            <div class="spark-box">
              <div class="spark-info">
                <span class="spark-name">Host CPU</span>
                <span class="spark-val font-mono blue">{{ hostCpu() }}%</span>
              </div>
              <svg viewBox="0 0 120 24" preserveAspectRatio="none" class="spark-svg">
                <polyline
                  fill="none"
                  stroke="var(--accent-blue)"
                  stroke-width="1.5"
                  [attr.points]="cpuSparkPoints()"
                />
              </svg>
            </div>

            <div class="spark-box">
              <div class="spark-info">
                <span class="spark-name">Host RSS</span>
                <span class="spark-val font-mono green">{{ hostRss() }} MiB</span>
              </div>
              <svg viewBox="0 0 120 24" preserveAspectRatio="none" class="spark-svg">
                <polyline
                  fill="none"
                  stroke="var(--accent-green)"
                  stroke-width="1.5"
                  [attr.points]="rssSparkPoints()"
                />
              </svg>
            </div>
          </div>
        </div>

        <!-- Tier 2: Guest Silicon Utilization & Stack Watermarks -->
        <div class="tier-section">
          <div class="tier-head">
            <span class="tier-title">Silicon Watermarks</span>
          </div>

          <div class="cores-telemetry">
            <!-- CPU0 M85 -->
            <div class="core-tele-card">
              <div class="core-tele-head">
                <span class="core-name m85">CPU0 • M85</span>
                <span *ngIf="cpu0Pinned()" class="pinned-tag">PINNED</span>
                <span *ngIf="!cpu0Pinned()" class="core-pct font-mono">{{ cpu0Load() }}%</span>
              </div>
              <div class="meter-bar">
                <div class="meter-fill m85" [style.width.%]="cpu0Load()"></div>
              </div>
              <div class="tele-stats font-mono">
                <span>RAM {{ cpu0RamUsed() }}/{{ cpu0RamTotal() }} KB</span>
                <span *ngIf="cpu0Stack()">MSP 0x{{ toHex(cpu0Stack()!.msp) }}</span>
              </div>
            </div>

            <!-- CPU1 M33 -->
            <div class="core-tele-card">
              <div class="core-tele-head">
                <span class="core-name m33">CPU1 • M33</span>
                <span *ngIf="cpu1Pinned()" class="pinned-tag">PINNED</span>
                <span *ngIf="!cpu1Pinned()" class="core-pct font-mono">
                  {{ emu.cpu1Attached() ? cpu1Load() + '%' : 'Gated' }}
                </span>
              </div>
              <div class="meter-bar">
                <div class="meter-fill m33" [style.width.%]="cpu1Load()"></div>
              </div>
              <div class="tele-stats font-mono">
                <span>RAM {{ cpu1RamUsed() }}/{{ cpu1RamTotal() }} KB</span>
                <span *ngIf="cpu1Stack()">MSP 0x{{ toHex(cpu1Stack()!.msp) }}</span>
              </div>
            </div>
          </div>
        </div>

        <!-- Tier 3: RTOS Task Ownership -->
        <div class="tier-section" *ngIf="rtosTasks().length > 0">
          <div class="tier-head">
            <span class="tier-title">RTOS Thread Trace</span>
          </div>
          <div class="rtos-list font-mono">
            <div *ngFor="let t of rtosTasks()" class="rtos-row">
              <span class="rtos-name">{{ t.name }}</span>
              <div class="meter-bar rtos-bar">
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
    .metrics-pane {
      height: 100%;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      background: var(--bg-surface);
    }

    .metrics-subtoolbar {
      height: 28px;
      min-height: 28px;
      background: var(--bg-surface);
      border-bottom: 1px solid var(--border-subtle);
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 10px;
      flex-shrink: 0;
    }

    .sub-left {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .sub-label {
      font-size: 10px;
      color: var(--text-secondary);
      font-weight: 500;
    }

    .virt-clock {
      font-size: 10px;
      color: var(--text-tertiary);
    }

    .pacing-pill {
      font-size: 10px;
      font-weight: 500;
      padding: 1px 6px;
      border-radius: var(--radius-sm);
      background: var(--bg-well);
      color: var(--text-secondary);
    }
    .pacing-pill.healthy {
      color: var(--accent-green);
      background: var(--accent-green-subtle);
    }
    .pacing-pill.bottleneck {
      color: var(--accent-amber);
      background: var(--accent-amber-subtle);
    }

    .telemetry-body {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      padding: 8px 10px;
      display: flex;
      flex-direction: column;
      gap: 10px;
    }

    .tier-section {
      display: flex;
      flex-direction: column;
      gap: 5px;
    }

    .tier-head {
      display: flex;
      justify-content: space-between;
      align-items: center;
    }

    .tier-title {
      font-size: 10px;
      font-weight: 600;
      color: var(--text-secondary);
    }

    .meta-tag {
      font-size: 9px;
      color: var(--text-tertiary);
    }

    .spark-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 6px;
    }

    .spark-box {
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      padding: 4px 6px;
      display: flex;
      flex-direction: column;
      gap: 3px;
    }

    .spark-info {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 10px;
    }
    .spark-name { color: var(--text-secondary); }
    .spark-val.blue { color: var(--accent-blue); font-weight: 600; }
    .spark-val.green { color: var(--accent-green); font-weight: 600; }

    .spark-svg {
      width: 100%;
      height: 20px;
      display: block;
    }

    .cores-telemetry {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 6px;
    }

    .core-tele-card {
      background: var(--bg-well);
      border: 1px solid var(--border-subtle);
      border-radius: var(--radius-sm);
      padding: 5px 7px;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .core-tele-head {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 10px;
    }

    .core-name { font-weight: 700; }
    .core-name.m85 { color: var(--accent-blue); }
    .core-name.m33 { color: var(--accent-purple); }
    .core-pct { color: var(--text-primary); }

    .pinned-tag {
      color: var(--accent-amber);
      background: var(--accent-amber-subtle);
      padding: 0 4px;
      border-radius: 2px;
      font-size: 9px;
      font-weight: 700;
    }

    .meter-bar {
      height: 4px;
      background: var(--border-subtle);
      border-radius: 2px;
      overflow: hidden;
    }

    .meter-fill {
      height: 100%;
      border-radius: 2px;
      transition: width 0.25s ease;
    }
    .meter-fill.m85 { background: var(--accent-blue); }
    .meter-fill.m33 { background: var(--accent-purple); }
    .meter-fill.rtos { background: var(--accent-green); }

    .tele-stats {
      display: flex;
      justify-content: space-between;
      color: var(--text-secondary);
      font-size: 9px;
    }

    .rtos-list {
      display: flex;
      flex-direction: column;
      gap: 3px;
    }

    .rtos-row {
      display: flex;
      align-items: center;
      gap: 6px;
      font-size: 10px;
    }
    .rtos-name {
      width: 90px;
      color: var(--text-primary);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .rtos-bar { flex: 1; }
    .rtos-pct { width: 30px; text-align: right; color: var(--accent-green); }
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
    if (samples.length === 0) return '0,22 120,22';
    if (samples.length === 1) {
      const y = 22 - Math.min(20, Math.round(((samples[0] ?? 0) / Math.max(1, maxScale)) * 20));
      return `0,${y} 120,${y}`;
    }
    return samples
      .map((val, idx) => {
        const x = ((idx / (samples.length - 1)) * 120).toFixed(1);
        const y = (22 - Math.min(20, ((val ?? 0) / Math.max(1, maxScale)) * 20)).toFixed(1);
        return `${x},${y}`;
      })
      .join(' ');
  }

  public toHex(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
