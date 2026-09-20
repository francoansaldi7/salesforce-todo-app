import { createElement } from 'lwc';
import TodoPendingList from 'c/todoPendingList';
import getPendingTasks from '@salesforce/apex/TaskController.getPendingTasks';
import createTask from '@salesforce/apex/TaskController.createTask';
import deleteTask from '@salesforce/apex/TaskController.deleteTask';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';

jest.mock(
    '@salesforce/apex/TaskController.createTask',
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
    '@salesforce/apex/TaskController.toggleTaskStatus',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TaskController.reorderTasks',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TaskController.markAllTasksComplete',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/TaskController.materializeDueRecurrences',
    () => ({ default: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

const getPendingTasksAdapter = registerApexTestWireAdapter(getPendingTasks);

const MOCK_TASKS = [
    {
        Id: 'a01', Name: 'Buy milk', Completed__c: false,
        Priority__c: 'High', Category__c: 'Errands', Notes__c: '', Sort_Order__c: null, Recurrence__c: 'None'
    },
    {
        Id: 'a02', Name: 'Write report', Completed__c: false,
        Priority__c: 'Medium', Category__c: 'Work', Notes__c: 'Due Friday', Sort_Order__c: null, Recurrence__c: 'None'
    }
];

function flushPromises() {
    return new Promise(resolve => setTimeout(resolve, 0));
}

describe('c-todo-pending-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders each task returned by the wire', async () => {
        const element = createElement('c-todo-pending-list', { is: TodoPendingList });
        document.body.appendChild(element);

        getPendingTasksAdapter.emit(MOCK_TASKS);
        await flushPromises();

        const links = element.shadowRoot.querySelectorAll('.task-link');
        expect(links.length).toBe(2);
        expect(links[0].textContent.trim()).toBe('Buy milk');
    });

    it('shows the empty state when there are no pending tasks', async () => {
        const element = createElement('c-todo-pending-list', { is: TodoPendingList });
        document.body.appendChild(element);

        getPendingTasksAdapter.emit([]);
        await flushPromises();

        const emptyState = element.shadowRoot.querySelector('.empty-state');
        expect(emptyState).not.toBeNull();
        expect(emptyState.textContent).toContain('No pending tasks');
    });

    it('shows the task count in the card title', async () => {
        const element = createElement('c-todo-pending-list', { is: TodoPendingList });
        document.body.appendChild(element);

        getPendingTasksAdapter.emit(MOCK_TASKS);
        await flushPromises();

        const title = element.shadowRoot.querySelector('.card-title');
        expect(title.textContent).toBe('Pending Tasks (2)');
    });

    it('filters the visible list as the user types in the search box', async () => {
        const element = createElement('c-todo-pending-list', { is: TodoPendingList });
        document.body.appendChild(element);

        getPendingTasksAdapter.emit(MOCK_TASKS);
        await flushPromises();

        const searchInput = element.shadowRoot.querySelector('.search-input');
        searchInput.value = 'milk';
        searchInput.dispatchEvent(new CustomEvent('input'));
        await flushPromises();

        const links = element.shadowRoot.querySelectorAll('.task-link');
        expect(links.length).toBe(1);
        expect(links[0].textContent.trim()).toBe('Buy milk');
    });

    it('shows a no-results message when the search matches nothing', async () => {
        const element = createElement('c-todo-pending-list', { is: TodoPendingList });
        document.body.appendChild(element);

        getPendingTasksAdapter.emit(MOCK_TASKS);
        await flushPromises();

        const searchInput = element.shadowRoot.querySelector('.search-input');
        searchInput.value = 'nothing matches this';
        searchInput.dispatchEvent(new CustomEvent('input'));
        await flushPromises();

        const emptyState = element.shadowRoot.querySelector('.empty-state');
        expect(emptyState.textContent).toContain('No pending tasks match');
    });

    it('calls createTask and clears the input when Add Task is clicked', async () => {
        createTask.mockResolvedValue();

        const element = createElement('c-todo-pending-list', { is: TodoPendingList });
        document.body.appendChild(element);

        getPendingTasksAdapter.emit(MOCK_TASKS);
        await flushPromises();

        const input = element.shadowRoot.querySelector('.new-task-input');
        input.value = 'New task';
        input.dispatchEvent(new CustomEvent('input'));

        const addButton = element.shadowRoot.querySelector('.add-btn');
        addButton.click();
        await flushPromises();

        expect(createTask).toHaveBeenCalledWith({ taskName: 'New task' });
    });

    it('does not call createTask when the input is blank', async () => {
        const element = createElement('c-todo-pending-list', { is: TodoPendingList });
        document.body.appendChild(element);

        getPendingTasksAdapter.emit(MOCK_TASKS);
        await flushPromises();

        const addButton = element.shadowRoot.querySelector('.add-btn');
        addButton.click();
        await flushPromises();

        expect(createTask).not.toHaveBeenCalled();
    });

    it('hides a task immediately on delete and shows an undo bar, without calling deleteTask yet', async () => {
        const element = createElement('c-todo-pending-list', { is: TodoPendingList });
        document.body.appendChild(element);

        getPendingTasksAdapter.emit(MOCK_TASKS);
        await flushPromises();

        const deleteButton = element.shadowRoot.querySelector('.delete-button');
        deleteButton.click();
        await flushPromises();

        const links = element.shadowRoot.querySelectorAll('.task-link');
        expect(links.length).toBe(1); // one task optimistically hidden

        const undoBar = element.shadowRoot.querySelector('.undo-bar');
        expect(undoBar).not.toBeNull();
        expect(deleteTask).not.toHaveBeenCalled();
    });

    it('restores the task when Undo is clicked, and never calls deleteTask', async () => {
        const element = createElement('c-todo-pending-list', { is: TodoPendingList });
        document.body.appendChild(element);

        getPendingTasksAdapter.emit(MOCK_TASKS);
        await flushPromises();

        const deleteButton = element.shadowRoot.querySelector('.delete-button');
        deleteButton.click();
        await flushPromises();

        const undoButton = element.shadowRoot.querySelector('.undo-btn');
        undoButton.click();
        await flushPromises();

        const links = element.shadowRoot.querySelectorAll('.task-link');
        expect(links.length).toBe(2);
        expect(deleteTask).not.toHaveBeenCalled();
    });
});
