import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="dashboard-filter"
export default class extends Controller {
  static targets = ["envFilter", "nameFilter", "statusBadge", "clearBtn", "projectRow", "metricsSection", "projectsSection", "viewToggle", "tableFilters", "chartFilters", "chartEnvFilter", "tagBtn", "chartCard", "chartsGrid", "projectTable", "environmentTable", "groupToggle", "envGroup"];

  connect() {
    this.activeStatus = '';
    this.activeTag = '';
    this.currentView = localStorage.getItem('dashboardView') || 'table';
    const storedGrouping = localStorage.getItem('dashboardGrouping');
    this.currentGrouping = ['project', 'environment'].includes(storedGrouping) ? storedGrouping : 'project';
    this.applyFilters = this.applyFilters.bind(this);
    this.statusBadgeTargets.forEach(badge => {
      badge.addEventListener('click', this.onBadgeClick.bind(this, badge));
    });
    if (this.hasEnvFilterTarget) this.envFilterTarget.addEventListener('change', this.applyFilters);
    if (this.hasNameFilterTarget) this.nameFilterTarget.addEventListener('input', this.applyFilters);
    if (this.hasClearBtnTarget) this.clearBtnTarget.addEventListener('click', this.clearFilters.bind(this));
    if (this.hasChartEnvFilterTarget) this.chartEnvFilterTarget.addEventListener('change', this.applyChartFilter.bind(this));
    this.applyView();
    this.applyGrouping();
  }

  onBadgeClick(badge) {
    this.activeStatus = (this.activeStatus === badge.dataset.statusFilter) ? '' : badge.dataset.statusFilter;
    this.applyFilters();
    // Also dispatch status filter event for charts
    this.dispatch('filterStatus', { detail: { status: this.activeStatus } });
  }

  applyFilters() {
    const envValue = this.hasEnvFilterTarget ? this.envFilterTarget.value : '';
    const nameValue = this.hasNameFilterTarget ? this.nameFilterTarget.value.trim().toLowerCase() : '';
    const anyActive = !!this.activeStatus || !!envValue || !!nameValue;
    this.projectRowTargets.forEach(row => {
      const matchesEnv = !envValue || row.dataset.environment === envValue;
      const project = row.querySelector('.col-project').textContent.toLowerCase();
      const environment = row.querySelector('.col-environment').textContent.toLowerCase();
      const matchesName = !nameValue || project.includes(nameValue) || environment.includes(nameValue);
      const matchesStatus = !this.activeStatus || row.dataset.status === this.activeStatus;
      row.style.display = (matchesEnv && matchesName && matchesStatus) ? '' : 'none';
    });
    // Environment-first groups: a group shows when any of its layers matches.
    // Roll-up numbers are computed on the server and do not change when filtering.
    this.envGroupTargets.forEach(group => {
      const groupNameMatch = !nameValue || (group.dataset.search || '').includes(nameValue);
      let anyVisible = false;
      group.querySelectorAll('.env-layer-row').forEach(row => {
        const matchesEnv = !envValue || row.dataset.environment === envValue;
        const matchesStatus = !this.activeStatus || row.dataset.status === this.activeStatus;
        const matchesName = !nameValue || groupNameMatch || (row.dataset.project || '').toLowerCase().includes(nameValue);
        const visible = matchesEnv && matchesStatus && matchesName;
        row.style.display = visible ? '' : 'none';
        if (visible) anyVisible = true;
      });
      group.style.display = anyVisible ? '' : 'none';
    });
    // Highlight active badge
    this.statusBadgeTargets.forEach(badge => {
      if (badge.dataset.statusFilter === this.activeStatus) {
        badge.style.boxShadow = '0 0 0 3px var(--color-filter-active-ring)';
        badge.style.transform = 'scale(1.05)';
        badge.style.background = 'var(--color-filter-active-bg)';
      } else {
        badge.style.boxShadow = '';
        badge.style.transform = '';
        badge.style.background = '';
      }
    });
    // Highlight env filter
    if (this.hasEnvFilterTarget) {
      if (envValue) {
        this.envFilterTarget.style.backgroundColor = 'var(--color-filter-active-bg)';
        this.envFilterTarget.style.boxShadow = '0 0 0 2px var(--color-filter-active-ring)';
      } else {
        this.envFilterTarget.style.backgroundColor = '';
        this.envFilterTarget.style.boxShadow = '';
      }
    }
    // Show/hide clear button
    if (this.hasClearBtnTarget) this.clearBtnTarget.style.display = anyActive ? '' : 'none';
  }

