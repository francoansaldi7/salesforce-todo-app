// ─── Imports ──────────────────────────────────────────────────────────────────
// LWC core decorators:
//   @track → makes arrays/objects deeply reactive (UI updates when items change)
//   @wire  → automatically calls an Apex method and updates the component when data arrives
//   @api   → marks a method as public so the parent component can call it
import { LightningElement, api, track, wire } from 'lwc';

// Apex methods from TaskController — each one talks to the Salesforce database
import getCompletedTasks from '@salesforce/apex/TaskController.getCompletedTasks';
import toggleTaskStatus from '@salesforce/apex/TaskController.toggleTaskStatus';
import deleteTask from '@salesforce/apex/TaskController.deleteTask';
import updateTask from '@salesforce/apex/TaskController.updateTask';
import clearCompletedTasks from '@salesforce/apex/TaskController.clearCompletedTasks';
import restoreArchivedTask from '@salesforce/apex/TaskController.restoreArchivedTask';
import restoreAllArchivedTasks from '@salesforce/apex/TaskController.restoreAllArchivedTasks';

// Shows a small pop-up notification (toast) at the top of the screen
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// Lets us navigate to a Salesforce record page when the user clicks a task name
import { NavigationMixin } from 'lightning/navigation';

// How long the undo bar stays up before a delete becomes permanent (ms)
const UNDO_WINDOW_MS = 5000;

// How long to wait after the user stops typing before searching the server (ms)
const SEARCH_DEBOUNCE_MS = 300;

// Must match TaskController.PAGE_SIZE — the server is authoritative on how many
// records actually come back per page; this is only used to compute the page count.
const PAGE_SIZE = 15;

// ─── Component ────────────────────────────────────────────────────────────────
export default class TodoCompletedList extends NavigationMixin(LightningElement) {

    @track tasks;          // the current page of completed task records shown in the UI
    selectedFilter = '';   // current filter value: '' = All, 'WEEK', 'MONTH', or 'ARCHIVED'
    isLoading = true;      // shows a spinner until the first data load finishes

    searchTerm = '';            // raw text as the user types it (bound directly to the input)
    committedSearchTerm = '';   // debounced value actually sent to the server
    searchDebounceTimeoutId = null;

    pageNumber = 1;   // 1-based current page
    totalCount = 0;   // total completed tasks matching the current filter/search, across all pages

    // Passed to the wire alongside selectedFilter/searchTerm/pageNumber purely to keep
    // its cache key fresh. getCompletedTasks is cacheable, and Salesforce's client-side
    // wire cache is keyed per unique parameter combination — a mutation made while
    // viewing one page/filter wouldn't otherwise invalidate a stale cached response for
    // a page/filter the client already queried earlier in the session. Bumping this on
    // every mutation forces a fresh server call the next time any combination, old or
    // new, is selected.
    cacheBuster = 0;

    editingTaskId = null;  // ID of the task currently being edited inline (null = none)
    // Draft values shown in the inline edit form — populated from the task being edited
    @track draft = { name: '', priority: 'Medium', category: '', notes: '', recurrence: 'None' };

    pendingDeletion = null; // { id, task } for a task hidden pending the undo window
    pendingDeletionTimeoutId = null;

    disconnectedCallback() {
        // Avoid finalizing a delete (or touching component state) after teardown.
        if (this.pendingDeletionTimeoutId) {
            clearTimeout(this.pendingDeletionTimeoutId);
        }
        if (this.searchDebounceTimeoutId) {
            clearTimeout(this.searchDebounceTimeoutId);
        }
    }

    // The options shown in the filter dropdown
    get filterOptions() {
        return [
            { label: 'All',        value: '' },
            { label: 'This Week',  value: 'WEEK' },
            { label: 'This Month', value: 'MONTH' },
            { label: 'Archived',   value: 'ARCHIVED' }
        ];
    }

    // True when viewing tasks that "Clear Completed" previously archived
    get isArchivedView() {
        return this.selectedFilter === 'ARCHIVED';
    }

    // ── Picklist options (must match the Apex-side picklist values) ────────────

    get priorityOptions() {
        return [
            { label: 'High', value: 'High' },
            { label: 'Medium', value: 'Medium' },
            { label: 'Low', value: 'Low' }
        ];
    }

    get categoryOptions() {
        return [
            { label: 'None', value: '' },
            { label: 'Work', value: 'Work' },
            { label: 'Personal', value: 'Personal' },
            { label: 'Errands', value: 'Errands' },
            { label: 'Shopping', value: 'Shopping' },
            { label: 'Other', value: 'Other' }
        ];
    }

    get recurrenceOptions() {
        return [
            { label: 'None', value: 'None' },
            { label: 'Daily', value: 'Daily' },
            { label: 'Weekly', value: 'Weekly' },
            { label: 'Monthly', value: 'Monthly' }
        ];
    }

    // ── Derived state ────────────────────────────────────────────────────────

    get cardTitle() {
        return `Completed Tasks (${this.totalCount})`;
    }

    get hasNoTasks() {
        return this.totalCount === 0;
    }

