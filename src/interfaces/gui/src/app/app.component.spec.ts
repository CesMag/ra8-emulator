import { ComponentFixture, TestBed } from '@angular/core/testing';
import { AppComponent } from './app.component';

describe('AppComponent', () => {
  let component: AppComponent;
  let fixture: ComponentFixture<AppComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [AppComponent],
    }).compileComponents();

    fixture = TestBed.createComponent(AppComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create the workbench application shell', () => {
    expect(component).toBeTruthy();
  });

  it('should initialize with disassembly tab selected in top deck', () => {
    expect(component.topDeckTab()).toBe('disasm');
  });

  it('should initialize with registers tab selected in bottom deck', () => {
    expect(component.bottomDeckTab()).toBe('registers');
  });

  it('should initialize with terminal tab in bottom drawer', () => {
    expect(component.drawerTab()).toBe('terminal');
    expect(component.drawerCollapsed()).toBeFalse();
  });

  it('should show zero-context quickstart banner when offline and allow dismissing it', () => {
    expect(component.showQuickstartBanner()).toBeTrue();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('.quickstart-strip')).toBeTruthy();
    expect(el.querySelector('.load-elf-btn')).toBeTruthy();

    component.dismissedQuickstart.set(true);
    fixture.detectChanges();
    expect(component.showQuickstartBanner()).toBeFalse();
  });

  it('should toggle bottom drawer collapsed state', () => {
    component.toggleDrawerCollapse();
    expect(component.drawerCollapsed()).toBeTrue();
    component.toggleDrawerCollapse();
    expect(component.drawerCollapsed()).toBeFalse();
  });

  it('should switch top, bottom (including Locals & Watch), and drawer tabs cleanly', () => {
    component.setTopTab('memory');
    expect(component.topDeckTab()).toBe('memory');

    component.setBottomTab('locals');
    fixture.detectChanges();
    expect(component.bottomDeckTab()).toBe('locals');
    expect(fixture.nativeElement.querySelector('app-locals-watch')).toBeTruthy();

    component.setBottomTab('metrics');
    expect(component.bottomDeckTab()).toBe('metrics');

    component.setDrawerTab('dag');
    expect(component.drawerTab()).toBe('dag');
  });

  it('should auto-switch top deck to Memory Hex when jumpMemoryTo is requested', () => {
    expect(component.topDeckTab()).toBe('disasm');
    component.emu.jumpMemoryTo(0x22000100);
    fixture.detectChanges();
    expect(component.topDeckTab()).toBe('memory');
  });

  it('should auto-switch bottom deck to System Diagnostics when HUD pacing badge requests it', () => {
    expect(component.bottomDeckTab()).toBe('registers');
    component.emu.requestOpenDiagnostics();
    fixture.detectChanges();
    expect(component.bottomDeckTab()).toBe('metrics');
  });
});
