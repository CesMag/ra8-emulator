import { Component } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ConnectionBarComponent } from './components/connection-bar/connection-bar.component';
import { ExecutionControlsComponent } from './components/execution-controls/execution-controls.component';
import { VirtualBoardComponent } from './components/virtual-board/virtual-board.component';
import { MetricsPanelComponent } from './components/metrics-panel/metrics-panel.component';
import { RegisterInspectorComponent } from './components/register-inspector/register-inspector.component';
import { CallStackComponent } from './components/call-stack/call-stack.component';
import { DisassemblyViewComponent } from './components/disassembly-view/disassembly-view.component';
import { MemoryInspectorComponent } from './components/memory-inspector/memory-inspector.component';
import { UartTerminalComponent } from './components/uart-terminal/uart-terminal.component';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [
    CommonModule,
    ConnectionBarComponent,
    ExecutionControlsComponent,
    VirtualBoardComponent,
    MetricsPanelComponent,
    RegisterInspectorComponent,
    CallStackComponent,
    DisassemblyViewComponent,
    MemoryInspectorComponent,
    UartTerminalComponent,
  ],
  templateUrl: './app.component.html',
  styleUrls: ['./app.component.css']
})
export class AppComponent {
  title = 'ra8-gui';
}
