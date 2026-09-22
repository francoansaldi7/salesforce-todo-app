import { createElement } from 'lwc';
import TodoCompletedList from 'c/todoCompletedList';
import getCompletedTasks from '@salesforce/apex/TaskController.getCompletedTasks';
import toggleTaskStatus from '@salesforce/apex/TaskController.toggleTaskStatus';
import clearCompletedTasks from '@salesforce/apex/TaskController.clearCompletedTasks';
import restoreArchivedTask from '@salesforce/apex/TaskController.restoreArchivedTask';
import restoreAllArchivedTasks from '@salesforce/apex/TaskController.restoreAllArchivedTasks';
import deleteTask from '@salesforce/apex/TaskController.deleteTask';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';

jest.mock(
    '@salesforce/apex/TaskController.toggleTaskStatus',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TaskController.deleteTask',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TaskController.updateTask',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TaskController.clearCompletedTasks',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TaskController.restoreArchivedTask',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TaskController.restoreAllArchivedTasks',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const getCompletedTasksAdapter = registerApexTestWireAdapter(getCompletedTasks);

const MOCK_TASKS = [
    {
        Id: 'b01', Name: 'Filed taxes', Completed_Date__c: '2026-09-01',
        Priority__c: 'Low', Category__c: 'Personal', Notes__c: '', Recurrence__c: 'None'
    },
    {
        Id: 'b02', Name: 'Sent invoice', Completed_Date__c: '2026-09-02',
        Priority__c: 'Medium', Category__c: 'Work', Notes__c: '', Recurrence__c: 'None'
    }
];

function page(records, totalCount) {
    return { records, totalCount: totalCount === undefined ? records.length : totalCount };
}

function flushPromises() {
    return new Promise(resolve => setTimeout(resolve, 0));
}

// Waits out the search debounce (300ms) plus a little slack, then flushes microtasks.
function flushDebounce() {
    return new Promise(resolve => setTimeout(resolve, 350));
}

describe('c-todo-completed-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders each completed task returned by the wire', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        getCompletedTasksAdapter.emit(page(MOCK_TASKS));
        await flushPromises();

        const links = element.shadowRoot.querySelectorAll('.task-link');
        expect(links.length).toBe(2);
    });

    it('shows the total count (not just the current page size) in the card title', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        getCompletedTasksAdapter.emit(page(MOCK_TASKS, 27));
        await flushPromises();

        const title = element.shadowRoot.querySelector('.card-title');
        expect(title.textContent).toBe('Completed Tasks (27)');
    });

    it('shows the empty state when there are no completed tasks', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        getCompletedTasksAdapter.emit(page([], 0));
        await flushPromises();

        const emptyState = element.shadowRoot.querySelector('.empty-state');
        expect(emptyState.textContent).toContain('No completed tasks yet');
    });

    it('filters the list server-side (via a debounced search) as the user types', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        getCompletedTasksAdapter.emit(page(MOCK_TASKS));
        await flushPromises();

        const searchInput = element.shadowRoot.querySelector('.search-input');
        searchInput.value = 'invoice';
        searchInput.dispatchEvent(new CustomEvent('input'));

        // Simulates the server responding to the debounced, narrowed search request
        await flushDebounce();
        getCompletedTasksAdapter.emit(page([MOCK_TASKS[1]], 1));
        await flushPromises();

        const links = element.shadowRoot.querySelectorAll('.task-link');
        expect(links.length).toBe(1);
        expect(links[0].textContent.trim()).toBe('Sent invoice');
    });

    it('calls toggleTaskStatus and dispatches refreshlists when a checkbox is unchecked', async () => {
        toggleTaskStatus.mockResolvedValue();

        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        const refreshHandler = jest.fn();
        element.addEventListener('refreshlists', refreshHandler);

        getCompletedTasksAdapter.emit(page(MOCK_TASKS));
        await flushPromises();

        const checkbox = element.shadowRoot.querySelector('lightning-input');
        checkbox.dispatchEvent(new CustomEvent('change'));
        await flushPromises();

        expect(toggleTaskStatus).toHaveBeenCalledWith({ taskId: 'b01' });
        expect(refreshHandler).toHaveBeenCalled();
    });

    it('calls clearCompletedTasks when "Clear Completed" is clicked', async () => {
        clearCompletedTasks.mockResolvedValue();

        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        getCompletedTasksAdapter.emit(page(MOCK_TASKS));
        await flushPromises();

        const clearButton = element.shadowRoot.querySelector('.bulk-action-btn');
        clearButton.click();
        await flushPromises();

        expect(clearCompletedTasks).toHaveBeenCalled();
    });

    it('does not call clearCompletedTasks when there are no completed tasks', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        getCompletedTasksAdapter.emit(page([], 0));
        await flushPromises();

        const clearButton = element.shadowRoot.querySelector('.bulk-action-btn');
        clearButton.click();
        await flushPromises();

        expect(clearCompletedTasks).not.toHaveBeenCalled();
    });

    it('swaps "Clear Completed" for "Restore All" and shows per-task Restore buttons when viewing the Archived filter', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        getCompletedTasksAdapter.emit(page(MOCK_TASKS));
        await flushPromises();

        const filterCombobox = element.shadowRoot.querySelector('.filter-combobox');
        filterCombobox.dispatchEvent(new CustomEvent('change', { detail: { value: 'ARCHIVED' } }));
        getCompletedTasksAdapter.emit(page(MOCK_TASKS));
        await flushPromises();

        expect(element.shadowRoot.querySelector('.bulk-action-btn').textContent.trim()).toBe('Restore All');
        expect(element.shadowRoot.querySelectorAll('.restore-button').length).toBe(2);
    });

    it('calls restoreArchivedTask when the Restore button is clicked in the Archived view', async () => {
        restoreArchivedTask.mockResolvedValue();

        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        const filterCombobox = element.shadowRoot.querySelector('.filter-combobox');
        filterCombobox.dispatchEvent(new CustomEvent('change', { detail: { value: 'ARCHIVED' } }));
        getCompletedTasksAdapter.emit(page(MOCK_TASKS));
        await flushPromises();

        const restoreButton = element.shadowRoot.querySelector('.restore-button');
        restoreButton.click();
        await flushPromises();

        expect(restoreArchivedTask).toHaveBeenCalledWith({ taskId: 'b01' });
    });

    it('shows a "Restore All" button instead of "Clear Completed" when viewing the Archived filter', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        const filterCombobox = element.shadowRoot.querySelector('.filter-combobox');
        filterCombobox.dispatchEvent(new CustomEvent('change', { detail: { value: 'ARCHIVED' } }));
        getCompletedTasksAdapter.emit(page(MOCK_TASKS));
        await flushPromises();

        const restoreAllButton = element.shadowRoot.querySelector('.bulk-action-btn');
        expect(restoreAllButton.textContent.trim()).toBe('Restore All');
    });

    it('calls restoreAllArchivedTasks when "Restore All" is clicked', async () => {
        restoreAllArchivedTasks.mockResolvedValue();

        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        const filterCombobox = element.shadowRoot.querySelector('.filter-combobox');
        filterCombobox.dispatchEvent(new CustomEvent('change', { detail: { value: 'ARCHIVED' } }));
        getCompletedTasksAdapter.emit(page(MOCK_TASKS));
        await flushPromises();

        const restoreAllButton = element.shadowRoot.querySelector('.bulk-action-btn');
        restoreAllButton.click();
        await flushPromises();

        expect(restoreAllArchivedTasks).toHaveBeenCalled();
    });

    it('does not call restoreAllArchivedTasks when there are no archived tasks', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        const filterCombobox = element.shadowRoot.querySelector('.filter-combobox');
        filterCombobox.dispatchEvent(new CustomEvent('change', { detail: { value: 'ARCHIVED' } }));
        getCompletedTasksAdapter.emit(page([], 0));
        await flushPromises();

        const restoreAllButton = element.shadowRoot.querySelector('.bulk-action-btn');
        restoreAllButton.click();
        await flushPromises();

        expect(restoreAllArchivedTasks).not.toHaveBeenCalled();
    });

    it('hides a task immediately on delete and shows an undo bar, without calling deleteTask yet', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        getCompletedTasksAdapter.emit(page(MOCK_TASKS));
        await flushPromises();

        const deleteButton = element.shadowRoot.querySelector('.delete-button');
        deleteButton.click();
        await flushPromises();

        const links = element.shadowRoot.querySelectorAll('.task-link');
        expect(links.length).toBe(1);

        const undoBar = element.shadowRoot.querySelector('.undo-bar');
        expect(undoBar).not.toBeNull();
        expect(deleteTask).not.toHaveBeenCalled();
    });

    it('hides pagination controls when everything fits on one page', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        getCompletedTasksAdapter.emit(page(MOCK_TASKS, 2));
        await flushPromises();

        expect(element.shadowRoot.querySelector('.pagination-row')).toBeNull();
    });

    it('shows pagination controls and advances to the next page when there is more than one page', async () => {
        const element = createElement('c-todo-completed-list', { is: TodoCompletedList });
        document.body.appendChild(element);

        // 27 total records with a page size of 15 means 2 pages
        getCompletedTasksAdapter.emit(page(MOCK_TASKS, 27));
        await flushPromises();

        const paginationLabel = element.shadowRoot.querySelector('.pagination-label');
        expect(paginationLabel.textContent).toBe('Page 1 of 2');

        const [previousButton, nextButton] = element.shadowRoot.querySelectorAll('.pagination-btn');
        expect(previousButton.disabled).toBe(true);
        expect(nextButton.disabled).toBe(false);

        nextButton.click();
        await flushPromises();
        // Simulates the server responding with page 2's data
        getCompletedTasksAdapter.emit(page(MOCK_TASKS, 27));
        await flushPromises();

        expect(element.shadowRoot.querySelector('.pagination-label').textContent).toBe('Page 2 of 2');
    });
});