    get hasVisibleTasks() {
        return !!this.tasks && this.tasks.length > 0;
    }

    // Shown when there are truly no completed tasks in this filter at all
    get showEmptyState() {
        return !this.isLoading && this.hasNoTasks && !this.committedSearchTerm;
    }

    get emptyStateMessage() {
        return this.isArchivedView
            ? 'No archived tasks. Tasks you clear from the completed list will show up here.'
            : 'No completed tasks yet.';
    }

    // Shown when there are tasks, but the search term matched none of them
    get showNoResultsState() {
        return !this.isLoading && this.hasNoTasks && !!this.committedSearchTerm;
    }

    // ── Pagination ───────────────────────────────────────────────────────────

    get totalPages() {
        return Math.max(1, Math.ceil(this.totalCount / PAGE_SIZE));
    }

    get showPagination() {
        return this.totalCount > PAGE_SIZE;
    }

    get paginationLabel() {
        return `Page ${this.pageNumber} of ${this.totalPages}`;
    }

    get isFirstPage() {
        return this.pageNumber <= 1;
    }

    get isLastPage() {
        return this.pageNumber >= this.totalPages;
    }

    handlePreviousPage() {
        if (!this.isFirstPage) {
            this.pageNumber -= 1;
        }
    }

    handleNextPage() {
        if (!this.isLastPage) {
            this.pageNumber += 1;
        }
    }

    // @wire automatically calls getCompletedTasks when the component loads, and again
    // whenever selectedFilter, searchTerm, pageNumber, or cacheBuster change (the $
    // prefix means "watch this property for changes").
    @wire(getCompletedTasks, {
        filterType: '$selectedFilter',
        searchTerm: '$committedSearchTerm',
        pageNumber: '$pageNumber',
        cacheBuster: '$cacheBuster'
    })
    wiredTasks(result) {
        this.isLoading = false;    // hide the spinner once we have a response

        if (result.data) {
            const { records, totalCount } = result.data;
            this.totalCount = totalCount;

            // If a mutation emptied out the page we're on, step back a page rather
            // than showing a dead end — this re-triggers the wire with the new
            // pageNumber automatically.
            if (records.length === 0 && this.pageNumber > 1) {
                this.pageNumber -= 1;
                return;
            }

            // Add display-only helper properties so the template can stay simple —
            // LWC templates can't call getters with per-item parameters in a loop.
            this.tasks = records.map(task => ({
                ...task,
                isEditing: false,
                priorityClass: `priority-dot priority-${(task.Priority__c || 'medium').toLowerCase()}`,
                hasNotes: !!(task.Notes__c && task.Notes__c.trim()),
                isRecurring: !!(task.Recurrence__c && task.Recurrence__c !== 'None')
            }));
            // Lets the parent (todoApp) show a live count on the mobile tab bar.
            this.dispatchEvent(new CustomEvent('completedcountchange', { detail: { count: this.totalCount } }));
        } else if (result.error) {
            this.showToast('Error', 'Failed to load completed tasks', 'error');
        }
    }

    // ── Search ───────────────────────────────────────────────────────────────

    handleSearchChange(event) {
        this.searchTerm = event.target.value;

        clearTimeout(this.searchDebounceTimeoutId);
        this.searchDebounceTimeoutId = setTimeout(() => {
            this.committedSearchTerm = this.searchTerm;
            this.pageNumber = 1; // a new search always starts back at page 1
        }, SEARCH_DEBOUNCE_MS);
    }

    // Called when the user picks a different option in the filter dropdown.
    // Updating selectedFilter automatically re-triggers the @wire above.
    handleFilterChange(event) {
        this.isLoading = true;                 // show spinner while reloading
        this.selectedFilter = event.detail.value;
        this.pageNumber = 1;                   // switching filters always starts at page 1
    }

    // Called when the user un-ticks the checkbox next to a completed task —
    // moves it back to Pending
    handleCheckboxChange(event) {
        const taskId = event.currentTarget.dataset.id; // read the task ID from data-id attribute

        toggleTaskStatus({ taskId })
            .then(() => {
                // Tell the parent component to also refresh the pending list
                this.dispatchEvent(new CustomEvent('refreshlists'));
                this.bumpCache();
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to update task', 'error');
            });
    }

    // Archives every completed task in one action — nothing is deleted, they're just
    // hidden from this list until restored from the Archived filter.
    handleClearCompleted() {
        if (this.hasNoTasks) {
            return;
        }

        clearCompletedTasks()
            .then(() => {
                this.showToast('Success', 'Completed tasks cleared — find them under the Archived filter', 'success');
                this.bumpCache();
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to clear completed tasks', 'error');
            });
    }

    // Brings an archived task back into the normal completed list.
    handleRestoreTask(event) {
        const taskId = event.currentTarget.dataset.id;

        restoreArchivedTask({ taskId })
            .then(() => {
                this.showToast('Success', 'Task restored', 'success');
                this.bumpCache();
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to restore task', 'error');
            });
    }

