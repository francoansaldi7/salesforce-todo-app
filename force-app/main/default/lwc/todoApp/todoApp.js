import { LightningElement, track, wire } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import USER_ID from '@salesforce/user/Id';
import FIRST_NAME_FIELD from '@salesforce/schema/User.FirstName';

// Parent container — holds both child list components and coordinates refreshes between them.
export default class TodoApp extends LightningElement {

    // Controls which list is visible on mobile: 'pending' (default) or 'completed'.
    // On desktop both columns are always visible and this value is ignored.
    @track activeMobileTab = 'pending';

    // Live counts reported by each child list, shown on the mobile tab labels.
    @track pendingCount = 0;
    @track completedCount = 0;

    // Running user's first name, used to personalize the greeting banner.
    @wire(getRecord, { recordId: USER_ID, fields: [FIRST_NAME_FIELD] })
    userRecord;

    // Falls back to 'Legend' if the first name isn't set or hasn't loaded yet.
    get firstName() {
        return this.userRecord?.data?.fields?.FirstName?.value || 'Legend';
    }

    // ── Mobile tab CSS getters ────────────────────────────────────────────────

    // Adds 'column--hidden' to the pending column when the completed tab is active on mobile.
    get pendingColumnClass() {
        return `column${this.activeMobileTab === 'completed' ? ' column--hidden' : ''}`;
    }

    // Adds 'column--hidden' to the completed column when the pending tab is active on mobile.
    get completedColumnClass() {
        return `column${this.activeMobileTab === 'pending' ? ' column--hidden' : ''}`;
    }

    // Highlights the Pending tab button when it is the active view.
    get pendingTabClass() {
        return `mobile-tab${this.activeMobileTab === 'pending' ? ' mobile-tab--active' : ''}`;
    }

    // Highlights the Completed tab button when it is the active view.
    get completedTabClass() {
        return `mobile-tab${this.activeMobileTab === 'completed' ? ' mobile-tab--active' : ''}`;
    }

    get pendingTabLabel() {
        return `Pending (${this.pendingCount})`;
    }

    get completedTabLabel() {
        return `Completed (${this.completedCount})`;
    }

    // ── Handlers ──────────────────────────────────────────────────────────────

    // Switches the active mobile tab based on which button was tapped (data-tab attribute).
    handleMobileTabSwitch(evt) {
        this.activeMobileTab = evt.currentTarget.dataset.tab;
    }

    // Called whenever a child fires the 'refreshlists' custom event.
    // Example: completing a task should refresh both lists so it moves columns.
    handleRefresh() {
        const pending   = this.template.querySelector('c-todo-pending-list');
        const completed = this.template.querySelector('c-todo-completed-list');

        // Both components expose a public refreshData() method for this purpose.
        if (pending)   pending.refreshData();
        if (completed) completed.refreshData();
    }

    // Keeps the mobile tab labels' counts in sync with each child list.
    handlePendingCountChange(evt) {
        this.pendingCount = evt.detail.count;
    }

    handleCompletedCountChange(evt) {
        this.completedCount = evt.detail.count;
    }
}