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

  it('should toggle bottom drawer collapsed state', () => {
    component.toggleDrawerCollapse();
    expect(component.drawerCollapsed()).toBeTrue();
    component.toggleDrawerCollapse();
    expect(component.drawerCollapsed()).toBeFalse();
  });

  it('should switch top and bottom deck tabs cleanly', () => {
    component.setTopTab('memory');
    expect(component.topDeckTab()).toBe('memory');

    component.setBottomTab('metrics');
    expect(component.bottomDeckTab()).toBe('metrics');

    component.setDrawerTab('dag');
    expect(component.drawerTab()).toBe('dag');
  });
});