    // Brings every archived task back into the normal completed list in one action.
    handleRestoreAll() {
        if (this.hasNoTasks) {
            return;
        }

        restoreAllArchivedTasks()
            .then(() => {
                this.showToast('Success', 'All tasks restored', 'success');
                this.bumpCache();
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to restore tasks', 'error');
            });
    }

    // Navigates to the Salesforce record page for the clicked task
    handleNavigateToRecord(event) {
        const recordId = event.currentTarget.dataset.id;

        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: recordId,
                objectApiName: 'To_Do_Task__c',
                actionName: 'view'
            }
        });
    }

    // Public method — the parent (todoApp) can call this to force a data reload.
    // The @api decorator makes it accessible from outside this component.
    @api
    refreshData() {
        this.bumpCache();
    }

    // Forces every subsequent call to getCompletedTasks — regardless of which filter
    // is selected, now or later — to hit the server instead of a possibly-stale cache.
    bumpCache() {
        this.cacheBuster += 1;
    }

    // ── Delete (optimistic, with undo) ───────────────────────────────────────

    // Hides the task immediately and shows an undo bar; the actual delete only
    // happens after the undo window elapses without the user clicking Undo.
    handleDeleteTask(event) {
        const taskId = event.currentTarget.dataset.id;
        const taskToDelete = this.tasks.find(t => t.Id === taskId);
        if (!taskToDelete) {
            return;
        }

        this.tasks = this.tasks.filter(t => t.Id !== taskId);
        this.pendingDeletion = { id: taskId, task: taskToDelete };

        this.pendingDeletionTimeoutId = setTimeout(() => {
            this.finalizeDelete(taskId);
        }, UNDO_WINDOW_MS);
    }

    handleUndoDelete() {
        if (!this.pendingDeletion) {
            return;
        }
        clearTimeout(this.pendingDeletionTimeoutId);
        this.pendingDeletionTimeoutId = null;
        this.tasks = [...this.tasks, this.pendingDeletion.task];
        this.pendingDeletion = null;
    }

    async finalizeDelete(taskId) {
        this.pendingDeletionTimeoutId = null;
        this.pendingDeletion = null;
        try {
            await deleteTask({ taskId });
            this.bumpCache();
        } catch (error) {
            this.showToast('Error', error?.body?.message || 'Failed to delete task', 'error');
            this.bumpCache(); // restore true server state on failure
        }
    }

    /* ===========================
    INLINE EDITING
    =========================== */

    // Called when the user clicks the pencil (edit) icon next to a task.
    // Sets that task into edit mode and pre-fills the form with its current values.
    handleEditTask(event) {
        const taskId = event.currentTarget.dataset.id;
        const task = this.tasks.find(t => t.Id === taskId);
        if (!task) {
            return;
        }

        this.tasks = this.tasks.map(t => ({
            ...t,
            isEditing: t.Id === taskId
        }));

        this.editingTaskId = taskId;
        this.draft = {
            name: task.Name,
            priority: task.Priority__c || 'Medium',
            category: task.Category__c || '',
            notes: task.Notes__c || '',
            recurrence: task.Recurrence__c || 'None'
        };
    }

    handleDraftNameChange(event) {
        this.draft = { ...this.draft, name: event.target.value };
    }

    handleDraftPriorityChange(event) {
        this.draft = { ...this.draft, priority: event.detail.value };
    }

    handleDraftCategoryChange(event) {
        this.draft = { ...this.draft, category: event.detail.value };
    }

    handleDraftRecurrenceChange(event) {
        this.draft = { ...this.draft, recurrence: event.detail.value };
    }

    handleDraftNotesChange(event) {
        this.draft = { ...this.draft, notes: event.target.value };
    }

    // Keyboard shortcuts while the inline edit form is focused:
    //   Enter → save   |   Escape → cancel
    handleEditKeyDown(event) {
        if (event.key === 'Enter' && event.target.tagName !== 'TEXTAREA') {
            event.preventDefault();
            this.persistEdit(this.editingTaskId);
        }

        if (event.key === 'Escape') {
            event.preventDefault();
            this.handleCancelEdit();
        }
    }

    handleSaveTask(event) {
        const taskId = event.currentTarget.dataset.id;
        return this.persistEdit(taskId);
    }

    async persistEdit(taskId) {
        if (!this.draft.name || !this.draft.name.trim()) {
            return;
        }

        try {
            await updateTask({
                taskId,
                newName: this.draft.name,
                priority: this.draft.priority,
                category: this.draft.category || null,
                notes: this.draft.notes || null,
                recurrence: this.draft.recurrence
            });

            this.editingTaskId = null;
            this.showToast('Success', 'Task updated', 'success');
            this.bumpCache();

        } catch (error) {
            this.showToast('Error', error?.body?.message || 'Failed to update task', 'error');
        }
    }

    // Discards any changes and exits edit mode without saving
    handleCancelEdit() {
        this.editingTaskId = null;

        this.tasks = this.tasks.map(task => ({
            ...task,
            isEditing: false
        }));
    }

    // Helper that fires a toast notification.
    // variant controls the colour: 'success' = green, 'error' = red, 'info' = blue
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
