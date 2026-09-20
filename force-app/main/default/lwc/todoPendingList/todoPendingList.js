// ─── Imports ──────────────────────────────────────────────────────────────────
// LWC core decorators:
//   @track  → makes arrays/objects deeply reactive (UI updates when items change)
//   @wire   → automatically calls an Apex method and updates the component when data arrives
//   @api    → marks a property or method as public so parent components can use it
import { LightningElement, track, wire, api } from 'lwc';

// Apex methods from TaskController — each one talks to the Salesforce database
import getPendingTasks from '@salesforce/apex/TaskController.getPendingTasks';
import createTask from '@salesforce/apex/TaskController.createTask';
import deleteTask from '@salesforce/apex/TaskController.deleteTask';
import updateTask from '@salesforce/apex/TaskController.updateTask';
import toggleTaskStatus from '@salesforce/apex/TaskController.toggleTaskStatus';
import reorderTasks from '@salesforce/apex/TaskController.reorderTasks';
import markAllTasksComplete from '@salesforce/apex/TaskController.markAllTasksComplete';
import materializeDueRecurrences from '@salesforce/apex/TaskController.materializeDueRecurrences';

// refreshApex re-runs a @wire query to get the latest data from Salesforce
import { refreshApex } from '@salesforce/apex';

// Shows a small pop-up notification (toast) at the top of the screen
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// Lets us navigate to a Salesforce record page when the user clicks a task name
import { NavigationMixin } from 'lightning/navigation';

// How long the undo bar stays up before a delete becomes permanent (ms)
const UNDO_WINDOW_MS = 5000;

// ─── Component ────────────────────────────────────────────────────────────────
export default class TodoPendingList extends NavigationMixin(LightningElement) {

    @track tasks;          // list of pending task records shown in the UI
    newTaskName = '';      // text the user types in the "New Task" input
    wiredResult;           // stored wire result so we can call refreshApex later
    isLoading = true;      // shows a spinner until the first data load finishes
    searchTerm = '';        // live text used to filter the visible task list

    editingTaskId = null;  // ID of the task currently being edited inline (null = none)
    // Draft values shown in the inline edit form — populated from the task being edited
    @track draft = { name: '', priority: 'Medium', category: '', notes: '', recurrence: 'None' };

    pendingDeletion = null; // { id, task } for a task hidden pending the undo window
    pendingDeletionTimeoutId = null;

    draggedTaskId = null;   // ID of the task currently being dragged

    connectedCallback() {
        // Recurring tasks whose next occurrence has come due are created lazily —
        // check for them once when the list loads, then refresh if anything changed.
        materializeDueRecurrences()
            .then(() => {
                if (this.wiredResult) {
                    return refreshApex(this.wiredResult);
                }
                return undefined;
            })
            .catch(() => {
                // Non-critical — if this fails, recurring tasks simply won't advance
                // until the next successful load. No need to surface an error toast.
            });
    }

    disconnectedCallback() {
        // Avoid finalizing a delete (or touching component state) after teardown.
        if (this.pendingDeletionTimeoutId) {
            clearTimeout(this.pendingDeletionTimeoutId);
        }
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
        const count = this.tasks ? this.tasks.length : 0;
        return `Pending Tasks (${count})`;
    }

    get hasNoTasks() {
        return !this.tasks || this.tasks.length === 0;
    }

    // Tasks after the live search filter is applied
    get filteredTasks() {
        if (!this.tasks) {
            return [];
        }
        const term = this.searchTerm.trim().toLowerCase();
        if (!term) {
            return this.tasks;
        }
        return this.tasks.filter(task =>
            (task.Name || '').toLowerCase().includes(term) ||
            (task.Notes__c || '').toLowerCase().includes(term)
        );
    }

    get hasVisibleTasks() {
        return this.filteredTasks.length > 0;
    }

    // Shown when there are truly no pending tasks at all
    get showEmptyState() {
        return !this.isLoading && this.hasNoTasks;
    }

    // Shown when there are tasks, but the search term matched none of them
    get showNoResultsState() {
        return !this.isLoading && !this.hasNoTasks && this.filteredTasks.length === 0;
    }

    // ── Data load ────────────────────────────────────────────────────────────

    // @wire automatically calls getPendingTasks when the component loads.
    // Every time the result changes (data or error), this function runs again.
    @wire(getPendingTasks)
    wiredTasks(result) {
        this.wiredResult = result; // save a reference for refreshApex to use later
        this.isLoading = false;    // hide the spinner once we have a response

        if (result.data) {
            // Add display-only helper properties so the template can stay simple —
            // LWC templates can't call getters with per-item parameters in a loop.
            this.tasks = result.data.map(task => ({
                ...task,       // copy all existing task fields
                isEditing: false,
                priorityClass: `priority-dot priority-${(task.Priority__c || 'medium').toLowerCase()}`,
                hasNotes: !!(task.Notes__c && task.Notes__c.trim()),
                isRecurring: !!(task.Recurrence__c && task.Recurrence__c !== 'None')
            }));
            // Lets the parent (todoApp) show a live count on the mobile tab bar.
            this.dispatchEvent(new CustomEvent('pendingcountchange', { detail: { count: this.tasks.length } }));
        } else if (result.error) {
            this.showToast('Error', 'Failed to load tasks', 'error');
        }
    }

