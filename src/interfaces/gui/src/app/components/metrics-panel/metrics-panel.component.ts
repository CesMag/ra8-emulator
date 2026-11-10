import { Component, inject, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { EmulatorService } from '../../services/emulator.service';

@Component({
  selector: 'app-metrics-panel',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="metrics-card">
      <div class="metrics-header">
        <span class="title">SYSTEM & DEVICE TELEMETRY</span>
        <span class="refresh-badge" *ngIf="hasMetrics()">Live 1s</span>
      </div>

      <div class="metrics-grid">
        <!-- Host Metrics -->
        <div class="metric-box">
          <div class="box-title">HOST METRICS</div>
          <div class="metric-row">
            <span class="metric-label">CPU:</span>
            <div class="bar-container">
              <div class="bar-fill cpu-fill" [style.width.%]="hostCpu()"></div>
            </div>
            <span class="metric-val">{{ hostCpu() }}%</span>
          </div>
          <div class="metric-row">
            <span class="metric-label">RSS:</span>
            <span class="metric-val">{{ hostRss() }} MB</span>
          </div>
          <div class="metric-row">
            <span class="metric-label">Threads:</span>
            <span class="metric-val">{{ hostThreads() }}</span>
          </div>
        </div>

        <!-- CPU0 Cortex-M85 -->
        <div class="metric-box">
          <div class="box-title">CPU0 (CORTEX-M85)</div>
          <div class="metric-row">
            <span class="metric-label">Load:</span>
            <div class="bar-container">
              <div class="bar-fill m85-fill" [style.width.%]="cpu0Load()"></div>
            </div>
            <span class="metric-val">{{ cpu0Load() }}%</span>
          </div>
          <div class="metric-row">
            <span class="metric-label">RAM:</span>
            <span class="metric-val">{{ cpu0RamUsed() }} / {{ cpu0RamTotal() }} KB</span>
          </div>
          <div class="metric-row">
            <span class="metric-label">State:</span>
            <span class="metric-val" [class.pinned]="cpu0Pinned()">
              {{ cpu0Pinned() ? 'PINNED' : 'Active' }}
            </span>
          </div>
        </div>

        <!-- CPU1 Cortex-M33 -->
        <div class="metric-box">
          <div class="box-title">CPU1 (CORTEX-M33)</div>
          <div class="metric-row">
            <span class="metric-label">Load:</span>
            <div class="bar-container">
              <div class="bar-fill m33-fill" [style.width.%]="cpu1Load()"></div>
            </div>
            <span class="metric-val">{{ cpu1Load() }}%</span>
          </div>
          <div class="metric-row">
            <span class="metric-label">RAM:</span>
            <span class="metric-val">{{ cpu1RamUsed() }} / {{ cpu1RamTotal() }} KB</span>
          </div>
          <div class="metric-row">
            <span class="metric-label">State:</span>
            <span class="metric-val" [class.pinned]="cpu1Pinned()">
              {{ cpu1Pinned() ? 'PINNED' : 'Idle' }}
            </span>
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .metrics-card {
      background: var(--bg-secondary);
      border: 1px solid var(--border-color);
      border-radius: 8px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .metrics-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 6px 10px;
      background: var(--bg-tertiary);
      border-bottom: 1px solid var(--border-color);
    }

    .title {
      font-size: 0.75rem;
      font-weight: 700;
      color: var(--text-primary);
    }

    .refresh-badge {
      font-size: 0.65rem;
      color: #4ade80;
      background: rgba(74, 222, 128, 0.1);
      padding: 1px 6px;
      border-radius: 4px;
      font-family: monospace;
    }

    .metrics-grid {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 8px;
      padding: 8px;
    }

    @media (max-width: 768px) {
      .metrics-grid {
        grid-template-columns: 1fr;
      }
    }

    .metric-box {
      background: #181b20;
      border: 1px solid #232730;
      border-radius: 6px;
      padding: 6px 8px;
      display: flex;
      flex-direction: column;
      gap: 4px;
      font-family: monospace;
      font-size: 0.7rem;
    }

    .box-title {
      font-weight: 700;
      color: #94a3b8;
      border-bottom: 1px solid #232730;
      padding-bottom: 2px;
      margin-bottom: 2px;
      font-size: 0.65rem;
      letter-spacing: 0.05em;
    }

    .metric-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 6px;
    }

    .metric-label {
      color: #64748b;
      min-width: 45px;
    }

    .bar-container {
      flex: 1;
      height: 6px;
      background: #232730;
      border-radius: 3px;
      overflow: hidden;
    }

    .bar-fill {
      height: 100%;
      border-radius: 3px;
      transition: width 0.3s ease;
    }
    .cpu-fill { background: #38bdf8; }
    .m85-fill { background: #4ade80; }
    .m33-fill { background: #a855f7; }

    .metric-val {
      color: #f1f5f9;
      font-weight: 600;
    }

    .metric-val.pinned {
      color: #f59e0b;
    }
  `]
})
export class MetricsPanelComponent {
  private emu = inject(EmulatorService);

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
}