  applyChartFilter() {
    const envValue = this.hasChartEnvFilterTarget ? this.chartEnvFilterTarget.value : '';

    // Highlight env filter when active
    if (this.hasChartEnvFilterTarget) {
      if (envValue) {
        this.chartEnvFilterTarget.style.backgroundColor = 'var(--color-filter-active-bg)';
        this.chartEnvFilterTarget.style.boxShadow = '0 0 0 2px var(--color-filter-active-ring)';
      } else {
        this.chartEnvFilterTarget.style.backgroundColor = '';
        this.chartEnvFilterTarget.style.boxShadow = '';
      }
    }

    // Dispatch event to chart controller to update data
    this.dispatch('filterChart', { detail: { environment: envValue } });
  }

  filterByTag(event) {
    const tag = event.currentTarget.dataset.tag;
    this.activeTag = tag;

    // Update active state on tag buttons
    this.tagBtnTargets.forEach(btn => {
      if (btn.dataset.tag === tag) {
        btn.classList.add('active');
      } else {
        btn.classList.remove('active');
      }
    });

    // Filter chart cards
    this.chartCardTargets.forEach(card => {
      const cardTags = card.dataset.tags || '';
      if (!tag || cardTags.includes(tag)) {
        card.style.display = '';
      } else {
        card.style.display = 'none';
      }
    });
  }

  clearFilters() {
    if (this.hasEnvFilterTarget) this.envFilterTarget.value = '';
    if (this.hasNameFilterTarget) this.nameFilterTarget.value = '';
    this.activeStatus = '';
    this.applyFilters();
    // Clear status filter for charts too
    this.dispatch('filterStatus', { detail: { status: '' } });
  }

  toggleView(event) {
    const view = event.currentTarget.dataset.view;
    this.currentView = view;
    localStorage.setItem('dashboardView', view);
    this.applyView();
  }

  toggleGrouping(event) {
    const grouping = event.currentTarget.dataset.group;
    this.currentGrouping = grouping;
    localStorage.setItem('dashboardGrouping', grouping);
    this.applyGrouping();
  }

  applyGrouping() {
    this.groupToggleTargets.forEach(btn => {
      const active = btn.dataset.group === this.currentGrouping;
      btn.classList.toggle('active', active);
      btn.setAttribute('aria-pressed', String(active));
    });
    if (this.hasProjectTableTarget) this.projectTableTarget.hidden = (this.currentGrouping === 'environment');
    if (this.hasEnvironmentTableTarget) this.environmentTableTarget.hidden = (this.currentGrouping !== 'environment');
  }

  applyView() {
    // Update toggle buttons
    this.viewToggleTargets.forEach(btn => {
      if (btn.dataset.view === this.currentView) {
        btn.classList.add('active');
      } else {
        btn.classList.remove('active');
      }
    });

    // Show/hide filter controls based on view
    if (this.hasTableFiltersTarget) {
      this.tableFiltersTarget.style.display = (this.currentView === 'chart') ? 'none' : '';
    }
    if (this.hasChartFiltersTarget) {
      this.chartFiltersTarget.style.display = (this.currentView === 'table') ? 'none' : '';
    }

    // Show/hide sections based on view
    if (this.hasMetricsSectionTarget) {
      this.metricsSectionTarget.style.display = (this.currentView === 'table') ? 'none' : '';
    }
    if (this.hasProjectsSectionTarget) {
      this.projectsSectionTarget.style.display = (this.currentView === 'chart') ? 'none' : '';
    }
  }
}