    // Public method — the parent (todoApp) can call this to force a data reload.
    // The @api decorator makes it accessible from outside this component.
    @api
    refreshData() {
        return refreshApex(this.wiredResult);
    }

    // ── Search ───────────────────────────────────────────────────────────────

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    // ── Add task ─────────────────────────────────────────────────────────────

    // Updates newTaskName as the user types in the input field
    handleInputChange(event) {
        this.newTaskName = event.target.value;
    }

    // Called when the user clicks "Add Task" — creates the task in Salesforce
    handleAddTask() {
        // Don't do anything if the input is empty or just spaces
        if (!this.newTaskName || this.newTaskName.trim() === '') {
            return;
        }

        createTask({ taskName: this.newTaskName })
            .then(() => {
                this.newTaskName = ''; // clear the input after a successful save
                this.showToast('Success', 'Task created', 'success');
                return refreshApex(this.wiredResult); // reload the list
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to create task', 'error');
            });
    }

    // Lets the user press Enter instead of clicking the "Add Task" button
    handleAddKeyDown(event) {
        if (event.key === 'Enter') {
            event.preventDefault(); // stop the browser's default Enter behaviour
            this.handleAddTask();
        }
    }

    // ── Complete / bulk complete ─────────────────────────────────────────────

    // Called when the user ticks the checkbox next to a task —
    // flips the task between Pending and Completed
    handleCheckboxChange(event) {
        const taskId = event.currentTarget.dataset.id; // read the task ID from data-id attribute

        toggleTaskStatus({ taskId })
            .then(() => {
                // Tell the parent component to also refresh the completed list
                this.dispatchEvent(new CustomEvent('refreshlists'));
                return refreshApex(this.wiredResult);
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to update task', 'error');
            });
    }

    // Marks every pending task as complete in one action.
    handleMarkAllComplete() {
        if (this.hasNoTasks) {
            return;
        }

        markAllTasksComplete()
            .then(() => {
                this.showToast('Success', 'All tasks marked complete', 'success');
                this.dispatchEvent(new CustomEvent('refreshlists'));
                return refreshApex(this.wiredResult);
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to update tasks', 'error');
            });
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
            await refreshApex(this.wiredResult);
        } catch (error) {
            this.showToast('Error', error?.body?.message || 'Failed to delete task', 'error');
            await refreshApex(this.wiredResult); // restore true server state on failure
        }
    }

    // ── Navigation ───────────────────────────────────────────────────────────

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

    /* ===========================
    DRAG-AND-DROP REORDERING
    =========================== */

    handleDragStart(event) {
        this.draggedTaskId = event.currentTarget.dataset.id;
        event.dataTransfer.effectAllowed = 'move';
    }

    handleDragOver(event) {
        // Required so the browser allows a drop on this element
        event.preventDefault();
    }

    handleDrop(event) {
        event.preventDefault();
        const targetId = event.currentTarget.dataset.id;

        if (!this.draggedTaskId || this.draggedTaskId === targetId) {
            return;
        }

        const reordered = [...this.tasks];
        const fromIndex = reordered.findIndex(t => t.Id === this.draggedTaskId);
        const toIndex = reordered.findIndex(t => t.Id === targetId);

        if (fromIndex === -1 || toIndex === -1) {
            return;
        }

        const [movedTask] = reordered.splice(fromIndex, 1);
        reordered.splice(toIndex, 0, movedTask);
        this.tasks = reordered; // optimistic reorder — updates immediately in the UI

        reorderTasks({ orderedTaskIds: reordered.map(t => t.Id) })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to save new order', 'error');
                refreshApex(this.wiredResult); // revert to server truth on failure
            });
    }

    handleDragEnd() {
        this.draggedTaskId = null;
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

        // Use map() to rebuild the array with only the clicked task set to isEditing = true
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

    // Keeps the draft in sync as the user edits each field
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
            this.saveInlineEdit(this.editingTaskId);
        }

        if (event.key === 'Escape') {
            event.preventDefault();
            this.handleCancelEdit();
        }
    }

    // Saves the edited task when the user presses Enter (keyboard shortcut path)
    saveInlineEdit(taskId) {
        return this.persistEdit(taskId);
    }

    // Saves the edited task when the user clicks the ✓ icon (button click path)
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
            await refreshApex(this.wiredResult);

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
